# beacon_chain
# Copyright (c) 2018-2020 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  # Standard library
  algorithm, os, tables, strutils, times, math, terminal, random,

  # Nimble packages
  stew/[objects, byteutils], stew/shims/macros,
  chronos, confutils, metrics, json_rpc/[rpcserver, jsonmarshal],
  chronicles,
  json_serialization/std/[options, sets, net], serialization/errors,
  eth/db/kvstore, eth/db/kvstore_sqlite3,
  eth/p2p/enode, eth/[keys, async_utils], eth/p2p/discoveryv5/[protocol, enr],

  # Local modules
  spec/[datatypes, digest, crypto, beaconstate, helpers, network],
  spec/state_transition, spec/presets/custom,
  conf, time, beacon_chain_db, validator_pool, extras,
  attestation_pool, block_pool, eth2_network, eth2_discovery,
  beacon_node_common, beacon_node_types, block_pools/block_pools_types,
  nimbus_binary_common,
  mainchain_monitor, version, ssz/[merkleization], sszdump,
  sync_protocol, request_manager, keystore_management, interop, statusbar,
  sync_manager, validator_duties, validator_api, attestation_aggregation

when defined(posix):
  import posix

const
  genesisFile* = "genesis.ssz"
  hasPrompt = not defined(withoutPrompt)

type
  RpcServer* = RpcHttpServer
  KeyPair = eth2_network.KeyPair

  # "state" is already taken by BeaconState
  BeaconNodeStatus* = enum
    Starting, Running, Stopping

# this needs to be global, so it can be set in the Ctrl+C signal handler
var status = BeaconNodeStatus.Starting

template init(T: type RpcHttpServer, ip: ValidIpAddress, port: Port): T =
  newRpcHttpServer([initTAddress(ip, port)])

# https://github.com/ethereum/eth2.0-metrics/blob/master/metrics.md#interop-metrics
declareGauge beacon_slot,
  "Latest slot of the beacon chain state"
declareGauge beacon_head_slot,
  "Slot of the head block of the beacon chain"

# Metrics for tracking attestation and beacon block loss
declareCounter beacon_attestations_received,
  "Number of beacon chain attestations received by this peer"
declareCounter beacon_blocks_received,
  "Number of beacon chain blocks received by this peer"

declareHistogram beacon_attestation_received_seconds_from_slot_start,
  "Interval between slot start and attestation receival", buckets = [2.0, 4.0, 6.0, 8.0, 10.0, 12.0, 14.0, Inf]

logScope: topics = "beacnde"

proc onBeaconBlock(node: BeaconNode, signedBlock: SignedBeaconBlock) {.gcsafe.}

proc getStateFromSnapshot(conf: BeaconNodeConf): NilableBeaconStateRef =
  var
    genesisPath = conf.dataDir/genesisFile
    snapshotContents: TaintedString
    writeGenesisFile = false

  if conf.stateSnapshot.isSome:
    let
      snapshotPath = conf.stateSnapshot.get.string
      snapshotExt = splitFile(snapshotPath).ext

    if cmpIgnoreCase(snapshotExt, ".ssz") != 0:
      error "The supplied state snapshot must be a SSZ file",
            suppliedPath = snapshotPath
      quit 1

    snapshotContents = readFile(snapshotPath)
    if fileExists(genesisPath):
      let genesisContents = readFile(genesisPath)
      if snapshotContents != genesisContents:
        error "Data directory not empty. Existing genesis state differs from supplied snapshot",
              dataDir = conf.dataDir.string, snapshot = snapshotPath
        quit 1
    else:
      debug "No previous genesis state. Importing snapshot",
            genesisPath, dataDir = conf.dataDir.string
      writeGenesisFile = true
      genesisPath = snapshotPath
  elif fileExists(genesisPath):
    try: snapshotContents = readFile(genesisPath)
    except CatchableError as err:
      error "Failed to read genesis file", err = err.msg
      quit 1
  else:
    # No snapshot was provided. We should wait for genesis.
    return nil

  result = try:
    newClone(SSZ.decode(snapshotContents, BeaconState))
  except SerializationError:
    error "Failed to import genesis file", path = genesisPath
    quit 1

  info "Loaded genesis state", path = genesisPath

  if writeGenesisFile:
    try:
      notice "Writing genesis to data directory", path = conf.dataDir/genesisFile
      writeFile(conf.dataDir/genesisFile, snapshotContents.string)
    except CatchableError as err:
      error "Failed to persist genesis file to data dir",
        err = err.msg, genesisFile = conf.dataDir/genesisFile
      quit 1

func enrForkIdFromState(state: BeaconState): ENRForkID =
  let
    forkVer = state.fork.current_version
    forkDigest = compute_fork_digest(forkVer, state.genesis_validators_root)

  ENRForkID(
    fork_digest: forkDigest,
    next_fork_version: forkVer,
    next_fork_epoch: FAR_FUTURE_EPOCH)

