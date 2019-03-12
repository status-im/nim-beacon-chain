import
  bitops, chronicles, options, tables,
  ssz, beacon_chain_db, state_transition, extras,
  spec/[crypto, datatypes, digest],
  beacon_node_types

proc link(parent, child: BlockRef) =
  doAssert (not (parent.root == Eth2Digest() or child.root == Eth2Digest())),
    "blocks missing root!"
  doAssert parent.root != child.root, "self-references not allowed"

  child.parent = parent
  parent.children.add(child)

proc init*(T: type BlockPool, db: BeaconChainDB): BlockPool =
  # TODO we require that the db contains both a head and a tail block -
  #      asserting here doesn't seem like the right way to go about it however..
  # TODO head is updated outside of block pool but read here - ugly.

  let
    tail = db.getTailBlock()
    head = db.getHeadBlock()

  doAssert tail.isSome(), "Missing tail block, database corrupt?"
  doAssert head.isSome(), "Missing head block, database corrupt?"

  let
    headRoot = head.get()
    tailRoot = tail.get()
    tailRef = BlockRef(root: tailRoot)

  var blocks = {tailRef.root: tailRef}.toTable()

  if headRoot != tailRoot:
    var curRef: BlockRef

    for root, _ in db.getAncestors(headRoot):
      if root == tailRef.root:
        assert(not curRef.isNil)
        link(tailRef, curRef)
        curRef = curRef.parent
        break

      if curRef == nil:
        curRef = BlockRef(root: root)
      else:
        link(BlockRef(root: root), curRef)
        curRef = curRef.parent
      blocks[curRef.root] = curRef

    doAssert curRef == tailRef,
      "head block does not lead to tail, database corrupt?"

  var blocksBySlot = initTable[uint64, seq[BlockRef]]()
  for _, b in tables.pairs(blocks):
    let slot = db.getBlock(b.root).get().slot
    blocksBySlot.mgetOrPut(slot, @[]).add(b)

  BlockPool(
    pending: initTable[Eth2Digest, BeaconBlock](),
    unresolved: initTable[Eth2Digest, UnresolvedBlock](),
    blocks: blocks,
    blocksBySlot: blocksBySlot,
    tail: BlockData(
      data: db.getBlock(tailRef.root).get(),
      refs: tailRef,
    ),
    db: db
  )

proc addSlotMapping(pool: BlockPool, slot: uint64, br: BlockRef) =
  proc addIfMissing(s: var seq[BlockRef], v: BlockRef) =
    if v notin s:
      s.add(v)
  pool.blocksBySlot.mgetOrPut(slot, @[]).addIfMissing(br)

proc updateState*(
  pool: BlockPool, state: var StateData, blck: BlockRef) {.gcsafe.}

