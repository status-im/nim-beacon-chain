import
  # Standard library
  os, net, tables, random, strutils, times, memfiles,

  # Nimble packages
  stew/[objects, bitseqs], stew/ranges/ptr_arith,
  chronos, chronicles, confutils, metrics,
  json_serialization/std/[options, sets], serialization/errors,
  eth/trie/db, eth/trie/backends/rocksdb_backend, eth/async_utils,

  # Local modules
  spec/[datatypes, digest, crypto, beaconstate, helpers, validator, network],
  conf, time, state_transition, fork_choice, beacon_chain_db,
  validator_pool, extras, attestation_pool, block_pool, eth2_network,
  beacon_node_types, mainchain_monitor, version, ssz, ssz/dynamic_navigator,
  sync_protocol, request_manager, validator_keygen, interop, statusbar

const
  dataDirValidators = "validators"
  genesisFile = "genesis.ssz"
  hasPrompt = not defined(withoutPrompt)

# https://github.com/ethereum/eth2.0-metrics/blob/master/metrics.md#interop-metrics
declareGauge beacon_slot,
  "Latest slot of the beacon chain state"
declareGauge beacon_head_slot,
  "Slot of the head block of the beacon chain"
declareGauge beacon_head_root,
  "Root of the head block of the beacon chain"

# Metrics for tracking attestation and beacon block loss
declareCounter beacon_attestations_sent,
  "Number of beacon chain attestations sent by this peer"
declareCounter beacon_attestations_received,
  "Number of beacon chain attestations received by this peer"
declareCounter beacon_blocks_proposed,
  "Number of beacon chain blocks sent by this peer"
declareCounter beacon_blocks_received,
  "Number of beacon chain blocks received by this peer"

logScope: topics = "beacnde"

proc onBeaconBlock*(node: BeaconNode, blck: BeaconBlock) {.gcsafe.}

func localValidatorsDir(conf: BeaconNodeConf): string =
  conf.dataDir / "validators"

func databaseDir(conf: BeaconNodeConf): string =
  conf.dataDir / "db"

proc saveValidatorKey(keyName, key: string, conf: BeaconNodeConf) =
  let validatorsDir = conf.dataDir / dataDirValidators
  let outputFile = validatorsDir / keyName
  createDir validatorsDir
  writeFile(outputFile, key)
  info "Imported validator key", file = outputFile

proc getStateFromSnapshot(node: BeaconNode, state: var BeaconState): bool =
  template conf: untyped = node.config

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
      error "missing genesis file"
      writeGenesisFile = true
      genesisPath = snapshotPath
  else:
    try:
      snapshotContents = readFile(genesisPath)
    except CatchableError as err:
      error "Failed to read genesis file", err = err.msg
      quit 1

  try:
    state = SSZ.decode(snapshotContents, BeaconState)
  except SerializationError as err:
    error "Failed to import genesis file", path = genesisPath
    quit 1

  if writeGenesisFile:
    try:
      error "writing genesis file", path = conf.dataDir/genesisFile
      writeFile(conf.dataDir/genesisFile, snapshotContents.string)
    except CatchableError as err:
      error "Failed to persist genesis file to data dir", err = err.msg
      quit 1

  result = true

proc commitGenesisState(node: BeaconNode, tailState: BeaconState) =
  info "Got genesis state", hash = hash_tree_root(tailState)
  node.forkVersion = tailState.fork.current_version
  try:
    let tailBlock = get_initial_beacon_block(tailState)
    BlockPool.preInit(node.db, tailState, tailBlock)

  except:
    stderr.write "Failed to initialize database\n"
    stderr.write getCurrentExceptionMsg(), "\n"
    quit 1

proc addBootstrapNode(node: BeaconNode, bootstrapNode: BootstrapAddr) =
  if bootstrapNode.isSameNode(node.networkIdentity):
    node.isBootstrapNode = true
  else:
    node.bootstrapNodes.add bootstrapNode

proc useBootstrapFile(node: BeaconNode, bootstrapFile: string) =
  for ln in lines(bootstrapFile):
    node.addBootstrapNode BootstrapAddr.initAddress(string ln)