proc init*(T: type BeaconNode, conf: BeaconNodeConf): Future[BeaconNode] {.async.} =
  let
    netKeys = getPersistentNetKeys(conf)
    nickname = if conf.nodeName == "auto": shortForm(netKeys)
               else: conf.nodeName
    db = BeaconChainDB.init(kvStore SqStoreRef.init(conf.databaseDir, "nbc").tryGet())

  var mainchainMonitor: MainchainMonitor

  if not BlockPool.isInitialized(db):
    # Fresh start - need to load a genesis state from somewhere
    var genesisState = conf.getStateFromSnapshot()

    # Try file from command line first
    if genesisState.isNil:
      if conf.web3Url.len == 0:
        fatal "Web3 URL not specified"
        quit 1

      if conf.depositContractAddress.len == 0:
        fatal "Deposit contract address not specified"
        quit 1

      if conf.depositContractDeployedAt.isNone:
        # When we don't have a known genesis state, the network metadata
        # must specify the deployment block of the contract.
        fatal "Deposit contract deployment block not specified"
        quit 1

      # TODO Could move this to a separate "GenesisMonitor" process or task
      #      that would do only this - see Paul's proposal for this.
      mainchainMonitor = MainchainMonitor.init(
        web3Provider(conf.web3Url),
        conf.depositContractAddress,
        Eth1Data(block_hash: conf.depositContractDeployedAt.get, deposit_count: 0))
      mainchainMonitor.start()

      genesisState = await mainchainMonitor.waitGenesis()

      info "Eth2 genesis state detected",
        genesisTime = genesisState.genesisTime,
        eth1Block = genesisState.eth1_data.block_hash,
        totalDeposits = genesisState.eth1_data.deposit_count

    # This is needed to prove the not nil property from here on
    if genesisState == nil:
      doAssert false
    else:
      if genesisState.slot != GENESIS_SLOT:
        # TODO how to get a block from a non-genesis state?
        error "Starting from non-genesis state not supported",
          stateSlot = genesisState.slot,
          stateRoot = hash_tree_root(genesisState[])
        quit 1

      let tailBlock = get_initial_beacon_block(genesisState[])

      try:
        BlockPool.preInit(db, genesisState[], tailBlock)
        doAssert BlockPool.isInitialized(db), "preInit should have initialized db"
      except CatchableError as e:
        error "Failed to initialize database", err = e.msg
        quit 1

  # TODO check that genesis given on command line (if any) matches database
  let blockPool = BlockPool.init(
    db,
    if conf.verifyFinalization:
      {verifyFinalization}
    else:
      {})

  if mainchainMonitor.isNil and
     conf.web3Url.len > 0 and
     conf.depositContractAddress.len > 0:
    mainchainMonitor = MainchainMonitor.init(
      web3Provider(conf.web3Url),
      conf.depositContractAddress,
      blockPool.headState.data.data.eth1_data)
    # TODO if we don't have any validators attached, we don't need a mainchain
    #      monitor
    mainchainMonitor.start()

  let rpcServer = if conf.rpcEnabled:
    RpcServer.init(conf.rpcAddress, conf.rpcPort)
  else:
    nil

  let
    enrForkId = enrForkIdFromState(blockPool.headState.data.data)
    topicBeaconBlocks = getBeaconBlocksTopic(enrForkId.forkDigest)
    topicAggregateAndProofs = getAggregateAndProofsTopic(enrForkId.forkDigest)
    network = await createEth2Node(conf, enrForkId)

  var res = BeaconNode(
    nickname: nickname,
    network: network,
    netKeys: netKeys,
    db: db,
    config: conf,
    attachedValidators: ValidatorPool.init(),
    blockPool: blockPool,
    attestationPool: AttestationPool.init(blockPool),
    mainchainMonitor: mainchainMonitor,
    beaconClock: BeaconClock.init(blockPool.headState.data.data),
    rpcServer: rpcServer,
    forkDigest: enrForkId.forkDigest,
    topicBeaconBlocks: topicBeaconBlocks,
    topicAggregateAndProofs: topicAggregateAndProofs,
  )

  res.requestManager = RequestManager.init(network,
    proc(signedBlock: SignedBeaconBlock) =
      onBeaconBlock(res, signedBlock)
  )

  await res.addLocalValidators()

  # This merely configures the BeaconSync
  # The traffic will be started when we join the network.
  network.initBeaconSync(blockPool, enrForkId.forkDigest,
    proc(signedBlock: SignedBeaconBlock) =
      if signedBlock.message.slot.isEpoch:
        # TODO this is a hack to make sure that lmd ghost is run regularly
        #      while syncing blocks - it's poor form to keep it here though -
        #      the logic should be moved elsewhere
        # TODO why only when syncing? well, because the way the code is written
        #      we require a connection to a boot node to start, and that boot
        #      node will start syncing as part of connection setup - it looks
        #      like it needs to finish syncing before the slot timer starts
        #      ticking which is a problem: all the synced blocks will be added
        #      to the block pool without any periodic head updates while this
        #      process is ongoing (during a blank start for example), which
        #      leads to an unhealthy buildup of blocks in the non-finalized part
        #      of the block pool
        # TODO is it a problem that someone sending us a block can force
        #      a potentially expensive head resolution?
        discard res.updateHead()

      onBeaconBlock(res, signedBlock))

  return res

proc onAttestation(node: BeaconNode, attestation: Attestation) =
  # We received an attestation from the network but don't know much about it
  # yet - in particular, we haven't verified that it belongs to particular chain
  # we're on, or that it follows the rules of the protocol
  logScope: pcs = "on_attestation"

  let
    wallSlot = node.beaconClock.now().toSlot()
    head = node.blockPool.head

  debug "Attestation received",
    attestation = shortLog(attestation),
    headRoot = shortLog(head.blck.root),
    headSlot = shortLog(head.blck.slot),
    wallSlot = shortLog(wallSlot.slot),
    cat = "consensus" # Tag "consensus|attestation"?

  if not wallSlot.afterGenesis or wallSlot.slot < head.blck.slot:
    warn "Received attestation before genesis or head - clock is wrong?",
      afterGenesis = wallSlot.afterGenesis,
      wallSlot = shortLog(wallSlot.slot),
      headSlot = shortLog(head.blck.slot),
      cat = "clock_drift" # Tag "attestation|clock_drift"?
    return

  if attestation.data.slot > head.blck.slot and
      (attestation.data.slot - head.blck.slot) > MaxEmptySlotCount:
    warn "Ignoring attestation, head block too old (out of sync?)",
      attestationSlot = attestation.data.slot, headSlot = head.blck.slot
    return

  node.attestationPool.add(attestation)

proc dumpBlock[T](
    node: BeaconNode, signedBlock: SignedBeaconBlock,
    res: Result[T, BlockError]) =
  if node.config.dumpEnabled and res.isErr:
    case res.error
    of Invalid:
      dump(
        node.config.dumpDirInvalid, signedBlock,
        hash_tree_root(signedBlock.message))
    of MissingParent:
      dump(
        node.config.dumpDirIncoming, signedBlock,
        hash_tree_root(signedBlock.message))
    else:
      discard

