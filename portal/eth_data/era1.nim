# Nimbus
# Copyright (c) 2024-2025 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import
  std/[strformat, typetraits],
  results,
  stew/[endians2, io2, byteutils, arrayops],
  stint,
  snappy,
  eth/common/[headers_rlp, blocks_rlp, receipts_rlp],
  beacon_chain/spec/beacon_time,
  ssz_serialization,
  ncli/e2store,
  ../network/legacy_history/validation/historical_hashes_accumulator

from eth/common/eth_types_rlp import computeRlpHash
from nimcrypto/hash import fromHex
from ../../execution_chain/utils/utils import calcTxRoot, calcReceiptsRoot

export e2store.readRecord

# Implementation of era1 file format as current described in:
# https://github.com/ethereum/go-ethereum/pull/26621

# era1 := Version | block-tuple* | other-entries* | Accumulator | BlockIndex
# block-tuple :=  CompressedHeader | CompressedBody | CompressedReceipts | TotalDifficulty

# block-index := starting-number | index | index | index ... | count

# CompressedHeader   = { type: 0x03,   data: snappyFramed(rlp(header)) }
# CompressedBody     = { type: 0x04,   data: snappyFramed(rlp(body)) }
# CompressedReceipts = { type: 0x05,   data: snappyFramed(rlp(receipts)) }
# TotalDifficulty    = { type: 0x06,   data: uint256(header.total_difficulty) }
# AccumulatorRoot    = { type: 0x07,   data: hash_tree_root(List(HeaderRecord, 8192)) }
# BlockIndex         = { type: 0x3266, data: block-index }

# Important note:
# Snappy does not give the same compression result as the implementation used
# by go-ethereum for some block headers and block bodies. This means that we
# cannot rely on the secondary verification mechanism that is based on doing the
# sha256sum of the full era1 files.
#

const
  # Note: When specification is more official, these could go with the other
  # E2S types.
  CompressedHeader* = [byte 0x03, 0x00]
  CompressedBody* = [byte 0x04, 0x00]
  CompressedReceipts* = [byte 0x05, 0x00]
  TotalDifficulty* = [byte 0x06, 0x00]
  AccumulatorRoot* = [byte 0x07, 0x00]
  E2BlockIndex* = [byte 0x66, 0x32]

  MaxEra1Size* = 8192

type
  BlockIndex* = object
    startNumber*: uint64
    offsets*: seq[int64] # Absolute positions in file

  Era1* = distinct uint64 # Period of 8192 blocks (not an exact time unit)

  Era1Group* = object
    blockIndex*: BlockIndex

# As stated, not really a time unit but nevertheless, need the borrows
ethTimeUnit Era1

template lenu64(x: untyped): untyped =
  uint64(len(x))

# Note: appendIndex, appendRecord and readIndex for BlockIndex are very similar
# to its consensus layer counter parts. The difference lies in the naming of
# slots vs block numbers and there is different behavior for the first era
# (first slot) and the last era (era1 ends at merge block).

proc appendIndex*(
    f: IoHandle, startNumber: uint64, offsets: openArray[int64]
): Result[int64, string] =
  let
    len = offsets.len() * sizeof(int64) + 16
    pos = ?f.appendHeader(E2BlockIndex, len)

  ?f.append(startNumber.uint64.toBytesLE())

  for v in offsets:
    ?f.append(cast[uint64](v - pos).toBytesLE())

  ?f.append(offsets.lenu64().toBytesLE())

  ok(pos)

proc appendRecord(f: IoHandle, index: BlockIndex): Result[int64, string] =
  f.appendIndex(index.startNumber, index.offsets)

proc readBlockIndex*(f: IoHandle): Result[BlockIndex, string] =
  var
    buf: seq[byte]
    pos: int

  let
    startPos = ?f.getFilePos().mapErr(toString)
    fileSize = ?f.getFileSize().mapErr(toString)
    header = ?f.readRecord(buf)

  if header.typ != E2BlockIndex:
    return err("not an index")
  if buf.len < 16:
    return err("index entry too small")
  if buf.len mod 8 != 0:
    return err("index length invalid")

  let
    blockNumber = uint64.fromBytesLE(buf.toOpenArray(pos, pos + 7))
    count = buf.len div 8 - 2
  pos += 8

  # technically not an error, but we'll throw this sanity check in here..
  if blockNumber > int32.high().uint64:
    return err("fishy block number")

  var offsets = newSeqUninit[int64](count)
  for i in 0 ..< count:
    let
      offset = uint64.fromBytesLE(buf.toOpenArray(pos, pos + 7))
      absolute =
        if offset == 0:
          0'i64
        else:
          # Wrapping math is actually convenient here
          cast[int64](cast[uint64](startPos) + offset)

    if absolute < 0 or absolute > fileSize:
      return err("invalid offset")
    offsets[i] = absolute
    pos += 8

  if uint64(count) != uint64.fromBytesLE(buf.toOpenArray(pos, pos + 7)):
    return err("invalid count")

  ok(BlockIndex(startNumber: blockNumber, offsets: offsets))

