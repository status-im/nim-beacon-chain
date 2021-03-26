# beacon_chain
# Copyright (c) 2018-2021 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  # Standard library
  std/[math, os, osproc, random, sequtils, strformat, strutils,
       tables, times, terminal],
  system/ansi_c,

  # Nimble packages
  stew/[objects, byteutils, endians2, io2], stew/shims/macros,
  chronos, confutils, metrics, metrics/chronos_httpserver,
  json_rpc/[rpcclient, rpcserver, jsonmarshal],
  chronicles, bearssl, blscurve,
  json_serialization/std/[options, sets, net], serialization/errors,

  eth/[keys, async_utils], eth/net/nat,
  eth/db/[kvstore, kvstore_sqlite3],
  eth/p2p/enode, eth/p2p/discoveryv5/[protocol, enr, random2],

  # Local modules
  "."/[
    beacon_chain_db,
    beacon_node_common, beacon_node_status, beacon_node_types, conf,
    extras, filepath, interop,
    nimbus_binary_common, ssz/merkleization, statusbar,
    beacon_clock, version],
  ./networking/[eth2_discovery, eth2_network, network_metadata],
  ./gossip_processing/[eth2_processor, gossip_to_consensus, consensus_manager],
  ./validators/[attestation_aggregation, validator_duties, validator_pool, slashing_protection, keystore_management],
  ./sync/[sync_manager, sync_protocol, request_manager],
  ./rpc/[beacon_api, config_api, debug_api, event_api, nimbus_api, node_api,
    validator_api],
  ./spec/[
    datatypes, digest, crypto, beaconstate, eth2_apis/beacon_rpc_client,
    helpers, network, presets, weak_subjectivity, signatures],
  ./consensus_object_pools/[
    blockchain_dag, block_quarantine, block_clearance, block_pools_types,
    attestation_pool, exit_pool, spec_cache],
  ./eth1/eth1_monitor

from eth/common/eth_types import BlockHashOrNumber

from
  libp2p/protocols/pubsub/gossipsub
import
  TopicParams, validateParameters, init

const
  hasPrompt = false and not defined(withoutPrompt) # disabled, doesn't work

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