proc init*(T: type BeaconNode, conf: BeaconNodeConf): Future[BeaconNode] {.async.} =
  new result
  result.onBeaconBlock = onBeaconBlock
  result.config = conf
  result.networkIdentity = getPersistentNetIdentity(conf)
  result.nickname = if conf.nodeName == "auto": shortForm(result.networkIdentity)
                    else: conf.nodeName

  template fail(args: varargs[untyped]) =
    stderr.write args, "\n"
    quit 1

  for bootNode in conf.bootstrapNodes:
    result.addBootstrapNode BootstrapAddr.init(bootNode)

  let bootstrapFile = string conf.bootstrapNodesFile
  if bootstrapFile.len > 0:
    result.useBootstrapFile(bootstrapFile)

  let siteLocalBootstrapFile = conf.dataDir / "bootstrap_nodes.txt"
  if fileExists(siteLocalBootstrapFile):
    result.useBootstrapFile(siteLocalBootstrapFile)

  result.attachedValidators = ValidatorPool.init

  let trieDB = trieDB newChainDb(conf.databaseDir)
  result.db = BeaconChainDB.init(trieDB)

  # TODO this is problably not the right place to ensure that db is sane..
  # TODO does it really make sense to load from DB if a state snapshot has been
  #      specified on command line? potentially, this should be the other way
  #      around...

  var eth1MonitorStartBlock: Eth2Digest
  if result.db.getHeadBlock().isNone():
    var state: BeaconState
    if not result.getStateFromSnapshot(state):
      if conf.depositWeb3Url.len != 0:
        result.mainchainMonitor = MainchainMonitor.init(conf.depositWeb3Url, conf.depositContractAddress, eth1MonitorStartBlock)
        result.mainchainMonitor.start()
      else:
        stderr.write "No state snapshot (or web3 URL) provided\n"
        quit 1

      state = await result.mainchainMonitor.getGenesis()
    else:
      eth1MonitorStartBlock = state.eth1Data.block_hash
    result.commitGenesisState(state)

  if result.mainchainMonitor.isNil and conf.depositWeb3Url.len != 0:
    result.mainchainMonitor = MainchainMonitor.init(conf.depositWeb3Url, conf.depositContractAddress, eth1MonitorStartBlock)
    result.mainchainMonitor.start()

  result.blockPool = BlockPool.init(result.db)
  result.attestationPool = AttestationPool.init(result.blockPool)

  result.network = await createEth2Node(conf, result.bootstrapNodes)
  result.requestManager.init result.network

  # TODO sync is called when a remote peer is connected - is that the right
  #      time to do so?
  let sync = result.network.protocolState(BeaconSync)
  sync.node = result
  sync.db = result.db

  result.stateCache = result.blockPool.loadTailState()
  result.justifiedStateCache = result.stateCache

  let addressFile = string(conf.dataDir) / "beacon_node.address"
  result.network.saveConnectionAddressFile(addressFile)
  result.beaconClock = BeaconClock.init(result.stateCache.data.data)

  when useInsecureFeatures:
    if conf.metricsServer:
      let metricsAddress = conf.metricsServerAddress
      info "Starting metrics HTTP server", address = metricsAddress, port = conf.metricsServerPort
      metrics.startHttpServer(metricsAddress, Port(conf.metricsServerPort))

template withState(
    pool: BlockPool, cache: var StateData, blockSlot: BlockSlot, body: untyped): untyped =
  ## Helper template that updates state to a particular BlockSlot - usage of
  ## cache is unsafe outside of block.
  ## TODO async transformations will lead to a race where cache gets updated
  ##      while waiting for future to complete - catch this here somehow?

  updateStateData(pool, cache, blockSlot)

  template hashedState(): HashedBeaconState {.inject, used.} = cache.data
  template state(): BeaconState {.inject, used.} = cache.data.data
  template blck(): BlockRef {.inject, used.} = cache.blck
  template root(): Eth2Digest {.inject, used.} = cache.data.root

  body

proc connectToNetwork(node: BeaconNode) {.async.} =
  if node.bootstrapNodes.len > 0:
    info "Connecting to bootstrap nodes", bootstrapNodes = node.bootstrapNodes
  else:
    info "Waiting for connections"

  await node.network.connectToNetwork(node.bootstrapNodes)

template findIt(s: openarray, predicate: untyped): int =
  var res = -1
  for i, it {.inject.} in s:
    if predicate:
      res = i
      break
  res

proc addLocalValidator(
    node: BeaconNode, state: BeaconState, privKey: ValidatorPrivKey) =
  let pubKey = privKey.pubKey()

  let idx = state.validators.findIt(it.pubKey == pubKey)
  if idx == -1:
    warn "Validator not in registry", pubKey
  else:
    node.attachedValidators.addLocalValidator(ValidatorIndex(idx), pubKey, privKey)

