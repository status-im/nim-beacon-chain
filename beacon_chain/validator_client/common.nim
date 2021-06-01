import std/[tables, os, sequtils]
import chronos, presto, presto/client as presto_client, chronicles, confutils,
       json_serialization/std/[options, net],
       stew/[base10, results]
# Local modules
import ".."/networking/[eth2_network, eth2_discovery],
       ".."/spec/[datatypes, digest, crypto, helpers, network, signatures],
       ".."/rpc/[beacon_rest_api, node_rest_api, validator_rest_api,
                 config_rest_api, rest_utils, eth2_json_rest_serialization],
       ".."/validators/[attestation_aggregation, keystore_management,
                        validator_pool, slashing_protection],
       ".."/[conf, beacon_clock, version, beacon_node_types,
             nimbus_binary_common],
       ./eth/db/[kvstore, kvstore_sqlite3]

export os, tables, sequtils, chronos, presto, chronicles, confutils,
       nimbus_binary_common, version, conf, options, tables, results,
       eth2_json_rest_serialization, presto_client

export beacon_rest_api, node_rest_api, validator_rest_api, config_rest_api,
       rest_utils,
       datatypes, crypto, digest,
       beacon_clock,
       kvstore, kvstore_sqlite3,
       keystore_management, slashing_protection, validator_pool

const
  SYNC_TOLERANCE* = 4'u64
  SLOT_LOOKAHEAD* = 1.seconds
  HISTORICAL_DUTIES_EPOCHS* = 2'u64

type
  ServiceState* {.pure.} = enum
    Running, Error, Closing, Closed

  ClientServiceRef* = ref object of RootObj
    state*: ServiceState
    lifeFut*: Future[void]
    client*: ValidatorClientRef

  DutiesServiceRef* = ref object of ClientServiceRef

  FallbackServiceRef* = ref object of ClientServiceRef

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
    dutiesService*: DutiesServiceRef
    runSlotLoop*: Future[void]
    beaconClock*: BeaconClock
    attachedValidators*: ValidatorPool
    fork*: Fork
    attesters*: AttesterMap
    proposers*: ProposerMap
    beaconGenesis*: RestBeaconGenesis

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
  pubkey = shortLog(it.pubkey)
  validator_index = it.validator_index
  committee_index = it.committee_index
  committee_length = it.committee_length
  committees_at_slot = it.committees_at_slot
  validator_committee_index = it.validator_committee_index
  slot = it.slot

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
