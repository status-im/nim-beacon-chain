# Nimbus
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or https://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or https://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [Defect].}

import
  options, stew/endians2,
  ./mocking/mock_deposits,
  ./helpers/math_helpers,
  ../beacon_chain/spec/[
    beaconstate, crypto, datatypes, forkedbeaconstate_helpers, helpers,
    presets, state_transition]

proc valid_deposit(state: var BeaconState) =
  const deposit_amount = MAX_EFFECTIVE_BALANCE
  let validator_index = state.validators.len
  let deposit = mockUpdateStateForNewDeposit(
                  state,
                  uint64 validator_index,
                  deposit_amount,
                  flags = {}
                )

  let pre_val_count = state.validators.len
  let pre_balance = if validator_index < pre_val_count:
                      state.balances[validator_index]
                    else:
                      0
  doAssert process_deposit(defaultRuntimePreset(), state, deposit, {}).isOk
  doAssert state.validators.len == pre_val_count + 1
  doAssert state.balances.len == pre_val_count + 1
  doAssert state.balances[validator_index] == pre_balance + deposit.data.amount
  doAssert state.validators[validator_index].effective_balance ==
    round_multiple_down(
      min(MAX_EFFECTIVE_BALANCE, state.balances[validator_index]),
      EFFECTIVE_BALANCE_INCREMENT
    )

proc getTestStates*(initialState: ForkedHashedBeaconState):
    seq[ref ForkedHashedBeaconState] =
  # Randomly generated slot numbers, with a jump to around
  # SLOTS_PER_HISTORICAL_ROOT to force wraparound of those
  # slot-based mod/increment fields.
  const stateEpochs = [
    0, 1,

    # Around minimal wraparound SLOTS_PER_HISTORICAL_ROOT wraparound
    5, 6, 7, 8, 9,

    39, 40, 97, 98, 99, 113, 114, 115, 116, 130, 131, 145, 146, 192, 193,
    232, 233, 237, 238,

    # Approaching and passing SLOTS_PER_HISTORICAL_ROOT wraparound
    254, 255, 256, 257, 258]

  var
    tmpState = assignClone(initialState)
    cache = StateCache()
    rewards = RewardInfo()

  for i, epoch in stateEpochs:
    let slot = epoch.Epoch.compute_start_slot_at_epoch
    if getStateField(tmpState[], slot) < slot:
      doAssert process_slots(
        tmpState[], slot, cache, rewards, {}, FAR_FUTURE_SLOT)
    if i mod 3 == 0:
      valid_deposit(tmpState.hbsPhase0.data)
    doAssert getStateField(tmpState[], slot) == slot
    result.add assignClone(tmpState[])
