import
  os, stats, strformat, tables,
  chronicles, confutils, stew/byteutils, eth/db/kvstore_sqlite3,
  ../beacon_chain/networking/network_metadata,
  ../beacon_chain/[beacon_chain_db, extras],
  ../beacon_chain/consensus_object_pools/blockchain_dag,
  ../beacon_chain/spec/[crypto, datatypes, digest, helpers,
                        state_transition, presets],
  ../beacon_chain/ssz, ../beacon_chain/ssz/sszdump,
  ../research/simutils, ./e2store

type Timers = enum
  tInit = "Initialize DB"
  tLoadBlock = "Load block from database"
  tLoadState = "Load state from database"
  tAdvanceSlot = "Advance slot, non-epoch"
  tAdvanceEpoch = "Advance slot, epoch"
  tApplyBlock = "Apply block, no slot processing"
  tDbLoad = "Database load"
  tDbStore = "Database store"

type
  DbCmd* = enum
    bench
    dumpState
    dumpBlock
    pruneDatabase
    rewindState
    exportEra

  # TODO:
  # This should probably allow specifying a run-time preset
  DbConf = object
    databaseDir* {.
        defaultValue: ""
        desc: "Directory where `nbc.sqlite` is stored"
        name: "db" }: InputDir

    eth2Network* {.
      desc: "The Eth2 network preset to use"
      name: "network" }: Option[string]

    case cmd* {.
      command
      desc: ""
      .}: DbCmd

    of bench:
      slots* {.
        defaultValue: 50000
        desc: "Number of slots to run benchmark for".}: uint64
      storeBlocks* {.
        defaultValue: false
        desc: "Store each read block back into a separate database".}: bool
      storeStates* {.
        defaultValue: false
        desc: "Store a state each epoch into a separate database".}: bool
      printTimes* {.
        defaultValue: true
        desc: "Print csv of block processing time".}: bool
      resetCache* {.
        defaultValue: false
        desc: "Process each block with a fresh cache".}: bool
    of dumpState:
      stateRoot* {.
        argument
        desc: "State roots to save".}: seq[string]

    of dumpBlock:
      blockRootx* {.
        argument
        desc: "Block roots to save".}: seq[string]

    of pruneDatabase:
      dryRun* {.
        defaultValue: false
        desc: "Don't write to the database copy; only simulate actions; default false".}: bool
      keepOldStates* {.
        defaultValue: true
        desc: "Keep pre-finalization states; default true".}: bool
      verbose* {.
        defaultValue: false
        desc: "Enables verbose output; default false".}: bool

    of rewindState:
      blockRoot* {.
        argument
        desc: "Block root".}: string

      slot* {.
        argument
        desc: "Slot".}: uint64

    of exportEra:
      era* {.
        defaultValue: 0
        desc: "The era number to write".}: uint64
      eraCount* {.
        defaultValue: 1
        desc: "Number of eras to write".}: uint64