declareGauge next_action_wait,
  "Seconds until the next attestation will be sent"

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
           runtimePreset: RuntimePreset,
           rng: ref BrHmacDrbgContext,
           config: BeaconNodeConf,
           depositContractAddress: Eth1Address,
           depositContractDeployedAt: BlockHashOrNumber,
           eth1Network: Option[Eth1Network],
           genesisStateContents: string,
           genesisDepositsSnapshotContents: string): BeaconNode =
  let
    db = BeaconChainDB.init(runtimePreset, config.databaseDir)

  var
    genesisState, checkpointState: ref BeaconState
    checkpointBlock: SignedBeaconBlock

  if config.finalizedCheckpointState.isSome:
    let checkpointStatePath = config.finalizedCheckpointState.get.string
    checkpointState = try:
      newClone(SSZ.loadFile(checkpointStatePath, BeaconState))
    except SerializationError as err:
      fatal "Checkpoint state deserialization failed",
            err = formatMsg(err, checkpointStatePath)
      quit 1
    except CatchableError as err:
      fatal "Failed to read checkpoint state file", err = err.msg
      quit 1

    if config.finalizedCheckpointBlock.isNone:
      if checkpointState.slot > 0:
        fatal "Specifying a non-genesis --finalized-checkpoint-state requires specifying --finalized-checkpoint-block as well"
        quit 1
    else:
      let checkpointBlockPath = config.finalizedCheckpointBlock.get.string
      try:
        checkpointBlock = SSZ.loadFile(checkpointBlockPath, SignedBeaconBlock)
      except SerializationError as err:
        fatal "Invalid checkpoint block", err = err.formatMsg(checkpointBlockPath)
        quit 1
      except IOError as err:
        fatal "Failed to load the checkpoint block", err = err.msg
        quit 1
  elif config.finalizedCheckpointBlock.isSome:
    # TODO We can download the state from somewhere in the future relying
    #      on the trusted `state_root` appearing in the checkpoint block.
    fatal "--finalized-checkpoint-block cannot be specified without --finalized-checkpoint-state"
    quit 1

  var eth1Monitor: Eth1Monitor
  if not ChainDAGRef.isInitialized(db):
    var
      tailState: ref BeaconState
      tailBlock: SignedBeaconBlock

    if genesisStateContents.len == 0 and checkpointState == nil:
      when hasGenesisDetection:
        if genesisDepositsSnapshotContents != nil:
          fatal "A deposits snapshot cannot be provided without also providing a matching beacon state snapshot"
          quit 1

        # This is a fresh start without a known genesis state
        # (most likely, it hasn't arrived yet). We'll try to
        # obtain a genesis through the Eth1 deposits monitor:
        if config.web3Url.len == 0:
          fatal "Web3 URL not specified"
          quit 1

        # TODO Could move this to a separate "GenesisMonitor" process or task
        #      that would do only this - see Paul's proposal for this.
        let eth1MonitorRes = waitFor Eth1Monitor.init(
          runtimePreset,
          db,
          config.web3Url,
          depositContractAddress,
          depositContractDeployedAt,
          eth1Network)

        if eth1MonitorRes.isErr:
          fatal "Failed to start Eth1 monitor",
                reason = eth1MonitorRes.error,
                web3Url = config.web3Url,
                depositContractAddress,
                depositContractDeployedAt
          quit 1
        else:
          eth1Monitor = eth1MonitorRes.get

        genesisState = waitFor eth1Monitor.waitGenesis()
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

    elif genesisStateContents.len == 0:
      if checkpointState.slot == GENESIS_SLOT:
        genesisState = checkpointState
        tailState = checkpointState
        tailBlock = get_initial_beacon_block(genesisState[])
      else:
        fatal "State checkpoints cannot be provided for a network without a known genesis state"
        quit 1
    else:
      try:
        genesisState = newClone(SSZ.decode(genesisStateContents, BeaconState))
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

  # Doesn't use std/random directly, but dependencies might
  randomize(rng[].rand(high(int)))

  info "Loading block dag from database", path = config.databaseDir

  let
    chainDagFlags = if config.verifyFinalization: {verifyFinalization}
                     else: {}
    chainDag = ChainDAGRef.init(runtimePreset, db, chainDagFlags)
    beaconClock = BeaconClock.init(chainDag.headState.data.data)
    quarantine = QuarantineRef.init(rng)
    databaseGenesisValidatorsRoot =
      chainDag.headState.data.data.genesis_validators_root

  if genesisStateContents.len != 0:
    let
      networkGenesisValidatorsRoot =
        extractGenesisValidatorRootFromSnapshop(genesisStateContents)

    if networkGenesisValidatorsRoot != databaseGenesisValidatorsRoot:
      fatal "The specified --data-dir contains data for a different network",
            networkGenesisValidatorsRoot, databaseGenesisValidatorsRoot,
            dataDir = config.dataDir
      quit 1

  if config.weakSubjectivityCheckpoint.isSome:
    let
      currentSlot = beaconClock.now.slotOrZero
      isCheckpointStale = not is_within_weak_subjectivity_period(
        currentSlot,
        chainDag.headState.data.data,
        config.weakSubjectivityCheckpoint.get)

    if isCheckpointStale:
      error "Weak subjectivity checkpoint is stale",
            currentSlot,
            checkpoint = config.weakSubjectivityCheckpoint.get,
            headStateSlot = chainDag.headState.data.data.slot
      quit 1

  if checkpointState != nil:
    let checkpointGenesisValidatorsRoot = checkpointState[].genesis_validators_root
    if checkpointGenesisValidatorsRoot != databaseGenesisValidatorsRoot:
      fatal "The specified checkpoint state is intended for a different network",
            checkpointGenesisValidatorsRoot, databaseGenesisValidatorsRoot,
            dataDir = config.dataDir
      quit 1

    chainDag.setTailState(checkpointState[], checkpointBlock)

  if eth1Monitor.isNil and
     config.web3Url.len > 0 and
     genesisDepositsSnapshotContents.len > 0:
    let genesisDepositsSnapshot = SSZ.decode(genesisDepositsSnapshotContents,
                                             DepositContractSnapshot)
    eth1Monitor = Eth1Monitor.init(
      runtimePreset,
      db,
      config.web3Url,
      depositContractAddress,
      genesisDepositsSnapshot,
      eth1Network)

  let rpcServer = if config.rpcEnabled:
    RpcServer.init(config.rpcAddress, config.rpcPort)
  else:
    nil

  let
    netKeys = getPersistentNetKeys(rng[], config)
    nickname = if config.nodeName == "auto": shortForm(netKeys)
               else: config.nodeName
    enrForkId = enrForkIdFromState(chainDag.headState.data.data)
    topicBeaconBlocks = getBeaconBlocksTopic(enrForkId.forkDigest)
    topicAggregateAndProofs = getAggregateAndProofsTopic(enrForkId.forkDigest)
    network = createEth2Node(rng, config, netKeys, enrForkId)
    attestationPool = newClone(AttestationPool.init(chainDag, quarantine))
    exitPool = newClone(ExitPool.init(chainDag, quarantine))

    slashingProtectionDB =
      case config.slashingDbKind
      of SlashingDbKind.v1:
        info "Loading slashing protection database", path = config.validatorsDir()
        SlashingProtectionDB.init(
          chainDag.headState.data.data.genesis_validators_root,
          config.validatorsDir(), "slashing_protection",
          modes = {kCompleteArchiveV1},
          disagreementBehavior = kChooseV1
        )
      of SlashingDbKind.v2:
        info "Loading slashing protection database (v2)", path = config.validatorsDir()
        SlashingProtectionDB.init(
          chainDag.headState.data.data.genesis_validators_root,
          config.validatorsDir(), "slashing_protection"
        )
      of SlashingDbKind.both:
        info "Loading slashing protection database (dual DB mode)", path = config.validatorsDir()
        SlashingProtectionDB.init(
          chainDag.headState.data.data.genesis_validators_root,
          config.validatorsDir(), "slashing_protection",
          modes = {kCompleteArchiveV1, kCompleteArchiveV2},
          disagreementBehavior = kChooseV2
        )
    validatorPool = newClone(ValidatorPool.init(slashingProtectionDB))

    consensusManager = ConsensusManager.new(
      chainDag, attestationPool, quarantine
    )
    verifQueues = VerifQueueManager.new(
      config, consensusManager,
      proc(): BeaconTime = beaconClock.now())
    processor = Eth2Processor.new(
      config,
      verifQueues,
      chainDag, attestationPool, exitPool, validatorPool,
      quarantine,
      proc(): BeaconTime = beaconClock.now())

  var res = BeaconNode(
    nickname: nickname,
    graffitiBytes: if config.graffiti.isSome: config.graffiti.get.GraffitiBytes
                   else: defaultGraffitiBytes(),
    network: network,
    netKeys: netKeys,
    db: db,
    config: config,
    chainDag: chainDag,
    quarantine: quarantine,
    attestationPool: attestationPool,
    attachedValidators: validatorPool,
    exitPool: exitPool,
    eth1Monitor: eth1Monitor,
    beaconClock: beaconClock,
    rpcServer: rpcServer,
    forkDigest: enrForkId.forkDigest,
    topicBeaconBlocks: topicBeaconBlocks,
    topicAggregateAndProofs: topicAggregateAndProofs,
    processor: processor,
    verifQueues: verifQueues,
    consensusManager: consensusManager,
    requestManager: RequestManager.init(network, verifQueues)
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
  # https://github.com/ethereum/eth2.0-specs/blob/v1.0.1/specs/phase0/p2p-interface.md#attestations-and-aggregation
  # properly applying parameters to subnets is hard and requires research and dynamic adjustments based on the number of validators
  # for now the best and easiest strategy is to use some parameters, which is better then no parameters at all and so no scoring
  # applying aggregate parameters seems to work the best, further research will be necessary
  const
    subnetsParams = TopicParams(
      topicWeight: 0.01,
      timeInMeshWeight: 0.03333333333333333,
      timeInMeshQuantum: chronos.seconds(12),
      timeInMeshCap: 300,
      firstMessageDeliveriesWeight: 0.8611923631641919,
      firstMessageDeliveriesDecay: 0.8659643233600653,
      firstMessageDeliveriesCap: 46.44723027156447,
      meshMessageDeliveriesWeight: -37.221277470375405,
      meshMessageDeliveriesDecay: 0.9646616199111993,
      meshMessageDeliveriesThreshold: 13.595606364013024,
      meshMessageDeliveriesCap: 217.5297018242084,
      meshMessageDeliveriesActivation: chronos.seconds(204),
      meshMessageDeliveriesWindow: chronos.seconds(2),
      meshFailurePenaltyWeight: -37.221277470375405,
      meshFailurePenaltyDecay: 0.9646616199111993,
      invalidMessageDeliveriesWeight: -6879.999999999998,
      invalidMessageDeliveriesDecay: 0.9971259067705325
    )

  static:
    subnetsParams.validateParameters().tryGet()

  for subnet in subnets:
    node.network.subscribe(getAttestationTopic(node.forkDigest, subnet), subnetsParams) # don't score attestation subnets for now

proc updateStabilitySubnetMetadata(
    node: BeaconNode, stabilitySubnets: set[uint8]) =
  # https://github.com/ethereum/eth2.0-specs/blob/v1.0.1/specs/phase0/p2p-interface.md#metadata
  node.network.metadata.seq_number += 1
  for subnet in 0'u8 ..< ATTESTATION_SUBNET_COUNT:
    node.network.metadata.attnets[subnet] = (subnet in stabilitySubnets)

  # https://github.com/ethereum/eth2.0-specs/blob/v1.0.1/specs/phase0/validator.md#phase-0-attestation-subnet-stability
  # https://github.com/ethereum/eth2.0-specs/blob/v1.0.1/specs/phase0/p2p-interface.md#attestation-subnet-bitfield
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

proc getAttachedValidators(node: BeaconNode):
    Table[ValidatorIndex, AttachedValidator] =
  for validatorIndex in 0 ..< node.chainDag.headState.data.data.validators.len:
    let attachedValidator = node.getAttachedValidator(
      node.chainDag.headState.data.data, validatorIndex.ValidatorIndex)
    if attachedValidator.isNil:
      continue
    result[validatorIndex.ValidatorIndex] = attachedValidator

proc updateSubscriptionSchedule(node: BeaconNode, epoch: Epoch) {.async.} =
  doAssert epoch >= 1
  let
    attachedValidators = node.getAttachedValidators()
    validatorIndices = toIntSet(toSeq(attachedValidators.keys()))

  var cache = StateCache()

  # https://github.com/ethereum/eth2.0-specs/blob/v1.0.1/specs/phase0/validator.md#lookahead
  # Only subscribe when this node should aggregate; libp2p broadcasting works
  # on subnet topics regardless.
  let epochRef = node.chainDag.getEpochRef(node.chainDag.head, epoch)

  # Update proposals
  node.attestationSubnets.proposingSlots[epoch mod 2] = 0
  for i in 0 ..< SLOTS_PER_EPOCH:
    let beaconProposer = epochRef.beacon_proposers[i]
    if beaconProposer.isSome and beaconProposer.get()[0] in attachedValidators:
      node.attestationsubnets.proposingSlots[epoch mod 2] =
        node.attestationsubnets.proposingSlots[epoch mod 2] or (1'u32 shl i)

  # Update attestations
  template isAnyCommitteeValidatorAggregating(
      validatorIndices, committeeLen: untyped, slot: Slot): bool =
    anyIt(
      validatorIndices,
      is_aggregator(
        committeeLen,
        await attachedValidators[it.ValidatorIndex].getSlotSig(
          node.chainDag.headState.data.data.fork,
          node.chainDag.headState.data.data.genesis_validators_root, slot)))

  node.attestationSubnets.lastCalculatedEpoch = epoch
  node.attestationSubnets.attestingSlots[epoch mod 2] = 0

  # The relevant bitmaps are 32 bits each.
  static: doAssert SLOTS_PER_EPOCH <= 32

  for (validatorIndices, committeeIndex, subnetIndex, slot) in
      get_committee_assignments(
        node.chainDag.headState.data.data, epoch, validatorIndices, cache):

    doAssert compute_epoch_at_slot(slot) == epoch

    # Each get_committee_assignments() call here is on the next epoch. At any
    # given time, only care about two epochs, the current and next epoch. So,
    # after it is done for an epoch, [aS[epoch mod 2], aS[1 - (epoch mod 2)]]
    # provides, sequentially, the current and next epochs' slot schedules. If
    # get_committee_assignments() has not been called for the next epoch yet,
    # typically because there hasn't been a block in the current epoch, there
    # isn't valid information in aS[1 - (epoch mod 2)], and only slots within
    # the current epoch can be known. Usually, this is not a major issue, but
    # when there hasn't been a block substantially through an epoch, it might
    # prove misleading to claim that there aren't attestations known, when it
    # only might be known either way for 3 more slots. However, it's also not
    # as important to attest when blocks aren't flowing as only attestions in
    # blocks garner rewards.
    node.attestationSubnets.attestingSlots[epoch mod 2] =
      node.attestationSubnets.attestingSlots[epoch mod 2] or
        (1'u32 shl (slot mod SLOTS_PER_EPOCH))

    if not isAnyCommitteeValidatorAggregating(
        validatorIndices,
        get_beacon_committee_len(epochRef, slot, committeeIndex), slot):
      continue

    node.attestationSubnets.unsubscribeSlot[subnetIndex] =
      max(slot + 1, node.attestationSubnets.unsubscribeSlot[subnetIndex])
    if subnetIndex notin node.attestationSubnets.subscribedSubnets:
      const SUBNET_SUBSCRIPTION_LEAD_TIME_SLOTS = 34

      node.attestationSubnets.subscribeSlot[subnetIndex] =
        # Queue upcoming subscription potentially earlier
        # SLOTS_PER_EPOCH emulates one boundary condition of the per-epoch
        # cycling mechanism timing buffers
        min(
          slot - min(slot.uint64, SUBNET_SUBSCRIPTION_LEAD_TIME_SLOTS),
          node.attestationSubnets.subscribeSlot[subnetIndex])

# https://github.com/ethereum/eth2.0-specs/blob/v1.0.1/specs/phase0/validator.md#phase-0-attestation-subnet-stability
func getStabilitySubnetLength(node: BeaconNode): uint64 =
  EPOCHS_PER_RANDOM_SUBNET_SUBSCRIPTION +
    node.network.rng[].rand(EPOCHS_PER_RANDOM_SUBNET_SUBSCRIPTION.int).uint64

func updateStabilitySubnets(node: BeaconNode, slot: Slot): set[uint8] =
  # Equivalent to wallSlot by cycleAttestationSubnets(), especially
  # since it'll try to run early in epochs, avoiding race conditions.
  static: doAssert ATTESTATION_SUBNET_COUNT <= high(uint8)
  let epoch = slot.epoch

  # https://github.com/ethereum/eth2.0-specs/blob/v1.0.1/specs/phase0/validator.md#phase-0-attestation-subnet-stability
  for i in 0 ..< node.attestationSubnets.stabilitySubnets.len:
    if epoch >= node.attestationSubnets.stabilitySubnets[i].expiration:
      node.attestationSubnets.stabilitySubnets[i].subnet =
        node.network.rng[].rand(ATTESTATION_SUBNET_COUNT - 1).uint8
      node.attestationSubnets.stabilitySubnets[i].expiration =
        epoch + node.getStabilitySubnetLength()

    result.incl node.attestationSubnets.stabilitySubnets[i].subnet

proc cycleAttestationSubnetsPerEpoch(
    node: BeaconNode, wallSlot: Slot, prevStabilitySubnets: set[uint8]):
    Future[set[uint8]] {.async.} =
  # Per-epoch portion of subnet cycling: updating stability subnets and
  # calculating future attestation subnets.

  # Only know RANDAO mix, which determines shuffling seed, one epoch in
  # advance. When node.chainDag.headState.data.data.slot.epoch is ahead
  # of wallSlot, the clock's just incorrect. If the state slot's behind
  # wallSlot, it would have to look more than MIN_SEED_LOOKAHEAD epochs
  # ahead to compute the shuffling determining the beacon committees.
  static: doAssert MIN_SEED_LOOKAHEAD == 1
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
    await node.updateSubscriptionSchedule(wallSlot.epoch + 1)
  node.attestationSubnets.nextCycleEpoch = wallSlot.epoch + 1

  let stabilitySubnets = node.updateStabilitySubnets(wallSlot)

  if  not node.config.subscribeAllSubnets and
      stabilitySubnets != prevStabilitySubnets:
    # In subscribeAllSubnets mode, this only gets set once, at initial subnet
    # attestation handler creation, since they're all considered as stability
    # subnets in that case.
    node.updateStabilitySubnetMetadata(stabilitySubnets)

  return stabilitySubnets

proc cycleAttestationSubnets(node: BeaconNode, wallSlot: Slot) {.async.} =
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
      await node.cycleAttestationSubnetsPerEpoch(wallSlot, prevStabilitySubnets)

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
    validatorIndices = toIntSet(toSeq(node.getAttachedValidators().keys()))

  var cache = StateCache()

  template mergeAttestationSubnets(epoch: Epoch) =
    # TODO when https://github.com/nim-lang/Nim/issues/15972 and
    # https://github.com/nim-lang/Nim/issues/16217 are fixed, in
    # Nimbus's Nim, use (_, _, subnetIndex, slot).
    for (_, ci, subnetIndex, slot) in get_committee_assignments(
        node.chainDag.headState.data.data, epoch, validatorIndices, cache):
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
  # https://github.com/ethereum/eth2.0-specs/blob/v1.0.1/specs/phase0/validator.md#phase-0-attestation-subnet-stability
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
    node.attachedValidators[].count)
  for i in 0 ..< node.attachedValidators[].count:
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
  # inspired by lighthouse research here
  # https://gist.github.com/blacktemplar/5c1862cb3f0e32a1a7fb0b25e79e6e2c#file-generate-scoring-params-py
  const
    blocksTopicParams = TopicParams(
      topicWeight: 0.5,
      timeInMeshWeight: 0.03333333333333333,
      timeInMeshQuantum: chronos.seconds(12),
      timeInMeshCap: 300,
      firstMessageDeliveriesWeight: 1.1471603557060206,
      firstMessageDeliveriesDecay: 0.9928302477768374,
      firstMessageDeliveriesCap: 34.86870846001471,
      meshMessageDeliveriesWeight: -458.31054878249114,
      meshMessageDeliveriesDecay: 0.9716279515771061,
      meshMessageDeliveriesThreshold: 0.6849191409056553,
      meshMessageDeliveriesCap: 2.054757422716966,
      meshMessageDeliveriesActivation: chronos.seconds(384),
      meshMessageDeliveriesWindow: chronos.seconds(2),
      meshFailurePenaltyWeight: -458.31054878249114 ,
      meshFailurePenaltyDecay: 0.9716279515771061,
      invalidMessageDeliveriesWeight: -214.99999999999994,
      invalidMessageDeliveriesDecay: 0.9971259067705325
    )
    aggregateTopicParams = TopicParams(
      topicWeight: 0.5,
      timeInMeshWeight: 0.03333333333333333,
      timeInMeshQuantum: chronos.seconds(12),
      timeInMeshCap: 300,
      firstMessageDeliveriesWeight: 0.10764904539552399,
      firstMessageDeliveriesDecay: 0.8659643233600653,
      firstMessageDeliveriesCap: 371.5778421725158,
      meshMessageDeliveriesWeight: -0.07538533073670682,
      meshMessageDeliveriesDecay: 0.930572040929699,
      meshMessageDeliveriesThreshold: 53.404248450179836,
      meshMessageDeliveriesCap: 213.61699380071934,
      meshMessageDeliveriesActivation: chronos.seconds(384),
      meshMessageDeliveriesWindow: chronos.seconds(2),
      meshFailurePenaltyWeight: -0.07538533073670682 ,
      meshFailurePenaltyDecay: 0.930572040929699,
      invalidMessageDeliveriesWeight: -214.99999999999994,
      invalidMessageDeliveriesDecay: 0.9971259067705325
    )
    basicParams = TopicParams.init()

  static:
    # compile time validation
    blocksTopicParams.validateParameters().tryGet()
    aggregateTopicParams.validateParameters().tryGet()
    basicParams.validateParameters.tryGet()

  node.network.subscribe(node.topicBeaconBlocks, blocksTopicParams, enableTopicMetrics = true)
  node.network.subscribe(getAttesterSlashingsTopic(node.forkDigest), basicParams)
  node.network.subscribe(getProposerSlashingsTopic(node.forkDigest), basicParams)
  node.network.subscribe(getVoluntaryExitsTopic(node.forkDigest), basicParams)
  node.network.subscribe(getAggregateAndProofsTopic(node.forkDigest), aggregateTopicParams, enableTopicMetrics = true)
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

proc setupDoppelgangerDetection(node: BeaconNode, slot: Slot) =
  # When another client's already running, this is very likely to detect
  # potential duplicate validators, which can trigger slashing.
  #
  # Every missed attestation costs approximately 3*get_base_reward(), which
  # can be up to around 10,000 Wei. Thus, skipping attestations isn't cheap
  # and one should gauge the likelihood of this simultaneous launch to tune
  # the epoch delay to one's perceived risk.
  const duplicateValidatorEpochs = 2

  node.processor.doppelgangerDetection.broadcastStartEpoch =
    slot.epoch + duplicateValidatorEpochs
  debug "Setting up doppelganger protection",
    epoch = slot.epoch,
    broadcastStartEpoch =
      node.processor.doppelgangerDetection.broadcastStartEpoch

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

    node.setupDoppelgangerDetection(slot)
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
    traceAsyncErrors node.cycleAttestationSubnets(slot)

func getNextValidatorAction(
    actionSlotSource: auto, lastCalculatedEpoch: Epoch, slot: Slot): Slot =
  # The relevant actions are in, depending on calculated bounds:
  # [aS[epoch mod 2], aS[1 - (epoch mod 2)]]
  #  current epoch          next epoch
  let orderedActionSlots = [
    actionSlotSource[     slot.epoch mod 2'u64],
    actionSlotSource[1 - (slot.epoch mod 2'u64)]]

  static: doAssert MIN_ATTESTATION_INCLUSION_DELAY == 1

  # Cleverer ways exist, but a short loop is fine. O(n) vs O(log n) isn't that
  # important when n is 32 or 64, with early exit on average no more than half
  # through.
  for i in [0'u64, 1'u64]:
    let bitmapEpoch = slot.epoch + i

    if bitmapEpoch > lastCalculatedEpoch:
      return FAR_FUTURE_SLOT

    for slotOffset in 0 ..< SLOTS_PER_EPOCH:
      let nextActionSlot =
        compute_start_slot_at_epoch(bitmapEpoch) + slotOffset
      if ((orderedActionSlots[i] and (1'u32 shl slotOffset)) != 0) and
          nextActionSlot > slot:
        return nextActionSlot

  FAR_FUTURE_SLOT

proc onSlotEnd(node: BeaconNode, slot: Slot) {.async.} =
  # Things we do when slot processing has ended and we're about to wait for the
  # next slot

  # Delay part of pruning until latency critical duties are done.
  # The other part of pruning, `pruneBlocksDAG`, is done eagerly.
  node.consensusManager[].pruneStateCachesAndForkChoice()

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

  # -1 is a more useful output than 18446744073709551615 as an indicator of
  # no future attestation/proposal known.
  template displayInt64(x: Slot): int64 =
    if x == high(uint64).Slot:
      -1'i64
    else:
      toGaugeValue(x)

  let
    nextAttestationSlot = getNextValidatorAction(
      node.attestationSubnets.attestingSlots,
      node.attestationSubnets.lastCalculatedEpoch, slot)
    nextProposalSlot = getNextValidatorAction(
      node.attestationSubnets.proposingSlots,
      node.attestationSubnets.lastCalculatedEpoch, slot)
    nextActionWaitTime = saturate(fromNow(
      node.beaconClock, min(nextAttestationSlot, nextProposalSlot)))

  info "Slot end",
    slot = shortLog(slot),
    nextSlot = shortLog(slot + 1),
    head = shortLog(node.chainDag.head),
    headEpoch = shortLog(node.chainDag.head.slot.compute_epoch_at_slot()),
    finalizedHead = shortLog(node.chainDag.finalizedHead.blck),
    finalizedEpoch =
      shortLog(node.chainDag.finalizedHead.blck.slot.compute_epoch_at_slot()),
    nextAttestationSlot = displayInt64(nextAttestationSlot),
    nextProposalSlot = displayInt64(nextProposalSlot),
    nextActionWait =
      if nextAttestationSlot == FAR_FUTURE_SLOT:
        "n/a"
      else:
        shortLog(nextActionWaitTime)

  if nextAttestationSlot != FAR_FUTURE_SLOT:
    next_action_wait.set(nextActionWaitTime.toFloatSeconds)

  node.updateGossipStatus(slot)

proc onSlotStart(
    node: BeaconNode, wallTime: BeaconTime, lastSlot: Slot) {.async.} =
  ## Called at the beginning of a slot - usually every slot, but sometimes might
  ## skip a few in case we're running late.
  ## wallTime: current system time - we will strive to perform all duties up
  ##           to this point in time
  ## lastSlot: the last slot that we successfully processed, so we know where to
  ##           start work from - there might be jumps if processing is delayed
  let
    # The slot we should be at, according to the clock
    wallSlot = wallTime.slotOrZero
    # If everything was working perfectly, the slot that we should be processing
    expectedSlot = lastSlot + 1
    finalizedEpoch =
      node.chainDag.finalizedHead.blck.slot.compute_epoch_at_slot()
    delay = wallTime - expectedSlot.toBeaconTime()

  info "Slot start",
    lastSlot = shortLog(lastSlot),
    wallSlot = shortLog(wallSlot),
    delay = shortLog(delay),
    peers = len(node.network.peerPool),
    head = shortLog(node.chainDag.head),
    headEpoch = shortLog(node.chainDag.head.slot.compute_epoch_at_slot()),
    finalized = shortLog(node.chainDag.finalizedHead.blck),
    finalizedEpoch = shortLog(finalizedEpoch),
    sync =
      if node.syncManager.inProgress: node.syncManager.syncStatus
      else: "synced"

  # Check before any re-scheduling of onSlotStart()
  checkIfShouldStopAtEpoch(wallSlot, node.config.stopAtEpoch)

  beacon_slot.set wallSlot.toGaugeValue
  beacon_current_epoch.set wallSlot.epoch.toGaugeValue

  # both non-negative, so difference can't overflow or underflow int64
  finalization_delay.set(
    wallSlot.epoch.toGaugeValue - finalizedEpoch.toGaugeValue)

  if node.config.verifyFinalization:
    verifyFinalization(node, wallSlot)

  node.consensusManager[].updateHead(wallSlot)

  await node.handleValidatorDuties(lastSlot, wallSlot)

  await onSlotEnd(node, wallSlot)

proc runSlotLoop(node: BeaconNode, startTime: BeaconTime) {.async.} =
  var
    curSlot = startTime.slotOrZero()
    nextSlot = curSlot + 1 # No earlier than GENESIS_SLOT + 1
    timeToNextSlot = nextSlot.toBeaconTime() - startTime

  info "Scheduling first slot action",
    startTime = shortLog(startTime),
    nextSlot = shortLog(nextSlot),
    timeToNextSlot = shortLog(timeToNextSlot)

  while true:
    # Start by waiting for the time when the slot starts. Sleeping relinquishes
    # control to other tasks which may or may not finish within the alotted
    # time, so below, we need to be wary that the ship might have sailed
    # already.
    await sleepAsync(timeToNextSlot)

    let
      wallTime = node.beaconClock.now()
      wallSlot = wallTime.slotOrZero() # Always > GENESIS!

    if wallSlot < nextSlot:
      # While we were sleeping, the system clock changed and time moved
      # backwards!
      if wallSlot + 1 < nextSlot:
        # This is a critical condition where it's hard to reason about what
        # to do next - we'll call the attention of the user here by shutting
        # down.
        fatal "System time adjusted backwards significantly - clock may be inaccurate - shutting down",
          nextSlot = shortLog(nextSlot),
          wallSlot = shortLog(wallSlot)
        bnStatus = BeaconNodeStatus.Stopping
        return

      # Time moved back by a single slot - this could be a minor adjustment,
      # for example when NTP does its thing after not working for a while
      warn "System time adjusted backwards, rescheduling slot actions",
        wallTime = shortLog(wallTime),
        nextSlot = shortLog(nextSlot),
        wallSlot = shortLog(wallSlot)

      # cur & next slot remain the same
      timeToNextSlot = nextSlot.toBeaconTime() - wallTime
      continue

    if wallSlot > nextSlot + SLOTS_PER_EPOCH:
      # Time moved forwards by more than an epoch - either the clock was reset
      # or we've been stuck in processing for a long time - either way, we will
      # skip ahead so that we only process the events of the last
      # SLOTS_PER_EPOCH slots
      warn "Time moved forwards by more than an epoch, skipping ahead",
        curSlot = shortLog(curSlot),
        nextSlot = shortLog(nextSlot),
        wallSlot = shortLog(wallSlot)

      curSlot = wallSlot - SLOTS_PER_EPOCH

    elif wallSlot > nextSlot:
        notice "Missed expected slot start, catching up",
          delay = shortLog(wallTime - nextSlot.toBeaconTime()),
          curSlot = shortLog(curSlot),
          nextSlot = shortLog(curSlot)

    await onSlotStart(node, wallTime, curSlot)

    curSlot = wallSlot
    nextSlot = wallSlot + 1
    timeToNextSlot = saturate(node.beaconClock.fromNow(nextSlot))

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
        asyncSpawn(try: peer.disconnect(PeerScoreLow)
        except Exception as exc: raiseAssert exc.msg) # Shouldn't actually happen!
      else:
        debug "Peer was removed from PeerPool", peer = peer,
              peer_score = peer.score, score_low_limit = PeerScoreLowLimit,
              score_high_limit = PeerScoreHighLimit
        asyncSpawn(try: peer.disconnect(FaultOrError)
        except Exception as exc: raiseAssert exc.msg) # Shouldn't actually happen!

  node.network.peerPool.setScoreCheck(scoreCheck)
  node.network.peerPool.setOnDeletePeer(onDeletePeer)

  node.syncManager = newSyncManager[Peer, PeerID](
    node.network.peerPool, getLocalHeadSlot, getLocalWallSlot,
    getFirstSlotAtFinalizedEpoch, node.verifQueues, chunkSize = 32
  )
  node.syncManager.start()

func connectedPeersCount(node: BeaconNode): int =
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
  # https://github.com/ethereum/eth2.0-specs/blob/v1.0.1/specs/phase0/p2p-interface.md#attestations-and-aggregation
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

    let startTime = node.beaconClock.now()
    asyncSpawn runSlotLoop(node, startTime)
    asyncSpawn runOnSecondLoop(node)
    asyncSpawn runQueueProcessingLoop(node.verifQueues)

    node.requestManager.start()
    node.startSyncManager()

    if not startTime.toSlot().afterGenesis:
      node.setupDoppelgangerDetection(startTime.slotOrZero())
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
  (node.config.web3Mode == Web3Mode.auto and node.attachedValidators[].count > 0)

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
    validators = node.attachedValidators[].count

  if genesisTime.inFuture:
    notice "Waiting for genesis", genesisIn = genesisTime.offset

  waitFor node.initializeNetworking()

  # TODO this does not account for validators getting attached "later"
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

proc initStatusBar(node: BeaconNode) =
  if not isatty(stdout): return
  if not node.config.statusBarEnabled: return

  enableTrueColors()

  proc dataResolver(expr: string): string {.raises: [Defect].} =
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
    try:
      while true:
        update statusBar
        erase statusBar
        render statusBar
        await sleepAsync(chronos.seconds(1))
    except CatchableError as exc:
      warn "Failed to update status bar, no further updates", err = exc.msg

  asyncSpawn statusBarUpdatesPollingLoop()

when hasPrompt:
  # TODO: nim-prompt seems to have threading issues at the moment
  #       which result in sporadic crashes. We should introduce a
  #       lock that guards the access to the internal prompt line
  #       variable.
  #
  # var p = Prompt.init("nimbus > ", providePromptCompletions)
  # p.useHistoryFile()

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
    # var t: Thread[ptr Prompt]
    # createThread(t, processPromptCommands, addr p)
    discard

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

  let (validator, validatorIdx, _, _) = try:
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
    config.nonInteractive)

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
    except IOError:
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

proc loadEth2Network(config: BeaconNodeConf): Eth2NetworkMetadata =
  if config.eth2Network.isSome:
    getMetadataForNetwork(config.eth2Network.get)
  else:
    when const_preset == "mainnet":
      mainnetMetadata
    else:
      # Presumably other configurations can have other defaults, but for now
      # this simplifies the flow
      echo "Must specify network on non-mainnet node"
      quit 1

proc loadBeaconNode(config: var BeaconNodeConf, rng: ref BrHmacDrbgContext): BeaconNode =
  let metadata = config.loadEth2Network()

  # Updating the config based on the metadata certainly is not beautiful but it
  # works
  for node in metadata.bootstrapNodes:
    config.bootstrapNodes.add node

  BeaconNode.init(
    metadata.runtimePreset,
    rng,
    config,
    metadata.depositContractAddress,
    metadata.depositContractDeployedAt,
    metadata.eth1Network,
    metadata.genesisData,
    metadata.genesisDepositsSnapshot)

proc doRunBeaconNode(config: var BeaconNodeConf, rng: ref BrHmacDrbgContext) =
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
      startMetricsHttpServer($metricsAddress, config.metricsPort)
    else:
      warn "Metrics support disabled, see https://status-im.github.io/nimbus-eth2/metrics-pretty-pictures.html#simple-metrics"

  # There are no managed event loops in here, to do a graceful shutdown, but
  # letting the default Ctrl+C handler exit is safe, since we only read from
  # the db.
  let node = loadBeaconNode(config, rng)

  if bnStatus == BeaconNodeStatus.Stopping:
    return

  initStatusBar(node)

  when hasPrompt:
    initPrompt(node)

  if node.nickname != "":
    dynamicLogScope(node = node.nickname): node.start()
  else:
    node.start()

proc doCreateTestnet(config: BeaconNodeConf, rng: var BrHmacDrbgContext) =
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
    runtimePreset = getRuntimePresetForNetwork(config.eth2Network)
  var
    initialState = initialize_beacon_state_from_eth1(
      runtimePreset, eth1Hash, startTime, deposits, {skipBlsValidation})

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
      networkKeys = getPersistentNetKeys(rng, config)
      netMetadata = getPersistentNetMetadata(config)
      bootstrapEnr = enr.Record.init(
        1, # sequence number
        networkKeys.seckey.asEthKey,
        some(config.bootstrapAddress),
        some(config.bootstrapPort),
        some(config.bootstrapPort),
        [toFieldPair("eth2", SSZ.encode(enrForkIdFromState initialState[])),
        toFieldPair("attnets", SSZ.encode(netMetadata.attnets))])

    writeFile(bootstrapFile, bootstrapEnr.tryGet().toURI)
    echo "Wrote ", bootstrapFile

proc doDeposits(config: BeaconNodeConf, rng: var BrHmacDrbgContext) =
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

    let sres = secureCreatePath(config.outSecretsDir)
    if sres.isErr():
      fatal "Could not create directory", path = config.outSecretsDir
      quit QuitFailure

    let deposits = generateDeposits(
      runtimePreset,
      rng[],
      seed,
      walletPath.wallet.nextAccount,
      config.totalDeposits,
      config.outValidatorsDir,
      config.outSecretsDir)

    if deposits.isErr:
      fatal "Failed to generate deposits", err = deposits.error
      quit 1

    try:
      let depositDataPath = if config.outDepositsFile.isSome:
        config.outDepositsFile.get.string
      else:
        config.outValidatorsDir / "deposit_data-" & $epochTime() & ".json"

      let launchPadDeposits =
        mapIt(deposits.value, LaunchPadDeposit.init(runtimePreset, it))

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
      rng,
      validatorKeysDir.string,
      config.validatorsDir, config.secretsDir)

  of DepositsCmd.exit:
    waitFor handleValidatorExitCommand(config)

proc doWallets(config: BeaconNodeConf, rng: var BrHmacDrbgContext) =
  template findWalletWithoutErrors(name: WalletName): auto =
    let res = keystore_management.findWallet(config, name)
    if res.isErr:
      fatal "Failed to locate wallet", error = res.error
      quit 1
    res.get

  case config.walletsCmd:
  of WalletsCmd.create:
    if config.createdWalletNameFlag.isSome:
      let
        name = config.createdWalletNameFlag.get
        existingWallet = findWalletWithoutErrors(name)
      if existingWallet.isSome:
        echo "The Wallet '" & name.string & "' already exists."
        quit 1

    var walletRes = createWalletInteractively(rng, config)
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
    restoreWalletInteractively(rng, config)

proc doRecord(config: BeaconNodeConf, rng: var BrHmacDrbgContext) =
  case config.recordCmd:
  of RecordCmd.create:
    let netKeys = getPersistentNetKeys(rng, config)

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
      some(config.tcpPortExt),
      some(config.udpPortExt),
      fieldPairs).expect("Record within size limits")

    echo record.toURI()

  of RecordCmd.print:
    echo $config.recordPrint

proc doWeb3Cmd(config: BeaconNodeConf) =
  case config.web3Cmd:
  of Web3Cmd.test:
    let metadata = config.loadEth2Network()
    waitFor testWeb3Provider(config.web3TestUrl,
                             metadata.depositContractAddress)

programMain:
  var
    config = makeBannerAndConfig(clientId, BeaconNodeConf)

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
    # in case a password prompt disabled echoing
    resetStdin()
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

  # Single RNG instance for the application - will be seeded on construction
  # and avoid using system resources (such as urandom) after that
  let rng = keys.newRng()

  case config.cmd
  of createTestnet: doCreateTestnet(config, rng[])
  of noCommand: doRunBeaconNode(config, rng)
  of deposits: doDeposits(config, rng[])
  of wallets: doWallets(config, rng[])
  of record: doRecord(config, rng[])
  of web3: doWeb3Cmd(config)
