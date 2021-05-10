# beacon_chain
# Copyright (c) 2018-Present Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.used.}

import
  # Standard library
  os, sequtils, chronicles,
  # Beacon chain internals
  ../../beacon_chain/spec/[crypto, datatypes, state_transition, presets],
  ../../beacon_chain/ssz,
  # Test utilities
  ../testutil,
  ./fixtures_utils

const
  FinalityDir = SszTestsDir/const_preset/"merge"/"finality"/"finality"/"pyspec_tests"
  SanityBlocksDir = SszTestsDir/const_preset/"merge"/"sanity"/"blocks"/"pyspec_tests"

proc runTest(testName, testDir, unitTestName: string) =
  # We wrap the tests in a proc to avoid running out of globals
  # in the future: Nim supports up to 3500 globals
  # but unittest with the macro/templates put everything as globals
  # https://github.com/nim-lang/Nim/issues/12084#issue-486866402

  let testPath = testDir / unitTestName

  proc `testImpl _ blck _ testName`() =
    let
      hasPostState = existsFile(testPath/"post.ssz_snappy")
      prefix = if hasPostState: "[Valid]   " else: "[Invalid] "

    test prefix & testName & " - " & unitTestName & preset():
      var
        preState = newClone(parseTest(testPath/"pre.ssz", SSZ, BeaconState))
        hashedPreState = (ref HashedBeaconState)(
          data: preState[], root: hash_tree_root(preState[]))
        cache = StateCache()
        rewards = RewardInfo()

      # In test cases with more than 10 blocks the first 10 aren't 0-prefixed,
      # so purely lexicographic sorting wouldn't sort properly.
      let numBlocks = toSeq(walkPattern(testPath/"blocks_*.ssz_snappy")).len
      for i in 0 ..< numBlocks:
        let blck = parseTest(testPath/"blocks_" & $i & ".ssz", SSZ, SignedBeaconBlock)

        if hasPostState:
          let success = state_transition(
            defaultRuntimePreset, hashedPreState[], blck, cache, rewards, flags = {},
            noRollback)
          doAssert success, "Failure when applying block " & $i
        else:
          let success = state_transition(
            defaultRuntimePreset, hashedPreState[], blck, cache, rewards, flags = {},
            noRollback)
          doAssert (i + 1 < numBlocks) or not success,
            "We didn't expect these invalid blocks to be processed"

      if hasPostState:
        let postState = newClone(parseTest(testPath/"post.ssz", SSZ, BeaconState))
        when false:
          reportDiff(hashedPreState.data, postState)
        doAssert hashedPreState.root == postState[].hash_tree_root()

  `testImpl _ blck _ testName`()

suite "Official - Sanity - Blocks " & preset():
  for kind, path in walkDir(SanityBlocksDir, true):
    runTest("Official - Sanity - Blocks", SanityBlocksDir, path)

suite "Official - Finality " & preset():
  for kind, path in walkDir(FinalityDir, true):
    runTest("Official - Finality", FinalityDir, path)
