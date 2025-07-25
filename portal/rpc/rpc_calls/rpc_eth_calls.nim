# Nimbus
# Copyright (c) 2021-2025 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import
  std/json,
  stint,
  json_serialization/stew/results,
  json_rpc/[client, jsonmarshal],
  web3/conversions,
  web3/eth_api_types

export eth_api_types

createRpcSigsFromNim(RpcClient):
  proc web3_clientVersion(): string
  proc eth_chainId(): UInt256
  proc eth_getBlockByHash(data: Hash32, fullTransactions: bool): Opt[BlockObject]
  proc eth_getBlockByNumber(
    blockId: BlockIdentifier, fullTransactions: bool
  ): Opt[BlockObject]

  proc eth_getUncleByBlockNumberAndIndex(
    blockId: BlockIdentifier, quantity: Quantity
  ): BlockObject

  proc eth_getBlockTransactionCountByHash(data: Hash32): Quantity
  proc eth_getTransactionReceipt(data: Hash32): Opt[ReceiptObject]
  proc eth_getLogs(filterOptions: FilterOptions): seq[LogObject]

  proc eth_getBlockReceipts(blockId: string): Opt[seq[ReceiptObject]]
  proc eth_getBlockReceipts(blockId: Quantity): Opt[seq[ReceiptObject]]
  proc eth_getBlockReceipts(blockId: RtBlockIdentifier): Opt[seq[ReceiptObject]]
