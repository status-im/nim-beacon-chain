import
  deques, options,
  milagro_crypto,
  ./spec/[datatypes, crypto, digest, helpers, validator], extras,
  tables, hashes

type
  AttestationCandidate* = object
    validator*: int
    data*: AttestationData
    signature*: ValidatorSig

  AttestationPool* = object
    # The Deque below stores all outstanding attestations per slot.
    # In each slot, we have an array of all attestations indexed by their
    # shard number. When we haven't received an attestation for a particular
    # shard yet, the Option value will be `none`
    attestations: Deque[array[SHARD_COUNT, Option[Attestation]]]
    startingSlot: int

  # TODO:
  # The compilicated Deque above is not needed.
  #
  # In fact, we can use a simple array with length SHARD_COUNT because
  # in each epoch, each shard is going to receive attestations exactly once.
  # Once the epoch is over, we can discard all attestations and start all
  # over again (no need for `discardHistoryToSlot` too).

  # Stub for BeaconChainDB
  BlockHash = Eth2Digest
  BeaconChainDB = ref object
    # API that the BeaconChainDB type should expose
    blocks: Table[Eth2Digest, BeaconBlock]

func hash(x: BlockHash): Hash =
  ## Hash for Keccak digests for Nim hash tables
  # Stub for BeaconChainDB

  # We just slice the first 4 or 8 bytes of the block hash
  # depending of if we are on a 32 or 64-bit platform
  const size = x.sizeof
  const num_hashes = size div sizeof(int)
  result = cast[array[num_hashes, Hash]](x)[0]

proc init*(T: type AttestationPool, startingSlot: int): T =
  result.attestations = initDeque[array[SHARD_COUNT, Option[Attestation]]]()
  result.startingSlot = startingSlot

proc setLen*[T](d: var Deque[T], len: int) =
  # TODO: The upstream `Deque` type should gain a proper resize API
  let delta = len - d.len
  if delta > 0:
    for i in 0 ..< delta:
      var defaultVal: T
      d.addLast(defaultVal)
  else:
    d.shrink(fromLast = delta)

proc combine*(tgt: var Attestation, src: Attestation, flags: UpdateFlags) =
  # Combine the signature and participation bitfield, with the assumption that
  # the same data is being signed!
  # TODO similar code in work_pool, clean up

  assert tgt.data == src.data

  for i in 0 ..< tgt.participation_bitfield.len:
    # TODO:
    # when BLS signatures are combined, we must ensure that
    # the same participant key is not included on both sides
    tgt.participation_bitfield[i] =
      tgt.participation_bitfield[i] or
      src.participation_bitfield[i]

  if skipValidation notin flags:
    tgt.aggregate_signature.combine(src.aggregate_signature)

proc add*(pool: var AttestationPool,
          attestation: Attestation,
          beaconState: BeaconState) =
  # The caller of this function is responsible for ensuring that
  # the attestations will be given in a strictly slot increasing order:
  doAssert attestation.data.slot.int >= pool.startingSlot

  # TODO:
  # Validate that the attestation is authentic (it's properly signed)
  # and make sure that the validator is supposed to make an attestation
  # for the specific shard/slot

  let slotIdxInPool = attestation.data.slot.int - pool.startingSlot
  if slotIdxInPool >= pool.attestations.len:
    pool.attestations.setLen(slotIdxInPool + 1)

  let shard = attestation.data.shard

  if pool.attestations[slotIdxInPool][shard].isSome:
    combine(pool.attestations[slotIdxInPool][shard].get, attestation, {})
  else:
    pool.attestations[slotIdxInPool][shard] = some(attestation)

proc getAttestationsForBlock*(pool: AttestationPool,
                              lastState: BeaconState,
                              newBlockSlot: uint64): seq[Attestation] =
  if newBlockSlot < MIN_ATTESTATION_INCLUSION_DELAY or pool.attestations.len == 0:
    return

  doAssert newBlockSlot > lastState.slot

  var
    firstSlot = 0.uint64
    lastSlot = newBlockSlot - MIN_ATTESTATION_INCLUSION_DELAY

  if pool.startingSlot.uint64 + MIN_ATTESTATION_INCLUSION_DELAY <= lastState.slot:
    firstSlot = lastState.slot - MIN_ATTESTATION_INCLUSION_DELAY

  for slot in firstSlot .. lastSlot:
    let slotDequeIdx = slot.int - pool.startingSlot
    if slotDequeIdx >= pool.attestations.len: return
    let shardAndComittees = get_shard_committees_at_slot(lastState, slot)
    for s in shardAndComittees:
      if pool.attestations[slotDequeIdx][s.shard].isSome:
        result.add pool.attestations[slotDequeIdx][s.shard].get

