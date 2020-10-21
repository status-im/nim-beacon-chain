# beacon_chain
# Copyright (c) 2018-2020 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [Defect].}

import
  std/[options, sequtils, tables, sets],
  metrics, snappy, chronicles,
  ../ssz/[ssz_serialization, merkleization], ../beacon_chain_db, ../extras,
  ../spec/[
    crypto, datatypes, digest, helpers, validator, state_transition,
    beaconstate],
  block_pools_types, quarantine

export block_pools_types

declareCounter beacon_reorgs_total, "Total occurrences of reorganizations of the chain" # On fork choice
declareCounter beacon_state_data_cache_hits, "EpochRef hits"
declareCounter beacon_state_data_cache_misses, "EpochRef misses"
declareCounter beacon_state_rewinds, "State database rewinds"

declareGauge beacon_pending_deposits, "Number of pending deposits (state.eth1_data.deposit_count - state.eth1_deposit_index)" # On block
declareGauge beacon_processed_deposits_total, "Number of total deposits included on chain" # On block

logScope: topics = "chaindag"

proc putBlock*(
    dag: var ChainDAGRef, signedBlock: SignedBeaconBlock) =
  dag.db.putBlock(signedBlock)

proc updateStateData*(
  dag: ChainDAGRef, state: var StateData, bs: BlockSlot, save: bool,
  cache: var StateCache) {.gcsafe.}

template withState*(
    dag: ChainDAGRef, stateData: var StateData, blockSlot: BlockSlot,
    body: untyped): untyped =
  ## Helper template that updates stateData to a particular BlockSlot - usage of
  ## stateData is unsafe outside of block.
  ## TODO async transformations will lead to a race where stateData gets updated
  ##      while waiting for future to complete - catch this here somehow?

  var cache {.inject.} = blockSlot.blck.getStateCache(blockSlot.slot.epoch())
  updateStateData(dag, stateData, blockSlot, false, cache)

  template hashedState(): HashedBeaconState {.inject, used.} = stateData.data
  template state(): BeaconState {.inject, used.} = stateData.data.data
  template blck(): BlockRef {.inject, used.} = stateData.blck
  template root(): Eth2Digest {.inject, used.} = stateData.data.root

  body

func parent*(bs: BlockSlot): BlockSlot =
  ## Return a blockslot representing the previous slot, using the parent block
  ## if the current slot had a block
  if bs.slot == Slot(0):
    BlockSlot(blck: nil, slot: Slot(0))
  else:
    BlockSlot(
      blck: if bs.slot > bs.blck.slot: bs.blck else: bs.blck.parent,
      slot: bs.slot - 1
    )

func parentOrSlot*(bs: BlockSlot): BlockSlot =
  ## Return a blockslot representing the previous slot, using the parent block
  ## with the current slot if the current had a block
  if bs.slot == Slot(0):
    BlockSlot(blck: nil, slot: Slot(0))
  elif bs.slot == bs.blck.slot:
    BlockSlot(blck: bs.blck.parent, slot: bs.slot)
  else:
    BlockSlot(blck: bs.blck, slot: bs.slot - 1)

func get_effective_balances*(state: BeaconState): seq[Gwei] =
  ## Get the balances from a state as counted for fork choice
  result.newSeq(state.validators.len) # zero-init

  let epoch = state.get_current_epoch()

  for i in 0 ..< result.len:
    # All non-active validators have a 0 balance
    template validator: Validator = state.validators[i]
    if validator.is_active_validator(epoch):
      result[i] = validator.effective_balance

