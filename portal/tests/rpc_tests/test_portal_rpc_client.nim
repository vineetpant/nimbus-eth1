# Nimbus - Portal Network
# Copyright (c) 2021-2025 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.used.}

import
  chronos,
  testutils/unittests,
  json_rpc/rpcserver,
  json_rpc/clients/httpclient,
  stint,
  eth/p2p/discoveryv5/enr,
  eth/common/keys,
  eth/common/[headers_rlp, blocks_rlp, receipts_rlp],
  eth/p2p/discoveryv5/protocol as discv5_protocol,
  ../../network/wire/[portal_protocol, portal_stream, portal_protocol_config],
  ../../network/legacy_history/
    [history_network, history_content, history_type_conversions, history_validation],
  ../../database/content_db,
  ../../rpc/[portal_rpc_client, rpc_portal_legacy_history_api],
  ../test_helpers

type HistoryNode = ref object
  discv5*: discv5_protocol.Protocol
  historyNetwork*: LegacyHistoryNetwork

proc newHistoryNode(rng: ref HmacDrbgContext, port: int): HistoryNode =
  let
    node = initDiscoveryNode(rng, PrivateKey.random(rng[]), localAddress(port))
    db = ContentDB.new(
      "", uint32.high, RadiusConfig(kind: Dynamic), node.localNode.id, inMemory = true
    )
    streamManager = StreamManager.new(node)
    historyNetwork = LegacyHistoryNetwork.new(
      PortalNetwork.none,
      node,
      db,
      streamManager,
      RuntimeConfig(),
      FinishedHistoricalHashesAccumulator(),
    )

  return HistoryNode(discv5: node, historyNetwork: historyNetwork)

proc portalProtocol(hn: HistoryNode): PortalProtocol =
  hn.historyNetwork.portalProtocol

proc localNode(hn: HistoryNode): Node =
  hn.discv5.localNode

proc start(hn: HistoryNode) =
  hn.historyNetwork.start()

proc stop(hn: HistoryNode) {.async.} =
  discard hn.historyNetwork.stop()
  await hn.discv5.closeWait()

proc containsId(hn: HistoryNode, contentId: ContentId): bool =
  return hn.historyNetwork.contentDB.contains(contentId)

proc store*(hn: HistoryNode, blockHash: Hash32, blockHeader: Header) =
  let
    headerRlp = rlp.encode(blockHeader)
    blockHeaderWithProof = BlockHeaderWithProof(
      header: ByteList[MAX_HEADER_LENGTH].init(headerRlp),
      proof: ByteList[MAX_HEADER_PROOF_LENGTH].init(@[]),
    )
    contentKeyBytes = blockHeaderContentKey(blockHash).encode()
    contentId = history_content.toContentId(contentKeyBytes)

  hn.portalProtocol().storeContent(
    contentKeyBytes, contentId, SSZ.encode(blockHeaderWithProof)
  )

proc store*(hn: HistoryNode, blockHash: Hash32, blockBody: BlockBody) =
  let
    contentKeyBytes = blockBodyContentKey(blockHash).encode()
    contentId = history_content.toContentId(contentKeyBytes)

  hn.portalProtocol().storeContent(contentKeyBytes, contentId, blockBody.encode())

proc store*(hn: HistoryNode, blockHash: Hash32, receipts: seq[Receipt]) =
  let
    contentKeyBytes = receiptsContentKey(blockHash).encode()
    contentId = history_content.toContentId(contentKeyBytes)

  hn.portalProtocol().storeContent(contentKeyBytes, contentId, receipts.encode())

type TestCase = ref object
  historyNode1: HistoryNode
  historyNode2: HistoryNode
  server: RpcHttpServer
  client: PortalRpcClient

proc setupTest(rng: ref HmacDrbgContext): Future[TestCase] {.async.} =
  let
    localSrvAddress = "127.0.0.1"
    localSrvPort = 0 # let the OS choose a port
    ta = initTAddress(localSrvAddress, localSrvPort)
    client = newRpcHttpClient()
    historyNode1 = newHistoryNode(rng, 20333)
    historyNode2 = newHistoryNode(rng, 20334)

  historyNode1.start()
  historyNode2.start()

  check:
    historyNode1.portalProtocol().addNode(historyNode2.localNode()) == Added
    historyNode2.portalProtocol().addNode(historyNode1.localNode()) == Added

  let rpcHttpServer = RpcHttpServer.new()
  rpcHttpServer.addHttpServer(ta, maxRequestBodySize = 16 * 1024 * 1024)
  rpcHttpServer.installPortalLegacyHistoryApiHandlers(
    historyNode1.historyNetwork.portalProtocol
  )
  rpcHttpServer.start()

  await client.connect(localSrvAddress, rpcHttpServer.localAddress[0].port, false)

  return TestCase(
    historyNode1: historyNode1,
    historyNode2: historyNode2,
    server: rpcHttpServer,
    client: PortalRpcClient.init(client),
  )

proc stop(testCase: TestCase) {.async.} =
  await testCase.server.stop()
  await testCase.server.closeWait()
  await testCase.historyNode1.stop()
  await testCase.historyNode2.stop()