proc storeBlock(
    node: BeaconNode, signedBlock: SignedBeaconBlock): Result[void, BlockError] =
  let blockRoot = hash_tree_root(signedBlock.message)
  debug "Block received",
    signedBlock = shortLog(signedBlock.message),
    blockRoot = shortLog(blockRoot),
    cat = "block_listener",
    pcs = "receive_block"

  beacon_blocks_received.inc()
  let blck = node.blockPool.add(blockRoot, signedBlock)

  node.dumpBlock(signedBlock, blck)

  if blck.isErr:
    return err(blck.error)

  # The block we received contains attestations, and we might not yet know about
  # all of them. Let's add them to the attestation pool.
  for attestation in signedBlock.message.body.attestations:
    debug "Attestation from block",
      attestation = shortLog(attestation),
      cat = "consensus" # Tag "consensus|attestation"?

    node.attestationPool.add(attestation)
  ok()

proc onBeaconBlock(node: BeaconNode, signedBlock: SignedBeaconBlock) =
  # We received a block but don't know much about it yet - in particular, we
  # don't know if it's part of the chain we're currently building.
  discard node.storeBlock(signedBlock)

func verifyFinalization(node: BeaconNode, slot: Slot) =
  # Epoch must be >= 4 to check finalization
  const SETTLING_TIME_OFFSET = 1'u64
  let epoch = slot.compute_epoch_at_slot()

  # Don't static-assert this -- if this isn't called, don't require it
  doAssert SLOTS_PER_EPOCH > SETTLING_TIME_OFFSET

  # Intentionally, loudly assert. Point is to fail visibly and unignorably
  # during testing.
  if epoch >= 4 and slot mod SLOTS_PER_EPOCH > SETTLING_TIME_OFFSET:
    let finalizedEpoch =
      node.blockPool.finalizedHead.blck.slot.compute_epoch_at_slot()
    # Finalization rule 234, that has the most lag slots among the cases, sets
    # state.finalized_checkpoint = old_previous_justified_checkpoint.epoch + 3
    # and then state.slot gets incremented, to increase the maximum offset, if
    # finalization occurs every slot, to 4 slots vs scheduledSlot.
    doAssert finalizedEpoch + 4 >= epoch

proc onSlotStart(node: BeaconNode, lastSlot, scheduledSlot: Slot) {.gcsafe, async.} =
  ## Called at the beginning of a slot - usually every slot, but sometimes might
  ## skip a few in case we're running late.
  ## lastSlot: the last slot that we successfully processed, so we know where to
  ##           start work from
  ## scheduledSlot: the slot that we were aiming for, in terms of timing

  logScope: pcs = "slot_start"

  let
    # The slot we should be at, according to the clock
    beaconTime = node.beaconClock.now()
    wallSlot = beaconTime.toSlot()

  info "Slot start",
    lastSlot = shortLog(lastSlot),
    scheduledSlot = shortLog(scheduledSlot),
    beaconTime = shortLog(beaconTime),
    peers = node.network.peersCount,
    headSlot = shortLog(node.blockPool.head.blck.slot),
    headEpoch = shortLog(node.blockPool.head.blck.slot.compute_epoch_at_slot()),
    headRoot = shortLog(node.blockPool.head.blck.root),
    finalizedSlot = shortLog(node.blockPool.finalizedHead.blck.slot),
    finalizedRoot = shortLog(node.blockPool.finalizedHead.blck.root),
    finalizedEpoch = shortLog(node.blockPool.finalizedHead.blck.slot.compute_epoch_at_slot()),
    cat = "scheduling"

  # Check before any re-scheduling of onSlotStart()
  # Offset backwards slightly to allow this epoch's finalization check to occur
  if scheduledSlot > 3 and node.config.stopAtEpoch > 0'u64 and
      (scheduledSlot - 3).compute_epoch_at_slot() >= node.config.stopAtEpoch:
    info "Stopping at pre-chosen epoch",
      chosenEpoch = node.config.stopAtEpoch,
      epoch = scheduledSlot.compute_epoch_at_slot(),
      slot = scheduledSlot

    # Brute-force, but ensure it's reliably enough to run in CI.
    quit(0)

  if not wallSlot.afterGenesis or (wallSlot.slot < lastSlot):
    let
      slot =
        if wallSlot.afterGenesis: wallSlot.slot
        else: GENESIS_SLOT
      nextSlot = slot + 1 # At least GENESIS_SLOT + 1!

    # This can happen if the system clock changes time for example, and it's
    # pretty bad
    # TODO shut down? time either was or is bad, and PoS relies on accuracy..
    warn "Beacon clock time moved back, rescheduling slot actions",
      beaconTime = shortLog(beaconTime),
      lastSlot = shortLog(lastSlot),
      scheduledSlot = shortLog(scheduledSlot),
      nextSlot = shortLog(nextSlot),
      cat = "clock_drift" # tag "scheduling|clock_drift"?

    addTimer(saturate(node.beaconClock.fromNow(nextSlot))) do (p: pointer):
      asyncCheck node.onSlotStart(slot, nextSlot)

    return

  let
    slot = wallSlot.slot # afterGenesis == true!
    nextSlot = slot + 1

  beacon_slot.set slot.int64

  if node.config.verifyFinalization:
    verifyFinalization(node, scheduledSlot)

  if slot > lastSlot + SLOTS_PER_EPOCH:
    # We've fallen behind more than an epoch - there's nothing clever we can
    # do here really, except skip all the work and try again later.
    # TODO how long should the period be? Using an epoch because that's roughly
    #      how long attestations remain interesting
    # TODO should we shut down instead? clearly we're unable to keep up
    warn "Unable to keep up, skipping ahead",
      lastSlot = shortLog(lastSlot),
      slot = shortLog(slot),
      nextSlot = shortLog(nextSlot),
      scheduledSlot = shortLog(scheduledSlot),
      cat = "overload"

    addTimer(saturate(node.beaconClock.fromNow(nextSlot))) do (p: pointer):
      # We pass the current slot here to indicate that work should be skipped!
      asyncCheck node.onSlotStart(slot, nextSlot)
    return

  # Whatever we do during the slot, we need to know the head, because this will
  # give us a state to work with and thus a shuffling.
  # TODO typically, what consitutes correct actions stays constant between slot
  #      updates and is stable across some epoch transitions as well - see how
  #      we can avoid recalculating everything here
  # TODO if the head is very old, that is indicative of something being very
  #      wrong - us being out of sync or disconnected from the network - need
  #      to consider what to do in that case:
  #      * nothing - the other parts of the application will reconnect and
  #                  start listening to broadcasts, learn a new head etc..
  #                  risky, because the network might stall if everyone does
  #                  this, because no blocks will be produced
  #      * shut down - this allows the user to notice and take action, but is
  #                    kind of harsh
  #      * keep going - we create blocks and attestations as usual and send them
  #                     out - if network conditions improve, fork choice should
  #                     eventually select the correct head and the rest will
  #                     disappear naturally - risky because user is not aware,
  #                     and might lose stake on canonical chain but "just works"
  #                     when reconnected..
  var head = node.updateHead()

  # TODO is the slot of the clock or the head block more interesting? provide
  #      rationale in comment
  beacon_head_slot.set slot.int64

  # Time passes in here..
  asyncCheck node.handleValidatorDuties(lastSlot, slot)

  let
    nextSlotStart = saturate(node.beaconClock.fromNow(nextSlot))

  info "Slot end",
    slot = shortLog(slot),
    nextSlot = shortLog(nextSlot),
    headSlot = shortLog(node.blockPool.head.blck.slot),
    headEpoch = shortLog(node.blockPool.head.blck.slot.compute_epoch_at_slot()),
    headRoot = shortLog(node.blockPool.head.blck.root),
    finalizedSlot = shortLog(node.blockPool.finalizedHead.blck.slot),
    finalizedEpoch = shortLog(node.blockPool.finalizedHead.blck.slot.compute_epoch_at_slot()),
    finalizedRoot = shortLog(node.blockPool.finalizedHead.blck.root),
    cat = "scheduling"

  when declared(GC_fullCollect):
    # The slots in the beacon node work as frames in a game: we want to make
    # sure that we're ready for the next one and don't get stuck in lengthy
    # garbage collection tasks when time is of essence in the middle of a slot -
    # while this does not guarantee that we'll never collect during a slot, it
    # makes sure that all the scratch space we used during slot tasks (logging,
    # temporary buffers etc) gets recycled for the next slot that is likely to
    # need similar amounts of memory.
    GC_fullCollect()

  addTimer(nextSlotStart) do (p: pointer):
    asyncCheck node.onSlotStart(slot, nextSlot)

