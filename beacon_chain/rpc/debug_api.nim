# beacon_chain
# Copyright (c) 2018-2021 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [Defect].}

import
  std/sequtils,
  json_rpc/servers/httpserver,
  chronicles,
  ../version, ../beacon_node_common,
  ../networking/[eth2_network, peer_pool],
  ../spec/datatypes/phase0,
  ../spec/[digest, presets],
  ./rpc_utils, ./eth2_json_rpc_serialization

logScope: topics = "debugapi"

type
  RpcServer = RpcHttpServer

proc installDebugApiHandlers*(rpcServer: RpcServer, node: BeaconNode) {.
    raises: [Exception].} = # TODO fix json-rpc
  rpcServer.rpc("get_v1_debug_beacon_states_stateId") do (
      stateId: string) -> phase0.BeaconState:
    withStateForStateId(stateId):
      return stateData.data.hbsPhase0.data

  rpcServer.rpc("get_v1_debug_beacon_heads") do () -> seq[tuple[root: Eth2Digest, slot: Slot]]:
    return node.dag.heads.mapIt((it.root, it.slot))