proc addLocalValidators(node: BeaconNode, state: BeaconState) =
  for validatorKeyFile in node.config.validators:
    node.addLocalValidator state, validatorKeyFile.load

  for kind, file in walkDir(node.config.localValidatorsDir):
    if kind in {pcFile, pcLinkToFile}:
      node.addLocalValidator state, ValidatorPrivKey.init(readFile(file).string)

  info "Local validators attached ", count = node.attachedValidators.count

proc getAttachedValidator(node: BeaconNode,
                          state: BeaconState,
                          idx: ValidatorIndex): AttachedValidator =
  let validatorKey = state.validators[idx].pubkey
  node.attachedValidators.getValidator(validatorKey)

proc updateHead(node: BeaconNode, slot: Slot): BlockRef =
  # Use head state for attestation resolution below

  # Check pending attestations - maybe we found some blocks for them
  node.attestationPool.resolve(node.stateCache)

  # TODO move all of this logic to BlockPool

  let
    justifiedHead = node.blockPool.latestJustifiedBlock()

  let newHead = node.blockPool.withState(
      node.justifiedStateCache, justifiedHead):
    lmdGhost(node.attestationPool, state, justifiedHead.blck)

  node.blockPool.updateHead(node.stateCache, newHead)
  beacon_head_slot.set slot.int64
  beacon_head_root.set newHead.root.toGaugeValue

  newHead

proc sendAttestation(node: BeaconNode,
                     fork: Fork,
                     validator: AttachedValidator,
                     attestationData: AttestationData,
                     committeeLen: int,
                     indexInCommittee: int) {.async.} =
  logScope: pcs = "send_attestation"

  let
    validatorSignature = await validator.signAttestation(attestationData, fork)

  var aggregationBits = CommitteeValidatorsBits.init(committeeLen)
  aggregationBits.raiseBit indexInCommittee

  var attestation = Attestation(
    data: attestationData,
    signature: validatorSignature,
    aggregation_bits: aggregationBits
  )

  node.network.broadcast(topicAttestations, attestation)

  info "Attestation sent",
    attestationData = shortLog(attestationData),
    validator = shortLog(validator),
    signature = shortLog(validatorSignature),
    indexInCommittee = indexInCommittee,
    cat = "consensus"

  beacon_attestations_sent.inc()

proc proposeBlock(node: BeaconNode,
                  validator: AttachedValidator,
                  head: BlockRef,
                  slot: Slot): Future[BlockRef] {.async.} =
  logScope: pcs = "block_proposal"

  if head.slot > slot:
    notice "Skipping proposal, we've already selected a newer head",
      headSlot = shortLog(head.slot),
      headBlockRoot = shortLog(head.root),
      slot = shortLog(slot),
      cat = "fastforward"
    return head

  if head.slot == 0 and slot == 0:
    # TODO there's been a startup assertion, which sometimes (but not always
    # evidently) crashes exactly one node on simulation startup, the one the
    # beacon chain proposer index points to first for slot 0. it tries using
    # slot 0 as required, notices head block's slot is also 0 (which, that's
    # how it's created; it's never less), and promptly fails, with assertion
    # occuring downstream via async code. This is most easily reproduced via
    # make clean_eth2_network_simulation_files && make eth2_network_simulation
    return head

  if head.slot == slot:
    # Weird, we should never see as head the same slot as we're proposing a
    # block for - did someone else steal our slot? why didn't we discard it?
    warn "Found head at same slot as we're supposed to propose for!",
      headSlot = shortLog(head.slot),
      headBlockRoot = shortLog(head.root),
      cat = "consensus_conflict"
    # TODO investigate how and when this happens.. maybe it shouldn't be an
    #      assert?
    doAssert false, "head slot matches proposal slot (!)"
    # return

  # Get eth1data which may be async
  # TODO it's a bad idea to get eth1data async because that might delay block
  #      production
  let (eth1data, deposits) = node.blockPool.withState(
      node.stateCache, BlockSlot(blck: head, slot: slot - 1)):
    if node.mainchainMonitor.isNil:
      let e1d =
        get_eth1data_stub(
          state.eth1_deposit_index, slot.compute_epoch_at_slot())

      (e1d, newSeq[Deposit]())
    else:
      let e1d = node.mainchainMonitor.eth1Data

      (e1d, node.mainchainMonitor.getPendingDeposits())

  let (nroot, nblck) = node.blockPool.withState(
      node.stateCache, BlockSlot(blck: head, slot: slot - 1)):
    # To create a block, we'll first apply a partial block to the state, skipping
    # some validations.
    let
      fork = state.fork
      blockBody = BeaconBlockBody(
        randao_reveal: validator.genRandaoReveal(fork, slot),
        eth1_data: eth1data,
        attestations:
          node.attestationPool.getAttestationsForBlock(state, slot),
        deposits: deposits)

    var
      newBlock = BeaconBlock(
        slot: slot,
        parent_root: head.root,
        body: blockBody,
        # TODO: This shouldn't be necessary if OpaqueBlob is the default
        signature: ValidatorSig(kind: OpaqueBlob))
      tmpState = hashedState
    discard state_transition(tmpState, newBlock, {skipValidation})
    # TODO only enable in fast-fail debugging situations
    # otherwise, bad attestations can bring down network
    # doAssert ok # TODO: err, could this fail somehow?

    newBlock.state_root = tmpState.root

    let blockRoot = signing_root(newBlock)

    # Careful, state no longer valid after here..
    # We use the fork from the pre-newBlock state which should be fine because
    # fork carries two epochs, so even if it's a fork block, the right thing
    # will happen here
    newBlock.signature =
      await validator.signBlockProposal(fork, slot, blockRoot)

    (blockRoot, newBlock)

  let newBlockRef = node.blockPool.add(node.stateCache, nroot, nblck)
  if newBlockRef == nil:
    warn "Unable to add proposed block to block pool",
      newBlock = shortLog(newBlock),
      blockRoot = shortLog(blockRoot),
      cat = "bug"
    return head

  info "Block proposed",
    blck = shortLog(newBlock),
    blockRoot = shortLog(newBlockRef.root),
    validator = shortLog(validator),
    cat = "consensus"

  node.network.broadcast(topicBeaconBlocks, newBlock)

  beacon_blocks_proposed.inc()

  return newBlockRef

