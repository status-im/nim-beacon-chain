# beacon_chain
# Copyright (c) 2018-Present Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at http://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at http://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  # Standard library
  os, unittest,
  # Beacon chain internals
  ../../beacon_chain/spec/[datatypes, beaconstate],
  ../../beacon_chain/[ssz, extras],
  # Test utilities
  ../testutil,
  ./fixtures_utils,
  ../helpers/debug_state

const OperationsDepositsDir = SszTestsDir/const_preset/"phase0"/"operations"/"deposit"/"pyspec_tests"

template runTest(testName: string, identifier: untyped) =
  # We wrap the tests in a proc to avoid running out of globals
  # in the future: Nim supports up to 3500 globals
  # but unittest with the macro/templates put everything as globals
  # https://github.com/nim-lang/Nim/issues/12084#issue-486866402

  const testDir = OperationsDepositsDir / astToStr(identifier)

  proc `testImpl _ operations_deposits _ identifier`() =

    var flags: UpdateFlags
    var prefix: string
    if not existsFile(testDir/"meta.yaml"):
      flags.incl skipValidation
    if existsFile(testDir/"post.ssz"):
      prefix = "[Valid]   "
    else:
      prefix = "[Invalid] "

    test prefix & testName & " (" & astToStr(identifier) & ")":
      var stateRef, postRef: ref BeaconStateNew
      var sr_pre, sr_post: ref BeaconState
      var depositRef: ref Deposit
      new depositRef
      new stateRef
      new sr_pre
      new sr_post

      depositRef[] = parseTest(testDir/"deposit.ssz", SSZ, Deposit)
      stateRef[] = parseTest(testDir/"pre.ssz", SSZ, BeaconStateNew)
      sr_pre[] = GetOldBeaconState(stateRef[])

      if existsFile(testDir/"post.ssz"):
        new postRef
        postRef[] = parseTest(testDir/"post.ssz", SSZ, BeaconStateNew)
        sr_post[] = GetOldBeaconState(postRef[])

      if postRef.isNil:
        expect(AssertionError):
          let done = process_deposit(sr_pre[], depositRef[], flags)
      else:
        let done = process_deposit(sr_pre[], depositRef[], flags)
        reportDiff(sr_pre, sr_post)

  `testImpl _ operations_deposits _ identifier`()

suite "Official - Operations - Deposits " & preset():
  runTest("new deposit under max", new_deposit_under_max)
  runTest("new deposit max", new_deposit_max)
  runTest("new deposit over max", new_deposit_over_max)
  runTest("invalid signature new deposit", invalid_sig_new_deposit)
  runTest("success top-up", success_top_up)
  runTest("invalid signature top-up", invalid_sig_top_up)
  runTest("invalid withdrawal credentials top-up", invalid_withdrawal_credentials_top_up)

  when false:
    # TODO - those should give an exception but do not
    #        probably because skipValidation is too strong
    #        https://github.com/status-im/nim-beacon-chain/issues/407
    runTest("wrong deposit for deposit count", wrong_deposit_for_deposit_count)
    runTest("bad merkle proof", bad_merkle_proof)
