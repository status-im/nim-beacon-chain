# beacon_chain
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at http://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at http://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  chronicles, math, options, sequtils,
  ../extras, ../ssz,
  ./crypto, ./datatypes, ./digest, ./helpers, ./validator

func get_effective_balance*(state: BeaconState, index: Uint24): uint64 =
  # Validators collect rewards which increases their balance but not their
  # influence. Validators may also lose balance if they fail to do their duty
  # in which case their influence decreases. Once they drop below a certain
  # balance, they're removed from the validator registry.
  min(state.validator_balances[index], MAX_DEPOSIT * GWEI_PER_ETH)

func sum_effective_balances*(
    state: BeaconState, validator_indices: openArray[Uint24]): uint64 =
  # TODO spec - add as helper? Used pretty often
  for index in validator_indices:
    result += get_effective_balance(state, index)

func validate_proof_of_possession(state: BeaconState,
                                  pubkey: ValidatorPubKey,
                                  proof_of_possession: ValidatorSig,
                                  withdrawal_credentials: Eth2Digest,
                                  randao_commitment: Eth2Digest): bool =
  let proof_of_possession_data = DepositInput(
    pubkey: pubkey,
    withdrawal_credentials: withdrawal_credentials,
    randao_commitment: randao_commitment
  )

  bls_verify(
    pubkey,
    hash_tree_root_final(proof_of_possession_data).data,
    proof_of_possession,
    get_domain(
        state.fork_data,
        state.slot,
        DOMAIN_DEPOSIT,
    )
  )

func process_deposit(state: var BeaconState,
                     pubkey: ValidatorPubKey,
                     deposit: uint64,
                     proof_of_possession: ValidatorSig,
                     withdrawal_credentials: Eth2Digest,
                     randao_commitment: Eth2Digest,
                     custody_commitment: Eth2Digest) : Uint24 =
  ## Process a deposit from Ethereum 1.0.

  if false:
    # TODO return error; currently, just fails if ever called
    # but hadn't been set up to run at all
    doAssert validate_proof_of_possession(
      state, pubkey, proof_of_possession, withdrawal_credentials,
      randao_commitment)

  let validator_pubkeys = state.validator_registry.mapIt(it.pubkey)

  if pubkey notin validator_pubkeys:
    # Add new validator
    let validator = Validator(
      status: UNUSED,
      pubkey: pubkey,
      withdrawal_credentials: withdrawal_credentials,
      randao_commitment: randao_commitment,
      randao_layers: 0,
      activation_slot: FAR_FUTURE_SLOT,
      exit_slot: FAR_FUTURE_SLOT,
      withdrawal_slot: FAR_FUTURE_SLOT,
      penalized_slot: FAR_FUTURE_SLOT,
      exit_count: 0,
      status_flags: 0,
      custody_commitment: custody_commitment,
      latest_custody_reseed_slot: GENESIS_SLOT,
      penultimate_custody_reseed_slot: GENESIS_SLOT
    )

    let index = min_empty_validator_index(
      state.validator_registry, state.validator_balances, state.slot)
    if index.isNone():
      state.validator_registry.add(validator)
      state.validator_balances.add(deposit)
      (len(state.validator_registry) - 1).Uint24
    else:
      state.validator_registry[index.get()] = validator
      state.validator_balances[index.get()] = deposit
      index.get().Uint24
  else:
    # Increase balance by deposit amount
    let index = validator_pubkeys.find(pubkey)
    let validator = addr state.validator_registry[index]
    assert state.validator_registry[index].withdrawal_credentials ==
      withdrawal_credentials

    state.validator_balances[index] += deposit
    index.Uint24

func activate_validator(state: var BeaconState,
                        index: Uint24,
                        genesis: bool) =
  ## Activate the validator with the given ``index``.
  let validator = addr state.validator_registry[index]

  validator.status = ACTIVE
  validator.activation_slot = if genesis: GENESIS_SLOT else: state.slot + ENTRY_EXIT_DELAY
  state.validator_registry_delta_chain_tip =
    get_new_validator_registry_delta_chain_tip(
      state.validator_registry_delta_chain_tip,
      index,
      validator.pubkey,
      validator.activation_slot,
      ACTIVATION,
    )

func initiate_validator_exit(state: var BeaconState,
                             index: Uint24) =
  ## Initiate exit for the validator with the given ``index``.
  let validator = addr state.validator_registry[index]
  if validator.status != ACTIVE:
    return

  validator.status = ACTIVE_PENDING_EXIT
  validator.latest_status_change_slot = state.slot

