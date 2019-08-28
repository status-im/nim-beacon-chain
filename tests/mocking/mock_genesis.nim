# beacon_chain
# Copyright (c) 2018-2019 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at http://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at http://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

# Mocking a genesis state
# ---------------------------------------------------------------

import
  # Specs
  ../../beacon_chain/spec/[datatypes, beaconstate, digest],
  # Internals
  ../../beacon_chain/extras,
  # Mocking procs
  ./mock_deposits,
  # Helpers
  ../helpers/digest_helpers


proc initGenesisState*(num_validators: uint64, genesis_time: uint64 = 0): BeaconState =

  # EF magic number (similar to https://en.wikipedia.org/wiki/Magic_number_(programming))
  const deposit_root = [byte 0x42] * 32

  let eth1_data = Eth1Data(
    deposit_root: deposit_root,
    deposit_count: num_validators,
    block_hash: ZERO_HASH
  )

  let deposits = mockGenesisBalancedDeposits(
      validatorCount = num_validators,
      amountInEth = 32, # We create canonical validators with 32 Eth
      flags = {skipValidation}
    )

  result = initialize_beacon_state_from_eth1(
    genesis_validator_deposits = deposits,
    genesis_time = 0,
    genesis_eth1_data = eth1_data,
    flags = {skipValidation}
  )

when isMainModule:
  # Smoke test
  let state = initGenesisState(num_validators = SLOTS_PER_EPOCH)
  doAssert state.validators.len == SLOTS_PER_EPOCH
