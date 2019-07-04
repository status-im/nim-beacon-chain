# beacon_chain
# Copyright (c) 2018-2019 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at http://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at http://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

# State transition - epoch processing, as described in
# https://github.com/ethereum/eth2.0-specs/blob/master/specs/core/0_beacon-chain.md#beacon-chain-state-transition-function
#
# The purpose of this code right is primarily educational, to help piece
# together the mechanics of the beacon state and to discover potential problem
# areas.
#
# The entry point is `process_epoch` which is at the bottom of this file.
#
# General notes about the code (TODO):
# * It's inefficient - we quadratically copy, allocate and iterate when there
#   are faster options
# * Weird styling - the sections taken from the spec use python styling while
#   the others use NEP-1 - helps grepping identifiers in spec
# * We mix procedural and functional styles for no good reason, except that the
#   spec does so also.
# * There are likely lots of bugs.
# * For indices, we get a mix of uint64, ValidatorIndex and int - this is currently
#   swept under the rug with casts
# * The spec uses uint64 for data types, but functions in the spec often assume
#   signed bigint semantics - under- and overflows ensue
# * Sane error handling is missing in most cases (yay, we'll get the chance to
#   debate exceptions again!)
# When updating the code, add TODO sections to mark where there are clear
# improvements to be made - other than that, keep things similar to spec for
# now.

import # TODO - cleanup imports
  algorithm, collections/sets, chronicles, math, options, sequtils, sets, tables,
  ../extras, ../ssz, ../beacon_node_types,
  beaconstate, bitfield, crypto, datatypes, digest, helpers, validator

# https://github.com/ethereum/eth2.0-specs/blob/v0.6.3/specs/core/0_beacon-chain.md#helper-functions-1
func get_total_active_balance(state: BeaconState): Gwei =
  return get_total_balance(
    state,
    get_active_validator_indices(state, get_current_epoch(state)))

func get_matching_source_attestations(state: BeaconState, epoch: Epoch):
    seq[PendingAttestation] =
  doAssert epoch in @[get_current_epoch(state), get_previous_epoch(state)]
  if epoch == get_current_epoch(state):
    state.current_epoch_attestations
  else:
    state.previous_epoch_attestations

func get_matching_target_attestations(state: BeaconState, epoch: Epoch):
    seq[PendingAttestation] =
  filterIt(
    get_matching_source_attestations(state, epoch),
    it.data.target.root == get_block_root(state, epoch)
  )

func get_matching_head_attestations(state: BeaconState, epoch: Epoch):
    seq[PendingAttestation] =
  filterIt(
     get_matching_source_attestations(state, epoch),
     it.data.beacon_block_root ==
       get_block_root_at_slot(state, get_attestation_data_slot(state, it.data))
  )

func get_unslashed_attesting_indices(
    state: BeaconState, attestations: seq[PendingAttestation],
    stateCache: var StateCache): HashSet[ValidatorIndex] =
  result = initSet[ValidatorIndex]()
  for a in attestations:
    result = result.union(get_attesting_indices(
      state, a.data, a.aggregation_bits, stateCache))

  for index in result:
    if state.validators[index].slashed:
      result.excl index

func get_attesting_balance(
    state: BeaconState, attestations: seq[PendingAttestation],
    stateCache: var StateCache): Gwei =
  get_total_balance(state, get_unslashed_attesting_indices(
    state, attestations, stateCache))

# Not exactly in spec, but for get_winning_crosslink_and_attesting_indices
func lowerThan(candidate, current: Eth2Digest): bool =
  # return true iff candidate is "lower" than current, per spec rule:
  # "ties broken in favor of lexicographically higher hash
  for i, v in current.data:
    if v > candidate.data[i]: return true
  false

