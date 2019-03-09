# beacon_chain
# Copyright (c) 2018-2019 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at http://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at http://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  chronicles, math, options, sequtils,
  ../extras, ../ssz,
  ./crypto, ./datatypes, ./digest, ./helpers, ./validator

# https://github.com/ethereum/eth2.0-specs/blob/v0.3.0/specs/core/0_beacon-chain.md#get_effective_balance
func get_effective_balance*(state: BeaconState, index: ValidatorIndex): uint64 =
  ## Return the effective balance (also known as "balance at stake") for a
  ## validator with the given ``index``.
  min(state.validator_balances[index], MAX_DEPOSIT_AMOUNT)

# https://github.com/ethereum/eth2.0-specs/blob/0.4.0/specs/core/0_beacon-chain.md#process_deposit
func process_deposit(state: var BeaconState, deposit: Deposit) =
  ## Process a deposit from Ethereum 1.0.
  ## Note that this function mutates ``state``.

  let deposit_input = deposit.deposit_data.deposit_input

  ## if not validate_proof_of_possession(
  ##     state, pubkey, proof_of_possession, withdrawal_credentials):
  ##   return
  ## TODO re-enable (but it wasn't running to begin with, and
  ## PoP isn't really a phase 0 concern, so this isn't meaningful
  ## regardless.

  let
    validator_pubkeys = state.validator_registry.mapIt(it.pubkey)
    pubkey = deposit_input.pubkey
    amount = deposit.deposit_data.amount
    withdrawal_credentials = deposit_input.withdrawal_credentials

  if pubkey notin validator_pubkeys:
    # Add new validator
    let validator = Validator(
      pubkey: pubkey,
      withdrawal_credentials: withdrawal_credentials,
      activation_epoch: FAR_FUTURE_EPOCH,
      exit_epoch: FAR_FUTURE_EPOCH,
      withdrawable_epoch: FAR_FUTURE_EPOCH,
      initiated_exit: false,
      slashed: false,
    )

    ## Note: In phase 2 registry indices that have been withdrawn for a long
    ## time will be recycled.
    state.validator_registry.add(validator)
    state.validator_balances.add(amount)
  else:
    # Increase balance by deposit amount
    let index = validator_pubkeys.find(pubkey)
    let validator = addr state.validator_registry[index]
    doAssert state.validator_registry[index].withdrawal_credentials ==
      withdrawal_credentials

    state.validator_balances[index] += amount

# https://github.com/ethereum/eth2.0-specs/blob/v0.3.0/specs/core/0_beacon-chain.md#get_delayed_activation_exit_epoch
func get_delayed_activation_exit_epoch*(epoch: Epoch): Epoch =
  ## An entry or exit triggered in the ``epoch`` given by the input takes effect at
  ## the epoch given by the output.
  epoch + 1 + ACTIVATION_EXIT_DELAY

# https://github.com/ethereum/eth2.0-specs/blob/0.4.0/specs/core/0_beacon-chain.md#activate_validator
func activate_validator(state: var BeaconState,
                        index: ValidatorIndex,
                        is_genesis: bool) =
  ## Activate the validator with the given ``index``.
  ## Note that this function mutates ``state``.
  let validator = addr state.validator_registry[index]

  validator.activation_epoch =
    if is_genesis:
      GENESIS_EPOCH
    else:
      get_delayed_activation_exit_epoch(get_current_epoch(state))

# https://github.com/ethereum/eth2.0-specs/blob/0.4.0/specs/core/0_beacon-chain.md#initiate_validator_exit
func initiate_validator_exit*(state: var BeaconState,
                              index: ValidatorIndex) =
  ## Initiate exit for the validator with the given ``index``.
  ## Note that this function mutates ``state``.
  var validator = addr state.validator_registry[index]
  validator.initiated_exit = true

# https://github.com/ethereum/eth2.0-specs/blob/0.4.0/specs/core/0_beacon-chain.md#exit_validator
func exit_validator*(state: var BeaconState,
                     index: ValidatorIndex) =
  ## Exit the validator with the given ``index``.
  ## Note that this function mutates ``state``.

  let validator = addr state.validator_registry[index]

  # The following updates only occur if not previous exited
  if validator.exit_epoch <= get_delayed_activation_exit_epoch(get_current_epoch(state)):
    return

  validator.exit_epoch = get_delayed_activation_exit_epoch(get_current_epoch(state))

