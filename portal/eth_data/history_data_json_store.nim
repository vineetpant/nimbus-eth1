# Nimbus - Portal Network
# Copyright (c) 2022-2025 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import
  json_serialization,
  json_serialization/std/tables,
  results,
  stew/[byteutils, io2],
  chronicles,
  eth/common/[hashes, blocks, receipts, headers_rlp],
  ../../execution_chain/common/[chain_config, genesis],
  ../network/legacy_history/[history_content, validation/historical_hashes_accumulator]

export results, tables

# Helper calls to read/write history data from/to json files.
# Format is currently unspecified and likely to change.

# Reading JSON history data

type
  BlockData* = object
    header*: string
    body*: string
    receipts*: string
    # TODO:
    # uint64, but then it expects a string for some reason.
    # Fix in nim-json-serialization or should I overload something here?
    number*: int

  BlockDataTable* = Table[string, BlockData]

iterator blockHashes*(blockData: BlockDataTable): Hash32 =
  for k, v in blockData:
    var blockHash: Hash32
    try:
      blockHash.data = hexToByteArray[sizeof(Hash32)](k)
    except ValueError as e:
      error "Invalid hex for block hash", error = e.msg, number = v.number
      continue

    yield blockHash

func readBlockData*(
    hash: string, blockData: BlockData, verify = false
): Result[seq[(ContentKey, seq[byte])], string] =
  var res: seq[(ContentKey, seq[byte])]

  var blockHash: Hash32
  try:
    blockHash.data = hexToByteArray[sizeof(Hash32)](hash)
  except ValueError as e:
    return err("Invalid hex for blockhash, number " & $blockData.number & ": " & e.msg)

  let contentKeyType = BlockKey(blockHash: blockHash)

  try:
    # If wanted the hash for the corresponding header can be verified
    if verify:
      if keccak256(blockData.header.hexToSeqByte()) != blockHash:
        return err("Data is not matching hash, number " & $blockData.number)

    block:
      let contentKey =
        ContentKey(contentType: blockHeader, blockHeaderKey: contentKeyType)

      res.add((contentKey, blockData.header.hexToSeqByte()))

    block:
      let contentKey = ContentKey(contentType: blockBody, blockBodyKey: contentKeyType)

      res.add((contentKey, blockData.body.hexToSeqByte()))

    block:
      let contentKey =
        ContentKey(contentType: ContentType.receipts, receiptsKey: contentKeyType)

      res.add((contentKey, blockData.receipts.hexToSeqByte()))
  except ValueError as e:
    return err("Invalid hex data, number " & $blockData.number & ": " & e.msg)

  ok(res)

iterator blocks*(
    blockData: BlockDataTable, verify = false
): seq[(ContentKey, seq[byte])] =
  for k, v in blockData:
    let res = readBlockData(k, v, verify)

    if res.isOk():
      yield res.get()
    else:
      error "Failed reading block from block data", error = res.error

func readBlockHeader*(blockData: BlockData): Result[Header, string] =
  var rlp =
    try:
      rlpFromHex(blockData.header)
    except ValueError as e:
      return err(
        "Invalid hex for rlp block data, number " & $blockData.number & ": " & e.msg
      )

  try:
    return ok(rlp.read(Header))
  except RlpError as e:
    return err("Invalid header, number " & $blockData.number & ": " & e.msg)

func readHeaderData*(
    hash: string, blockData: BlockData, verify = false
): Result[(ContentKey, seq[byte]), string] =
  var blockHash: Hash32
  try:
    blockHash.data = hexToByteArray[sizeof(Hash32)](hash)
  except ValueError as e:
    return err("Invalid hex for blockhash, number " & $blockData.number & ": " & e.msg)

  let contentKeyType = BlockKey(blockHash: blockHash)

  try:
    # If wanted the hash for the corresponding header can be verified
    if verify:
      if keccak256(blockData.header.hexToSeqByte()) != blockHash:
        return err("Data is not matching hash, number " & $blockData.number)

    let contentKey =
      ContentKey(contentType: blockHeader, blockHeaderKey: contentKeyType)

    let res = (contentKey, blockData.header.hexToSeqByte())
    return ok(res)
  except ValueError as e:
    return err("Invalid hex data, number " & $blockData.number & ": " & e.msg)

iterator headers*(blockData: BlockDataTable, verify = false): (ContentKey, seq[byte]) =
  for k, v in blockData:
    let res = readHeaderData(k, v, verify)

    if res.isOk():
      yield res.get()
    else:
      error "Failed reading header from block data", error = res.error

proc getGenesisHeader*(id: NetworkId = MainNet): Header =
  let params =
    try:
      networkParams(id)
    except ValueError, RlpError:
      debugEcho getCurrentException()[]
      raise (ref Defect)(msg: "Network parameters should be valid")

  toGenesisHeader(params)

# Reading JSON Portal content and content keys

type
  JsonPortalContent* = object
    content_key*: string
    content_value*: string

  JsonPortalContentTable* = OrderedTable[string, JsonPortalContent]

proc toString(v: IoErrorCode): string =
  try:
    ioErrorMsg(v)
  except Exception as e:
    raiseAssert e.msg

proc readJsonType*(dataFile: string, T: type): Result[T, string] =
  let data = ?readAllFile(dataFile).mapErr(toString)

  let decoded =
    try:
      Json.decode(data, T)
    except SerializationError as e:
      return err("Failed decoding json data-file: " & e.msg)

  ok(decoded)

# Writing JSON history data

type
  HeaderRecord* = object
    header: string
    number: uint64

  BlockRecord* = object
    header: string
    body: string
    receipts: string
    number: uint64

proc writeHeaderRecord*(writer: var JsonWriter, header: Header) {.raises: [IOError].} =
  let
    dataRecord =
      HeaderRecord(header: rlp.encode(header).to0xHex(), number: header.number)

    headerHash = to0xHex(computeRlpHash(header).data)

  writer.writeField(headerHash, dataRecord)

proc writeBlockRecord*(
    writer: var JsonWriter, header: Header, body: BlockBody, receipts: seq[Receipt]
) {.raises: [IOError].} =
  let
    dataRecord = BlockRecord(
      header: rlp.encode(header).to0xHex(),
      body: encode(body).to0xHex(),
      receipts: encode(receipts).to0xHex(),
      number: header.number,
    )

    headerHash = to0xHex(computeRlpHash(header).data)

  writer.writeField(headerHash, dataRecord)
