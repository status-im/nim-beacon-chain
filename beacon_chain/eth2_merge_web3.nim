# Keep changes in one repo

import
  strutils,
  json_serialization/std/[sets, net], serialization/errors,
  ./spec/[datatypes, digest, crypto, eth2_apis/beacon_rpc_client],
  json_rpc/[client, jsonmarshal]

from os import DirSep, AltSep
template sourceDir: string = currentSourcePath.rsplit({DirSep, AltSep}, 1)[0]
createRpcSigs(RpcClient, sourceDir & "/rpc/eth_merge_sigs.nim")
