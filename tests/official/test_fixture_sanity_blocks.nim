# beacon_chain
# Copyright (c) 2018-Present Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at http://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at http://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  # Standard library
  os, unittest, strutils,
  # Beacon chain internals
  ../../beacon_chain/spec/[datatypes],
  ../../beacon_chain/[ssz, state_transition, extras],
  # Test utilities
  ../testutil,
  ./fixtures_utils,
  ../helpers/debug_state,
  ../mocking/mock_blocks

const SanityBlocksDir = SszTestsDir/const_preset/"phase0"/"sanity"/"blocks"/"pyspec_tests"

template runValidTest(testName: string, identifier: untyped, num_blocks: int): untyped =
  # We wrap the tests in a proc to avoid running out of globals
  # in the future: Nim supports up to 3500 globals
  # but unittest with the macro/templates put everything as globals
  # https://github.com/nim-lang/Nim/issues/12084#issue-486866402

  const testDir = SanityBlocksDir / astToStr(identifier)

  proc `testImpl _ blck _ identifier`() =
    test "[Valid]   " & testName & " (" & astToStr(identifier) & ")":
      var stateRef, postRef: ref BeaconState
      new stateRef
      new postRef
      stateRef[] = parseTest(testDir/"pre.ssz", SSZ, BeaconState)
      postRef[] = parseTest(testDir/"post.ssz", SSZ, BeaconState)

      var success = true
      for i in 0 ..< num_blocks:
        let blck = parseTest(testDir/"blocks_" & $i & ".ssz", SSZ, BeaconBlock)

        # TODO: The EF is using invalid BLS keys so we can't verify them
        let success = state_transition(stateRef[], blck, flags = {skipValidation})
        doAssert success, "Failure when applying block " & $i

      # Checks:
      # check: stateRef.hash_tree_root() == postRef.hash_tree_root()
      reportDiff(stateRef, postRef)

  `testImpl _ blck _ identifier`()

suite "Official - Sanity - Blocks " & preset():
  test "[Invalid] Previous slot block transition (prev_slot_block_transition)":
    const testDir = SanityBlocksDir/"prev_slot_block_transition"
    var stateRef: ref BeaconState
    new stateRef
    stateRef[] = parseTest(testDir/"pre.ssz", SSZ, BeaconState)

    let blck = parseTest(testDir/"blocks_0.ssz", SSZ, BeaconBlock)

    # Check that a block build for an old slot cannot be used for state transition
    expect(AssertionError):
      # assert in process_slots. This should not be triggered
      #                          for blocks from block_pool/network
      let done = state_transition(stateRef[], blck, flags = {skipValidation})

  runValidTest("Same slot block transition", same_slot_block_transition, 1)
  runValidTest("Empty block transition", empty_block_transition, 1)

  when false: # TODO: we need more granular skipValidation
    test "[Invalid] Invalid state root":
      const testDir = SanityBlocksDir/"invalid_state_root"
      var stateRef: ref BeaconState
      new stateRef
      stateRef[] = parseTest(testDir/"pre.ssz", SSZ, BeaconState)

      let blck = parseTest(testDir/"blocks_0.ssz", SSZ, BeaconBlock)

      expect(AssertionError):
        let done = state_transition(stateRef[], blck, flags = {skipValidation})

  runValidTest("Skipped Slots", skipped_slots, 1)
  when false: # TODO: failing due to state_roots[8]
    runValidTest("Empty epoch transition", empty_epoch_transition, 1)
    runValidTest("Empty epoch transition not finalizing", empty_epoch_transition_not_finalizing, 1)
  runValidTest("Proposer slashing", proposer_slashing, 1)
  when false: # TODO: Assert spec/crypto.nim(156, 12) `x.kind == Real and other.kind == Real`
    runValidTest("Attester slashing", attester_slashing, 1)

  # TODO: Expected deposit in block

  when false: # TODO: Assert .spec/crypto.nim(175, 14) `sig.kind == Real and pubkey.kind == Real`
    runValidTest("Deposit in block", deposit_in_block, 1)
  runValidTest("Deposit top up", deposit_top_up, 1)

  when false: # TODO: Assert spec/crypto.nim(156, 12) `x.kind == Real and other.kind == Real`
    runValidTest("Attestation", attestation, 2)
  when false: # TODO: failing due to state_roots[8]
    runValidTest("Voluntary exit", voluntary_exit, 2)
    runValidTest("Balance-driven status transitions", balance_driven_status_transitions, 1)

  runValidTest("Historical batch", historical_batch, 1)

  when false: # TODO: `stateRef3870603.block_roots[idx3874628] == postRef3870605.block_roots[idx3874628]`
              #       stateRef3856003.block_roots[16] = 06013007F8A1D4E310344192C5DF6157B1F9F0F5B3A8404103ED822DF47CD85D
              #       postRef3856005.block_roots[16] = 73F47FF01C106CC82BF839C953C4171E019A22590D762076306F4CEE1CB77583
    runValidTest("ETH1 data votes consensus", eth1_data_votes_consensus, 17)
    runValidTest("ETH1 data votes no consensus", eth1_data_votes_no_consensus, 16)