proc skipRecord*(f: IoHandle): Result[void, string] =
  let header = ?readHeader(f)
  if header.len > 0:
    ?f.setFilePos(header.len, SeekPosition.SeekCurrent).mapErr(ioErrorMsg)

  ok()

func startNumber*(era: Era1): uint64 =
  era * MaxEra1Size

func endNumber*(era: Era1): uint64 =
  if (era + 1) * MaxEra1Size - 1'u64 >= mergeBlockNumber:
    # The incomplete era just before the merge
    mergeBlockNumber - 1'u64
  else:
    (era + 1) * MaxEra1Size - 1'u64

func endNumber*(blockIdx: BlockIndex): uint64 =
  blockIdx.startNumber + blockIdx.offsets.lenu64() - 1

func era*(blockNumber: uint64): Era1 =
  Era1(blockNumber div MaxEra1Size)

func offsetsLen(startNumber: uint64): int =
  # For the era where the merge happens the era files only holds the blocks
  # until the merge block so the offsets length needs to be adapted too.
  if startNumber.era() >= mergeBlockNumber.era():
    int((mergeBlockNumber) mod MaxEra1Size)
  else:
    MaxEra1Size

proc toCompressedRlpBytes(item: auto): seq[byte] =
  snappy.encodeFramed(rlp.encode(item))

proc fromCompressedRlpBytes[T](bytes: openArray[byte], v: var T): Result[void, string] =
  try:
    v = rlp.decode(decodeFramed(bytes, checkIntegrity = false), T)
    ok()
  except RlpError as e:
    err("Invalid compressed RLP data for " & $T & ": " & e.msg)

proc init*(T: type Era1Group, f: IoHandle, startNumber: uint64): Result[T, string] =
  discard ?f.appendHeader(E2Version, 0)

  ok(
    Era1Group(
      blockIndex: BlockIndex(
        startNumber: startNumber, offsets: newSeq[int64](startNumber.offsetsLen())
      )
    )
  )

proc update*(
    g: var Era1Group,
    f: IoHandle,
    blockNumber: uint64,
    header, body, receipts, totalDifficulty: openArray[byte],
): Result[void, string] =
  doAssert blockNumber >= g.blockIndex.startNumber

  g.blockIndex.offsets[int(blockNumber - g.blockIndex.startNumber)] =
    ?f.appendRecord(CompressedHeader, header)
  discard ?f.appendRecord(CompressedBody, body)
  discard ?f.appendRecord(CompressedReceipts, receipts)
  discard ?f.appendRecord(TotalDifficulty, totalDifficulty)

  ok()

proc update*(
    g: var Era1Group,
    f: IoHandle,
    blockNumber: uint64,
    header: headers.Header,
    body: BlockBody,
    receipts: seq[Receipt],
    totalDifficulty: UInt256,
): Result[void, string] =
  g.update(
    f,
    blockNumber,
    toCompressedRlpBytes(header),
    toCompressedRlpBytes(body),
    toCompressedRlpBytes(receipts),
    totalDifficulty.toBytesLE(),
  )

proc finish*(
    g: var Era1Group, f: IoHandle, accumulatorRoot: Digest, lastBlockNumber: uint64
): Result[void, string] =
  let accumulatorRootPos = ?f.appendRecord(AccumulatorRoot, accumulatorRoot.data)

  if lastBlockNumber > 0:
    discard ?f.appendRecord(g.blockIndex)

  # TODO:
  # This is not something added in current specification of era1.
  # But perhaps we want to be able to quickly jump to acummulator root.
  # discard ? f.appendIndex(lastBlockNumber, [accumulatorRootPos])
  discard accumulatorRootPos

  ok()

func shortLog*(x: Digest): string =
  x.data.toOpenArray(0, 3).toHex()

func era1FileName*(network: string, era: Era1, eraRoot: Digest): string =
  try:
    &"{network}-{era.uint64:05}-{shortLog(eraRoot)}.era1"
  except ValueError as exc:
    raiseAssert exc.msg

# Helpers to directly read objects from era1 files
# TODO: Might want to var parameters to avoid copying as is done for era files.

type
  Era1File* = ref object
    handle: Opt[IoHandle]
    blockIdx*: BlockIndex

  BlockTuple* =
    tuple[header: headers.Header, body: BlockBody, receipts: seq[Receipt], td: UInt256]

