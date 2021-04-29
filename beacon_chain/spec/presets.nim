# beacon_chain
# Copyright (c) 2018-2021 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [Defect].}

import
  std/[macros, strutils, parseutils, tables],
  stew/endians2,
  preset_values

export
  PresetValue, toBytesBE

type
  Slot* = distinct uint64
  Epoch* = distinct uint64
  Version* = distinct array[4, byte]

  RuntimePreset* = object
    GENESIS_FORK_VERSION*: Version
    ALTAIR_FORK_VERSION*: Version
    GENESIS_DELAY*: uint64
    MIN_GENESIS_ACTIVE_VALIDATOR_COUNT*: uint64
    MIN_GENESIS_TIME*: uint64
    ETH1_FOLLOW_DISTANCE*: uint64
    DEPOSIT_CHAIN_ID*: uint64
    DEPOSIT_NETWORK_ID*: uint64
    SECONDS_PER_ETH1_BLOCK*: uint64

  PresetFile* = object
    values*: Table[PresetValue, TaintedString]
    missingValues*: set[PresetValue]

  PresetFileError* = object of CatchableError

const
  const_preset* {.strdefine.} = "mainnet"

  runtimeValues* = {
    ALTAIR_FORK_VERSION,
    DEPOSIT_CHAIN_ID,
    DEPOSIT_NETWORK_ID,
    ETH1_FOLLOW_DISTANCE,
    GENESIS_DELAY,
    GENESIS_FORK_VERSION,
    MIN_GENESIS_ACTIVE_VALIDATOR_COUNT,
    MIN_GENESIS_TIME,
    SECONDS_PER_ETH1_BLOCK
  }

  # These constants cannot really be overriden in a preset.
  # If we encounter them, we'll just ignore the preset value.
  ignoredValues* = {
    # The deposit contract address is loaded through a dedicated
    # metadata file. It would break the property we are exploiting
    # right now that all preset values can be parsed as uint64
    DEPOSIT_CONTRACT_ADDRESS,

    # These are defined as an enum in datatypes.nim:
    DOMAIN_BEACON_PROPOSER,
    DOMAIN_BEACON_ATTESTER,
    DOMAIN_RANDAO,
    DOMAIN_DEPOSIT,
    DOMAIN_VOLUNTARY_EXIT,
    DOMAIN_SELECTION_PROOF,
    DOMAIN_AGGREGATE_AND_PROOF,
    DOMAIN_SYNC_COMMITTEE,
    DOMAIN_SYNC_COMMITTEE_SELECTION_PROOF,
    DOMAIN_CONTRIBUTION_AND_PROOF,
    CONFIG_NAME,

    # TODO:
    # The following constants are ignored because they are already
    # present in the testnet config presets, but our code is still
    # not using them in any way. Once the respective functionality
    # is implemented, they should be removed from the ignored set.
    MERGE_FORK_VERSION,
    MERGE_FORK_SLOT,
    TRANSITION_TOTAL_DIFFICULTY
  }

  presetValueTypes* = {
    ALTAIR_FORK_VERSION: "Version",
    BLS_WITHDRAWAL_PREFIX: "byte",
    GENESIS_FORK_VERSION: "Version",
  }.toTable

func parse*(T: type uint64, input: string): T
           {.raises: [ValueError, Defect].} =
  var res: BiggestUInt
  if input.len > 2 and input[0] == '0' and input[1] == 'x':
    if parseHex(input, res) != input.len:
      raise newException(ValueError, "The constant value should be a valid hex integer")
  else:
    if parseBiggestUInt(input, res) != input.len:
      raise newException(ValueError, "The constant value should be a valid unsigned integer")

  result = uint64(res)

template parse*(T: type byte, input: string): T =
  byte parse(uint64, input)

proc parse*(T: type Version, input: string): T
           {.raises: [ValueError, Defect].} =
  Version toBytesBE(uint32 parse(uint64, input))

template parse*(T: type Slot, input: string): T =
  Slot parse(uint64, input)

template getType*(presetValue: PresetValue): string =
  presetValueTypes.getOrDefault(presetValue, "uint64")

template toUInt64*(v: Version): uint64 =
  fromBytesBE(uint64, array[4, byte](v))

template entireSet(T: type enum): untyped =
  {low(T) .. high(T)}