proc add*(
    pool: var BlockPool, state: var StateData, blockRoot: Eth2Digest,
    blck: BeaconBlock): bool {.gcsafe.} =
  ## return false indicates that the block parent was missing and should be
  ## fetched
  ## the state parameter may be updated to include the given block, if
  ## everything checks out
  # TODO reevaluate passing the state in like this
  # TODO reevaluate this API - it's pretty ugly with the bool return
  doAssert blockRoot == hash_tree_root_final(blck)

  # Already seen this block??
  if blockRoot in pool.blocks:
    debug "Block already exists",
      slot = humaneSlotNum(blck.slot),
      stateRoot = shortLog(blck.state_root),
      parentRoot = shortLog(blck.parent_root),
      blockRoot = shortLog(blockRoot)

    return true

  # The tail block points to a cutoff time beyond which we don't store blocks -
  # if we receive a block with an earlier slot, there's no hope of ever
  # resolving it
  if blck.slot <= pool.tail.data.slot:
    debug "Old block, dropping",
      slot = humaneSlotNum(blck.slot),
      tailSlot = humaneSlotNum(pool.tail.data.slot),
      stateRoot = shortLog(blck.state_root),
      parentRoot = shortLog(blck.parent_root),
      blockRoot = shortLog(blockRoot)

    return true

  let parent = pool.blocks.getOrDefault(blck.parent_root)

  if parent != nil:
    # The block might have been in either of these - we don't want any more
    # work done on its behalf
    pool.unresolved.del(blockRoot)
    pool.pending.del(blockRoot)

    # The block is resolved, now it's time to validate it to ensure that the
    # blocks we add to the database are clean for the given state
    updateState(pool, state, parent)
    skipSlots(state.data, parent.root, blck.slot.Slot - 1)

    if not updateState(state.data, parent.root, blck, {}):
      # TODO find a better way to log all this block data
      notice "Invalid block",
        blockRoot = shortLog(blockRoot),
        slot = humaneSlotNum(blck.slot),
        stateRoot = shortLog(blck.state_root),
        parentRoot = shortLog(blck.parent_root),
        signature = shortLog(blck.signature),
        proposer_slashings = blck.body.proposer_slashings.len,
        attester_slashings = blck.body.attester_slashings.len,
        attestations = blck.body.attestations.len,
        deposits = blck.body.deposits.len,
        voluntary_exits = blck.body.voluntary_exits.len,
        transfers = blck.body.transfers.len

    let blockRef = BlockRef(
      root: blockRoot
    )
    link(parent, blockRef)

    pool.blocks[blockRoot] = blockRef

    pool.addSlotMapping(blck.slot, blockRef)

    # Resolved blocks should be stored in database
    pool.db.putBlock(blockRoot, blck)

    info "Block resolved",
      blockRoot = shortLog(blockRoot),
      slot = humaneSlotNum(blck.slot),
      stateRoot = shortLog(blck.state_root),
      parentRoot = shortLog(blck.parent_root),
      signature = shortLog(blck.signature),
      proposer_slashings = blck.body.proposer_slashings.len,
      attester_slashings = blck.body.attester_slashings.len,
      attestations = blck.body.attestations.len,
      deposits = blck.body.deposits.len,
      voluntary_exits = blck.body.voluntary_exits.len,
      transfers = blck.body.transfers.len

    # Now that we have the new block, we should see if any of the previously
    # unresolved blocks magically become resolved
    # TODO there are more efficient ways of doing this, that also don't risk
    #      running out of stack etc
    let retries = pool.pending
    for k, v in retries:
      discard pool.add(state, k, v)

    return true

  # TODO possibly, it makes sense to check the database - that would allow sync
  #      to simply fill up the database with random blocks the other clients
  #      think are useful - but, it would also risk filling the database with
  #      junk that's not part of the block graph

  if blck.parent_root in pool.unresolved:
    return true

  # This is an unresolved block - put it on the unresolved list for now...
  # TODO if we receive spam blocks, one heurestic to implement might be to wait
  #      for a couple of attestations to appear before fetching parents - this
  #      would help prevent using up network resources for spam - this serves
  #      two purposes: one is that attestations are likely to appear for the
  #      block only if it's valid / not spam - the other is that malicious
  #      validators that are not proposers can sign invalid blocks and send
  #      them out without penalty - but signing invalid attestations carries
  #      a risk of being slashed, making attestations a more valuable spam
  #      filter.
  debug "Unresolved block",
    slot = humaneSlotNum(blck.slot),
    stateRoot = shortLog(blck.state_root),
    parentRoot = shortLog(blck.parent_root),
    blockRoot = shortLog(blockRoot)

  pool.unresolved[blck.parent_root] = UnresolvedBlock()
  pool.pending[blockRoot] = blck

  false

proc get*(pool: BlockPool, blck: BlockRef): BlockData =
  ## Retrieve the associated block body of a block reference
  doAssert (not blck.isNil), "Trying to get nil BlockRef"

  let data = pool.db.getBlock(blck.root)
  doAssert data.isSome, "BlockRef without backing data, database corrupt?"

  BlockData(data: data.get(), refs: blck)

proc get*(pool: BlockPool, root: Eth2Digest): Option[BlockData] =
  ## Retrieve a resolved block reference and its associated body, if available
  let refs = pool.blocks.getOrDefault(root)

  if not refs.isNil:
    some(pool.get(refs))
  else:
    none(BlockData)

proc getOrResolve*(pool: var BlockPool, root: Eth2Digest): BlockRef =
  ## Fetch a block ref, or nil if not found (will be added to list of
  ## blocks-to-resolve)
  result = pool.blocks.getOrDefault(root)

  if result.isNil:
    pool.unresolved[root] = UnresolvedBlock()

iterator blockRootsForSlot*(pool: BlockPool, slot: uint64): Eth2Digest =
  for br in pool.blocksBySlot.getOrDefault(slot, @[]):
    yield br.root

