# beacon_chain
# Copyright (c) 2018-2021 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [Defect].}

import
  tables, strutils, os,
  stew/shims/macros, nimcrypto/hash,
  eth/common/eth_types as commonEthTypes,
  web3/[ethtypes, conversions],
  chronicles,
  json_serialization,
  json_serialization/std/[options, sets, net], serialization/errors,
  ../ssz/navigator,
  eth/common/eth_types_json_serialization,
  ../spec/[presets, datatypes, digest]

# ATTENTION! This file will produce a large C file, because we are inlining
# genesis states as C literals in the generated code (and blobs in the final
# binary). It makes sense to keep the file small and separated from the rest
# of the module in order go gain maximum efficiency in incremental compilation.
#
# TODO(zah):
# We can compress the embedded states with snappy before embedding them here.

export
  ethtypes, conversions, RuntimePreset

type
  Eth1Address* = ethtypes.Address
  Eth1BlockHash* = ethtypes.BlockHash

  Eth1Network* = enum
    mainnet
    rinkeby
    goerli

  PresetIncompatible* = object of CatchableError

  Eth2NetworkMetadata* = object
    case incompatible*: bool
    of false:
      # TODO work-around a Nim codegen issue where upon constant assignment
      #      the compiler will copy `incompatibilityDesc` even when the case
      #      branch is not active and thus it will override the first variable
      #      in this branch.
      dummy: string
      eth1Network*: Option[Eth1Network]
      runtimePreset*: RuntimePreset

      # Parsing `enr.Records` is still not possible at compile-time
      bootstrapNodes*: seq[string]

      depositContractAddress*: Eth1Address
      depositContractDeployedAt*: BlockHashOrNumber

      # Please note that we are using `string` here because SSZ.decode
      # is not currently usable at compile time and we want to load the
      # network metadata into a constant.
      #
      # We could have also used `seq[byte]`, but this results in a lot
      # more generated code that slows down compilation. The impact on
      # compilation times of embedding the genesis as a string is roughly
      # 0.1s on my machine (you can test this by choosing an invalid name
      # for the genesis file below).
      #
      # `genesisData` will have `len == 0` for networks with a still
      # unknown genesis state.
      genesisData*: string
      genesisDepositsSnapshot*: string
    else:
      incompatibilityDesc*: string

const
  eth2testnetsDir = currentSourcePath.parentDir.replace('\\', '/') & "/../../vendor/eth2-testnets"

const presetValueLoaders = genExpr(nnkBracket):
  for constName in PresetValue:
    let
      constNameIdent = ident $constName
      constType = ident getType(constName)

    yield quote do:
      (
        proc (preset: var RuntimePreset, presetValue: string): bool
             {.gcsafe, noSideEffect, raises: [Defect].} =
          try:
            when PresetValue.`constNameIdent` in runtimeValues:
              preset.`constNameIdent` = parse(`constType`, presetValue)
              true
            elif PresetValue.`constNameIdent` in ignoredValues:
              true
            else:
              `constType`(`constNameIdent`) == parse(`constType`, presetValue)
          except CatchableError:
            false
      )

proc extractRuntimePreset*(configPath: string, configData: PresetFile): RuntimePreset
                          {.raises: [PresetIncompatible, Defect].} =
  result = RuntimePreset()

  for name, value in configData.values:
    if not presetValueLoaders[name.int](result, value):
      let errMsg = "The preset '" & configPath & "'is not compatible with " &
                   "the current build due to an incompatible value " &
                   $name & " = " & value.string
      raise newException(PresetIncompatible, errMsg)