proc handleMissingBlocks(node: BeaconNode) =
  let missingBlocks = node.blockPool.checkMissing()
  if missingBlocks.len > 0:
    var left = missingBlocks.len
    info "Requesting detected missing blocks", blocks = shortLog(missingBlocks)
    node.requestManager.fetchAncestorBlocks(missingBlocks)

proc onSecond(node: BeaconNode) {.async.} =
  ## This procedure will be called once per second.
  if not(node.syncManager.inProgress):
    node.handleMissingBlocks()

proc runOnSecondLoop(node: BeaconNode) {.async.} =
  var sleepTime = chronos.seconds(1)
  while true:
    await chronos.sleepAsync(sleepTime)
    let start = chronos.now(chronos.Moment)
    await node.onSecond()
    let finish = chronos.now(chronos.Moment)
    debug "onSecond task completed", elapsed = $(finish - start)
    if finish - start > chronos.seconds(1):
      sleepTime = chronos.seconds(0)
    else:
      sleepTime = chronos.seconds(1) - (finish - start)

proc runForwardSyncLoop(node: BeaconNode) {.async.} =
  func getLocalHeadSlot(): Slot =
    result = node.blockPool.head.blck.slot

  proc getLocalWallSlot(): Slot {.gcsafe.} =
    let epoch = node.beaconClock.now().slotOrZero.compute_epoch_at_slot() +
                1'u64
    result = epoch.compute_start_slot_at_epoch()

  func getFirstSlotAtFinalizedEpoch(): Slot {.gcsafe.} =
    let fepoch = node.blockPool.headState.data.data.finalized_checkpoint.epoch
    compute_start_slot_at_epoch(fepoch)

  proc updateLocalBlocks(list: openarray[SignedBeaconBlock]): Result[void, BlockError] =
    debug "Forward sync imported blocks", count = len(list),
          local_head_slot = getLocalHeadSlot()
    let sm = now(chronos.Moment)
    for blk in list:
      let res = node.storeBlock(blk)
      # We going to ignore `BlockError.Unviable` errors because we have working
      # backward sync and it can happens that we can perform overlapping
      # requests.
      if res.isErr and res.error != BlockError.Unviable:
        return res
    discard node.updateHead()

    let dur = now(chronos.Moment) - sm
    let secs = float(chronos.seconds(1).nanoseconds)
    var storeSpeed = 0.0
    if not(dur.isZero()):
      let v = float(len(list)) * (secs / float(dur.nanoseconds))
      # We doing round manually because stdlib.round is deprecated
      storeSpeed = round(v * 10000) / 10000

    info "Forward sync blocks got imported successfully", count = len(list),
         local_head_slot = getLocalHeadSlot(), store_speed = storeSpeed
    ok()

  proc scoreCheck(peer: Peer): bool =
    if peer.score < PeerScoreLowLimit:
      try:
        debug "Peer score is too low, removing it from PeerPool", peer = peer,
              peer_score = peer.score, score_low_limit = PeerScoreLowLimit,
              score_high_limit = PeerScoreHighLimit
      except:
        discard
      result = false
    else:
      result = true

  node.network.peerPool.setScoreCheck(scoreCheck)

  node.syncManager = newSyncManager[Peer, PeerID](
    node.network.peerPool, getLocalHeadSlot, getLocalWallSlot,
    getFirstSlotAtFinalizedEpoch, updateLocalBlocks,
    # 4 blocks per chunk is the optimal value right now, because our current
    # syncing speed is around 4 blocks per second. So there no need to request
    # more then 4 blocks right now. As soon as `store_speed` value become
    # significantly more then 4 blocks per second you can increase this
    # value appropriately.
    chunkSize = 4
  )

  await node.syncManager.sync()

