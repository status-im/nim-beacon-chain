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

const JustificationFinalizationDir = SszTestsDir/const_preset/"merge"/"epoch_processing"/"justification_and_finalization"/"pyspec_tests"
runSuite(JustificationFinalizationDir, "Justification & Finalization",  process_justification_and_finalization, useCache = false)

# Rewards & Penalties
# ---------------------------------------------------------------

# in test_fixture_rewards

# Registry updates
# ---------------------------------------------------------------

const RegistryUpdatesDir = SszTestsDir/const_preset/"merge"/"epoch_processing"/"registry_updates"/"pyspec_tests"
runSuite(RegistryUpdatesDir, "Registry updates",  process_registry_updates, useCache = true)

# Slashings
# ---------------------------------------------------------------

const SlashingsDir = SszTestsDir/const_preset/"merge"/"epoch_processing"/"slashings"/"pyspec_tests"
runSuite(SlashingsDir, "Slashings",  process_slashings, useCache = false)

# Final updates
# ---------------------------------------------------------------

const Eth1DataResetDir = SszTestsDir/const_preset/"merge"/"epoch_processing"/"eth1_data_reset/"/"pyspec_tests"
runSuite(Eth1DataResetDir, "Eth1 data reset", process_eth1_data_reset, useCache = false)

const EffectiveBalanceUpdatesDir = SszTestsDir/const_preset/"merge"/"epoch_processing"/"effective_balance_updates"/"pyspec_tests"
runSuite(EffectiveBalanceUpdatesDir, "Effective balance updates", process_effective_balance_updates, useCache = false)

const SlashingsResetDir = SszTestsDir/const_preset/"merge"/"epoch_processing"/"slashings_reset"/"pyspec_tests"
runSuite(SlashingsResetDir, "Slashings reset", process_slashings_reset, useCache = false)

const RandaoMixesResetDir = SszTestsDir/const_preset/"merge"/"epoch_processing"/"randao_mixes_reset"/"pyspec_tests"
runSuite(RandaoMixesResetDir, "RANDAO mixes reset", process_randao_mixes_reset, useCache = false)

const HistoricalRootsUpdateDir = SszTestsDir/const_preset/"merge"/"epoch_processing"/"historical_roots_update"/"pyspec_tests"
runSuite(HistoricalRootsUpdateDir, "Historical roots update", process_historical_roots_update, useCache = false)

const ParticipationRecordsDir = SszTestsDir/const_preset/"merge"/"epoch_processing"/"participation_record_updates"/"pyspec_tests"
runSuite(ParticipationRecordsDir, "Participation record updates", process_participation_record_updates, useCache = false)
