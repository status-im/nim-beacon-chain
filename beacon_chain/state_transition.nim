# beacon_chain
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at http://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at http://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

# State transition, as described in
# https://github.com/ethereum/eth2.0-specs/blob/master/specs/core/0_beacon-chain.md#beacon-chain-state-transition-function
#
# The purpose of this code right is primarily educational, to help piece
# together the mechanics of the beacon state and to discover potential problem
# areas. The entry point is `updateState` which is at the bottom of the file!
#
# General notes about the code (TODO):
# * It's inefficient - we quadratically copy, allocate and iterate when there
#   are faster options
# * Weird styling - the sections taken from the spec use python styling while
#   the others use NEP-1 - helps grepping identifiers in spec
# * We mix procedural and functional styles for no good reason, except that the
#   spec does so also.
# * There are no tests, and likely lots of bugs.
# * For indices, we get a mix of uint64, Uint24 and int - this is currently
#   swept under the rug with casts
# * The spec uses uint64 for data types, but functions in the spec often assume
#   signed bigint semantics - under- and overflows ensue
# * Sane error handling is missing in most cases (yay, we'll get the chance to
#   debate exceptions again!)
# When updating the code, add TODO sections to mark where there are clear
# improvements to be made - other than that, keep things similar to spec for
# now.

import
  chronicles, math, options, sequtils,
  ./extras, ./ssz,
  ./spec/[beaconstate, crypto, datatypes, digest, helpers, validator],
  milagro_crypto

func flatten[T](v: openArray[seq[T]]): seq[T] =
  # TODO not in nim - doh.
  for x in v: result.add x

func verifyProposerSignature(state: BeaconState, blck: BeaconBlock): bool =
  ## When creating a block, the proposer will sign a version of the block that
  ## doesn't contain the data (chicken and egg), then add the signature to that
  ## block. Here, we check that the signature is correct by repeating the same
  ## process.
  ##
  ## https://github.com/ethereum/eth2.0-specs/blob/master/specs/core/0_beacon-chain.md#proposer-signature
  var blck_without_sig = blck
  blck_without_sig.signature = ValidatorSig()

  let
    signed_data = ProposalSignedData(
      slot: state.slot,
      shard: BEACON_CHAIN_SHARD_NUMBER,
      block_root: hash_tree_root_final(blck_without_sig)
    )
    proposal_hash = hash_tree_root_final(signed_data)
    proposer_index = get_beacon_proposer_index(state, state.slot)

  bls_verify(
    state.validator_registry[proposer_index].pubkey,
    proposal_hash.data, blck.signature,
    get_domain(state.fork_data, state.slot, DOMAIN_PROPOSAL))

func processRandao(
    state: var BeaconState, blck: BeaconBlock, flags: UpdateFlags): bool =
  ## When a validator signs up, they will include a hash number together with
  ## the deposit - the randao_commitment. The commitment is formed by hashing
  ## a secret value N times.
  ## The first time the proposer proposes a block, they will hash their secret
  ## value N-1 times, and provide the reuslt as "reveal" - now everyone else can
  ## verify that the reveal matches the commitment by hashing it once.
  ## The next time the proposer proposes, they will reveal the secret value
  ## hashed N-2 times and so on, and everyone will verify that it matches N-1.
  ## The previous reveal has now become the commitment!
  ##
  ## Effectively, the block proposer can only reveal N-1 times, so better pick
  ## a large N!
  ##
  ## https://github.com/ethereum/eth2.0-specs/blob/master/specs/core/0_beacon-chain.md#randao
  let
    proposer_index = get_beacon_proposer_index(state, state.slot)
    proposer = addr state.validator_registry[proposer_index]

  if skipValidation notin flags:
    # Check that proposer commit and reveal match
    if repeat_hash(blck.randao_reveal, proposer.randao_layers) !=
        proposer.randao_commitment:
      return false

  # Update state and proposer now that we're alright
  let mix = state.slot mod LATEST_RANDAO_MIXES_LENGTH
  for i, b in state.latest_randao_mixes[mix].data:
    state.latest_randao_mixes[mix].data[i] = b xor blck.randao_reveal.data[i]

  proposer.randao_commitment = blck.randao_reveal
  proposer.randao_layers = 0

  return true

func processDepositRoot(state: var BeaconState, blck: BeaconBlock) =
  ## https://github.com/ethereum/eth2.0-specs/blob/master/specs/core/0_beacon-chain.md#deposit-root

  for x in state.deposit_roots.mitems():
    if blck.deposit_root == x.deposit_root:
      x.vote_count += 1
      return

  state.deposit_roots.add DepositRootVote(
    deposit_root: blck.deposit_root,
    vote_count: 1
  )

func penalizeValidator(state: var BeaconState, index: Uint24) =
  exit_validator(state, index)
  var validator = state.validator_registry[index]
  #state.latest_penalized_exit_balances[(state.slot div EPOCH_LENGTH) mod LATEST_PENALIZED_EXIT_LENGTH] += get_effective_balance(state, index.Uint24)

  let
    whistleblower_index = get_beacon_proposer_index(state, state.slot)
    whistleblower_reward = get_effective_balance(state, index) div WHISTLEBLOWER_REWARD_QUOTIENT
  state.validator_balances[whistleblower_index] += whistleblower_reward
  state.validator_balances[index] -= whistleblower_reward
  validator.penalized_slot = state.slot

