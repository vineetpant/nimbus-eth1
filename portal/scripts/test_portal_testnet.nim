# Nimbus
# Copyright (c) 2021-2025 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  os,
  std/sequtils,
  unittest2,
  testutils,
  confutils,
  chronos,
  stew/byteutils,
  eth/p2p/discoveryv5/random2,
  eth/common/keys,
  ../common/common_types,
  ../rpc/portal_rpc_client,
  ../rpc/eth_rpc_client,
  ../eth_data/[history_data_seeding, history_data_json_store, history_data_ssz_e2s],
  ../network/legacy_history/
    [history_content, validation/block_proof_historical_hashes_accumulator],
  ../tests/legacy_history_network_tests/test_history_util

type
  FutureCallback[A] = proc(): Future[A] {.gcsafe, raises: [].}

  CheckCallback[A] = proc(a: A): bool {.gcsafe, raises: [].}

  PortalTestnetConf* = object
    nodeCount* {.defaultValue: 17, desc: "Number of nodes to test", name: "node-count".}:
      int

    rpcAddress* {.
      desc: "Listening address of the JSON-RPC service for all nodes",
      defaultValue: "127.0.0.1",
      name: "rpc-address"
    .}: string

    baseRpcPort* {.
      defaultValue: 10000,
      desc: "Port of the JSON-RPC service of the bootstrap (first) node",
      name: "base-rpc-port"
    .}: uint16

proc connectToRpcServers(config: PortalTestnetConf): Future[seq[RpcClient]] {.async.} =
  var clients: seq[RpcClient]
  for i in 0 ..< config.nodeCount:
    let client = newRpcHttpClient()
    await client.connect(config.rpcAddress, Port(config.baseRpcPort + uint16(i)), false)
    clients.add(client)

  return clients

proc withRetries[A](
    f: FutureCallback[A],
    check: CheckCallback[A],
    numRetries: int,
    initialWait: Duration,
    checkFailMessage: string,
    nodeIdx: int,
): Future[A] {.async.} =
  ## Retries given future callback until either:
  ## it returns successfuly and given check is true
  ## or
  ## function reaches max specified retries

  var tries = 0
  var currentDuration = initialWait

  while true:
    try:
      let res = await f()
      if check(res):
        return res
      else:
        raise newException(ValueError, checkFailMessage)
    except CatchableError as exc:
      if tries > numRetries:
        # if we reached max number of retries fail
        let msg =
          "Call failed with msg: " & exc.msg & ", for node with idx: " & $nodeIdx &
          ", after " & $tries & " tries."
        raise newException(ValueError, msg)

    inc tries
    # wait before new retry
    await sleepAsync(currentDuration)
    currentDuration = currentDuration * 2

# Sometimes we need to wait till data will be propagated over the network.
# To avoid long sleeps, this combinator can be used to retry some calls until
# success or until some condition hold (or both)
proc retryUntil[A](
    f: FutureCallback[A], c: CheckCallback[A], checkFailMessage: string, nodeIdx: int
): Future[A] =
  # some reasonable limits, which will cause waits as: 1, 2, 4, 8, 16, 32 seconds
  return withRetries(f, c, 3, seconds(1), checkFailMessage, nodeIdx)

# Note:
# When doing json-rpc requests following `RpcPostError` can occur:
# "Failed to send POST Request with JSON-RPC." when a `HttpClientRequestRef`
# POST request is send in the json-rpc http client.
# This error is raised when the httpclient hits error:
# "Could not send request headers", which in its turn is caused by the
# "Incomplete data sent or received" in `AsyncStream`, which is caused by
# `ECONNRESET` or `EPIPE` error (see `isConnResetError()`) on the TCP stream.
# This can occur when the server side closes the connection, which happens after
# a `httpHeadersTimeout` of default 10 seconds (set on `HttpServerRef.new()`).
# In order to avoid here hitting this timeout a `close()` is done after each
# json-rpc call. Because the first json-rpc call opens up the connection, and it
# remains open until a close() (or timeout). No need to do another connect
# before any new call as the proc `connectToRpcServers` doesn't actually connect
# to servers, as client.connect doesn't do that. It just sets the `httpAddress`.
# Yes, this client json rpc API couldn't be more confusing.
# Could also just retry each call on failure, which would set up a new
# connection.