proc currentSlot(node: BeaconNode): Slot =
  node.beaconClock.now.slotOrZero

proc connectedPeersCount(node: BeaconNode): int =
  nbc_peers.value.int

func fromJson(n: JsonNode; argName: string; result: var Slot) =
  var i: int
  fromJson(n, argName, i)
  result = Slot(i)

proc installBeaconApiHandlers(rpcServer: RpcServer, node: BeaconNode) =
  rpcServer.rpc("getBeaconHead") do () -> Slot:
    return node.blockPool.head.blck.slot

  rpcServer.rpc("getChainHead") do () -> JsonNode:
    let
      head = node.blockPool.head
      finalized = node.blockPool.headState.data.data.finalized_checkpoint
      justified = node.blockPool.headState.data.data.current_justified_checkpoint
    return %* {
      "head_slot": head.blck.slot,
      "head_block_root": head.blck.root.data.toHex(),
      "finalized_slot": finalized.epoch * SLOTS_PER_EPOCH,
      "finalized_block_root": finalized.root.data.toHex(),
      "justified_slot": justified.epoch * SLOTS_PER_EPOCH,
      "justified_block_root": justified.root.data.toHex(),
    }

  rpcServer.rpc("getSyncing") do () -> bool:
    let
      beaconTime = node.beaconClock.now()
      wallSlot = currentSlot(node)
      headSlot = node.blockPool.head.blck.slot
    # FIXME: temporary hack: If more than 1 block away from expected head, then we are "syncing"
    return (headSlot + 1) < wallSlot

  template requireOneOf(x, y: distinct Option) =
    if x.isNone xor y.isNone:
      raise newException(CatchableError,
       "Please specify one of " & astToStr(x) & " or " & astToStr(y))

  template jsonResult(x: auto): auto =
    StringOfJson(Json.encode(x))

  rpcServer.rpc("getBeaconBlock") do (slot: Option[Slot],
                                      root: Option[Eth2Digest]) -> StringOfJson:
    requireOneOf(slot, root)
    var blockHash: Eth2Digest
    if root.isSome:
      blockHash = root.get
    else:
      let foundRef = node.blockPool.getBlockByPreciseSlot(slot.get)
      if foundRef != nil:
        blockHash = foundRef.root
      else:
        return StringOfJson("null")

    let dbBlock = node.db.getBlock(blockHash)
    if dbBlock.isSome:
      return jsonResult(dbBlock.get)
    else:
      return StringOfJson("null")

  rpcServer.rpc("getBeaconState") do (slot: Option[Slot],
                                      root: Option[Eth2Digest]) -> StringOfJson:
    requireOneOf(slot, root)
    if slot.isSome:
      let blk = node.blockPool.head.blck.atSlot(slot.get)
      node.blockPool.withState(node.blockPool.tmpState, blk):
        return jsonResult(state)
    else:
      let tmp = BeaconStateRef() # TODO use tmpState - but load the entire StateData!
      let state = node.db.getState(root.get, tmp[], noRollback)
      if state:
        return jsonResult(tmp[])
      else:
        return StringOfJson("null")

  rpcServer.rpc("getNetworkPeerId") do () -> string:
    return $publicKey(node.network)

  rpcServer.rpc("getNetworkPeers") do () -> seq[string]:
    for peerId, peer in node.network.peerPool:
      result.add $peerId

  rpcServer.rpc("getNetworkEnr") do () -> string:
    return $node.network.discovery.localNode.record

proc installDebugApiHandlers(rpcServer: RpcServer, node: BeaconNode) =
  rpcServer.rpc("getNodeVersion") do () -> string:
    return "Nimbus/" & fullVersionStr

  rpcServer.rpc("getSpecPreset") do () -> JsonNode:
    var res = newJObject()
    genCode:
      for setting in BeaconChainConstants:
        let
          settingSym = ident($setting)
          settingKey = newLit(toLowerAscii($setting))
        yield quote do:
          res[`settingKey`] = %`settingSym`

    return res

  rpcServer.rpc("peers") do () -> JsonNode:
    var res = newJObject()
    var peers = newJArray()
    for id, peer in node.network.peerPool:
      peers.add(
        %(
          info: shortLog(peer.info),
          wasDialed: peer.wasDialed,
          connectionState: $peer.connectionState,
          score: peer.score,
        )
      )
    res.add("peers", peers)

    return res

proc installRpcHandlers(rpcServer: RpcServer, node: BeaconNode) =
  rpcServer.installValidatorApiHandlers(node)
  rpcServer.installBeaconApiHandlers(node)
  rpcServer.installDebugApiHandlers(node)