proc processProposerSlashings(
    state: var BeaconState, blck: BeaconBlock, flags: UpdateFlags): bool =
  ## https://github.com/ethereum/eth2.0-specs/blob/master/specs/core/0_beacon-chain.md#proposer-slashings-1

  if len(blck.body.proposer_slashings) > MAX_PROPOSER_SLASHINGS:
    warn("PropSlash: too many!",
      proposer_slashings = len(blck.body.proposer_slashings))
    return false

  for proposer_slashing in blck.body.proposer_slashings:
    let proposer = state.validator_registry[proposer_slashing.proposer_index]
    if skipValidation notin flags:
      if not bls_verify(
          proposer.pubkey,
          hash_tree_root_final(proposer_slashing.proposal_data_1).data,
          proposer_slashing.proposal_signature_1,
          get_domain(
            state.fork_data, proposer_slashing.proposal_data_1.slot,
            DOMAIN_PROPOSAL)):
        warn("PropSlash: invalid signature 1")
        return false
      if not bls_verify(
          proposer.pubkey,
          hash_tree_root_final(proposer_slashing.proposal_data_2).data,
          proposer_slashing.proposal_signature_2,
          get_domain(
            state.fork_data, proposer_slashing.proposal_data_2.slot,
            DOMAIN_PROPOSAL)):
        warn("PropSlash: invalid signature 2")
        return false

    if not (proposer_slashing.proposal_data_1.slot ==
        proposer_slashing.proposal_data_2.slot):
      warn("PropSlash: slot mismatch")
      return false

    if not (proposer_slashing.proposal_data_1.shard ==
        proposer_slashing.proposal_data_2.shard):
      warn("PropSlash: shard mismatch")
      return false

    if not (proposer_slashing.proposal_data_1.block_root ==
        proposer_slashing.proposal_data_2.block_root):
      warn("PropSlash: block root mismatch")
      return false

    if not (proposer.penalized_slot > state.slot):
      warn("PropSlash: penalized slot")
      return false

    penalizeValidator(state, proposer_slashing.proposer_index)

  return true

func verify_slashable_vote_data(state: BeaconState, vote_data: SlashableVoteData): bool =
  if len(vote_data.aggregate_signature_poc_0_indices) +
      len(vote_data.aggregate_signature_poc_1_indices) > MAX_CASPER_VOTES:
    return false

  let pubs = [
    bls_aggregate_pubkeys(vote_data.aggregate_signature_poc_0_indices.
      mapIt(state.validator_registry[it].pubkey)),
    bls_aggregate_pubkeys(vote_data.aggregate_signature_poc_1_indices.
      mapIt(state.validator_registry[it].pubkey))]

  # TODO
  # return bls_verify_multiple(pubs, [hash_tree_root(votes)+bytes1(0), hash_tree_root(votes)+bytes1(1), signature=aggregate_signature)

  return true

proc indices(vote: SlashableVoteData): seq[Uint24] =
  vote.aggregate_signature_poc_0_indices &
    vote.aggregate_signature_poc_1_indices

proc processCasperSlashings(state: var BeaconState, blck: BeaconBlock): bool =
  ## https://github.com/ethereum/eth2.0-specs/blob/master/specs/core/0_beacon-chain.md#casper-slashings-1
  if len(blck.body.casper_slashings) > MAX_CASPER_SLASHINGS:
    warn("CaspSlash: too many!")
    return false

  for casper_slashing in blck.body.casper_slashings:
    let
      slashable_vote_data_1 = casper_slashing.slashable_vote_data_1
      slashable_vote_data_2 = casper_slashing.slashable_vote_data_2
      indices2 = indices(slashable_vote_data_2)
      intersection =
        indices(slashable_vote_data_1).filterIt(it in indices2)

    if not (slashable_vote_data_1.data != slashable_vote_data_2.data):
      warn("CaspSlash: invalid data")
      return false

    if not (len(intersection) >= 1):
      warn("CaspSlash: no intersection")
      return false

    if not (
      is_double_vote(slashable_vote_data_1.data, slashable_vote_data_2.data) or
      is_surround_vote(slashable_vote_data_1.data, slashable_vote_data_2.data)):
      warn("CaspSlash: surround or double vote check failed")
      return false

    if not verify_slashable_vote_data(state, slashable_vote_data_1):
      warn("CaspSlash: invalid votes 1")
      return false

    if not verify_slashable_vote_data(state, slashable_vote_data_2):
      warn("CaspSlash: invalid votes 2")
      return false

    for i in intersection:
      if state.validator_registry[i].penalized_slot > state.slot:
        penalize_validator(state, i)

  return true

proc processAttestations(
    state: var BeaconState, blck: BeaconBlock, flags: UpdateFlags): bool =
  ## Each block includes a number of attestations that the proposer chose. Each
  ## attestation represents an update to a specific shard and is signed by a
  ## committee of validators.
  ## Here we make sanity checks for each attestation and it to the state - most
  ## updates will happen at the epoch boundary where state updates happen in
  ## bulk.
  ##
  ## https://github.com/ethereum/eth2.0-specs/blob/master/specs/core/0_beacon-chain.md#attestations-1
  if blck.body.attestations.len > MAX_ATTESTATIONS:
    warn("Attestation: too many!", attestations = blck.body.attestations.len)
    return false

  if not blck.body.attestations.allIt(checkAttestation(state, it, flags)):
    return false

  # All checks passed - update state
  state.latest_attestations.add blck.body.attestations.mapIt(
    PendingAttestationRecord(
      data: it.data,
      participation_bitfield: it.participation_bitfield,
      custody_bitfield: it.custody_bitfield,
      slot_included: state.slot,
    )
  )

  return true