# We are kind of abusing the unittest2 here to run json rpc tests against other
# processes. Needs to be compiled with `-d:unittest2DisableParamFiltering` or
# the confutils cli will not work.
procSuite "Portal testnet tests":
  let config = PortalTestnetConf.load()
  let rng = newRng()

  asyncTest "Discv5 - Random node lookup from each node":
    let clients = await connectToRpcServers(config)

    var nodeInfos: seq[NodeInfo]
    for client in clients:
      let nodeInfo = await client.discv5_nodeInfo()
      await client.close()
      nodeInfos.add(nodeInfo)

    # Kick off the network by trying to add all records to each node.
    # These nodes are also set as seen, so they get passed along on findNode
    # requests.
    # Note: The amount of Records added here can be less but then the
    # probability that all nodes will still be reached needs to be calculated.
    # Note 2: One could also ping all nodes but that is much slower and more
    # error prone
    for client in clients:
      discard await client.discv5_addEnrs(
        nodeInfos.map(
          proc(x: NodeInfo): Record =
            x.enr
        )
      )
      await client.close()

    for client in clients:
      let routingTableInfo = await client.discv5_routingTableInfo()
      await client.close()
      var start: seq[NodeId]
      let nodes = foldl(routingTableInfo.buckets, a & b, start)
      # A node will have at least the first bucket filled. One could increase
      # this based on the probability that x amount of nodes fit in the buckets.
      check nodes.len >= (min(config.nodeCount - 1, 16))

    # grab a random node its `NodeInfo` and lookup that node from all nodes.
    let randomNodeInfo = sample(rng[], nodeInfos)
    for client in clients:
      var enr: Record
      enr = await client.discv5_lookupEnr(randomNodeInfo.nodeId)
      check enr == randomNodeInfo.enr
      await client.close()

  asyncTest "Portal History - Random node lookup from each node":
    let clients = await connectToRpcServers(config)

    var nodeInfos: seq[NodeInfo]
    for client in clients:
      let nodeInfo = await client.portal_historyNodeInfo()
      await client.close()
      nodeInfos.add(nodeInfo)

    for client in clients:
      discard await client.portal_historyAddEnrs(
        nodeInfos.map(
          proc(x: NodeInfo): Record =
            x.enr
        )
      )
      await client.close()

    for client in clients:
      let routingTableInfo = await client.portal_historyRoutingTableInfo()
      await client.close()
      var start: seq[NodeId]
      let nodes = foldl(routingTableInfo.buckets, a & b, start)
      check nodes.len >= (min(config.nodeCount - 1, 16))

    # grab a random node its `NodeInfo` and lookup that node from all nodes.
    let randomNodeInfo = sample(rng[], nodeInfos)
    for client in clients:
      var enr: Record
      enr = await client.portal_historyLookupEnr(randomNodeInfo.nodeId)
      await client.close()
      check enr == randomNodeInfo.enr

  asyncTest "Portal History - Propagate blocks and do content lookups":
    const
      headerFile =
        "./vendor/portal-spec-tests/tests/mainnet/history/headers/1000001-1000010.e2s"
      accumulatorFile =
        "./vendor/portal-spec-tests/tests/mainnet/history/accumulator/epoch-record-00122.ssz"
      blockDataFile = "./portal/tests/blocks/mainnet_blocks_1000001_1000010.json"

    let
      blockHeaders = readBlockHeaders(headerFile).valueOr:
        raiseAssert "Invalid header file: " & headerFile
      epochRecord = readEpochRecordCached(accumulatorFile).valueOr:
        raiseAssert "Invalid epoch accumulator file: " & accumulatorFile
      blockHeadersWithProof = buildHeadersWithProof(blockHeaders, epochRecord).valueOr:
        raiseAssert "Could not build headers with proof"
      blockData = readJsonType(blockDataFile, BlockDataTable).valueOr:
        raiseAssert "Invalid block data file" & blockDataFile

      clients = await connectToRpcServers(config)

    # Gossiping all block headers with proof first, as bodies and receipts
    # require them for validation.
    for (contentKey, contentValue) in blockHeadersWithProof:
      discard (
        await clients[0].portal_historyPutContent(
          contentKey.toHex(), contentValue.toHex()
        )
      )

    # TODO: Fix iteration order: Because the blockData gets parsed into a
    # BlockDataTable, iterating over this result in gossiping the block bodies
    # and receipts of block in a different order than the headers.
    # Because of this, block bodies and receipts for block
    # 0x6251d65b8a8668efabe2f89c96a5b6332d83b3bbe585089ea6b2ab9b6754f5e9
    # come right after the headers with proof. This is likely to cause validation
    # failures on the nodes, as the block bodies and receipts require the header
    # to get validated.
    await sleepAsync(seconds(1))

    # Gossiping all block bodies and receipts.
    for b in blocks(blockData, false):
      for i, value in b:
        if i == 0:
          # Note: Skipping the headers, they are handled above already
          continue
        # Only sending non empty data, e.g. empty receipts are not send
        # TODO: Could do a similar thing for a combination of empty
        # txs and empty uncles, as then the serialization is always the same.
        if value[1].len() > 0:
          let
            contentKey = history_content.encode(value[0]).asSeq().toHex()
            contentValue = value[1].toHex()

          discard (await clients[0].portal_historyPutContent(contentKey, contentValue))

    await clients[0].close()

    for i, client in clients:
      # Note: Once there is the Canonical Indices Network, we don't need to
      # access this file anymore here for the block hashes.
      for hash in blockData.blockHashes():
        # Note: More flexible approach instead of generic retries could be to
        # add a json-rpc debug proc that returns whether the offer queue is empty or
        # not. And then poll every node until all nodes have an empty queue.
        let content = await retryUntil(
          proc(): Future[Opt[BlockObject]] {.async.} =
            try:
              let res = await client.eth_getBlockByHash(hash, true)
              await client.close()
              return res
            except CatchableError as exc:
              await client.close()
              raise exc,
          proc(mc: Opt[BlockObject]): bool =
            return mc.isSome(),
          "Did not receive expected Block with hash " & hash.data.toHex(),
          i,
        )
        check content.isSome()
        let blockObj = content.get()
        check blockObj.hash == hash

        for tx in blockObj.transactions:
          doAssert(tx.kind == tohTx)
          check tx.tx.blockHash.get == hash

        let filterOptions = FilterOptions(blockHash: Opt.some(hash))

        let logs = await retryUntil(
          proc(): Future[seq[LogObject]] {.async.} =
            try:
              let res = await client.eth_getLogs(filterOptions)
              await client.close()
              return res
            except CatchableError as exc:
              await client.close()
              raise exc,
          proc(mc: seq[LogObject]): bool =
            return true,
          "",
          i,
        )

        for l in logs:
          check:
            l.blockHash == Opt.some(hash)

        # TODO: Check ommersHash, need the headers and not just the hashes
        # for uncle in blockObj.uncles:
        #   discard

      await client.close()