func exit_validator*(state: var BeaconState,
                     index: Uint24,
                     new_status: ValidatorStatusCodes) =
  ## Exit the validator with the given ``index``.

  let
    validator = addr state.validator_registry[index]
    prev_status = validator.status

  if prev_status == EXITED_WITH_PENALTY:
    return

  validator.status = new_status
  validator.latest_status_change_slot = state.slot

  if new_status == EXITED_WITH_PENALTY:
    state.latest_penalized_exit_balances[
      (state.slot div COLLECTIVE_PENALTY_CALCULATION_PERIOD).int] +=
        get_effective_balance(state, index)

    let
      whistleblower_index =
        get_beacon_proposer_index(state, state.slot)
      whistleblower_reward =
        get_effective_balance(state, index) div WHISTLEBLOWER_REWARD_QUOTIENT

    state.validator_balances[whistleblower_index] += whistleblower_reward
    state.validator_balances[index] -= whistleblower_reward

  if prev_status == EXITED_WITHOUT_PENALTY:
    return

  # The following updates only occur if not previous exited
  state.validator_registry_exit_count += 1
  validator.exit_count = state.validator_registry_exit_count
  state.validator_registry_delta_chain_tip =
    get_new_validator_registry_delta_chain_tip(
      state.validator_registry_delta_chain_tip,
      index,
      validator.pubkey,
      validator.exit_slot,
      ValidatorSetDeltaFlags.EXIT
    )

  # Remove validator from persistent committees
  for committee in state.persistent_committees.mitems():
    for i, validator_index in committee:
      if validator_index == index:
        committee.delete(i)
        break

func process_penalties_and_exits_eligible(state: BeaconState, index: int): bool =
  let validator = state.validator_registry[index]
  if validator.penalized_slot <= state.slot:
    # strangely uppercase variable-ish name
    let PENALIZED_WITHDRAWAL_TIME = (LATEST_PENALIZED_EXIT_LENGTH * EPOCH_LENGTH div 2).uint64
    return state.slot >= validator.penalized_slot + PENALIZED_WITHDRAWAL_TIME
  else:
    return state.slot >= validator.exit_slot + MIN_VALIDATOR_WITHDRAWAL_TIME

func process_penalties_and_exits(state: var BeaconState) =
  # The active validators
  let active_validator_indices = get_active_validator_indices(state.validator_registry, state.slot)
  # The total effective balance of active validators
  var total_balance : uint64 = 0
  for i in active_validator_indices:
    total_balance += get_effective_balance(state, i)

  for index, validator in state.validator_registry:
    if (state.slot div EPOCH_LENGTH) == (validator.penalized_slot div EPOCH_LENGTH) + LATEST_PENALIZED_EXIT_LENGTH div 2:
      let
        e = ((state.slot div EPOCH_LENGTH) mod LATEST_PENALIZED_EXIT_LENGTH).int
        total_at_start = state.latest_penalized_exit_balances[(e + 1) mod LATEST_PENALIZED_EXIT_LENGTH]
        total_at_end = state.latest_penalized_exit_balances[e]
        total_penalties = total_at_end - total_at_start
        penalty = get_effective_balance(state, index.Uint24) * min(total_penalties * 3, total_balance) div total_balance
      state.validator_balances[index] -= penalty

  ## 'state' is of type <var BeaconState> which cannot be captured as it
  ## would violate memory safety, when using nested function approach in
  ## spec directly. That said, the spec approach evidently is not meant,
  ## based on its abundant and pointless memory copies, for production.
  var eligible_indices : seq[Uint24] = @[]
  for i in 0 ..< len(state.validator_registry):
    eligible_indices.add i.Uint24

  ## TODO figure out that memory safety issue, which would come up again when
  ## sorting, and then actually do withdrawals