func get_winning_crosslink_and_attesting_indices(
    state: BeaconState, epoch: Epoch, shard: Shard,
    stateCache: var StateCache): tuple[a: Crosslink, b: HashSet[ValidatorIndex]] =
  let
    attestations =
      filterIt(
        get_matching_source_attestations(state, epoch),
        it.data.crosslink.shard == shard)
    # TODO don't keep h_t_r'ing state.current_crosslinks[shard]
    crosslinks =
      filterIt(
        mapIt(attestations, it.data.crosslink),
        hash_tree_root(state.current_crosslinks[shard]) in
          # TODO pointless memory allocation, etc.
          @[it.parent_root, hash_tree_root(it)])

  # default=Crosslink()
  if len(crosslinks) == 0:
    return (Crosslink(), initSet[ValidatorIndex]())

  ## Winning crosslink has the crosslink data root with the most balance voting
  ## for it (ties broken lexicographically)
  var
    winning_crosslink: Crosslink
    winning_crosslink_balance = 0.Gwei

  for candidate_crosslink in crosslinks:
    ## TODO check if should cache this again
    ## let root_balance = get_attesting_balance_cached(
    ##   state, attestations_for.getOrDefault(r), cache)
    let crosslink_balance =
      get_attesting_balance(
        state,
        filterIt(attestations, it.data.crosslink == candidate_crosslink),
        stateCache)
    if (crosslink_balance > winning_crosslink_balance or
        (winning_crosslink_balance == crosslink_balance and
         lowerThan(winning_crosslink.data_root,
                   candidate_crosslink.data_root))):
      winning_crosslink = candidate_crosslink
      winning_crosslink_balance = crosslink_balance

  let winning_attestations =
    filterIt(attestations, it.data.crosslink == winning_crosslink)
  (winning_crosslink,
   get_unslashed_attesting_indices(state, winning_attestations, stateCache))

# https://github.com/ethereum/eth2.0-specs/blob/v0.7.1/specs/core/0_beacon-chain.md#justification-and-finalization
func process_justification_and_finalization(
    state: var BeaconState, stateCache: var StateCache) =
  if get_current_epoch(state) <= GENESIS_EPOCH + 1:
    return

  let
    previous_epoch = get_previous_epoch(state)
    current_epoch = get_current_epoch(state)
    old_previous_justified_epoch = state.previous_justified_epoch
    old_current_justified_epoch = state.current_justified_epoch

  # Process justifications
  state.previous_justified_epoch = state.current_justified_epoch
  state.previous_justified_root = state.current_justified_root
  state.justification_bits = (state.justification_bits shl 1)
  let previous_epoch_matching_target_balance =
    get_attesting_balance(state,
      get_matching_target_attestations(state, previous_epoch), stateCache)
  if previous_epoch_matching_target_balance * 3 >=
      get_total_active_balance(state) * 2:
    state.current_justified_epoch = previous_epoch
    state.current_justified_root =
      get_block_root(state, state.current_justified_epoch)
    state.justification_bits = state.justification_bits or (1 shl 1)
  let current_epoch_matching_target_balance =
    get_attesting_balance(state,
      get_matching_target_attestations(state, current_epoch),
      stateCache)
  if current_epoch_matching_target_balance * 3 >=
      get_total_active_balance(state) * 2:
    state.current_justified_epoch = current_epoch
    state.current_justified_root =
      get_block_root(state, state.current_justified_epoch)
    state.justification_bits = state.justification_bits or (1 shl 0)

  # Process finalizations
  let bitfield = state.justification_bits

  ## The 2nd/3rd/4th most recent epochs are justified, the 2nd using the 4th
  ## as source
  if (bitfield shr 1) mod 8 == 0b111 and old_previous_justified_epoch + 3 ==
      current_epoch:
    state.finalized_checkpoint.epoch = old_previous_justified_epoch
    state.finalized_checkpoint.root =
      get_block_root(state, state.finalized_checkpoint.epoch)

  ## The 2nd/3rd most recent epochs are justified, the 2nd using the 3rd as
  ## source
  if (bitfield shr 1) mod 4 == 0b11 and old_previous_justified_epoch + 2 ==
      current_epoch:
    state.finalized_checkpoint.epoch = old_previous_justified_epoch
    state.finalized_checkpoint.root =
      get_block_root(state, state.finalized_checkpoint.epoch)

  ## The 1st/2nd/3rd most recent epochs are justified, the 1st using the 3rd as
  ## source
  if (bitfield shr 0) mod 8 == 0b111 and old_current_justified_epoch + 2 ==
      current_epoch:
    state.finalized_checkpoint.epoch = old_current_justified_epoch
    state.finalized_checkpoint.root =
      get_block_root(state, state.finalized_checkpoint.epoch)

  ## The 1st/2nd most recent epochs are justified, the 1st using the 2nd as
  ## source
  if (bitfield shr 0) mod 4 == 0b11 and old_current_justified_epoch + 1 ==
      current_epoch:
    state.finalized_checkpoint.epoch = old_current_justified_epoch
    state.finalized_checkpoint.root =
      get_block_root(state, state.finalized_checkpoint.epoch)

