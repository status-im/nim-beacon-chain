# beacon_chain
# Copyright (c) 2018-2021 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

# State transition - epoch processing, as described in
# https://github.com/ethereum/eth2.0-specs/blob/master/specs/core/0_beacon-chain.md#beacon-chain-state-transition-function
#
# The entry point is `process_epoch`, which is at the bottom of this file.
#
# General notes about the code:
# * Weird styling - the sections taken from the spec use python styling while
#   the others use NEP-1 - helps grepping identifiers in spec
# * When updating the code, add TODO sections to mark where there are clear
#   improvements to be made - other than that, keep things similar to spec unless
#   motivated by security or performance considerations

{.push raises: [Defect].}

import
  std/[math, sequtils, sets, tables, algorithm],
  stew/[bitops2], chronicles, ssz_serialization,
  ../extras, ../ssz/spec_types,
  ./beaconstate, ./crypto, ./datatypes/[phase0, altair], ./digest, ./helpers, ./validator,
  ../../nbench/bench_lab

# Logging utilities
# --------------------------------------------------------

logScope: topics = "consens"

# Accessors that implement the max condition in `get_total_balance`:
# https://github.com/ethereum/eth2.0-specs/blob/v1.0.1/specs/phase0/beacon-chain.md#get_total_balance
template current_epoch*(v: TotalBalances): Gwei =
  max(EFFECTIVE_BALANCE_INCREMENT, v.current_epoch_raw)
template previous_epoch*(v: TotalBalances): Gwei =
  max(EFFECTIVE_BALANCE_INCREMENT, v.previous_epoch_raw)
template current_epoch_attesters*(v: TotalBalances): Gwei =
  max(EFFECTIVE_BALANCE_INCREMENT, v.current_epoch_attesters_raw)
template current_epoch_target_attesters*(v: TotalBalances): Gwei =
  max(EFFECTIVE_BALANCE_INCREMENT, v.current_epoch_target_attesters_raw)
template previous_epoch_attesters*(v: TotalBalances): Gwei =
  max(EFFECTIVE_BALANCE_INCREMENT, v.previous_epoch_attesters_raw)
template previous_epoch_target_attesters*(v: TotalBalances): Gwei =
  max(EFFECTIVE_BALANCE_INCREMENT, v.previous_epoch_target_attesters_raw)
template previous_epoch_head_attesters*(v: TotalBalances): Gwei =
  max(EFFECTIVE_BALANCE_INCREMENT, v.previous_epoch_head_attesters_raw)

func init*(rewards: var RewardInfo, state: SomeBeaconState) =
  rewards.total_balances = TotalBalances()
  rewards.statuses.setLen(state.validators.len)

  for i in 0..<state.validators.len:
    let v = unsafeAddr state.validators[i]
    var flags: set[RewardFlags]

    if v[].slashed:
      flags.incl(RewardFlags.isSlashed)
    if state.get_current_epoch() >= v[].withdrawable_epoch:
      flags.incl RewardFlags.canWithdrawInCurrentEpoch

    if v[].is_active_validator(state.get_current_epoch()):
      rewards.total_balances.current_epoch_raw += v[].effective_balance

    if v[].is_active_validator(state.get_previous_epoch()):
      flags.incl RewardFlags.isActiveInPreviousEpoch
      rewards.total_balances.previous_epoch_raw += v[].effective_balance

    rewards.statuses[i] = RewardStatus(
      current_epoch_effective_balance: v[].effective_balance,
      flags: flags,
    )

func add(a: var RewardDelta, b: RewardDelta) =
  a.rewards += b.rewards
  a.penalties += b.penalties

func process_attestation(
    self: var RewardInfo, state: phase0.BeaconState, a: PendingAttestation,
    cache: var StateCache) =
  # Collect information about the attestation
  var
    flags: set[RewardFlags]
    is_previous_epoch_attester: Option[InclusionInfo]

  if a.data.target.epoch == state.get_current_epoch():
    flags.incl RewardFlags.isCurrentEpochAttester

    if a.data.target.root == get_block_root(state, state.get_current_epoch()):
      flags.incl RewardFlags.isCurrentEpochTargetAttester

  elif a.data.target.epoch == state.get_previous_epoch():
    is_previous_epoch_attester = some(InclusionInfo(
      delay: a.inclusion_delay,
      proposer_index: a.proposer_index,
    ))

    if a.data.target.root == get_block_root(state, state.get_previous_epoch()):
      flags.incl RewardFlags.isPreviousEpochTargetAttester

      if a.data.beacon_block_root == get_block_root_at_slot(state, a.data.slot):
        flags.incl RewardFlags.isPreviousEpochHeadAttester

  # Update the cache for all participants
  for validator_index in get_attesting_indices(
      state, a.data, a.aggregation_bits, cache):
    template v(): untyped = self.statuses[validator_index]

    v.flags = v.flags + flags

    if is_previous_epoch_attester.isSome:
      if v.isPreviousEpochAttester.isSome:
        if is_previous_epoch_attester.get().delay <
            v.is_previous_epoch_attester.get().delay:
          v.is_previous_epoch_attester = is_previous_epoch_attester
      else:
        v.is_previous_epoch_attester = is_previous_epoch_attester