proc open*(_: type Era1File, name: string): Result[Era1File, string] =
  var f = Opt[IoHandle].ok(?openFile(name, {OpenFlags.Read}).mapErr(ioErrorMsg))

  defer:
    if f.isSome():
      discard closeFile(f[])

  # Indices can be found at the end of each era file - we only support
  # single-era files for now
  ?f[].setFilePos(0, SeekPosition.SeekEnd).mapErr(ioErrorMsg)

  # Last in the file is the block index
  let blockIdxPos = ?f[].findIndexStartOffset()
  ?f[].setFilePos(blockIdxPos, SeekPosition.SeekCurrent).mapErr(ioErrorMsg)

  let blockIdx = ?f[].readBlockIndex()
  if blockIdx.offsets.len() != blockIdx.startNumber.offsetsLen():
    return err("Block index length invalid")

  let res = Era1File(handle: f, blockIdx: blockIdx)
  reset(f)
  ok res

proc close*(f: Era1File) =
  if f.handle.isSome():
    discard closeFile(f.handle.get())
    reset(f.handle)

proc skipRecord*(f: Era1File): Result[void, string] =
  doAssert f[].handle.isSome()

  f[].handle.get().skipRecord()

proc getBlockHeader(f: Era1File, res: var headers.Header): Result[void, string] =
  var bytes: seq[byte]

  let header = ?f[].handle.get().readRecord(bytes)
  if header.typ != CompressedHeader:
    return err("Invalid era file: didn't find block header at index position")

  fromCompressedRlpBytes(bytes, res)

proc getBlockBody(f: Era1File, res: var BlockBody): Result[void, string] =
  var bytes: seq[byte]

  let header = ?f[].handle.get().readRecord(bytes)
  if header.typ != CompressedBody:
    return err("Invalid era file: didn't find block body at index position")

  fromCompressedRlpBytes(bytes, res)

proc getReceipts(f: Era1File, res: var seq[Receipt]): Result[void, string] =
  var bytes: seq[byte]

  let header = ?f[].handle.get().readRecord(bytes)
  if header.typ != CompressedReceipts:
    return err("Invalid era file: didn't find receipts at index position")

  fromCompressedRlpBytes(bytes, res)

proc getTotalDifficulty(f: Era1File): Result[UInt256, string] =
  var bytes: seq[byte]

  let header = ?f[].handle.get().readRecord(bytes)
  if header.typ != TotalDifficulty:
    return err("Invalid era file: didn't find total difficulty at index position")

  if bytes.len != 32:
    return err("Invalid total difficulty length")

  ok(UInt256.fromBytesLE(bytes))

proc getNextEthBlock*(f: Era1File, res: var Block): Result[void, string] =
  doAssert not isNil(f) and f[].handle.isSome

  var body: BlockBody
  ?getBlockHeader(f, res.header)
  ?getBlockBody(f, body)

  ?skipRecord(f) # receipts
  ?skipRecord(f) # totalDifficulty

  res.transactions = move(body.transactions)
  res.uncles = move(body.uncles)
  res.withdrawals = move(body.withdrawals)

  ok()

proc getEthBlock*(
    f: Era1File, blockNumber: uint64, res: var Block
): Result[void, string] =
  doAssert not isNil(f) and f[].handle.isSome
  doAssert(
    blockNumber >= f[].blockIdx.startNumber and blockNumber <= f[].blockIdx.endNumber,
    "Wrong era1 file for selected block number",
  )

  let pos = f[].blockIdx.offsets[blockNumber - f[].blockIdx.startNumber]

  ?f[].handle.get().setFilePos(pos, SeekPosition.SeekBegin).mapErr(ioErrorMsg)

  getNextEthBlock(f, res)

proc getNextBlockTuple*(f: Era1File, res: var BlockTuple): Result[void, string] =
  doAssert not isNil(f) and f[].handle.isSome

  ?getBlockHeader(f, res.header)
  ?getBlockBody(f, res.body)
  ?getReceipts(f, res.receipts)
  res.td = ?getTotalDifficulty(f)

  ok()

proc getBlockTuple*(
    f: Era1File, blockNumber: uint64, res: var BlockTuple
): Result[void, string] =
  doAssert not isNil(f) and f[].handle.isSome
  doAssert(
    blockNumber >= f[].blockIdx.startNumber and blockNumber <= f[].blockIdx.endNumber,
    "Wrong era1 file for selected block number",
  )

  let pos = f[].blockIdx.offsets[blockNumber - f[].blockIdx.startNumber]

  ?f[].handle.get().setFilePos(pos, SeekPosition.SeekBegin).mapErr(ioErrorMsg)

  getNextBlockTuple(f, res)