func get_initial_beacon_state*(
    initial_validator_deposits: openArray[Deposit],
    genesis_time: uint64,
    latest_deposit_root: Eth2Digest,
    flags: UpdateFlags = {}): BeaconState =
  ## BeaconState constructor
  ##
  ## Before the beacon chain starts, validators will register in the Eth1 chain
  ## and deposit ETH. When enough many validators have registered, a
  ## `ChainStart` log will be emitted and the beacon chain can start beaconing.
  ##
  ## Because the state root hash is part of the genesis block, the beacon state
  ## must be calculated before creating the genesis block.

  # Induct validators
  # Not in spec: the system doesn't work unless there are at least EPOCH_LENGTH
  # validators - there needs to be at least one member in each committee -
  # good to know for testing, though arguably the system is not that useful at
  # at that point :)
  assert initial_validator_deposits.len >= EPOCH_LENGTH

  var state = BeaconState(
    # Misc
    slot: GENESIS_SLOT,
    genesis_time: genesis_time,
    fork_data: ForkData(
        pre_fork_version: GENESIS_FORK_VERSION,
        post_fork_version: GENESIS_FORK_VERSION,
        fork_slot: GENESIS_SLOT,
    ),

    validator_registry_latest_change_slot: GENESIS_SLOT,
    validator_registry_exit_count: 0,
    validator_registry_delta_chain_tip: ZERO_HASH,

    # Randomness and committees
    previous_epoch_start_shard: GENESIS_START_SHARD,
    current_epoch_start_shard: GENESIS_START_SHARD,
    previous_epoch_calculation_slot: GENESIS_SLOT,
    current_epoch_calculation_slot: GENESIS_SLOT,
    previous_epoch_randao_mix: ZERO_HASH,
    current_epoch_randao_mix: ZERO_HASH,

    # Finality
    previous_justified_slot: GENESIS_SLOT,
    justified_slot: GENESIS_SLOT,
    justification_bitfield: 0,
    finalized_slot: GENESIS_SLOT,

    # Deposit root
    latest_deposit_root: latest_deposit_root,
  )

  # Process initial deposits
  for deposit in initial_validator_deposits:
    let validator_index = process_deposit(
      state,
      deposit.deposit_data.deposit_input.pubkey,
      deposit.deposit_data.amount,
      deposit.deposit_data.deposit_input.proof_of_possession,
      deposit.deposit_data.deposit_input.withdrawal_credentials,
      deposit.deposit_data.deposit_input.randao_commitment,
      deposit.deposit_data.deposit_input.custody_commitment,
    )

    if state.validator_balances[validator_index] >= MAX_DEPOSIT:
      activate_validator(state, validator_index, true)

  # Process initial activations
  #for validator_index in 0 ..< state.validator_registry.len:
  #  let vi = validator_index.Uint24
  #  if get_effective_balance(state, vi) > MAX_DEPOSIT * GWEI_PER_ETH:
  #    activate_validator(state, vi, true)

  # set initial committee shuffling
  let
    initial_shuffling =
      get_shuffling(Eth2Digest(), state.validator_registry, 0)

  # initial_shuffling + initial_shuffling in spec, but more ugly
  for i, n in initial_shuffling:
    state.shard_committees_at_slots[i] = n
    state.shard_committees_at_slots[EPOCH_LENGTH + i] = n

  # set initial persistent shuffling
  let active_validator_indices =
    get_active_validator_indices(state.validator_registry)

  state.persistent_committees = split(shuffle(
    active_validator_indices, ZERO_HASH), SHARD_COUNT)

  state

func get_block_root*(state: BeaconState,
                     slot: uint64): Eth2Digest =
  doAssert state.slot <= slot + LATEST_BLOCK_ROOTS_LENGTH
  doAssert slot < state.slot
  state.latest_block_roots[slot mod LATEST_BLOCK_ROOTS_LENGTH]

func get_randao_mix*(state: BeaconState,
                    slot: uint64): Eth2Digest =
    ## Returns the randao mix at a recent ``slot``.
    assert state.slot < slot + LATEST_RANDAO_MIXES_LENGTH
    assert slot <= state.slot
    state.latest_randao_mixes[slot mod LATEST_RANDAO_MIXES_LENGTH]

func get_attestation_participants*(state: BeaconState,
                                   attestation_data: AttestationData,
                                   participation_bitfield: seq[byte]): seq[Uint24] =
  ## Attestation participants in the attestation data are called out in a
  ## bit field that corresponds to the committee of the shard at the time - this
  ## function converts it to list of indices in to BeaconState.validators
  ## Returns empty list if the shard is not found
  # TODO Linear search through shard list? borderline ok, it's a small list
  # TODO bitfield type needed, once bit order settles down
  # TODO iterator candidate
  let
    sncs_for_slot = get_shard_committees_at_slot(
      state, attestation_data.slot)

  for snc in sncs_for_slot:
    if snc.shard != attestation_data.shard:
      continue

    # TODO investigate functional library / approach to help avoid loop bugs
    assert len(participation_bitfield) == ceil_div8(len(snc.committee))
    for i, vindex in snc.committee:
      if bitIsSet(participation_bitfield, i):
        result.add(vindex)
    return # found the shard, we're done

func process_ejections*(state: var BeaconState) =
  ## Iterate through the validator registry
  ## and eject active validators with balance below ``EJECTION_BALANCE``.

  for index in get_active_validator_indices(state.validator_registry):
    if state.validator_balances[index] < EJECTION_BALANCE:
      exit_validator(state, index, EXITED_WITHOUT_PENALTY)

