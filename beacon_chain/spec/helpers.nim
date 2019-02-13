# beacon_chain
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at http://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at http://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

# Uncategorized helper functions from the spec

import ./datatypes, ./digest, sequtils, math

# TODO spec candidate? there's bits in nim-ranges but that one has some API
#      issues regarding bit endianess that need resolving..
func bitSet*(bitfield: var openArray[byte], index: int) =
  bitfield[index div 8] = bitfield[index div 8] or 1'u8 shl (7 - (index mod 8))

# https://github.com/ethereum/eth2.0-specs/blob/v0.1/specs/core/0_beacon-chain.md#get_bitfield_bit
func get_bitfield_bit*(bitfield: openarray[byte], i: int): byte =
  # Extract the bit in ``bitfield`` at position ``i``.
  (bitfield[i div 8] shr (7 - (i mod 8))) mod 2

# https://github.com/ethereum/eth2.0-specs/blob/v0.1/specs/core/0_beacon-chain.md#verify_bitfield
func verify_bitfield*(bitfield: openarray[byte], committee_size: int): bool =
  # Verify ``bitfield`` against the ``committee_size``.
  if len(bitfield) != (committee_size + 7) div 8:
    return false

  for i in committee_size + 1 ..< committee_size - (committee_size mod 8) + 8:
    if get_bitfield_bit(bitfield, i) == 0b1:
      return false

  true

# https://github.com/ethereum/eth2.0-specs/blob/v0.2.0/specs/core/0_beacon-chain.md#split
func split*[T](lst: openArray[T], N: Positive): seq[seq[T]] =
  ## split lst in N pieces, with each piece having `len(lst) div N` or
  ## `len(lst) div N + 1` pieces
  # TODO: implement as an iterator
  result = newSeq[seq[T]](N)
  for i in 0 ..< N:
    result[i] = lst[lst.len * i div N ..< lst.len * (i+1) div N] # TODO: avoid alloc via toOpenArray

func get_new_recent_block_roots*(old_block_roots: seq[Eth2Digest],
                                  parent_slot, current_slot: int64,
                                  parent_hash: Eth2Digest
                                  ): seq[Eth2Digest] =

  # Should throw for `current_slot - CYCLE_LENGTH * 2 - 1` according to spec comment
  let d = current_slot - parent_slot
  result = old_block_roots[d .. ^1]
  for _ in 0 ..< min(d, old_block_roots.len):
    result.add parent_hash

# TODO remove; cascades through randao.nim, validator_pool.nim, etc
func repeat_hash*(v: Eth2Digest, n: SomeInteger): Eth2Digest =
  # Spec version:
  # if n == 0: v
  # else: repeat_hash(eth2hash(v.data), n - 1)
  # Nim is pretty bad at recursion though (max 2k levels / no tco), so:
  result = v
  var n = n
  while n != 0:
    result = eth2hash(result.data)
    dec n

func ceil_div8*(v: int): int = (v + 7) div 8 # TODO use a proper bitarray!

# https://github.com/ethereum/eth2.0-specs/blob/v0.1/specs/core/0_beacon-chain.md#integer_squareroot
func integer_squareroot*(n: SomeInteger): SomeInteger =
  ## The largest integer ``x`` such that ``x**2`` is less than ``n``.
  var
    x = n
    y = (x + 1) div 2
  while y < x:
    x = y
    y = (x + n div x) div 2
  x

# https://github.com/ethereum/eth2.0-specs/blob/v0.1/specs/core/0_beacon-chain.md#get_fork_version
func get_fork_version*(fork: Fork, epoch: EpochNumber): uint64 =
  ## Return the fork version of the given ``epoch``.
  if epoch < fork.epoch:
    fork.previous_version
  else:
    fork.current_version