proc installAttestationHandlers(node: BeaconNode) =
  proc attestationHandler(attestation: Attestation) =
    # Avoid double-counting attestation-topic attestations on shared codepath
    # when they're reflected through beacon blocks
    beacon_attestations_received.inc()
    beacon_attestation_received_seconds_from_slot_start.observe(
      node.beaconClock.now.int64 -
        (attestation.data.slot.int64 * SECONDS_PER_SLOT.int64))

    node.onAttestation(attestation)

  proc attestationValidator(attestation: Attestation,
                            committeeIndex: uint64): bool =
    # https://github.com/ethereum/eth2.0-specs/blob/v0.12.1/specs/phase0/p2p-interface.md#attestation-subnets
    let (afterGenesis, slot) = node.beaconClock.now().toSlot()
    if not afterGenesis:
      return false
    node.attestationPool.isValidAttestation(attestation, slot, committeeIndex)

  proc aggregatedAttestationValidator(
      signedAggregateAndProof: SignedAggregateAndProof): bool =
    let (afterGenesis, slot) = node.beaconClock.now().toSlot()
    if not afterGenesis:
      return false
    node.attestationPool.isValidAggregatedAttestation(signedAggregateAndProof, slot)

  var attestationSubscriptions: seq[Future[void]] = @[]

  # https://github.com/ethereum/eth2.0-specs/blob/v0.12.1/specs/phase0/p2p-interface.md#attestations-and-aggregation
  for it in 0'u64 ..< ATTESTATION_SUBNET_COUNT.uint64:
    closureScope:
      let ci = it
      attestationSubscriptions.add(node.network.subscribe(
        getAttestationTopic(node.forkDigest, ci), attestationHandler,
        # This proc needs to be within closureScope; don't lift out of loop.
        proc(attestation: Attestation): bool =
          attestationValidator(attestation, ci)
      ))

  attestationSubscriptions.add(node.network.subscribe(
    getAggregateAndProofsTopic(node.forkDigest),
    proc(signedAggregateAndProof: SignedAggregateAndProof) =
      attestationHandler(signedAggregateAndProof.message.aggregate),
    proc(signedAggregateAndProof: SignedAggregateAndProof): bool =
      aggregatedAttestationValidator(signedAggregateAndProof)
  ))

  waitFor allFutures(attestationSubscriptions)

proc stop*(node: BeaconNode) =
  status = BeaconNodeStatus.Stopping
  info "Graceful shutdown"
  waitFor node.network.stop()

proc run*(node: BeaconNode) =
  if status == BeaconNodeStatus.Starting:
    # it might have been set to "Stopping" with Ctrl+C
    status = BeaconNodeStatus.Running

    if node.rpcServer != nil:
      node.rpcServer.installRpcHandlers(node)
      node.rpcServer.start()

    waitFor node.network.subscribe(node.topicBeaconBlocks) do (signedBlock: SignedBeaconBlock):
      onBeaconBlock(node, signedBlock)
    do (signedBlock: SignedBeaconBlock) -> bool:
      let (afterGenesis, slot) = node.beaconClock.now.toSlot()
      if not afterGenesis:
        return false

      let blck = node.blockPool.isValidBeaconBlock(signedBlock, slot, {})
      node.dumpBlock(signedBlock, blck)

      blck.isOk

    installAttestationHandlers(node)

    let
      curSlot = node.beaconClock.now().slotOrZero()
      nextSlot = curSlot + 1 # No earlier than GENESIS_SLOT + 1
      fromNow = saturate(node.beaconClock.fromNow(nextSlot))

    info "Scheduling first slot action",
      beaconTime = shortLog(node.beaconClock.now()),
      nextSlot = shortLog(nextSlot),
      fromNow = shortLog(fromNow),
      cat = "scheduling"

    addTimer(fromNow) do (p: pointer):
      asyncCheck node.onSlotStart(curSlot, nextSlot)

    node.onSecondLoop = runOnSecondLoop(node)
    node.forwardSyncLoop = runForwardSyncLoop(node)

    node.requestManager.start()

  # main event loop
  while status == BeaconNodeStatus.Running:
    try:
      poll()
    except CatchableError as e:
      debug "Exception in poll()", exc = e.name, err = e.msg

  # time to say goodbye
  node.stop()

var gPidFile: string
proc createPidFile(filename: string) =
  createDir splitFile(filename).dir
  writeFile filename, $os.getCurrentProcessId()
  gPidFile = filename
  addQuitProc proc {.noconv.} = removeFile gPidFile

proc initializeNetworking(node: BeaconNode) {.async.} =
  node.network.startListening()

  let addressFile = node.config.dataDir / "beacon_node.enr"
  writeFile(addressFile, node.network.announcedENR.toURI)

  await node.network.startLookingForPeers()

  info "Networking initialized",
    enr = node.network.announcedENR.toURI,
    libp2p = shortLog(node.network.switch.peerInfo)

proc start(node: BeaconNode) =
  let
    head = node.blockPool.head
    finalizedHead = node.blockPool.finalizedHead
    genesisTime = node.beaconClock.fromNow(toBeaconTime(Slot 0))

  info "Starting beacon node",
    version = fullVersionStr,
    nim = shortNimBanner(),
    timeSinceFinalization =
      int64(finalizedHead.slot.toBeaconTime()) -
      int64(node.beaconClock.now()),
    headSlot = shortLog(head.blck.slot),
    headRoot = shortLog(head.blck.root),
    finalizedSlot = shortLog(finalizedHead.blck.slot),
    finalizedRoot = shortLog(finalizedHead.blck.root),
    SLOTS_PER_EPOCH,
    SECONDS_PER_SLOT,
    SPEC_VERSION,
    dataDir = node.config.dataDir.string,
    cat = "init",
    pcs = "start_beacon_node"

  if genesisTime.inFuture:
    notice "Waiting for genesis", genesisIn = genesisTime.offset

  waitFor node.initializeNetworking()
  node.run()

func formatGwei(amount: uint64): string =
  # TODO This is implemented in a quite a silly way.
  # Better routines for formatting decimal numbers
  # should exists somewhere else.
  let
    eth = amount div 1000000000
    remainder = amount mod 1000000000

  result = $eth
  if remainder != 0:
    result.add '.'
    result.add $remainder
    while result[^1] == '0':
      result.setLen(result.len - 1)

