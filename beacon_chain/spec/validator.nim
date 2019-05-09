# Copyright (c) 2018-2019 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at http://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at http://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

# Helpers and functions pertaining to managing the validator set

import
  options, nimcrypto, sequtils, math, chronicles,
  eth/common,
  ../ssz, ../beacon_node_types,
  ./crypto, ./datatypes, ./digest, ./helpers

# TODO: Proceed to renaming and signature changes
# https://github.com/ethereum/eth2.0-specs/blob/v0.6.1/specs/core/0_beacon-chain.md#get_shuffled_index
# https://github.com/ethereum/eth2.0-specs/blob/v0.6.1/specs/core/0_beacon-chain.md#compute_committee
func get_shuffled_seq*(seed: Eth2Digest,
                       list_size: uint64,
                       ): seq[ValidatorIndex] =
  ## Via https://github.com/protolambda/eth2-shuffle/blob/master/shuffle.go
  ## Shuffles ``validators`` into crosslink committees seeded by ``seed`` and
  ## ``slot``.
  ## Returns a list of ``SLOTS_PER_EPOCH * committees_per_slot`` committees
  ## where each committee is itself a list of validator indices.
  ##
  ## Invert the inner/outer loops from the spec, essentially. Most useful
  ## hash result re-use occurs within a round.

  # Empty size -> empty list.
  if list_size == 0:
    return

  var
    # Share these buffers.
    # TODO: Redo to follow spec.
    #       We can have an "Impl" private version that takes buffer as parameters
    #       so that we avoid alloc on repeated calls from compute_committee
    pivot_buffer: array[(32+1), byte]
    source_buffer: array[(32+1+4), byte]
    shuffled_active_validator_indices = mapIt(
      0 ..< list_size.int, it.ValidatorIndex)
    sources = repeat(Eth2Digest(), (list_size div 256) + 1)

  ## The pivot's a function of seed and round only.
  ## This doesn't change across rounds.
  pivot_buffer[0..31] = seed.data
  source_buffer[0..31] = seed.data

  for round in 0 ..< SHUFFLE_ROUND_COUNT:
    let round_bytes1 = int_to_bytes1(round)[0]
    pivot_buffer[32] = round_bytes1
    source_buffer[32] = round_bytes1

    # Only one pivot per round.
    let pivot = bytes_to_int(eth2hash(pivot_buffer).data.toOpenArray(0, 7)) mod list_size

    ## Only need to run, per round, position div 256 hashes, so precalculate
    ## them. This consumes memory, but for low-memory devices, it's possible
    ## to mitigate by some light LRU caching and similar.
    for reduced_position in 0 ..< sources.len:
      source_buffer[33..36] = int_to_bytes4(reduced_position.uint64)
      sources[reduced_position] = eth2hash(source_buffer)

    ## Iterate over all the indices. This was in get_permuted_index, but large
    ## efficiency gains exist in caching and re-using data.
    for index in 0 ..< list_size.int:
      let
        cur_idx_permuted = shuffled_active_validator_indices[index]
        flip = ((list_size + pivot) - cur_idx_permuted.uint64) mod list_size
        position = max(cur_idx_permuted, flip.int)

      let
        source = sources[position div 256].data
        byte_value = source[(position mod 256) div 8]
        bit = (byte_value shr (position mod 8)) mod 2

      if bit != 0:
        shuffled_active_validator_indices[index] = flip.ValidatorIndex

  result = shuffled_active_validator_indices

# https://github.com/ethereum/eth2.0-specs/blob/v0.5.1/specs/core/0_beacon-chain.md#get_shuffling
func get_shuffling*(seed: Eth2Digest,
                    validators: openArray[Validator],
                    epoch: Epoch,
                    ): seq[seq[ValidatorIndex]] =
  ## This function is factored to facilitate testing with
  ## https://github.com/ethereum/eth2.0-test-generators/tree/master/permutated_index
  ## test vectors, which the split of get_shuffling obfuscates.

  let
    active_validator_indices = get_active_validator_indices(validators, epoch)
    list_size = active_validator_indices.len.uint64
    committees_per_epoch = get_epoch_committee_count(
      validators, epoch).int
    shuffled_seq = get_shuffled_seq(seed, list_size)

  # Split the shuffled list into committees_per_epoch pieces
  result = split(shuffled_seq, committees_per_epoch)
  doAssert result.len() == committees_per_epoch # what split should do..

# https://github.com/ethereum/eth2.0-specs/blob/v0.5.0/specs/core/0_beacon-chain.md#get_previous_epoch
func get_previous_epoch*(state: BeaconState): Epoch =
  ## Return the previous epoch of the given ``state``.
  # Note: This is allowed to underflow internally (this is why GENESIS_EPOCH != 0)
  #       however when interfacing with peers for example for attestations
  #       this should not underflow.
  # TODO or not - it causes issues: https://github.com/ethereum/eth2.0-specs/issues/849

  let epoch = get_current_epoch(state)
  max(GENESIS_EPOCH, epoch - 1) # TODO max here to work around the above issue