proc loadEth2NetworkMetadata*(path: string): Eth2NetworkMetadata
                             {.raises: [CatchableError, Defect].} =
  try:
    let
      genesisPath = path & "/genesis.ssz"
      genesisDepositsSnapshotPath = path & "/genesis_deposit_contract_snapshot.ssz"
      configPath = path & "/config.yaml"
      depositContractPath = path & "/deposit_contract.txt"
      depositContractBlockPath = path & "/deposit_contract_block.txt"
      bootstrapNodesPath = path & "/bootstrap_nodes.txt"

      runtimePreset = if fileExists(configPath):
        extractRuntimePreset(configPath, readPresetFile(configPath))
      else:
        mainnetRuntimePreset

      depositContractAddress = if fileExists(depositContractPath):
        Eth1Address.fromHex readFile(depositContractPath).strip
      else:
        default(Eth1Address)

      depositContractBlock = if fileExists(depositContractBlockPath):
        readFile(depositContractBlockPath).strip
      else:
        ""

      depositContractDeployedAt = if depositContractBlock.len > 0:
        BlockHashOrNumber.init(depositContractBlock)
      else:
        BlockHashOrNumber(isHash: false, number: 1)

      bootstrapNodes = if fileExists(bootstrapNodesPath):
        readFile(bootstrapNodesPath).splitLines()
      else:
        @[]

      genesisData = if fileExists(genesisPath):
        readFile(genesisPath)
      else:
        ""

      genesisDepositsSnapshot = if fileExists(genesisDepositsSnapshotPath):
        readFile(genesisDepositsSnapshotPath)
      else:
        ""

    Eth2NetworkMetadata(
      incompatible: false,
      eth1Network: some goerli,
      runtimePreset: runtimePreset,
      bootstrapNodes: bootstrapNodes,
      depositContractAddress: depositContractAddress,
      depositContractDeployedAt: depositContractDeployedAt,
      genesisData: genesisData,
      genesisDepositsSnapshot: genesisDepositsSnapshot)

  except PresetIncompatible as err:
    Eth2NetworkMetadata(incompatible: true,
                        incompatibilityDesc: err.msg)

const
  mainnetMetadataDir = eth2testnetsDir & "/shared/mainnet"

  mainnetMetadata* = when const_preset == "mainnet":
    Eth2NetworkMetadata(
      incompatible: false, # TODO: This can be more accurate if we verify
                           # that there are no constant overrides
      eth1Network: some mainnet,
      runtimePreset: mainnetRuntimePreset,
      bootstrapNodes: readFile(mainnetMetadataDir & "/bootstrap_nodes.txt").splitLines,
      depositContractAddress: Eth1Address.fromHex "0x00000000219ab540356cBB839Cbe05303d7705Fa",
      depositContractDeployedAt: BlockHashOrNumber.init "11052984",
      genesisData: readFile(mainnetMetadataDir & "/genesis.ssz"),
      genesisDepositsSnapshot: readFile(mainnetMetadataDir & "/genesis_deposit_contract_snapshot.ssz"))
  else:
    Eth2NetworkMetadata(
      incompatible: true,
      incompatibilityDesc: "This build is compiled with the " & const_preset & " const preset. " &
                           "It's not compatible with mainnet")

template eth2testnet(path: string): Eth2NetworkMetadata =
  loadEth2NetworkMetadata(eth2testnetsDir & "/" & path)

const
  pyrmontMetadata* = eth2testnet "shared/pyrmont"
  praterMetadata* = eth2testnet "shared/prater"
  nocturneMetadata* = eth2testnet "shared/rayonism/nocturne"

{.pop.} # the following pocedures raise more than just `Defect`

proc getMetadataForNetwork*(networkName: string): Eth2NetworkMetadata =
  let
    metadata = case toLowerAscii(networkName)
      of "mainnet":
        mainnetMetadata
      of "pyrmont":
        pyrmontMetadata
      of "prater":
        praterMetadata
      of "nocturne":
        nocturneMetadata
      else:
        if fileExists(networkName):
          try:
            Json.loadFile(networkName, Eth2NetworkMetadata)
          except SerializationError as err:
            echo err.formatMsg(networkName)
            quit 1
        else:
          fatal "Unrecognized network name", networkName
          quit 1

  if metadata.incompatible:
    fatal "The selected network is not compatible with the current build",
            reason = metadata.incompatibilityDesc
    quit 1
  return metadata

proc getRuntimePresetForNetwork*(eth2Network: Option[string]): RuntimePreset =
  if eth2Network.isSome:
    return getMetadataForNetwork(eth2Network.get).runtimePreset
  return defaultRuntimePreset

proc extractGenesisValidatorRootFromSnapshop*(snapshot: string): Eth2Digest =
  sszMount(snapshot, BeaconState).genesis_validators_root[]
