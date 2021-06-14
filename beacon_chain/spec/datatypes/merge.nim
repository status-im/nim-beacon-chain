# beacon_chain
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

# TODO Careful, not nil analysis is broken / incomplete and the semantics will
#      likely change in future versions of the language:
#      https://github.com/nim-lang/RFCs/issues/250
{.experimental: "notnil".}

{.push raises: [Defect].}

import
  std/macros,
  stew/assign2,
  json_serialization,
  json_serialization/types as jsonTypes,
  ssz_serialization/types as sszTypes,
  ../digest,
  #web3/ethtypes,
  nimcrypto/utils

const
  # https://github.com/ethereum/eth2.0-specs/blob/e895c29f3f42382a0c913f3d0fd33522d7db9e87/specs/merge/beacon-chain.md#execution
  MAX_BYTES_PER_OPAQUE_TRANSACTION* = 1048576
  MAX_EXECUTION_TRANSACTIONS* = 16384
  BYTES_PER_LOGS_BLOOM* = 256

  EVM_BLOCK_ROOTS_SIZE* = 8

type
  # https://github.com/ethereum/eth2.0-specs/blob/dev/specs/merge/beacon-chain.md#custom-types
  OpaqueTransaction* = List[byte, Limit MAX_BYTES_PER_OPAQUE_TRANSACTION]

  EthAddress* = object
    data*: array[20, byte]  # TODO there's a network_metadata type, but the import hierarchy's inconvenient

  BloomLogs* = object
    data*: array[BYTES_PER_LOGS_BLOOM, byte]

  # https://github.com/ethereum/eth2.0-specs/blob/dev/specs/merge/beacon-chain.md#executionpayload
  ExecutionPayload* = object
    block_hash*: Eth2Digest # Hash of execution block
    parent_hash*: Eth2Digest
    coinbase*: EthAddress
    state_root*: Eth2Digest
    number*: uint64
    gas_limit*: uint64
    gas_used*: uint64
    timestamp*: uint64
    receipt_root*: Eth2Digest
    logs_bloom*: BloomLogs
    transactions*: List[OpaqueTransaction, MAX_EXECUTION_TRANSACTIONS]

  # https://github.com/ethereum/eth2.0-specs/blob/dev/specs/merge/beacon-chain.md#executionpayloadheader
  ExecutionPayloadHeader* = object
    block_hash*: Eth2Digest  # Hash of execution block
    parent_hash*: Eth2Digest
    coinbase*: EthAddress
    state_root*: Eth2Digest
    number*: uint64
    gas_limit*: uint64
    gas_used*: uint64
    timestamp*: uint64
    receipt_root*: Eth2Digest
    logs_bloom*: BloomLogs
    transactions_root*: Eth2Digest

  # Empirically derived from Catalyst responses; doesn't seem to match merge
  # spec per commit 1fb9a6dd32b581c912d672634882d7e2eb2775cd from 2021-04-22
  # {"jsonrpc":"2.0","id":1,"result":{"blockHash":"0x35139e42d930c640eee446944f7f8b345771b69dfa10120895057f48680ea27d","parentHash":"0x3a3fdfc9ab6e17ff530b57bc21494da3848ebbeaf9343545fded7a18d221ffec","miner":"0x1000000000000000000000000000000000000000","stateRoot":"0x56e81f171bcc55a6ff8345e692c0f86e5b48e01b996cadc001622fb5e363b421","number":"0x1","gasLimit":"0x2fefd8","gasUsed":"0x0","timestamp":"0x6087e796","receiptsRoot":"0x56e81f171bcc55a6ff8345e692c0f86e5b48e01b996cadc001622fb5e363b421","logsBloom":"0x00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000","transactions":[]}}
  ExecutionPayloadRPC* = object
    blockHash*: string  # Hash of execution block
    parentHash*: string
    miner*: string
    stateRoot*: string
    number*: string
    gasLimit*: string
    gasUsed*: string
    timestamp*: string
    receiptsRoot*: string
    logsBloom*: string
    transactions*: List[string, MAX_EXECUTION_TRANSACTIONS]

  BlockParams* = object
    parentHash*: string
    timestamp*: string

  BoolReturnValidRPC* = object
    valid*: bool

  BoolReturnSuccessRPC* = object
    success*: bool

func encodeQuantityHex*(x: auto): string =
  "0x" & x.toHex

proc fromHex*(T: typedesc[BloomLogs], s: string): T =
  hexToBytes(s, result.data)

proc fromHex*(T: typedesc[EthAddress], s: string): T =
  hexToBytes(s, result.data)

proc writeValue*(w: var JsonWriter, a: EthAddress) {.raises: [Defect, IOError, SerializationError].} =
  w.writeValue $a

proc readValue*(r: var JsonReader, a: var EthAddress) {.raises: [Defect, IOError, SerializationError].} =
  try:
    a = fromHex(type(a), r.readValue(string))
  except ValueError:
    raiseUnexpectedValue(r, "Hex string expected")

# https://github.com/ethereum/eth2.0-specs/blob/dev/specs/merge/beacon-chain.md#is_transition_completed
func is_transition_completed*(state: auto): bool =
  # Rayonism starts post-merge
  true