func process_attestations*(
    self: var RewardInfo, state: phase0.BeaconState, cache: var StateCache) =
  # Walk state attestations and update the status information
  for a in state.previous_epoch_attestations:
    process_attestation(self, state, a, cache)
  for a in state.current_epoch_attestations:
    process_attestation(self, state, a, cache)

  for idx, v in self.statuses:
    if v.flags.contains RewardFlags.isSlashed:
      continue

    let validator_balance = state.validators[idx].effective_balance

    if v.flags.contains RewardFlags.isCurrentEpochAttester:
      self.total_balances.current_epoch_attesters_raw += validator_balance

    if v.flags.contains RewardFlags.isCurrentEpochTargetAttester:
      self.total_balances.current_epoch_target_attesters_raw += validator_balance

    if v.is_previous_epoch_attester.isSome():
      self.total_balances.previous_epoch_attesters_raw += validator_balance

    if v.flags.contains RewardFlags.isPreviousEpochTargetAttester:
      self.total_balances.previous_epoch_target_attesters_raw += validator_balance

    if v.flags.contains RewardFlags.isPreviousEpochHeadAttester:
      self.total_balances.previous_epoch_head_attesters_raw += validator_balance

func is_eligible_validator*(validator: RewardStatus): bool =
  validator.flags.contains(RewardFlags.isActiveInPreviousEpoch) or
    (validator.flags.contains(RewardFlags.isSlashed) and not
      (validator.flags.contains RewardFlags.canWithdrawInCurrentEpoch))

# Spec
# --------------------------------------------------------

# https://github.com/ethereum/eth2.0-specs/blob/v1.1.0-alpha.6/specs/altair/beacon-chain.md#get_unslashed_participating_indices
func get_unslashed_participating_indices(
    state: altair.BeaconState, flag_index: int, epoch: Epoch):
    HashSet[ValidatorIndex] =
  ## Return the set of validator indices that are both active and unslashed for
  ## the given ``flag_index`` and ``epoch``.
  doAssert epoch in [get_previous_epoch(state), get_current_epoch(state)]
  let
    epoch_participation =
      if epoch == get_current_epoch(state):
        state.current_epoch_participation
      else:
        state.previous_epoch_participation

    # TODO use cached version, or similar
    active_validator_indices = get_active_validator_indices(state, epoch)

  var res: HashSet[ValidatorIndex]
  for validator_index in active_validator_indices:
    if  has_flag(epoch_participation[validator_index], flag_index) and
        not state.validators[validator_index].slashed:
      res.incl validator_index
  res

# https://github.com/ethereum/eth2.0-specs/blob/v1.0.1/specs/phase0/beacon-chain.md#justification-and-finalization
proc process_justification_and_finalization*(state: var phase0.BeaconState,
    total_balances: TotalBalances, flags: UpdateFlags = {}) {.nbench.} =
  # Initial FFG checkpoint values have a `0x00` stub for `root`.
  # Skip FFG updates in the first two epochs to avoid corner cases that might
  # result in modifying this stub.
  if get_current_epoch(state) <= GENESIS_EPOCH + 1:
    return

  let
    previous_epoch = get_previous_epoch(state)
    current_epoch = get_current_epoch(state)
    old_previous_justified_checkpoint = state.previous_justified_checkpoint
    old_current_justified_checkpoint = state.current_justified_checkpoint

  # Process justifications
  state.previous_justified_checkpoint = state.current_justified_checkpoint

  ## Spec:
  ## state.justification_bits[1:] = state.justification_bits[:-1]
  ## state.justification_bits[0] = 0b0

  # https://github.com/ethereum/eth2.0-specs/blob/v1.0.1/specs/phase0/beacon-chain.md#constants
  const JUSTIFICATION_BITS_LENGTH = 4

  state.justification_bits = (state.justification_bits shl 1) and
    cast[uint8]((2^JUSTIFICATION_BITS_LENGTH) - 1)

  let total_active_balance = total_balances.current_epoch
  if total_balances.previous_epoch_target_attesters * 3 >=
      total_active_balance * 2:
    state.current_justified_checkpoint =
      Checkpoint(epoch: previous_epoch,
                 root: get_block_root(state, previous_epoch))
    state.justification_bits.setBit 1

    trace "Justified with previous epoch",
      current_epoch = current_epoch,
      checkpoint = shortLog(state.current_justified_checkpoint)
  elif verifyFinalization in flags:
    warn "Low attestation participation in previous epoch",
      total_balances, epoch = get_current_epoch(state)

  if total_balances.current_epoch_target_attesters * 3 >=
      total_active_balance * 2:
    state.current_justified_checkpoint =
      Checkpoint(epoch: current_epoch,
                 root: get_block_root(state, current_epoch))
    state.justification_bits.setBit 0

    trace "Justified with current epoch",
      current_epoch = current_epoch,
      checkpoint = shortLog(state.current_justified_checkpoint)

  # Process finalizations
  let bitfield = state.justification_bits

  ## The 2nd/3rd/4th most recent epochs are justified, the 2nd using the 4th
  ## as source
  if (bitfield and 0b1110) == 0b1110 and
     old_previous_justified_checkpoint.epoch + 3 == current_epoch:
    state.finalized_checkpoint = old_previous_justified_checkpoint

    trace "Finalized with rule 234",
      current_epoch = current_epoch,
      checkpoint = shortLog(state.finalized_checkpoint)

  ## The 2nd/3rd most recent epochs are justified, the 2nd using the 3rd as
  ## source
  if (bitfield and 0b110) == 0b110 and
     old_previous_justified_checkpoint.epoch + 2 == current_epoch:
    state.finalized_checkpoint = old_previous_justified_checkpoint

    trace "Finalized with rule 23",
      current_epoch = current_epoch,
      checkpoint = shortLog(state.finalized_checkpoint)

  ## The 1st/2nd/3rd most recent epochs are justified, the 1st using the 3rd as
  ## source
  if (bitfield and 0b111) == 0b111 and
     old_current_justified_checkpoint.epoch + 2 == current_epoch:
    state.finalized_checkpoint = old_current_justified_checkpoint

    trace "Finalized with rule 123",
      current_epoch = current_epoch,
      checkpoint = shortLog(state.finalized_checkpoint)

  ## The 1st/2nd most recent epochs are justified, the 1st using the 2nd as
  ## source
  if (bitfield and 0b11) == 0b11 and
     old_current_justified_checkpoint.epoch + 1 == current_epoch:
    state.finalized_checkpoint = old_current_justified_checkpoint

    trace "Finalized with rule 12",
      current_epoch = current_epoch,
      checkpoint = shortLog(state.finalized_checkpoint)