proc init*(
    T: type EpochRef, state: BeaconState, cache: var StateCache,
    prevEpoch: EpochRef): T =
  let
    epoch = state.get_current_epoch()
    epochRef = EpochRef(
      epoch: epoch,
      current_justified_checkpoint: state.current_justified_checkpoint,
      finalized_checkpoint: state.finalized_checkpoint,
      shuffled_active_validator_indices:
        cache.get_shuffled_active_validator_indices(state, epoch))
  for i in 0'u64..<SLOTS_PER_EPOCH:
    let idx = get_beacon_proposer_index(
      state, cache, epoch.compute_start_slot_at_epoch() + i)
    if idx.isSome():
      epochRef.beacon_proposers[i] =
        some((idx.get(), state.validators[idx.get].pubkey))

  # Validator sets typically don't change between epochs - a more efficient
  # scheme could be devised where parts of the validator key set is reused
  # between epochs because in a single history, the validator set only
  # grows - this however is a trivially implementable compromise.

  # The validators root is cached in the state, so we can quickly compare
  # it to see if it remains unchanged - effective balances in the validator
  # information may however result in a different root, even if the public
  # keys are the same

  let validators_root = hash_tree_root(state.validators)

  template sameKeys(a: openArray[ValidatorPubKey], b: openArray[Validator]): bool =
    if a.len != b.len:
      false
    else:
      block:
        var ret = true
        for i, key in a:
          if key != b[i].pubkey:
            ret = false
            break
        ret

  if prevEpoch != nil and (
    prevEpoch.validator_key_store[0] == hash_tree_root(state.validators) or
      sameKeys(prevEpoch.validator_key_store[1][], state.validators.asSeq)):
    epochRef.validator_key_store =
      (validators_root, prevEpoch.validator_key_store[1])
  else:
    epochRef.validator_key_store = (
      hash_tree_root(state.validators),
      newClone(mapIt(state.validators.toSeq, it.pubkey)))

  # When fork choice runs, it will need the effective balance of the justified
  # checkpoint - we pre-load the balances here to avoid rewinding the justified
  # state later and compress them because not all checkpoints end up being used
  # for fork choice - specially during long periods of non-finalization
  proc snappyEncode(inp: openArray[byte]): seq[byte] =
    try:
      snappy.encode(inp)
    except CatchableError as err:
      raiseAssert err.msg

  epochRef.effective_balances_bytes =
    snappyEncode(SSZ.encode(
      List[Gwei, Limit VALIDATOR_REGISTRY_LIMIT](get_effective_balances(state))))

  epochRef

func effective_balances*(epochRef: EpochRef): seq[Gwei] =
  try:
    SSZ.decode(snappy.decode(epochRef.effective_balances_bytes, uint32.high),
      List[Gwei, Limit VALIDATOR_REGISTRY_LIMIT]).toSeq()
  except CatchableError as exc:
    raiseAssert exc.msg

func updateKeyStores*(epochRef: EpochRef, blck: BlockRef, finalized: BlockRef) =
  # Because key stores are additive lists, we can use a newer list whereever an
  # older list is expected - all indices in the new list will be valid for the
  # old list also
  var blck = blck
  while blck != nil and blck.slot >= finalized.slot:
    for e in blck.epochRefs:
      e.validator_key_store = epochRef.validator_key_store
    blck = blck.parent

func link*(parent, child: BlockRef) =
  doAssert (not (parent.root == Eth2Digest() or child.root == Eth2Digest())),
    "blocks missing root!"
  doAssert parent.root != child.root, "self-references not allowed"

  child.parent = parent

