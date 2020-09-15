# beacon_chain
# Copyright (c) 2018-2020 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  # Standard library
  std/tables,
  # Status
  eth/db/kvstore,
  chronicles,
  nimcrypto/[hash, utils],
  serialization,
  json_serialization,
  # Internal
  ./spec/[datatypes, digest, crypto],
  ./ssz

# Requirements
# --------------------------------------------
#
# Overview of slashing and how it ties in with the rest of Eth2.0
#
# Phase 0 for humans - Validator responsibilities:
# - https://notes.ethereum.org/@djrtwo/Bkn3zpwxB#Validator-responsibilities
#
# Phase 0 spec - Honest Validator - how to avoid slashing
# - https://github.com/ethereum/eth2.0-specs/blob/v0.12.2/specs/phase0/validator.md#how-to-avoid-slashing
#
# In-depth reading on slashing conditions
#
# - Detecting slashing conditions https://hackmd.io/@n0ble/By897a5sH
# - Open issue on writing a slashing detector https://github.com/ethereum/eth2.0-pm/issues/63
# - Casper the Friendly Finality Gadget, Vitalik Buterin and Virgil Griffith
#   https://arxiv.org/pdf/1710.09437.pdf
#   Figure 2
#   An individual validator ν MUST NOT publish two distinct votes,
#   〈ν,s1,t1,h(s1),h(t1) AND〈ν,s2,t2,h(s2),h(t2)〉,
#   such that either:
#   I. h(t1) = h(t2).
#      Equivalently, a validator MUST NOT publish two distinct votes for the same target height.
#   OR
#   II. h(s1) < h(s2) < h(t2) < h(t1).
#      Equivalently, a validator MUST NOT vote within the span of its other votes.
# - Vitalik's annotated spec: https://github.com/ethereum/annotated-spec/blob/d8c51af84f9f309d91c37379c1fcb0810bc5f10a/phase0/beacon-chain.md#proposerslashing
#   1. A proposer can get slashed for signing two distinct headers at the same slot.
#   2. An attester can get slashed for signing
#      two attestations that together violate
#      the Casper FFG slashing conditions.
# - https://github.com/ethereum/eth2.0-specs/blob/v0.12.2/specs/phase0/validator.md#ffg-vote
#   The "source" is the current_justified_epoch
#   The "target" is the current_epoch
#
# Reading on weak subjectivity
# - https://notes.ethereum.org/@adiasg/weak-subjectvity-eth2
# - https://www.symphonious.net/2019/11/27/exploring-ethereum-2-weak-subjectivity-period/
# - https://ethresear.ch/t/weak-subjectivity-under-the-exit-queue-model/5187
#
# Reading of interop serialization format
# - Import/export format: https://hackmd.io/@sproul/Bk0Y0qdGD
# - Tests: https://github.com/eth2-clients/slashing-protection-interchange-tests
#
# Relaxation for Nimbus
#
# We are not building a slashing detector but only protecting
# attached validator from slashing, hence we make the following assumptions
#
# 1. We only need to store specific validators signed blocks and attestations
# 2. We assume that our node is synced past
#    the last finalized epoch
#    hence we only need to keep track of blocks and attestations
#    since the last finalized epoch and we don't need to care
#    about the weak subjectivity period.
#    i.e. if `Node.isSynced()` returns false
#    a node skips its validator duties and doesn't invoke slashing protection.
#    and `isSynced` syncs at least up to the blockchain last finalized epoch.
#
# Hence the database or key-value store should support
#
# Queries
# 1. db.signedBlockExistsFor(validator, slot) -> bool
# 2. db.attestationExistsFor(validator, target_epoch) -> bool
# 3. db.attestationSurrounds(validator, source_epoch, target_epoch)
#
# Update
# 1. db.registerBlock(validator, slot, block_root)
# 2. db.registerAttestation(validator, source_epoch, target_epoch, attestation_root)
#
# Maintenance
# 1. db.prune(finalized_epoch)
#
# Interop
# 1. db.import(json)
# 2. db.export(json)
# 3. db.export(json, validator)
# 4. db.export(json, seq[validator])

