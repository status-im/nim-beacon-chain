# beacon_chain
# Copyright (c) 2018-2021 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  # Standard library
  std/[math, os, strformat, strutils, tables, times,
       terminal, osproc],
  system/ansi_c,

  # Nimble packages
  stew/[objects, byteutils, endians2, io2], stew/shims/macros,
  chronos, confutils, metrics, json_rpc/[rpcclient, rpcserver, jsonmarshal],
  chronicles, bearssl, blscurve,
  json_serialization/std/[options, sets, net], serialization/errors,

  eth/[keys, async_utils],
  eth/db/[kvstore, kvstore_sqlite3],
  eth/p2p/enode, eth/p2p/discoveryv5/[protocol, enr, random2],

  # Local modules
  ./rpc/[beacon_api, config_api, debug_api, event_api, nimbus_api, node_api,
    validator_api],
  spec/[datatypes, digest, crypto, beaconstate, helpers, network, presets],
  spec/[weak_subjectivity, signatures],
  spec/eth2_apis/beacon_rpc_client,
  conf, time, beacon_chain_db, validator_pool, extras,
  attestation_pool, exit_pool, eth2_network, eth2_discovery,
  beacon_node_common, beacon_node_types, beacon_node_status,
  block_pools/[chain_dag, quarantine, clearance, block_pools_types],
  nimbus_binary_common, network_metadata,
  eth1_monitor, version, ssz/merkleization,
  sync_protocol, request_manager, keystore_management, interop, statusbar,
  sync_manager, validator_duties, filepath,
  validator_slashing_protection, ./eth2_processor

from eth/common/eth_types import BlockHashOrNumber

const
  hasPrompt = not defined(withoutPrompt)

type
  RpcServer* = RpcHttpServer

template init(T: type RpcHttpServer, ip: ValidIpAddress, port: Port): T =
  newRpcHttpServer([initTAddress(ip, port)])

# https://github.com/ethereum/eth2.0-metrics/blob/master/metrics.md#interop-metrics
declareGauge beacon_slot, "Latest slot of the beacon chain state"
declareGauge beacon_current_epoch, "Current epoch"

# Finalization tracking
declareGauge finalization_delay,
  "Epoch delay between scheduled epoch and finalized epoch"

declareGauge ticks_delay,
  "How long does to take to run the onSecond loop"

logScope: topics = "beacnde"

func enrForkIdFromState(state: BeaconState): ENRForkID =
  let
    forkVer = state.fork.current_version
    forkDigest = compute_fork_digest(forkVer, state.genesis_validators_root)

  ENRForkID(
    fork_digest: forkDigest,
    next_fork_version: forkVer,
    next_fork_epoch: FAR_FUTURE_EPOCH)

