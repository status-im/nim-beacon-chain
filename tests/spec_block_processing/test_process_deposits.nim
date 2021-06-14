# beacon_chain
# Copyright (c) 2018-2021 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.


# process_deposit (beaconstate.nim)
# https://github.com/ethereum/eth2.0-specs/blob/v1.0.1/specs/phase0/beacon-chain.md#deposits
# ---------------------------------------------------------------

{.used.}

import
  # Standard library
  std/math,
  # Specs
  ../../beacon_chain/spec/[beaconstate, datatypes, crypto, presets],
  # Internals
  ../../beacon_chain/extras,
  # Mock helpers
  ../mocking/[mock_deposits, mock_genesis],
  ../testutil, ../helpers/math_helpers

suite "[Unit - Spec - Block processing] Deposits " & preset():

  const NumValidators = uint64 5 * SLOTS_PER_EPOCH
  let genesisState = newClone(initGenesisState(NumValidators))
  doAssert genesisState.data.validators.lenu64 == NumValidators

  template valid_deposit(deposit_amount: uint64, name: string): untyped =
    test "Deposit " & name & " MAX_EFFECTIVE_BALANCE balance (" &
          $(MAX_EFFECTIVE_BALANCE div 10'u64^9) & " ETH)":
      var state = assignClone(genesisState[])

      # Test configuration
      # ----------------------------------------
      let validator_index = state.data.validators.len
      let deposit = mockUpdateStateForNewDeposit(
                      state.data,
                      uint64 validator_index,
                      deposit_amount,
                      flags = {}
                    )

      # Params for sanity checks
      # ----------------------------------------
      let pre_val_count = state.data.validators.len
      let pre_balance = if validator_index < pre_val_count:
                          state.data.balances[validator_index]
                        else:
                          0

      # State transition
      # ----------------------------------------
      check: process_deposit(defaultRuntimePreset(), state.data, deposit, {}).isOk

      # Check invariants
      # ----------------------------------------
      check:
        state.data.validators.len == pre_val_count + 1
        state.data.balances.len == pre_val_count + 1
        state.data.balances[validator_index] == pre_balance + deposit.data.amount
        state.data.validators[validator_index].effective_balance ==
          round_multiple_down(
            min(MAX_EFFECTIVE_BALANCE, state.data.balances[validator_index]),
            EFFECTIVE_BALANCE_INCREMENT
          )

  valid_deposit(MAX_EFFECTIVE_BALANCE - 1, "under")
  valid_deposit(MAX_EFFECTIVE_BALANCE, "at")
  valid_deposit(MAX_EFFECTIVE_BALANCE + 1, "over")

  test "Validator top-up":
    var state = assignClone(genesisState[])

    # Test configuration
    # ----------------------------------------
    let validator_index = 0
    let deposit_amount = MAX_EFFECTIVE_BALANCE div 4
    let deposit = mockUpdateStateForNewDeposit(
                    state.data,
                    uint64 validator_index,
                    deposit_amount,
                    flags = {}
                  )

    # Params for sanity checks
    # ----------------------------------------
    let pre_val_count = state.data.validators.len
    let pre_balance = if validator_index < pre_val_count:
                        state.data.balances[validator_index]
                      else:
                        0

    # State transition
    # ----------------------------------------
    check: process_deposit(defaultRuntimePreset(), state.data, deposit, {}).isOk

    # Check invariants
    # ----------------------------------------
    check:
      state.data.validators.len == pre_val_count
      state.data.balances.len == pre_val_count
      state.data.balances[validator_index] == pre_balance + deposit.data.amount
      state.data.validators[validator_index].effective_balance ==
        round_multiple_down(
          min(MAX_EFFECTIVE_BALANCE, state.data.balances[validator_index]),
          EFFECTIVE_BALANCE_INCREMENT
        )

  template invalid_signature(deposit_amount: uint64, name: string): untyped =
    test "Invalid deposit " & name & " MAX_EFFECTIVE_BALANCE balance (" &
          $(MAX_EFFECTIVE_BALANCE div 10'u64^9) & " ETH)":
      var state = assignClone(genesisState[])

      # Test configuration
      # ----------------------------------------
      let validator_index = state.data.validators.len
      var deposit = mockUpdateStateForNewDeposit(
                      state.data,
                      uint64 validator_index,
                      deposit_amount,
                      flags = {skipBlsValidation}
                    )

      # Params for sanity checks
      # ----------------------------------------
      let pre_val_count = state.data.validators.len

      # State transition
      # ----------------------------------------
      check:
        process_deposit(defaultRuntimePreset(), state.data, deposit, {}).isOk

      # Check invariants
      # ----------------------------------------
      check:
        state.data.validators.len == pre_val_count
        state.data.balances.len == pre_val_count

  invalid_signature(MAX_EFFECTIVE_BALANCE, "at")

  # TODO, tests with:
  # - invalid withdrawal credential
  # - invalid deposit root
  # - invalid merkle proof
