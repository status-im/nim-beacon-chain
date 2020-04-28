# beacon_chain
# Copyright (c) 2018-2020 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  # Standard library
  os, tables, random, strutils, times,

  # Nimble packages
  stew/[objects, bitseqs, byteutils], stew/shims/macros,
  chronos, confutils, metrics, json_rpc/[rpcserver, jsonmarshal],
  chronicles, chronicles/helpers as chroniclesHelpers,
  json_serialization/std/[options, sets, net], serialization/errors,
  eth/db/kvstore, eth/db/kvstore_sqlite3,
  eth/p2p/enode, eth/[keys, async_utils], eth/p2p/discoveryv5/[protocol, enr],

  # Local modules
  spec/[datatypes, digest, crypto, beaconstate, helpers, validator, network,
    state_transition_block], spec/presets/custom,
  conf, time, beacon_chain_db, validator_pool, extras,
  attestation_pool, block_pool, eth2_network, eth2_discovery,
  beacon_node_types, mainchain_monitor, version, ssz, ssz/dynamic_navigator,
  sync_protocol, request_manager, validator_keygen, interop, statusbar,
  attestation_aggregation, sync_manager

const
  genesisFile = "genesis.ssz"
  hasPrompt = not defined(withoutPrompt)
  maxEmptySlotCount = uint64(10*60) div SECONDS_PER_SLOT

type
  KeyPair = eth2_network.KeyPair
  RpcServer = RpcHttpServer

template init(T: type RpcHttpServer, ip: IpAddress, port: Port): T =
  newRpcHttpServer([initTAddress(ip, port)])

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

type
  BeaconNode = ref object
    nickname: string
    network: Eth2Node
    netKeys: KeyPair
    requestManager: RequestManager
    db: BeaconChainDB
    config: BeaconNodeConf
    attachedValidators: ValidatorPool
    blockPool: BlockPool
    attestationPool: AttestationPool
    mainchainMonitor: MainchainMonitor
    beaconClock: BeaconClock
    rpcServer: RpcServer
    forkDigest: ForkDigest
    topicBeaconBlocks: string
    topicAggregateAndProofs: string
    syncLoop: Future[void]

proc onBeaconBlock*(node: BeaconNode, signedBlock: SignedBeaconBlock) {.gcsafe.}
proc updateHead(node: BeaconNode): BlockRef

proc saveValidatorKey(keyName, key: string, conf: BeaconNodeConf) =
  let validatorsDir = conf.localValidatorsDir
  let outputFile = validatorsDir / keyName
  createDir validatorsDir
  writeFile(outputFile, key)
  info "Imported validator key", file = outputFile

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
  else:
    try:
      snapshotContents = readFile(genesisPath)
    except CatchableError as err:
      error "Failed to read genesis file", err = err.msg
      quit 1

  try:
    result = SSZ.decode(snapshotContents, BeaconStateRef)
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