proc cmdBench(conf: DbConf, runtimePreset: RuntimePreset) =
  var timers: array[Timers, RunningStat]

  echo "Opening database..."
  let
    db = BeaconChainDB.init(runtimePreset, conf.databaseDir.string)
    dbBenchmark = BeaconChainDB.init(runtimePreset, "benchmark")
  defer:
    db.close()
    dbBenchmark.close()

  if not ChainDAGRef.isInitialized(db):
    echo "Database not initialized"
    quit 1

  echo "Initializing block pool..."
  let pool = withTimerRet(timers[tInit]):
    ChainDAGRef.init(runtimePreset, db, {})

  echo &"Loaded {pool.blocks.len} blocks, head slot {pool.head.slot}"

  var
    blockRefs: seq[BlockRef]
    blocks: seq[TrustedSignedBeaconBlock]
    cur = pool.head

  while cur != nil:
    blockRefs.add cur
    cur = cur.parent

  for b in 1..<blockRefs.len: # Skip genesis block
    if blockRefs[blockRefs.len - b - 1].slot > conf.slots:
      break

    withTimer(timers[tLoadBlock]):
      blocks.add db.getBlock(blockRefs[blockRefs.len - b - 1].root).get()

  let state = (ref HashedBeaconState)(
    root: db.getBlock(blockRefs[^1].root).get().message.state_root
  )

  withTimer(timers[tLoadState]):
    discard db.getState(state[].root, state[].data, noRollback)

  var
    cache = StateCache()
    loadedState = new BeaconState

  for b in blocks.mitems():
    while state[].data.slot < b.message.slot:
      let isEpoch = state[].data.slot.epoch() != (state[].data.slot + 1).epoch
      withTimer(timers[if isEpoch: tAdvanceEpoch else: tAdvanceSlot]):
        let ok = process_slots(state[], state[].data.slot + 1, cache, {})
        doAssert ok, "Slot processing can't fail with correct inputs"

    var start = Moment.now()
    withTimer(timers[tApplyBlock]):
      if conf.resetCache:
        cache = StateCache()
      if not state_transition(
          runtimePreset, state[], b, cache, {slotProcessed}, noRollback):
        dump("./", b)
        echo "State transition failed (!)"
        quit 1
    if conf.printTimes:
      echo b.message.slot, ",", toHex(b.root.data), ",", nanoseconds(Moment.now() - start)
    if conf.storeBlocks:
      withTimer(timers[tDbStore]):
        dbBenchmark.putBlock(b)

    if state[].data.slot.isEpoch and conf.storeStates:
      if state[].data.slot.epoch < 2:
        dbBenchmark.putState(state[].root, state[].data)
        dbBenchmark.checkpoint()
      else:
        withTimer(timers[tDbStore]):
          dbBenchmark.putState(state[].root, state[].data)
          dbBenchmark.checkpoint()

        withTimer(timers[tDbLoad]):
          doAssert dbBenchmark.getState(state[].root, loadedState[], noRollback)

        if state[].data.slot.epoch mod 16 == 0:
          doAssert hash_tree_root(state[].data) == hash_tree_root(loadedState[])

  printTimers(false, timers)

proc cmdDumpState(conf: DbConf, preset: RuntimePreset) =
  let db = BeaconChainDB.init(preset, conf.databaseDir.string)
  defer: db.close()

  for stateRoot in conf.stateRoot:
    try:
      let root = Eth2Digest(data: hexToByteArray[32](stateRoot))
      var state = (ref HashedBeaconState)(root: root)
      if not db.getState(root, state.data, noRollback):
        echo "Couldn't load ", root
      else:
        dump("./", state[])
    except CatchableError as e:
      echo "Couldn't load ", stateRoot, ": ", e.msg

proc cmdDumpBlock(conf: DbConf, preset: RuntimePreset) =
  let db = BeaconChainDB.init(preset, conf.databaseDir.string)
  defer: db.close()

  for blockRoot in conf.blockRootx:
    try:
      let root = Eth2Digest(data: hexToByteArray[32](blockRoot))
      if (let blck = db.getBlock(root); blck.isSome):
        dump("./", blck.get())
      else:
        echo "Couldn't load ", root
    except CatchableError as e:
      echo "Couldn't load ", blockRoot, ": ", e.msg

proc copyPrunedDatabase(
    db: BeaconChainDB, copyDb: BeaconChainDB,
    dryRun, verbose, keepOldStates: bool) =
  ## Create a pruned copy of the beacon chain database

  let
    headBlock = db.getHeadBlock()
    tailBlock = db.getTailBlock()

  doAssert headBlock.isOk and tailBlock.isOk
  doAssert db.getBlock(headBlock.get).isOk
  doAssert db.getBlock(tailBlock.get).isOk

  var
    beaconState: ref BeaconState
    finalizedEpoch: Epoch  # default value of 0 is conservative/safe
    prevBlockSlot = db.getBlock(db.getHeadBlock().get).get.message.slot

  beaconState = new BeaconState
  let headEpoch = db.getBlock(headBlock.get).get.message.slot.epoch

  # Tail states are specially addressed; no stateroot intermediary
  if not db.getState(
      db.getBlock(tailBlock.get).get.message.state_root, beaconState[],
      noRollback):
    doAssert false, "could not load tail state"
  if not dry_run:
    copyDb.putState(beaconState[])

  for signedBlock in getAncestors(db, headBlock.get):
    if not dry_run:
      copyDb.putBlock(signedBlock)
      copyDb.checkpoint()
    if verbose:
      echo "copied block at slot ", signedBlock.message.slot

    for slot in countdown(prevBlockSlot, signedBlock.message.slot + 1):
      if slot mod SLOTS_PER_EPOCH != 0 or
          ((not keepOldStates) and slot.epoch < finalizedEpoch):
        continue

      # Could also only copy these states, head and finalized, plus tail state
      let stateRequired = slot.epoch in [finalizedEpoch, headEpoch]

      let sr = db.getStateRoot(signedBlock.root, slot)
      if sr.isErr:
        if stateRequired:
          echo "skipping state root required for slot ",
            slot, " with root ", signedBlock.root
        continue

      if not db.getState(sr.get, beaconState[], noRollback):
        # Don't copy dangling stateroot pointers
        if stateRequired:
          doAssert false, "state root and state required"
        continue

      finalizedEpoch = max(
        finalizedEpoch, beaconState.finalized_checkpoint.epoch)

      if not dry_run:
        copyDb.putStateRoot(signedBlock.root, slot, sr.get)
        copyDb.putState(beaconState[])
      if verbose:
        echo "copied state at slot ", slot, " from block at ", shortLog(signedBlock.message.slot)

    prevBlockSlot = signedBlock.message.slot

  if not dry_run:
    copyDb.putHeadBlock(headBlock.get)
    copyDb.putTailBlock(tailBlock.get)