proc init*(T: type BeaconNode,
           rng: ref BrHmacDrbgContext,
           conf: BeaconNodeConf,
           depositContractAddress: Eth1Address,
           depositContractDeployedAt: BlockHashOrNumber,
           eth1Network: Option[Eth1Network],
           genesisStateContents: ref string,
           genesisDepositsSnapshotContents: ref string): Future[BeaconNode] {.async.} =
  let
    db = BeaconChainDB.init(conf.runtimePreset, conf.databaseDir)

  var
    genesisState, checkpointState: ref BeaconState
    checkpointBlock: SignedBeaconBlock

  if conf.finalizedCheckpointState.isSome:
    let checkpointStatePath = conf.finalizedCheckpointState.get.string
    checkpointState = try:
      newClone(SSZ.loadFile(checkpointStatePath, BeaconState))
    except SerializationError as err:
      fatal "Checkpoint state deserialization failed",
            err = formatMsg(err, checkpointStatePath)
      quit 1
    except CatchableError as err:
      fatal "Failed to read checkpoint state file", err = err.msg
      quit 1

    if conf.finalizedCheckpointBlock.isNone:
      if checkpointState.slot > 0:
        fatal "Specifying a non-genesis --finalized-checkpoint-state requires specifying --finalized-checkpoint-block as well"
        quit 1
    else:
      let checkpointBlockPath = conf.finalizedCheckpointBlock.get.string
      try:
        checkpointBlock = SSZ.loadFile(checkpointBlockPath, SignedBeaconBlock)
      except SerializationError as err:
        fatal "Invalid checkpoint block", err = err.formatMsg(checkpointBlockPath)
        quit 1
      except IOError as err:
        fatal "Failed to load the checkpoint block", err = err.msg
        quit 1
  elif conf.finalizedCheckpointBlock.isSome:
    # TODO We can download the state from somewhere in the future relying
    #      on the trusted `state_root` appearing in the checkpoint block.
    fatal "--finalized-checkpoint-block cannot be specified without --finalized-checkpoint-state"
    quit 1

  var eth1Monitor: Eth1Monitor
  if not ChainDAGRef.isInitialized(db):
    var
      tailState: ref BeaconState
      tailBlock: SignedBeaconBlock

    if genesisStateContents == nil and checkpointState == nil:
      when hasGenesisDetection:
        if genesisDepositsSnapshotContents != nil:
          fatal "A deposits snapshot cannot be provided without also providing a matching beacon state snapshot"
          quit 1

        # This is a fresh start without a known genesis state
        # (most likely, it hasn't arrived yet). We'll try to
        # obtain a genesis through the Eth1 deposits monitor:
        if conf.web3Url.len == 0:
          fatal "Web3 URL not specified"
          quit 1

        # TODO Could move this to a separate "GenesisMonitor" process or task
        #      that would do only this - see Paul's proposal for this.
        let eth1MonitorRes = await Eth1Monitor.init(
          conf.runtimePreset,
          db,
          conf.web3Url,
          depositContractAddress,
          depositContractDeployedAt,
          eth1Network)

        if eth1MonitorRes.isErr:
          fatal "Failed to start Eth1 monitor",
                reason = eth1MonitorRes.error,
                web3Url = conf.web3Url,
                depositContractAddress,
                depositContractDeployedAt
          quit 1
        else:
          eth1Monitor = eth1MonitorRes.get

        genesisState = await eth1Monitor.waitGenesis()
        if bnStatus == BeaconNodeStatus.Stopping:
          return nil

        tailState = genesisState
        tailBlock = get_initial_beacon_block(genesisState[])

        notice "Eth2 genesis state detected",
          genesisTime = genesisState.genesisTime,
          eth1Block = genesisState.eth1_data.block_hash,
          totalDeposits = genesisState.eth1_data.deposit_count
      else:
        fatal "The beacon node must be compiled with -d:has_genesis_detection " &
              "in order to support monitoring for genesis events"
        quit 1

    elif genesisStateContents == nil:
      if checkpointState.slot == GENESIS_SLOT:
        genesisState = checkpointState
        tailState = checkpointState
        tailBlock = get_initial_beacon_block(genesisState[])
      else:
        fatal "State checkpoints cannot be provided for a network without a known genesis state"
        quit 1
    else:
      try:
        genesisState = newClone(SSZ.decode(genesisStateContents[], BeaconState))
      except CatchableError as err:
        raiseAssert "Invalid baked-in state: " & err.msg

      if checkpointState != nil:
        tailState = checkpointState
        tailBlock = checkpointBlock
      else:
        tailState = genesisState
        tailBlock = get_initial_beacon_block(genesisState[])

    try:
      ChainDAGRef.preInit(db, genesisState[], tailState[], tailBlock)
      doAssert ChainDAGRef.isInitialized(db), "preInit should have initialized db"
    except CatchableError as e:
      error "Failed to initialize database", err = e.msg
      quit 1

  info "Loading block dag from database", path = conf.databaseDir

  let
    chainDagFlags = if conf.verifyFinalization: {verifyFinalization}
                     else: {}
    chainDag = ChainDAGRef.init(conf.runtimePreset, db, chainDagFlags)
    beaconClock = BeaconClock.init(chainDag.headState.data.data)
    quarantine = QuarantineRef()
    databaseGenesisValidatorsRoot =
      chainDag.headState.data.data.genesis_validators_root

  if genesisStateContents != nil:
    let
      networkGenesisValidatorsRoot =
        extractGenesisValidatorRootFromSnapshop(genesisStateContents[])

    if networkGenesisValidatorsRoot != databaseGenesisValidatorsRoot:
      fatal "The specified --data-dir contains data for a different network",
            networkGenesisValidatorsRoot, databaseGenesisValidatorsRoot,
            dataDir = conf.dataDir
      quit 1

  if conf.weakSubjectivityCheckpoint.isSome:
    let
      currentSlot = beaconClock.now.slotOrZero
      isCheckpointStale = not is_within_weak_subjectivity_period(
        currentSlot,
        chainDag.headState.data.data,
        conf.weakSubjectivityCheckpoint.get)

    if isCheckpointStale:
      error "Weak subjectivity checkpoint is stale",
            currentSlot,
            checkpoint = conf.weakSubjectivityCheckpoint.get,
            headStateSlot = chainDag.headState.data.data.slot
      quit 1

  if checkpointState != nil:
    let checkpointGenesisValidatorsRoot = checkpointState[].genesis_validators_root
    if checkpointGenesisValidatorsRoot != databaseGenesisValidatorsRoot:
      fatal "The specified checkpoint state is intended for a different network",
            checkpointGenesisValidatorsRoot, databaseGenesisValidatorsRoot,
            dataDir = conf.dataDir
      quit 1

    chainDag.setTailState(checkpointState[], checkpointBlock)

  if eth1Monitor.isNil and
     conf.web3Url.len > 0 and
     genesisDepositsSnapshotContents != nil:
    let genesisDepositsSnapshot = SSZ.decode(genesisDepositsSnapshotContents[],
                                             DepositContractSnapshot)
    eth1Monitor = Eth1Monitor.init(
      conf.runtimePreset,
      db,
      conf.web3Url,
      depositContractAddress,
      genesisDepositsSnapshot,
      eth1Network)

  let rpcServer = if conf.rpcEnabled:
    RpcServer.init(conf.rpcAddress, conf.rpcPort)
  else:
    nil

  let
    netKeys = getPersistentNetKeys(rng[], conf)
    nickname = if conf.nodeName == "auto": shortForm(netKeys)
               else: conf.nodeName
    enrForkId = enrForkIdFromState(chainDag.headState.data.data)
    topicBeaconBlocks = getBeaconBlocksTopic(enrForkId.forkDigest)
    topicAggregateAndProofs = getAggregateAndProofsTopic(enrForkId.forkDigest)
    network = createEth2Node(rng, conf, netKeys, enrForkId)
    attestationPool = newClone(AttestationPool.init(chainDag, quarantine))
    exitPool = newClone(ExitPool.init(chainDag, quarantine))
  var res = BeaconNode(
    nickname: nickname,
    graffitiBytes: if conf.graffiti.isSome: conf.graffiti.get.GraffitiBytes
                   else: defaultGraffitiBytes(),
    network: network,
    netKeys: netKeys,
    db: db,
    config: conf,
    chainDag: chainDag,
    quarantine: quarantine,
    attestationPool: attestationPool,
    exitPool: exitPool,
    eth1Monitor: eth1Monitor,
    beaconClock: beaconClock,
    rpcServer: rpcServer,
    forkDigest: enrForkId.forkDigest,
    topicBeaconBlocks: topicBeaconBlocks,
    topicAggregateAndProofs: topicAggregateAndProofs,
  )

  # set topic validation routine
  network.setValidTopics(
    block:
      var
        topics = @[
            topicBeaconBlocks,
            getAttesterSlashingsTopic(enrForkId.forkDigest),
            getProposerSlashingsTopic(enrForkId.forkDigest),
            getVoluntaryExitsTopic(enrForkId.forkDigest),
            getAggregateAndProofsTopic(enrForkId.forkDigest)
          ]
      for subnet in 0'u64 ..< ATTESTATION_SUBNET_COUNT:
        topics &= getAttestationTopic(enrForkId.forkDigest, subnet)
      topics)

  info "Loading slashing protection database", path = conf.validatorsDir()
  res.attachedValidators = ValidatorPool.init(
    SlashingProtectionDB.init(
      chainDag.headState.data.data.genesis_validators_root,
      kvStore SqStoreRef.init(conf.validatorsDir(), "slashing_protection").tryGet()
    )
  )

  proc getWallTime(): BeaconTime = res.beaconClock.now()

  res.processor = Eth2Processor.new(
    conf, chainDag, attestationPool, exitPool, quarantine, getWallTime)

  res.requestManager = RequestManager.init(
    network, res.processor.blocksQueue)

  if res.config.inProcessValidators:
    res.addLocalValidators()
  else:
    let cmd = getAppDir() / "nimbus_signing_process".addFileExt(ExeExt)
    let args = [$res.config.validatorsDir, $res.config.secretsDir]
    let workdir = io2.getCurrentDir().tryGet()
    res.vcProcess = startProcess(cmd, workdir, args)
    res.addRemoteValidators()

  # This merely configures the BeaconSync
  # The traffic will be started when we join the network.
  network.initBeaconSync(chainDag, enrForkId.forkDigest)

  res.updateValidatorMetrics()

  return res

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
      node.chainDag.finalizedHead.slot.compute_epoch_at_slot()
    # Finalization rule 234, that has the most lag slots among the cases, sets
    # state.finalized_checkpoint = old_previous_justified_checkpoint.epoch + 3
    # and then state.slot gets incremented, to increase the maximum offset, if
    # finalization occurs every slot, to 4 slots vs scheduledSlot.
    doAssert finalizedEpoch + 4 >= epoch

proc installAttestationSubnetHandlers(node: BeaconNode, subnets: set[uint8]) =
  # https://github.com/ethereum/eth2.0-specs/blob/v1.0.0/specs/phase0/p2p-interface.md#attestations-and-aggregation
  for subnet in subnets:
    node.network.subscribe(getAttestationTopic(node.forkDigest, subnet))

proc updateStabilitySubnetMetadata(
    node: BeaconNode, stabilitySubnets: set[uint8]) =
  # https://github.com/ethereum/eth2.0-specs/blob/v1.0.0/specs/phase0/p2p-interface.md#metadata
  node.network.metadata.seq_number += 1
  for subnet in 0'u8 ..< ATTESTATION_SUBNET_COUNT:
    node.network.metadata.attnets[subnet] = (subnet in stabilitySubnets)

  # https://github.com/ethereum/eth2.0-specs/blob/v1.0.0/specs/phase0/validator.md#phase-0-attestation-subnet-stability
  # https://github.com/ethereum/eth2.0-specs/blob/v1.0.0/specs/phase0/p2p-interface.md#attestation-subnet-bitfield
  let res = node.network.discovery.updateRecord(
    {"attnets": SSZ.encode(node.network.metadata.attnets)})
  if res.isErr():
    # This should not occur in this scenario as the private key would always
    # be the correct one and the ENR will not increase in size.
    warn "Failed to update record on subnet cycle", error = res.error
  else:
    debug "Stability subnets changed; updated ENR attnets", stabilitySubnets

func getStabilitySubnets(stabilitySubnets: auto): set[uint8] =
  for subnetInfo in stabilitySubnets:
    result.incl subnetInfo.subnet