# https://github.com/ethereum/eth2.0-specs/blob/v1.1.0-alpha.6/specs/altair/beacon-chain.md#justification-and-finalization
# https://github.com/ethereum/eth2.0-specs/blob/v1.1.0-alpha.6/specs/phase0/beacon-chain.md#justification-and-finalization
# TODO merge these things -- effectively, the phase0 process_justification_and_finalization is mostly a stub in this world
proc weigh_justification_and_finalization(state: var altair.BeaconState,
                                          total_active_balance: Gwei,
                                          previous_epoch_target_balance: Gwei,
                                          current_epoch_target_balance: Gwei,
                                          flags: UpdateFlags = {}) =
  let
    previous_epoch = get_previous_epoch(state)
    current_epoch = get_current_epoch(state)
    old_previous_justified_checkpoint = state.previous_justified_checkpoint
    old_current_justified_checkpoint = state.current_justified_checkpoint

  # Process justifications
  state.previous_justified_checkpoint = state.current_justified_checkpoint

  ## Spec:
  ## state.justification_bits[1:] = state.justification_bits[:-1]
  ## state.justification_bits[0] = 0b0

  # https://github.com/ethereum/eth2.0-specs/blob/v1.0.1/specs/phase0/beacon-chain.md#constants
  const JUSTIFICATION_BITS_LENGTH = 4

  state.justification_bits = (state.justification_bits shl 1) and
    cast[uint8]((2^JUSTIFICATION_BITS_LENGTH) - 1)

  if previous_epoch_target_balance * 3 >= total_active_balance * 2:
    state.current_justified_checkpoint =
      Checkpoint(epoch: previous_epoch,
                 root: get_block_root(state, previous_epoch))
    state.justification_bits.setBit 1

    trace "Justified with previous epoch",
      current_epoch = current_epoch,
      checkpoint = shortLog(state.current_justified_checkpoint)
  elif verifyFinalization in flags:
    warn "Low attestation participation in previous epoch",
      total_active_balance,
      previous_epoch_target_balance,
      current_epoch_target_balance,
      epoch = get_current_epoch(state)

  if current_epoch_target_balance * 3 >= total_active_balance * 2:
    state.current_justified_checkpoint =
      Checkpoint(epoch: current_epoch,
                 root: get_block_root(state, current_epoch))
    state.justification_bits.setBit 0

    trace "Justified with current epoch",
      current_epoch = current_epoch,
      checkpoint = shortLog(state.current_justified_checkpoint)

  # Process finalizations
  let bitfield = state.justification_bits

  ## The 2nd/3rd/4th most recent epochs are justified, the 2nd using the 4th
  ## as source
  if (bitfield and 0b1110) == 0b1110 and
     old_previous_justified_checkpoint.epoch + 3 == current_epoch:
    state.finalized_checkpoint = old_previous_justified_checkpoint

    trace "Finalized with rule 234",
      current_epoch = current_epoch,
      checkpoint = shortLog(state.finalized_checkpoint)

  ## The 2nd/3rd most recent epochs are justified, the 2nd using the 3rd as
  ## source
  if (bitfield and 0b110) == 0b110 and
     old_previous_justified_checkpoint.epoch + 2 == current_epoch:
    state.finalized_checkpoint = old_previous_justified_checkpoint

    trace "Finalized with rule 23",
      current_epoch = current_epoch,
      checkpoint = shortLog(state.finalized_checkpoint)

  ## The 1st/2nd/3rd most recent epochs are justified, the 1st using the 3rd as
  ## source
  if (bitfield and 0b111) == 0b111 and
     old_current_justified_checkpoint.epoch + 2 == current_epoch:
    state.finalized_checkpoint = old_current_justified_checkpoint

    trace "Finalized with rule 123",
      current_epoch = current_epoch,
      checkpoint = shortLog(state.finalized_checkpoint)

  ## The 1st/2nd most recent epochs are justified, the 1st using the 2nd as
  ## source
  if (bitfield and 0b11) == 0b11 and
     old_current_justified_checkpoint.epoch + 1 == current_epoch:
    state.finalized_checkpoint = old_current_justified_checkpoint

    trace "Finalized with rule 12",
      current_epoch = current_epoch,
      checkpoint = shortLog(state.finalized_checkpoint)