proc processDeposits(state: var BeaconState, blck: BeaconBlock): bool =
  ## https://github.com/ethereum/eth2.0-specs/blob/master/specs/core/0_beacon-chain.md#deposits-1
  # TODO! Spec writing in progress
  true

func initiate_validator_exit(state: var BeaconState, index: int) =
  var validator = state.validator_registry[index]
  validator.status_flags = validator.status_flags or INITIATED_EXIT

proc processExits(
    state: var BeaconState, blck: BeaconBlock, flags: UpdateFlags): bool =
  ## https://github.com/ethereum/eth2.0-specs/blob/master/specs/core/0_beacon-chain.md#exits-1
  if len(blck.body.exits) > MAX_EXITS:
    warn("Exit: too many!")
    return false

  for exit in blck.body.exits:
    let validator = state.validator_registry[exit.validator_index]

    if skipValidation notin flags:
      if not bls_verify(
          validator.pubkey, ZERO_HASH.data, exit.signature,
          get_domain(state.fork_data, exit.slot, DOMAIN_EXIT)):
        warn("Exit: invalid signature")
        return false

    if not (validator.exit_slot > state.slot + ENTRY_EXIT_DELAY):
      warn("Exit: exit/entry too close")
      return false

    if not (state.slot >= exit.slot):
      warn("Exit: bad slot")
      return false

    initiate_validator_exit(state, exit.validator_index)

  return true

proc process_ejections(state: var BeaconState) =
  ## Iterate through the validator registry and eject active validators with
  ## balance below ``EJECTION_BALANCE``
  ##
  ## https://github.com/ethereum/eth2.0-specs/blob/master/specs/core/0_beacon-chain.md#ejections

  for index, validator in state.validator_registry:
    if is_active_validator(validator, state.slot) and
        state.validator_balances[index] < EJECTION_BALANCE:
      exit_validator(state, index.Uint24)

func processSlot(state: var BeaconState, previous_block_root: Eth2Digest) =
  ## Time on the beacon chain moves in slots. Every time we make it to a new
  ## slot, a proposer creates a block to represent the state of the beacon
  ## chain at that time. In case the proposer is missing, it may happen that
  ## the no block is produced during the slot.
  ##
  ## https://github.com/ethereum/eth2.0-specs/blob/master/specs/core/0_beacon-chain.md#per-slot-processing

  state.slot += 1
  state.validator_registry[
    get_beacon_proposer_index(state, state.slot)].randao_layers += 1
  state.latest_randao_mixes[state.slot mod LATEST_RANDAO_MIXES_LENGTH] =
    state.latest_randao_mixes[(state.slot - 1) mod LATEST_RANDAO_MIXES_LENGTH]
  state.latest_block_roots[(state.slot - 1) mod LATEST_BLOCK_ROOTS_LENGTH] =
    previous_block_root

  if state.slot mod LATEST_BLOCK_ROOTS_LENGTH == 0:
    state.batched_block_roots.add(merkle_root(state.latest_block_roots))

proc processBlock(
    state: var BeaconState, blck: BeaconBlock, flags: UpdateFlags): bool =
  ## When there's a new block, we need to verify that the block is sane and
  ## update the state accordingly

  # TODO when there's a failure, we should reset the state!
  # TODO probably better to do all verification first, then apply state changes

  if not (blck.slot == state.slot):
    warn "Unexpected block slot number"
    return false

  # Spec does not have this check explicitly, but requires that this condition
  # holds - so we give verify it as well - this would happen naturally if
  # `blck.parent_root` was used in `processSlot` - but that doesn't cut it for
  # blockless slot processing.
  if not (blck.parent_root ==
      state.latest_block_roots[(state.slot - 1) mod LATEST_BLOCK_ROOTS_LENGTH]):
    warn("Unexpected parent root")
    return false

  if skipValidation notin flags:
    # TODO Technically, we could make processBlock take a generic type instead
    #      of BeaconBlock - we would then have an intermediate `ProposedBlock`
    #      type that omits some fields - this way, the compiler would guarantee
    #      that we don't try to access fields that don't have a value yet
    if not verifyProposerSignature(state, blck):
      warn("Proposer signature not valid")
      return false

  if not processRandao(state, blck, flags):
    warn("Randao reveal failed")
    return false

  processDepositRoot(state, blck)

  if not processProposerSlashings(state, blck, flags):
    return false

  if not processCasperSlashings(state, blck):
    return false

  if not processAttestations(state, blck, flags):
    return false

  if not processDeposits(state, blck):
    return false

  if not processExits(state, blck, flags):
    return false

  process_ejections(state)

  return true

func get_attester_indices(
    state: BeaconState,
    attestations: openArray[PendingAttestationRecord]): seq[Uint24] =
  # Union of attesters that participated in some attestations
  # TODO spec - add as helper?
  attestations.
    mapIt(
      get_attestation_participants(state, it.data, it.participation_bitfield)).
    flatten().
    deduplicate()

