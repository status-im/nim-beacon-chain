import std/[tables, os, sequtils, strutils]
import chronos, presto, presto/client as presto_client, chronicles, confutils,
       json_serialization/std/[options, net],
       stew/[base10, results]
# Local modules
import ".."/networking/[eth2_network, eth2_discovery],
       ".."/spec/[datatypes, digest, crypto, helpers, signatures],
       ".."/rpc/[beacon_rest_api, node_rest_api, validator_rest_api,
                 config_rest_api, rest_utils, eth2_json_rest_serialization],
       ".."/validators/[attestation_aggregation, keystore_management,
                        validator_pool, slashing_protection],
       ".."/[conf, beacon_clock, version, beacon_node_types,
             nimbus_binary_common],
       ".."/ssz/merkleization,
       ./eth/db/[kvstore, kvstore_sqlite3]

export os, tables, sequtils, sequtils, chronos, presto, chronicles, confutils,
       nimbus_binary_common, version, conf, options, tables, results, base10,
       eth2_json_rest_serialization, presto_client

export beacon_rest_api, node_rest_api, validator_rest_api, config_rest_api,
       rest_utils,
       datatypes, crypto, digest, signatures, merkleization,
       beacon_clock,
       kvstore, kvstore_sqlite3,
       keystore_management, slashing_protection, validator_pool,
       attestation_aggregation

const
  SYNC_TOLERANCE* = 4'u64
  SLOT_LOOKAHEAD* = 1.seconds
  HISTORICAL_DUTIES_EPOCHS* = 2'u64
  TIME_DELAY_FROM_SLOT* = 79.milliseconds

type
  ServiceState* {.pure.} = enum
    Initialized, Running, Error, Closing, Closed

  BlockServiceEventRef* = ref object of RootObj
    slot*: Slot
    proposers*: seq[ValidatorPubKey]

  ClientServiceRef* = ref object of RootObj
    state*: ServiceState
    lifeFut*: Future[void]
    client*: ValidatorClientRef

  DutiesServiceRef* = ref object of ClientServiceRef

  FallbackServiceRef* = ref object of ClientServiceRef

  ForkServiceRef* = ref object of ClientServiceRef

  AttestationServiceRef* = ref object of ClientServiceRef

  BlockServiceRef* = ref object of ClientServiceRef

  DutyAndProof* = object
    epoch*: Epoch
    dependentRoot*: Eth2Digest
    data*: RestAttesterDuty

  ProposedData* = object
    epoch*: Epoch
    dependentRoot*: Eth2Digest
    data*: seq[RestProposerDuty]

  BeaconNodeServer* = object
    client*: RestClientRef
    endpoint*: string
    config*: Option[RestConfig]
    ident*: Option[string]
    genesis*: Option[RestBeaconGenesis]
    syncInfo*: Option[RestSyncInfo]
    status*: BeaconNodeStatus

  BeaconNodeStatus* {.pure.} = enum
    Uninitalized, Offline, Incompatible, NotSynced, Online

  BeaconNodeServerRef* = ref BeaconNodeServer

  AttesterMap* = Table[ValidatorPubKey, Table[Epoch, DutyAndProof]]
  ProposerMap* = Table[Epoch, ProposedData]

  ValidatorClient* = object
    config*: ValidatorClientConf
    graffitiBytes*: GraffitiBytes
    beaconNodes*: seq[BeaconNodeServerRef]
    nodesAvailable*: AsyncEvent
    fallbackService*: FallbackServiceRef
    forkService*: ForkServiceRef
    dutiesService*: DutiesServiceRef
    attestationService*: AttestationServiceRef
    blockService*: BlockServiceRef
    runSlotLoop*: Future[void]
    beaconClock*: BeaconClock
    attachedValidators*: ValidatorPool
    fork*: Option[Fork]
    attesters*: AttesterMap
    proposers*: ProposerMap
    beaconGenesis*: RestBeaconGenesis
    blocksQueue*: AsyncQueue[BlockServiceEventRef]

  ValidatorClientRef* = ref ValidatorClient

const
  DefaultDutyAndProof* = DutyAndProof(epoch: Epoch(0xFFFF_FFFF_FFFF_FFFF'u64))

proc `$`*(bn: BeaconNodeServerRef): string =
  if bn.ident.isSome():
    bn.client.address.hostname & ":" &
      Base10.toString(bn.client.address.port) & " [" & bn.ident.get() & "]"
  else:
    bn.client.address.hostname & ":" &
      Base10.toString(bn.client.address.port)

chronicles.formatIt BeaconNodeServerRef:
  $it

chronicles.expandIt(RestAttesterDuty):
  slot = it.slot
  pubkey = shortLog(it.pubkey)
  validator_index = it.validator_index
  committee_index = it.committee_index
  committee_length = it.committee_length
  committees_at_slot = it.committees_at_slot
  validator_committee_index = it.validator_committee_index

proc stop*(csr: ClientServiceRef) {.async.} =
  if csr.state == ServiceState.Running:
    csr.state = ServiceState.Closing
    if not(csr.lifeFut.finished()):
      await csr.lifeFut.cancelAndWait()
    csr.state = ServiceState.Closed

proc isDefault*(dap: DutyAndProof): bool =
  dap.epoch == Epoch(0xFFFF_FFFF_FFFF_FFFF'u64)

proc isDefault*(prd: ProposedData): bool =
  prd.epoch == Epoch(0xFFFF_FFFF_FFFF_FFFF'u64)

proc init*(t: typedesc[DutyAndProof], epoch: Epoch, dependentRoot: Eth2Digest,
           duty: RestAttesterDuty): DutyAndProof =
  DutyAndProof(epoch: epoch, dependentRoot: dependentRoot, data: duty)

proc init*(t: typedesc[ProposedData], epoch: Epoch, dependentRoot: Eth2Digest,
           data: openarray[RestProposerDuty]): ProposedData =
  ProposedData(epoch: epoch, dependentRoot: dependentRoot, data: @data)

proc getCurrentSlot*(vc: ValidatorClientRef): Option[Slot] =
  let
    wallTime = vc.beaconClock.now()
    wallSlot = wallTime.toSlot()

  if not(wallSlot.afterGenesis):
    let checkGenesisTime = vc.beaconClock.fromNow(toBeaconTime(Slot(0)))
    warn "Jump in time detected, something wrong with wallclock",
         wall_time = wallTime, genesisIn = checkGenesisTime.offset
    none[Slot]()
  else:
    some(wallSlot.slot)

proc getAttesterDutiesForSlot*(vc: ValidatorClientRef,
                               slot: Slot): seq[RestAttesterDuty] =
  ## Returns all `DutyAndPrrof` for the given `slot`.
  var res: seq[RestAttesterDuty]
  let epoch = slot.epoch()
  for key, item in vc.attesters.pairs():
    let duty = item.getOrDefault(epoch, DefaultDutyAndProof)
    if not(duty.isDefault()):
      if duty.data.slot == slot:
        res.add(duty.data)
  res
