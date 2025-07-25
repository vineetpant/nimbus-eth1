# Nimbus
# Copyright (c) 2024-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import
  std/sequtils,
  chronos,
  chronicles,
  ./networking/p2p,
  metrics/chronos_httpserver,
  ./rpc/rpc_server,
  ./core/chain,
  ./core/tx_pool,
  ./sync/peers,
  ./sync/beacon as beacon_sync,
  ./sync/wire_protocol,
  ./beacon/beacon_engine,
  ./common,
  ./config

export
  chronos,
  p2p,
  chronos_httpserver,
  rpc_server,
  chain,
  tx_pool,
  peers,
  beacon_sync,
  beacon_engine,
  common,
  config

{.push raises: [].}

type
  NimbusState* = enum
    Starting, Running, Stopping

  NimbusNode* = ref object
    httpServer*: NimbusHttpServerRef
    engineApiServer*: NimbusHttpServerRef
    ethNode*: EthereumNode
    state*: NimbusState
    ctx*: EthContext
    fc*: ForkedChainRef
    txPool*: TxPoolRef
    peerManager*: PeerManagerRef
    beaconSyncRef*: BeaconSyncRef
    beaconEngine*: BeaconEngineRef
    metricsServer*: MetricsHttpServerRef
    wire*: EthWireRef

proc closeWait*(nimbus: NimbusNode) {.async.} =
  trace "Graceful shutdown"
  var waitedFutures: seq[Future[void]]
  if nimbus.httpServer.isNil.not:
    waitedFutures.add nimbus.httpServer.stop()
  if nimbus.engineApiServer.isNil.not:
    waitedFutures.add nimbus.engineApiServer.stop()
  if nimbus.ethNode.isNil.not:
    waitedFutures.add nimbus.ethNode.closeWait()
  if nimbus.peerManager.isNil.not:
    waitedFutures.add nimbus.peerManager.stop()
  if nimbus.beaconSyncRef.isNil.not:
    waitedFutures.add nimbus.beaconSyncRef.stop()
  if nimbus.metricsServer.isNil.not:
    waitedFutures.add nimbus.metricsServer.stop()
  if nimbus.wire.isNil.not:
    waitedFutures.add nimbus.wire.stop()

  waitedFutures.add nimbus.fc.stopProcessingQueue()

  let
    timeout = chronos.seconds(5)
    completed = await withTimeout(allFutures(waitedFutures), timeout)
  if not completed:
    trace "Nimbus.stop(): timeout reached", timeout,
      futureErrors = waitedFutures.filterIt(it.error != nil).mapIt(it.error.msg)

{.pop.}
