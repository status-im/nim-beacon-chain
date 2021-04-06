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
  ../../beacon_chain/spec/[datatypes, state_transition_epoch],
  # Test utilities
  ../testutil,
  ./fixtures_utils,
  ./test_fixture_rewards,
  ../helpers/debug_state

from ../../beacon_chain/spec/beaconstate import process_registry_updates
  # XXX: move to state_transition_epoch?

template runSuite(suiteDir, testName: string, transitionProc: untyped{ident}, useCache: static bool): untyped =
  suite "Official - Epoch Processing - " & testName & preset():
    doAssert dirExists(suiteDir)
    for testDir in walkDirRec(suiteDir, yieldFilter = {pcDir}):

      let unitTestName = testDir.rsplit(DirSep, 1)[1]
      test testName & " - " & unitTestName & preset():
        # BeaconState objects are stored on the heap to avoid stack overflow
        var preState = newClone(parseTest(testDir/"pre.ssz", SSZ, BeaconState))
        let postState = newClone(parseTest(testDir/"post.ssz", SSZ, BeaconState))

        when useCache:
          var cache = StateCache()
          transitionProc(preState[], cache)
        else:
          transitionProc(preState[])

        reportDiff(preState, postState)

# Justification & Finalization
# ---------------------------------------------------------------

const JustificationFinalizationDir = SszTestsDir/const_preset/"phase0"/"epoch_processing"/"justification_and_finalization"/"pyspec_tests"

# Rewards & Penalties
# ---------------------------------------------------------------

# in test_fixture_rewards

# Registry updates
# ---------------------------------------------------------------

const RegistryUpdatesDir = SszTestsDir/const_preset/"phase0"/"epoch_processing"/"registry_updates"/"pyspec_tests"
runSuite(RegistryUpdatesDir, "Registry updates",  process_registry_updates, useCache = true)

# Slashings
# ---------------------------------------------------------------

const SlashingsDir = SszTestsDir/const_preset/"phase0"/"epoch_processing"/"slashings"/"pyspec_tests"
runSuite(SlashingsDir, "Slashings",  process_slashings, useCache = false)

# Final updates
# ---------------------------------------------------------------

const FinalUpdatesDir = SszTestsDir/const_preset/"phase0"/"epoch_processing"/"final_updates"/"pyspec_tests"
runSuite(FinalUpdatesDir, "Final updates",  process_final_updates, useCache = false)
