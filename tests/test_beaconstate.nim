# beacon_chain
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at http://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at http://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  sequtils, unittest,
  ./testhelpers,
  ../beacon_chain/extras,
  ../beacon_chain/spec/[beaconstate, datatypes, digest]

suite "Beacon state":
  # Smoke test

  test "Smoke on_startup":
    let state = on_startup(makeInitialValidators(EPOCH_LENGTH), 0, Eth2Digest())
    check: state.validators.len == EPOCH_LENGTH