func reduce_balance*(balance: var uint64, amount: uint64) =
  # Not in spec, but useful to avoid underflow.
  balance -= min(amount, balance)

# https://github.com/ethereum/eth2.0-specs/blob/0.4.0/specs/core/0_beacon-chain.md#slash_validator
func slash_validator*(state: var BeaconState, index: ValidatorIndex) =
  ## Slash the validator with index ``index``.
  ## Note that this function mutates ``state``.

  let validator = addr state.validator_registry[index]
  doAssert state.slot < get_epoch_start_slot(validator.withdrawable_epoch) ##\
  ## [TO BE REMOVED IN PHASE 2]

  exit_validator(state, index)
  state.latest_slashed_balances[
    (get_current_epoch(state) mod LATEST_SLASHED_EXIT_LENGTH).int
    ] += get_effective_balance(state, index)

  let
    whistleblower_index = get_beacon_proposer_index(state, state.slot)
    whistleblower_reward = get_effective_balance(state, index) div
      WHISTLEBLOWER_REWARD_QUOTIENT

  ## TODO here and elsewhere, if reduce_balance can't reduce balance by full
  ## whistleblower_reward (to prevent underflow) should increase be full? It
  ## seems wrong for the amounts to differ.
  state.validator_balances[whistleblower_index] += whistleblower_reward
  reduce_balance(state.validator_balances[index], whistleblower_reward)
  validator.slashed = true
  validator.withdrawable_epoch =
    get_current_epoch(state) + LATEST_SLASHED_EXIT_LENGTH

func update_shuffling_cache*(state: var BeaconState) =
  let
    list_size = state.validator_registry.len.uint64
    shuffling_seq = mapIt(
      get_shuffled_seq(state.current_shuffling_seed, list_size),
      # No intrinsic reason for this conversion; SSZ requirement artifact.
      it.int)

  doAssert state.shuffling_cache.index in [0, 1]

  # Do a dance to keep everything JSON-encodable.
  state.shuffling_cache.seeds[state.shuffling_cache.index] =
    state.current_shuffling_seed
  state.shuffling_cache.list_sizes[state.shuffling_cache.index] = list_size
  if state.shuffling_cache.index == 0:
    state.shuffling_cache.shuffling_0 = shuffling_seq
  else:
    state.shuffling_cache.shuffling_1 = shuffling_seq
  state.shuffling_cache.index = 1 - state.shuffling_cache.index

