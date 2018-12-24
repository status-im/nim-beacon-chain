import
  std_shims/os_shims, net, sequtils, options,
  asyncdispatch2, chronicles, confutils, eth_p2p, eth_keys,
  spec/[beaconstate, datatypes, helpers, crypto, digest], conf, time,
  fork_choice, ssz, beacon_chain_db, validator_pool, mainchain_monitor,
  sync_protocol, gossipsub_protocol, trusted_state_snapshots

type
  BeaconNode* = ref object
    beaconState*: BeaconState
    network*: EthereumNode
    db*: BeaconChainDB
    config*: BeaconNodeConf
    keys*: KeyPair
    attachedValidators: ValidatorPool
    attestations: AttestationPool
    headBlock: BeaconBlock
    mainchainMonitor: MainchainMonitor

const
  version = "v0.1" # TODO: read this from the nimble file
  clientId = "nimbus beacon node " & version

  topicBeaconBlocks = "ethereum/2.1/beacon_chain/blocks"
  topicAttestations = "ethereum/2.1/beacon_chain/attestations"

proc ensureNetworkKeys*(dataDir: string): KeyPair =
  # TODO:
  # 1. Check if keys already exist in the data dir
  # 2. Generate new ones and save them in the directory
  # if necessary
  return newKeyPair()

proc init*(T: type BeaconNode, conf: BeaconNodeConf): T =
  new result
  result.config = conf

  result.db = BeaconChainDB.init(string conf.dataDir)
  result.keys = ensureNetworkKeys(string conf.dataDir)

  var address: Address
  address.ip = parseIpAddress("0.0.0.0")
  address.tcpPort = Port(conf.tcpPort)
  address.udpPort = Port(conf.udpPort)

  result.network = newEthereumNode(result.keys, address, 0, nil, clientId)

  writeFile(string(conf.dataDir) / "beacon_node.address",
            $result.network.listeningAddress)

proc connectToNetwork(node: BeaconNode) {.async.} =
  var bootstrapNodes = newSeq[ENode]()

  for node in node.config.bootstrapNodes:
    bootstrapNodes.add initENode(node)

  let bootstrapFile = string node.config.bootstrapNodesFile
  if bootstrapFile.len > 0:
    for ln in lines(bootstrapFile):
      bootstrapNodes.add initENode(string ln)

  if bootstrapNodes.len > 0:
    await node.network.connectToNetwork(bootstrapNodes)
  else:
    node.network.startListening()

proc sync*(node: BeaconNode): Future[bool] {.async.} =
  let persistedState = node.db.lastFinalizedState()
  if persistedState.isNil or
     persistedState[].slotDistanceFromNow() > WEAK_SUBJECTVITY_PERIOD:
    if node.config.stateSnapshot.isSome:
      node.beaconState = node.config.stateSnapshot.get
    else:
      node.beaconState = await obtainTrustedStateSnapshot(node.db)
  else:
    node.beaconState = persistedState[]
    var targetSlot = toSlot timeSinceGenesis(node.beaconState)

    while node.beaconState.finalized_slot.int < targetSlot:
      var (peer, changeLog) = await node.network.getValidatorChangeLog(
        node.beaconState.validator_registry_delta_chain_tip)

      if peer == nil:
        error "Failed to sync with any peer"
        return false

      if applyValidatorChangeLog(changeLog, node.beaconState):
        node.db.persistBlock(node.beaconState, changeLog.signedBlock)
      else:
        warn "Ignoring invalid validator change log", sentFrom = peer

  return true

template findIt(s: openarray, predicate: untyped): int =
  var res = -1
  for i, it {.inject.} in s:
    if predicate:
      res = i
      break
  res

proc addLocalValidators*(node: BeaconNode) =
  for validator in node.config.validators:
    let
      privKey = validator.privKey
      pubKey = privKey.pubKey()
      randao = validator.randao

    let idx = node.beaconState.validator_registry.findIt(it.pubKey == pubKey)
    if idx == -1:
      warn "Validator not in registry", pubKey
    else:
      node.attachedValidators.addLocalValidator(idx, pubKey, privKey, randao)

    info "Local validators attached ", count = node.attachedValidators.count

proc getAttachedValidator(node: BeaconNode, idx: int): AttachedValidator =
  let validatorKey = node.beaconState.validator_registry[idx].pubkey
  return node.attachedValidators.getValidator(validatorKey)

proc makeAttestation(node: BeaconNode,
                     validator: AttachedValidator) {.async.} =
  var attestation: AttestationCandidate
  attestation.validator = validator.idx

  # TODO: Populate attestation.data

  attestation.signature = await validator.signAttestation(attestation.data)
  await node.network.broadcast(topicAttestations, attestation)