proc process_justification_and_finalization*(state: var altair.BeaconState,
    total_active_balance: Gwei, flags: UpdateFlags = {}) {.nbench.} =
  # Initial FFG checkpoint values have a `0x00` stub for `root`.
  # Skip FFG updates in the first two epochs to avoid corner cases that might
  # result in modifying this stub.
  if get_current_epoch(state) <= GENESIS_EPOCH + 1:
    return
  let
    # these ultimately differ from phase0 only in these lines
    # ref: https://github.com/ethereum/eth2.0-specs/blob/v1.1.0-alpha.6/specs/phase0/beacon-chain.md#justification-and-finalization
    previous_indices = get_unslashed_participating_indices(
      state, TIMELY_TARGET_FLAG_INDEX, get_previous_epoch(state))
    current_indices = get_unslashed_participating_indices(
      state, TIMELY_TARGET_FLAG_INDEX, get_current_epoch(state))
    previous_target_balance = get_total_balance(state, previous_indices)
    current_target_balance = get_total_balance(state, current_indices)
  weigh_justification_and_finalization(
    state, total_active_balance, previous_target_balance,
    current_target_balance, flags)

# https://github.com/ethereum/eth2.0-specs/blob/v1.0.1/specs/phase0/beacon-chain.md#helpers
func get_base_reward_sqrt*(state: phase0.BeaconState, index: ValidatorIndex,
    total_balance_sqrt: auto): Gwei =
  # Spec function recalculates total_balance every time, which creates an
  # O(n^2) situation.
  let effective_balance = state.validators[index].effective_balance
  effective_balance * BASE_REWARD_FACTOR div
    total_balance_sqrt div BASE_REWARDS_PER_EPOCH

func get_proposer_reward(base_reward: Gwei): Gwei =
  # Spec version recalculates get_total_active_balance(state) quadratically
  base_reward div PROPOSER_REWARD_QUOTIENT

func is_in_inactivity_leak(finality_delay: uint64): bool =
  finality_delay > MIN_EPOCHS_TO_INACTIVITY_PENALTY

func get_finality_delay(state: SomeBeaconState): uint64 =
  get_previous_epoch(state) - state.finalized_checkpoint.epoch

# https://github.com/ethereum/eth2.0-specs/blob/v1.1.0-alpha.6/specs/phase0/beacon-chain.md#rewards-and-penalties-1
func is_in_inactivity_leak(state: altair.BeaconState): bool =
  # TODO remove this, see above
  get_finality_delay(state) > MIN_EPOCHS_TO_INACTIVITY_PENALTY

func get_attestation_component_delta(is_unslashed_attester: bool,
                                     attesting_balance: Gwei,
                                     total_balance: Gwei,
                                     base_reward: uint64,
                                     finality_delay: uint64): RewardDelta =
  # Helper with shared logic for use by get source, target, and head deltas
  # functions
  if is_unslashed_attester:
    if is_in_inactivity_leak(finality_delay):
      # Since full base reward will be canceled out by inactivity penalty deltas,
      # optimal participation receives full base reward compensation here.
      RewardDelta(rewards: base_reward)
    else:
      let reward_numerator =
        base_reward * (attesting_balance div EFFECTIVE_BALANCE_INCREMENT)
      RewardDelta(rewards:
        reward_numerator div (total_balance div EFFECTIVE_BALANCE_INCREMENT))
  else:
    RewardDelta(penalties: base_reward)

# https://github.com/ethereum/eth2.0-specs/blob/v1.0.1/specs/phase0/beacon-chain.md#components-of-attestation-deltas
func get_source_delta*(validator: RewardStatus,
                       base_reward: uint64,
                       total_balances: TotalBalances,
                       finality_delay: uint64): RewardDelta =
  ## Return attester micro-rewards/penalties for source-vote for each validator.
  get_attestation_component_delta(
    validator.is_previous_epoch_attester.isSome() and
      not (validator.flags.contains RewardFlags.isSlashed),
    total_balances.previous_epoch_attesters,
    total_balances.current_epoch,
    base_reward,
    finality_delay)

func get_target_delta*(validator: RewardStatus,
                       base_reward: uint64,
                       total_balances: TotalBalances,
                       finality_delay: uint64): RewardDelta =
  ## Return attester micro-rewards/penalties for target-vote for each validator.
  get_attestation_component_delta(
    validator.flags.contains(RewardFlags.isPreviousEpochTargetAttester) and
      not (validator.flags.contains(RewardFlags.isSlashed)),
    total_balances.previous_epoch_target_attesters,
    total_balances.current_epoch,
    base_reward,
    finality_delay)

func get_head_delta*(validator: RewardStatus,
                     base_reward: uint64,
                     total_balances: TotalBalances,
                     finality_delay: uint64): RewardDelta =
  ## Return attester micro-rewards/penalties for head-vote for each validator.
  get_attestation_component_delta(
    validator.flags.contains(RewardFlags.isPreviousEpochHeadAttester) and
      ((not validator.flags.contains(RewardFlags.isSlashed))),
    total_balances.previous_epoch_head_attesters,
    total_balances.current_epoch,
    base_reward,
    finality_delay)

func get_inclusion_delay_delta*(validator: RewardStatus,
                                base_reward: uint64):
                                  (RewardDelta, Option[(uint64, RewardDelta)]) =
  ## Return proposer and inclusion delay micro-rewards/penalties for each validator.
  if validator.is_previous_epoch_attester.isSome() and ((not validator.flags.contains(RewardFlags.isSlashed))):
    let
      inclusion_info = validator.is_previous_epoch_attester.get()
      proposer_reward = get_proposer_reward(base_reward)
      proposer_delta = RewardDelta(rewards: proposer_reward)

    let
      max_attester_reward = base_reward - proposer_reward
      delta = RewardDelta(rewards: max_attester_reward div inclusion_info.delay)
      proposer_index = inclusion_info.proposer_index;
    return (delta, some((proposer_index, proposer_delta)))