when hasPrompt:
  from unicode import Rune
  import prompt

  func providePromptCompletions*(line: seq[Rune], cursorPos: int): seq[string] =
    # TODO
    # The completions should be generated with the general-purpose command-line
    # parsing API of Confutils
    result = @[]

  proc processPromptCommands(p: ptr Prompt) {.thread.} =
    while true:
      var cmd = p[].readLine()
      case cmd
      of "quit":
        quit 0
      else:
        p[].writeLine("Unknown command: " & cmd)

  proc initPrompt(node: BeaconNode) =
    if isatty(stdout) and node.config.statusBarEnabled:
      enableTrueColors()

      # TODO: nim-prompt seems to have threading issues at the moment
      #       which result in sporadic crashes. We should introduce a
      #       lock that guards the access to the internal prompt line
      #       variable.
      #
      # var p = Prompt.init("nimbus > ", providePromptCompletions)
      # p.useHistoryFile()

      proc dataResolver(expr: string): string =
        # TODO:
        # We should introduce a general API for resolving dot expressions
        # such as `db.latest_block.slot` or `metrics.connected_peers`.
        # Such an API can be shared between the RPC back-end, CLI tools
        # such as ncli, a potential GraphQL back-end and so on.
        # The status bar feature would allow the user to specify an
        # arbitrary expression that is resolvable through this API.
        case expr.toLowerAscii
        of "connected_peers":
          $(node.connectedPeersCount)

        of "head_root":
          shortLog(node.blockPool.head.blck.root)
        of "head_epoch":
          $(node.blockPool.head.blck.slot.epoch)
        of "head_epoch_slot":
          $(node.blockPool.head.blck.slot mod SLOTS_PER_EPOCH)
        of "head_slot":
          $(node.blockPool.head.blck.slot)

        of "justifed_root":
          shortLog(node.blockPool.head.justified.blck.root)
        of "justifed_epoch":
          $(node.blockPool.head.justified.slot.epoch)
        of "justifed_epoch_slot":
          $(node.blockPool.head.justified.slot mod SLOTS_PER_EPOCH)
        of "justifed_slot":
          $(node.blockPool.head.justified.slot)

        of "finalized_root":
          shortLog(node.blockPool.finalizedHead.blck.root)
        of "finalized_epoch":
          $(node.blockPool.finalizedHead.slot.epoch)
        of "finalized_epoch_slot":
          $(node.blockPool.finalizedHead.slot mod SLOTS_PER_EPOCH)
        of "finalized_slot":
          $(node.blockPool.finalizedHead.slot)

        of "epoch":
          $node.currentSlot.epoch

        of "epoch_slot":
          $(node.currentSlot mod SLOTS_PER_EPOCH)

        of "slot":
          $node.currentSlot

        of "slots_per_epoch":
          $SLOTS_PER_EPOCH

        of "slot_trailing_digits":
          var slotStr = $node.currentSlot
          if slotStr.len > 3: slotStr = slotStr[^3..^1]
          slotStr

        of "attached_validators_balance":
          var balance = uint64(0)
          # TODO slow linear scan!
          for idx, b in node.blockPool.headState.data.data.balances:
            if node.getAttachedValidator(
                node.blockPool.headState.data.data, ValidatorIndex(idx)) != nil:
              balance += b
          formatGwei(balance)

        else:
          # We ignore typos for now and just render the expression
          # as it was written. TODO: come up with a good way to show
          # an error message to the user.
          "$" & expr

      var statusBar = StatusBarView.init(
        node.config.statusBarContents,
        dataResolver)

      when compiles(defaultChroniclesStream.output.writer):
        defaultChroniclesStream.output.writer =
          proc (logLevel: LogLevel, msg: LogOutputStr) {.gcsafe, raises: [Defect].} =
            try:
              # p.hidePrompt
              erase statusBar
              # p.writeLine msg
              stdout.write msg
              render statusBar
              # p.showPrompt
            except Exception as e: # render raises Exception
              logLoggingFailure(cstring(msg), e)

      proc statusBarUpdatesPollingLoop() {.async.} =
        while true:
          update statusBar
          await sleepAsync(chronos.seconds(1))

      traceAsyncErrors statusBarUpdatesPollingLoop()

      # var t: Thread[ptr Prompt]
      # createThread(t, processPromptCommands, addr p)

proc createWalletInteractively(conf: BeaconNodeConf): OutFile {.raises: [Defect].} =
  if conf.nonInteractive:
    fatal "Wallets can be created only in interactive mode"
    quit 1

  var mnemonic = generateMnemonic()
  defer: keystore_management.burnMem(mnemonic)

  template readLine: string =
    try: stdin.readLine()
    except IOError:
      fatal "Failed to read data from stdin"
      quit 1

  echo "The created wallet will be protected with a password " &
       "that applies only to the current Nimbus installation. " &
       "In case you lose your wallet and you need to restore " &
       "it on a different machine, you must use the following " &
       "seed recovery phrase: \n"

  echo $mnemonic

  echo "Please back up the seed phrase now to a safe location as " &
       "if you are protecting a sensitive password. The seed phrase " &
       "be used to withdrawl funds from your wallet.\n"

  echo "Did you back up your seed recovery phrase? (please type 'yes' to continue or press enter to quit)"
  while true:
    let answer = readLine()
    if answer == "":
      quit 1
    elif answer != "yes":
      echo "To continue, please type 'yes' (without the quotes) or press enter to quit"
    else:
      break

  echo "When you perform operations with your wallet such as withdrawals " &
       "and additional deposits, you'll be asked to enter a password. " &
       "Please note that this password is local to the current Nimbus " &
       "installation and can be changed at any time."

  while true:
    var password, confirmedPassword: TaintedString
    try:
      let status = try:
        readPasswordFromStdin("Please enter a password:", password) and
        readPasswordFromStdin("Please repeat the password:", confirmedPassword)
      except IOError:
        fatal "Failed to read password interactively"
        quit 1

      if status:
        if password != confirmedPassword:
          echo "Passwords don't match, please try again"
        else:
          var name: WalletName
          if conf.createdWalletName.isSome:
            name = conf.createdWalletName.get
          else:
            echo "For your convenience, the wallet can be identified with a name " &
                 "of your choice. Please enter a wallet name below or press ENTER " &
                 "to continue with a machine-generated name."

            while true:
              var enteredName = readLine()
              if enteredName.len > 0:
                name = try: WalletName.parseCmdArg(enteredName)
                       except CatchableError as err:
                         echo err.msg & ". Please try again."
                         continue
              break

          let (uuid, walletContent) = KdfPbkdf2.createWalletContent(mnemonic, name)
          try:
            var outWalletFile: OutFile

            if conf.createdWalletFile.isSome:
              outWalletFile = conf.createdWalletFile.get
              createDir splitFile(string outWalletFile).dir
            else:
              let walletsDir = conf.walletsDir
              createDir walletsDir
              outWalletFile = OutFile(walletsDir / addFileExt(string uuid, "json"))

            writeFile(string outWalletFile, string walletContent)
            return outWalletFile
          except CatchableError as err:
            fatal "Failed to write wallet file", err = err.msg
            quit 1

      if not status:
        fatal "Failed to read a password from stdin"
        quit 1

    finally:
      keystore_management.burnMem(password)
      keystore_management.burnMem(confirmedPassword)