# Technical Discussion
# --------------------------------------------
#
# TODO: Merge with BeaconChainDB?
# - https://stackoverflow.com/questions/21844479/multiple-databases-vs-single-database-with-logically-partitioned-data
#
# Reasons for merging
# - Single database
#
# Reasons for not merging
# - BeaconChainDB is about the beacon node itself
#   while slashing protection is about validators
# - BeaconChainDB is append-only
#   while slashing protection will be pruned
#   at each finalization.
#   Hence we might want different backend in the future
# - In a VC/BN split configuration the slashing protection
#   may be better attached to the VC. (VC: Validator Client, BN: Beacon Node)
# - The slashing protection DB only held cryptographic hashes
#   and epoch/slot integers which are uncompressible
#   while BeaconChainDB is snappy-compressed.
#
# TODO: if we enshrine the split we likely want to use
#       a relational DB instead of KV-Store,
#       for efficient pruning and range queries support

# DB primitives
# --------------------------------------------
# Implementation
#
# As mentioned in the technical discussion
# we currently use a simple KV-store abstraction
# with no range queries or iterators.
#
# To support our requirements
# we store block proposals and attestations
# as per-validator linked lists

type
  SlashingProtectionDB* = ref object
    ## Database storing the blocks attested
    ## by validators attached to a beacon node
    ## or validator client.
    backend: KvStoreRef

  BadVoteKind* = enum
    ## Attestation bad vote kind
    # h: height (i.e. epoch for attestation, slot for blocks)
    # t: target
    # s: source
    # 1: existing attestations
    # 2: candidate attestation

    # Spec slashing condition
    DoubleVote           # h(t1) = h(t2)
    SurroundedVote       # h(s1) < h(s2) < h(t2) < h(t1)
    SurroundingVote      # h(s2) < h(s1) < h(t1) < h(t2)
    # Non-spec, should never happen in a well functioning client
    TargetPrecedesSource # h(t1) < h(s1) - current epoch precedes last justified epoch

  BadVote* = object
    case kind*: BadVoteKind
    of DoubleVote:
      existingAttestation*: Eth2Digest
    of SurroundedVote, SurroundingVote:
      existingAttestationRoot*: Eth2Digest # Many roots might be in conflict
      sourceExisting*, targetExisting*: Epoch
      sourceSlashable*, targetSlashable*: Epoch
    of TargetPrecedesSource:
      discard

  SlotDesc = object
    # Using tuple instead of objects, crashes the Nim compiler
    # with SSZ serialization
    # Making this generic as well
    start, stop: Slot
    isInit: bool
  EpochDesc = object
    start, stop: Epoch
    isInit: bool

  KeysEpochs = object
    ## Per-validator linked lists start/stop
    blockSlots: SlotDesc
    sourceEpochs: EpochDesc
    targetEpochs: EpochDesc

  SlashingKeyKind = enum
    # Note: source epochs are not unique
    # and so cannot be used to build a key
    kBlock
    kTargetEpoch
    kLinkedListMeta
    # Interchange format
    kGenesisValidatorRoot
    kNumValidators
    kValidator

  BlockNode = object
    prev, next: Slot
    # TODO distinct type for block root vs all other ETH2Digest
    block_root: Eth2Digest

  TargetEpochNode = object
    prev, next: Epoch
    # TODO distinct type for attestation root vs all other ETH2Digest
    attestation_root: Eth2Digest
    source: Epoch

  ValID = array[RawPubKeySize, byte]
    ## This is the serialized byte representation
    ## of a Validator Public Key.
    ## Portable between Miracl/BLST
    ## and limits serialization/deserialization call

{.push raises: [Defect].}
logScope:
  topics = "antislash"

const UseSlashingProtection* {.booldefine.} = false

when UseSlashingProtection:
  static: echo "  Built with slashing protection"
else:
  static: echo "  Built without slashing protection"

func subkey(
       kind: static SlashingKeyKind,
       validator: ValID,
       slot: Slot
     ): array[RawPubKeySize+8, byte] =
  static: doAssert kind == kBlock

  # Big endian to get a naturally ascending order on slots in sorted indices
  result[0..<8] = toBytesBE(slot.uint64)
  # .. but 7 bytes should be enough for slots - in return, we get a nicely
  # rounded key length
  result[0] = byte ord(kBlock)
  result[8..<56] = validator

func subkey(
       kind: static SlashingKeyKind,
       validator: ValID,
       epoch: Epoch
     ): array[RawPubKeySize+8, byte] =
  static: doAssert kind == kTargetEpoch, "Got invalid kind " & $kind

  # Big endian to get a naturally ascending order on slots in sorted indices
  result[0..<8] = toBytesBE(epoch.uint64)
  # .. but 7 bytes should be enough for slots - in return, we get a nicely
  # rounded key length
  result[0] = byte ord(kind)
  result[8..<56] = validator