# https://github.com/ethereum/eth2.0-specs/blob/v0.8.0/specs/core/0_beacon-chain.md#crosslinks
func process_crosslinks(state: var BeaconState, stateCache: var StateCache) =
  state.previous_crosslinks = state.current_crosslinks

  for epoch in @[get_previous_epoch(state), get_current_epoch(state)]:
    for offset in 0'u64 ..< get_committee_count(state, epoch):
      let
        shard = (get_start_shard(state, epoch) + offset) mod SHARD_COUNT
        crosslink_committee =
          toSet(get_crosslink_committee(state, epoch, shard, stateCache))
        # In general, it'll loop over the same shards twice, and
        # get_winning_root_and_participants is defined to return
        # the same results from the previous epoch as current.
        # TODO cache like before, in 0.5 version of this function
        (winning_crosslink, attesting_indices) =
          get_winning_crosslink_and_attesting_indices(
            state, epoch, shard, stateCache)
      if 3'u64 * get_total_balance(state, attesting_indices) >=
          2'u64 * get_total_balance(state, crosslink_committee):
        state.current_crosslinks[shard] = winning_crosslink

# https://github.com/ethereum/eth2.0-specs/blob/v0.7.1/specs/core/0_beacon-chain.md#rewards-and-penalties-1
func get_base_reward(state: BeaconState, index: ValidatorIndex): Gwei =
  let
    total_balance = get_total_active_balance(state)
    effective_balance = state.validators[index].effective_balance
  effective_balance * BASE_REWARD_FACTOR div
    integer_squareroot(total_balance) div BASE_REWARDS_PER_EPOCH

