# beacon_chain
# Copyright (c) 2018-Present Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.used.}

import
  # Standard library
  os, strutils,
  # Beacon chain internals
  ../../beacon_chain/spec/[datatypes, state_transition],
  # Test utilities
  ../testutil,
  ./fixtures_utils,
  ../helpers/debug_state

const SanitySlotsDir = SszTestsDir/const_preset/"merge"/"sanity"/"slots"/"pyspec_tests"

proc runTest(identifier: string) =
  let
    testDir = SanitySlotsDir / identifier
    num_slots = readLines(testDir / "slots.yaml", 2)[0].parseInt.uint64

  proc `testImpl _ slots _ identifier`() =
    test "Slots - " & identifier:
      var
        preState = newClone(parseTest(testDir/"pre.ssz", SSZ, BeaconState))
        hashedPreState = (ref HashedBeaconState)(
          data: preState[], root: hash_tree_root(preState[]))
        cache = StateCache()
        rewards: RewardInfo
      let postState = newClone(parseTest(testDir/"post.ssz", SSZ, BeaconState))

      check:
        process_slots(
          hashedPreState[], hashedPreState.data.slot + num_slots, cache, rewards)

        hashedPreState.root == postState[].hash_tree_root()
      let newPreState = newClone(hashedPreState.data)
      reportDiff(newPreState, postState)

  `testImpl _ slots _ identifier`()

suite "Official - Sanity - Slots " & preset():
  for kind, path in walkDir(SanitySlotsDir, true):
    runTest(path)