func subkey(
       kind: static SlashingKeyKind,
       validator: ValID
     ): array[RawPubKeySize+1, byte] =
  static: doAssert kind == kLinkedListMeta

  result[0] = byte ord(kLinkedListMeta)
  result[1 .. ^1] = validator

func subkey(kind: static SlashingKeyKind): array[1, byte] =
  static: doAssert kind in {kNumValidators, kGenesisValidatorRoot}
  result[0] = byte ord(kind)

func subkey(kind: static SlashingKeyKind, valIndex: uint32): array[5, byte] =
  static: doAssert kind == kValidator
  # Big endian to get a naturally ascending order on slots in sorted indices
  result[1..<5] = toBytesBE(valIndex)
  result[0] = byte ord(kind)

proc put(db: SlashingProtectionDB, key: openarray[byte], v: auto) =
  db.backend.put(
    key,
    SSZ.encode(v)
  ).expect("working database")

proc get(db: SlashingProtectionDB,
         key: openarray[byte],
         T: typedesc): Opt[T] =

  const ExpectedNodeSszSize = block:
    when T is BlockNode:
      2*sizeof(Epoch) + sizeof(Eth2Digest)
    elif T is TargetEpochNode:
      2*sizeof(Epoch) + sizeof(Eth2Digest) + sizeof(Epoch)
    elif T is KeysEpochs:
      2*sizeof(Slot) + 4*sizeof(Epoch) + 3*sizeof(bool)
    elif T is Eth2Digest:
      sizeof(Eth2Digest)
    elif T is uint32:
      sizeof(uint32)
    elif T is ValidatorPubKey:
      RawPubKeySize
    else:
      {.error: "Invalid database node type: " & $T.}
  ## SSZ serialization is packed
  ## However in-memory, BlockNode, TargetEpochNode
  ## might be bigger due to alignment/compiler padding

  var res: Opt[T]
  proc decode(data: openArray[byte]) =
    # We are capturing "result" and "T" from outer scope
    # And allocating on the heap which are not ideal
    # from a safety and performance point of view.
    try:
      if data.len == ExpectedNodeSszSize:
        when T is ValidatorPubKey:
          # symbol resolution bug
          # SSZ.decode doesn't see "fromSSZBytes"
          res.ok ValidatorPubKey.fromSszBytes(data)
        else:
          res.ok SSZ.decode(data, T) # captures from `get` scope
      else:
        # If the data can't be deserialized, it could be because it's from a
        # version of the software that uses a different SSZ encoding
        warn "Unable to deserialize data, old database?",
          typ = $T,
          dataLen = data.len,
          expectedSize = ExpectedNodeSszSize
        discard
    except SerializationError as e:
      # If the data can't be deserialized, it could be because it's from a
      # version of the software that uses a different SSZ encoding
      warn "Unable to deserialize data, old database?",
        typ = $T,
        dataLen = data.len,
        expectedSize = ExpectedNodeSszSize
      discard

  discard db.backend.get(key, decode).expect("working database")

  res

proc setGenesis(db: SlashingProtectionDB, genesis_validator_root: Eth2Digest) =
  # Workaround SSZ / nim-serialization visibility issue
  # "template WriterType(T: type SSZ): type"
  # by having a non-generic proc
  db.put(
    subkey(kGenesisValidatorRoot),
    genesis_validator_root
  )

proc init*(
       T: type SlashingProtectionDB,
       genesis_validator_root: Eth2Digest,
       backend: KVStoreRef): SlashingProtectionDB =
  when UseSlashingProtection:
    result = T(backend: backend)
    result.setGenesis(genesis_validator_root)

proc close*(db: SlashingProtectionDB) =
  when UseSlashingProtection:
    discard db.backend.close()

# DB Queries
# --------------------------------------------

proc notSlashableBlockProposalImpl(
       db: SlashingProtectionDB,
       validator: ValidatorPubKey,
       slot: Slot
     ): Result[void, Eth2Digest] =
  ## Returns an error if the specified validator
  ## already proposed a block for the specified slot.
  ## This would lead to slashing.
  ## The error contains the blockroot that was already proposed
  ##
  ## Returns success otherwise
  # TODO distinct type for the result block root
  let valID = validator.toRaw()
  let foundBlock = db.get(
    subkey(kBlock, valID, slot),
    BlockNode
  )
  if foundBlock.isNone():
    return ok()
  return err(foundBlock.unsafeGet().block_root)