func update_validator_registry*(state: var BeaconState) =
  let
    active_validator_indices =
      get_active_validator_indices(state.validator_registry)
    # The total effective balance of active validators
    total_balance = sum_effective_balances(state, active_validator_indices)

    # The maximum balance churn in Gwei (for deposits and exits separately)
    max_balance_churn = max(
        MAX_DEPOSIT * GWEI_PER_ETH,
        total_balance div (2 * MAX_BALANCE_CHURN_QUOTIENT)
    )

  # Activate validators within the allowable balance churn
  var balance_churn = 0'u64
  for index, validator in state.validator_registry:
    if validator.activation_slot > state.slot + ENTRY_EXIT_DELAY and
      state.validator_balances[index] >= MAX_DEPOSIT * GWEI_PER_ETH:
      # Check the balance churn would be within the allowance
      balance_churn += get_effective_balance(state, index.Uint24)
      if balance_churn > max_balance_churn:
        break

      # Activate validator
      activate_validator(state, index.Uint24, false)

  # Exit validators within the allowable balance churn
  balance_churn = 0
  for index, validator in state.validator_registry:
    if (validator.exit_slot > state.slot + ENTRY_EXIT_DELAY) and
      ((validator.status_flags and INITIATED_EXIT) == INITIATED_EXIT):
      # Check the balance churn would be within the allowance
      balance_churn += get_effective_balance(state, index.Uint24)
      if balance_churn > max_balance_churn:
        break

      # Exit validator
      exit_validator(state, index.Uint24, EXITED_WITHOUT_PENALTY)

  # Perform additional updates
  state.previous_epoch_calculation_slot = state.current_epoch_calculation_slot
  state.previous_epoch_start_shard = state.current_epoch_start_shard
  state.previous_epoch_randao_mix = state.current_epoch_randao_mix
  state.current_epoch_calculation_slot = state.slot
  state.current_epoch_start_shard = (state.current_epoch_start_shard + get_current_epoch_committee_count_per_slot(state) * EPOCH_LENGTH) mod SHARD_COUNT
  state.current_epoch_randao_mix = get_randao_mix(state, state.current_epoch_calculation_slot - SEED_LOOKAHEAD)

  # TODO "If a validator registry update does not happen do the following: ..."

  process_penalties_and_exits(state)

proc checkAttestation*(
    state: BeaconState, attestation: Attestation, flags: UpdateFlags): bool =
  ## Check that an attestation follows the rules of being included in the state
  ## at the current slot. When acting as a proposer, the same rules need to
  ## be followed!
  ##
  ## https://github.com/ethereum/eth2.0-specs/blob/master/specs/core/0_beacon-chain.md#attestations-1

  if not (attestation.data.slot + MIN_ATTESTATION_INCLUSION_DELAY <= state.slot):
    warn("Attestation too new",
      attestation_slot = attestation.data.slot, state_slot = state.slot)
    return

  if not (attestation.data.slot + EPOCH_LENGTH >= state.slot):
    warn("Attestation too old",
      attestation_slot = attestation.data.slot, state_slot = state.slot)
    return

  let expected_justified_slot =
    if attestation.data.slot >= state.slot - (state.slot mod EPOCH_LENGTH):
      state.justified_slot
    else:
      state.previous_justified_slot

  if not (attestation.data.justified_slot == expected_justified_slot):
    warn("Unexpected justified slot",
      attestation_justified_slot = attestation.data.justified_slot,
      expected_justified_slot)
    return

  let expected_justified_block_root =
    get_block_root(state, attestation.data.justified_slot)
  if not (attestation.data.justified_block_root == expected_justified_block_root):
    warn("Unexpected justified block root",
      attestation_justified_block_root = attestation.data.justified_block_root,
      expected_justified_block_root)
    return

  if not (state.latest_crosslinks[attestation.data.shard].shard_block_root in [
      attestation.data.latest_crosslink_root,
      attestation.data.shard_block_root]):
    warn("Unexpected crosslink shard_block_root")
    return

  let
    participants = get_attestation_participants(
      state, attestation.data, attestation.participation_bitfield)
    group_public_key = bls_aggregate_pubkeys(
      participants.mapIt(state.validator_registry[it].pubkey))

  if skipValidation notin flags:
    # Verify that aggregate_signature verifies using the group pubkey.
    let msg = hash_tree_root_final(attestation.data)

    if not bls_verify(
          group_public_key, @(msg.data) & @[0'u8], attestation.aggregate_signature,
          get_domain(state.fork_data, attestation.data.slot, DOMAIN_ATTESTATION)
        ):
      warn("Invalid attestation group signature")
      return

  # To be removed in Phase1:
  if attestation.data.shard_block_root != ZERO_HASH:
    warn("Invalid shard block root")
    return

  true