proc proposeBlock(node: BeaconNode,
                  validator: AttachedValidator,
                  slot: int) {.async.} =
  var proposal: BeaconBlock

  # TODO:
  # 1. Produce a RANDAO reveal from attachedVadalidator.randaoSecret
  # and its matching ValidatorRecord.
  let randaoCommitment = node.beaconState.validator_registry[validator.idx].randao_commitment
  proposal.randao_reveal = await validator.randaoReveal(randaoCommitment)

  # 2. Get ancestors from the beacon_db

  # 3. Calculate the correct state hash

  proposal.candidate_pow_receipt_root =
    node.mainchainMonitor.getBeaconBlockRef()

  for a in node.attestations.each(firstSlot = node.headBlock.slot.int + 1,
                                  lastSlot = slot - MIN_ATTESTATION_INCLUSION_DELAY.int):
    # TODO: this is not quite right,
    # the attestations from individual validators have to be merged.
    # proposal.attestations.add a
    discard

  # TODO update after spec change removed specials
  # for r in node.mainchainMonitor.getValidatorActions(
  #     node.headBlock.candidate_pow_receipt_root,
  #     proposal.candidate_pow_receipt_root):
  #   proposal.specials.add r

  var signedData: ProposalSignedData
  signedData.slot = node.beaconState.slot
  signedData.shard = BEACON_CHAIN_SHARD_NUMBER
  signedData.blockRoot = hash_tree_root_final(proposal)

  proposal.signature = await validator.signBlockProposal(signedData)
  await node.network.broadcast(topicBeaconBlocks, proposal)

proc scheduleCycleActions(node: BeaconNode) =
  ## This schedules the required block proposals and
  ## attestations from our attached validators.
  let cycleStart = node.beaconState.slot.int

  for i in 0 ..< EPOCH_LENGTH:
    # Schedule block proposals
    let
      slot = cycleStart + i
      proposerIdx = get_beacon_proposer_index(node.beaconState, slot.uint64)
      attachedValidator = node.getAttachedValidator(proposerIdx)

    if attachedValidator != nil:
      # TODO:
      # Warm-up the proposer earlier to try to obtain previous
      # missing blocks if necessary

      addTimer(node.beaconState.slotStart(slot)) do (p: pointer):
        asyncCheck proposeBlock(node, attachedValidator, slot)

    # Schedule attestations
    let
      committeesIdx = get_shard_committees_index(node.beaconState, slot.uint64)

    for shard in node.beaconState.shard_committees_at_slots[committees_idx]:
      for validatorIdx in shard.committee:
        let attachedValidator = node.getAttachedValidator(validatorIdx)
        if attachedValidator != nil:
          addTimer(node.beaconState.slotMiddle(slot)) do (p: pointer):
            asyncCheck makeAttestation(node, attachedValidator)

proc processBlocks*(node: BeaconNode) {.async.} =
  node.scheduleCycleActions()

  node.network.subscribe(topicBeaconBlocks) do (b: BeaconBlock):
    # TODO:
    #
    # 1. Check for missing blocks and obtain them
    #
    # 2. Apply fork-choice rule (update node.headBlock)
    #
    # 3. Peform block processing / state recalculation / etc
    #

    if b.slot mod EPOCH_LENGTH == 0:
      node.scheduleCycleActions()
      node.attestations.discardHistoryToSlot(b.slot.int)

  node.network.subscribe(topicAttestations) do (a: Attestation):
    # Attestations are verified as aggregated groups
    node.attestations.add(getAttestationCandidate a, node.beaconState)

var gPidFile: string
proc createPidFile(filename: string) =
  createDir splitFile(filename).dir
  writeFile filename, $getCurrentProcessId()
  gPidFile = filename
  addQuitProc proc {.noconv.} = removeFile gPidFile

when isMainModule:
  let config = BeaconNodeConf.load()
  case config.cmd
  of createChain:
    let outfile = string config.outputStateFile
    let initialState = get_initial_beacon_state(
      config.chainStartupData.validatorDeposits,
      config.chainStartupData.genesisTime,
      Eth2Digest())

    Json.saveFile(outfile, initialState, pretty = true)
    echo "Wrote ", outfile
    quit 0

  of noCommand:
    waitFor syncrhronizeClock()
    createPidFile(string(config.dataDir) / "beacon_node.pid")

    var node = BeaconNode.init config
    waitFor node.connectToNetwork()

    if not waitFor node.sync():
      quit 1

    node.addLocalValidators()

    waitFor node.processBlocks()

