# beacon_chain
# Copyright (c) 2018-2021 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.used.}

import
  # Status lib
  unittest2,
  chronicles, chronos,
  eth/keys,
  # Internal
  ../beacon_chain/[beacon_node_types, extras, beacon_clock],
  ../beacon_chain/gossip_processing/[gossip_validation, batch_validation],
  ../beacon_chain/fork_choice/[fork_choice_types, fork_choice],
  ../beacon_chain/consensus_object_pools/[
    block_quarantine, blockchain_dag, block_clearance, attestation_pool],
  ../beacon_chain/spec/[crypto, datatypes, digest, forkedbeaconstate_helpers,
                        state_transition, helpers, presets, network],
  # Test utilities
  ./testutil, ./testdbutil, ./testblockutil

proc pruneAtFinalization(dag: ChainDAGRef, attPool: AttestationPool) =
  if dag.needStateCachesAndForkChoicePruning():
    dag.pruneStateCachesDAG()
    # pool[].prune() # We test logic without att_1_0 pool / fork choice pruning

suite "Gossip validation " & preset():
  setup:
    # Genesis state that results in 3 members per committee
    var
      dag = init(ChainDAGRef, defaultRuntimePreset, makeTestDB(SLOTS_PER_EPOCH * 3))
      quarantine = QuarantineRef.init(keys.newRng())
      pool = newClone(AttestationPool.init(dag, quarantine))
      state = newClone(dag.headState)
      cache = StateCache()
      rewards = RewardInfo()
      batchCrypto = BatchCrypto.new(keys.newRng(), eager = proc(): bool = false)
    # Slot 0 is a finalized slot - won't be making attestations for it..
    check:
      process_slots(
        state.data, getStateField(state.data, slot) + 1, cache, rewards, {},
        FAR_FUTURE_SLOT)

  test "Validation sanity":
    # TODO: refactor tests to avoid skipping BLS validation
    dag.updateFlags.incl {skipBLSValidation}

    var
      cache: StateCache
    for blck in makeTestBlocks(
        dag.headState.data, dag.head.root, cache,
        int(SLOTS_PER_EPOCH * 5), false):
      let added = dag.addRawBlock(quarantine, blck) do (
          blckRef: BlockRef, signedBlock: TrustedSignedBeaconBlock,
          epochRef: EpochRef, state: HashedBeaconState):
        # Callback add to fork choice if valid
        pool[].addForkChoice(epochRef, blckRef, signedBlock.message, blckRef.slot)

      check: added.isOk()
      dag.updateHead(added[], quarantine)
      pruneAtFinalization(dag, pool[])

    var
      # Create attestations for slot 1
      beacon_committee = get_beacon_committee(
        dag.headState.data, dag.head.slot, 0.CommitteeIndex, cache)
      att_1_0 = makeAttestation(
        dag.headState.data, dag.head.root, beacon_committee[0], cache)
      att_1_1 = makeAttestation(
        dag.headState.data, dag.head.root, beacon_committee[1], cache)

      committees_per_slot =
        get_committee_count_per_slot(dag.headState.data,
          att_1_0.data.slot.epoch, cache)

      subnet = compute_subnet_for_attestation(
        committees_per_slot,
        att_1_0.data.slot, att_1_0.data.index.CommitteeIndex)

      beaconTime = att_1_0.data.slot.toBeaconTime()

    check:
      validateAttestation(pool, batchCrypto, att_1_0, beaconTime, subnet, true).waitFor().isOk

      # Same validator again
      validateAttestation(pool, batchCrypto, att_1_0, beaconTime, subnet, true).waitFor().error()[0] ==
        ValidationResult.Ignore

    pool[].nextAttestationEpoch.setLen(0) # reset for test
    check:
      # Wrong subnet
      validateAttestation(
        pool, batchCrypto, att_1_0, beaconTime, SubnetId(subnet.uint8 + 1), true).waitFor().isErr

    pool[].nextAttestationEpoch.setLen(0) # reset for test
    check:
      # Too far in the future
      validateAttestation(
        pool, batchCrypto, att_1_0, beaconTime - 1.seconds, subnet, true).waitFor().isErr

    pool[].nextAttestationEpoch.setLen(0) # reset for test
    check:
      # Too far in the past
      validateAttestation(
        pool, batchCrypto, att_1_0,
        beaconTime - (SECONDS_PER_SLOT * SLOTS_PER_EPOCH - 1).int.seconds,
        subnet, true).waitFor().isErr

    block:
      var broken = att_1_0
      broken.signature.blob[0] += 1
      pool[].nextAttestationEpoch.setLen(0) # reset for test
      check:
        # Invalid signature
        validateAttestation(
          pool, batchCrypto, broken, beaconTime, subnet, true).waitFor().
            error()[0] == ValidationResult.Reject

    block:
      var broken = att_1_0
      broken.signature.blob[5] += 1
      pool[].nextAttestationEpoch.setLen(0) # reset for test
      # One invalid, one valid (batched)
      let
        fut_1_0 = validateAttestation(
          pool, batchCrypto, broken, beaconTime, subnet, true)
        fut_1_1 = validateAttestation(
          pool, batchCrypto, att_1_1, beaconTime, subnet, true)

      check:
        fut_1_0.waitFor().error()[0] == ValidationResult.Reject
        fut_1_1.waitFor().isOk()

    block:
      var broken = att_1_0
      # This shouldn't deserialize, which is a different way to break it
      broken.signature.blob = default(type broken.signature.blob)
      pool[].nextAttestationEpoch.setLen(0) # reset for test
      # One invalid, one valid (batched)
      let
        fut_1_0 = validateAttestation(
          pool, batchCrypto, broken, beaconTime, subnet, true)
        fut_1_1 = validateAttestation(
          pool, batchCrypto, att_1_1, beaconTime, subnet, true)

      check:
        fut_1_0.waitFor().error()[0] == ValidationResult.Reject
        fut_1_1.waitFor().isOk()