proc notSlashableBlockProposal*(
       db: SlashingProtectionDB,
       validator: ValidatorPubKey,
       slot: Slot
     ): Result[void, Eth2Digest] =
  ## Returns an error if the specified validator
  ## already proposed a block for the specified slot.
  ## This would lead to slashing.
  ## The error contains the blockroot that was already proposed
  ##
  ## Returns success otherwise
  # TODO distinct type for the result block root
  when UseSlashingProtection:
    notSlashableBlockProposalImpl(
      db, validator, slot
    )
  else:
    ok()

proc notSlashableAttestationImpl(
       db: SlashingProtectionDB,
       validator: ValidatorPubKey,
       source: Epoch,
       target: Epoch
     ): Result[void, BadVote] =
  ## Returns an error if the specified validator
  ## already proposed a block for the specified slot.
  ## This would lead to slashing.
  ## The error contains the blockroot that was already proposed
  ##
  ## Returns success otherwise
  # TODO distinct type for the result attestation root

  let valID = validator.toRaw()

  # Sanity
  # ---------------------------------
  if source > target:
    return err(BadVote(kind: TargetPrecedesSource))

  # Casper FFG 1st slashing condition
  # Detect h(t1) = h(t2)
  # ---------------------------------
  let foundAttestation = db.get(
    subkey(kTargetEpoch, valID, target),
    TargetEpochNode
  )
  if foundAttestation.isSome():
    # Logged by caller
    return err(BadVote(
      kind: DoubleVote,
      existingAttestation: foundAttestation.unsafeGet().attestation_root
    ))

  # TODO: we hack KV-store range queries
  # ---------------------------------
  let maybeLL = db.get(
    subkey(kLinkedListMeta, valID),
    KeysEpochs
  )

  if maybeLL.isNone:
    info "No slashing protection data - first attestation?",
      validator = validator,
      attSource = source,
      attTarget = target
    return ok()
  let ll = maybeLL.unsafeGet()
  if not ll.targetEpochs.isInit:
    info "No attestation slashing protection data - first attestation?",
      validator = validator,
      attSource = source,
      attTarget = target
    return ok()

  # Chain reorg
  # Detect h(s2) < h(s1)
  # If the candidate attestation source precedes
  # source(s) we have in the SlashingProtectionDB
  # we have a chain reorg
  # ---------------------------------
  if source < ll.sourceEpochs.stop:
    warn "Detected a chain reorg",
      earliestJustifiedEpoch = ll.sourceEpochs.start,
      oldestJustifiedEpoch = ll.sourceEpochs.stop,
      reorgJustifiedEpoch = source,
      monitoredValidator = validator

  # Casper FFG 2nd slashing condition
  # -> Surrounded vote
  # Detect h(s1) < h(s2) < h(t2) < h(t1)
  # ---------------------------------
  # Casper FFG 2nd slashing condition
  # -> Surrounding vote
  # Detect h(s2) < h(s1) < h(t1) < h(t2)
  # ---------------------------------

  template s2: untyped = source
  template t2: untyped = target

  # We start from the final target epoch
  var t1: Epoch
  var t1Node: TargetEpochNode

  t1 = ll.targetEpochs.stop
  t1Node = db.get(
    subkey(kTargetEpoch, valID, t1),
    TargetEpochNode
    # bug in Nim results, ".e" field inaccessible
    # ).expect("Consistent linked-list in DB")
  ).unsafeGet()
  template s1: untyped = t1Node.source
  template ar1: untyped = t1Node.attestation_root

  # Surrounding vote
  while true:
    if not(t1 < t2):
      # s1|s2 < t2 < t1 -> surrounded vote case
      break
    if s2 < s1:
      # s2 < s1 < t1 < t2
      # Logged by caller
      return err(BadVote(
        kind: SurroundingVote,
        existingAttestationRoot: ar1,
        sourceExisting: s1,
        targetExisting: t1,
        sourceSlashable: s2,
        targetSlashable: t2
      ))

    # Next iteration
    if t1Node.prev == default(Epoch) or
        t1Node.prev == ll.targetEpochs.stop:
      return ok()
    else:
      t1 = t1Node.prev
      t1Node = db.get(
        subkey(kTargetEpoch, valID, t1Node.prev),
        TargetEpochNode
        # bug in Nim results, ".e" field inaccessible
        # ).expect("Consistent linked-list in DB")
      ).unsafeGet()

  # Surrounded vote
  doAssert t2 < t1, "Checking surrounded vote"
  while true:
    if t1 < s2:
      # s1 < t1 < s2 < t2
      return ok()
    if s1 < s2:
      # s1 < s2 < t2 < t1
      # Logged by caller
      return err(BadVote(
        kind: SurroundedVote,
        existingAttestationRoot: ar1,
        sourceExisting: s1,
        targetExisting: t1,
        sourceSlashable: s2,
        targetSlashable: t2
      ))

    # Next iteration
    if t1Node.prev == default(Epoch) or
        t1Node.prev == ll.targetEpochs.stop:
      return ok()
    else:
      t1 = t1Node.prev
      t1Node = db.get(
        subkey(kTargetEpoch, valID, t1Node.prev),
        TargetEpochNode
        # bug in Nim results, ".e" field inaccessible
        # ).expect("Consistent linked-list in DB")
      ).unsafeGet()

  doAssert false, "Unreachable"