# https://github.com/ethereum/eth2.0-specs/blob/v0.1/specs/core/0_beacon-chain.md#get_domain
func get_domain*(
    fork: Fork, epoch: EpochNumber, domain_type: SignatureDomain): uint64 =
  # TODO Slot overflow? Or is slot 32 bits for all intents and purposes?
  # Get the domain number that represents the fork meta and signature domain.
  (get_fork_version(fork, epoch) shl 32) + domain_type.uint32

# https://github.com/ethereum/eth2.0-specs/blob/v0.2.0/specs/core/0_beacon-chain.md#is_power_of_two
func is_power_of_2*(v: uint64): bool = (v and (v-1)) == 0

# https://github.com/ethereum/eth2.0-specs/blob/v0.1/specs/core/0_beacon-chain.md#merkle_root
func merkle_root*(values: openArray[Eth2Digest]): Eth2Digest =
  ## Merkleize ``values`` (where ``len(values)`` is a power of two) and return
  ## the Merkle root.
  #var o = array[len(values) * 2, Eth2Digest]
  #o[len(values) .. 2*len(values)] = values
  #for i in countdown(len(values)-1, 0):
  #  discard
    #o[i] = hash(o[i*2] + o[i*2+1])
  #return o[1]
  #TODO
  discard

# https://github.com/ethereum/eth2.0-specs/blob/v0.2.0/specs/core/0_beacon-chain.md#slot_to_epoch
func slot_to_epoch*(slot: SlotNumber): EpochNumber =
  slot div EPOCH_LENGTH

# https://github.com/ethereum/eth2.0-specs/blob/v0.1/specs/core/0_beacon-chain.md#is_double_vote
func is_double_vote*(attestation_data_1: AttestationData,
                     attestation_data_2: AttestationData): bool =
  ## Check if ``attestation_data_1`` and ``attestation_data_2`` have the same
  ## target.
  let
    target_epoch_1 = slot_to_epoch(attestation_data_1.slot)
    target_epoch_2 = slot_to_epoch(attestation_data_2.slot)
  target_epoch_1 == target_epoch_2

# https://github.com/ethereum/eth2.0-specs/blob/v0.1/specs/core/0_beacon-chain.md#is_surround_vote
func is_surround_vote*(attestation_data_1: AttestationData,
                       attestation_data_2: AttestationData): bool =
  ## Check if ``attestation_data_1`` surrounds ``attestation_data_2``.
  let
    source_epoch_1 = attestation_data_1.justified_epoch
    source_epoch_2 = attestation_data_2.justified_epoch
    target_epoch_1 = slot_to_epoch(attestation_data_1.slot)
    target_epoch_2 = slot_to_epoch(attestation_data_2.slot)

  source_epoch_1 < source_epoch_2 and target_epoch_2 < target_epoch_1

# https://github.com/ethereum/eth2.0-specs/blob/v0.2.0/specs/core/0_beacon-chain.md#is_active_validator
func is_active_validator*(validator: Validator, epoch: EpochNumber): bool =
  ### Checks if validator is active
  validator.activation_epoch <= epoch and epoch < validator.exit_epoch

# https://github.com/ethereum/eth2.0-specs/blob/v0.2.0/specs/core/0_beacon-chain.md#get_active_validator_indices
func get_active_validator_indices*(validators: openArray[Validator], epoch: EpochNumber): seq[ValidatorIndex] =
  ## Gets indices of active validators from validators
  for idx, val in validators:
    if is_active_validator(val, epoch):
      result.add idx.ValidatorIndex

# https://github.com/ethereum/eth2.0-specs/blob/v0.2.0/specs/core/0_beacon-chain.md#get_epoch_committee_count
func get_epoch_committee_count*(active_validator_count: int): uint64 =
  clamp(
    active_validator_count div EPOCH_LENGTH div TARGET_COMMITTEE_SIZE,
    1, SHARD_COUNT div EPOCH_LENGTH).uint64 * EPOCH_LENGTH