# https://github.com/ethereum/eth2.0-specs/blob/v0.5.0/specs/core/0_beacon-chain.md#get_crosslink_committees_at_slot
func get_crosslink_committees_at_slot*(state: BeaconState, slot: Slot|uint64,
                                       registry_change: bool = false):
    seq[CrosslinkCommittee] =
  ## Returns the list of ``(committee, shard)`` tuples for the ``slot``.
  ##
  ## Note: There are two possible shufflings for crosslink committees for a
  ## ``slot`` in the next epoch -- with and without a `registry_change`

  let
    epoch = slot_to_epoch(slot) # TODO, enforce slot to be a Slot
    current_epoch = get_current_epoch(state)
    previous_epoch = get_previous_epoch(state)
    next_epoch = current_epoch + 1

  doAssert previous_epoch <= epoch,
    "Previous epoch: " & $humaneEpochNum(previous_epoch) &
    ", epoch: " & $humaneEpochNum(epoch) &
    " (slot: " & $humaneSlotNum(slot.Slot) & ")" &
    ", Next epoch: " & $humaneEpochNum(next_epoch)

  doAssert epoch <= next_epoch,
    "Previous epoch: " & $humaneEpochNum(previous_epoch) &
    ", epoch: " & $humaneEpochNum(epoch) &
    " (slot: " & $humaneSlotNum(slot.Slot) & ")" &
    ", Next epoch: " & $humaneEpochNum(next_epoch)

  template get_epoch_specific_params(): auto =
    if epoch == current_epoch:
      let
        committees_per_epoch = get_epoch_committee_count(state, current_epoch)
        seed = state.current_shuffling_seed
        shuffling_epoch = state.current_shuffling_epoch
        shuffling_start_shard = state.current_shuffling_start_shard
      (committees_per_epoch, seed, shuffling_epoch, shuffling_start_shard)
    elif epoch == previous_epoch:
      let
        committees_per_epoch = get_epoch_committee_count(state, previous_epoch)
        seed = state.previous_shuffling_seed
        shuffling_epoch = state.previous_shuffling_epoch
        shuffling_start_shard = state.previous_shuffling_start_shard
      (committees_per_epoch, seed, shuffling_epoch, shuffling_start_shard)
    else:
      doAssert epoch == next_epoch

      let
        shuffling_epoch = next_epoch

        epochs_since_last_registry_update =
          current_epoch - state.validator_registry_update_epoch
        condition = epochs_since_last_registry_update > 1'u64 and
                    is_power_of_2(epochs_since_last_registry_update)
        use_next = registry_change or condition
        committees_per_epoch =
          if use_next:
            get_epoch_committee_count(state, next_epoch)
          else:
            get_epoch_committee_count(state, current_epoch)
        seed =
          if use_next:
            generate_seed(state, next_epoch)
          else:
            state.current_shuffling_seed
        shuffling_epoch =
          if use_next: next_epoch else: state.current_shuffling_epoch
        shuffling_start_shard =
          if registry_change:
            (state.current_shuffling_start_shard +
             get_epoch_committee_count(state, current_epoch)) mod SHARD_COUNT
          else:
            state.current_shuffling_start_shard
      (committees_per_epoch, seed, shuffling_epoch, shuffling_start_shard)

  let (committees_per_epoch, seed, shuffling_epoch, shuffling_start_shard) =
    get_epoch_specific_params()

  let
    shuffling = get_shuffling(seed, state.validator_registry, shuffling_epoch)
    offset = slot mod SLOTS_PER_EPOCH
    committees_per_slot = committees_per_epoch div SLOTS_PER_EPOCH
    slot_start_shard = (shuffling_start_shard + committees_per_slot * offset) mod SHARD_COUNT

  for i in 0 ..< committees_per_slot.int:
    result.add (
     shuffling[(committees_per_slot * offset + i.uint64).int],
     (slot_start_shard + i.uint64) mod SHARD_COUNT
    )

iterator get_crosslink_committees_at_slot_cached*(
  state: BeaconState, slot: Slot|uint64,
  registry_change: bool = false, cache: var StateCache):
    CrosslinkCommittee =
  let key = (slot.uint64, registry_change)
  if key in cache.crosslink_committee_cache:
    for v in cache.crosslink_committee_cache[key]: yield v
  #debugEcho "get_crosslink_committees_at_slot_cached: MISS"
  let result = get_crosslink_committees_at_slot(state, slot, registry_change)
  cache.crosslink_committee_cache[key] = result
  for v in result: yield v

# https://github.com/ethereum/eth2.0-specs/blob/v0.5.0/specs/core/0_beacon-chain.md#get_beacon_proposer_index
# TODO remove/merge these back together once 0.5.1 callers removed
func get_beacon_proposer_index*(state: BeaconState, slot: Slot): ValidatorIndex =
  ## From Casper RPJ mini-spec:
  ## When slot i begins, validator Vidx is expected
  ## to create ("propose") a block, which contains a pointer to some parent block
  ## that they perceive as the "head of the chain",
  ## and includes all of the **attestations** that they know about
  ## that have not yet been included into that chain.
  ##
  ## idx in Vidx == p(i mod N), pi being a random permutation of validators indices (i.e. a committee)
  ## Returns the beacon proposer index for the ``slot``.
  # TODO this index is invalid outside of the block state transition function
  #      because presently, `state.slot += 1` happens before this function
  #      is called - see also testutil.getNextBeaconProposerIndex
  # TODO is the above still true? the shuffling has changed since it was written
  let
    epoch = slot_to_epoch(slot)
    current_epoch = get_current_epoch(state)
    previous_epoch = get_previous_epoch(state)
    next_epoch = current_epoch + 1

  doAssert previous_epoch <= epoch
  doAssert epoch <= next_epoch

  let (first_committee, _) = get_crosslink_committees_at_slot(state, slot)[0]
  let idx = int(slot mod uint64(first_committee.len))
  first_committee[idx]

func get_beacon_proposer_index*(state: BeaconState): ValidatorIndex =
  # Return the beacon proposer index at ``state.slot``.
  # TODO there are some other changes here
  get_beacon_proposer_index(state, state.slot)
