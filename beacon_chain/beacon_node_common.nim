# beacon_chain
# Copyright (c) 2018-2021 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

# Common routines for a BeaconNode and a BeaconValidator node

import
  std/osproc,

  # Nimble packages
  chronos, json_rpc/servers/httpserver, presto,

  # Local modules
  ./conf, ./beacon_clock, ./beacon_chain_db,
  ./beacon_node_types,
  ./gossip_processing/[eth2_processor, block_processor, consensus_manager],
  ./networking/eth2_network,
  ./eth1/eth1_monitor,
  ./consensus_object_pools/[blockchain_dag, block_quarantine, attestation_pool],
  ./spec/datatypes/base,
  ./sync/[sync_manager, request_manager]

export
  osproc, chronos, httpserver, conf, beacon_clock, beacon_chain_db,
  attestation_pool, eth2_network, beacon_node_types, eth1_monitor,
  request_manager, sync_manager, eth2_processor, blockchain_dag, block_quarantine,
  base

type
  RpcServer* = RpcHttpServer

  BeaconNode* = ref object
    nickname*: string
    graffitiBytes*: GraffitiBytes
    network*: Eth2Node
    netKeys*: NetKeyPair
    db*: BeaconChainDB
    config*: BeaconNodeConf
    attachedValidators*: ref ValidatorPool
    dag*: ChainDAGRef
    quarantine*: QuarantineRef
    attestationPool*: ref AttestationPool
    syncCommitteeMsgPool*: ref SyncCommitteeMsgPool
    exitPool*: ref ExitPool
    eth1Monitor*: Eth1Monitor
    rpcServer*: RpcServer
    restServer*: RestServerRef
    vcProcess*: Process
    requestManager*: RequestManager
    syncManager*: SyncManager[Peer, PeerID]
    genesisSnapshotContent*: string
    attestationSubnets*: AttestationSubnets
    processor*: ref Eth2Processor
    blockProcessor*: ref BlockProcessor
    consensusManager*: ref ConsensusManager
    attachedValidatorBalanceTotal*: uint64
    syncCommitteesUpdatedAt*: Option[Epoch]

const
  MaxEmptySlotCount* = uint64(10*60) div SECONDS_PER_SLOT

# TODO stew/sequtils2
template findIt*(s: openArray, predicate: untyped): int =
  var res = -1
  for i, it {.inject.} in s:
    if predicate:
      res = i
      break
  res

template beaconClock*(node: BeaconNode): BeaconClock =
  node.dag.beaconClock

proc currentSlot*(node: BeaconNode): Slot =
  node.beaconClock.now.slotOrZero

template runtimePreset*(node: BeaconNode): RuntimeConfig =
  node.db.preset