# https://github.com/ethereum/eth2.0-specs/blob/v0.2.0/specs/core/0_beacon-chain.md#get_current_epoch_committee_count
func get_current_epoch_committee_count*(state: BeaconState): uint64 =
  # Return the number of committees in the current epoch of the given ``state``.
  let current_active_validators = get_active_validator_indices(
    state.validator_registry,
    state.current_calculation_epoch,
  )
  get_epoch_committee_count(len(current_active_validators))

# https://github.com/ethereum/eth2.0-specs/blob/v0.2.0/specs/core/0_beacon-chain.md#get_current_epoch
func get_current_epoch*(state: BeaconState): EpochNumber =
  # Return the current epoch of the given ``state``.
  slot_to_epoch(state.slot)

# https://github.com/ethereum/eth2.0-specs/blob/v0.2.0/specs/core/0_beacon-chain.md#get_randao_mix
func get_randao_mix*(state: BeaconState,
                     epoch: EpochNumber): Eth2Digest =
    ## Returns the randao mix at a recent ``epoch``.

    # Cannot underflow, since GENESIS_EPOCH > LATEST_RANDAO_MIXES_LENGTH
    assert get_current_epoch(state) - LATEST_RANDAO_MIXES_LENGTH < epoch
    assert epoch <= get_current_epoch(state)

    state.latest_randao_mixes[epoch mod LATEST_RANDAO_MIXES_LENGTH]

# https://github.com/ethereum/eth2.0-specs/blob/v0.2.0/specs/core/0_beacon-chain.md#get_active_index_root
func get_active_index_root(state: BeaconState, epoch: EpochNumber): Eth2Digest =
  # Returns the index root at a recent ``epoch``.

  # Cannot underflow, since GENESIS_EPOCH > LATEST_RANDAO_MIXES_LENGTH
  assert get_current_epoch(state) - LATEST_INDEX_ROOTS_LENGTH < epoch
  assert epoch <= get_current_epoch(state) + ENTRY_EXIT_DELAY
  state.latest_index_roots[epoch mod LATEST_INDEX_ROOTS_LENGTH]

# https://github.com/ethereum/eth2.0-specs/blob/v0.2.0/specs/core/0_beacon-chain.md#bytes_to_int
func bytes_to_int*(data: seq[byte]): uint64 =
  assert data.len == 8

  # Little-endian data representation
  result = 0
  for i in countdown(7, 0):
    result = result * 256 + data[i]

# https://github.com/ethereum/eth2.0-specs/blob/v0.2.0/specs/core/0_beacon-chain.md#int_to_bytes1-int_to_bytes2-
# Have 1, 4, and 32-byte versions. 2+ more and maybe worth metaprogramming.
func int_to_bytes32*(x: uint64) : array[32, byte] =
  # Little-endian data representation
  for i in 0 ..< 8:
    result[24 + i] = byte((x shr i*8) and 0xff)

func int_to_bytes1*(x: int): array[1, byte] =
  assert x >= 0
  assert x < 256

  result[0] = x.byte

func int_to_bytes4*(x: uint64): array[4, byte] =
  assert x >= 0'u64
  assert x < 2'u64^32

  # Little-endian data representation
  result[0] = ((x shr  0) and 0xff).byte
  result[1] = ((x shr  8) and 0xff).byte
  result[2] = ((x shr 16) and 0xff).byte
  result[3] = ((x shr 24) and 0xff).byte

# https://github.com/ethereum/eth2.0-specs/blob/v0.2.0/specs/core/0_beacon-chain.md#generate_seed
func generate_seed*(state: BeaconState, epoch: EpochNumber): Eth2Digest =
  # Generate a seed for the given ``epoch``.

  var seed_input : array[32*3, byte]
  # Cannot underflow, since GENESIS_EPOCH > SEED_LOOKAHEAD
  seed_input[0..31] = get_randao_mix(state, epoch - SEED_LOOKAHEAD).data
  seed_input[32..63] = get_active_index_root(state, epoch).data
  seed_input[64..95] = int_to_bytes32(epoch)
  eth2hash(seed_input)
