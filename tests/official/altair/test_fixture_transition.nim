# beacon_chain
# Copyright (c) 2021-Present Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.used.}

import
  yaml,
  # Standard library
  os, sequtils,
  # Status internal
  faststreams, streams,
  # Beacon chain internals
  ../../../beacon_chain/spec/[
    crypto, state_transition, presets, forkedbeaconstate_helpers, helpers],
  ../../../beacon_chain/spec/datatypes/[phase0, altair],
  ../../../beacon_chain/[extras, ssz],
  # Test utilities
  ../../testutil,
  ../fixtures_utils

const
  TransitionDir = SszTestsDir/const_preset/"altair"/"transition"/"core"/"pyspec_tests"

type
  TransitionEpoch = object
    post_fork: string
    fork_epoch: int
    blocks_count: int
    fork_block {.defaultVal: 0.}: int

proc runTest(testName, testDir, unitTestName: string) =
  # We wrap the tests in a proc to avoid running out of globals
  # in the future: Nim supports up to 3500 globals
  # but unittest with the macro/templates put everything as globals
  # https://github.com/nim-lang/Nim/issues/12084#issue-486866402

  let testPath = testDir / unitTestName

  var transitionEpoch: TransitionEpoch
  var s = openFileStream(testPath/"meta.yaml")
  defer: close(s)
  yaml.load(s, transitionEpoch)

  proc `testImpl _ blck _ testName`() =
    test testName & " - " & unitTestName & preset():
      var
        preState = newClone(parseTest(testPath/"pre.ssz_snappy", SSZ, phase0.BeaconState))
        fhPreState = (ref ForkedHashedBeaconState)(hbsPhase0: phase0.HashedBeaconState(
          data: preState[], root: hash_tree_root(preState[])), beaconStateFork: forkPhase0)
        cache = StateCache()
        rewards = RewardInfo()
        cfg = defaultRuntimeConfig
      cfg.ALTAIR_FORK_EPOCH = transitionEpoch.fork_epoch.Epoch

      # In test cases with more than 10 blocks the first 10 aren't 0-prefixed,
      # so purely lexicographic sorting wouldn't sort properly.
      let numBlocks = toSeq(walkPattern(testPath/"blocks_*.ssz_snappy")).len
      for i in 0 ..< numBlocks:
        let inBeforeTimes = i <= transitionEpoch.fork_block and transitionEpoch.fork_block > 0
        if inBeforeTimes:
          let blck = parseTest(testPath/"blocks_" & $i & ".ssz_snappy", SSZ, phase0.SignedBeaconBlock)

          let success = state_transition(
            cfg, fhPreState[], blck,
            cache, rewards,
            flags = {skipStateRootValidation}, noRollback)
          doAssert success, "Failure when applying block " & $i
        else:
          let blck = parseTest(testPath/"blocks_" & $i & ".ssz_snappy", SSZ, altair.SignedBeaconBlock)

          let success = state_transition(
            cfg, fhPreState[], blck,
            cache, rewards,
            flags = {skipStateRootValidation}, noRollback)
          doAssert success, "Failure when applying block " & $i

      let postState = newClone(parseTest(testPath/"post.ssz_snappy", SSZ, altair.BeaconState))
      when false:
        reportDiff(fhPreState.data, postState)
      doAssert getStateRoot(fhPreState[]) == postState[].hash_tree_root()

  `testImpl _ blck _ testName`()

suite "Official - Altair - Transition " & preset():
  # TODO investigate why this isn't working in minimal preset
  when const_preset == "mainnet":
    for kind, path in walkDir(TransitionDir, relative = true, checkDir = true):
      runTest("Official - Altair - Transition", TransitionDir, path)