proc onAttestation(node: BeaconNode, attestation: Attestation) =
  # We received an attestation from the network but don't know much about it
  # yet - in particular, we haven't verified that it belongs to particular chain
  # we're on, or that it follows the rules of the protocol
  logScope: pcs = "on_attestation"

  debug "Attestation received",
    attestationData = shortLog(attestation.data),
    signature = shortLog(attestation.signature),
    cat = "consensus" # Tag "consensus|attestation"?

  if (let attestedBlock = node.blockPool.getOrResolve(
        attestation.data.beacon_block_root); attestedBlock != nil):
    let
      wallSlot = node.beaconClock.now().toSlot()
      head = node.blockPool.head

    if not wallSlot.afterGenesis or wallSlot.slot < head.blck.slot:
      warn "Received attestation before genesis or head - clock is wrong?",
        afterGenesis = wallSlot.afterGenesis,
        wallSlot = shortLog(wallSlot.slot),
        headSlot = shortLog(head.blck.slot),
        cat = "clock_drift" # Tag "attestation|clock_drift"?
      return

    # TODO seems reasonable to use the latest head state here.. needs thinking
    #      though - maybe we should use the state from the block pointed to by
    #      the attestation for some of the check? Consider interop with block
    #      production!
    let
      bs = BlockSlot(blck: head.blck, slot: wallSlot.slot)

    node.blockPool.withState(node.stateCache, bs):
      node.attestationPool.add(state, attestedBlock, attestation)
  else:
    node.attestationPool.addUnresolved(attestation)

proc onBeaconBlock(node: BeaconNode, blck: BeaconBlock) =
  # We received a block but don't know much about it yet - in particular, we
  # don't know if it's part of the chain we're currently building.
  let blockRoot = signing_root(blck)
  debug "Block received",
    blck = shortLog(blck),
    blockRoot = shortLog(blockRoot),
    cat = "block_listener",
    pcs = "receive_block"

  beacon_blocks_received.inc()

  if node.blockPool.add(node.stateCache, blockRoot, blck).isNil:
    return

  # The block we received contains attestations, and we might not yet know about
  # all of them. Let's add them to the attestation pool - in case they block
  # is not yet resolved, neither will the attestations be!
  # But please note that we only care about recent attestations.
  # TODO shouldn't add attestations if the block turns out to be invalid..
  let currentSlot = node.beaconClock.now.toSlot
  if currentSlot.afterGenesis and
     blck.slot.epoch + 1 >= currentSlot.slot.epoch:
    for attestation in blck.body.attestations:
      node.onAttestation(attestation)