func boundary_attestations(
    state: BeaconState, boundary_hash: Eth2Digest,
    attestations: openArray[PendingAttestationRecord]
    ): seq[PendingAttestationRecord] =
  # TODO spec - add as helper?
  attestations.filterIt(
    it.data.epoch_boundary_root == boundary_hash and
    it.data.justified_slot == state.justified_slot)

func lowerThan(candidate, current: Eth2Digest): bool =
  # return true iff candidate is "lower" than current, per spec rule:
  # "ties broken by favoring lower `shard_block_root` values"
  # TODO spec - clarify hash ordering..
  for i, v in current.data:
    if v > candidate.data[i]: return true
  return false

func inclusion_slot(state: BeaconState, v: Uint24): uint64 =
  for a in state.latest_attestations:
    if v in get_attestation_participants(state, a.data, a.participation_bitfield):
      return a.slot_included
  doAssert false # shouldn't happen..

func inclusion_distance(state: BeaconState, v: Uint24): uint64 =
  for a in state.latest_attestations:
    if v in get_attestation_participants(state, a.data, a.participation_bitfield):
      return a.slot_included - a.data.slot
  doAssert false # shouldn't happen..

func processEpoch(state: var BeaconState) =
  ## https://github.com/ethereum/eth2.0-specs/blob/master/specs/core/0_beacon-chain.md#per-epoch-processing

  if state.slot mod EPOCH_LENGTH != 0:
    return

  # Precomputation
  let
    active_validator_indices =
      get_active_validator_indices(state.validator_registry, state.slot)
    total_balance = sum_effective_balances(state, active_validator_indices)
    total_balance_in_eth = total_balance div GWEI_PER_ETH

    # The per-slot maximum interest rate is `2/reward_quotient`.)
    base_reward_quotient =
      BASE_REWARD_QUOTIENT * integer_squareroot(total_balance_in_eth)

  func base_reward(state: BeaconState, index: Uint24): uint64 =
    get_effective_balance(state, index) div base_reward_quotient.uint64 div 4

  func inactivity_penalty(
      state: BeaconState, index: Uint24, epochs_since_finality: uint64): uint64 =
    base_reward(state, index) +
      get_effective_balance(state, index) *
      epochs_since_finality div INACTIVITY_PENALTY_QUOTIENT div 2

  # TODO doing this with iterators failed:
  #      https://github.com/nim-lang/Nim/issues/9827
  let
    current_epoch_attestations =
      state.latest_attestations.filterIt(
        state.slot <= it.data.slot + EPOCH_LENGTH and
        it.data.slot < state.slot)

    current_epoch_boundary_attestations =
      boundary_attestations(
        state, get_block_root(state, state.slot-EPOCH_LENGTH),
        current_epoch_attestations)

    current_epoch_boundary_attester_indices =
      get_attester_indices(state, current_epoch_attestations)

    current_epoch_boundary_attesting_balance =
      sum_effective_balances(state, current_epoch_boundary_attester_indices)

  let
    previous_epoch_attestations =
      state.latest_attestations.filterIt(
        state.slot <= it.data.slot + 2 * EPOCH_LENGTH and
        it.data.slot + EPOCH_LENGTH < state.slot)

  let
    previous_epoch_attester_indices =
      get_attester_indices(state, previous_epoch_attestations)

  let # Previous epoch justified
    previous_epoch_justified_attestations =
      concat(current_epoch_attestations, previous_epoch_attestations).
        filterIt(it.data.justified_slot == state.previous_justified_slot)

    previous_epoch_justified_attester_indices =
      get_attester_indices(state, previous_epoch_justified_attestations)

    previous_epoch_justified_attesting_balance =
      sum_effective_balances(state, previous_epoch_justified_attester_indices)

  let # Previous epoch boundary
    # TODO check this with spec...
    negative_uint_hack =
      if state.slot < 2 * EPOCH_LENGTH: 0'u64 else: state.slot - 2 * EPOCH_LENGTH
    previous_epoch_boundary_attestations =
      boundary_attestations(
        state, get_block_root(state, negative_uint_hack),
        previous_epoch_attestations)

    previous_epoch_boundary_attester_indices =
      get_attester_indices(state, previous_epoch_boundary_attestations)

    previous_epoch_boundary_attesting_balance =
      sum_effective_balances(state, previous_epoch_boundary_attester_indices)

  let # Previous epoch head
    previous_epoch_head_attestations =
      previous_epoch_attestations.filterIt(
        it.data.beacon_block_root == get_block_root(state, it.data.slot))

    previous_epoch_head_attester_indices =
      get_attester_indices(state, previous_epoch_head_attestations)

    previous_epoch_head_attesting_balance =
      sum_effective_balances(state, previous_epoch_head_attester_indices)

  # TODO this is really hairy - we cannot capture `state` directly, but we
  #      can capture a pointer to it - this is safe because we don't leak
  #      these closures outside this scope, but still..
  let statePtr = state.addr
  func attesting_validator_indices(
      shard_committee: ShardCommittee, shard_block_root: Eth2Digest): seq[Uint24] =
    let shard_block_attestations =
      concat(current_epoch_attestations, previous_epoch_attestations).
      filterIt(it.data.shard == shard_committee.shard and
        it.data.shard_block_root == shard_block_root)
    get_attester_indices(statePtr[], shard_block_attestations)

  func winning_root(shard_committee: ShardCommittee): Eth2Digest =
    # * Let `winning_root(shard_committee)` be equal to the value of
    #   `shard_block_root` such that
    #   `sum([get_effective_balance(state, i) for i in attesting_validator_indices(shard_committee, shard_block_root)])`
    #   is maximized (ties broken by favoring lower `shard_block_root` values).
    let candidates =
      concat(current_epoch_attestations, previous_epoch_attestations).
        filterIt(it.data.shard == shard_committee.shard).
        mapIt(it.data.shard_block_root)

    # TODO not covered by spec!
    if candidates.len == 0:
      return

    var max_hash = candidates[0]
    var max_val =
      sum_effective_balances(
        statePtr[], attesting_validator_indices(shard_committee, max_hash))
    for candidate in candidates[1..^1]:
      let val = sum_effective_balances(
        statePtr[], attesting_validator_indices(shard_committee, candidate))
      if val > max_val or (val == max_val and candidate.lowerThan(max_hash)):
        max_hash = candidate
        max_val = val
    max_hash

  func attesting_validator_indices(shard_committee: ShardCommittee): seq[Uint24] =
    attesting_validator_indices(shard_committee, winning_root(shard_committee))

  func total_attesting_balance(shard_committee: ShardCommittee): uint64 =
    sum_effective_balances(
      statePtr[], attesting_validator_indices(shard_committee))

  func total_balance_sac(shard_committee: ShardCommittee): uint64 =
    sum_effective_balances(statePtr[], shard_committee.committee)

  block: # Deposit roots
    if state.slot mod ETH1_DATA_VOTING_PERIOD == 0:
      for x in state.deposit_roots:
        if x.vote_count * 2 >= ETH1_DATA_VOTING_PERIOD:
          state.latest_deposit_root = x.deposit_root
          break
      state.deposit_roots = @[]

  block: # Justification
    state.previous_justified_slot = state.justified_slot

    # TODO where's that bitfield type when you need it?
    # TODO why are all bits kept?
    state.justification_bitfield = state.justification_bitfield shl 1

    # TODO Spec - underflow
    if state.slot >= 2'u64 * EPOCH_LENGTH:
      if 3'u64 * previous_epoch_boundary_attesting_balance >=
          2'u64 * total_balance:
        state.justification_bitfield = state.justification_bitfield or 2
        state.justified_slot = state.slot - 2 * EPOCH_LENGTH

      if 3'u64 * current_epoch_boundary_attesting_balance >=
          2'u64 * total_balance:
        state.justification_bitfield = state.justification_bitfield or 1
        state.justified_slot = state.slot - 1 * EPOCH_LENGTH

  block: # Finalization
    if
      (state.previous_justified_slot + 2 * EPOCH_LENGTH == state.slot and
        state.justification_bitfield mod 4 == 3) or
      (state.previous_justified_slot + 3 * EPOCH_LENGTH == state.slot and
        state.justification_bitfield mod 8 == 7) or
      (state.previous_justified_slot + 4 * EPOCH_LENGTH == state.slot and
        state.justification_bitfield mod 16 in [15'u64, 14]):
      state.finalized_slot = state.justified_slot

  block: # Crosslinks
    for sac in state.shard_committees_at_slots:
      for shard_committee in sac:
        if 3'u64 * total_attesting_balance(shard_committee) >=
            2'u64 * total_balance_sac(shard_committee):
          state.latest_crosslinks[shard_committee.shard] = CrosslinkRecord(
            slot: state.slot + EPOCH_LENGTH,
            shard_block_root: winning_root(shard_committee))

  block: # Justification and finalization
    let
      epochs_since_finality =
        (state.slot - state.finalized_slot) div EPOCH_LENGTH

    proc update_balance(attesters: openArray[Uint24], attesting_balance: uint64) =
      # TODO Spec - add helper?
      for v in attesters:
        statePtr.validator_balances[v] +=
          base_reward(statePtr[], v) *
          attesting_balance div total_balance

      for v in active_validator_indices:
        if v notin attesters:
          # TODO underflows?
          statePtr.validator_balances[v] -= base_reward(statePtr[], v)

    if epochs_since_finality <= 4'u64 * EPOCH_LENGTH:
      # Expected FFG source
      update_balance(
        previous_epoch_justified_attester_indices,
        previous_epoch_justified_attesting_balance)

      # Expected FFG target:
      update_balance(
        previous_epoch_boundary_attester_indices,
        previous_epoch_boundary_attesting_balance)

      # Expected beacon chain head:
      update_balance(
        previous_epoch_head_attester_indices,
        previous_epoch_head_attesting_balance)

      # Inclusion distance
      for v in previous_epoch_attester_indices:
        statePtr.validator_balances[v] +=
          base_reward(state, v) *
          MIN_ATTESTATION_INCLUSION_DELAY div inclusion_distance(state, v)

    else:
      for index in active_validator_indices:
        # TODO underflows?
        if index notin previous_epoch_justified_attester_indices:
          state.validator_balances[index] -=
            inactivity_penalty(state, index, epochs_since_finality)
        if index notin previous_epoch_boundary_attester_indices:
          state.validator_balances[index] -=
            inactivity_penalty(state, index, epochs_since_finality)
        if index notin previous_epoch_head_attester_indices:
          state.validator_balances[index] -=
            inactivity_penalty(state, index, epochs_since_finality)

  block: # Attestation inclusion
    for v in previous_epoch_attester_indices:
      let proposer_index =
        get_beacon_proposer_index(state, inclusion_slot(state, v))
      state.validator_balances[proposer_index] +=
        base_reward(state, v) div INCLUDER_REWARD_QUOTIENT

  block: # Crosslinks
    for sac in state.shard_committees_at_slots[0 ..< EPOCH_LENGTH]:
      for shard_committee in sac:
        for index in shard_committee.committee:
          if index in attesting_validator_indices(shard_committee):
            state.validator_balances[index] +=
              base_reward(state, index) *
              total_attesting_balance(shard_committee) div
              total_balance_sac(shard_committee)
          else:
            # TODO underflows?
            state.validator_balances[index] -= base_reward(state, index)

  block: # Validator registry
    if state.finalized_slot > state.validator_registry_latest_change_slot and
        state.shard_committees_at_slots.allIt(
          it.allIt(
            state.latest_crosslinks[it.shard].slot >
              state.validator_registry_latest_change_slot)):
      update_validator_registry(state)

      state.validator_registry_latest_change_slot = state.slot

      for i in 0..<EPOCH_LENGTH:
        state.shard_committees_at_slots[i] =
          state.shard_committees_at_slots[EPOCH_LENGTH + i]

      let next_start_shard =
        (state.shard_committees_at_slots[^1][^1].shard + 1) mod SHARD_COUNT
      for i, v in get_shuffling(
          state.latest_randao_mixes[
            (state.slot - EPOCH_LENGTH) mod LATEST_RANDAO_MIXES_LENGTH],
          state.validator_registry, next_start_shard, state.slot):
        state.shard_committees_at_slots[i + EPOCH_LENGTH] = v

    else:
      # If a validator registry change does NOT happen
      for i in 0..<EPOCH_LENGTH:
        state.shard_committees_at_slots[i] =
          state.shard_committees_at_slots[EPOCH_LENGTH + i]

      let
        epochs_since_last_registry_change =
          (state.slot - state.validator_registry_latest_change_slot) div
            EPOCH_LENGTH
        start_shard = state.shard_committees_at_slots[0][0].shard

      if is_power_of_2(epochs_since_last_registry_change):
        for i, v in get_shuffling(
            state.latest_randao_mixes[
              (state.slot - EPOCH_LENGTH) mod LATEST_RANDAO_MIXES_LENGTH],
            state.validator_registry, start_shard, state.slot):
          state.shard_committees_at_slots[i + EPOCH_LENGTH] = v
        # Note that `start_shard` is not changed from the last epoch.

  block: # Proposer reshuffling
    let num_validators_to_reshuffle =
      len(active_validator_indices) div
        SHARD_PERSISTENT_COMMITTEE_CHANGE_PERIOD.int
    for i in 0..<num_validators_to_reshuffle:
      # Multiplying i to 2 to ensure we have different input to all the required hashes in the shuffling
      # and none of the hashes used for entropy in this loop will be the same
      # TODO Modulo of hash value.. hm...
      let
        validator_index = 0.Uint24 # TODO active_validator_indices[hash(state.latest_randao_mixes[state.slot % LATEST_RANDAO_MIXES_LENGTH] + bytes8(i * 2)) % len(active_validator_indices)]
        new_shard = 0'u64 # TODO hash(state.randao_mix + bytes8(i * 2 + 1)) mod SHARD_COUNT
        shard_reassignment_record = ShardReassignmentRecord(
          validator_index: validator_index,
          shard: new_shard,
          slot: state.slot + SHARD_PERSISTENT_COMMITTEE_CHANGE_PERIOD
        )
      state.persistent_committee_reassignments.add(shard_reassignment_record)

    while len(state.persistent_committee_reassignments) > 0 and
        state.persistent_committee_reassignments[0].slot <= state.slot:
      let reassignment = state.persistent_committee_reassignments[0]
      state.persistent_committee_reassignments.delete(0)
      for committee in state.persistent_committees.mitems():
        if reassignment.validator_index in committee:
          committee.delete(committee.find(reassignment.validator_index))
      state.persistent_committees[reassignment.shard.int].add(
        reassignment.validator_index)

  block: # Final updates
    state.latest_attestations.keepItIf(
      not (it.data.slot + EPOCH_LENGTH < state.slot)
    )

proc verifyStateRoot(state: BeaconState, blck: BeaconBlock): bool =
  let state_root = hash_tree_root_final(state)
  if state_root != blck.state_root:
    warn("Block: root verification failed",
      block_state_root = blck.state_root, state_root)
    false
  else:
    true

proc updateState*(state: var BeaconState, previous_block_root: Eth2Digest,
    new_block: Option[BeaconBlock], flags: UpdateFlags): bool =
  ## Time in the beacon chain moves by slots. Every time (haha.) that happens,
  ## we will update the beacon state. Normally, the state updates will be driven
  ## by the contents of a new block, but it may happen that the block goes
  ## missing - the state updates happen regardless.
  ## Each call to this function will advance the state by one slot - new_block,
  ## if present, must match that slot.
  ##
  ## The flags are used to specify that certain validations should be skipped
  ## for the new block. This is done during block proposal, to create a state
  ## whose hash can be included in the new block.
  #
  # TODO this function can be written with a loop inside to handle all empty
  #      slots up to the slot of the new_block - but then again, why not eagerly
  #      update the state as time passes? Something to ponder...
  #      One reason to keep it this way is that you need to look ahead if you're
  #      the block proposer, though in reality we only need a partial update for
  #      that
  # TODO check to which extent this copy can be avoided (considering forks etc),
  #      for now, it serves as a reminder that we need to handle invalid blocks
  #      somewhere..
  # TODO many functions will mutate `state` partially without rolling back
  #      the changes in case of failure (look out for `var BeaconState` and
  #      bool return values...)
  # TODO There's a discussion about what this function should do, and when:
  #      https://github.com/ethereum/eth2.0-specs/issues/284
  var old_state = state

  # Per-slot updates - these happen regardless if there is a block or not
  processSlot(state, previous_block_root)

  if new_block.isSome():
    # Block updates - these happen when there's a new block being suggested
    # by the block proposer. Every actor in the network will update its state
    # according to the contents of this block - but first they will validate
    # that the block is sane.
    # TODO what should happen if block processing fails?
    #      https://github.com/ethereum/eth2.0-specs/issues/293
    if processBlock(state, new_block.get(), flags):
      # Block ok so far, proceed with state update
      processEpoch(state)

      # This is a bit awkward - at the end of processing we verify that the
      # state we arrive at is what the block producer thought it would be -
      # meaning that potentially, it could fail verification
      if skipValidation in flags or verifyStateRoot(state, new_block.get()):
        # State root is what it should be - we're done!
        return true

    # Block processing failed, have to start over
    state = old_state
    processSlot(state, previous_block_root)
    processEpoch(state)
    false
  else:
    # Skip all per-block processing. Move directly to epoch processing
    # prison. Do not do any block updates when passing go.

    # Heavy updates that happen for every epoch - these never fail (or so we hope)
    processEpoch(state)
    true

# TODO document this:

# Jacek Sieka
# @arnetheduck
# Dec 21 11:32
# question about making attestations: in the attestation we carry slot and a justified_slot - just to make sure, this justified_slot is the slot that was justified when the state was at slot, not whatever the client may be seeing now? effectively, because we're attesting to MIN_ATTESTATION_INCLUSION_DELAYold states, it might be that we know about a newer justified slot, but don't include it - correct?
# Danny Ryan
# @djrtwo
# Dec 21 11:34
# You are attesting to what you see as the head of the chain at that slot
# The MIN_ATTESTATION_INCLUSION_DELAY is just how many slots must past before this message can be included on chain
# so whatever the justified_slot was inside the state that was associate with the head you are attesting to
# Jacek Sieka
# @arnetheduck
# Dec 21 11:37
# can I revise an attestation, once I get new information (about the shard or state)?
# Danny Ryan
# @djrtwo
# Dec 21 11:37
# We are attesting to the exact current state at that slot. The MIN_ATTESTATION_INCLUSION_DELAY is to attempt to reduce centralization risk in light of fast block times (ensure attestations have time to fully propagate so fair playing field on including them on chain)
# No, if you create two attestations for the same slot, you can be slashed
# https://github.com/ethereum/eth2.0-specs/blob/master/specs/core/0_beacon-chain.md#is_double_vote
# Jacek Sieka
# @arnetheduck
# Dec 21 11:39
# is there any interest for me to publish my attestation before MIN_ATTESTATION_INCLUSION_DELAY-1 time has passed?
# (apart from the risk of it not being picked up on time)
# Danny Ryan
# @djrtwo
# Dec 21 11:40

# that’s the main risk.

# Note, we’re a bit unsure about MIN_ATTESTATION_INCLUSION_DELAY because it might open up an attestors timing strategy too much. In the case where MIN_ATTESTATION_INCLUSION_DELAY is removed, we just set it to 1
# part of validator honesty assumption is to attest during your slot. That said, a rational actor might act in any number of interesting ways..
# Jacek Sieka
# @arnetheduck
# Dec 21 11:59
# I can probably google this somehow, but bls signatures, anyone knows off the top of their head if they have to be combined one by one, or can two group signatures be combined? what happens to overlap then?
# Danny Ryan
# @djrtwo
# Dec 21 12:00
# Yeah, you can do any linear combination of signatures. but you have to remember the linear combination of pubkeys that constructed
# if you have two instances of a signature from pubkey p, then you need 2*p in the group pubkey
# because the attestation bitfield is only 1 bit per pubkey right now, attestations do not support this
# it could be extended to support N overlaps up to N times per pubkey if we had N bits per validator instead of 1
# We are shying away from this for the time being. If there end up being substantial difficulties in network layer aggregation, then adding bits to aid in supporting overlaps is one potential solution
# Jacek Sieka
# @arnetheduck
# Dec 21 12:02
# ah nice, you anticipated my followup question there :) so it's not a straight-off set union operation
# Danny Ryan
# @djrtwo
# Dec 21 12:02
# depending on the particular network level troubles we run into
# right
# aggregatng sigs and pubkeys are both just ec adds https://github.com/ethereum/py-evm/blob/d82b10ae361cde6abbac62f171fcea7809c4e3cf/eth/_utils/bls.py#L191-L202
# subtractions work too (i suppose this is obvious). You can linearly combine sigs or pubs in any way
# Jacek Sieka
# @arnetheduck
# Dec 21 12:05
# hm.. well, because one thing I'm thinking of is the scenario where someone attests to some shard head and I receive that attestation.. now, let's say that's an honest attestation, but within that same slot, I have more fresh information about a shard for example.. now, I can either sign the data in the old attestation or churn out a new one, risking that neither of these get enough votes to be useful - does that sound.. accurate?
# Danny Ryan
# @djrtwo
# Dec 21 12:08

# So you won’t just be signing the head of the shard. This isn’t specified yet, but it would be targeting some recent epoch boundary to ensure higher chance of consensus.

# If your recent info is about a better fork in the shard than the one you see the other attester signed, then you are better off signing that fork because if it is winning in your few of the shard chain fork choice, then you would assume it is winning in the view of most attesters shard fork choice
# If some strange circumstance arose in which you saw a majority of attestations that signed something you think is unexpected before you signed, a rational actor might defect to this majority. An honest actor would sign what they believe to be true
# in practice, the actor would have to wait some amount of time past when they should have attested to gather this info.
# also, at the end of the day the validator has to compute the non-outsourcable proof of custody bit, so if the other validators are signing off on some shard chain fork they don’t know about, then they can’t attest to that data anyway
# (for fear of signing a bad custody bit)
# so their rational move is to just attest to the data they acutally know about and can accurately compute their proof of custody bit on
# Jacek Sieka
# @arnetheduck
# Dec 21 12:58
# what's justified_block_root doing in attestation_data? isn't that available already as get_block_root(state, attestation.data.justified_slot)?
# also, when we sign hash_tree_root(attestation.data) + bytes1(0) - what's the purpose of the 0 byte, given we have domain already?
# Danny Ryan
# @djrtwo
# Dec 21 13:03
# 0 byte is a stub for the proof of custody bit in phase 0
# If the attestation is included in a short range fork but still votes for the chain it is added to’s justified_block_root/slot, then we want to count the casper vote
# likely if I see the head of the chain as different from what ends up being the canonical chain, my view of the latest justified block might still be in accordance with the canonical chain
# if my attesation is included in a fork, the head i voted on doesn’t necessarily lead back to the justified block in the fork. Without including justified_block_root, my vote could be used in any fork for the same epoch even if the block at that justified_slot height was different
# Danny Ryan
# @djrtwo
# Dec 21 13:14
# Long story short, because attestations can be included in forks of the head they are actually attesting to, we can’t be sure of the justified_block that was being voted on by just usng the justified_slot. The security of properties of Casper FFG require that the voter makes a firm commitment to the actual source block, not just the height of the source block
# Jacek Sieka
# @arnetheduck
# Dec 21 13:23
# ok. that's quite a piece. I'm gonna have to draw some diagrams I think :)
# ah. ok. actually makes sense.. I think :)
# Jacek Sieka
# @arnetheduck
# Dec 21 13:31
# how does that interact then with the following check:

#     Verify that attestation.data.justified_block_root is equal to get_block_root(state, attestation.data.justified_slot).

# Danny Ryan
# @djrtwo
# Dec 21 13:32
# ah, my bad above. We only include an attestation on chain if it is for the correct source
# That’s one of the bare minimum requirements to get it included on chain. Without the justified_block_root, we can’t do that check
# essentially that checks if this attestation is relevant at all to the current fork’s consensus.
# if the justified_block is wrong, then we know the target of the vote and the head of the attestation are wrong too
# sorry for the slight mix up there
# logic still holds — the justified_slot alone is not actually a firm commitment to a particular chain history. You need the associated hash
# Jacek Sieka
# @arnetheduck
# Dec 21 13:35
# can't you just follow Block.parent_root?
# well, that, and ultimately.. Block.state_root
# Danny Ryan
# @djrtwo
# Dec 21 13:37
# The block the attestation is included in might not be for the same fork the attestation was made
# we first make sure that the attestation and the block that it’s included in match at the justified_slot. if not, throw it out
# then in the incentives, we give some extra reward if the epoch_boundary_root and the chain match
# and some extra reward if the beacon_block_root match
# if all three match, then the attestation is fully agreeing with the canonical chain. +1 casper vote and strengthening the head of the fork choice
# if just justified_block_root and epoch_boundary_root match then the attestation agrees enough to successfully cast an ffg vote
# if just justified_block_root match, then at least the attestation agrees on the base of the fork choice, but this isn’t enough to cast an FFG vote
# Jacek Sieka
# @arnetheduck
# Dec 21 13:41

#     if not, throw it out

# it = block or attestation?
# Danny Ryan
# @djrtwo
# Dec 21 13:42
# well, if you are buildling the block ,you shouldn’t include it (thus throw it out of current consideration). If you are validating a block you just received and that conditon fails for an attestation, throw the block out because it included a bad attestation and is thus invalid
# The block producer knows when producing the block if they are including bad attestations or other data that will fail state transition
# and should not do that
# Jacek Sieka
# @arnetheduck
# Dec 21 13:43
# yeah, that makes sense, just checking
# ok, I think I'm gonna let that sink in a bit before asking more questions.. thanks :)
