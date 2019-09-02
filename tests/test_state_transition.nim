# beacon_chain
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at http://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at http://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  options, sequtils, unittest, chronicles,
  ./testutil,
  ../beacon_chain/spec/[beaconstate, crypto, datatypes, digest, helpers, validator],
  ../beacon_chain/[extras, state_transition, ssz]

suite "Block processing" & preset():
  ## For now just test that we can compile and execute block processing with
  ## mock data.

  let
    # Genesis state with minimal number of deposits
    # TODO bls verification is a bit of a bottleneck here
    genesisState = initialize_beacon_state_from_eth1(
      Eth2Digest(), 0,
      makeInitialDeposits(), {})
    genesisBlock = get_initial_beacon_block(genesisState)
    genesisRoot = signing_root(genesisBlock)

  test "Passes from genesis state, no block" & preset():
    var
      state = genesisState

    process_slots(state, state.slot + 1)
    check:
      state.slot == genesisState.slot + 1

  test "Passes from genesis state, empty block" & preset():
    var
      state = genesisState
      previous_block_root = signing_root(genesisBlock)
      new_block = makeBlock(state, previous_block_root, BeaconBlockBody())

    let block_ok = state_transition(state, new_block, {})

    check:
      block_ok

      state.slot == genesisState.slot + 1

  test "Passes through epoch update, no block" & preset():
    var
      state = genesisState

    process_slots(state, Slot(SLOTS_PER_EPOCH))

    check:
      state.slot == genesisState.slot + SLOTS_PER_EPOCH

  test "Passes through epoch update, empty block" & preset():
    var
      state = genesisState
      previous_block_root = genesisRoot

    for i in 1..SLOTS_PER_EPOCH.int:
      var new_block = makeBlock(state, previous_block_root, BeaconBlockBody())

      let block_ok = state_transition(state, new_block, {})

      check:
        block_ok

      previous_block_root = signing_root(new_block)

    check:
      state.slot == genesisState.slot + SLOTS_PER_EPOCH

  test "Attestation gets processed at epoch" & preset():
    var
      state = genesisState
      previous_block_root = genesisRoot
      cache = get_empty_per_epoch_cache()

    # Slot 0 is a finalized slot - won't be making attestations for it..
    process_slots(state, state.slot + 1)

    let
      # Create an attestation for slot 1 signed by the only attester we have!
      crosslink_committee =
        get_crosslink_committee(state, compute_epoch_of_slot(state.slot), 0, cache)
      attestation = makeAttestation(
        state, previous_block_root, crosslink_committee[0])

    # Some time needs to pass before attestations are included - this is
    # to let the attestation propagate properly to interested participants
    process_slots(state, GENESIS_SLOT + MIN_ATTESTATION_INCLUSION_DELAY + 1)

    let
      new_block = makeBlock(state, previous_block_root, BeaconBlockBody(
        attestations: @[attestation]
      ))
    discard state_transition(state, new_block, {})

    check:
      # TODO epoch attestations can get multiplied now; clean up paths to
      # enable exact 1-check again and keep finalization.
      state.current_epoch_attestations.len >= 1

    process_slots(state, Slot(191))

    # Would need to process more epochs for the attestation to be removed from
    # the state! (per above bug)
    #
    # check:
    #  state.latest_attestations.len == 0