# https://github.com/ethereum/eth2.0-specs/blob/0.4.0/specs/core/0_beacon-chain.md#on-genesis
func get_genesis_beacon_state*(
    genesis_validator_deposits: openArray[Deposit],
    genesis_time: uint64,
    latest_eth1_data: Eth1Data,
    flags: UpdateFlags = {}): BeaconState =
  ## Get the genesis ``BeaconState``.
  ##
  ## Before the beacon chain starts, validators will register in the Eth1 chain
  ## and deposit ETH. When enough many validators have registered, a
  ## `ChainStart` log will be emitted and the beacon chain can start beaconing.
  ##
  ## Because the state root hash is part of the genesis block, the beacon state
  ## must be calculated before creating the genesis block.

  # Induct validators
  # Not in spec: the system doesn't work unless there are at least SLOTS_PER_EPOCH
  # validators - there needs to be at least one member in each committee -
  # good to know for testing, though arguably the system is not that useful at
  # at that point :)
  doAssert genesis_validator_deposits.len >= SLOTS_PER_EPOCH

  var state = BeaconState(
    # Misc
    slot: GENESIS_SLOT,
    genesis_time: genesis_time,
    fork: Fork(
        previous_version: GENESIS_FORK_VERSION,
        current_version: GENESIS_FORK_VERSION,
        epoch: GENESIS_EPOCH,
    ),

    validator_registry_update_epoch: GENESIS_EPOCH,

    # validator_registry and validator_balances automatically initalized
    # TODO remove or conditionally compile; not in spec anymore
    validator_registry_delta_chain_tip: ZERO_HASH,

    # Randomness and committees
    # latest_randao_mixes automatically initialized
    previous_shuffling_start_shard: GENESIS_START_SHARD,
    current_shuffling_start_shard: GENESIS_START_SHARD,
    previous_shuffling_epoch: GENESIS_EPOCH,
    current_shuffling_epoch: GENESIS_EPOCH,
    previous_shuffling_seed: ZERO_HASH,
    current_shuffling_seed: ZERO_HASH,

    # Finality
    previous_justified_epoch: GENESIS_EPOCH,
    justified_epoch: GENESIS_EPOCH,
    justification_bitfield: 0,
    finalized_epoch: GENESIS_EPOCH,

    # Deposit root
    latest_eth1_data: latest_eth1_data,

    # Recent state
    # latest_block_roots, latest_active_index_roots, latest_slashed_balances,
    # latest_attestations, and batched_block_roots automatically initialized.
  )

  for i in 0 ..< SHARD_COUNT:
    state.latest_crosslinks[i] = Crosslink(
      epoch: GENESIS_EPOCH, crosslink_data_root: ZERO_HASH)

  # Process genesis deposits
  for deposit in genesis_validator_deposits:
    process_deposit(state, deposit)

  # Process genesis activations
  for validator_index in 0 ..< state.validator_registry.len:
    let vi = validator_index.ValidatorIndex
    if get_effective_balance(state, vi) >= MAX_DEPOSIT_AMOUNT:
      activate_validator(state, vi, true)

  let genesis_active_index_root = Eth2Digest(data: hash_tree_root(
    get_active_validator_indices(state.validator_registry, GENESIS_EPOCH)))
  for index in 0 ..< LATEST_ACTIVE_INDEX_ROOTS_LENGTH:
    state.latest_active_index_roots[index] = genesis_active_index_root
  state.current_shuffling_seed = generate_seed(state, GENESIS_EPOCH)

  # Not in spec.
  update_shuffling_cache(state)

  state

# TODO candidate for spec?
# https://github.com/ethereum/eth2.0-specs/blob/v0.3.0/specs/core/0_beacon-chain.md#on-genesis
func get_initial_beacon_block*(state: BeaconState): BeaconBlock =
  BeaconBlock(
    slot: GENESIS_SLOT,
    state_root: Eth2Digest(data: hash_tree_root(state))
  )

# https://github.com/ethereum/eth2.0-specs/blob/0.4.0/specs/core/0_beacon-chain.md#get_block_root
func get_block_root*(state: BeaconState,
                     slot: Slot): Eth2Digest =
  # Return the block root at a recent ``slot``.

  doAssert state.slot <= slot + LATEST_BLOCK_ROOTS_LENGTH
  doAssert slot < state.slot
  state.latest_block_roots[slot mod LATEST_BLOCK_ROOTS_LENGTH]

# https://github.com/ethereum/eth2.0-specs/blob/v0.3.0/specs/core/0_beacon-chain.md#get_attestation_participants
func get_attestation_participants*(state: BeaconState,
                                   attestation_data: AttestationData,
                                   bitfield: seq[byte]): seq[ValidatorIndex] =
  ## Return the participant indices at for the ``attestation_data`` and
  ## ``bitfield``.
  ## Attestation participants in the attestation data are called out in a
  ## bit field that corresponds to the committee of the shard at the time;
  ## this function converts it to list of indices in to BeaconState.validators
  ##
  ## Returns empty list if the shard is not found
  ## Return the participant indices at for the ``attestation_data`` and ``bitfield``.
  ##
  # TODO Linear search through shard list? borderline ok, it's a small list
  # TODO bitfield type needed, once bit order settles down
  # TODO iterator candidate

  ## Return the participant indices at for the ``attestation_data`` and
  ## ``bitfield``.
  let crosslink_committees = get_crosslink_committees_at_slot(
    state, attestation_data.slot)

  assert anyIt(
    crosslink_committees,
    it[1] == attestation_data.shard)
  let crosslink_committee = mapIt(
    filterIt(crosslink_committees, it.shard == attestation_data.shard),
    it.committee)[0]

  doAssert verify_bitfield(bitfield, len(crosslink_committee))

  # Find the participating attesters in the committee
  result = @[]
  for i, validator_index in crosslink_committee:
    let aggregation_bit = get_bitfield_bit(bitfield, i)
    if aggregation_bit == 1:
      result.add(validator_index)

