import
  json_serialization/std/[options, sets, net], serialization/errors,
  "."/[
    beacon_clock, version],
  #./networking/[eth2_discovery, network_metadata],
  #./gossip_processing/eth2_processor,
  ./rpc/rest_utils,
  ./spec/[
    datatypes, digest, crypto, eth2_apis/beacon_rpc_client,
    helpers, presets],
  ./eth1/eth1_monitor

# Keep changes in one repo
import json_rpc/client, strutils
import json_rpc/jsonmarshal
import web3
import spec/datatypes

from os import DirSep, AltSep
template sourceDir: string = currentSourcePath.rsplit({DirSep, AltSep}, 1)[0]
createRpcSigs(RpcClient, sourceDir & "/rpc/eth_merge_sigs.nim")