proc getBlockHeader*(
    f: Era1File, blockNumber: uint64, res: var headers.Header
): Result[void, string] =
  doAssert not isNil(f) and f[].handle.isSome
  doAssert(
    blockNumber >= f[].blockIdx.startNumber and blockNumber <= f[].blockIdx.endNumber,
    "Wrong era1 file for selected block number",
  )

  let pos = f[].blockIdx.offsets[blockNumber - f[].blockIdx.startNumber]

  ?f[].handle.get().setFilePos(pos, SeekPosition.SeekBegin).mapErr(ioErrorMsg)

  getBlockHeader(f, res)

proc getTotalDifficulty*(f: Era1File, blockNumber: uint64): Result[UInt256, string] =
  doAssert not isNil(f) and f[].handle.isSome
  doAssert(
    blockNumber >= f[].blockIdx.startNumber and blockNumber <= f[].blockIdx.endNumber,
    "Wrong era1 file for selected block number",
  )

  let pos = f[].blockIdx.offsets[blockNumber - f[].blockIdx.startNumber]

  ?f[].handle.get().setFilePos(pos, SeekPosition.SeekBegin).mapErr(ioErrorMsg)

  ?skipRecord(f) # Header
  ?skipRecord(f) # BlockBody
  ?skipRecord(f) # Receipts
  getTotalDifficulty(f)

# TODO: Should we add this perhaps in the Era1File object and grab it in open()?
proc getAccumulatorRoot*(f: Era1File): Result[Digest, string] =
  # Get position of BlockIndex
  ?f[].handle.get().setFilePos(0, SeekPosition.SeekEnd).mapErr(ioErrorMsg)
  let blockIdxPos = ?f[].handle.get().findIndexStartOffset()

  # Accumulator root is 40 bytes before the BlockIndex
  let accumulatorRootPos = blockIdxPos - 40 # 8 + 32
  ?f[].handle.get().setFilePos(accumulatorRootPos, SeekPosition.SeekCurrent).mapErr(
    ioErrorMsg
  )

  var bytes: seq[byte]
  let header = ?f[].handle.get().readRecord(bytes)

  if header.typ != AccumulatorRoot:
    return err("Invalid era file: didn't find accumulator root at index position")

  if bytes.len != 32:
    return err("invalid accumulator root")

  ok(Digest(data: array[32, byte].initCopyFrom(bytes)))

proc buildAccumulator*(f: Era1File): Result[EpochRecordCached, string] =
  let
    startNumber = f.blockIdx.startNumber
    endNumber = f.blockIdx.endNumber()

  var headerRecords: seq[HeaderRecord]
  var header: headers.Header
  for blockNumber in startNumber .. endNumber:
    ?f.getBlockHeader(blockNumber, header)
    let totalDifficulty = ?f.getTotalDifficulty(blockNumber)

    headerRecords.add(
      HeaderRecord(blockHash: header.computeRlpHash(), totalDifficulty: totalDifficulty)
    )

  ok(EpochRecordCached.init(headerRecords))

proc verify*(f: Era1File): Result[Digest, string] =
  let
    startNumber = f.blockIdx.startNumber
    endNumber = f.blockIdx.endNumber()

  var headerRecords: seq[HeaderRecord]
  var blockTuple: BlockTuple
  for blockNumber in startNumber .. endNumber:
    ?f.getBlockTuple(blockNumber, blockTuple)
    let
      txRoot = calcTxRoot(blockTuple.body.transactions)
      ommershHash = computeRlpHash(blockTuple.body.uncles)

    if blockTuple.header.txRoot != txRoot:
      return err("Invalid transactions root")

    if blockTuple.header.ommersHash != ommershHash:
      return err("Invalid ommers hash")

    if blockTuple.header.receiptsRoot != calcReceiptsRoot(blockTuple.receipts):
      return err("Invalid receipts root")

    headerRecords.add(
      HeaderRecord(
        blockHash: blockTuple.header.computeRlpHash(), totalDifficulty: blockTuple.td
      )
    )

  let expectedRoot = ?f.getAccumulatorRoot()
  let accumulatorRoot = getEpochRecordRoot(headerRecords)

  if accumulatorRoot != expectedRoot:
    err("Invalid accumulator root")
  else:
    ok(accumulatorRoot)

iterator era1BlockHeaders*(f: Era1File): headers.Header =
  let
    startNumber = f.blockIdx.startNumber
    endNumber = f.blockIdx.endNumber()

  var header: headers.Header
  for blockNumber in startNumber .. endNumber:
    f.getBlockHeader(blockNumber, header).expect("Header can be read")
    yield header

iterator era1BlockTuples*(f: Era1File): BlockTuple =
  let
    startNumber = f.blockIdx.startNumber
    endNumber = f.blockIdx.endNumber()

  var blockTuple: BlockTuple
  for blockNumber in startNumber .. endNumber:
    f.getBlockTuple(blockNumber, blockTuple).expect("Block tuple can be read")
    yield blockTuple