func get_inactivity_penalty_delta*(validator: RewardStatus,
                                   base_reward: Gwei,
                                   finality_delay: uint64): RewardDelta =
  ## Return inactivity reward/penalty deltas for each validator.
  var delta: RewardDelta

  if is_in_inactivity_leak(finality_delay):
    # If validator is performing optimally this cancels all rewards for a neutral balance
    delta.penalties +=
      BASE_REWARDS_PER_EPOCH * base_reward - get_proposer_reward(base_reward)

    # Additionally, all validators whose FFG target didn't match are penalized extra
    # This condition is equivalent to this condition from the spec:
    # `index not in get_unslashed_attesting_indices(state, matching_target_attestations)`
    if (validator.flags.contains(RewardFlags.isSlashed)) or
        ((not validator.flags.contains(RewardFlags.isPreviousEpochTargetAttester))):
      delta.penalties +=
        validator.current_epoch_effective_balance * finality_delay div
          INACTIVITY_PENALTY_QUOTIENT

  delta

# https://github.com/ethereum/eth2.0-specs/blob/v1.0.1/specs/phase0/beacon-chain.md#get_attestation_deltas
func get_attestation_deltas(state: phase0.BeaconState, rewards: var RewardInfo) =
  ## Update rewards with attestation reward/penalty deltas for each validator.

  let
    finality_delay = get_finality_delay(state)
    total_balance = rewards.total_balances.current_epoch
    total_balance_sqrt = integer_squareroot(total_balance)
  # Filter out ineligible validators. All sub-functions of the spec do this
  # except for `get_inclusion_delay_deltas`. It's safe to do so here because
  # any validator that is in the unslashed indices of the matching source
  # attestations is active, and therefore eligible.
  for index, validator in rewards.statuses.mpairs():
    if not is_eligible_validator(validator):
      continue

    let
      base_reward = get_base_reward_sqrt(
        state, index.ValidatorIndex, total_balance_sqrt)

    let
      source_delta = get_source_delta(
        validator, base_reward, rewards.total_balances, finality_delay)
      target_delta = get_target_delta(
        validator, base_reward, rewards.total_balances, finality_delay)
      head_delta = get_head_delta(
        validator, base_reward, rewards.total_balances, finality_delay)
      (inclusion_delay_delta, proposer_delta) =
        get_inclusion_delay_delta(validator, base_reward)
      inactivity_delta = get_inactivity_penalty_delta(
        validator, base_reward, finality_delay)

    validator.delta.add source_delta
    validator.delta.add target_delta
    validator.delta.add head_delta
    validator.delta.add inclusion_delay_delta
    validator.delta.add inactivity_delta

    if proposer_delta.isSome:
      let proposer_index = proposer_delta.get()[0]
      if proposer_index < rewards.statuses.lenu64:
        rewards.statuses[proposer_index].delta.add(
          proposer_delta.get()[1])

# https://github.com/ethereum/eth2.0-specs/blob/v1.1.0-alpha.6/specs/altair/beacon-chain.md#get_base_reward_per_increment
func get_base_reward_per_increment(
    state: altair.BeaconState, total_active_balance: Gwei): Gwei =
  # TODO hoist this integer_squareroot, as with phase 0
  EFFECTIVE_BALANCE_INCREMENT * BASE_REWARD_FACTOR div
    integer_squareroot(total_active_balance)

# https://github.com/ethereum/eth2.0-specs/blob/v1.1.0-alpha.6/specs/altair/beacon-chain.md#get_base_reward
func get_base_reward(
    state: altair.BeaconState, index: ValidatorIndex, total_active_balance: Gwei):
    Gwei =
  ## Return the base reward for the validator defined by ``index`` with respect
  ## to the current ``state``.
  #
  # Note: An optimally performing validator can earn one base reward per epoch
  # over a long time horizon. This takes into account both per-epoch (e.g.
  # attestation) and intermittent duties (e.g. block proposal and sync
  # committees).
  let increments =
    state.validators[index].effective_balance div EFFECTIVE_BALANCE_INCREMENT
  increments * get_base_reward_per_increment(state, total_active_balance)

# https://github.com/ethereum/eth2.0-specs/blob/v1.1.0-alpha.6/specs/altair/beacon-chain.md#get_flag_index_deltas
iterator get_flag_index_deltas(
    state: altair.BeaconState, flag_index: int, total_active_balance: Gwei):
    (ValidatorIndex, Gwei, Gwei) =
  ## Return the deltas for a given ``flag_index`` by scanning through the
  ## participation flags.
  let
    previous_epoch = get_previous_epoch(state)
    unslashed_participating_indices =
      get_unslashed_participating_indices(state, flag_index, previous_epoch)
    weight = PARTICIPATION_FLAG_WEIGHTS[flag_index].uint64 # safe
    unslashed_participating_balance =
      get_total_balance(state, unslashed_participating_indices)
    unslashed_participating_increments =
      unslashed_participating_balance div EFFECTIVE_BALANCE_INCREMENT
    active_increments = total_active_balance div EFFECTIVE_BALANCE_INCREMENT

  for index in 0 ..< state.validators.len:
    # TODO Obviously not great
    let v = state.validators[index]
    if  not (is_active_validator(v, previous_epoch) or
        (v.slashed and previous_epoch + 1 < v.withdrawable_epoch)):
      continue

    template vidx: ValidatorIndex = index.ValidatorIndex
    let base_reward = get_base_reward(state, vidx, total_active_balance)
    yield
      if vidx in unslashed_participating_indices:
        if not is_in_inactivity_leak(state):
          let reward_numerator =
            base_reward * weight * unslashed_participating_increments
          (vidx, reward_numerator div (active_increments * WEIGHT_DENOMINATOR), 0.Gwei)
        else:
          (vidx, 0.Gwei, 0.Gwei)
      elif flag_index != TIMELY_HEAD_FLAG_INDEX:
        (vidx, 0.Gwei, base_reward * weight div WEIGHT_DENOMINATOR)
      else:
        (vidx, 0.Gwei, 0.Gwei)

