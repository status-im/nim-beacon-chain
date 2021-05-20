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
  ../../beacon_chain/spec/[datatypes, beaconstate, presets],
  ../../beacon_chain/ssz,
  # Test utilities
  ../testutil,
  ./fixtures_utils,
  ../helpers/debug_state

const OperationsDepositsDir = SszTestsDir/const_preset/"merge"/"operations"/"deposit"/"pyspec_tests"

proc runTest(identifier: string) =
  # We wrap the tests in a proc to avoid running out of globals
  # in the future: Nim supports up to 3500 globals
  # but unittest with the macro/templates put everything as globals
  # https://github.com/nim-lang/Nim/issues/12084#issue-486866402

  let testDir = OperationsDepositsDir / identifier

  proc `testImpl _ operations_deposits _ identifier`() =

    var prefix: string
    if existsFile(testDir/"post.ssz_snappy"):
      prefix = "[Valid]   "
    else:
      prefix = "[Invalid] "

    test prefix & " " & identifier:
      let deposit = parseTest(testDir/"deposit.ssz", SSZ, Deposit)
      var preState = newClone(parseTest(testDir/"pre.ssz", SSZ, BeaconState))

      if existsFile(testDir/"post.ssz_snappy"):
        let postState = newClone(parseTest(testDir/"post.ssz", SSZ, BeaconState))
        discard process_deposit(defaultRuntimePreset, preState[], deposit)
        reportDiff(preState, postState)
      else:
        check process_deposit(defaultRuntimePreset, preState[], deposit).isErr

  `testImpl _ operations_deposits _ identifier`()

suite "Official - Operations - Deposits " & preset():
  for kind, path in walkDir(OperationsDepositsDir, true):
    runTest(path)
