# beacon_chain
# Copyright (c) 2018-Present Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at http://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at http://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.used.}

import
  # Standard library
  os, unittest,
  # Beacon chain internals
  ../../beacon_chain/spec/[datatypes, state_transition_block],
  ../../beacon_chain/[ssz, extras],
  # Test utilities
  ../testutil,
  ./fixtures_utils,
  ../helpers/debug_state

const OpVoluntaryExitDir = SszTestsDir/const_preset/"phase0"/"operations"/"voluntary_exit"/"pyspec_tests"

template runTest(identifier: untyped) =
  # We wrap the tests in a proc to avoid running out of globals
  # in the future: Nim supports up to 3500 globals
  # but unittest with the macro/templates put everything as globals
  # https://github.com/nim-lang/Nim/issues/12084#issue-486866402

  const testDir = OpVoluntaryExitDir / astToStr(identifier)

  proc `testImpl _ voluntary_exit _ identifier`() =

    var flags: UpdateFlags
    var prefix: string
    if not existsFile(testDir/"meta.yaml"):
      flags.incl skipValidation
    if existsFile(testDir/"post.ssz"):
      prefix = "[Valid]   "
    else:
      prefix = "[Invalid] "

    test prefix & astToStr(identifier):
      var stateRef, postRef: ref BeaconState
      var voluntaryExit: ref VoluntaryExit
      new voluntaryExit
      new stateRef

      voluntaryExit[] = parseTest(testDir/"voluntary_exit.ssz", SSZ, VoluntaryExit)
      stateRef[] = parseTest(testDir/"pre.ssz", SSZ, BeaconState)

      if existsFile(testDir/"post.ssz"):
        new postRef
        postRef[] = parseTest(testDir/"post.ssz", SSZ, BeaconState)

      if postRef.isNil:
        let done = process_voluntary_exit(stateRef[], voluntaryExit[], flags)
        doAssert done == false, "We didn't expect this invalid voluntary exit to be processed."
      else:
        let done = process_voluntary_exit(stateRef[], voluntaryExit[], flags)
        doAssert done, "Valid voluntary exit not processed"
        check: stateRef.hash_tree_root() == postRef.hash_tree_root()
        reportDiff(stateRef, postRef)

  `testImpl _ voluntary_exit _ identifier`()

suite "Official - Operations - Voluntary exit " & preset():
  runTest(success)
  runTest(invalid_signature)
  runTest(success_exit_queue)
  runTest(validator_exit_in_future)
  runTest(validator_invalid_validator_index)
  runTest(validator_not_active)
  runTest(validator_already_exited)
  runTest(validator_not_active_long_enough)