# https://github.com/ethereum/eth2.0-specs/blob/v1.1.0-alpha.6/specs/altair/beacon-chain.md#modified-get_inactivity_penalty_deltas
iterator get_inactivity_penalty_deltas(state: altair.BeaconState):
    (ValidatorIndex, Gwei) =
  ## Return the inactivity penalty deltas by considering timely target
  ## participation flags and inactivity scores.
  let
    previous_epoch = get_previous_epoch(state)
    matching_target_indices =
      get_unslashed_participating_indices(state, TIMELY_TARGET_FLAG_INDEX, previous_epoch)
  for index in 0 ..< state.validators.len:
    # get_eligible_validator_indices()
    let v = state.validators[index]
    if  not (is_active_validator(v, previous_epoch) or
        (v.slashed and previous_epoch + 1 < v.withdrawable_epoch)):
      continue

    template vidx: untyped = index.ValidatorIndex
    if not (vidx in matching_target_indices):
      const penalty_denominator =
        INACTIVITY_SCORE_BIAS * INACTIVITY_PENALTY_QUOTIENT_ALTAIR
      let
        penalty_numerator = state.validators[index].effective_balance *
          state.inactivity_scores[index]
      yield (vidx, Gwei(penalty_numerator div penalty_denominator))

# https://github.com/ethereum/eth2.0-specs/blob/v1.0.1/specs/phase0/beacon-chain.md#process_rewards_and_penalties
func process_rewards_and_penalties(
    state: var phase0.BeaconState, rewards: var RewardInfo) {.nbench.} =
  # No rewards are applied at the end of `GENESIS_EPOCH` because rewards are
  # for work done in the previous epoch
  doAssert rewards.statuses.len == state.validators.len

  if get_current_epoch(state) == GENESIS_EPOCH:
    return

  get_attestation_deltas(state, rewards)

  # Here almost all balances are updated (assuming most validators are active) -
  # clearing the cache becomes a bottleneck if done item by item because of the
  # recursive nature of cache clearing - instead, we clear the whole cache then
  # update the raw list directly
  state.balances.clearCache()
  for idx, v in rewards.statuses:
    increase_balance(state.balances.asSeq()[idx], v.delta.rewards)
    decrease_balance(state.balances.asSeq()[idx], v.delta.penalties)

# https://github.com/ethereum/eth2.0-specs/blob/v1.1.0-alpha.6/specs/altair/beacon-chain.md#rewards-and-penalties
func process_rewards_and_penalties(
    state: var altair.BeaconState, total_active_balance: Gwei) {.nbench.} =
  if get_current_epoch(state) == GENESIS_EPOCH:
    return

  # TODO assess relevance of missing phase0 optimizations
  # TODO probably both of these aren't necessary, but need to verify
  # commutativity & associativity. Probably, since active validators
  # get ejected at 16 Gwei, either it avoids over or underflow there
  # or doesn't receive rewards or penalties so both are 0. But start
  # with this.
  var
    rewards = newSeq[Gwei](state.validators.len)
    penalties = newSeq[Gwei](state.validators.len)

  for flag_index in 0 ..< PARTICIPATION_FLAG_WEIGHTS.len:
    for validator_index, reward, penalty in get_flag_index_deltas(
        state, flag_index, total_active_balance):
      rewards[validator_index] += reward
      penalties[validator_index] += penalty

  for validator_index, penalty in get_inactivity_penalty_deltas(state):
    penalties[validator_index] += penalty

  for index in 0 ..< len(state.validators):
    increase_balance(state, ValidatorIndex(index), rewards[index])
    decrease_balance(state, ValidatorIndex(index), penalties[index])

# https://github.com/ethereum/eth2.0-specs/blob/v1.0.1/specs/phase0/beacon-chain.md#slashings
# https://github.com/ethereum/eth2.0-specs/blob/v1.1.0-alpha.6/specs/altair/beacon-chain.md#slashings
func process_slashings*(state: var SomeBeaconState, total_balance: Gwei) {.nbench.}=
  let
    epoch = get_current_epoch(state)
    multiplier =
      # tradeoff here about interleaving phase0/altair, but for these
      # single-constant changes...
      uint64(when state is phase0.BeaconState:
        PROPORTIONAL_SLASHING_MULTIPLIER
      elif state is altair.BeaconState:
        PROPORTIONAL_SLASHING_MULTIPLIER_ALTAIR
      else:
        raiseAssert "process_slashings: incorrect BeaconState type")
    adjusted_total_slashing_balance =
      min(sum(state.slashings) * multiplier, total_balance)

  for index in 0..<state.validators.len:
    let validator = unsafeAddr state.validators.asSeq()[index]
    if validator[].slashed and epoch + EPOCHS_PER_SLASHINGS_VECTOR div 2 ==
        validator[].withdrawable_epoch:
      let increment = EFFECTIVE_BALANCE_INCREMENT # Factored out from penalty
                                                  # numerator to avoid uint64 overflow
      let penalty_numerator =
        validator[].effective_balance div increment *
        adjusted_total_slashing_balance
      let penalty = penalty_numerator div total_balance * increment
      decrease_balance(state, index.ValidatorIndex, penalty)

