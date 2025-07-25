# Nimbus
# Copyright (c) 2021-2025 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  json_serialization,
  chronos,
  stew/byteutils,
  results,
  eth/common/[headers_rlp, blocks_rlp, receipts_rlp],
  json_rpc/rpcclient,
  ../common/common_types,
  ../network/legacy_history/
    [history_content, history_type_conversions, history_validation],
  ./rpc_calls/[rpc_discovery_calls, rpc_portal_calls, rpc_portal_debug_calls]

export rpcclient, rpc_discovery_calls, rpc_portal_calls, rpc_portal_debug_calls, results

type
  PortalRpcClient* = distinct RpcClient

  PortalRpcError* = enum
    ContentNotFound
    InvalidContentKey
    InvalidContentValue
    ContentValidationFailed

  ErrorResponse = object
    code*: int
    message*: string

proc init*(T: type PortalRpcClient, rpcClient: RpcClient): T =
  T(rpcClient)

func toPortalRpcError(e: ref CatchableError): PortalRpcError =
  let error =
    try:
      Json.decode(e.msg, ErrorResponse)
    except SerializationError as e:
      raiseAssert(e.msg)

  if error.code == -39001:
    ContentNotFound
  elif error.code == -32602:
    InvalidContentKey
  else:
    raiseAssert(e.msg)

proc portal_historyGetContent(
    client: PortalRpcClient, contentKey: string
): Future[Result[string, PortalRpcError]] {.async: (raises: []).} =
  try:
    let contentInfo = await RpcClient(client).portal_historyGetContent(contentKey)
    ok(contentInfo.content)
  except CatchableError as e:
    err(e.toPortalRpcError())

template toBytes(content: string): seq[byte] =
  try:
    hexToSeqByte(content)
  except ValueError as e:
    raiseAssert(e.msg)

template valueOrErr[T](res: Result[T, string], error: PortalRpcError): auto =
  if res.isOk():
    ok(res.value)
  else:
    err(error)

proc historyGetBlockHeader*(
    client: PortalRpcClient, blockHash: Hash32, validateContent = true
): Future[Result[Header, PortalRpcError]] {.async: (raises: []).} =
  ## Fetches the block header for the given hash from the Portal History Network.
  ## The data is first looked up in the node's local database before trying to
  ## fetch it from the network.
  ##
  ## Note: This does not validate that the returned header is part of the canonical
  ## chain, it only validates that the header matches the block hash. For example,
  ## a malicious portal node could return a valid but non-canonical header such
  ## as an uncle block that matches the block hash. For this reason the caller
  ## needs to use another method to verify the header is part of the canonical chain.

  let
    contentKey = blockHeaderContentKey(blockHash).encode().asSeq().to0xHex()
    content = ?await client.portal_historyGetContent(contentKey)
    headerWithProof = decodeSsz(content.toBytes(), BlockHeaderWithProof).valueOr:
      return err(InvalidContentValue)
    headerBytes = headerWithProof.header.asSeq()

  if validateContent:
    validateHeaderBytes(headerBytes, blockHash).valueOrErr(ContentValidationFailed)
  else:
    decodeRlp(headerBytes, Header).valueOrErr(InvalidContentValue)

proc historyGetBlockBody*(
    client: PortalRpcClient, blockHash: Hash32, validateContent = true
): Future[Result[BlockBody, PortalRpcError]] {.async: (raises: []).} =
  ## Fetches the block body for the given block hash from the Portal History
  ## Network. The data is first looked up in the node's local database before
  ## trying to fetch it from the network. If validateContent is true, the
  ## block header is fetched first in order to run the content validation.

  let
    contentKey = blockBodyContentKey(blockHash).encode().asSeq().to0xHex()
    content = ?await client.portal_historyGetContent(contentKey)

  if validateContent:
    let blockHeader = ?await client.historyGetBlockHeader(blockHash)
    validateBlockBodyBytes(content.toBytes(), blockHeader).valueOrErr(
      ContentValidationFailed
    )
  else:
    fromPortalBlockBodyBytes(content.toBytes()).valueOrErr(InvalidContentValue)

proc historyGetReceipts*(
    client: PortalRpcClient, blockHash: Hash32, validateContent = true
): Future[Result[seq[Receipt], PortalRpcError]] {.async: (raises: []).} =
  ## Fetches the receipts for the given block hash from the Portal History
  ## Network. The data is first looked up in the node's local database before
  ## trying to fetch it from the network. If validateContent is true, the
  ## block header is fetched first in order to run the content validation.

  let
    contentKey = receiptsContentKey(blockHash).encode().asSeq().to0xHex()
    content = ?await client.portal_historyGetContent(contentKey)

  if validateContent:
    let blockHeader = ?await client.historyGetBlockHeader(blockHash)
    validateReceiptsBytes(content.toBytes(), blockHeader.receiptsRoot).valueOrErr(
      ContentValidationFailed
    )
  else:
    let receipts = decodeSsz(content.toBytes(), PortalReceipts).valueOr:
      return err(InvalidContentValue)
    seq[Receipt].fromPortalReceipts(receipts).valueOrErr(InvalidContentValue)