proc handleAttestations(node: BeaconNode, head: BlockRef, slot: Slot) =
  ## Perform all attestations that the validators attached to this node should
  ## perform during the given slot
  logScope: pcs = "on_attestation"

  if slot + SLOTS_PER_EPOCH < head.slot:
    # The latest block we know about is a lot newer than the slot we're being
    # asked to attest to - this makes it unlikely that it will be included
    # at all.
    # TODO the oldest attestations allowed are those that are older than the
    #      finalized epoch.. also, it seems that posting very old attestations
    #      is risky from a slashing perspective. More work is needed here.
    notice "Skipping attestation, head is too recent",
      headSlot = shortLog(head.slot),
      slot = shortLog(slot)
    return

  let attestationHead = head.findAncestorBySlot(slot)
  if head != attestationHead.blck:
    # In rare cases, such as when we're busy syncing or just slow, we'll be
    # attesting to a past state - we must then recreate the world as it looked
    # like back then
    notice "Attesting to a state in the past, falling behind?",
      headSlot = shortLog(head.slot),
      attestationHeadSlot = shortLog(attestationHead.slot),
      attestationSlot = shortLog(slot)

  trace "Checking attestations",
    attestationHeadRoot = shortLog(attestationHead.blck.root),
    attestationSlot = shortLog(slot),
    cat = "attestation"

  # Collect data to send before node.stateCache grows stale
  var attestations: seq[tuple[
    data: AttestationData, committeeLen, indexInCommittee: int,
    validator: AttachedValidator]]

  # We need to run attestations exactly for the slot that we're attesting to.
  # In case blocks went missing, this means advancing past the latest block
  # using empty slots as fillers.
  # https://github.com/ethereum/eth2.0-specs/blob/v0.8.4/specs/validator/0_beacon-chain-validator.md#validator-assignments
  # TODO we could cache the validator assignment since it's valid for the entire
  #      epoch since it doesn't change, but that has to be weighed against
  #      the complexity of handling forks correctly - instead, we use an adapted
  #      version here that calculates the committee for a single slot only
  node.blockPool.withState(node.stateCache, attestationHead):
    var cache = get_empty_per_epoch_cache()
    let committees_per_slot = get_committee_count_at_slot(state, slot)

    for committee_index in 0'u64..<committees_per_slot:
      let
        committee = get_beacon_committee(state, slot, committee_index, cache)

      for index_in_committee, validatorIdx in committee:
        let validator = node.getAttachedValidator(state, validatorIdx)
        if validator != nil:
          let ad = makeAttestationData(state, slot, committee_index, blck.root)
          attestations.add((ad, committee.len, index_in_committee, validator))

    for a in attestations:
      traceAsyncErrors sendAttestation(
        node, state.fork, a.validator, a.data, a.committeeLen, a.indexInCommittee)

proc handleProposal(node: BeaconNode, head: BlockRef, slot: Slot):
    Future[BlockRef] {.async.} =
  ## Perform the proposal for the given slot, iff we have a validator attached
  ## that is supposed to do so, given the shuffling in head

  # TODO here we advanced the state to the new slot, but later we'll be
  #      proposing for it - basically, we're selecting proposer based on an
  #      empty slot.. wait for the committee selection to settle, then
  #      revisit this - we should be able to advance behind
  var cache = get_empty_per_epoch_cache()
  node.blockPool.withState(node.stateCache, BlockSlot(blck: head, slot: slot)):
    let
      proposerIdx = get_beacon_proposer_index(state, cache)
      validator = node.getAttachedValidator(state, proposerIdx)

    if validator != nil:
      return await proposeBlock(node, validator, head, slot)

    trace "Expecting block proposal",
      headRoot = shortLog(head.root),
      slot = shortLog(slot),
      proposer = shortLog(state.validators[proposerIdx].pubKey),
      cat = "consensus",
      pcs = "wait_for_proposal"

  return head