# https://github.com/ethereum/eth2.0-specs/blob/34cea67b91/specs/phase0/beacon-chain.md#eth1-data-votes-updates
func process_eth1_data_reset*(state: var SomeBeaconState) {.nbench.} =
  let next_epoch = get_current_epoch(state) + 1

  # Reset eth1 data votes
  if next_epoch mod EPOCHS_PER_ETH1_VOTING_PERIOD == 0:
    state.eth1_data_votes = default(type state.eth1_data_votes)

# https://github.com/ethereum/eth2.0-specs/blob/34cea67b91/specs/phase0/beacon-chain.md#effective-balances-updates
func process_effective_balance_updates*(state: var SomeBeaconState) {.nbench.} =
  # Update effective balances with hysteresis
  for index in 0..<state.validators.len:
    let balance = state.balances.asSeq()[index]
    const
      HYSTERESIS_INCREMENT =
        EFFECTIVE_BALANCE_INCREMENT div HYSTERESIS_QUOTIENT
      DOWNWARD_THRESHOLD =
        HYSTERESIS_INCREMENT * HYSTERESIS_DOWNWARD_MULTIPLIER
      UPWARD_THRESHOLD = HYSTERESIS_INCREMENT * HYSTERESIS_UPWARD_MULTIPLIER
    let effective_balance = state.validators.asSeq()[index].effective_balance
    if balance + DOWNWARD_THRESHOLD < effective_balance or
        effective_balance + UPWARD_THRESHOLD < balance:
      state.validators[index].effective_balance =
        min(
          balance - balance mod EFFECTIVE_BALANCE_INCREMENT,
          MAX_EFFECTIVE_BALANCE)

# https://github.com/ethereum/eth2.0-specs/blob/34cea67b91/specs/phase0/beacon-chain.md#slashings-balances-updates
func process_slashings_reset*(state: var SomeBeaconState) {.nbench.} =
  let next_epoch = get_current_epoch(state) + 1

  # Reset slashings
  state.slashings[int(next_epoch mod EPOCHS_PER_SLASHINGS_VECTOR)] = 0.Gwei

# https://github.com/ethereum/eth2.0-specs/blob/34cea67b91/specs/phase0/beacon-chain.md#randao-mixes-updates
func process_randao_mixes_reset*(state: var SomeBeaconState) {.nbench.} =
  let
    current_epoch = get_current_epoch(state)
    next_epoch = current_epoch + 1

  # Set randao mix
  state.randao_mixes[next_epoch mod EPOCHS_PER_HISTORICAL_VECTOR] =
    get_randao_mix(state, current_epoch)

# https://github.com/ethereum/eth2.0-specs/blob/34cea67b91/specs/phase0/beacon-chain.md#historical-roots-updates
func process_historical_roots_update*(state: var SomeBeaconState) {.nbench.} =
  # Set historical root accumulator
  let next_epoch = get_current_epoch(state) + 1

  if next_epoch mod (SLOTS_PER_HISTORICAL_ROOT div SLOTS_PER_EPOCH) == 0:
    # Equivalent to hash_tree_root(foo: HistoricalBatch), but without using
    # significant additional stack or heap.
    # https://github.com/ethereum/eth2.0-specs/blob/v1.0.1/specs/phase0/beacon-chain.md#historicalbatch
    # In response to https://github.com/status-im/nimbus-eth2/issues/921
    if not state.historical_roots.add hash_tree_root(
        [hash_tree_root(state.block_roots), hash_tree_root(state.state_roots)]):
      raiseAssert "no more room for historical roots, so long and thanks for the fish!"

# https://github.com/ethereum/eth2.0-specs/blob/34cea67b91/specs/phase0/beacon-chain.md#participation-records-rotation
func process_participation_record_updates*(state: var phase0.BeaconState) {.nbench.} =
  # Rotate current/previous epoch attestations - using swap avoids copying all
  # elements using a slow genericSeqAssign
  state.previous_epoch_attestations.clear()
  swap(state.previous_epoch_attestations, state.current_epoch_attestations)

# https://github.com/ethereum/eth2.0-specs/blob/v1.1.0-alpha.6/specs/altair/beacon-chain.md#participation-flags-updates
func process_participation_flag_updates*(state: var altair.BeaconState) =
  state.previous_epoch_participation = state.current_epoch_participation

  # TODO more subtle clearing
  state.current_epoch_participation.clear()
  for _ in 0 ..< state.validators.len:
    doAssert state.current_epoch_participation.add 0.ParticipationFlags

# https://github.com/ethereum/eth2.0-specs/blob/v1.1.0-alpha.6/specs/altair/beacon-chain.md#sync-committee-updates
proc process_sync_committee_updates*(state: var altair.BeaconState) =
  let next_epoch = get_current_epoch(state) + 1
  if next_epoch mod EPOCHS_PER_SYNC_COMMITTEE_PERIOD == 0:
    state.current_sync_committee = state.next_sync_committee
    state.next_sync_committee = get_next_sync_committee(state)

