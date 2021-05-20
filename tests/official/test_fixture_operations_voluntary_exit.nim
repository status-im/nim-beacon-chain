# beacon_chain
# Copyright (c) 2018-Present Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.used.}

import
  # Standard library
  os,
  # Utilities
  stew/results,
  # Beacon chain internals
  ../../beacon_chain/spec/[datatypes, state_transition_block],
  ../../beacon_chain/ssz,
  # Test utilities
  ../testutil,
  ./fixtures_utils,
  ../helpers/debug_state

const OpVoluntaryExitDir = SszTestsDir/const_preset/"merge"/"operations"/"voluntary_exit"/"pyspec_tests"

proc runTest(identifier: string) =
  # We wrap the tests in a proc to avoid running out of globals
  # in the future: Nim supports up to 3500 globals
  # but unittest with the macro/templates put everything as globals
  # https://github.com/nim-lang/Nim/issues/12084#issue-486866402

  let testDir = OpVoluntaryExitDir / identifier

  proc `testImpl _ voluntary_exit _ identifier`() =

    var prefix: string
    if existsFile(testDir/"post.ssz_snappy"):
      prefix = "[Valid]   "
    else:
      prefix = "[Invalid] "

    test prefix & identifier:
      let voluntaryExit = parseTest(testDir/"voluntary_exit.ssz", SSZ, SignedVoluntaryExit)
      var preState = newClone(parseTest(testDir/"pre.ssz", SSZ, BeaconState))

      var cache = StateCache()

      if existsFile(testDir/"post.ssz_snappy"):
        let postState = newClone(parseTest(testDir/"post.ssz", SSZ, BeaconState))
        let done =
          process_voluntary_exit(preState[], voluntaryExit, {}, cache).isOk
        doAssert done, "Valid voluntary exit not processed"
        check: preState[].hash_tree_root() == postState[].hash_tree_root()
        reportDiff(preState, postState)
      else:
        let done =
          process_voluntary_exit(preState[], voluntaryExit, {}, cache).isOk
        doAssert done == false, "We didn't expect this invalid voluntary exit to be processed."

  `testImpl _ voluntary_exit _ identifier`()

suite "Official - Operations - Voluntary exit " & preset():
  for kind, path in walkDir(OpVoluntaryExitDir, true):
    runTest(path)
