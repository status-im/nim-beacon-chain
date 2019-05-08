# beacon_chain
# Copyright (c) 2018-2019 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at http://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at http://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  chronicles, math, options, sequtils,
  ../extras, ../ssz, ../beacon_node_types,
  ./bitfield, ./crypto, ./datatypes, ./digest, ./helpers, ./validator,
  tables

# https://github.com/ethereum/eth2.0-specs/blob/v0.5.0/specs/core/0_beacon-chain.md#get_effective_balance
func get_effective_balance*(state: BeaconState, index: ValidatorIndex): Gwei =
  ## Return the effective balance (also known as "balance at stake") for a
  ## validator with the given ``index``.
  min(state.balances[index], MAX_EFFECTIVE_BALANCE)

# https://github.com/ethereum/eth2.0-specs/blob/v0.6.0/specs/core/0_beacon-chain.md#verify_merkle_branch
func verify_merkle_branch(leaf: Eth2Digest, proof: openarray[Eth2Digest], depth: uint64, index: uint64, root: Eth2Digest): bool =
  ## Verify that the given ``leaf`` is on the merkle branch ``proof``
  ## starting with the given ``root``.
  var
    value = leaf
    buf: array[64, byte]

  for i in 0 ..< depth.int:
    if (index div (1'u64 shl i)) mod 2 != 0:
      buf[0..31] = proof[i.int].data
      buf[32..63] = value.data
    else:
      buf[0..31] = value.data
      buf[32..63] = proof[i.int].data
    value = eth2hash(buf)
  value == root

# https://github.com/ethereum/eth2.0-specs/blob/v0.6.0/specs/core/0_beacon-chain.md#increase_balance
func increase_balance*(
    state: var BeaconState, index: ValidatorIndex, delta: Gwei) =
  # Increase validator balance by ``delta``.
  state.balances[index] += delta

# https://github.com/ethereum/eth2.0-specs/blob/v0.6.0/specs/core/0_beacon-chain.md#decrease_balance
func decrease_balance*(
    state: var BeaconState, index: ValidatorIndex, delta: Gwei) =
  # Decrease validator balance by ``delta`` with underflow protection.
  state.balances[index] =
    if delta > state.balances[index]:
      0'u64
    else:
      state.balances[index] - delta

# https://github.com/ethereum/eth2.0-specs/blob/v0.6.1/specs/core/0_beacon-chain.md#deposits
func process_deposit*(
    state: var BeaconState, deposit: Deposit, flags: UpdateFlags = {}): bool =
  # Process an Eth1 deposit, registering a validator or increasing its balance.

  # Verify the Merkle branch
  # TODO enable this check, but don't use doAssert
  if not verify_merkle_branch(
    hash_tree_root(deposit.data),
     deposit.proof,
     DEPOSIT_CONTRACT_TREE_DEPTH,
     deposit.index,
    state.latest_eth1_data.deposit_root,
  ):
    ## TODO: a notice-like mechanism which works in a func
    ## here and elsewhere, one minimal approach is a check-if-true
    ## and return false iff so.
    ## obviously, better/more principled ones exist, but
    ## generally require broader rearchitecting, and this is what
    ## mostly happens now, just haphazardly.
    discard

  # Deposits must be processed in order
  if not (deposit.index == state.deposit_index):
    ## TODO see above, re errors
    ## it becomes even more important, as one might might sometimes want
    ## to flag such things as higher/lower priority. chronicles?
    return false

  state.deposit_index += 1

  let
    pubkey = deposit.data.pubkey
    amount = deposit.data.amount
    validator_pubkeys = mapIt(state.validator_registry, it.pubkey)
    index = validator_pubkeys.find(pubkey)

  if index == -1:
    # Verify the deposit signature (proof of possession)
    # TODO should be get_domain(state, DOMAIN_DEPOSIT)
    if skipValidation notin flags and not bls_verify(
        pubkey, signing_root(deposit.data).data, deposit.data.signature,
        3'u64):
      return false

    # Add validator and balance entries
    state.validator_registry.add(Validator(
      pubkey: pubkey,
      withdrawal_credentials: deposit.data.withdrawal_credentials,
      activation_eligibility_epoch: FAR_FUTURE_EPOCH,
      activation_epoch: FAR_FUTURE_EPOCH,
      exit_epoch: FAR_FUTURE_EPOCH,
      withdrawable_epoch: FAR_FUTURE_EPOCH,
      effective_balance: min(amount - amount mod EFFECTIVE_BALANCE_INCREMENT,
        MAX_EFFECTIVE_BALANCE)
    ))
    state.balances.add(amount)
  else:
     # Increase balance by deposit amount
     increase_balance(state, index.ValidatorIndex, amount)

  true

# https://github.com/ethereum/eth2.0-specs/blob/v0.6.0/specs/core/0_beacon-chain.md#get_delayed_activation_exit_epoch
func get_delayed_activation_exit_epoch*(epoch: Epoch): Epoch =
  ## Return the epoch at which an activation or exit triggered in ``epoch``
  ## takes effect.
  epoch + 1 + ACTIVATION_EXIT_DELAY

# https://github.com/ethereum/eth2.0-specs/blob/v0.5.0/specs/core/0_beacon-chain.md#activate_validator
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

# https://github.com/ethereum/eth2.0-specs/blob/v0.5.0/specs/core/0_beacon-chain.md#initiate_validator_exit
func initiate_validator_exit*(state: var BeaconState,
                              index: ValidatorIndex) =
  ## Initiate exit for the validator with the given ``index``.
  ## Note that this function mutates ``state``.
  var validator = addr state.validator_registry[index]
  validator.initiated_exit = true

# https://github.com/ethereum/eth2.0-specs/blob/v0.5.0/specs/core/0_beacon-chain.md#exit_validator
func exit_validator*(state: var BeaconState,
                     index: ValidatorIndex) =
  ## Exit the validator with the given ``index``.
  ## Note that this function mutates ``state``.

  let
    validator = addr state.validator_registry[index]
    delayed_activation_exit_epoch =
      get_delayed_activation_exit_epoch(get_current_epoch(state))

  # The following updates only occur if not previous exited
  if validator.exit_epoch <= delayed_activation_exit_epoch:
    return

  validator.exit_epoch = delayed_activation_exit_epoch

func reduce_balance*(balance: var uint64, amount: uint64) =
  # Not in spec, but useful to avoid underflow.
  balance -= min(amount, balance)

# https://github.com/ethereum/eth2.0-specs/blob/v0.5.0/specs/core/0_beacon-chain.md#slash_validator
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
  state.balances[whistleblower_index] += whistleblower_reward
  reduce_balance(state.balances[index], whistleblower_reward)
  validator.slashed = true
  validator.withdrawable_epoch =
    get_current_epoch(state) + LATEST_SLASHED_EXIT_LENGTH

# https://github.com/ethereum/eth2.0-specs/blob/v0.5.1/specs/core/0_beacon-chain.md#get_temporary_block_header
func get_temporary_block_header*(blck: BeaconBlock): BeaconBlockHeader =
  ## Return the block header corresponding to a block with ``state_root`` set
  ## to ``ZERO_HASH``.
  BeaconBlockHeader(
    slot: blck.slot,
    previous_block_root: blck.previous_block_root,
    state_root: ZERO_HASH,
    block_body_root: hash_tree_root(blck.body),
    # signing_root(block) is used for block id purposes so signature is a stub
    signature: EMPTY_SIGNATURE,
  )

# https://github.com/ethereum/eth2.0-specs/blob/v0.5.1/specs/core/0_beacon-chain.md#on-genesis
func get_empty_block*(): BeaconBlock =
  # Nim default values fill this in mostly correctly.
  BeaconBlock(slot: GENESIS_SLOT)

func get_genesis_beacon_state*(
    genesis_validator_deposits: openArray[Deposit],
    genesis_time: uint64,
    genesis_eth1_data: Eth1Data,
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

    # validator_registry and balances automatically initalized

    # Randomness and committees
    # latest_randao_mixes automatically initialized
    previous_shuffling_start_shard: GENESIS_START_SHARD,
    current_shuffling_start_shard: GENESIS_START_SHARD,
    previous_shuffling_epoch: GENESIS_EPOCH,
    current_shuffling_epoch: GENESIS_EPOCH,
    previous_shuffling_seed: ZERO_HASH,
    current_shuffling_seed: ZERO_HASH,

    # Finality
    # previous_epoch_attestations and current_epoch_attestations automatically
    # initialized
    previous_justified_epoch: GENESIS_EPOCH,
    current_justified_epoch: GENESIS_EPOCH,
    justification_bitfield: 0,
    finalized_epoch: GENESIS_EPOCH,
    finalized_root: ZERO_HASH,

    # Recent state
    # latest_block_roots, latest_state_roots, latest_active_index_roots,
    # latest_slashed_balances, and latest_slashed_balances automatically
    # initialized
    latest_block_header: get_temporary_block_header(get_empty_block()),

    # Ethereum 1.0 chain data
    # eth1_data_votes automatically initialized
    latest_eth1_data: genesis_eth1_data,
    deposit_index: 0,
  )

  for i in 0 ..< SHARD_COUNT:
    state.latest_crosslinks[i] = Crosslink(
      epoch: GENESIS_EPOCH, crosslink_data_root: ZERO_HASH)

  # Process genesis deposits
  for deposit in genesis_validator_deposits:
    discard process_deposit(state, deposit, flags)

  # Process genesis activations
  for validator_index in 0 ..< state.validator_registry.len:
    let vi = validator_index.ValidatorIndex
    if get_effective_balance(state, vi) >= MAX_EFFECTIVE_BALANCE:
      activate_validator(state, vi, true)

  let genesis_active_index_root = hash_tree_root(
    get_active_validator_indices(state, GENESIS_EPOCH))
  for index in 0 ..< LATEST_ACTIVE_INDEX_ROOTS_LENGTH:
    state.latest_active_index_roots[index] = genesis_active_index_root
  state.current_shuffling_seed = generate_seed(state, GENESIS_EPOCH)

  state

# TODO candidate for spec?
# https://github.com/ethereum/eth2.0-specs/blob/0.5.1/specs/core/0_beacon-chain.md#on-genesis
func get_initial_beacon_block*(state: BeaconState): BeaconBlock =
  BeaconBlock(
    slot: GENESIS_SLOT,
    state_root: hash_tree_root(state)
    # parent_root, randao_reveal, eth1_data, signature, and body automatically
    # initialized to default values.
  )

# https://github.com/ethereum/eth2.0-specs/blob/v0.5.0/specs/core/0_beacon-chain.md#get_block_root
func get_block_root*(state: BeaconState,
                     slot: Slot): Eth2Digest =
  # Return the block root at a recent ``slot``.

  doAssert state.slot <= slot + SLOTS_PER_HISTORICAL_ROOT
  doAssert slot < state.slot
  state.latest_block_roots[slot mod SLOTS_PER_HISTORICAL_ROOT]

# https://github.com/ethereum/eth2.0-specs/blob/v0.5.1/specs/core/0_beacon-chain.md#get_attestation_participants
func get_attestation_participants*(state: BeaconState,
                                   attestation_data: AttestationData,
                                   bitfield: BitField): seq[ValidatorIndex] =
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
  # TODO iterator candidate

  # Find the committee in the list with the desired shard
  let crosslink_committees = get_crosslink_committees_at_slot(
    state, attestation_data.slot)

  doAssert anyIt(
    crosslink_committees,
    it[1] == attestation_data.shard)
  let crosslink_committee = mapIt(
    filterIt(crosslink_committees, it.shard == attestation_data.shard),
    it.committee)[0]

  # TODO this and other attestation-based fields need validation so we don't
  #      crash on a malicious attestation!
  doAssert verify_bitfield(bitfield, len(crosslink_committee))

  # Find the participating attesters in the committee
  result = @[]
  for i, validator_index in crosslink_committee:
    let aggregation_bit = get_bitfield_bit(bitfield, i)
    if aggregation_bit:
      result.add(validator_index)

iterator get_attestation_participants_cached*(state: BeaconState,
                                   attestation_data: AttestationData,
                                   bitfield: BitField,
                                   cache: var StateCache): ValidatorIndex =
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
  # TODO iterator candidate

  # Find the committee in the list with the desired shard
  # let crosslink_committees = get_crosslink_committees_at_slot_cached(
  #   state, attestation_data.slot, false, crosslink_committees_cached)

  var found = false
  for crosslink_committee in get_crosslink_committees_at_slot_cached(
      state, attestation_data.slot, false, cache):
    if crosslink_committee.shard == attestation_data.shard:
      # TODO this and other attestation-based fields need validation so we don't
      #      crash on a malicious attestation!
      doAssert verify_bitfield(bitfield, len(crosslink_committee.committee))

      # Find the participating attesters in the committee
      for i, validator_index in crosslink_committee.committee:
        let aggregation_bit = get_bitfield_bit(bitfield, i)
        if aggregation_bit:
          yield validator_index
      found = true
      break
  doAssert found, "Couldn't find crosslink committee"

# https://github.com/ethereum/eth2.0-specs/blob/v0.5.0/specs/core/0_beacon-chain.md#ejections
func process_ejections*(state: var BeaconState) =
  ## Iterate through the validator registry and eject active validators with
  ## balance below ``EJECTION_BALANCE``
  for index in get_active_validator_indices(
      state, get_current_epoch(state)):
    if state.balances[index] < EJECTION_BALANCE:
      exit_validator(state, index)

# https://github.com/ethereum/eth2.0-specs/blob/v0.5.0/specs/core/0_beacon-chain.md#get_total_balance
func get_total_balance*(state: BeaconState, validators: auto): Gwei =
  # Return the combined effective balance of an array of validators.
  foldl(validators, a + get_effective_balance(state, b), 0'u64)

# https://github.com/ethereum/eth2.0-specs/blob/v0.5.0/specs/core/0_beacon-chain.md#validator-registry-and-shuffling-seed-data
func should_update_validator_registry*(state: BeaconState): bool =
  # Must have finalized a new block
  if state.finalized_epoch <= state.validator_registry_update_epoch:
    return false
  # Must have processed new crosslinks on all shards of the current epoch
  allIt(0 ..< get_epoch_committee_count(state, get_current_epoch(state)).int,
        not (state.latest_crosslinks[
          ((state.current_shuffling_start_shard + it.uint64) mod
            SHARD_COUNT).int].epoch <= state.validator_registry_update_epoch))

func update_validator_registry*(state: var BeaconState) =
  ## Update validator registry.
  ## Note that this function mutates ``state``.
  let
    current_epoch = get_current_epoch(state)
    # The active validators
    active_validator_indices =
      get_active_validator_indices(state, current_epoch)
    # The total effective balance of active validators
    total_balance = get_total_balance(state, active_validator_indices)

    # The maximum balance churn in Gwei (for deposits and exits separately)
    max_balance_churn = max(
        MAX_EFFECTIVE_BALANCE,
        total_balance div (2 * MAX_BALANCE_CHURN_QUOTIENT)
    )

  # Activate validators within the allowable balance churn
  var balance_churn = 0'u64
  for index, validator in state.validator_registry:
    if validator.activation_epoch == FAR_FUTURE_EPOCH and
      state.balances[index] >= MAX_EFFECTIVE_BALANCE:
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

# https://github.com/ethereum/eth2.0-specs/blob/v0.5.1/specs/core/0_beacon-chain.md#attestations
proc checkAttestation*(
    state: BeaconState, attestation: Attestation, flags: UpdateFlags): bool =
  ## Check that an attestation follows the rules of being included in the state
  ## at the current slot. When acting as a proposer, the same rules need to
  ## be followed!

  let stateSlot =
    if nextSlot in flags: state.slot + 1
    else: state.slot

  # Can't submit attestations that are too far in history (or in prehistory)
  if not (attestation.data.slot >= GENESIS_SLOT):
    warn("Attestation predates genesis slot",
      attestation_slot = attestation.data.slot,
      state_slot = humaneSlotNum(stateSlot))
    return

  if not (stateSlot <= attestation.data.slot + SLOTS_PER_EPOCH):
    warn("Attestation too old",
      attestation_slot = humaneSlotNum(attestation.data.slot),
      state_slot = humaneSlotNum(stateSlot))
    return

  # Can't submit attestations too quickly
  if not (
      attestation.data.slot + MIN_ATTESTATION_INCLUSION_DELAY <= stateSlot):
    warn("Attestation too new",
      attestation_slot = humaneSlotNum(attestation.data.slot),
      state_slot = humaneSlotNum(stateSlot))
    return

  # # Verify that the justified epoch and root is correct
  if slot_to_epoch(attestation.data.slot) >= stateSlot.slot_to_epoch():
    # Case 1: current epoch attestations
    if not (attestation.data.source_epoch == state.current_justified_epoch):
      warn("Source epoch is not current justified epoch",
        attestation_slot = humaneSlotNum(attestation.data.slot),
        state_slot = humaneSlotNum(stateSlot))
      return

    if not (attestation.data.source_root == state.current_justified_root):
      warn("Source root is not current justified root",
        attestation_slot = humaneSlotNum(attestation.data.slot),
        state_slot = humaneSlotNum(stateSlot))
      return
  else:
    # Case 2: previous epoch attestations
    if not (attestation.data.source_epoch == state.previous_justified_epoch):
      warn("Source epoch is not previous justified epoch",
        attestation_slot = humaneSlotNum(attestation.data.slot),
        state_slot = humaneSlotNum(stateSlot))
      return

    if not (attestation.data.source_root == state.previous_justified_root):
      warn("Source root is not previous justified root",
        attestation_slot = humaneSlotNum(attestation.data.slot),
        state_slot = humaneSlotNum(stateSlot))
      return

  # Check that the crosslink data is valid
  let acceptable_crosslink_data = @[
    # Case 1: Latest crosslink matches the one in the state
    attestation.data.previous_crosslink,

    # Case 2: State has already been updated, state's latest crosslink matches
    # the crosslink the attestation is trying to create
    Crosslink(
      crosslink_data_root: attestation.data.crosslink_data_root,
      epoch: slot_to_epoch(attestation.data.slot)
    )
  ]
  if not (state.latest_crosslinks[attestation.data.shard] in
      acceptable_crosslink_data):
    warn("Unexpected crosslink shard",
      state_latest_crosslinks_attestation_data_shard =
        state.latest_crosslinks[attestation.data.shard],
      attestation_data_previous_crosslink = attestation.data.previous_crosslink,
      epoch = humaneEpochNum(slot_to_epoch(attestation.data.slot)),
      actual_epoch = slot_to_epoch(attestation.data.slot),
      crosslink_data_root = attestation.data.crosslink_data_root,
      acceptable_crosslink_data = acceptable_crosslink_data)
    return

  # Attestation must be nonempty!
  if not anyIt(attestation.aggregation_bitfield.bits, it != 0):
    warn("No signature bits")
    return

  # Custody must be empty (to be removed in phase 1)
  if not allIt(attestation.custody_bitfield.bits, it == 0):
    warn("Custody bits set in phase0")
    return

  # Get the committee for the specific shard that this attestation is for
  let crosslink_committee = mapIt(
    filterIt(get_crosslink_committees_at_slot(state, attestation.data.slot),
             it.shard == attestation.data.shard),
    it.committee)[0]

  # Custody bitfield must be a subset of the attestation bitfield
  if not allIt(0 ..< len(crosslink_committee),
      if not get_bitfield_bit(attestation.aggregation_bitfield, it):
        not get_bitfield_bit(attestation.custody_bitfield, it)
      else:
        true):
    warn("Wrong custody bits set")
    return

  # Verify aggregate signature
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
    if not bls_verify_multiple(
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
      get_domain(state, DOMAIN_ATTESTATION,
                 slot_to_epoch(attestation.data.slot))
    ):
      warn("Invalid attestation signature")
      return

  # Crosslink data root is zero (to be removed in phase 1)
  if attestation.data.crosslink_data_root != ZERO_HASH:
    warn("Invalid crosslink data root")
    return

  true

# https://github.com/ethereum/eth2.0-specs/blob/v0.5.0/specs/core/0_beacon-chain.md#prepare_validator_for_withdrawal
func prepare_validator_for_withdrawal*(state: var BeaconState, index: ValidatorIndex) =
  ## Set the validator with the given ``index`` as withdrawable
  ## ``MIN_VALIDATOR_WITHDRAWABILITY_DELAY`` after the current epoch.
  ## Note that this function mutates ``state``.
  var validator = addr state.validator_registry[index]
  validator.withdrawable_epoch = get_current_epoch(state) +
    MIN_VALIDATOR_WITHDRAWABILITY_DELAY

proc makeAttestationData*(
    state: BeaconState, shard: uint64,
    beacon_block_root: Eth2Digest): AttestationData =
  ## Fine points:
  ## Head must be the head state during the slot that validator is
  ## part of committee - notably, it can't be a newer or older state (!)

  let
    epoch_start_slot = get_epoch_start_slot(slot_to_epoch(state.slot))
    target_root =
      if epoch_start_slot == state.slot: beacon_block_root
      else: get_block_root(state, epoch_start_slot)

  AttestationData(
    slot: state.slot,
    shard: shard,
    beacon_block_root: beacon_block_root,
    target_root: target_root,
    crosslink_data_root: Eth2Digest(), # Stub in phase0
    previous_crosslink: state.latest_crosslinks[shard],
    source_epoch: state.current_justified_epoch,
    source_root: state.current_justified_root
  )