proc notSlashableAttestation*(
       db: SlashingProtectionDB,
       validator: ValidatorPubKey,
       source: Epoch,
       target: Epoch
     ): Result[void, BadVote] =
  ## Returns an error if the specified validator
  ## already proposed a block for the specified slot.
  ## This would lead to slashing.
  ## The error contains the blockroot that was already proposed
  ##
  ## Returns success otherwise
  # TODO distinct type for the result attestation root
  when UseSlashingProtection:
    notSlashableAttestationImpl(
      db, validator, source, target
    )
  else:
    ok()

# DB update
# --------------------------------------------

proc registerValidator(db: SlashingProtectionDB, validator: ValidatorPubKey) =
  ## Add a new validator to the database
  ## Assumes the validator does not exist
  let maybeNumVals = db.get(
    subkey(kNumValidators),
    uint32
  )
  var valIndex = 0'u32
  if maybeNumVals.isNone():
    db.put(subkey(kNumValidators), 1'u32)
  else:
    valIndex = maybeNumVals.unsafeGet()
    db.put(subkey(kNumValidators), valIndex + 1)

  db.put(subkey(kValidator, valIndex), validator)

proc registerBlockImpl(
       db: SlashingProtectionDB,
       validator: ValidatorPubKey,
       slot: Slot, block_root: Eth2Digest) =
  ## Add a block to the slashing protection DB
  ## `notSlashableBlockProposal` MUST be run
  ## before to ensure no overwrite.

  let valID = validator.toRaw()

  # We want to keep the linked-list ordered
  # to ease pruning.
  # TODO: DB instead of KV-store,
  # at the very least we should isolate that logic
  let maybeLL = db.get(
    subkey(kLinkedListMeta, valID),
    KeysEpochs
  )

  if maybeLL.isNone:
    info "No slashing protection data - initiating block tracking for validator",
      validator = validator

    db.registerValidator(validator)

    let node = BlockNode(
      block_root: block_root
    )
    db.put(subkey(kBlock, valID, slot), node)
    db.put(
      subkey(kLinkedListMeta, valID),
      KeysEpochs(
        blockSlots: SlotDesc(start: slot, stop: slot, isInit: true),
        # targetEpochs.isInit will be false
      )
    )
    return

  var ll = maybeLL.unsafeGet()
  var cur = ll.blockSlots.stop
  if not ll.blockSlots.isInit:
    let node = BlockNode(
      block_root: block_root
    )
    ll.blockSlots = SlotDesc(start: slot, stop: slot, isInit: true)
    db.put(subkey(kBlock, valID, slot), node)
    # TODO: what if crash here?
    db.put(subkey(kLinkedListMeta, valID), ll)
    return

  if cur < slot:
    # Adding a block later than all known blocks
    let node = BlockNode(
      prev: cur,
      block_root: block_root
    )
    var prevNode = db.get(
      subkey(kBlock, valID, cur),
      BlockNode
      # bug in Nim results, ".e" field inaccessible
      # ).expect("Consistent linked-list in DB")
    ).unsafeGet()
    prevNode.next = slot
    ll.blockSlots.stop = slot
    db.put(subkey(kBlock, valID, slot), node)
    db.put(subkey(kBlock, valID, cur), prevNode)
    # TODO: what if crash here?
    db.put(subkey(kLinkedListMeta, valID), ll)
    return

  # TODO: we likely want a proper DB or better KV-store high-level API
  #       in the future.
  while true:
    var curNode = db.get(
      subkey(kBlock, valID, cur),
      BlockNode
      # bug in Nim results, ".e" field inaccessible
      # ).expect("Consistent linked-list in DB")
    ).unsafeGet()

    if curNode.prev == ll.blockSlots.start:
      # Reached the beginning
      # Change: Metadata.start <-> cur
      # to: Metadata.start <-> new <-> cur
      # This should happen only if registerBlock
      # is called out-of-order
      warn "Validator proposal in the past - out-of-order antislash registration?",
        validator = validator,
        slot = slot,
        blockroot = blockroot,
        earliestBlockProposalSlotInDB = ll.blockSlots.start,
        latestBlockProposalSlotInDB = ll.blockSlots.stop
      var node = BlockNode(
        prev: ll.blockSlots.start,
        next: cur,
        block_root: block_root
      )
      ll.blockSlots.start = slot
      curNode.prev = slot
      db.put(subkey(kBlock, valID, slot), node)
      # TODO: what if crash here?
      db.put(subkey(kBlock, valID, cur), curNode)
      db.put(subkey(kLinkedListMeta, valID), ll)
      return
    elif slot < curNode.prev:
      # Reached: prev < slot < cur
      # Change: prev <-> cur
      # to: prev <-> new <-> cur
      let prev = curNode.prev
      var node = BlockNode(
        prev: prev, next: cur,
        block_root: block_root
      )
      var prevNode = db.get(
        subkey(kBlock, valID, prev),
        BlockNode
        # bug in Nim results, ".e" field inaccessible
        # ).expect("Consistent linked-list in DB")
      ).unsafeGet()
      prevNode.next = slot
      curNode.prev = slot
      db.put(subkey(kBlock, valID, slot), node)
      # TODO: what if crash here?
      db.put(subkey(kBlock, valID, cur), curNode)
      db.put(subkey(kBlock, valID, prev), prevNode)
      return

    # Previous
    cur = curNode.prev
    curNode = db.get(
      subkey(kBlock, valID, cur),
      BlockNode
      # bug in Nim results, ".e" field inaccessible
      # ).expect("Consistent linked-list in DB")
    ).unsafeGet()

proc registerBlock*(
       db: SlashingProtectionDB,
       validator: ValidatorPubKey,
       slot: Slot, block_root: Eth2Digest) =
  ## Add a block to the slashing protection DB
  ## `notSlashableBlockProposal` MUST be run
  ## before to ensure no overwrite.
  when UseSlashingProtection:
    registerBlockImpl(
      db, validator, slot, block_root
    )
  else:
    discard

proc registerAttestationImpl(
       db: SlashingProtectionDB,
       validator: ValidatorPubKey,
       source, target: Epoch,
       attestation_root: Eth2Digest) =
  ## Add an attestation to the slashing protection DB
  ## `notSlashableAttestation` MUST be run
  ## before to ensure no overwrite.

  let valID = validator.toRaw()

  # We want to keep the linked-list ordered
  # to ease pruning.
  # TODO: DB instead of KV-store,
  # at the very least we should isolate that logic
  let maybeLL = db.get(
    subkey(kLinkedListMeta, valID),
    KeysEpochs
  )

  if maybeLL.isNone:
    info "No slashing protection data - initiating attestation tracking for validator",
      validator = validator

    db.registerValidator(validator)

    let node = TargetEpochNode(
      source: source,
      attestation_root: attestation_root
    )
    db.put(subkey(kTargetEpoch, valID, target), node)
    db.put(
      subkey(kLinkedListMeta, valID),
      KeysEpochs(
        # blockSlots.isInit will be false
        sourceEpochs: EpochDesc(start: source, stop: source, isInit: true),
        targetEpochs: EpochDesc(start: target, stop: target, isInit: true)
      )
    )
    return

  var ll = maybeLL.unsafeGet()
  var cur = ll.targetEpochs.stop
  if not ll.targetEpochs.isInit:
    let node = TargetEpochNode(
      attestation_root: attestation_root,
      source: source
    )
    ll.targetEpochs = EpochDesc(start: target, stop: target, isInit: true)
    ll.sourceEpochs = EpochDesc(start: source, stop: source, isInit: true)
    db.put(subkey(kTargetEpoch, valID, target), node)
    # TODO: what if crash here?
    db.put(subkey(kLinkedListMeta, valID), ll)
    return

  block: # Update source epoch
    if ll.sourceEpochs.stop < source:
      ll.sourceEpochs.stop = source
    if source < ll.sourceEpochs.start:
      ll.sourceEpochs.start = source

  if cur < target:
    # Adding an attestation later than all known blocks
    let node = TargetEpochNode(
      prev: cur,
      source: source,
      attestation_root: attestation_root
    )
    var prevNode = db.get(
      subkey(kTargetEpoch, valID, cur),
      TargetEpochNode
      # bug in Nim results, ".e" field inaccessible
      # ).expect("Consistent linked-list in DB")
    ).unsafeGet()
    prevNode.next = target
    ll.targetEpochs.stop = target
    db.put(subkey(kTargetEpoch, valID, target), node)
    db.put(subkey(kTargetEpoch, valID, cur), prevNode)
    # TODO: what if crash here?
    db.put(subkey(kLinkedListMeta, valID), ll)
    return

  # TODO: we likely want a proper DB or better KV-store high-level API
  #       in the future.
  while true:
    var curNode = db.get(
      subkey(kTargetEpoch, valID, cur),
      TargetEpochNode
      # bug in Nim results, ".e" field inaccessible
      # ).expect("Consistent linked-list in DB")
    ).unsafeGet()
    if curNode.prev == ll.targetEpochs.start:
      # Reached the beginning
      # Change: Metadata.start <-> cur
      # to: Metadata.start <-> new <-> cur
      # This should happen only if registerAttestation
      # is called out-of-order or if the validator
      # changes its vote for an earlier fork than its latest vote
      warn "Validator vote targeting the past - out-of-order antislash registration or chain reorg?",
        validator = validator,
        source_epoch = source,
        target_epoch = target,
        attestation_root = attestation_root
      var node = TargetEpochNode(
        prev: ll.targetEpochs.start,
        next: cur,
        source: source,
        attestation_root: attestation_root
      )
      ll.targetEpochs.start = target
      curNode.prev = target
      db.put(subkey(kTargetEpoch, valID, target), node)
      # TODO: what if crash here?
      db.put(subkey(kTargetEpoch, valID, cur), curNode)
      db.put(subkey(kLinkedListMeta, valID), ll)
      return
    elif target < curNode.prev:
      # Reached: prev < target < cur
      # Change: prev <-> cur
      # to: prev <-> new <-> cur
      let prev = curNode.prev
      var node = TargetEpochNode(
        prev: prev, next: cur,
        source: source,
        attestation_root: attestation_root
      )
      var prevNode = db.get(
        subkey(kTargetEpoch, valID, prev),
        TargetEpochNode
        # bug in Nim results, ".e" field inaccessible
        # ).expect("Consistent linked-list in DB")
      ).unsafeGet()
      prevNode.next = target
      curNode.prev = target
      db.put(subkey(kTargetEpoch, valID, target), node)
      # TODO: what if crash here?
      db.put(subkey(kTargetEpoch, valID, cur), curNode)
      db.put(subkey(kTargetEpoch, valID, prev), prevNode)
      return

    # Previous
    cur = curNode.prev
    curNode = db.get(
      subkey(kTargetEpoch, valID, cur),
      TargetEpochNode
      # bug in Nim results, ".e" field inaccessible
      # ).expect("Consistent linked-list in DB")
    ).unsafeGet()

proc registerAttestation*(
       db: SlashingProtectionDB,
       validator: ValidatorPubKey,
       source, target: Epoch,
       attestation_root: Eth2Digest) =
  ## Add an attestation to the slashing protection DB
  ## `notSlashableAttestation` MUST be run
  ## before to ensure no overwrite.
  when UseSlashingProtection:
    registerAttestationImpl(
      db, validator, source, target, attestation_root
    )
  else:
    discard

# DB maintenance
# --------------------------------------------
# TODO: pruning
# Note that the complete interchange format
# requires all proposals/attestations ever and so prevent pruning.

# Interchange
# --------------------------------------------

type
  SPDIF = object
    ## Slashing Protection Database Interchange Format
    metadata: SPDIF_Meta
    data: seq[SPDIF_Validator]

  Eth2Digest0x = distinct Eth2Digest
    ## The spec mandates "0x" prefix on serialization
    ## So we need to set custom read/write
  PubKey0x = distinct ValidatorPubKey
    ## The spec mandates "0x" prefix on serialization
    ## So we need to set custom read/write

  SPDIF_Meta = object
    interchange_format: string
    interchange_format_version: string
    genesis_validator_root: Eth2Digest0x

  SPDIF_Validator = object
    pubkey: PubKey0x
    signed_blocks: seq[SPDIF_SignedBlock]
    signed_attestations: seq[SPDIF_SignedAttestation]

  SPDIF_SignedBlock = object
    slot: Slot
    signing_root: Eth2Digest0x # compute_signing_root(block, domain)

  SPDIF_SignedAttestation = object
    source_epoch: Epoch
    target_epoch: Epoch
    signing_root: Eth2Digest0x # compute_signing_root(attestation, domain)

proc writeValue*(writer: var JsonWriter, value: PubKey0x)
                {.inline, raises: [IOError, Defect].} =
  writer.writeValue("0x" & value.ValidatorPubKey.toHex())

proc readValue*(reader: var JsonReader, value: var PubKey0x)
               {.raises: [SerializationError, IOError, Defect].} =
  let key = ValidatorPubKey.fromHex(reader.readValue(string))
  if key.isOk:
    value = PubKey0x key.get
  else:
    # TODO: Can we provide better diagnostic?
    raiseUnexpectedValue(reader, "Valid hex-encoded public key expected")

proc writeValue*(w: var JsonWriter, a: Eth2Digest0x)
                {.inline, raises: [IOError, Defect].} =
  w.writeValue "0x" & a.Eth2Digest.data.toHex(lowercase = true)

proc readValue*(r: var JsonReader, a: var Eth2Digest0x)
               {.raises: [SerializationError, IOError, Defect].} =
  try:
    a = Eth2Digest0x fromHex(Eth2Digest, r.readValue(string))
  except ValueError:
    raiseUnexpectedValue(r, "Hex string expected")

proc toSPDIF*(db: SlashingProtectionDB, path: string)
             {.raises: [IOError, Defect].} =
  ## Export the full slashing protection database
  ## to a json the Slashing Protection Database Interchange Format
  var extract: SPDIF
  extract.metadata.interchange_format = "complete"
  extract.metadata.interchange_format_version = "3"
  extract.metadata.genesis_validator_root = Eth2Digest0x db.get(
    subkey(kGenesisValidatorRoot), ETH2Digest
    # Bug in results.nim
    # ).expect("Slashing Protection requires genesis_validator_root at init")
  ).unsafeGet()

  let maybeNumVals = db.get(
    subkey(kNumValidators),
    uint32
  )
  var numValidators = 0'u32
  if maybeNumVals.isSome():
    numValidators = maybeNumVals.unsafeGet()

  for i in 0'u32 ..< numValidators:
    var validator: SPDIF_Validator
    validator.pubkey = PubKey0x db.get(
      subkey(kValidator, i),
      ValidatorPubKey
    ).unsafeGet()

    let valID = validator.pubkey.ValidatorPubKey.toRaw()
    let ll = db.get(
      subkey(kLinkedListMeta, valID),
      KeysEpochs
    ).unsafeGet()

    if ll.blockSlots.isInit:
      var curSlot = ll.blockSlots.start
      while true:
        let node = db.get(
          subkey(kBlock, valID, curSlot),
          BlockNode
        ).unsafeGet()

        validator.signed_blocks.add SPDIF_SignedBlock(
          slot: curSlot,
          signing_root: Eth2Digest0x node.block_root
        )

        if curSlot == ll.blockSlots.stop:
          break
        else:
          curSlot = node.next

    if ll.targetEpochs.isInit:
      var curEpoch = ll.targetEpochs.start
      var count = 0
      while true:
        let node = db.get(
          subkey(kTargetEpoch, valID, curEpoch),
          TargetEpochNode
        ).unsafeGet()

        validator.signed_attestations.add SPDIF_SignedAttestation(
          source_epoch: node.source, target_epoch: curEpoch,
          signing_root: Eth2Digest0x node.attestation_root
        )

        if curEpoch == ll.targetEpochs.stop:
          break
        else:
          curEpoch = node.next

        inc count
        doAssert count < 5

    # Update extract without reallocating seqs
    # by manually transferring ownership
    extract.data.setLen(extract.data.len + 1)
    shallowCopy(extract.data[^1], validator)

  Json.saveFile(path, extract, pretty = true)
  echo "Exported slashing protection DB to '", path, "'"