proc checkUnresolved*(pool: var BlockPool): seq[Eth2Digest] =
  ## Return a list of blocks that we should try to resolve from other client -
  ## to be called periodically but not too often (once per slot?)
  var done: seq[Eth2Digest]

  for k, v in pool.unresolved.mpairs():
    if v.tries > 8:
      done.add(k)
    else:
      inc v.tries

  for k in done:
    # TODO Need to potentially remove from pool.pending - this is currently a
    #      memory leak here!
    pool.unresolved.del(k)

  # simple (simplistic?) exponential backoff for retries..
  for k, v in pool.unresolved.pairs():
    if v.tries.popcount() == 1:
      result.add(k)

proc skipAndUpdateState(
    state: var BeaconState, blck: BeaconBlock, flags: UpdateFlags,
    afterUpdate: proc (state: BeaconState)): bool =
  skipSlots(state, blck.parent_root, blck.slot.Slot - 1, afterUpdate)
  let ok  = updateState(state, blck.parent_root, blck, flags)

  afterUpdate(state)

  ok

proc maybePutState(pool: BlockPool, state: BeaconState) =
  # TODO we save state at every epoch start but never remove them - we also
  #      potentially save multiple states per slot if reorgs happen, meaning
  #      we could easily see a state explosion
  if state.slot mod SLOTS_PER_EPOCH == 0:
    info "Storing state",
      stateSlot = humaneSlotNum(state.slot),
      stateRoot = shortLog(hash_tree_root_final(state)) # TODO cache?
    pool.db.putState(state)

proc updateState*(
    pool: BlockPool, state: var StateData, blck: BlockRef) =
  # Rewind or advance state such that it matches the given block - this may
  # include replaying from an earlier snapshot if blck is on a different branch
  # or has advanced to a higher slot number than blck
  var ancestors = @[pool.get(blck)]

  # We need to check the slot because the state might have moved forwards
  # without blocks
  if state.blck.root == blck.root and state.data.slot == ancestors[0].data.slot:
    return # State already at the right spot

  # Common case: blck points to a block that is one step ahead of state
  if state.blck.root == ancestors[0].data.parent_root and
      state.data.slot + 1 == ancestors[0].data.slot:
    let ok = skipAndUpdateState(
        state.data, ancestors[0].data, {skipValidation}) do (state: BeaconState):
      pool.maybePutState(state)
    doAssert ok, "Blocks in database should never fail to apply.."
    state.blck = blck
    state.root = ancestors[0].data.state_root

    return

  # It appears that the parent root of the proposed new block is different from
  # what we expected. We will have to rewind the state to a point along the
  # chain of ancestors of the new block. We will do this by loading each
  # successive parent block and checking if we can find the corresponding state
  # in the database.
  while not ancestors[^1].refs.parent.isNil:
    let parent = pool.get(ancestors[^1].refs.parent)
    ancestors.add parent

    if pool.db.containsState(parent.data.state_root): break

  let
    ancestor = ancestors[^1]
    ancestorState = pool.db.getState(ancestor.data.state_root)

  if ancestorState.isNone():
    # TODO this should only happen if the database is corrupt - we walked the
    #      list of parent blocks and couldn't find a corresponding state in the
    #      database, which should never happen (at least we should have the
    #      tail state in there!)
    error "Couldn't find ancestor state or block parent missing!",
      blockRoot = shortLog(blck.root)
    doAssert false, "Oh noes, we passed big bang!"

  notice "Replaying state transitions",
    stateSlot = humaneSlotNum(state.data.slot),
    stateRoot = shortLog(ancestor.data.state_root),
    prevStateSlot = humaneSlotNum(ancestorState.get().slot),
    ancestors = ancestors.len

  state.data = ancestorState.get()

  # If we come this far, we found the state root. The last block on the stack
  # is the one that produced this particular state, so we can pop it
  # TODO it might be possible to use the latest block hashes from the state to
  #      do this more efficiently.. whatever!

  # Time to replay all the blocks between then and now. We skip the one because
  # it's the one that we found the state with, and it has already been
  # applied
  for i in countdown(ancestors.len - 2, 0):
    let last = ancestors[i]

    skipSlots(
        state.data, last.data.parent_root,
        last.data.slot.Slot - 1) do(state: BeaconState):
      pool.maybePutState(state)

    let ok = updateState(
        state.data, last.data.parent_root, last.data, {skipValidation})
    doAssert ok,
      "We only keep validated blocks in the database, should never fail"

  state.blck = blck
  state.root = ancestors[0].data.state_root

  pool.maybePutState(state.data)

proc loadTailState*(pool: BlockPool): StateData =
  ## Load the state associated with the current tail in the pool
  StateData(
    data: pool.db.getState(pool.tail.data.state_root).get(),
    root: pool.tail.data.state_root,
    blck: pool.tail.refs
  )
