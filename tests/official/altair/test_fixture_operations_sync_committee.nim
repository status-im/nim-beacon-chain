# beacon_chain
# Copyright (c) 2018-Present Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.used.}

import
  # Standard library
  std/os,
  # Utilities
  stew/results, ssz_serialization,
  # Beacon chain internals
  ../../../beacon_chain/spec/state_transition_block,
  ../../../beacon_chain/spec/datatypes/altair,
  # Test utilities
  ../../testutil,
  ../fixtures_utils,
  ../../helpers/debug_state

when isMainModule:
  import chronicles # or some random compile error happens...

const OpSyncCommitteeDir = SszTestsDir/const_preset/"altair"/"operations"/"sync_committee"/"pyspec_tests"

proc runTest(identifier: string) =
  # We wrap the tests in a proc to avoid running out of globals
  # in the future: Nim supports up to 3500 globals
  # but unittest with the macro/templates put everything as globals
  # https://github.com/nim-lang/Nim/issues/12084#issue-486866402

  let testDir = OpSyncCommitteeDir / identifier

  proc `testImpl_sync_committee _ identifier`() =

    var prefix: string
    if existsFile(testDir/"post.ssz_snappy"):
      prefix = "[Valid]   "
    else:
      prefix = "[Invalid] "

    test prefix & identifier:
      let syncAggregate = parseTest(
        testDir/"sync_aggregate.ssz_snappy", SSZ, SyncAggregate)
      var
        preState =
          newClone(parseTest(testDir/"pre.ssz_snappy", SSZ, BeaconState))
        cache = StateCache()

      if existsFile(testDir/"post.ssz_snappy"):
        let
          postState =
            newClone(parseTest(testDir/"post.ssz_snappy", SSZ, BeaconState))
          done = process_sync_committee(
            preState[], syncAggregate, cache).isOk
        doAssert done, "Valid sync aggregate not processed"
        check: preState[].hash_tree_root() == postState[].hash_tree_root()
        reportDiff(preState, postState)
      else:
        let done = process_sync_committee(preState[], syncAggregate, cache).isOk
        doAssert done == false, "We didn't expect this invalid proposer slashing to be processed."

  `testImpl_sync_committee _ identifier`()

suite "Official - Altair - Operations - Sync Committee " & preset():
  for kind, path in walkDir(OpSyncCommitteeDir, true):
    runTest(path)
