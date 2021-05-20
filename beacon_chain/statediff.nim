# beacon_chain
# Copyright (c) 2020-2021 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [Defect].}

import
  stew/assign2,
  ./ssz/types,
  ./spec/[datatypes, digest, helpers]

func diffModIncEpoch[T, U](hl: HashArray[U, T], startSlot: uint64):
    array[SLOTS_PER_EPOCH, T] =
  static: doAssert U.uint64 mod SLOTS_PER_EPOCH == 0
  doAssert startSlot mod SLOTS_PER_EPOCH == 0
  for i in startSlot ..< startSlot + SLOTS_PER_EPOCH:
    result[i mod SLOTS_PER_EPOCH] = hl[i mod U.uint64]

func applyModIncrement[T, U](
    ha: var HashArray[U, T], hl: array[SLOTS_PER_EPOCH, T], slot: uint64) =
  var indexSlot = slot

  for item in hl:
    ha[indexSlot mod U.uint64] = item
    indexSlot += 1

func applyValidatorIdentities(
    validators: var HashList[Validator, Limit VALIDATOR_REGISTRY_LIMIT],
    hl: auto) =
  for item in hl:
    if not validators.add Validator(
        pubkey: item.pubkey,
        withdrawal_credentials: item.withdrawal_credentials):
      raiseAssert "cannot readd"

func setValidatorStatuses(
    validators: var HashList[Validator, Limit VALIDATOR_REGISTRY_LIMIT],
    hl: List[ValidatorStatus, Limit VALIDATOR_REGISTRY_LIMIT]) =
  doAssert validators.len == hl.len

  for i in 0 ..< hl.len:
    validators[i].effective_balance = hl[i].effective_balance
    validators[i].slashed = hl[i].slashed

    validators[i].activation_eligibility_epoch =
      hl[i].activation_eligibility_epoch
    validators[i].activation_epoch = hl[i].activation_epoch
    validators[i].exit_epoch = hl[i].exit_epoch
    validators[i].withdrawable_epoch = hl[i].withdrawable_epoch

func replaceOrAddEncodeEth1Votes[T, U](votes0, votes1: HashList[T, U]):
    (bool, List[T, U]) =
  let
    num_votes0 = votes0.len
    lower_bound =
      if  votes1.len < num_votes0 or
          (num_votes0 > 0 and votes0[num_votes0 - 1] != votes1[num_votes0 - 1]):
        # EPOCHS_PER_ETH1_VOTING_PERIOD epochs have passed, and
        # eth1_data_votes has been reset/cleared. Because their
        # deposit_index counts increase monotonically, it works
        # to use only the last element for comparison.
        0
      else:
        num_votes0

  result[0] = lower_bound == 0
  for i in lower_bound ..< votes1.len:
    if not result[1].add votes1[i]:
      raiseAssert "same limit"

func replaceOrAddDecodeEth1Votes[T, U](
    votes0: var HashList[T, U], eth1_data_votes_replaced: bool,
    votes1: List[T, U]) =
  if eth1_data_votes_replaced:
    votes0 = HashList[T, U]()

  for item in votes1:
    if not votes0.add item:
      raiseAssert "same limit"

func getMutableValidatorStatuses(state: BeaconState):
    List[ValidatorStatus, Limit VALIDATOR_REGISTRY_LIMIT] =
  if not result.setLen(state.validators.len):
    raiseAssert "same limt as validators"
  for i in 0 ..< state.validators.len:
    let validator = unsafeAddr state.validators.data[i]
    assign(result[i].effective_balance, validator.effective_balance)
    assign(result[i].slashed, validator.slashed)
    assign(
      result[i].activation_eligibility_epoch,
      validator.activation_eligibility_epoch)
    assign(result[i].activation_epoch, validator.activation_epoch)
    assign(result[i].exit_epoch, validator.exit_epoch)
    assign(result[i].withdrawable_epoch, validator.withdrawable_epoch)