proc getAttachedValidators(node: BeaconNode): HashSet[ValidatorIndex] =
  for validatorIndex in 0 ..< node.chainDag.headState.data.data.validators.len:
    if node.getAttachedValidator(
        node.chainDag.headState.data.data, validatorIndex.ValidatorIndex) != nil:
      result.incl validatorIndex.ValidatorIndex

proc updateSubscriptionSchedule(node: BeaconNode, epoch: Epoch) =
  doAssert epoch >= 1
  let attachedValidators = node.getAttachedValidators()
  for (subnetIndex, slot) in get_committee_assignments(
      node.chainDag.headState.data.data, epoch, attachedValidators):
    node.attestationSubnets.unsubscribeSlot[subnetIndex] =
      max(slot + 1, node.attestationSubnets.unsubscribeSlot[subnetIndex])
    if subnetIndex notin node.attestationSubnets.subscribedSubnets:
      # A Pyrmont test validator didn't manage to subscribe in time with
      # SUBNET_SUBSCRIPTION_LEAD_TIME_SLOTS being 32.
      const SUBNET_SUBSCRIPTION_LEAD_TIME_SLOTS = 34

      node.attestationSubnets.subscribeSlot[subnetIndex] =
        # Queue upcoming subscription potentially earlier
        # SLOTS_PER_EPOCH emulates one boundary condition of the per-epoch
        # cycling mechanism timing buffers
        min(
          slot - min(slot.uint64, SUBNET_SUBSCRIPTION_LEAD_TIME_SLOTS),
          node.attestationSubnets.subscribeSlot[subnetIndex])

# https://github.com/ethereum/eth2.0-specs/blob/v1.0.0/specs/phase0/validator.md#phase-0-attestation-subnet-stability
proc getStabilitySubnetLength(node: BeaconNode): uint64 =
  EPOCHS_PER_RANDOM_SUBNET_SUBSCRIPTION +
    node.network.rng[].rand(EPOCHS_PER_RANDOM_SUBNET_SUBSCRIPTION.int).uint64

proc updateStabilitySubnets(node: BeaconNode, slot: Slot): set[uint8] =
  # Equivalent to wallSlot by cycleAttestationSubnets(), especially
  # since it'll try to run early in epochs, avoiding race conditions.
  static: doAssert ATTESTATION_SUBNET_COUNT <= high(uint8)
  let epoch = slot.epoch

  # https://github.com/ethereum/eth2.0-specs/blob/v1.0.0/specs/phase0/validator.md#phase-0-attestation-subnet-stability
  for i in 0 ..< node.attestationSubnets.stabilitySubnets.len:
    if epoch >= node.attestationSubnets.stabilitySubnets[i].expiration:
      node.attestationSubnets.stabilitySubnets[i].subnet =
        node.network.rng[].rand(ATTESTATION_SUBNET_COUNT - 1).uint8
      node.attestationSubnets.stabilitySubnets[i].expiration =
        epoch + node.getStabilitySubnetLength()

    result.incl node.attestationSubnets.stabilitySubnets[i].subnet

proc cycleAttestationSubnetsPerEpoch(
    node: BeaconNode, wallSlot: Slot, prevStabilitySubnets: set[uint8]):
    set[uint8] =
  # Per-epoch portion of subnet cycling: updating stability subnets and
  # calculating future attestation subnets.

  # Only know RANDAO mix, which determines shuffling seed, one epoch in
  # advance. When node.chainDag.headState.data.data.slot.epoch is ahead
  # of wallSlot, the clock's just incorrect. If the state slot's behind
  # wallSlot, it would have to look more than MIN_SEED_LOOKAHEAD epochs
  # ahead to compute the shuffling determining the beacon committees.
  if node.chainDag.headState.data.data.slot.epoch != wallSlot.epoch:
    debug "Requested attestation subnets too far in advance",
      wallSlot,
      stateSlot = node.chainDag.headState.data.data.slot
    return prevStabilitySubnets

  # This works so long as at least one block in an epoch provides a basis for
  # calculating the shuffling for the next epoch. It will keep checking for a
  # block, each slot, until a block comes in, even if the first few blocks in
  # an epoch are missing. If a whole epoch without blocks occurs, it's not as
  # important to attest regardless, as those upcoming blocks will hit maximum
  # attestations quickly and any individual attestation's likelihood of being
  # selected is low.
  if node.attestationSubnets.nextCycleEpoch <= wallSlot.epoch:
    node.updateSubscriptionSchedule(wallSlot.epoch + 1)
  node.attestationSubnets.nextCycleEpoch = wallSlot.epoch + 1

  let stabilitySubnets = node.updateStabilitySubnets(wallSlot)

  if  not node.config.subscribeAllSubnets and
      stabilitySubnets != prevStabilitySubnets:
    # In subscribeAllSubnets mode, this only gets set once, at initial subnet
    # attestation handler creation, since they're all considered as stability
    # subnets in that case.
    node.updateStabilitySubnetMetadata(stabilitySubnets)

  stabilitySubnets

proc cycleAttestationSubnets(node: BeaconNode, wallSlot: Slot) =
  static: doAssert RANDOM_SUBNETS_PER_VALIDATOR == 1
  doAssert not node.config.subscribeAllSubnets

  let prevSubscribedSubnets = node.attestationSubnets.subscribedSubnets

  for i in 0'u8 ..< ATTESTATION_SUBNET_COUNT:
    if i in node.attestationSubnets.subscribedSubnets:
      if wallSlot >= node.attestationSubnets.unsubscribeSlot[i]:
        node.attestationSubnets.subscribedSubnets.excl i
    else:
      if wallSlot >= node.attestationSubnets.subscribeSlot[i]:
        node.attestationSubnets.subscribedSubnets.incl i

  let
    prevStabilitySubnets =
      getStabilitySubnets(node.attestationSubnets.stabilitySubnets)
    stabilitySubnets =
      node.cycleAttestationSubnetsPerEpoch(wallSlot, prevStabilitySubnets)

  # Accounting specific to non-stability subnets
  for expiringSubnet in
      prevSubscribedSubnets - node.attestationSubnets.subscribedSubnets:
    node.attestationSubnets.subscribeSlot[expiringSubnet] = FAR_FUTURE_SLOT

  let
    prevAllSubnets = prevSubscribedSubnets + prevStabilitySubnets
    allSubnets = node.attestationSubnets.subscribedSubnets + stabilitySubnets
    unsubscribedSubnets = prevAllSubnets - allSubnets
    subscribedSubnets = allSubnets - prevAllSubnets

  for subnet in unsubscribedSubnets:
    node.network.unsubscribe(
      getAttestationTopic(node.forkDigest, subnet))

  node.installAttestationSubnetHandlers(subscribedSubnets)

  debug "Attestation subnets",
    expiringSubnets =
      prevSubscribedSubnets - node.attestationSubnets.subscribedSubnets,
    subnets = node.attestationSubnets.subscribedSubnets,
    newSubnets =
      node.attestationSubnets.subscribedSubnets - prevSubscribedSubnets,
    wallSlot,
    wallEpoch = wallSlot.epoch,
    num_stability_subnets = node.attestationSubnets.stabilitySubnets.len,
    expiring_stability_subnets = prevStabilitySubnets - stabilitySubnets,
    new_stability_subnets = stabilitySubnets - prevStabilitySubnets,
    subscribedSubnets,
    unsubscribedSubnets

proc getInitialAttestationSubnets(node: BeaconNode): Table[uint8, Slot] =
  let
    wallEpoch = node.beaconClock.now().slotOrZero().epoch
    validator_indices = node.getAttachedValidators()

  template mergeAttestationSubnets(epoch: Epoch) =
    for (subnetIndex, slot) in get_committee_assignments(
        node.chainDag.headState.data.data, epoch, validator_indices):
      if subnetIndex in result:
        result[subnetIndex] = max(result[subnetIndex], slot + 1)
      else:
        result[subnetIndex] = slot + 1

  # Either wallEpoch is 0, in which case it might be pre-genesis, but we only
  # care about the already-known first two epochs of attestations, or it's in
  # epoch 0 for real, in which case both are also already known; or wallEpoch
  # is greater than 0, in which case it's being called from onSlotStart which
  # has enough state to calculate wallEpoch + {0,1}'s attestations.
  mergeAttestationSubnets(wallEpoch)
  mergeAttestationSubnets(wallEpoch + 1)