# https://github.com/ethereum/eth2.0-specs/blob/v0.6.3/specs/core/0_beacon-chain.md#rewards-and-penalties
func get_attestation_deltas(state: BeaconState, stateCache: var StateCache):
    tuple[a: seq[Gwei], b: seq[Gwei]] =
  let
    previous_epoch = get_previous_epoch(state)
    total_balance = get_total_active_balance(state)
  var
    rewards = repeat(0'u64, len(state.validators))
    penalties = repeat(0'u64, len(state.validators))
    eligible_validator_indices : seq[ValidatorIndex] = @[]

  for index, v in state.validators:
    if is_active_validator(v, previous_epoch) or
        (v.slashed and previous_epoch + 1 < v.withdrawable_epoch):
      eligible_validator_indices.add index.ValidatorIndex

  # Micro-incentives for matching FFG source, FFG target, and head
  let
    matching_source_attestations =
      get_matching_source_attestations(state, previous_epoch)
    matching_target_attestations =
      get_matching_target_attestations(state, previous_epoch)
    matching_head_attestations =
      get_matching_head_attestations(state, previous_epoch)
  for attestations in
      @[matching_source_attestations, matching_target_attestations,
        matching_head_attestations]:
    let
      unslashed_attesting_indices =
        get_unslashed_attesting_indices(state, attestations, stateCache)
      attesting_balance = get_attesting_balance(state, attestations, stateCache)
    for index in eligible_validator_indices:
      if index in unslashed_attesting_indices:
        rewards[index] +=
          get_base_reward(state, index) * attesting_balance div total_balance
      else:
        penalties[index] += get_base_reward(state, index)

  if matching_source_attestations.len == 0:
    return (rewards, penalties)

  # Proposer and inclusion delay micro-rewards
  for index in get_unslashed_attesting_indices(
      state, matching_source_attestations, stateCache):
    doAssert matching_source_attestations.len > 0
    var attestation = matching_source_attestations[0]
    for a in matching_source_attestations:
      if index notin get_attesting_indices(
          state, a.data, a.aggregation_bits, stateCache):
        continue
      if a.inclusion_delay < attestation.inclusion_delay:
        attestation = a
    rewards[attestation.proposer_index] += get_base_reward(state, index) div
      PROPOSER_REWARD_QUOTIENT
    rewards[index] +=
      get_base_reward(state, index) * MIN_ATTESTATION_INCLUSION_DELAY div
        attestation.inclusion_delay

  # Inactivity penalty
  let finality_delay = previous_epoch - state.finalized_checkpoint.epoch
  if finality_delay > MIN_EPOCHS_TO_INACTIVITY_PENALTY:
    let matching_target_attesting_indices =
      get_unslashed_attesting_indices(
        state, matching_target_attestations, stateCache)
    for index in eligible_validator_indices:
      penalties[index] +=
        BASE_REWARDS_PER_EPOCH.uint64 * get_base_reward(state, index)
      if index notin matching_target_attesting_indices:
        penalties[index] +=
          state.validators[index].effective_balance *
            finality_delay div INACTIVITY_PENALTY_QUOTIENT

  (rewards, penalties)

# TODO re-cache this one, as under 0.5 version, if profiling suggests it
func get_crosslink_deltas(state: BeaconState, cache: var StateCache):
    tuple[a: seq[Gwei], b: seq[Gwei]] =

  var
    rewards = repeat(0'u64, len(state.validators))
    penalties = repeat(0'u64, len(state.validators))
  let epoch = get_previous_epoch(state)
  for offset in 0'u64 ..< get_committee_count(state, epoch):
    let
      shard = (get_start_shard(state, epoch) + offset) mod SHARD_COUNT
      crosslink_committee =
        get_crosslink_committee(state, epoch, shard, cache)
      (winning_crosslink, attesting_indices) =
        get_winning_crosslink_and_attesting_indices(
          state, epoch, shard, cache)
      attesting_balance = get_total_balance(state, attesting_indices)
      committee_balance = get_total_balance(state, crosslink_committee)
    for index in crosslink_committee:
      let base_reward = get_base_reward(state, index)
      if index in attesting_indices:
        rewards[index] +=
          get_base_reward(state, index) * attesting_balance div
            committee_balance
      else:
        penalties[index] += get_base_reward(state, index)

  (rewards, penalties)

# https://github.com/ethereum/eth2.0-specs/blob/v0.8.0/specs/core/0_beacon-chain.md#rewards-and-penalties-1
func process_rewards_and_penalties(
    state: var BeaconState, cache: var StateCache) =
  if get_current_epoch(state) == GENESIS_EPOCH:
    return

  let
    (rewards1, penalties1) = get_attestation_deltas(state, cache)
    (rewards2, penalties2) = get_crosslink_deltas(state, cache)
  for i in 0 ..< len(state.validators):
    increase_balance(state, i.ValidatorIndex, rewards1[i] + rewards2[i])
    decrease_balance(state, i.ValidatorIndex, penalties1[i] + penalties2[i])

# https://github.com/ethereum/eth2.0-specs/blob/v0.7.1/specs/core/0_beacon-chain.md#slashings
func process_slashings(state: var BeaconState) =
  let
    current_epoch = get_current_epoch(state)
    total_balance = get_total_active_balance(state)

    # Compute `total_penalties`
    total_at_start = state.slashings[
      (current_epoch + 1) mod LATEST_SLASHED_EXIT_LENGTH]
    total_at_end =
      state.slashings[current_epoch mod
        LATEST_SLASHED_EXIT_LENGTH]
    total_penalties = total_at_end - total_at_start

  for index, validator in state.validators:
    if validator.slashed and current_epoch == validator.withdrawable_epoch -
        LATEST_SLASHED_EXIT_LENGTH div 2:
      let
        penalty = max(
          validator.effective_balance *
            min(total_penalties * 3, total_balance) div total_balance,
          validator.effective_balance div MIN_SLASHING_PENALTY_QUOTIENT)
      decrease_balance(state, index.ValidatorIndex, penalty)

# https://github.com/ethereum/eth2.0-specs/blob/v0.6.3/specs/core/0_beacon-chain.md#final-updates
func process_final_updates(state: var BeaconState) =
  let
    current_epoch = get_current_epoch(state)
    next_epoch = current_epoch + 1

  # Reset eth1 data votes
  if (state.slot + 1) mod SLOTS_PER_ETH1_VOTING_PERIOD == 0:
    state.eth1_data_votes = @[]

  # Update effective balances with hysteresis
  for index, validator in state.validators:
    let balance = state.balances[index]
    const HALF_INCREMENT = EFFECTIVE_BALANCE_INCREMENT div 2
    if balance < validator.effective_balance or
        validator.effective_balance + 3'u64 * HALF_INCREMENT < balance:
      state.validators[index].effective_balance =
        min(
          balance - balance mod EFFECTIVE_BALANCE_INCREMENT,
          MAX_EFFECTIVE_BALANCE)

  # Update start shard
  state.start_shard =
    (state.start_shard + get_shard_delta(state, current_epoch)) mod
      SHARD_COUNT

  # Set total slashed balances
  state.slashings[next_epoch mod LATEST_SLASHED_EXIT_LENGTH] = (
    state.slashings[current_epoch mod LATEST_SLASHED_EXIT_LENGTH]
  )

  # Set randao mix
  state.randao_mixes[next_epoch mod LATEST_RANDAO_MIXES_LENGTH] =
    get_randao_mix(state, current_epoch)

  # Set historical root accumulator
  if next_epoch mod (SLOTS_PER_HISTORICAL_ROOT div SLOTS_PER_EPOCH).uint64 == 0:
    let historical_batch = HistoricalBatch(
      block_roots: state.block_roots,
      state_roots: state.state_roots,
    )
    state.historical_roots.add (hash_tree_root(historical_batch))

  # Rotate current/previous epoch attestations
  state.previous_epoch_attestations = state.current_epoch_attestations
  state.current_epoch_attestations = @[]

# https://github.com/ethereum/eth2.0-specs/blob/v0.6.3/specs/core/0_beacon-chain.md#per-epoch-processing
func processEpoch*(state: var BeaconState) =
  if not (state.slot > GENESIS_SLOT and
         (state.slot + 1) mod SLOTS_PER_EPOCH == 0):
    return

  var per_epoch_cache = get_empty_per_epoch_cache()

  # https://github.com/ethereum/eth2.0-specs/blob/v0.7.1/specs/core/0_beacon-chain.md#justification-and-finalization
  process_justification_and_finalization(state, per_epoch_cache)

  # https://github.com/ethereum/eth2.0-specs/blob/v0.7.1/specs/core/0_beacon-chain.md#crosslinks
  process_crosslinks(state, per_epoch_cache)

  # https://github.com/ethereum/eth2.0-specs/blob/v0.7.1/specs/core/0_beacon-chain.md#rewards-and-penalties-1
  process_rewards_and_penalties(state, per_epoch_cache)

  # https://github.com/ethereum/eth2.0-specs/blob/v0.8.0/specs/core/0_beacon-chain.md#registry-updates
  # Don't rely on caching here.
  process_registry_updates(state)

  ## Caching here for get_crosslink_committee(...) can break otherwise, since
  ## get_active_validator_indices(...) usually changes.
  clear(per_epoch_cache.crosslink_committee_cache)

  # https://github.com/ethereum/eth2.0-specs/blob/v0.7.1/specs/core/0_beacon-chain.md#slashings
  process_slashings(state)

  # https://github.com/ethereum/eth2.0-specs/blob/v0.7.1/specs/core/0_beacon-chain.md#final-updates
  process_final_updates(state)