proc discardHistoryToSlot*(pool: var AttestationPool, slot: int) =
  ## The index is treated inclusively
  let slot = slot - MIN_ATTESTATION_INCLUSION_DELAY.int
  if slot < pool.startingSlot:
    return
  let slotIdx = int(slot - pool.startingSlot)
  pool.attestations.shrink(fromFirst = slotIdx + 1)

func getAttestationCandidate*(attestation: Attestation): AttestationCandidate =
  # TODO: not complete AttestationCandidate object
  result.data = attestation.data
  result.signature = attestation.aggregate_signature

# ##################################################################
# Specs
#
#   The beacon chain fork choice rule is a hybrid that combines justification and finality with Latest Message Driven (LMD) Greediest Heaviest Observed SubTree (GHOST). At any point in time a [validator](#dfn-validator) `v` subjectively calculates the beacon chain head as follows.
#
#      * Let `store` be the set of attestations and blocks
#        that the validator `v` has observed and verified
#        (in particular, block ancestors must be recursively verified).
#        Attestations not part of any chain are still included in `store`.
#      * Let `finalized_head` be the finalized block with the highest slot number.
#        (A block `B` is finalized if there is a descendant of `B` in `store`
#        the processing of which sets `B` as finalized.)
#      * Let `justified_head` be the descendant of `finalized_head`
#        with the highest slot number that has been justified
#        for at least `EPOCH_LENGTH` slots.
#        (A block `B` is justified if there is a descendant of `B` in `store`
#        the processing of which sets `B` as justified.)
#        If no such descendant exists set `justified_head` to `finalized_head`.
#      * Let `get_ancestor(store, block, slot)` be the ancestor of `block` with slot number `slot`.
#        The `get_ancestor` function can be defined recursively
#
#        def get_ancestor(store, block, slot):
#            return block if block.slot == slot
#                         else get_ancestor(store, store.get_parent(block), slot)`.
#
#      * Let `get_latest_attestation(store, validator)`
#        be the attestation with the highest slot number in `store` from `validator`.
#        If several such attestations exist,
#        use the one the validator `v` observed first.
#      * Let `get_latest_attestation_target(store, validator)`
#        be the target block in the attestation `get_latest_attestation(store, validator)`.
#      * The head is `lmd_ghost(store, justified_head)`. (See specs)
#
# Departing from specs:
#   - We use a simple fork choice rule without finalized and justified head
#   - We don't implement "get_latest_attestation(store, validator) -> Attestation"
#     nor get_latest_attestation_target

func getVoteCount(participation_bitfield: openarray[byte]): int =
  ## Get the number of votes
  # TODO: A bitfield type that tracks that information
  # https://github.com/status-im/nim-beacon-chain/issues/19

  for validatorIdx in 0 ..< participation_bitfield.len * 8:
    result += int participation_bitfield.bitIsSet(validatorIdx)

func getAttestationVoteCount(pool: AttestationPool, state: BeaconState): CountTable[BlockHash] =
  ## Returns all blocks that were attested and their vote count for a specific slot.
  # This replaces:
  #   - get_latest_attestation,
  #   - get_latest_attestation_targets
  # that are used in lmd_ghost for
  # ```
  # attestation_targets = [get_latest_attestation_target(store, validator)
  #                        for validator in active_validators]
  # ```
  # Note that attestation_targets in the Eth2 specs can have duplicates
  # while the following implementation will count such blockhash multiple times instead.
  result = initCountTable[BlockHash]()
  for attestation in pool.attestations[state.slot.int - pool.startingSlot]:
    if attestation.isSome:
      # Increase the block attestation counts by the number of validators aggregated
      let voteCount = attestation.get.participation_bitfield.getVoteCount()
      result.inc(attestation.get.data.beacon_block_root, voteCount)

func getParent(db: BeaconChainDB, blck: BeaconBlock): BeaconBlock =
  db.blocks[blck.parent_root]

func get_ancestor(store: BeaconChainDB, blck: BeaconBlock, slot: uint64): BeaconBlock =
  ## Find the ancestor with a specific slot number
  if blck.slot == slot:
    return blck
  else:
    return store.get_ancestor(store.get_parent(blck), slot)
  # TODO: what if the slot was never observed/verified?

func lmdGhost*(store: BeaconChainDB, pool: AttestationPool, state: BeaconState): BeaconBlock =
  # Recompute the new head of the beacon chain according to
  # LMD GHOST (Latest Message Driven - Greediest Heaviest Observed SubTree)
  let validators = state.validator_registry

  var active_validators: seq[ValidatorRecord]
  for i in validators.get_active_validator_indices:
    active_validators.add validators[i]