# https://github.com/ethereum/eth2.0-specs/blob/v1.1.0-alpha.6/specs/altair/beacon-chain.md#inactivity-scores
func process_inactivity_updates*(state: var altair.BeaconState) =
  # Score updates based on previous epoch participation, skip genesis epoch
  if get_current_epoch(state) == GENESIS_EPOCH:
    return

  # TODO actually implement get_eligible_validator_indices() as an iterator
  let previous_epoch = get_previous_epoch(state)  # get_eligible_validator_indices()
  for index in 0'u64 ..< state.validators.lenu64:
    # get_eligible_validator_indices()
    let v = state.validators[index]
    if not (is_active_validator(v, previous_epoch) or (v.slashed and previous_epoch + 1 < v.withdrawable_epoch)):
      continue

    # Increase inactivity score of inactive validators
    if index.ValidatorIndex in get_unslashed_participating_indices(state, TIMELY_TARGET_FLAG_INDEX, get_previous_epoch(state)):
      state.inactivity_scores[index] -= min(1'u64, state.inactivity_scores[index])
    else:
      state.inactivity_scores[index] += INACTIVITY_SCORE_BIAS
    # Decrease the score of all validators for forgiveness when not during a leak
    if not is_in_inactivity_leak(state):
      state.inactivity_scores[index] -= min(INACTIVITY_SCORE_RECOVERY_RATE.uint64, state.inactivity_scores[index])

# https://github.com/ethereum/eth2.0-specs/blob/v1.0.1/specs/phase0/beacon-chain.md#epoch-processing
proc process_epoch*(
    state: var phase0.BeaconState, flags: UpdateFlags, cache: var StateCache,
    rewards: var RewardInfo) {.nbench.} =
  let currentEpoch = get_current_epoch(state)
  trace "process_epoch",
    current_epoch = currentEpoch
  init(rewards, state)
  rewards.process_attestations(state, cache)

  # https://github.com/ethereum/eth2.0-specs/blob/v1.0.1/specs/phase0/beacon-chain.md#justification-and-finalization
  process_justification_and_finalization(
    state, rewards.total_balances, flags)

  # state.slot hasn't been incremented yet.
  if verifyFinalization in flags and currentEpoch >= 2:
    doAssert state.current_justified_checkpoint.epoch + 2 >= currentEpoch

  if verifyFinalization in flags and currentEpoch >= 3:
    # Rule 2/3/4 finalization results in the most pessimal case. The other
    # three finalization rules finalize more quickly as long as the any of
    # the finalization rules triggered.
    doAssert state.finalized_checkpoint.epoch + 3 >= currentEpoch

  # https://github.com/ethereum/eth2.0-specs/blob/v1.0.1/specs/phase0/beacon-chain.md#rewards-and-penalties-1
  process_rewards_and_penalties(state, rewards)

  # https://github.com/ethereum/eth2.0-specs/blob/v1.0.1/specs/phase0/beacon-chain.md#registry-updates
  process_registry_updates(state, cache)

  # https://github.com/ethereum/eth2.0-specs/blob/v1.0.1/specs/phase0/beacon-chain.md#slashings
  process_slashings(state, rewards.total_balances.current_epoch)

  # https://github.com/ethereum/eth2.0-specs/blob/v1.0.1/specs/phase0/beacon-chain.md#final-updates
  process_eth1_data_reset(state)
  process_effective_balance_updates(state)
  process_slashings_reset(state)
  process_randao_mixes_reset(state)
  process_historical_roots_update(state)
  process_participation_record_updates(state)

# https://github.com/ethereum/eth2.0-specs/blob/v1.1.0-alpha.6/specs/altair/beacon-chain.md#epoch-processing
proc process_epoch*(
    state: var altair.BeaconState, flags: UpdateFlags, cache: var StateCache,
    rewards: var RewardInfo) {.nbench.} =
  let currentEpoch = get_current_epoch(state)
  trace "process_epoch",
    current_epoch = currentEpoch
  init(rewards, state)
  when false:
    rewards.process_attestations(state, cache)

  let total_active_balance = state.get_total_active_balance(cache)

  # https://github.com/ethereum/eth2.0-specs/blob/v1.0.1/specs/phase0/beacon-chain.md#justification-and-finalization
  process_justification_and_finalization(state, total_active_balance, flags)

  # state.slot hasn't been incremented yet.
  if verifyFinalization in flags and currentEpoch >= 2:
    doAssert state.current_justified_checkpoint.epoch + 2 >= currentEpoch

  if verifyFinalization in flags and currentEpoch >= 3:
    # Rule 2/3/4 finalization results in the most pessimal case. The other
    # three finalization rules finalize more quickly as long as the any of
    # the finalization rules triggered.
    doAssert state.finalized_checkpoint.epoch + 3 >= currentEpoch

  process_inactivity_updates(state)  # [New in Altair]

  # https://github.com/ethereum/eth2.0-specs/blob/v1.0.1/specs/phase0/beacon-chain.md#rewards-and-penalties-1
  process_rewards_and_penalties(state, total_active_balance)

  # https://github.com/ethereum/eth2.0-specs/blob/v1.0.1/specs/phase0/beacon-chain.md#registry-updates
  process_registry_updates(state, cache)

  # https://github.com/ethereum/eth2.0-specs/blob/v1.0.1/specs/phase0/beacon-chain.md#slashings
  process_slashings(state, total_active_balance)

  process_eth1_data_reset(state)

  process_effective_balance_updates(state)

  process_slashings_reset(state)

  process_randao_mixes_reset(state)

  process_historical_roots_update(state)

  process_participation_flag_updates(state)  # [New in Altair]

  process_sync_committee_updates(state)  # [New in Altair]