programMain:
  let config = makeBannerAndConfig(clientId, BeaconNodeConf)

  setupMainProc(config.logLevel)

  ## handle command line arguments
  case config.cmd
  of createTestnet:
    var
      depositDirs: seq[string]
      deposits: seq[Deposit]
      i = -1
    for kind, dir in walkDir(config.testnetDepositsDir.string):
      if kind != pcDir:
        continue

      inc i
      if i < config.firstValidator.int:
        continue

      depositDirs.add dir

    # Add deposits, in order, to pass Merkle validation
    sort(depositDirs, system.cmp)

    for dir in depositDirs:
      let depositFile = dir / "deposit.json"
      try:
        deposits.add Json.loadFile(depositFile, Deposit)
      except SerializationError as err:
        stderr.write "Error while loading a deposit file:\n"
        stderr.write err.formatMsg(depositFile), "\n"
        stderr.write "Please regenerate the deposit files by running 'beacon_node deposits create' again\n"
        quit 1

    let
      startTime = uint64(times.toUnix(times.getTime()) + config.genesisOffset)
      outGenesis = config.outputGenesis.string
      eth1Hash = if config.web3Url.len == 0: eth1BlockHash
                 else: waitFor getLatestEth1BlockHash(config.web3Url)
    var
      initialState = initialize_beacon_state_from_eth1(
        eth1Hash, startTime, deposits, {skipBlsValidation})

    # https://github.com/ethereum/eth2.0-pm/tree/6e41fcf383ebeb5125938850d8e9b4e9888389b4/interop/mocked_start#create-genesis-state
    initialState.genesis_time = startTime

    doAssert initialState.validators.len > 0

    let outGenesisExt = splitFile(outGenesis).ext
    if cmpIgnoreCase(outGenesisExt, ".json") == 0:
      Json.saveFile(outGenesis, initialState, pretty = true)
      echo "Wrote ", outGenesis

    let outSszGenesis = outGenesis.changeFileExt "ssz"
    SSZ.saveFile(outSszGenesis, initialState[])
    echo "Wrote ", outSszGenesis

    let bootstrapFile = config.outputBootstrapFile.string
    if bootstrapFile.len > 0:
      let
        networkKeys = getPersistentNetKeys(config)
        metadata = getPersistentNetMetadata(config)
        bootstrapEnr = enr.Record.init(
          1, # sequence number
          networkKeys.seckey.asEthKey,
          some(config.bootstrapAddress),
          config.bootstrapPort,
          config.bootstrapPort,
          [toFieldPair("eth2", SSZ.encode(enrForkIdFromState initialState[])),
           toFieldPair("attnets", SSZ.encode(metadata.attnets))])

      writeFile(bootstrapFile, bootstrapEnr.tryGet().toURI)
      echo "Wrote ", bootstrapFile

  of noCommand:
    debug "Launching beacon node",
          version = fullVersionStr,
          cmdParams = commandLineParams(),
          config

    createPidFile(config.dataDir.string / "beacon_node.pid")

    config.createDumpDirs()

    var node = waitFor BeaconNode.init(config)

    ctrlCHandling: status = BeaconNodeStatus.Stopping

    when hasPrompt:
      initPrompt(node)

    when useInsecureFeatures:
      if config.metricsEnabled:
        let metricsAddress = config.metricsAddress
        info "Starting metrics HTTP server",
          address = metricsAddress, port = config.metricsPort
        metrics.startHttpServer($metricsAddress, config.metricsPort)

    if node.nickname != "":
      dynamicLogScope(node = node.nickname): node.start()
    else:
      node.start()

  of deposits:
    case config.depositsCmd
    of DepositsCmd.create:
      createDir(config.outValidatorsDir)
      createDir(config.outSecretsDir)

      let deposits = generateDeposits(
        config.totalDeposits,
        config.outValidatorsDir,
        config.outSecretsDir)

      if deposits.isErr:
        fatal "Failed to generate deposits", err = deposits.error
        quit 1

      if not config.dontSend:
        waitFor sendDeposits(config, deposits.value)

    of DepositsCmd.send:
      var delayGenerator: DelayGenerator
      if config.maxDelay > 0.0:
        delayGenerator = proc (): chronos.Duration {.gcsafe.} =
          chronos.milliseconds (rand(config.minDelay..config.maxDelay)*1000).int

      if config.minDelay > config.maxDelay:
        echo "The minimum delay should not be larger than the maximum delay"
        quit 1

      let deposits = loadDeposits(config.depositsDir)
      waitFor sendDeposits(config, deposits, delayGenerator)

    of DepositsCmd.status:
      # TODO
      echo "The status command is not implemented yet"
      quit 1

  of wallets:
    case config.walletsCmd:
    of WalletsCmd.create:
      let walletFile = createWalletInteractively(config)
    of WalletsCmd.list:
      # TODO
      discard
    of WalletsCmd.restore:
      # TODO
      discard