# https://github.com/ethereum/eth2.0-specs/blob/0.4.0/specs/core/0_beacon-chain.md#ejections
func process_ejections*(state: var BeaconState) =
  ## Iterate through the validator registry and eject active validators with
  ## balance below ``EJECTION_BALANCE``
  for index in get_active_validator_indices(
      # Spec bug in 0.4.0: is just current_epoch(state)
      state.validator_registry, get_current_epoch(state)):
    if state.validator_balances[index] < EJECTION_BALANCE:
      exit_validator(state, index)

# https://github.com/ethereum/eth2.0-specs/blob/0.4.0/specs/core/0_beacon-chain.md#get_total_balance
func get_total_balance*(state: BeaconState, validators: auto): Gwei =
  # Return the combined effective balance of an array of validators.
  foldl(validators, a + get_effective_balance(state, b), 0'u64)

# https://github.com/ethereum/eth2.0-specs/blob/0.4.0/specs/core/0_beacon-chain.md#validator-registry-and-shuffling-seed-data
func update_validator_registry*(state: var BeaconState) =
  ## Update validator registry.
  ## Note that this function mutates ``state``.
  let
    current_epoch = get_current_epoch(state)
    # The active validators
    active_validator_indices =
      get_active_validator_indices(state.validator_registry, current_epoch)
    # The total effective balance of active validators
    total_balance = get_total_balance(state, active_validator_indices)

    # The maximum balance churn in Gwei (for deposits and exits separately)
    max_balance_churn = max(
        MAX_DEPOSIT_AMOUNT,
        total_balance div (2 * MAX_BALANCE_CHURN_QUOTIENT)
    )

  # Activate validators within the allowable balance churn
  var balance_churn = 0'u64
  for index, validator in state.validator_registry:
    if validator.activation_epoch == FAR_FUTURE_EPOCH and
      state.validator_balances[index] >= MAX_DEPOSIT_AMOUNT:
      # Check the balance churn would be within the allowance
      balance_churn += get_effective_balance(state, index.ValidatorIndex)
      if balance_churn > max_balance_churn:
        break

      # Activate validator
      activate_validator(state, index.ValidatorIndex, false)

  # Exit validators within the allowable balance churn
  balance_churn = 0
  for index, validator in state.validator_registry:
    if validator.activation_epoch == FAR_FUTURE_EPOCH and
      validator.initiated_exit:
      # Check the balance churn would be within the allowance
      balance_churn += get_effective_balance(state, index.ValidatorIndex)
      if balance_churn > max_balance_churn:
        break

      # Exit validator
      exit_validator(state, index.ValidatorIndex)

  state.validator_registry_update_epoch = current_epoch

# https://github.com/ethereum/eth2.0-specs/blob/0.4.0/specs/core/0_beacon-chain.md#attestations-1
proc checkAttestation*(
    state: BeaconState, attestation: Attestation, flags: UpdateFlags): bool =
  ## Check that an attestation follows the rules of being included in the state
  ## at the current slot. When acting as a proposer, the same rules need to
  ## be followed!

  if not (attestation.data.slot >= GENESIS_SLOT):
    warn("Attestation predates genesis slot",
      attestation_slot = attestation.data.slot,
      state_slot = humaneSlotNum(state.slot))
    return

  if not (attestation.data.slot + MIN_ATTESTATION_INCLUSION_DELAY <= state.slot):
    warn("Attestation too new",
      attestation_slot = humaneSlotNum(attestation.data.slot),
      state_slot = humaneSlotNum(state.slot))
    return

  if not (state.slot < attestation.data.slot + SLOTS_PER_EPOCH):
    warn("Attestation too old",
      attestation_slot = humaneSlotNum(attestation.data.slot),
      state_slot = humaneSlotNum(state.slot))
    return

  let expected_justified_epoch =
    if slot_to_epoch(attestation.data.slot + 1) >= get_current_epoch(state):
      state.justified_epoch
    else:
      state.previous_justified_epoch

  if not (attestation.data.justified_epoch == expected_justified_epoch):
    warn("Unexpected justified epoch",
      attestation_justified_epoch =
        humaneEpochNum(attestation.data.justified_epoch),
      expected_justified_epoch = humaneEpochNum(expected_justified_epoch))
    return

  let expected_justified_block_root =
    get_block_root(state, get_epoch_start_slot(attestation.data.justified_epoch))
  if not (attestation.data.justified_block_root == expected_justified_block_root):
    warn("Unexpected justified block root",
      attestation_justified_block_root = attestation.data.justified_block_root,
      expected_justified_block_root)
    return

  if not (state.latest_crosslinks[attestation.data.shard] in [
      attestation.data.latest_crosslink,
      Crosslink(
        crosslink_data_root: attestation.data.crosslink_data_root,
        epoch: slot_to_epoch(attestation.data.slot))]):
    warn("Unexpected crosslink shard",
      state_latest_crosslinks_attestation_data_shard =
        state.latest_crosslinks[attestation.data.shard],
      attestation_data_latest_crosslink = attestation.data.latest_crosslink,
      epoch = humaneEpochNum(slot_to_epoch(attestation.data.slot)),
      crosslink_data_root = attestation.data.crosslink_data_root)
    return

  assert allIt(attestation.custody_bitfield, it == 0) #TO BE REMOVED IN PHASE 1
  assert anyIt(attestation.aggregation_bitfield, it != 0)

  let crosslink_committee = mapIt(
    filterIt(get_crosslink_committees_at_slot(state, attestation.data.slot),
             it.shard == attestation.data.shard),
    it.committee)[0]

  # Extra checks not in specs
  # https://github.com/status-im/nim-beacon-chain/pull/105#issuecomment-462432544
  assert attestation.aggregation_bitfield.len == (
            crosslink_committee.len + 7) div 8, (
              "Error: got " & $attestation.aggregation_bitfield.len &
              " but expected " & $((crosslink_committee.len + 7) div 8)
            )

  assert attestation.custody_bitfield.len == (
            crosslink_committee.len + 7) div 8, (
              "Error: got " & $attestation.custody_bitfield.len &
              " but expected " & $((crosslink_committee.len + 7) div 8)
            )
  # End extra checks

  assert allIt(0 ..< len(crosslink_committee),
    if get_bitfield_bit(attestation.aggregation_bitfield, it) == 0b0:
      # Should always be true in phase 0, because of above assertion
      get_bitfield_bit(attestation.custody_bitfield, it) == 0b0
    else:
      true)

  let
    participants = get_attestation_participants(
      state, attestation.data, attestation.aggregation_bitfield)

    ## TODO when the custody_bitfield assertion-to-emptiness disappears do this
    ## and fix the custody_bit_0_participants check to depend on it.
    # custody_bit_1_participants = {nothing, always, because assertion above}
    custody_bit_1_participants: seq[ValidatorIndex] = @[]
    custody_bit_0_participants = participants

  if skipValidation notin flags:
    # Verify that aggregate_signature verifies using the group pubkey.
    assert bls_verify_multiple(
      @[
        bls_aggregate_pubkeys(mapIt(custody_bit_0_participants,
                                    state.validator_registry[it].pubkey)),
        bls_aggregate_pubkeys(mapIt(custody_bit_1_participants,
                                    state.validator_registry[it].pubkey)),
      ],
      @[
        hash_tree_root(AttestationDataAndCustodyBit(
          data: attestation.data, custody_bit: false)),
        hash_tree_root(AttestationDataAndCustodyBit(
          data: attestation.data, custody_bit: true)),
      ],
      attestation.aggregate_signature,
      get_domain(state.fork, slot_to_epoch(attestation.data.slot),
                 DOMAIN_ATTESTATION),
    )

  # To be removed in Phase1:
  if attestation.data.crosslink_data_root != ZERO_HASH:
    warn("Invalid crosslink data root")
    return

  true

# https://github.com/ethereum/eth2.0-specs/blob/0.4.0/specs/core/0_beacon-chain.md#prepare_validator_for_withdrawal
func prepare_validator_for_withdrawal*(state: var BeaconState, index: ValidatorIndex) =
  ## Set the validator with the given ``index`` as withdrawable
  ## ``MIN_VALIDATOR_WITHDRAWABILITY_DELAY`` after the current epoch.
  ## Note that this function mutates ``state``.
  var validator = addr state.validator_registry[index]
  validator.withdrawable_epoch = get_current_epoch(state) +
    MIN_VALIDATOR_WITHDRAWABILITY_DELAY