procSuite "Portal RPC Client":
  let rng = newRng()

  asyncTest "Test historyGetBlockHeader with validation":
    let
      tc = await setupTest(rng)
      blockHeader = Header(number: 100)
      blockHash = blockHeader.computeRlpHash()

    # Test content not found
    block:
      let blockHeaderRes =
        await tc.client.historyGetBlockHeader(blockHash, validateContent = true)
      check:
        blockHeaderRes.isErr()
        blockHeaderRes.error() == ContentNotFound

    # Test content found
    block:
      tc.historyNode2.store(blockHash, blockHeader)

      let blockHeaderRes =
        await tc.client.historyGetBlockHeader(blockHash, validateContent = true)
      check:
        blockHeaderRes.isOk()
        blockHeaderRes.value() == blockHeader

    # Test content validation failed
    block:
      tc.historyNode1.store(blockHash, Header()) # bad header

      let blockHeaderRes =
        await tc.client.historyGetBlockHeader(blockHash, validateContent = true)
      check:
        blockHeaderRes.isErr()
        blockHeaderRes.error() == ContentValidationFailed

    waitFor tc.stop()

  asyncTest "Test historyGetBlockHeader without validation":
    let
      tc = await setupTest(rng)
      blockHeader = Header(number: 200)
      blockHash = blockHeader.computeRlpHash()

    # Test content not found
    block:
      let blockHeaderRes =
        await tc.client.historyGetBlockHeader(blockHash, validateContent = false)
      check:
        blockHeaderRes.isErr()
        blockHeaderRes.error() == ContentNotFound

    # Test content found
    block:
      tc.historyNode1.store(blockHash, blockHeader)

      let blockHeaderRes =
        await tc.client.historyGetBlockHeader(blockHash, validateContent = false)
      check:
        blockHeaderRes.isOk()
        blockHeaderRes.value() == blockHeader

    waitFor tc.stop()

  asyncTest "Test historyGetBlockBody with validation":
    let
      tc = await setupTest(rng)
      blockHeader = Header(number: 300)
      blockBody = BlockBody()
      blockHash = blockHeader.computeRlpHash()

    # Test content not found
    block:
      let blockBodyRes =
        await tc.client.historyGetBlockBody(blockHash, validateContent = true)
      check:
        blockBodyRes.isErr()
        blockBodyRes.error() == ContentNotFound

    # Test content validation failed
    block:
      tc.historyNode1.store(blockHash, blockHeader)
      tc.historyNode1.store(blockHash, blockBody)

      let blockBodyRes =
        await tc.client.historyGetBlockBody(blockHash, validateContent = true)
      check:
        blockBodyRes.isErr()
        blockBodyRes.error() == ContentValidationFailed

    waitFor tc.stop()

  asyncTest "Test historyGetBlockBody without validation":
    let
      tc = await setupTest(rng)
      blockHeader = Header(number: 300)
      blockBody = BlockBody()
      blockHash = blockHeader.computeRlpHash()

    # Test content not found
    block:
      let blockBodyRes =
        await tc.client.historyGetBlockBody(blockHash, validateContent = false)
      check:
        blockBodyRes.isErr()
        blockBodyRes.error() == ContentNotFound

    # Test content found
    block:
      tc.historyNode1.store(blockHash, blockHeader)
      tc.historyNode1.store(blockHash, blockBody)

      let blockBodyRes =
        await tc.client.historyGetBlockBody(blockHash, validateContent = false)
      check:
        blockBodyRes.isOk()
        blockBodyRes.value() == blockBody

    waitFor tc.stop()

  asyncTest "Test historyGetReceipts with validation":
    let
      tc = await setupTest(rng)
      blockHeader = Header(number: 300)
      receipts = @[Receipt()]
      blockHash = blockHeader.computeRlpHash()

    # Test content not found
    block:
      let receiptsRes =
        await tc.client.historyGetReceipts(blockHash, validateContent = true)
      check:
        receiptsRes.isErr()
        receiptsRes.error() == ContentNotFound

    # Test content validation failed
    block:
      tc.historyNode1.store(blockHash, blockHeader)
      tc.historyNode1.store(blockHash, receipts)

      let receiptsRes =
        await tc.client.historyGetReceipts(blockHash, validateContent = true)
      check:
        receiptsRes.isErr()
        receiptsRes.error() == ContentValidationFailed

    waitFor tc.stop()

  asyncTest "Test historyGetReceipts without validation":
    let
      tc = await setupTest(rng)
      blockHeader = Header(number: 300)
      receipts = @[Receipt()]
      blockHash = blockHeader.computeRlpHash()

    # Test content not found
    block:
      let receiptsRes =
        await tc.client.historyGetReceipts(blockHash, validateContent = false)
      check:
        receiptsRes.isErr()
        receiptsRes.error() == ContentNotFound

    # Test content found
    block:
      tc.historyNode1.store(blockHash, blockHeader)
      tc.historyNode1.store(blockHash, receipts)

      let receiptsRes =
        await tc.client.historyGetReceipts(blockHash, validateContent = false)
      check:
        receiptsRes.isOk()
        receiptsRes.value() == receipts

    waitFor tc.stop()
