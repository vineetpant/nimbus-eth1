# Nimbus
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.used.}

{.push raises: [].}

import
  unittest2,
  beacon_chain/spec/forks,
  beacon_chain/spec/datatypes/deneb,
  beacon_chain /../ tests/testblockutil,
  # Mock helpers
  beacon_chain /../ tests/mocking/mock_genesis,
  ../../network/legacy_history/validation/block_proof_historical_summaries

suite "History Block Proofs - Historical Summaries - Deneb":
  let
    cfg = block:
      var res = defaultRuntimeConfig
      res.ALTAIR_FORK_EPOCH = GENESIS_EPOCH
      res.BELLATRIX_FORK_EPOCH = GENESIS_EPOCH
      res.CAPELLA_FORK_EPOCH = GENESIS_EPOCH
      res.DENEB_FORK_EPOCH = GENESIS_EPOCH
      res
    state = newClone(initGenesisState(cfg = cfg))
  var cache = StateCache()

  var blocks: seq[deneb.SignedBeaconBlock]

  # Note:
  # Adding 8192*2 blocks. First block is genesis block and not one of these.
  # Then one extra block is needed to get the historical roots, block
  # roots and state roots processed.
  # index i = 0 is second block.
  # index i = 8190 is 8192th block and last one that is part of the first
  # historical root

  # genesis + 8191 slots, next one will be capella fork
  for i in 0 ..< SLOTS_PER_HISTORICAL_ROOT - 1:
    blocks.add(addTestBlock(state[], cache, cfg = cfg).denebData)

  # One more slot to hit second SLOTS_PER_HISTORICAL_ROOT, hitting first
  # historical_summary.
  discard addTestBlock(state[], cache, cfg = cfg)

  # Starts from the block after genesis.
  const blocksToTest = [
    0'u64,
    1,
    2,
    3,
    SLOTS_PER_HISTORICAL_ROOT div 2,
    SLOTS_PER_HISTORICAL_ROOT - 3,
    SLOTS_PER_HISTORICAL_ROOT - 2,
  ]

  test "BeaconBlockProofHistoricalSummaries for BeaconBlock":
    let blockRoots = getStateField(state[], block_roots).data

    withState(state[]):
      when consensusFork >= ConsensusFork.Capella:
        let historical_summaries = forkyState.data.historical_summaries

        # for i in 0..<(SLOTS_PER_HISTORICAL_ROOT - 1): # Test all blocks
        for i in blocksToTest:
          let
            beaconBlock = blocks[i].message
            historicalRootsIndex = getHistoricalSummariesIndex(beaconBlock.slot, cfg)
            blockRootIndex = getBlockRootsIndex(beaconBlock.slot)

          let res = buildProof(blockRoots, blockRootIndex)
          check res.isOk()
          let proof = res.get()

          check verifyProof(
            blocks[i].root,
            proof,
            historical_summaries[historicalRootsIndex].block_summary_root,
            blockRootIndex,
          )

  test "ExecutionBlockProof for Execution BlockHeader":
    # for i in 0..<(SLOTS_PER_HISTORICAL_ROOT - 1): # Test all blocks
    for i in blocksToTest:
      let beaconBlock = blocks[i].message

      let res = block_proof_historical_summaries.buildProof(beaconBlock)
      check res.isOk()
      let proof = res.get()

      let leave = beaconBlock.body.execution_payload.block_hash
      check verifyProof(leave, proof, blocks[i].root)

  test "BlockProofHistoricalSummaries for Execution BlockHeader":
    let blockRoots = getStateField(state[], block_roots).data

    withState(state[]):
      when consensusFork >= ConsensusFork.Capella:
        let historical_summaries = forkyState.data.historical_summaries

        # for i in 0..<(SLOTS_PER_HISTORICAL_ROOT - 1): # Test all blocks
        for i in blocksToTest:
          let
            beaconBlock = blocks[i].message
            # Normally we would have an execution BlockHeader that holds this
            # value, but we skip the creation of that header for now and just take
            # the blockHash from the execution payload.
            blockHash = beaconBlock.body.execution_payload.block_hash

          let proofRes = buildProof(blockRoots, beaconBlock)
          check proofRes.isOk()
          let proof = proofRes.get()

          check verifyProof(historical_summaries, proof, blockHash, cfg)