proc cmdPrune(conf: DbConf, preset: RuntimePreset) =
  let
    db = BeaconChainDB.init(preset, conf.databaseDir.string)
    # TODO: add the destination as CLI paramter
    copyDb = BeaconChainDB.init(preset, "pruned_db")

  defer:
    db.close()
    copyDb.close()

  db.copyPrunedDatabase(copyDb, conf.dryRun, conf.verbose, conf.keepOldStates)

proc cmdRewindState(conf: DbConf, preset: RuntimePreset) =
  echo "Opening database..."
  let db = BeaconChainDB.init(preset, conf.databaseDir.string)
  defer: db.close()

  if not ChainDAGRef.isInitialized(db):
    echo "Database not initialized"
    quit 1

  echo "Initializing block pool..."
  let dag = init(ChainDAGRef, preset, db)

  let blckRef = dag.getRef(fromHex(Eth2Digest, conf.blockRoot))
  if blckRef == nil:
    echo "Block not found in database"
    return

  let tmpState = assignClone(dag.headState)
  dag.withState(tmpState[], blckRef.atSlot(Slot(conf.slot))):
    echo "Writing state..."
    dump("./", hashedState, blck)

proc atCanonicalSlot(blck: BlockRef, slot: Slot): BlockSlot =
  if slot == 0:
    blck.atSlot(slot)
  else:
    blck.atSlot(slot - 1).blck.atSlot(slot)

proc cmdExportEra(conf: DbConf, preset: RuntimePreset) =
  let db = BeaconChainDB.init(preset, conf.databaseDir.string)
  defer: db.close()

  if not ChainDAGRef.isInitialized(db):
    echo "Database not initialized"
    quit 1

  echo "Initializing block pool..."
  let
    dag = init(ChainDAGRef, preset, db)

  let tmpState = assignClone(dag.headState)

  for era in conf.era..<conf.era + conf.eraCount:
    let
      firstSlot = if era == 0: Slot(0) else: Slot((era - 1) * SLOTS_PER_HISTORICAL_ROOT)
      endSlot = Slot(era * SLOTS_PER_HISTORICAL_ROOT)
      slotCount = endSlot - firstSlot
      name = &"ethereum2-mainnet-{era.int:08x}-{1:08x}"
      canonical = dag.head.atCanonicalSlot(endSlot)

    if endSlot > dag.head.slot:
      echo "Written all complete eras"
      break

    var e2s = E2Store.open(".", name, firstSlot).get()
    defer: e2s.close()

    dag.withState(tmpState, canonical):
      e2s.appendRecord(state).get()

    var
      ancestors: seq[BlockRef]
      cur = canonical.blck
    if era != 0:
      while cur != nil and cur.slot >= firstSlot:
        ancestors.add(cur)
        cur = cur.parent

      for i in 0..<ancestors.len():
        let
          ancestor = ancestors[ancestors.len - 1 - i]
        e2s.appendRecord(db.getBlock(ancestor.root).get()).get()

when isMainModule:
  var
    conf = DbConf.load()
    runtimePreset = getRuntimePresetForNetwork(conf.eth2Network)

  case conf.cmd
  of bench:
    cmdBench(conf, runtimePreset)
  of dumpState:
    cmdDumpState(conf, runtimePreset)
  of dumpBlock:
    cmdDumpBlock(conf, runtimePreset)
  of pruneDatabase:
    cmdPrune(conf, runtimePreset)
  of rewindState:
    cmdRewindState(conf, runtimePreset)
  of exportEra:
    cmdExportEra(conf, runtimePreset)