proc enrForkIdFromState(state: BeaconState): ENRForkID =
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
      # Didn't work, try creating a genesis state using main chain monitor
      # TODO Could move this to a separate "GenesisMonitor" process or task
      #      that would do only this - see
      if conf.web3Url.len > 0 and conf.depositContractAddress.len > 0:
        mainchainMonitor = MainchainMonitor.init(
          web3Provider(conf.web3Url),
          conf.depositContractAddress,
          Eth2Digest())
        mainchainMonitor.start()
      else:
        error "No initial state, need genesis state or deposit contract address"
        quit 1

      genesisState = await mainchainMonitor.getGenesis()

    # This is needed to prove the not nil property from here on
    if genesisState == nil:
      doAssert false
    else:
      if genesisState.slot != GENESIS_SLOT:
        # TODO how to get a block from a non-genesis state?
        error "Starting from non-genesis state not supported",
          stateSlot = genesisState.slot,
          stateRoot = hash_tree_root(genesisState)
        quit 1

      let tailBlock = get_initial_beacon_block(genesisState[])

      try:
        BlockPool.preInit(db, genesisState, tailBlock)
        doAssert BlockPool.isInitialized(db), "preInit should have initialized db"
      except CatchableError as e:
        error "Failed to initialize database", err = e.msg
        quit 1

  # TODO check that genesis given on command line (if any) matches database
  let
    blockPool = BlockPool.init(db)

  if mainchainMonitor.isNil and
     conf.web3Url.len > 0 and
     conf.depositContractAddress.len > 0:
    mainchainMonitor = MainchainMonitor.init(
      web3Provider(conf.web3Url),
      conf.depositContractAddress,
      blockPool.headState.data.data.eth1_data.block_hash)
    # TODO if we don't have any validators attached, we don't need a mainchain
    #      monitor
    mainchainMonitor.start()

  let rpcServer = if conf.rpcEnabled:
    RpcServer.init(conf.rpcAddress, conf.rpcPort)
  else:
    nil

  let
    enrForkId = enrForkIdFromState(blockPool.headState.data.data[])
    topicBeaconBlocks = getBeaconBlocksTopic(enrForkId.forkDigest)
    topicAggregateAndProofs = getAggregateAndProofsTopic(enrForkId.forkDigest)
    network = await createEth2Node(conf, enrForkId)

  var res = BeaconNode(
    nickname: nickname,
    network: network,
    netKeys: netKeys,
    requestManager: RequestManager.init(network),
    db: db,
    config: conf,
    attachedValidators: ValidatorPool.init(),
    blockPool: blockPool,
    attestationPool: AttestationPool.init(blockPool),
    mainchainMonitor: mainchainMonitor,
    beaconClock: BeaconClock.init(blockPool.headState.data.data[]),
    rpcServer: rpcServer,
    forkDigest: enrForkId.forkDigest,
    topicBeaconBlocks: topicBeaconBlocks,
    topicAggregateAndProofs: topicAggregateAndProofs,
  )

  # TODO sync is called when a remote peer is connected - is that the right
  #      time to do so?
  network.initBeaconSync(blockPool, enrForkId.forkDigest,
    proc(signedBlock: SignedBeaconBlock) =
      if signedBlock.message.slot mod SLOTS_PER_EPOCH == 0:
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

proc connectToNetwork(node: BeaconNode) {.async.} =
  await node.network.connectToNetwork()

  let addressFile = node.config.dataDir / "beacon_node.address"
  writeFile(addressFile, node.network.announcedENR.toURI)

template findIt(s: openarray, predicate: untyped): int =
  var res = -1
  for i, it {.inject.} in s:
    if predicate:
      res = i
      break
  res

proc addLocalValidator(node: BeaconNode,
                       state: BeaconState,
                       privKey: ValidatorPrivKey) =
  let pubKey = privKey.toPubKey()

  let idx = state.validators.findIt(it.pubKey == pubKey)
  if idx == -1:
    # We allow adding a validator even if its key is not in the state registry:
    # it might be that the deposit for this validator has not yet been processed
    warn "Validator not in registry (yet?)", pubKey

  node.attachedValidators.addLocalValidator(pubKey, privKey)

proc addLocalValidators(node: BeaconNode, state: BeaconState) =
  for validatorKey in node.config.validatorKeys:
    node.addLocalValidator state, validatorKey

  info "Local validators attached ", count = node.attachedValidators.count

func getAttachedValidator(node: BeaconNode,
                          state: BeaconState,
                          idx: ValidatorIndex): AttachedValidator =
  let validatorKey = state.validators[idx].pubkey
  node.attachedValidators.getValidator(validatorKey)

proc isSynced(node: BeaconNode, head: BlockRef): bool =
  ## TODO This function is here as a placeholder for some better heurestics to
  ##      determine if we're in sync and should be producing blocks and
  ##      attestations. Generally, the problem is that slot time keeps advancing
  ##      even when there are no blocks being produced, so there's no way to
  ##      distinguish validators geniunely going missing from the node not being
  ##      well connected (during a network split or an internet outage for
  ##      example). It would generally be correct to simply keep running as if
  ##      we were the only legit node left alive, but then we run into issues:
  ##      with enough many empty slots, the validator pool is emptied leading
  ##      to empty committees and lots of empty slot processing that will be
  ##      thrown away as soon as we're synced again.

  let
    # The slot we should be at, according to the clock
    beaconTime = node.beaconClock.now()
    wallSlot = beaconTime.toSlot()

  # TODO if everyone follows this logic, the network will not recover from a
  #      halt: nobody will be producing blocks because everone expects someone
  #      else to do it
  if wallSlot.afterGenesis and head.slot + maxEmptySlotCount < wallSlot.slot:
    false
  else:
    true

proc updateHead(node: BeaconNode): BlockRef =
  # Check pending attestations - maybe we found some blocks for them
  node.attestationPool.resolve()

  # Grab the new head according to our latest attestation data
  let newHead = node.attestationPool.selectHead()

  # Store the new head in the block pool - this may cause epochs to be
  # justified and finalized
  node.blockPool.updateHead(newHead)
  beacon_head_root.set newHead.root.toGaugeValue

  newHead

proc sendAttestation(node: BeaconNode,
                     fork: Fork,
                     genesis_validators_root: Eth2Digest,
                     validator: AttachedValidator,
                     attestationData: AttestationData,
                     committeeLen: int,
                     indexInCommittee: int) {.async.} =
  logScope: pcs = "send_attestation"

  let validatorSignature = await validator.signAttestation(attestationData,
    fork, genesis_validators_root)

  var aggregationBits = CommitteeValidatorsBits.init(committeeLen)
  aggregationBits.setBit indexInCommittee

  var attestation = Attestation(
    data: attestationData,
    signature: validatorSignature,
    aggregation_bits: aggregationBits
  )

  # https://github.com/ethereum/eth2.0-specs/blob/v0.11.1/specs/phase0/validator.md#broadcast-attestation
  node.network.broadcast(
    getAttestationTopic(node.forkDigest, attestationData.index), attestation)

  if node.config.dumpEnabled:
    SSZ.saveFile(
      node.config.dumpDir / "att-" & $attestationData.slot & "-" &
      $attestationData.index & "-" & validator.pubKey.shortLog &
      ".ssz", attestation)

  info "Attestation sent",
    attestation = shortLog(attestation),
    validator = shortLog(validator),
    indexInCommittee = indexInCommittee,
    cat = "consensus"

  beacon_attestations_sent.inc()

proc proposeBlock(node: BeaconNode,
                  validator: AttachedValidator,
                  head: BlockRef,
                  slot: Slot): Future[BlockRef] {.async.} =
  logScope: pcs = "block_proposal"

  if head.slot >= slot:
    # We should normally not have a head newer than the slot we're proposing for
    # but this can happen if block proposal is delayed
    warn "Skipping proposal, have newer head already",
      headSlot = shortLog(head.slot),
      headBlockRoot = shortLog(head.root),
      slot = shortLog(slot),
      cat = "fastforward"
    return head

  # Advance state to the slot that we're proposing for - this is the equivalent
  # of running `process_slots` up to the slot of the new block.
  let (nroot, nblck) = node.blockPool.withState(
      node.blockPool.tmpState, head.atSlot(slot)):
    let (eth1data, deposits) =
      if node.mainchainMonitor.isNil:
        (get_eth1data_stub(state.eth1_deposit_index, slot.compute_epoch_at_slot()),
         newSeq[Deposit]())
      else:
        node.mainchainMonitor.getBlockProposalData(state[])

    let message = makeBeaconBlock(
      state[],
      head.root,
      validator.genRandaoReveal(state.fork, state.genesis_validators_root, slot),
      eth1data,
      Eth2Digest(),
      node.attestationPool.getAttestationsForBlock(state[]),
      deposits)

    if not message.isSome():
      return head # already logged elsewhere!
    var
      newBlock = SignedBeaconBlock(
        message: message.get()
      )

    let blockRoot = hash_tree_root(newBlock.message)

    # Careful, state no longer valid after here because of the await..
    newBlock.signature = await validator.signBlockProposal(
      state.fork, state.genesis_validators_root, slot, blockRoot)

    (blockRoot, newBlock)

  let newBlockRef = node.blockPool.add(nroot, nblck)
  if newBlockRef == nil:
    warn "Unable to add proposed block to block pool",
      newBlock = shortLog(newBlock.message),
      blockRoot = shortLog(blockRoot),
      cat = "bug"
    return head

  info "Block proposed",
    blck = shortLog(newBlock.message),
    blockRoot = shortLog(newBlockRef.root),
    validator = shortLog(validator),
    cat = "consensus"

  if node.config.dumpEnabled:
    SSZ.saveFile(
      node.config.dumpDir / "block-" & $newBlock.message.slot & "-" &
      shortLog(newBlockRef.root) & ".ssz", newBlock)
    node.blockPool.withState(
        node.blockPool.tmpState, newBlockRef.atSlot(newBlockRef.slot)):
      SSZ.saveFile(
        node.config.dumpDir / "state-" & $state.slot & "-" &
        shortLog(newBlockRef.root) & "-"  & shortLog(root()) & ".ssz",
        state)

  node.network.broadcast(node.topicBeaconBlocks, newBlock)

  beacon_blocks_proposed.inc()

  return newBlockRef

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
      (attestation.data.slot - head.blck.slot) > maxEmptySlotCount:
    warn "Ignoring attestation, head block too old (out of sync?)",
      attestationSlot = attestation.data.slot, headSlot = head.blck.slot
    return

  node.attestationPool.add(attestation)

proc storeBlock(node: BeaconNode, signedBlock: SignedBeaconBlock): bool =
  let blockRoot = hash_tree_root(signedBlock.message)
  debug "Block received",
    signedBlock = shortLog(signedBlock.message),
    blockRoot = shortLog(blockRoot),
    cat = "block_listener",
    pcs = "receive_block"

  beacon_blocks_received.inc()
  if node.blockPool.add(blockRoot, signedBlock).isNil:
    return false

  # The block we received contains attestations, and we might not yet know about
  # all of them. Let's add them to the attestation pool - in case they block
  # is not yet resolved, neither will the attestations be!
  # But please note that we only care about recent attestations.
  # TODO shouldn't add attestations if the block turns out to be invalid..
  let currentSlot = node.beaconClock.now.toSlot
  if currentSlot.afterGenesis and
    signedBlock.message.slot.epoch + 1 >= currentSlot.slot.epoch:
    for attestation in signedBlock.message.body.attestations:
      node.onAttestation(attestation)
  return true

proc onBeaconBlock(node: BeaconNode, signedBlock: SignedBeaconBlock) =
  # We received a block but don't know much about it yet - in particular, we
  # don't know if it's part of the chain we're currently building.
  discard node.storeBlock(signedBlock)

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
  node.blockPool.withState(node.blockPool.tmpState, attestationHead):
    var cache = get_empty_per_epoch_cache()
    let committees_per_slot = get_committee_count_at_slot(state[], slot)

    for committee_index in 0'u64..<committees_per_slot:
      let committee = get_beacon_committee(
        state[], slot, committee_index.CommitteeIndex, cache)

      for index_in_committee, validatorIdx in committee:
        let validator = node.getAttachedValidator(state[], validatorIdx)
        if validator != nil:
          let ad = makeAttestationData(state[], slot, committee_index, blck.root)
          attestations.add((ad, committee.len, index_in_committee, validator))

    for a in attestations:
      traceAsyncErrors sendAttestation(
        node, state.fork, state.genesis_validators_root, a.validator, a.data,
        a.committeeLen, a.indexInCommittee)

proc handleProposal(node: BeaconNode, head: BlockRef, slot: Slot):
    Future[BlockRef] {.async.} =
  ## Perform the proposal for the given slot, iff we have a validator attached
  ## that is supposed to do so, given the shuffling in head

  # TODO here we advance the state to the new slot, but later we'll be
  #      proposing for it - basically, we're selecting proposer based on an
  #      empty slot

  let proposerKey = node.blockPool.getProposer(head, slot)
  if proposerKey.isNone():
    return head

  let validator = node.attachedValidators.getValidator(proposerKey.get())

  if validator != nil:
    return await proposeBlock(node, validator, head, slot)

  debug "Expecting block proposal",
    headRoot = shortLog(head.root),
    slot = shortLog(slot),
    proposer = shortLog(proposerKey.get()),
    cat = "consensus",
    pcs = "wait_for_proposal"

  return head

proc verifyFinalization(node: BeaconNode, slot: Slot) =
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
    doAssert finalizedEpoch + 2 == epoch

proc broadcastAggregatedAttestations(
    node: BeaconNode, aggregationHead: BlockRef, aggregationSlot: Slot,
    trailing_distance: uint64) =
  # The index is via a
  # locally attested validator. Unlike in handleAttestations(...) there's a
  # single one at most per slot (because that's how aggregation attestation
  # works), so the machinery that has to handle looping across, basically a
  # set of locally attached validators is in principle not necessary, but a
  # way to organize this. Then the private key for that validator should be
  # the corresponding one -- whatver they are, they match.

  let bs = BlockSlot(blck: aggregationHead, slot: aggregationSlot)
  node.blockPool.withState(node.blockPool.tmpState, bs):
    let
      committees_per_slot = get_committee_count_at_slot(state[], aggregationSlot)
    var cache = get_empty_per_epoch_cache()
    for committee_index in 0'u64..<committees_per_slot:
      let committee = get_beacon_committee(
        state[], aggregationSlot, committee_index.CommitteeIndex, cache)

      for index_in_committee, validatorIdx in committee:
        let validator = node.getAttachedValidator(state[], validatorIdx)
        if validator != nil:
          # This is slightly strange/inverted control flow, since really it's
          # going to happen once per slot, but this is the best way to get at
          # the validator index and private key pair. TODO verify it only has
          # one isSome() with test.
          let aggregateAndProof =
            aggregate_attestations(node.attestationPool, state[],
              committee_index.CommitteeIndex,
              # TODO https://github.com/status-im/nim-beacon-chain/issues/545
              # this assumes in-process private keys
              validator.privKey,
              trailing_distance)

          # Don't broadcast when, e.g., this node isn't an aggregator
          if aggregateAndProof.isSome:
            var signedAP = SignedAggregateAndProof(
              message: aggregateAndProof.get,
              # TODO Make the signing async here
              signature: validator.signAggregateAndProof(
                aggregateAndProof.get, state.fork,
                state.genesis_validators_root))
            node.network.broadcast(node.topicAggregateAndProofs, signedAP)

proc handleValidatorDuties(
    node: BeaconNode, head: BlockRef, lastSlot, slot: Slot): Future[BlockRef] {.async.} =
  ## Perform validator duties - create blocks, vote and aggreagte existing votes
  if node.attachedValidators.count == 0:
    # Nothing to do because we have no validator attached
    return head

  if not node.isSynced(head):
    notice "Node out of sync, skipping validator duties",
      slot, headSlot = head.slot
    return head

  var curSlot = lastSlot + 1
  var head = head

  # Start by checking if there's work we should have done in the past that we
  # can still meaningfully do
  while curSlot < slot:
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
  # send out attestations at the slot thirds-point, so we go back to the clock
  # to see how much time we need to wait.
  # TODO the beacon clock might jump here also. It's probably easier to complete
  #      the work for the whole slot using a monotonic clock instead, then deal
  #      with any clock discrepancies once only, at the start of slot timer
  #      processing..

  # https://github.com/ethereum/eth2.0-specs/blob/v0.11.1/specs/phase0/validator.md#attesting
  # A validator should create and broadcast the attestation to the associated
  # attestation subnet when either (a) the validator has received a valid
  # block from the expected block proposer for the assigned slot or
  # (b) one-third of the slot has transpired (`SECONDS_PER_SLOT / 3` seconds
  # after the start of slot) -- whichever comes first.
  template sleepToSlotOffset(extra: chronos.Duration, msg: static string) =
    let
      fromNow = node.beaconClock.fromNow(slot.toBeaconTime(extra))

    if fromNow.inFuture:
      trace msg,
        slot = shortLog(slot),
        fromNow = shortLog(fromNow.offset),
        cat = "scheduling"

      await sleepAsync(fromNow.offset)

      # Time passed - we might need to select a new head in that case
      head = node.updateHead()

  sleepToSlotOffset(
    seconds(int64(SECONDS_PER_SLOT)) div 3, "Waiting to send attestations")

  handleAttestations(node, head, slot)

  # https://github.com/ethereum/eth2.0-specs/blob/v0.11.1/specs/phase0/validator.md#broadcast-aggregate
  # If the validator is selected to aggregate (is_aggregator), then they
  # broadcast their best aggregate as a SignedAggregateAndProof to the global
  # aggregate channel (beacon_aggregate_and_proof) two-thirds of the way
  # through the slot-that is, SECONDS_PER_SLOT * 2 / 3 seconds after the start
  # of slot.
  if slot > 2:
    sleepToSlotOffset(
      seconds(int64(SECONDS_PER_SLOT * 2) div 3),
      "Waiting to aggregate attestations")

    const TRAILING_DISTANCE = 1
    let
      aggregationSlot = slot - TRAILING_DISTANCE
      aggregationHead = getAncestorAt(head, aggregationSlot)

    broadcastAggregatedAttestations(
      node, aggregationHead, aggregationSlot, TRAILING_DISTANCE)

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
  if node.config.stopAtEpoch > 0'u64 and
      scheduledSlot.compute_epoch_at_slot() >= node.config.stopAtEpoch:
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
  head = await node.handleValidatorDuties(head, lastSlot, slot)

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

  addTimer(nextSlotStart) do (p: pointer):
    asyncCheck node.onSlotStart(slot, nextSlot)

proc handleMissingBlocks(node: BeaconNode) =
  let missingBlocks = node.blockPool.checkMissing()
  if missingBlocks.len > 0:
    var left = missingBlocks.len

    info "Requesting detected missing blocks", missingBlocks
    node.requestManager.fetchAncestorBlocks(missingBlocks) do (b: SignedBeaconBlock):
      onBeaconBlock(node, b)

      # TODO instead of waiting for a full second to try the next missing block
      #      fetching, we'll do it here again in case we get all blocks we asked
      #      for (there might be new parents to fetch). of course, this is not
      #      good because the onSecond fetching also kicks in regardless but
      #      whatever - this is just a quick fix for making the testnet easier
      #      work with while the sync problem is dealt with more systematically
      # dec left
      # if left == 0:
      #   discard setTimer(Moment.now()) do (p: pointer):
      #     handleMissingBlocks(node)

proc onSecond(node: BeaconNode, moment: Moment) {.async.} =
  node.handleMissingBlocks()

  let nextSecond = max(Moment.now(), moment + chronos.seconds(1))
  discard setTimer(nextSecond) do (p: pointer):
    asyncCheck node.onSecond(nextSecond)

proc getHeadSlot*(peer: Peer): Slot {.inline.} =
  ## Returns head slot for specific peer ``peer``.
  result = peer.state(BeaconSync).statusMsg.headSlot

proc updateStatus*(peer: Peer): Future[bool] {.async.} =
  ## Request `status` of remote peer ``peer``.
  let
    nstate = peer.networkState(BeaconSync)
    finalizedHead = nstate.blockPool.finalizedHead
    headBlock = nstate.blockPool.head.blck

    ourStatus = StatusMsg(
      forkDigest: nstate.forkDigest,
      finalizedRoot: finalizedHead.blck.root,
      finalizedEpoch: finalizedHead.slot.compute_epoch_at_slot(),
      headRoot: headBlock.root,
      headSlot: headBlock.slot
    )

  let theirStatus = await peer.status(ourStatus,
                                      timeout = chronos.seconds(60))
  if theirStatus.isSome():
    peer.state(BeaconSync).statusMsg = theirStatus.get()
    result = true

proc runSyncLoop(node: BeaconNode) {.async.} =
  proc getLocalHeadSlot(): Slot =
    result = node.blockPool.head.blck.slot

  proc getLocalWallSlot(): Slot {.gcsafe.} =
    let epoch = node.beaconClock.now().toSlot().slot.compute_epoch_at_slot() + 1'u64
    result = epoch.compute_start_slot_at_epoch()

  proc updateLocalBlocks(list: openarray[SignedBeaconBlock]): bool =
    debug "Forward sync imported blocks", count = len(list),
          local_head_slot = getLocalHeadSlot()
    for blk in list:
      if not(node.storeBlock(blk)):
        return false
    discard node.updateHead()
    info "Forward sync blocks got imported sucessfully", count = len(list),
         local_head_slot = getLocalHeadSlot()
    result = true

  proc scoreCheck(peer: Peer): bool =
    if peer.score < PeerScoreLimit:
      try:
        debug "Peer score is too low, removing it from PeerPool", peer = peer,
              peer_score = peer.score, score_limit = PeerScoreLimit
      except:
        discard
      result = false
    else:
      result = true

  node.network.peerPool.setScoreCheck(scoreCheck)

  var syncman = newSyncManager[Peer, PeerID](
    node.network.peerPool, getLocalHeadSlot, getLocalWallSlot,
    updateLocalBlocks
  )

  await syncman.sync()

# TODO: Should we move these to other modules?
# This would require moving around other type definitions
proc installValidatorApiHandlers(rpcServer: RpcServer, node: BeaconNode) =
  discard

func slotOrZero(time: BeaconTime): Slot =
  let exSlot = time.toSlot
  if exSlot.afterGenesis: exSlot.slot
  else: Slot(0)

proc currentSlot(node: BeaconNode): Slot =
  node.beaconClock.now.slotOrZero

proc connectedPeersCount(node: BeaconNode): int =
  libp2p_peers.value.int

proc fromJson(n: JsonNode; argName: string; result: var Slot) =
  var i: int
  fromJson(n, argName, i)
  result = Slot(i)

proc installBeaconApiHandlers(rpcServer: RpcServer, node: BeaconNode) =
  rpcServer.rpc("getBeaconHead") do () -> Slot:
    return node.currentSlot

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
      var tmpState = emptyStateData()
      node.blockPool.withState(tmpState, blk):
        return jsonResult(state)
    else:
      let state = node.db.getState(root.get)
      if state.isSome:
        return jsonResult(state.get)
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

proc installRpcHandlers(rpcServer: RpcServer, node: BeaconNode) =
  rpcServer.installValidatorApiHandlers(node)
  rpcServer.installBeaconApiHandlers(node)
  rpcServer.installDebugApiHandlers(node)

proc run*(node: BeaconNode) =
  if node.rpcServer != nil:
    node.rpcServer.installRpcHandlers(node)
    node.rpcServer.start()

  waitFor node.network.subscribe(node.topicBeaconBlocks) do (signedBlock: SignedBeaconBlock):
    onBeaconBlock(node, signedBlock)
  do (signedBlock: SignedBeaconBlock) -> bool:
    let (afterGenesis, slot) = node.beaconClock.now.toSlot()
    if not afterGenesis:
      return false
    node.blockPool.isValidBeaconBlock(signedBlock, slot, {})

  proc attestationHandler(attestation: Attestation) =
    # Avoid double-counting attestation-topic attestations on shared codepath
    # when they're reflected through beacon blocks
    beacon_attestations_received.inc()
    node.onAttestation(attestation)

  var attestationSubscriptions: seq[Future[void]] = @[]
  for it in 0'u64 ..< ATTESTATION_SUBNET_COUNT.uint64:
    closureScope:
      let ci = it
      attestationSubscriptions.add(node.network.subscribe(
        getAttestationTopic(node.forkDigest, ci), attestationHandler,
        proc(attestation: Attestation): bool =
          # https://github.com/ethereum/eth2.0-specs/blob/v0.11.1/specs/phase0/p2p-interface.md#attestation-subnets
          let (afterGenesis, slot) = node.beaconClock.now().toSlot()
          if not afterGenesis:
            return false
          node.attestationPool.isValidAttestation(attestation, slot, ci, {})))
  waitFor allFutures(attestationSubscriptions)

  let
    t = node.beaconClock.now().toSlot()
    curSlot = if t.afterGenesis: t.slot
              else: GENESIS_SLOT
    nextSlot = curSlot + 1 # No earlier than GENESIS_SLOT + 1
    fromNow = saturate(node.beaconClock.fromNow(nextSlot))

  info "Scheduling first slot action",
    beaconTime = shortLog(node.beaconClock.now()),
    nextSlot = shortLog(nextSlot),
    fromNow = shortLog(fromNow),
    cat = "scheduling"

  addTimer(fromNow) do (p: pointer):
    asyncCheck node.onSlotStart(curSlot, nextSlot)

  let second = Moment.now() + chronos.seconds(1)
  discard setTimer(second) do (p: pointer):
    asyncCheck node.onSecond(second)

  node.syncLoop = runSyncLoop(node)

  runForever()

var gPidFile: string
proc createPidFile(filename: string) =
  createDir splitFile(filename).dir
  writeFile filename, $os.getCurrentProcessId()
  gPidFile = filename
  addQuitProc proc {.noconv.} = removeFile gPidFile

proc start(node: BeaconNode) =
  # TODO: while it's nice to cheat by waiting for connections here, we
  #       actually need to make this part of normal application flow -
  #       losing all connections might happen at any time and we should be
  #       prepared to handle it.
  waitFor node.connectToNetwork()

  let
    head = node.blockPool.head
    finalizedHead = node.blockPool.finalizedHead

  info "Starting beacon node",
    version = fullVersionStr,
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

  let
    bs = BlockSlot(blck: head.blck, slot: head.blck.slot)

  node.blockPool.withState(node.blockPool.tmpState, bs):
    node.addLocalValidators(state[])

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
          $node.currentSlot

        of "slot_trailing_digits":
          var slotStr = $node.beaconClock.now.slotOrZero
          if slotStr.len > 3: slotStr = slotStr[^3..^1]
          slotStr

        of "attached_validators_balance":
          var balance = uint64(0)
          # TODO slow linear scan!
          for idx, b in node.blockPool.headState.data.data.balances:
            if node.getAttachedValidator(
                node.blockPool.headState.data.data[], ValidatorIndex(idx)) != nil:
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

programMain:
  let
    banner = clientId & "\p" & copyrights & "\p\p" & nimBanner
    config = BeaconNodeConf.load(version = banner, copyrightBanner = banner)

  when compiles(defaultChroniclesStream.output.writer):
    defaultChroniclesStream.output.writer =
      proc (logLevel: LogLevel, msg: LogOutputStr) {.gcsafe, raises: [Defect].} =
        try:
          stdout.write(msg)
        except IOError as err:
          logLoggingFailure(cstring(msg), err)

  randomize()

  try:
    let directives = config.logLevel.split(";")
    try:
      setLogLevel(parseEnum[LogLevel](directives[0]))
    except ValueError:
      raise (ref ValueError)(msg: "Please specify one of TRACE, DEBUG, INFO, NOTICE, WARN, ERROR or FATAL")

    if directives.len > 1:
      for topicName, settings in parseTopicDirectives(directives[1..^1]):
        if not setTopicState(topicName, settings.state, settings.logLevel):
          warn "Unrecognized logging topic", topic = topicName
  except ValueError as err:
    stderr.write "Invalid value for --log-level. " & err.msg
    quit 1

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
      eth1Hash = if config.web3Url.len == 0: eth1BlockHash
                 else: waitFor getLatestEth1BlockHash(config.web3Url)
    var
      initialState = initialize_beacon_state_from_eth1(
        eth1Hash, startTime, deposits, {skipBlsValidation, skipMerkleValidation})

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

      writeFile(bootstrapFile, bootstrapEnr.toURI)
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
    debug "Launching beacon node",
          version = fullVersionStr,
          cmdParams = commandLineParams(),
          config

    createPidFile(config.dataDir.string / "beacon_node.pid")

    var node = waitFor BeaconNode.init(config)
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

  of makeDeposits:
    createDir(config.depositsDir)

    let
      quickstartDeposits = generateDeposits(
        config.totalQuickstartDeposits, config.depositsDir, false)

      randomDeposits = generateDeposits(
        config.totalRandomDeposits, config.depositsDir, true,
        firstIdx = config.totalQuickstartDeposits)

    if config.web3Url.len > 0 and config.depositContractAddress.len > 0:
      if config.minDelay > config.maxDelay:
        echo "The minimum delay should not be larger than the maximum delay"
        quit 1

      var delayGenerator: DelayGenerator
      if config.maxDelay > 0.0:
        delayGenerator = proc (): chronos.Duration {.gcsafe.} =
          chronos.milliseconds (rand(config.minDelay..config.maxDelay)*1000).int

      info "Sending deposits",
        web3 = config.web3Url,
        depositContract = config.depositContractAddress

      waitFor sendDeposits(
        quickstartDeposits & randomDeposits,
        config.web3Url,
        config.depositContractAddress,
        config.depositPrivateKey,
        delayGenerator)

  of query:
    case config.queryCmd
    of QueryCmd.nimQuery:
      # TODO: This will handle a simple subset of Nim using
      #       dot syntax and `[]` indexing.
      echo "nim query: ", config.nimQueryExpression

    of QueryCmd.get:
      let pathFragments = config.getQueryPath.split('/', maxsplit = 1)
      let bytes =
        case pathFragments[0]
        of "genesis_state":
          readFile(config.dataDir/genesisFile).string.toBytes()
        else:
          stderr.write config.getQueryPath & " is not a valid path"
          quit 1

      let navigator = DynamicSszNavigator.init(bytes, BeaconState)

      echo navigator.navigatePath(pathFragments[1 .. ^1]).toJson