proc getAttestationSubnetHandlers(node: BeaconNode) =
  # https://github.com/ethereum/eth2.0-specs/blob/v1.0.0/specs/phase0/validator.md#phase-0-attestation-subnet-stability
  # TODO:
  # We might want to reuse the previous stability subnet if not expired when:
  # - Restarting the node with a presistent netkey
  # - When going from synced -> syncing -> synced state

  template getAllAttestationSubnets(): Table[uint8, Slot] =
    var subnets: Table[uint8, Slot]
    for i in 0'u8 ..< ATTESTATION_SUBNET_COUNT:
      subnets[i] = FAR_FUTURE_SLOT
    subnets

  let
    initialSubnets =
      if node.config.subscribeAllSubnets:
        getAllAttestationSubnets()
      else:
        node.getInitialAttestationSubnets()
    wallEpoch = node.beaconClock.now().slotOrZero().epoch

  var initialStabilitySubnets: set[uint8]

  node.attestationSubnets.stabilitySubnets.setLen(
    node.attachedValidators.count)
  for i in 0 ..< node.attachedValidators.count:
    node.attestationSubnets.stabilitySubnets[i] = (
      subnet: node.network.rng[].rand(ATTESTATION_SUBNET_COUNT - 1).uint8,
      expiration: wallEpoch + node.getStabilitySubnetLength())
    initialStabilitySubnets.incl(
      node.attestationSubnets.stabilitySubnets[i].subnet)

  node.updateStabilitySubnetMetadata(
    if node.config.subscribeAllSubnets:
      {0'u8 .. (ATTESTATION_SUBNET_COUNT - 1)}
    else:
      node.attestationSubnets.stabilitySubnets.getStabilitySubnets)

  for i in 0'u8 ..< ATTESTATION_SUBNET_COUNT:
    if i in initialSubnets:
      node.attestationSubnets.subscribedSubnets.incl i
      node.attestationSubnets.unsubscribeSlot[i] = initialSubnets[i]
    else:
      node.attestationSubnets.subscribedSubnets.excl i
      node.attestationSubnets.subscribeSlot[i] = FAR_FUTURE_SLOT

  node.attestationSubnets.enabled = true

  debug "Initial attestation subnets subscribed",
     initialSubnets,
     initialStabilitySubnets,
     wallEpoch
  node.installAttestationSubnetHandlers(
    node.attestationSubnets.subscribedSubnets + initialStabilitySubnets)

proc addMessageHandlers(node: BeaconNode) =
  node.network.subscribe(node.topicBeaconBlocks, enableTopicMetrics = true)
  node.network.subscribe(getAttesterSlashingsTopic(node.forkDigest))
  node.network.subscribe(getProposerSlashingsTopic(node.forkDigest))
  node.network.subscribe(getVoluntaryExitsTopic(node.forkDigest))
  node.network.subscribe(getAggregateAndProofsTopic(node.forkDigest), enableTopicMetrics = true)
  node.getAttestationSubnetHandlers()

func getTopicSubscriptionEnabled(node: BeaconNode): bool =
  node.attestationSubnets.enabled

proc removeMessageHandlers(node: BeaconNode) =
  node.attestationSubnets.enabled = false
  doAssert not node.getTopicSubscriptionEnabled()

  node.network.unsubscribe(getBeaconBlocksTopic(node.forkDigest))
  node.network.unsubscribe(getVoluntaryExitsTopic(node.forkDigest))
  node.network.unsubscribe(getProposerSlashingsTopic(node.forkDigest))
  node.network.unsubscribe(getAttesterSlashingsTopic(node.forkDigest))
  node.network.unsubscribe(getAggregateAndProofsTopic(node.forkDigest))

  for subnet in 0'u64 ..< ATTESTATION_SUBNET_COUNT:
    node.network.unsubscribe(getAttestationTopic(node.forkDigest, subnet))

proc updateGossipStatus(node: BeaconNode, slot: Slot) =
  # Syncing tends to be ~1 block/s, and allow for an epoch of time for libp2p
  # subscribing to spin up. The faster the sync, the more wallSlot - headSlot
  # lead time is required
  const
    TOPIC_SUBSCRIBE_THRESHOLD_SLOTS = 64
    HYSTERESIS_BUFFER = 16

  let
    syncQueueLen = node.syncManager.syncQueueLen
    topicSubscriptionEnabled = node.getTopicSubscriptionEnabled()
  if
      # Don't enable if already enabled; to avoid race conditions requires care,
      # but isn't crucial, as this condition spuriously fail, but the next time,
      # should properly succeed.
      not topicSubscriptionEnabled and
      # SyncManager forward sync by default runs until maxHeadAge slots, or one
      # epoch range is achieved. This particular condition has a couple caveats
      # including that under certain conditions, debtsCount appears to push len
      # (here, syncQueueLen) to underflow-like values; and even when exactly at
      # the expected walltime slot the queue isn't necessarily empty. Therefore
      # TOPIC_SUBSCRIBE_THRESHOLD_SLOTS is not exactly the number of slots that
      # are left. Furthermore, even when 0 peers are being used, this won't get
      # to 0 slots in syncQueueLen, but that's a vacuous condition given that a
      # networking interaction cannot happen under such circumstances.
      syncQueueLen < TOPIC_SUBSCRIBE_THRESHOLD_SLOTS:
    # When node.cycleAttestationSubnets() is enabled more properly, integrate
    # this into the node.cycleAttestationSubnets() call.
    debug "Enabling topic subscriptions",
      wallSlot = slot,
      headSlot = node.chainDag.head.slot,
      syncQueueLen

    node.addMessageHandlers()
    doAssert node.getTopicSubscriptionEnabled()
  elif
      topicSubscriptionEnabled and
      syncQueueLen > TOPIC_SUBSCRIBE_THRESHOLD_SLOTS + HYSTERESIS_BUFFER and
      # Filter out underflow from debtsCount; plausible queue lengths can't
      # exceed wallslot, with safety margin.
      syncQueueLen < 2 * slot.uint64:
    debug "Disabling topic subscriptions",
      wallSlot = slot,
      headSlot = node.chainDag.head.slot,
      syncQueueLen
    node.removeMessageHandlers()

  # Subscription or unsubscription might have occurred; recheck. Since Nimbus
  # initially subscribes to all subnets, simply do not ever cycle attestation
  # subnets and they'll all remain subscribed.
  if node.getTopicSubscriptionEnabled and not node.config.subscribeAllSubnets:
    # This exits early all but one call each epoch.
    node.cycleAttestationSubnets(slot)

proc onSlotEnd(node: BeaconNode, slot, nextSlot: Slot) =
  # Things we do when slot processing has ended and we're about to wait for the
  # next slot

  when declared(GC_fullCollect):
    # The slots in the beacon node work as frames in a game: we want to make
    # sure that we're ready for the next one and don't get stuck in lengthy
    # garbage collection tasks when time is of essence in the middle of a slot -
    # while this does not guarantee that we'll never collect during a slot, it
    # makes sure that all the scratch space we used during slot tasks (logging,
    # temporary buffers etc) gets recycled for the next slot that is likely to
    # need similar amounts of memory.
    GC_fullCollect()

  # Checkpoint the database to clear the WAL file and make sure changes in
  # the database are synced with the filesystem.
  node.db.checkpoint()

  info "Slot end",
    slot = shortLog(slot),
    nextSlot = shortLog(nextSlot),
    head = shortLog(node.chainDag.head),
    headEpoch = shortLog(node.chainDag.head.slot.compute_epoch_at_slot()),
    finalizedHead = shortLog(node.chainDag.finalizedHead.blck),
    finalizedEpoch = shortLog(node.chainDag.finalizedHead.blck.slot.compute_epoch_at_slot())

  node.updateGossipStatus(slot)

proc onSlotStart(node: BeaconNode, lastSlot, scheduledSlot: Slot) {.async.} =
  ## Called at the beginning of a slot - usually every slot, but sometimes might
  ## skip a few in case we're running late.
  ## lastSlot: the last slot that we successfully processed, so we know where to
  ##           start work from
  ## scheduledSlot: the slot that we were aiming for, in terms of timing
  let
    # The slot we should be at, according to the clock
    beaconTime = node.beaconClock.now()
    wallSlot = beaconTime.toSlot()
    finalizedEpoch =
      node.chainDag.finalizedHead.blck.slot.compute_epoch_at_slot()

  if not node.processor[].blockReceivedDuringSlot.finished:
    node.processor[].blockReceivedDuringSlot.complete()
  node.processor[].blockReceivedDuringSlot = newFuture[void]()

  let delay = beaconTime - scheduledSlot.toBeaconTime()

  info "Slot start",
    lastSlot = shortLog(lastSlot),
    scheduledSlot = shortLog(scheduledSlot),
    delay,
    peers = len(node.network.peerPool),
    head = shortLog(node.chainDag.head),
    headEpoch = shortLog(node.chainDag.head.slot.compute_epoch_at_slot()),
    finalized = shortLog(node.chainDag.finalizedHead.blck),
    finalizedEpoch = shortLog(finalizedEpoch),
    sync =
      if node.syncManager.inProgress: node.syncManager.syncStatus
      else: "synced"

  # Check before any re-scheduling of onSlotStart()
  checkIfShouldStopAtEpoch(scheduledSlot, node.config.stopAtEpoch)

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
      nextSlot = shortLog(nextSlot)

    addTimer(saturate(node.beaconClock.fromNow(nextSlot))) do (p: pointer):
      asyncCheck node.onSlotStart(slot, nextSlot)

    return

  let
    slot = wallSlot.slot # afterGenesis == true!
    nextSlot = slot + 1

  defer: onSlotEnd(node, slot, nextSlot)

  beacon_slot.set slot.int64
  beacon_current_epoch.set slot.epoch.int64

  finalization_delay.set scheduledSlot.epoch.int64 - finalizedEpoch.int64

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
      scheduledSlot = shortLog(scheduledSlot)

    addTimer(saturate(node.beaconClock.fromNow(nextSlot))) do (p: pointer):
      # We pass the current slot here to indicate that work should be skipped!
      asyncCheck node.onSlotStart(slot, nextSlot)
    return

  # Whatever we do during the slot, we need to know the head, because this will
  # give us a state to work with and thus a shuffling.
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
  node.processor[].updateHead(slot)

  # Time passes in here..
  await node.handleValidatorDuties(lastSlot, slot)

  let
    nextSlotStart = saturate(node.beaconClock.fromNow(nextSlot))

  addTimer(nextSlotStart) do (p: pointer):
    asyncCheck node.onSlotStart(slot, nextSlot)

proc handleMissingBlocks(node: BeaconNode) =
  let missingBlocks = node.quarantine.checkMissing()
  if missingBlocks.len > 0:
    debug "Requesting detected missing blocks", blocks = shortLog(missingBlocks)
    node.requestManager.fetchAncestorBlocks(missingBlocks)

proc onSecond(node: BeaconNode) =
  ## This procedure will be called once per second.
  if not(node.syncManager.inProgress):
    node.handleMissingBlocks()

proc runOnSecondLoop(node: BeaconNode) {.async.} =
  let sleepTime = chronos.seconds(1)
  const nanosecondsIn1s = float(chronos.seconds(1).nanoseconds)
  while true:
    let start = chronos.now(chronos.Moment)
    await chronos.sleepAsync(sleepTime)
    let afterSleep = chronos.now(chronos.Moment)
    let sleepTime = afterSleep - start
    node.onSecond()
    let finished = chronos.now(chronos.Moment)
    let processingTime = finished - afterSleep
    ticks_delay.set(sleepTime.nanoseconds.float / nanosecondsIn1s)
    trace "onSecond task completed", sleepTime, processingTime

proc startSyncManager(node: BeaconNode) =
  func getLocalHeadSlot(): Slot =
    node.chainDag.head.slot

  proc getLocalWallSlot(): Slot =
    node.beaconClock.now().slotOrZero

  func getFirstSlotAtFinalizedEpoch(): Slot =
    node.chainDag.finalizedHead.slot

  proc scoreCheck(peer: Peer): bool =
    if peer.score < PeerScoreLowLimit:
      false
    else:
      true

  proc onDeletePeer(peer: Peer) =
    if peer.connectionState notin {Disconnecting, Disconnected}:
      if peer.score < PeerScoreLowLimit:
        debug "Peer was removed from PeerPool due to low score", peer = peer,
              peer_score = peer.score, score_low_limit = PeerScoreLowLimit,
              score_high_limit = PeerScoreHighLimit
        asyncSpawn peer.disconnect(PeerScoreLow)
      else:
        debug "Peer was removed from PeerPool", peer = peer,
              peer_score = peer.score, score_low_limit = PeerScoreLowLimit,
              score_high_limit = PeerScoreHighLimit
        asyncSpawn peer.disconnect(FaultOrError)

  node.network.peerPool.setScoreCheck(scoreCheck)
  node.network.peerPool.setOnDeletePeer(onDeletePeer)

  node.syncManager = newSyncManager[Peer, PeerID](
    node.network.peerPool, getLocalHeadSlot, getLocalWallSlot,
    getFirstSlotAtFinalizedEpoch, node.processor.blocksQueue, chunkSize = 32
  )
  node.syncManager.start()

proc connectedPeersCount(node: BeaconNode): int =
  len(node.network.peerPool)

proc installRpcHandlers(rpcServer: RpcServer, node: BeaconNode) =
  rpcServer.installBeaconApiHandlers(node)
  rpcServer.installConfigApiHandlers(node)
  rpcServer.installDebugApiHandlers(node)
  rpcServer.installEventApiHandlers(node)
  rpcServer.installNimbusApiHandlers(node)
  rpcServer.installNodeApiHandlers(node)
  rpcServer.installValidatorApiHandlers(node)

proc installMessageValidators(node: BeaconNode) =
  # https://github.com/ethereum/eth2.0-specs/blob/v1.0.0/specs/phase0/p2p-interface.md#attestations-and-aggregation
  # These validators stay around the whole time, regardless of which specific
  # subnets are subscribed to during any given epoch.
  for it in 0'u64 ..< ATTESTATION_SUBNET_COUNT.uint64:
    closureScope:
      let ci = it
      node.network.addValidator(
        getAttestationTopic(node.forkDigest, ci),
        # This proc needs to be within closureScope; don't lift out of loop.
        proc(attestation: Attestation): ValidationResult =
          node.processor[].attestationValidator(attestation, ci))

  node.network.addValidator(
    getAggregateAndProofsTopic(node.forkDigest),
    proc(signedAggregateAndProof: SignedAggregateAndProof): ValidationResult =
      node.processor[].aggregateValidator(signedAggregateAndProof))

  node.network.addValidator(
    node.topicBeaconBlocks,
    proc (signedBlock: SignedBeaconBlock): ValidationResult =
      node.processor[].blockValidator(signedBlock))

  node.network.addValidator(
    getAttesterSlashingsTopic(node.forkDigest),
    proc (attesterSlashing: AttesterSlashing): ValidationResult =
      node.processor[].attesterSlashingValidator(attesterSlashing))

  node.network.addValidator(
    getProposerSlashingsTopic(node.forkDigest),
    proc (proposerSlashing: ProposerSlashing): ValidationResult =
      node.processor[].proposerSlashingValidator(proposerSlashing))

  node.network.addValidator(
    getVoluntaryExitsTopic(node.forkDigest),
    proc (signedVoluntaryExit: SignedVoluntaryExit): ValidationResult =
      node.processor[].voluntaryExitValidator(signedVoluntaryExit))

proc stop*(node: BeaconNode) =
  bnStatus = BeaconNodeStatus.Stopping
  notice "Graceful shutdown"
  if not node.config.inProcessValidators:
    node.vcProcess.close()
  waitFor node.network.stop()
  node.attachedValidators.slashingProtection.close()
  node.db.close()
  notice "Databases closed"

proc run*(node: BeaconNode) =
  if bnStatus == BeaconNodeStatus.Starting:
    # it might have been set to "Stopping" with Ctrl+C
    bnStatus = BeaconNodeStatus.Running

    if node.rpcServer != nil:
      node.rpcServer.installRpcHandlers(node)
      node.rpcServer.start()

    node.installMessageValidators()

    let
      curSlot = node.beaconClock.now().slotOrZero()
      nextSlot = curSlot + 1 # No earlier than GENESIS_SLOT + 1
      fromNow = saturate(node.beaconClock.fromNow(nextSlot))

    info "Scheduling first slot action",
      beaconTime = shortLog(node.beaconClock.now()),
      nextSlot = shortLog(nextSlot),
      fromNow = shortLog(fromNow)

    addTimer(fromNow) do (p: pointer):
      asyncCheck node.onSlotStart(curSlot, nextSlot)

    node.onSecondLoop = runOnSecondLoop(node)
    node.blockProcessingLoop = node.processor.runQueueProcessingLoop()

    node.requestManager.start()
    node.startSyncManager()

    if not node.beaconClock.now().toSlot().afterGenesis:
      node.addMessageHandlers()
      doAssert node.getTopicSubscriptionEnabled()

  ## Ctrl+C handling
  proc controlCHandler() {.noconv.} =
    when defined(windows):
      # workaround for https://github.com/nim-lang/Nim/issues/4057
      setupForeignThreadGc()
    notice "Shutting down after having received SIGINT"
    bnStatus = BeaconNodeStatus.Stopping
  setControlCHook(controlCHandler)
  # equivalent SIGTERM handler
  when defined(posix):
    proc SIGTERMHandler(signal: cint) {.noconv.} =
      notice "Shutting down after having received SIGTERM"
      bnStatus = BeaconNodeStatus.Stopping
    c_signal(SIGTERM, SIGTERMHandler)

  # main event loop
  while bnStatus == BeaconNodeStatus.Running:
    try:
      poll()
    except CatchableError as e:
      debug "Exception in poll()", exc = e.name, err = e.msg

  # time to say goodbye
  node.stop()

var gPidFile: string
proc createPidFile(filename: string) =
  writeFile filename, $os.getCurrentProcessId()
  gPidFile = filename
  addQuitProc proc {.noconv.} = discard io2.removeFile(gPidFile)

proc initializeNetworking(node: BeaconNode) {.async.} =
  info "Listening to incoming network requests"
  await node.network.startListening()

  let addressFile = node.config.dataDir / "beacon_node.enr"
  writeFile(addressFile, node.network.announcedENR.toURI)

  await node.network.start()

func shouldWeStartWeb3(node: BeaconNode): bool =
  (node.config.web3Mode == Web3Mode.enabled) or
  (node.config.web3Mode == Web3Mode.auto and node.attachedValidators.count > 0)

proc start(node: BeaconNode) =
  let
    head = node.chainDag.head
    finalizedHead = node.chainDag.finalizedHead
    genesisTime = node.beaconClock.fromNow(toBeaconTime(Slot 0))

  notice "Starting beacon node",
    version = fullVersionStr,
    enr = node.network.announcedENR.toURI,
    peerId = $node.network.switch.peerInfo.peerId,
    timeSinceFinalization =
      node.beaconClock.now() - finalizedHead.slot.toBeaconTime(),
    head = shortLog(head),
    finalizedHead = shortLog(finalizedHead),
    SLOTS_PER_EPOCH,
    SECONDS_PER_SLOT,
    SPEC_VERSION,
    dataDir = node.config.dataDir.string,
    validators = node.attachedValidators.count

  if genesisTime.inFuture:
    notice "Waiting for genesis", genesisIn = genesisTime.offset

  waitFor node.initializeNetworking()

  if node.eth1Monitor != nil and node.shouldWeStartWeb3:
    node.eth1Monitor.start()

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
    let remainderStr = $remainder
    for i in remainderStr.len ..< 9:
      result.add '0'
    result.add remainderStr
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
        template justified: untyped = node.chainDag.head.atEpochStart(
          node.chainDag.headState.data.data.current_justified_checkpoint.epoch)
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
          shortLog(node.chainDag.head.root)
        of "head_epoch":
          $(node.chainDag.head.slot.epoch)
        of "head_epoch_slot":
          $(node.chainDag.head.slot mod SLOTS_PER_EPOCH)
        of "head_slot":
          $(node.chainDag.head.slot)

        of "justifed_root":
          shortLog(justified.blck.root)
        of "justifed_epoch":
          $(justified.slot.epoch)
        of "justifed_epoch_slot":
          $(justified.slot mod SLOTS_PER_EPOCH)
        of "justifed_slot":
          $(justified.slot)

        of "finalized_root":
          shortLog(node.chainDag.finalizedHead.blck.root)
        of "finalized_epoch":
          $(node.chainDag.finalizedHead.slot.epoch)
        of "finalized_epoch_slot":
          $(node.chainDag.finalizedHead.slot mod SLOTS_PER_EPOCH)
        of "finalized_slot":
          $(node.chainDag.finalizedHead.slot)

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
          formatGwei(node.attachedValidatorBalanceTotal)

        of "sync_status":
          if isNil(node.syncManager):
            "pending"
          else:
            if node.syncManager.inProgress:
              node.syncManager.syncStatus
            else:
              "synced"
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
          proc (logLevel: LogLevel, msg: LogOutputStr) {.raises: [Defect].} =
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
          erase statusBar
          render statusBar
          await sleepAsync(chronos.seconds(1))

      traceAsyncErrors statusBarUpdatesPollingLoop()

      # var t: Thread[ptr Prompt]
      # createThread(t, processPromptCommands, addr p)

proc handleValidatorExitCommand(config: BeaconNodeConf) {.async.} =
  let port = try:
    let value = parseInt(config.rpcUrlForExit.port)
    if value < Port.low.int or value > Port.high.int:
      raise newException(ValueError,
        "The port number must be between " & $Port.low & " and " & $Port.high)
    Port value
  except CatchableError as err:
    fatal "Invalid port number", err = err.msg
    quit 1

  let rpcClient = newRpcHttpClient()

  try:
    await connect(rpcClient, config.rpcUrlForExit.hostname, port)
  except CatchableError as err:
    fatal "Failed to connect to the beacon node RPC service", err = err.msg
    quit 1

  let (validator, validatorIdx, status, balance) = try:
    await rpcClient.get_v1_beacon_states_stateId_validators_validatorId(
      "head", config.exitedValidator)
  except CatchableError as err:
    fatal "Failed to obtain information for validator", err = err.msg
    quit 1

  let exitAtEpoch = if config.exitAtEpoch.isSome:
    Epoch config.exitAtEpoch.get
  else:
    let headSlot = try:
      await rpcClient.getBeaconHead()
    except CatchableError as err:
      fatal "Failed to obtain the current head slot", err = err.msg
      quit 1
    headSlot.epoch

  let
    validatorsDir = config.validatorsDir
    validatorKeyAsStr = "0x" & $validator.pubkey
    keystoreDir = validatorsDir / validatorKeyAsStr

  if not dirExists(keystoreDir):
    echo "The validator keystores directory '" & config.validatorsDir.string &
         "' does not contain a keystore for the selected validator with public " &
         "key '" & validatorKeyAsStr & "'."
    quit 1

  let signingKey = loadKeystore(
    validatorsDir,
    config.secretsDir,
    validatorKeyAsStr,
    config.getKeystoreFlags())

  if signingKey.isNone:
    fatal "Unable to continue without decrypted signing key"
    quit 1

  let fork = try:
    await rpcClient.get_v1_beacon_states_fork("head")
  except CatchableError as err:
    fatal "Failed to obtain the fork id of the head state", err = err.msg
    quit 1

  let genesisValidatorsRoot = try:
    (await rpcClient.get_v1_beacon_genesis()).genesis_validators_root
  except CatchableError as err:
    fatal "Failed to obtain the genesis validators root of the network",
           err = err.msg
    quit 1

  var signedExit = SignedVoluntaryExit(
    message: VoluntaryExit(
      epoch: exitAtEpoch,
      validator_index: validatorIdx))

  signedExit.signature = get_voluntary_exit_signature(
    fork, genesisValidatorsRoot, signedExit.message, signingKey.get)

  template ask(prompt: string): string =
    try:
      stdout.write prompt, ": "
      stdin.readLine()
    except IOError as err:
      fatal "Failed to read user input from stdin"
      quit 1

  try:
    echoP "PLEASE BEWARE!"

    echoP "Publishing a voluntary exit is an irreversible operation! " &
          "You won't be able to restart again with the same validator."

    echoP "By requesting an exit now, you'll be exempt from penalties " &
          "stemming from not performing your validator duties, but you " &
          "won't be able to withdraw your deposited funds for the time " &
          "being. This means that your funds will be effectively frozen " &
          "until withdrawals are enabled in a future phase of Eth2."


    echoP "To understand more about the Eth2 roadmap, we recommend you " &
          "have a look at\n" &
          "https://ethereum.org/en/eth2/#roadmap"

    echoP "You must keep your validator running for at least 5 epochs " &
          "(32 minutes) after requesting a validator exit, as you will " &
          "still be required to perform validator duties until your exit " &
          "has been processed. The number of epochs could be significantly " &
          "higher depending on how many other validators are queued to exit."

    echoP "As such, we recommend you keep track of your validator's status " &
          "using an Eth2 block explorer before shutting down your beacon node."

    const
      confirmation = "I understand the implications of submitting a voluntary exit"

    while true:
      echoP "To proceed to submitting your voluntary exit, please type '" &
            confirmation & "' (without the quotes) in the prompt below and " &
            "press ENTER or type 'q' to quit."
      echo ""

      let choice = ask "Your choice"
      if choice == "q":
        quit 0
      elif choice == confirmation:
        let success = await rpcClient.post_v1_beacon_pool_voluntary_exits(signedExit)
        if success:
          echo "Successfully published voluntary exit for validator " &
                $validatorIdx & "(" & validatorKeyAsStr[0..9] & ")."
          quit 0
        else:
          echo "The voluntary exit was not submitted successfully. Please try again."
          quit 1
  except CatchableError as err:
    fatal "Failed to send the signed exit message to the beacon node RPC",
           err = err.msg
    quit 1

programMain:
  var
    config = makeBannerAndConfig(clientId, BeaconNodeConf)
    # This is ref so we can mutate it (to erase it) after the initial loading.
    genesisStateContents: ref string
    genesisDepositsSnapshotContents: ref string
    eth1Network: Option[Eth1Network]
    depositContractAddress: Option[Eth1Address]
    depositContractDeployedAt: Option[BlockHashOrNumber]

  setupStdoutLogging(config.logLevel)

  if not(checkAndCreateDataDir(string(config.dataDir))):
    # We are unable to access/create data folder or data folder's
    # permissions are insecure.
    quit QuitFailure

  setupLogging(config.logLevel, config.logFile)

  ## This Ctrl+C handler exits the program in non-graceful way.
  ## It's responsible for handling Ctrl+C in sub-commands such
  ## as `wallets *` and `deposits *`. In a regular beacon node
  ## run, it will be overwritten later with a different handler
  ## performing a graceful exit.
  proc exitImmediatelyOnCtrlC() {.noconv.} =
    when defined(windows):
      # workaround for https://github.com/nim-lang/Nim/issues/4057
      setupForeignThreadGc()
    echo "" # If we interrupt during an interactive prompt, this
            # will move the cursor to the next line
    notice "Shutting down after having received SIGINT"
    quit 0
  setControlCHook(exitImmediatelyOnCtrlC)
  # equivalent SIGTERM handler
  when defined(posix):
    proc exitImmediatelyOnSIGTERM(signal: cint) {.noconv.} =
      notice "Shutting down after having received SIGTERM"
      quit 0
    c_signal(SIGTERM, exitImmediatelyOnSIGTERM)

  if config.eth2Network.isSome:
    let metadata = getMetadataForNetwork(config.eth2Network.get)
    config.runtimePreset = metadata.runtimePreset

    if config.cmd == noCommand:
      for node in mainnetMetadata.bootstrapNodes:
        config.bootstrapNodes.add node

      if metadata.genesisData.len > 0:
        genesisStateContents = newClone metadata.genesisData

      if metadata.genesisDepositsSnapshot.len > 0:
        genesisDepositsSnapshotContents = newClone metadata.genesisDepositsSnapshot

    depositContractAddress = some metadata.depositContractAddress
    depositContractDeployedAt = some metadata.depositContractDeployedAt
    eth1Network = metadata.eth1Network
  else:
    config.runtimePreset = defaultRuntimePreset
    when const_preset == "mainnet":
      if config.cmd == noCommand:
        depositContractAddress = some mainnetMetadata.depositContractAddress
        depositContractDeployedAt = some mainnetMetadata.depositContractDeployedAt

        for node in mainnetMetadata.bootstrapNodes:
          config.bootstrapNodes.add node

        genesisStateContents = newClone mainnetMetadata.genesisData
        genesisDepositsSnapshotContents = newClone mainnetMetadata.genesisDepositsSnapshot
        eth1Network = some mainnet

  # Single RNG instance for the application - will be seeded on construction
  # and avoid using system resources (such as urandom) after that
  let rng = keys.newRng()

  template findWalletWithoutErrors(name: WalletName): auto =
    let res = keystore_management.findWallet(config, name)
    if res.isErr:
      fatal "Failed to locate wallet", error = res.error
      quit 1
    res.get

  case config.cmd
  of createTestnet:
    let launchPadDeposits = try:
      Json.loadFile(config.testnetDepositsFile.string, seq[LaunchPadDeposit])
    except SerializationError as err:
      error "Invalid LaunchPad deposits file",
             err = formatMsg(err, config.testnetDepositsFile.string)
      quit 1

    var deposits: seq[DepositData]
    for i in config.firstValidator.int ..< launchPadDeposits.len:
      deposits.add(launchPadDeposits[i] as DepositData)

    let
      startTime = uint64(times.toUnix(times.getTime()) + config.genesisOffset)
      outGenesis = config.outputGenesis.string
      eth1Hash = if config.web3Url.len == 0: eth1BlockHash
                 else: (waitFor getEth1BlockHash(config.web3Url, blockId("latest"))).asEth2Digest
    var
      initialState = initialize_beacon_state_from_eth1(
        config.runtimePreset, eth1Hash, startTime, deposits, {skipBlsValidation})

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
        networkKeys = getPersistentNetKeys(rng[], config)
        netMetadata = getPersistentNetMetadata(config)
        bootstrapEnr = enr.Record.init(
          1, # sequence number
          networkKeys.seckey.asEthKey,
          some(config.bootstrapAddress),
          config.bootstrapPort,
          config.bootstrapPort,
          [toFieldPair("eth2", SSZ.encode(enrForkIdFromState initialState[])),
           toFieldPair("attnets", SSZ.encode(netMetadata.attnets))])

      writeFile(bootstrapFile, bootstrapEnr.tryGet().toURI)
      echo "Wrote ", bootstrapFile

  of noCommand:
    info "Launching beacon node",
          version = fullVersionStr,
          bls_backend = $BLS_BACKEND,
          cmdParams = commandLineParams(),
          config

    createPidFile(config.dataDir.string / "beacon_node.pid")

    config.createDumpDirs()

    if config.metricsEnabled:
      when useInsecureFeatures:
        let metricsAddress = config.metricsAddress
        notice "Starting metrics HTTP server",
          url = "http://" & $metricsAddress & ":" & $config.metricsPort & "/metrics"
        metrics.startHttpServer($metricsAddress, config.metricsPort)
      else:
        warn "Metrics support disabled, see https://status-im.github.io/nimbus-eth2/metrics-pretty-pictures.html#simple-metrics"

    if depositContractAddress.isNone or depositContractDeployedAt.isNone:
      echo "Please specify the a network through the --network option"
      quit 1

    # There are no managed event loops in here, to do a graceful shutdown, but
    # letting the default Ctrl+C handler exit is safe, since we only read from
    # the db.
    var node = waitFor BeaconNode.init(
      rng, config,
      depositContractAddress.get,
      depositContractDeployedAt.get,
      eth1Network,
      genesisStateContents,
      genesisDepositsSnapshotContents)

    if bnStatus == BeaconNodeStatus.Stopping:
      return

    # The memory for the initial snapshot won't be needed anymore
    if genesisStateContents != nil:
      genesisStateContents[] = ""
    if genesisDepositsSnapshotContents != nil:
      genesisDepositsSnapshotContents[] = ""

    when hasPrompt:
      initPrompt(node)

    if node.nickname != "":
      dynamicLogScope(node = node.nickname): node.start()
    else:
      node.start()

  of deposits:
    case config.depositsCmd
    #[
    of DepositsCmd.create:
      var seed: KeySeed
      defer: burnMem(seed)
      var walletPath: WalletPathPair

      if config.existingWalletId.isSome:
        let
          id = config.existingWalletId.get
          found = findWalletWithoutErrors(id)

        if found.isSome:
          walletPath = found.get
        else:
          fatal "Unable to find wallet with the specified name/uuid", id
          quit 1

        var unlocked = unlockWalletInteractively(walletPath.wallet)
        if unlocked.isOk:
          swap(seed, unlocked.get)
        else:
          # The failure will be reported in `unlockWalletInteractively`.
          quit 1
      else:
        var walletRes = createWalletInteractively(rng[], config)
        if walletRes.isErr:
          fatal "Unable to create wallet", err = walletRes.error
          quit 1
        else:
          swap(seed, walletRes.get.seed)
          walletPath = walletRes.get.walletPath

      let vres = secureCreatePath(config.outValidatorsDir)
      if vres.isErr():
        fatal "Could not create directory", path = config.outValidatorsDir
        quit QuitFailure

      let deposits = generateDeposits(
        config.runtimePreset,
        rng[],
        seed,
        walletPath.wallet.nextAccount,
        config.totalDeposits,
        config.outValidatorsDir,
        config.getKeystoreFlags())

      if deposits.isErr:
        fatal "Failed to generate deposits", err = deposits.error
        quit 1

      try:
        let depositDataPath = if config.outDepositsFile.isSome:
          config.outDepositsFile.get.string
        else:
          config.outValidatorsDir / "deposit_data-" & $epochTime() & ".json"

        let launchPadDeposits =
          mapIt(deposits.value, LaunchPadDeposit.init(config.runtimePreset, it))

        Json.saveFile(depositDataPath, launchPadDeposits)
        echo "Deposit data written to \"", depositDataPath, "\""

        walletPath.wallet.nextAccount += deposits.value.len
        let status = saveWallet(walletPath)
        if status.isErr:
          fatal "Failed to update wallet file after generating deposits",
                 wallet = walletPath.path,
                 error = status.error
          quit 1
      except CatchableError as err:
        fatal "Failed to create launchpad deposit data file", err = err.msg
        quit 1

    of DepositsCmd.status:
      echo "The status command is not implemented yet"
      quit 1

    #]#
    of DepositsCmd.`import`:
      let validatorKeysDir = if config.importedDepositsDir.isSome:
        config.importedDepositsDir.get
      else:
        let cwd = os.getCurrentDir()
        if dirExists(cwd / "validator_keys"):
          InputDir(cwd / "validator_keys")
        else:
          echo "The default search path for validator keys is a sub-directory " &
               "named 'validator_keys' in the current working directory. Since " &
               "no such directory exists, please either provide the correct path" &
               "as an argument or copy the imported keys in the expected location."
          quit 1

      importKeystoresFromDir(
        rng[],
        validatorKeysDir.string,
        config.validatorsDir, config.getKeystoreFlags())

    of DepositsCmd.exit:
      waitFor handleValidatorExitCommand(config)

  of wallets:
    case config.walletsCmd:
    of WalletsCmd.create:
      if config.createdWalletNameFlag.isSome:
        let
          name = config.createdWalletNameFlag.get
          existingWallet = findWalletWithoutErrors(name)
        if existingWallet.isSome:
          echo "The Wallet '" & name.string & "' already exists."
          quit 1

      var walletRes = createWalletInteractively(rng[], config)
      if walletRes.isErr:
        fatal "Unable to create wallet", err = walletRes.error
        quit 1
      burnMem(walletRes.get.seed)

    of WalletsCmd.list:
      for kind, walletFile in walkDir(config.walletsDir):
        if kind != pcFile: continue
        if checkSensitiveFilePermissions(walletFile):
          let walletRes = loadWallet(walletFile)
          if walletRes.isOk:
            echo walletRes.get.longName
          else:
            warn "Found corrupt wallet file",
                 wallet = walletFile, error = walletRes.error
        else:
          warn "Found wallet file with insecure permissions",
               wallet = walletFile

    of WalletsCmd.restore:
      restoreWalletInteractively(rng[], config)

  of record:
    case config.recordCmd:
    of RecordCmd.create:
      let netKeys = getPersistentNetKeys(rng[], config)

      var fieldPairs: seq[FieldPair]
      for field in config.fields:
        let fieldPair = field.split(":")
        if fieldPair.len > 1:
          fieldPairs.add(toFieldPair(fieldPair[0], hexToSeqByte(fieldPair[1])))
        else:
          fatal "Invalid field pair"
          quit QuitFailure

      let record = enr.Record.init(
        config.seqNumber,
        netKeys.seckey.asEthKey,
        some(config.ipExt),
        config.tcpPortExt,
        config.udpPortExt,
        fieldPairs).expect("Record within size limits")

      echo record.toURI()

    of RecordCmd.print:
      echo $config.recordPrint

  of web3:
    case config.web3Cmd:
    of Web3Cmd.test:
      waitFor testWeb3Provider(config.web3TestUrl,
                               depositContractAddress,
                               depositContractDeployedAt)