proc onSlotStart(node: BeaconNode, lastSlot, scheduledSlot: Slot) {.gcsafe, async.} =
  ## Called at the beginning of a slot - usually every slot, but sometimes might
  ## skip a few in case we're running late.
  ## lastSlot: the last slot that we sucessfully processed, so we know where to
  ##           start work from
  ## scheduledSlot: the slot that we were aiming for, in terms of timing

  logScope: pcs = "slot_start"

  let
    # The slot we should be at, according to the clock
    beaconTime = node.beaconClock.now()
    wallSlot = beaconTime.toSlot()

  debug "Slot start",
    lastSlot = shortLog(lastSlot),
    scheduledSlot = shortLog(scheduledSlot),
    beaconTime = shortLog(beaconTime),
    peers = node.network.peersCount,
    cat = "scheduling"

  if not wallSlot.afterGenesis or (wallSlot.slot < lastSlot):
    # This can happen if the system clock changes time for example, and it's
    # pretty bad
    # TODO shut down? time either was or is bad, and PoS relies on accuracy..
    warn "Beacon clock time moved back, rescheduling slot actions",
      beaconTime = shortLog(beaconTime),
      lastSlot = shortLog(lastSlot),
      scheduledSlot = shortLog(scheduledSlot),
      cat = "clock_drift" # tag "scheduling|clock_drift"?

    let
      slot = Slot(
        if wallSlot.afterGenesis:
          max(1'u64, wallSlot.slot.uint64)
        else: GENESIS_SLOT.uint64 + 1)
      nextSlot = slot + 1

    addTimer(saturate(node.beaconClock.fromNow(nextSlot))) do (p: pointer):
      asyncCheck node.onSlotStart(slot, nextSlot)

    return

  let
    slot = wallSlot.slot # afterGenesis == true!
    nextSlot = slot + 1

  beacon_slot.set slot.int64

  if slot > lastSlot + SLOTS_PER_EPOCH:
    # We've fallen behind more than an epoch - there's nothing clever we can
    # do here really, except skip all the work and try again later.
    # TODO how long should the period be? Using an epoch because that's roughly
    #      how long attestations remain interesting
    # TODO should we shut down instead? clearly we're unable to keep up
    warn "Unable to keep up, skipping ahead without doing work",
      lastSlot = shortLog(lastSlot),
      slot = shortLog(slot),
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

  var head = node.updateHead(slot)

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
  #      Right now, we keep going

  var curSlot = lastSlot + 1
  while curSlot < slot:
    # Timers may be delayed because we're busy processing, and we might have
    # more work to do. We'll try to do so in an expedited way.
    # TODO maybe even collect all work synchronously to avoid unnecessary
    #      state rewinds while waiting for async operations like validator
    #      signature..
    notice "Catching up",
      curSlot = shortLog(curSlot),
      lastSlot = shortLog(lastSlot),
      slot = shortLog(slot),
      cat = "overload"

    # For every slot we're catching up, we'll propose then send
    # attestations - head should normally be advancing along the same branch
    # in this case
    # TODO what if we receive blocks / attestations while doing this work?
    head = await handleProposal(node, head, curSlot)

    # For each slot we missed, we need to send out attestations - if we were
    # proposing during this time, we'll use the newly proposed head, else just
    # keep reusing the same - the attestation that goes out will actually
    # rewind the state to what it looked like at the time of that slot
    # TODO smells like there's an optimization opportunity here
    handleAttestations(node, head, curSlot)

    curSlot += 1

  head = await handleProposal(node, head, slot)

  # We've been doing lots of work up until now which took time. Normally, we
  # send out attestations at the slot mid-point, so we go back to the clock
  # to see how much time we need to wait.
  # TODO the beacon clock might jump here also. It's probably easier to complete
  #      the work for the whole slot using a monotonic clock instead, then deal
  #      with any clock discrepancies once only, at the start of slot timer
  #      processing..
  let
    attestationStart = node.beaconClock.fromNow(slot)
    halfSlot = seconds(int64(SECONDS_PER_SLOT div 2))

  if attestationStart.inFuture or attestationStart.offset <= halfSlot:
    let fromNow =
      if attestationStart.inFuture: attestationStart.offset + halfSlot
      else: halfSlot - attestationStart.offset

    trace "Waiting to send attestations",
      slot = shortLog(slot),
      fromNow = shortLog(fromNow),
      cat = "scheduling"

    await sleepAsync(fromNow)

    # Time passed - we might need to select a new head in that case
    head = node.updateHead(slot)

  handleAttestations(node, head, slot)

  # TODO ... and beacon clock might jump here also. sigh.
  let
    nextSlotStart = saturate(node.beaconClock.fromNow(nextSlot))

  addTimer(nextSlotStart) do (p: pointer):
    asyncCheck node.onSlotStart(slot, nextSlot)

proc onSecond(node: BeaconNode, moment: Moment) {.async.} =
  let missingBlocks = node.blockPool.checkMissing()
  if missingBlocks.len > 0:
    info "Requesting detected missing blocks", missingBlocks
    node.requestManager.fetchAncestorBlocks(missingBlocks) do (b: BeaconBlock):
      onBeaconBlock(node ,b)

  let nextSecond = max(Moment.now(), moment + chronos.seconds(1))
  addTimer(nextSecond) do (p: pointer):
    asyncCheck node.onSecond(nextSecond)

proc run*(node: BeaconNode) =
  waitFor node.network.subscribe(topicBeaconBlocks) do (blck: BeaconBlock):
    onBeaconBlock(node, blck)

  waitFor node.network.subscribe(topicAttestations) do (attestation: Attestation):
    # Avoid double-counting attestation-topic attestations on shared codepath
    # when they're reflected through beacon blocks
    beacon_attestations_received.inc()

    node.onAttestation(attestation)

  let
    t = node.beaconClock.now()
    startSlot = if t > BeaconTime(0): t.toSlot.slot + 1
                else: GENESIS_SLOT + 1
    fromNow = saturate(node.beaconClock.fromNow(startSlot))

  info "Scheduling first slot action",
    beaconTime = shortLog(node.beaconClock.now()),
    nextSlot = shortLog(startSlot),
    fromNow = shortLog(fromNow),
    cat = "scheduling"

  addTimer(fromNow) do (p: pointer):
    asyncCheck node.onSlotStart(startSlot - 1, startSlot)

  let second = Moment.now() + chronos.seconds(1)
  addTimer(second) do (p: pointer):
    asyncCheck node.onSecond(second)

  runForever()

var gPidFile: string
proc createPidFile(filename: string) =
  createDir splitFile(filename).dir
  writeFile filename, $os.getCurrentProcessId()
  gPidFile = filename
  addQuitProc proc {.noconv.} = removeFile gPidFile

proc start(node: BeaconNode, headState: BeaconState) =
  # TODO: while it's nice to cheat by waiting for connections here, we
  #       actually need to make this part of normal application flow -
  #       losing all connections might happen at any time and we should be
  #       prepared to handle it.
  waitFor node.connectToNetwork()

  info "Starting beacon node",
    version = fullVersionStr,
    timeSinceFinalization =
      int64(node.blockPool.finalizedHead.slot.toBeaconTime()) -
      int64(node.beaconClock.now()),
    stateSlot = shortLog(headState.slot),
    SLOTS_PER_EPOCH,
    SECONDS_PER_SLOT,
    SPEC_VERSION,
    dataDir = node.config.dataDir.string,
    cat = "init",
    pcs = "start_beacon_node"

  node.addLocalValidators(headState)
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
  import terminal, prompt

  proc providePromptCompletions*(line: seq[Rune], cursorPos: int): seq[string] =
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

  proc slotOrZero(time: BeaconTime): Slot =
    let exSlot = time.toSlot
    if exSlot.afterGenesis: exSlot.slot
    else: Slot(0)

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
          $(sync_protocol.libp2p_peers.value.int)

        of "last_finalized_epoch":
          var head = node.blockPool.finalizedHead
          # TODO: Should we display a state root instead?
          $(head.slot.epoch) & " (" & shortLog(head.blck.root) & ")"

        of "epoch":
          $node.beaconClock.now.slotOrZero.epoch

        of "epoch_slot":
          $(node.beaconClock.now.slotOrZero mod SLOTS_PER_EPOCH)

        of "slots_per_epoch":
          $SLOTS_PER_EPOCH

        of "slot":
          $node.beaconClock.now.slotOrZero

        of "slot_trailing_digits":
          var slotStr = $node.beaconClock.now.slotOrZero
          if slotStr.len > 3: slotStr = slotStr[^3..^1]
          slotStr

        of "attached_validators_balance":
          var balance = uint64(0)
          for _, validator in node.attachedValidators.validators:
            balance += node.stateCache.data.data.balances[validator.idx]
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
          proc (logLevel: LogLevel, msg: LogOutputStr) {.gcsafe.} =
            # p.hidePrompt
            erase statusBar
            # p.writeLine msg
            stdout.write msg
            render statusBar
            # p.showPrompt

      proc statusBarUpdatesPollingLoop() {.async.} =
        while true:
          update statusBar
          await sleepAsync(1000)

      traceAsyncErrors statusBarUpdatesPollingLoop()

      # var t: Thread[ptr Prompt]
      # createThread(t, processPromptCommands, addr p)

template bytes(memFile: MemFile): untyped =
  let f = memFile
  makeOpenArray(f.mem, byte, f.size)

when isMainModule:
  randomize()

  let config = BeaconNodeConf.load(
    version = clientId,
    copyrightBanner = clientId & "\p" & copyrights)

  when compiles(defaultChroniclesStream.output.writer):
    defaultChroniclesStream.output.writer =
      proc (logLevel: LogLevel, msg: LogOutputStr) {.gcsafe.} =
        stdout.write(msg)

  if config.logLevel != LogLevel.NONE:
    setLogLevel(config.logLevel)

  ## Ctrl+C handling
  proc controlCHandler() {.noconv.} =
    when defined(windows):
      # workaround for https://github.com/nim-lang/Nim/issues/4057
      setupForeignThreadGc()
    debug "Shutting down after having received SIGINT"
    quit(QuitFailure)
  setControlCHook(controlCHandler)

  case config.cmd
  of createTestnet:
    var deposits: seq[Deposit]
    for i in config.firstValidator.int ..< config.totalValidators.int:
      let depositFile = config.validatorsDir /
                        validatorFileBaseName(i) & ".deposit.json"
      try:
        deposits.add Json.loadFile(depositFile, Deposit)
      except SerializationError as err:
        stderr.write "Error while loading a deposit file:\n"
        stderr.write err.formatMsg(depositFile), "\n"
        stderr.write "Please regenerate the deposit files by running makeDeposits again\n"
        quit 1

    let
      startTime = uint64(times.toUnix(times.getTime()) + config.genesisOffset)
      outGenesis = config.outputGenesis.string
      eth1Hash = if config.depositWeb3Url.len == 0: eth1BlockHash
                 else: waitFor getLatestEth1BlockHash(config.depositWeb3Url)
    var
      initialState = initialize_beacon_state_from_eth1(
        eth1Hash, startTime, deposits, {skipValidation})

    # https://github.com/ethereum/eth2.0-pm/tree/6e41fcf383ebeb5125938850d8e9b4e9888389b4/interop/mocked_start#create-genesis-state
    initialState.genesis_time = startTime

    doAssert initialState.validators.len > 0

    let outGenesisExt = splitFile(outGenesis).ext
    if cmpIgnoreCase(outGenesisExt, ".json") == 0:
      Json.saveFile(outGenesis, initialState, pretty = true)
      echo "Wrote ", outGenesis

    let outSszGenesis = outGenesis.changeFileExt "ssz"
    SSZ.saveFile(outSszGenesis, initialState)
    echo "Wrote ", outSszGenesis

    var
      bootstrapAddress = getPersistenBootstrapAddr(
        config, parseIpAddress(config.bootstrapAddress), Port config.bootstrapPort)

    let bootstrapFile = config.outputBootstrapFile.string
    if bootstrapFile.len > 0:
      let bootstrapAddrLine = $bootstrapAddress
      writeFile(bootstrapFile, bootstrapAddrLine)
      echo "Wrote ", bootstrapFile

  of importValidator:
    template reportFailureFor(keyExpr) =
      error "Failed to import validator key", key = keyExpr
      programResult = 1

    if config.keyFiles.len == 0:
      stderr.write "Please specify at least one keyfile to import."
      quit 1

    for keyFile in config.keyFiles:
      try:
        saveValidatorKey(keyFile.string.extractFilename,
                         readFile(keyFile.string), config)
      except:
        reportFailureFor keyFile.string

  of noCommand:
    createPidFile(config.dataDir.string / "beacon_node.pid")

    var node = waitFor BeaconNode.init(config)
    when hasPrompt: initPrompt(node)

    # TODO slightly ugly to rely on node.stateCache state here..
    if node.nickname != "":
      dynamicLogScope(node = node.nickname): node.start(node.stateCache.data.data)
    else:
      node.start(node.stateCache.data.data)

  of makeDeposits:
    createDir(config.depositsDir)

    let
      quickstartDeposits = generateDeposits(
        config.totalQuickstartDeposits, config.depositsDir, false)

      randomDeposits = generateDeposits(
        config.totalRandomDeposits, config.depositsDir, true,
        firstIdx = config.totalQuickstartDeposits)

    if config.depositWeb3Url.len > 0 and config.depositContractAddress.len > 0:
      waitFor sendDeposits(
        quickstartDeposits & randomDeposits,
        config.depositWeb3Url,
        config.depositContractAddress,
        config.depositPrivateKey)

  of query:
    case config.queryCmd
    of QueryCmd.nimQuery:
      # TODO: This will handle a simple subset of Nim using
      #       dot syntax and `[]` indexing.
      echo "nim query: ", config.nimQueryExpression

    of QueryCmd.get:
      let pathFragments = config.getQueryPath.split('/', maxsplit = 1)
      var navigator: DynamicSszNavigator

      case pathFragments[0]
      of "genesis_state":
        var genesisMapFile = memfiles.open(config.dataDir/genesisFile)
        navigator = DynamicSszNavigator.init(genesisMapFile.bytes, BeaconState)
      else:
        stderr.write config.getQueryPath & " is not a valid path"
        quit 1

      echo navigator.navigatePath(pathFragments[1 .. ^1]).toJson