func isAncestorOf*(a, b: BlockRef): bool =
  var b = b
  var depth = 0
  const maxDepth = (100'i64 * 365 * 24 * 60 * 60 div SECONDS_PER_SLOT.int)
  while true:
    if a == b: return true

    # for now, use an assert for block chain length since a chain this long
    # indicates a circular reference here..
    doAssert depth < maxDepth
    depth += 1

    if a.slot >= b.slot or b.parent.isNil:
      return false

    doAssert b.slot > b.parent.slot
    b = b.parent

func get_ancestor*(blck: BlockRef, slot: Slot,
    maxDepth = 100'i64 * 365 * 24 * 60 * 60 div SECONDS_PER_SLOT.int):
    BlockRef =
  ## https://github.com/ethereum/eth2.0-specs/blob/v1.0.0-rc.0/specs/phase0/fork-choice.md#get_ancestor
  ## Return the most recent block as of the time at `slot` that not more recent
  ## than `blck` itself
  doAssert not blck.isNil

  var blck = blck

  var depth = 0

  while true:
    if blck.slot <= slot:
      return blck

    if blck.parent.isNil:
      return nil

    doAssert depth < maxDepth
    depth += 1

    blck = blck.parent

func atSlot*(blck: BlockRef, slot: Slot): BlockSlot =
  ## Return a BlockSlot at a given slot, with the block set to the closest block
  ## available. If slot comes from before the block, a suitable block ancestor
  ## will be used, else blck is returned as if all slots after it were empty.
  ## This helper is useful when imagining what the chain looked like at a
  ## particular moment in time, or when imagining what it will look like in the
  ## near future if nothing happens (such as when looking ahead for the next
  ## block proposal)
  BlockSlot(blck: blck.get_ancestor(slot), slot: slot)

func atEpochStart*(blck: BlockRef, epoch: Epoch): BlockSlot =
  ## Return the BlockSlot corresponding to the first slot in the given epoch
  atSlot(blck, epoch.compute_start_slot_at_epoch)

func atEpochEnd*(blck: BlockRef, epoch: Epoch): BlockSlot =
  ## Return the BlockSlot corresponding to the last slot in the given epoch
  atSlot(blck, (epoch + 1).compute_start_slot_at_epoch - 1)

func epochAncestor*(blck: BlockRef, epoch: Epoch): BlockSlot =
  ## The state transition works by storing information from blocks in a
  ## "working" area until the epoch transition, then batching work collected
  ## during the epoch. Thus, last block in the ancestor epochs is the block
  ## that has an impact on epoch currently considered.
  ##
  ## This function returns a BlockSlot pointing to that epoch boundary, ie the
  ## boundary where the last block has been applied to the state and epoch
  ## processing has been done - we will store epoch caches in that particular
  ## block so that any block in the dag that needs it can find it easily. In
  ## particular, if empty slot processing is done, there may be multiple epoch
  ## caches found there.
  var blck = blck
  while blck.slot.epoch >= epoch and not blck.parent.isNil:
    blck = blck.parent

  blck.atEpochStart(epoch)

proc getStateCache*(blck: BlockRef, epoch: Epoch): StateCache =
  # When creating a state cache, we want the current and the previous epoch
  # information to be preloaded as both of these are used in state transition
  # functions

  var res = StateCache()
  template load(e: Epoch) =
    let ancestor = blck.epochAncestor(epoch)
    for epochRef in ancestor.blck.epochRefs:
      if epochRef.epoch == e:
        res.shuffled_active_validator_indices[epochRef.epoch] =
          epochRef.shuffled_active_validator_indices

        if epochRef.epoch == epoch:
          for i, idx in epochRef.beacon_proposers:
            res.beacon_proposer_indices[
              epoch.compute_start_slot_at_epoch + i] =
                if idx.isSome: some(idx.get()[0]) else: none(ValidatorIndex)

        break

  load(epoch)

  if epoch > 0:
    load(epoch - 1)

  res

func init(T: type BlockRef, root: Eth2Digest, slot: Slot): BlockRef =
  BlockRef(
    root: root,
    slot: slot
  )

func init*(T: type BlockRef, root: Eth2Digest, blck: SomeBeaconBlock): BlockRef =
  BlockRef.init(root, blck.slot)

proc init*(T: type ChainDAGRef,
           preset: RuntimePreset,
           db: BeaconChainDB,
           updateFlags: UpdateFlags = {}): ChainDAGRef =
  # TODO we require that the db contains both a head and a tail block -
  #      asserting here doesn't seem like the right way to go about it however..

  let
    tailBlockRoot = db.getTailBlock()
    headBlockRoot = db.getHeadBlock()

  doAssert tailBlockRoot.isSome(), "Missing tail block, database corrupt?"
  doAssert headBlockRoot.isSome(), "Missing head block, database corrupt?"

  let
    tailRoot = tailBlockRoot.get()
    tailBlock = db.getBlock(tailRoot).get()
    tailRef = BlockRef.init(tailRoot, tailBlock.message)
    headRoot = headBlockRoot.get()

  let genesisRef = if tailBlock.message.slot == GENESIS_SLOT:
    tailRef
  else:
    let
      genesisBlockRoot = db.getGenesisBlockRoot()
      genesisBlock = db.getBlock(genesisBlockRoot).expect(
        "preInit should have initialized the database with a genesis block")
    BlockRef.init(genesisBlockRoot, genesisBlock.message)

  var
    blocks = {tailRef.root: tailRef}.toTable()
    headRef: BlockRef

  if genesisRef != tailRef:
    blocks[genesisRef.root] = genesisRef

  if headRoot != tailRoot:
    var curRef: BlockRef

    for blck in db.getAncestors(headRoot):
      if blck.root == tailRef.root:
        doAssert(not curRef.isNil)
        link(tailRef, curRef)
        curRef = curRef.parent
        break

      let newRef = BlockRef.init(blck.root, blck.message)
      if curRef == nil:
        curRef = newRef
        headRef = newRef
      else:
        link(newRef, curRef)
        curRef = curRef.parent
      blocks[curRef.root] = curRef
      trace "Populating block dag", key = curRef.root, val = curRef

    doAssert curRef == tailRef,
      "head block does not lead to tail, database corrupt?"
  else:
    headRef = tailRef

  var
    cur = headRef.atSlot(headRef.slot)
    tmpState = (ref StateData)()

  # Now that we have a head block, we need to find the most recent state that
  # we have saved in the database
  while cur.blck != nil:
    let root = db.getStateRoot(cur.blck.root, cur.slot)
    if root.isSome():
      if db.getState(root.get(), tmpState.data.data, noRollback):
        tmpState.data.root = root.get()
        tmpState.blck = cur.blck

        break

    if cur.blck.parent != nil and
        cur.blck.slot.epoch != epoch(cur.blck.parent.slot):
      # We store the state of the parent block with the epoch processing applied
      # in the database!
      cur = cur.blck.parent.atEpochStart(cur.blck.slot.epoch)
    else:
      # Moves back slot by slot, in case a state for an empty slot was saved
      cur = cur.parent

  if tmpState.blck == nil:
    warn "No state found in head history, database corrupt?"
    # TODO Potentially we could recover from here instead of crashing - what
    #      would be a good recovery model?
    raiseAssert "No state found in head history, database corrupt?"

  let res = ChainDAGRef(
    blocks: blocks,
    tail: tailRef,
    head: headRef,
    genesis: genesisRef,
    db: db,
    heads: @[headRef],
    headState: tmpState[],
    tmpState: tmpState[],
    clearanceState: tmpState[],

    # The only allowed flag right now is verifyFinalization, as the others all
    # allow skipping some validation.
    updateFlags: {verifyFinalization} * updateFlags,
    runtimePreset: preset,
  )

  doAssert res.updateFlags in [{}, {verifyFinalization}]

  var cache: StateCache
  res.updateStateData(res.headState, headRef.atSlot(headRef.slot), false, cache)
  # We presently save states on the epoch boundary - it means that the latest
  # state we loaded might be older than head block - nonetheless, it will be
  # from the same epoch as the head, thus the finalized and justified slots are
  # the same - these only change on epoch boundaries.
  # When we start from a snapshot state, the `finalized_checkpoint` in the
  # snapshot will point to an even older state, but we trust the tail state
  # (the snapshot) to be finalized, hence the `max` expression below.
  let finalizedEpoch = max(res.headState.data.data.finalized_checkpoint.epoch,
                           tailRef.slot.epoch)
  res.finalizedHead = headRef.atEpochStart(finalizedEpoch)

  res.clearanceState = res.headState

  info "Block dag initialized",
    head = shortLog(headRef),
    finalizedHead = shortLog(res.finalizedHead),
    tail = shortLog(tailRef),
    totalBlocks = blocks.len

  res

proc findEpochRef*(blck: BlockRef, epoch: Epoch): EpochRef = # may return nil!
  let ancestor = blck.epochAncestor(epoch)
  doAssert ancestor.blck != nil
  for epochRef in ancestor.blck.epochRefs:
    if epochRef.epoch == epoch:
      return epochRef

proc getEpochRef*(dag: ChainDAGRef, blck: BlockRef, epoch: Epoch): EpochRef =
  let epochRef = blck.findEpochRef(epoch)
  if epochRef != nil:
    beacon_state_data_cache_hits.inc
    return epochRef

  beacon_state_data_cache_misses.inc

  let
    ancestor = blck.epochAncestor(epoch)

  dag.withState(dag.tmpState, ancestor):
    let
      prevEpochRef = if dag.tail.slot.epoch >= epoch: nil
                     else: blck.findEpochRef(epoch - 1)
      newEpochRef = EpochRef.init(state, cache, prevEpochRef)

    # TODO consider constraining the number of epochrefs per state
    if ancestor.blck.slot >= dag.finalizedHead.blck.slot:
      # Only cache epoch information for unfinalized blocks - earlier states
      # are seldomly used (ie RPC), so no need to cache
      ancestor.blck.epochRefs.add newEpochRef
      newEpochRef.updateKeyStores(blck.parent, dag.finalizedHead.blck)
    newEpochRef

proc getState(
    dag: ChainDAGRef, state: var StateData, stateRoot: Eth2Digest,
    blck: BlockRef): bool =
  let restoreAddr =
    # Any restore point will do as long as it's not the object being updated
    if unsafeAddr(state) == unsafeAddr(dag.headState):
      unsafeAddr dag.tmpState
    else:
      unsafeAddr dag.headState

  func restore(v: var BeaconState) =
    assign(v, restoreAddr[].data.data)

  if not dag.db.getState(stateRoot, state.data.data, restore):
    return false

  state.blck = blck
  state.data.root = stateRoot

  true

proc getState(dag: ChainDAGRef, state: var StateData, bs: BlockSlot): bool =
  ## Load a state from the database given a block and a slot - this will first
  ## lookup the state root in the state root table then load the corresponding
  ## state, if it exists
  if not bs.slot.isEpoch:
    return false # We only ever save epoch states - no need to hit database

  # TODO earlier versions would store the epoch state with a the epoch block
  #      applied - we generally shouldn't hit the database for such states but
  #      will do so in a transitionary upgrade period!

  if (let stateRoot = dag.db.getStateRoot(bs.blck.root, bs.slot);
      stateRoot.isSome()):
    return dag.getState(state, stateRoot.get(), bs.blck)

  false

proc putState*(dag: ChainDAGRef, state: StateData) =
  # Store a state and its root
  logScope:
    blck = shortLog(state.blck)
    stateSlot = shortLog(state.data.data.slot)
    stateRoot = shortLog(state.data.root)

  # As a policy, we only store epoch boundary states without the epoch block
  # (if it exists) applied - the rest can be reconstructed by loading an epoch
  # boundary state and applying the missing blocks.
  # We also avoid states that were produced with empty slots only - we should
  # not call this function for states that don't have a follow-up block
  if not state.data.data.slot.isEpoch:
    trace "Not storing non-epoch state"
    return

  if state.data.data.slot.epoch != (state.blck.slot.epoch + 1):
    trace "Not storing state that isn't an immediate epoch successor to its block"
    return

  if dag.db.containsState(state.data.root):
    return

  debug "Storing state"
  # Ideally we would save the state and the root lookup cache in a single
  # transaction to prevent database inconsistencies, but the state loading code
  # is resilient against one or the other going missing
  dag.db.putState(state.data.root, state.data.data)
  dag.db.putStateRoot(state.blck.root, state.data.data.slot, state.data.root)

func getRef*(dag: ChainDAGRef, root: Eth2Digest): BlockRef =
  ## Retrieve a resolved block reference, if available
  dag.blocks.getOrDefault(root, nil)

func getBlockRange*(
    dag: ChainDAGRef, startSlot: Slot, skipStep: uint64,
    output: var openArray[BlockRef]): Natural =
  ## This function populates an `output` buffer of blocks
  ## with a slots ranging from `startSlot` up to, but not including,
  ## `startSlot + skipStep * output.len`, skipping any slots that don't have
  ## a block.
  ##
  ## Blocks will be written to `output` from the end without gaps, even if
  ## a block is missing in a particular slot. The return value shows how
  ## many slots were missing blocks - to iterate over the result, start
  ## at this index.
  ##
  ## If there were no blocks in the range, `output.len` will be returned.
  let
    requestedCount = output.lenu64
    headSlot = dag.head.slot

  trace "getBlockRange entered",
    head = shortLog(dag.head.root), requestedCount, startSlot, skipStep, headSlot

  if startSlot < dag.tail.slot or headSlot <= startSlot or requestedCount == 0:
    return output.len # Identical to returning an empty set of block as indicated above

  let
    runway = uint64(headSlot - startSlot)

    # This is the number of blocks that will follow the start block
    extraBlocks = min(runway div skipStep, requestedCount - 1)

    # If `skipStep` is very large, `extraBlocks` should be 0 from
    # the previous line, so `endSlot` will be equal to `startSlot`:
    endSlot = startSlot + extraBlocks * skipStep

  var
    b = dag.head.atSlot(endSlot)
    o = output.len

  # Process all blocks that follow the start block (may be zero blocks)
  for i in 1..extraBlocks:
    if b.blck.slot == b.slot:
      dec o
      output[o] = b.blck
    for j in 1..skipStep:
      b = b.parent

  # We should now be at the start block.
  # Like any "block slot", it may be a missing/skipped block:
  if b.blck.slot == b.slot:
    dec o
    output[o] = b.blck

  o # Return the index of the first non-nil item in the output

func getBlockBySlot*(dag: ChainDAGRef, slot: Slot): BlockRef =
  ## Retrieves the first block in the current canonical chain
  ## with slot number less or equal to `slot`.
  dag.head.atSlot(slot).blck

func getBlockByPreciseSlot*(dag: ChainDAGRef, slot: Slot): BlockRef =
  ## Retrieves a block from the canonical chain with a slot
  ## number equal to `slot`.
  let found = dag.getBlockBySlot(slot)
  if found.slot != slot: found else: nil

proc get*(dag: ChainDAGRef, blck: BlockRef): BlockData =
  ## Retrieve the associated block body of a block reference
  doAssert (not blck.isNil), "Trying to get nil BlockRef"

  let data = dag.db.getBlock(blck.root)
  doAssert data.isSome, "BlockRef without backing data, database corrupt?"

  BlockData(data: data.get(), refs: blck)

proc get*(dag: ChainDAGRef, root: Eth2Digest): Option[BlockData] =
  ## Retrieve a resolved block reference and its associated body, if available
  let refs = dag.getRef(root)

  if not refs.isNil:
    some(dag.get(refs))
  else:
    none(BlockData)

proc advanceSlots(
    dag: ChainDAGRef, state: var StateData, slot: Slot, save: bool,
    cache: var StateCache) =
  # Given a state, advance it zero or more slots by applying empty slot
  # processing - the state must be positions at a slot before or equal to the
  # target
  doAssert state.data.data.slot <= slot
  while state.data.data.slot < slot:
    doAssert process_slots(
        state.data, state.data.data.slot + 1, cache,
        dag.updateFlags),
      "process_slots shouldn't fail when state slot is correct"
    if save:
      dag.putState(state)

proc applyBlock(
    dag: ChainDAGRef,
    state: var StateData, blck: BlockData, flags: UpdateFlags,
    cache: var StateCache): bool =
  # Apply a single block to the state - the state must be positioned at the
  # parent of the block with a slot lower than the one of the block being
  # applied
  doAssert state.blck == blck.refs.parent

  var statePtr = unsafeAddr state # safe because `restore` is locally scoped
  func restore(v: var HashedBeaconState) =
    doAssert (addr(statePtr.data) == addr v)
    statePtr[] = dag.headState

  let ok = state_transition(
    dag.runtimePreset, state.data, blck.data,
    cache, flags + dag.updateFlags + {slotProcessed}, restore)
  if ok:
    state.blck = blck.refs

  ok

proc updateStateData*(
    dag: ChainDAGRef, state: var StateData, bs: BlockSlot, save: bool,
    cache: var StateCache) =
  ## Rewind or advance state such that it matches the given block and slot -
  ## this may include replaying from an earlier snapshot if blck is on a
  ## different branch or has advanced to a higher slot number than slot
  ## If slot is higher than blck.slot, replay will fill in with empty/non-block
  ## slots, else it is ignored

  # First, see if we're already at the requested block. If we are, also check
  # that the state has not been advanced past the desired block - if it has,
  # an earlier state must be loaded since there's no way to undo the slot
  # transitions

  var
    ancestors: seq[BlockRef]
    cur = bs
    found = false

  template canAdvance(state: StateData, bs: BlockSlot): bool =
    # The block is the same and we're at an early enough slot - the state can
    # be used to arrive at the desired blockslot
    state.blck == bs.blck and state.data.data.slot <= bs.slot

  # First, run a quick check if we can simply apply a few blocks to an in-memory
  # state - any in-memory state will be faster than loading from database.
  # The limit here how many blocks we apply is somewhat arbitrary but two full
  # epochs (might be more slots if there are skips) seems like a good enough
  # first guess.
  # This happens in particular during startup where we replay blocks
  # sequentially to grab their votes.
  const RewindBlockThreshold = 64
  while ancestors.len < RewindBlockThreshold:
    if canAdvance(state, cur):
      found = true
      break

    if canAdvance(dag.headState, cur):
      assign(state, dag.headState)
      found = true
      break

    if canAdvance(dag.clearanceState, cur):
      assign(state, dag.clearanceState)
      found = true
      break

    if cur.slot == cur.blck.slot:
      # This is not an empty slot, so the block will need to be applied to
      # eventually reach bs
      ancestors.add(cur.blck)

    if cur.blck.parent == nil:
      break

    # Moving slot by slot helps find states that were advanced with empty slots
    cur = cur.parentOrSlot

  # Let's see if we're within a few epochs of the state block - then we can
  # simply replay blocks without loading the whole state

  if not found:
    debug "UpdateStateData cache miss",
      bs, stateBlock = state.blck, stateSlot = state.data.data.slot

    # Either the state is too new or was created by applying a different block.
    # We'll now resort to loading the state from the database then reapplying
    # blocks until we reach the desired point in time.

    cur = bs
    ancestors.setLen(0)

    # Look for a state in the database and load it - as long as it cannot be
    # found, keep track of the blocks that are needed to reach it from the
    # state that eventually will be found
    while not dag.getState(state, cur):
      # There's no state saved for this particular BlockSlot combination, keep
      # looking...
      if cur.blck.parent != nil and
          cur.blck.slot.epoch != epoch(cur.blck.parent.slot):
        # We store the state of the parent block with the epoch processing applied
        # in the database - we'll need to apply the block however!
        ancestors.add(cur.blck)
        cur = cur.blck.parent.atEpochStart(cur.blck.slot.epoch)
      else:
        if cur.slot == cur.blck.slot:
          # This is not an empty slot, so the block will need to be applied to
          # eventually reach bs
          ancestors.add(cur.blck)

        # Moves back slot by slot, in case a state for an empty slot was saved
        cur = cur.parent

    beacon_state_rewinds.inc()

  let
    startSlot {.used.} = state.data.data.slot # used in logs below
    startRoot {.used.} = state.data.root
  # Time to replay all the blocks between then and now
  for i in countdown(ancestors.len - 1, 0):
    # Because the ancestors are in the database, there's no need to persist them
    # again. Also, because we're applying blocks that were loaded from the
    # database, we can skip certain checks that have already been performed
    # before adding the block to the database.
    let ok =
      dag.applyBlock(state, dag.get(ancestors[i]), {}, cache)
    doAssert ok, "Blocks in database should never fail to apply.."

  # ...and make sure to process empty slots as requested
  dag.advanceSlots(state, bs.slot, save, cache)

  trace "State updated",
    blocks = ancestors.len,
    slots = state.data.data.slot - startSlot,
    stateRoot = shortLog(state.data.root),
    stateSlot = state.data.data.slot,
    startRoot = shortLog(startRoot),
    startSlot,
    blck = shortLog(bs),
    found

proc delState(dag: ChainDAGRef, bs: BlockSlot) =
  # Delete state state and mapping for a particular block+slot
  if not bs.slot.isEpoch:
    return # We only ever save epoch states
  if (let root = dag.db.getStateRoot(bs.blck.root, bs.slot); root.isSome()):
    dag.db.delState(root.get())
    dag.db.delStateRoot(bs.blck.root, bs.slot)

proc updateHead*(
    dag: ChainDAGRef, newHead: BlockRef, quarantine: var QuarantineRef) =
  ## Update what we consider to be the current head, as given by the fork
  ## choice.
  ## The choice of head affects the choice of finalization point - the order
  ## of operations naturally becomes important here - after updating the head,
  ## blocks that were once considered potential candidates for a tree will
  ## now fall from grace, or no longer be considered resolved.
  doAssert not newHead.isNil()
  doAssert not newHead.parent.isNil() or newHead.slot <= dag.tail.slot
  logScope:
    newHead = shortLog(newHead)

  if dag.head == newHead:
    trace "No head block update"

    return

  let
    lastHead = dag.head
  dag.db.putHeadBlock(newHead.root)

  # Start off by making sure we have the right state - as a special case, we'll
  # check the last block that was cleared by clearance - it might be just the
  # thing we're looking for

  if dag.clearanceState.blck == newHead and
      dag.clearanceState.data.data.slot == newHead.slot:
    assign(dag.headState, dag.clearanceState)
  else:
    var cache = getStateCache(newHead, newHead.slot.epoch())
    updateStateData(
      dag, dag.headState, newHead.atSlot(newHead.slot), false, cache)

  dag.head = newHead

  if not lastHead.isAncestorOf(newHead):
    notice "Updated head block with chain reorg",
      lastHead = shortLog(lastHead),
      headParent = shortLog(newHead.parent),
      stateRoot = shortLog(dag.headState.data.root),
      headBlock = shortLog(dag.headState.blck),
      stateSlot = shortLog(dag.headState.data.data.slot),
      justified = shortLog(dag.headState.data.data.current_justified_checkpoint),
      finalized = shortLog(dag.headState.data.data.finalized_checkpoint)

    # A reasonable criterion for "reorganizations of the chain"
    quarantine.clearQuarantine()
    beacon_reorgs_total.inc()
  else:
    debug "Updated head block",
      stateRoot = shortLog(dag.headState.data.root),
      headBlock = shortLog(dag.headState.blck),
      stateSlot = shortLog(dag.headState.data.data.slot),
      justified = shortLog(dag.headState.data.data.current_justified_checkpoint),
      finalized = shortLog(dag.headState.data.data.finalized_checkpoint)
  let
    finalizedHead = newHead.atEpochStart(
      dag.headState.data.data.finalized_checkpoint.epoch)

  # https://github.com/ethereum/eth2.0-metrics/blob/master/metrics.md#additional-metrics
  if dag.headState.data.data.eth1_data.deposit_count < high(int64).uint64:
    beacon_pending_deposits.set(
      dag.headState.data.data.eth1_data.deposit_count.int64 -
      dag.headState.data.data.eth1_deposit_index.int64)
    beacon_processed_deposits_total.set(
      dag.headState.data.data.eth1_deposit_index.int64)

  doAssert (not finalizedHead.blck.isNil),
    "Block graph should always lead to a finalized block"

  if finalizedHead != dag.finalizedHead:
    block: # Remove states, walking slot by slot
      discard
      var cur = finalizedHead
      while cur != dag.finalizedHead:
        # TODO This is a quick fix to prune some states from the database, but
        # not all, pending a smarter storage - the downside of pruning these
        # states is that certain rewinds will take longer
        # After long periods of non-finalization, it can also take some time to
        # release all these states!
        if cur.slot.epoch mod 32 != 0 and cur.slot != dag.tail.slot:
          dag.delState(cur)
        cur = cur.parentOrSlot

    block: # Clean up block refs, walking block by block
      # Finalization means that we choose a single chain as the canonical one -
      # it also means we're no longer interested in any branches from that chain
      # up to the finalization point
      let hlen = dag.heads.len
      for i in 0..<hlen:
        let n = hlen - i - 1
        let head = dag.heads[n]
        if finalizedHead.blck.isAncestorOf(head):
          continue

        var cur = head.atSlot(head.slot)
        while not cur.blck.isAncestorOf(finalizedHead.blck):
          # TODO there may be more empty states here: those that have a slot
          #      higher than head.slot and those near the branch point - one
          #      needs to be careful though because those close to the branch
          #      point should not necessarily be cleaned up
          dag.delState(cur)

          if cur.blck.slot == cur.slot:
            dag.blocks.del(cur.blck.root)
            dag.db.delBlock(cur.blck.root)

          if cur.blck.parent.isNil:
            break
          cur = cur.parentOrSlot

        dag.heads.del(n)
    block: # Clean up old EpochRef instances
      # After finalization, we can clear up the epoch cache and save memory -
      # it will be recomputed if needed
      # TODO don't store recomputed pre-finalization epoch refs
      var tmp = finalizedHead.blck
      while tmp != dag.finalizedHead.blck:
        # leave the epoch cache in the last block of the epoch..
        tmp = tmp.parent
        tmp.epochRefs = @[]

    dag.finalizedHead = finalizedHead

    notice "Reached new finalization checkpoint",
      finalizedHead = shortLog(finalizedHead),
      heads = dag.heads.len

proc isInitialized*(T: type ChainDAGRef, db: BeaconChainDB): bool =
  let
    headBlockRoot = db.getHeadBlock()
    tailBlockRoot = db.getTailBlock()

  if not (headBlockRoot.isSome() and tailBlockRoot.isSome()):
    return false

  let
    headBlock = db.getBlock(headBlockRoot.get())
    tailBlock = db.getBlock(tailBlockRoot.get())

  if not (headBlock.isSome() and tailBlock.isSome()):
    return false

  if not db.containsState(tailBlock.get().message.state_root):
    return false

  true

proc preInit*(
    T: type ChainDAGRef, db: BeaconChainDB,
    genesisState, tailState: BeaconState, tailBlock: SignedBeaconBlock) =
  # write a genesis state, the way the ChainDAGRef expects it to be stored in
  # database
  # TODO probably should just init a block pool with the freshly written
  #      state - but there's more refactoring needed to make it nice - doing
  #      a minimal patch for now..
  doAssert tailBlock.message.state_root == hash_tree_root(tailState)
  notice "New database from snapshot",
    blockRoot = shortLog(tailBlock.root),
    stateRoot = shortLog(tailBlock.message.state_root),
    fork = tailState.fork,
    validators = tailState.validators.len()

  db.putState(tailState)
  db.putBlock(tailBlock)
  db.putTailBlock(tailBlock.root)
  db.putHeadBlock(tailBlock.root)
  db.putStateRoot(tailBlock.root, tailState.slot, tailBlock.message.state_root)

  if tailState.slot == GENESIS_SLOT:
    db.putGenesisBlockRoot(tailBlock.root)
  else:
    doAssert genesisState.slot == GENESIS_SLOT
    db.putState(genesisState)
    let genesisBlock = get_initial_beacon_block(genesisState)
    db.putBlock(genesisBlock)
    db.putStateRoot(genesisBlock.root, GENESIS_SLOT, genesisBlock.message.state_root)
    db.putGenesisBlockRoot(genesisBlock.root)

proc setTailState*(dag: ChainDAGRef,
                   checkpointState: BeaconState,
                   checkpointBlock: SignedBeaconBlock) =
  # TODO
  # Delete all records up to the tail node. If the tail node is not
  # in the database, init the dabase in a way similar to `preInit`.
  discard

proc getGenesisBlockData*(dag: ChainDAGRef): BlockData =
  dag.get(dag.genesis)

proc getGenesisBlockSlot*(dag: ChainDAGRef): BlockSlot =
  let blockData = dag.getGenesisBlockData()
  BlockSlot(blck: blockData.refs, slot: GENESIS_SLOT)

proc getProposer*(
    dag: ChainDAGRef, head: BlockRef, slot: Slot):
    Option[(ValidatorIndex, ValidatorPubKey)] =
  let
    epochRef = dag.getEpochRef(head, slot.compute_epoch_at_slot())
    slotInEpoch = slot - slot.compute_epoch_at_slot().compute_start_slot_at_epoch()

  epochRef.beacon_proposers[slotInEpoch]
