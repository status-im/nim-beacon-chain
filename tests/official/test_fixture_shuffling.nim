# beacon_chain
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at http://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at http://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  # Standard libs
  ospaths, strutils, json, unittest,
  # Third parties

  # Beacon chain internals
  ../../beacon_chain/spec/[datatypes, validator],
  # Test utilities
  ../testutil,
  ./fixtures_utils

const TestFolder = currentSourcePath.rsplit(DirSep, 1)[0]

when const_preset == "mainnet":
  const TestsPath = "fixtures" / "json_tests" / "shuffling" / "core" / "shuffling_full.json"
elif const_preset == "minimal":
  const TestsPath = "fixtures" / "json_tests" / "shuffling" / "core" / "shuffling_minimal.json"

var shufflingTests: Tests[Shuffling]

suite "Official - Shuffling tests [Preset: " & const_preset & ']':
  test "Parsing the official shuffling tests [Preset: " & const_preset & ']':
    shufflingTests = parseTestsShuffling(TestFolder / TestsPath)

  test "Shuffling a sequence of N validators" & preset():
    for t in shufflingTests.test_cases:
      let implResult = get_shuffled_seq(t.seed, t.count)
      check: implResult == t.shuffled