proc readPresetFile*(path: string): PresetFile
                    {.raises: [IOError, PresetFileError, Defect].} =
  var
    lineNum = 0
    presetValues = ignoredValues

  template lineinfo: string =
    try: "$1($2) " % [path, $lineNum]
    except ValueError: path

  template fail(msg) =
    raise newException(PresetFileError, lineinfo() & msg)

  for line in splitLines(readFile(path)):
    inc lineNum
    if line.len == 0 or line[0] == '#': continue

    var lineParts = line.split(":")
    if lineParts.len != 2:
      fail "Invalid syntax: A preset file should include only assignments in the form 'ConstName: Value'"

    let value = try: parseEnum[PresetValue](lineParts[0])
                except ValueError: fail "Unrecognized constant in a preset: " & lineParts[0]

    if value in ignoredValues: continue
    presetValues.incl value
    result.values.add value, lineParts[1].strip

  result.missingValues = PresetValue.entireSet - presetValues

const mainnetRuntimePreset* = RuntimePreset(
  MIN_GENESIS_ACTIVE_VALIDATOR_COUNT: 16384,
  MIN_GENESIS_TIME: 1606824000, # Dec 1, 2020, 12pm UTC
  GENESIS_FORK_VERSION: Version [byte 0, 0, 0, 0],
  ALTAIR_FORK_VERSION: Version [byte 1, 0, 0, 0],
  GENESIS_DELAY: 604800,
  ETH1_FOLLOW_DISTANCE: 2048,
  DEPOSIT_CHAIN_ID: 1,
  DEPOSIT_NETWORK_ID: 1,
  SECONDS_PER_ETH1_BLOCK: 14)

const
  minimalRuntimePreset* = RuntimePreset(
    MIN_GENESIS_ACTIVE_VALIDATOR_COUNT: 64,
    MIN_GENESIS_TIME: 1606824000, # Dec 1, 2020, 12pm UTC
    GENESIS_FORK_VERSION: Version [byte 0, 0, 0, 1],
    ALTAIR_FORK_VERSION: Version [byte 1, 0, 0, 0],
    GENESIS_DELAY: 300,
    ETH1_FOLLOW_DISTANCE: 16,
    DEPOSIT_CHAIN_ID: 5,
    DEPOSIT_NETWORK_ID: 5,
    SECONDS_PER_ETH1_BLOCK: 14)

when const_preset == "mainnet":
  template defaultRuntimePreset*: auto = mainnetRuntimePreset
  import
    ./presets/v1_0_1/mainnet as phase0Mainnet,
    ./presets/altair/mainnet as altairMainnet

  # https://github.com/nim-lang/Nim/issues/17511 workaround
  static:
    discard phase0Mainnet.CONFIG_NAME
    discard altairMainnet.CONFIG_NAME

  export phase0Mainnet, altairMainnet

elif const_preset == "minimal":
  template defaultRuntimePreset*: auto = minimalRuntimePreset
  import
    ./presets/v1_0_1/minimal as phase0Minimal,
    ./presets/altair/minimal as altairMinimal

  # https://github.com/nim-lang/Nim/issues/17511 workaround
  static:
    discard phase0Minimal.CONFIG_NAME
    discard altairMinimal.CONFIG_NAME

  export phase0Minimal, altairMinimal

else:
  macro createConstantsFromPreset*(path: static string): untyped =
    result = newStmtList()

    let preset = try: readPresetFile(path)
                 except CatchableError as err:
                   error err.msg # TODO: This should be marked as noReturn
                   return

    for name, value in preset.values:
      let
        typ = getType(name)
        value = if typ in ["int64", "uint64", "byte"]: typ & "(" & value & ")"
                else: "parse(" & typ & ", \"" & value & "\")"
      try:
        result.add parseStmt("const $1* {.intdefine.} = $2" % [$name, value])
      except ValueError:
        doAssert false, "All values in the presets are printable"

    if preset.missingValues.card > 0:
      warning "Missing constants in preset: " & $preset.missingValues

  createConstantsFromPreset const_preset

  const defaultRuntimePreset* = RuntimePreset(
    MIN_GENESIS_ACTIVE_VALIDATOR_COUNT: MIN_GENESIS_ACTIVE_VALIDATOR_COUNT,
    MIN_GENESIS_TIME: MIN_GENESIS_TIME,
    GENESIS_FORK_VERSION: GENESIS_FORK_VERSION,
    GENESIS_DELAY: GENESIS_DELAY,
    ETH1_FOLLOW_DISTANCE: ETH1_FOLLOW_DISTANCE,
    DEPOSIT_CHAIN_ID: DEPOSIT_CHAIN_ID,
    DEPOSIT_NETWORK_ID: DEPOSIT_NETWORK_ID,
    SECONDS_PER_ETH1_BLOCK: SECONDS_PER_ETH1_BLOCK)