func diffStates*(state0, state1: BeaconState): BeaconStateDiff =
  doAssert state1.slot > state0.slot
  doAssert state0.slot.isEpoch
  doAssert state1.slot == state0.slot + SLOTS_PER_EPOCH
  # TODO not here, but in chainDag, an isancestorof check

  doAssert state0.genesis_time == state1.genesis_time
  doAssert state0.genesis_validators_root == state1.genesis_validators_root
  doAssert state0.fork == state1.fork  # TODO fork might change
  doAssert state1.historical_roots.len - state0.historical_roots.len in [0, 1]

  let
    historical_root_added =
      state0.historical_roots.len != state1.historical_roots.len
    (eth1_data_votes_replaced, eth1_data_votes) =
      replaceOrAddEncodeEth1Votes(state0.eth1_data_votes, state1.eth1_data_votes)

  BeaconStateDiff(
    slot: state1.slot,
    latest_block_header: state1.latest_block_header,

    block_roots: diffModIncEpoch(state1.block_roots, state0.slot.uint64),
    state_roots: diffModIncEpoch(state1.state_roots, state0.slot.uint64),
    historical_root_added: historical_root_added,
    historical_root:
      if historical_root_added:
        state1.historical_roots[state0.historical_roots.len]
      else:
        default(Eth2Digest),
    eth1_data: state1.eth1_data,
    eth1_data_votes_replaced: eth1_data_votes_replaced,
    eth1_data_votes: eth1_data_votes,
    eth1_deposit_index: state1.eth1_deposit_index,

    validatorStatuses: getMutableValidatorStatuses(state1),
    balances: state1.balances.data,

    # RANDAO mixes gets updated every block, in place
    randao_mix: state1.randao_mixes[state0.slot.compute_epoch_at_slot.uint64 mod
      EPOCHS_PER_HISTORICAL_VECTOR.uint64],
    slashing: state1.slashings[state0.slot.compute_epoch_at_slot.uint64 mod
      EPOCHS_PER_HISTORICAL_VECTOR.uint64],

    previous_epoch_attestations: state1.previous_epoch_attestations.data,
    current_epoch_attestations: state1.current_epoch_attestations.data,

    justification_bits: state1.justification_bits,
    previous_justified_checkpoint: state1.previous_justified_checkpoint,
    current_justified_checkpoint: state1.current_justified_checkpoint,
    finalized_checkpoint: state1.finalized_checkpoint
  )

func applyDiff*(
    state: var BeaconState,
    immutableValidators: openArray[ImmutableValidatorData],
    stateDiff: BeaconStateDiff) =
  template assign[T, U](tgt: var HashList[T, U], src: List[T, U]) =
    assign(tgt.data, src)
    tgt.resetCache()

  # Carry over unchanged genesis_time, genesis_validators_root, and fork.
  assign(state.latest_block_header, stateDiff.latest_block_header)

  applyModIncrement(state.block_roots, stateDiff.block_roots, state.slot.uint64)
  applyModIncrement(state.state_roots, stateDiff.state_roots, state.slot.uint64)
  if stateDiff.historical_root_added:
    if not state.historical_roots.add stateDiff.historical_root:
      raiseAssert "cannot readd historical state root"

  assign(state.eth1_data, stateDiff.eth1_data)
  replaceOrAddDecodeEth1Votes(
    state.eth1_data_votes, stateDiff.eth1_data_votes_replaced,
    stateDiff.eth1_data_votes)
  assign(state.eth1_deposit_index, stateDiff.eth1_deposit_index)

  applyValidatorIdentities(state.validators, immutableValidators)
  setValidatorStatuses(state.validators, stateDiff.validator_statuses)
  assign(state.balances, stateDiff.balances)

  # RANDAO mixes gets updated every block, in place, so ensure there's always
  # >=1 value from it
  let epochIndex =
    state.slot.epoch.uint64 mod EPOCHS_PER_HISTORICAL_VECTOR.uint64
  assign(state.randao_mixes[epochIndex], stateDiff.randao_mix)
  assign(state.slashings[epochIndex], stateDiff.slashing)

  assign(
    state.previous_epoch_attestations, stateDiff.previous_epoch_attestations)
  assign(
    state.current_epoch_attestations, stateDiff.current_epoch_attestations)

  state.justification_bits = stateDiff.justification_bits
  assign(
    state.previous_justified_checkpoint, stateDiff.previous_justified_checkpoint)
  assign(
    state.current_justified_checkpoint, stateDiff.current_justified_checkpoint)
  assign(state.finalized_checkpoint, stateDiff.finalized_checkpoint)

  # Don't update slot until the end, because various other updates depend on it
  state.slot = stateDiff.slot
