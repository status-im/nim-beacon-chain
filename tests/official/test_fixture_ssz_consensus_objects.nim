# beacon_chain
# Copyright (c) 2018-2021 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  # Standard library
  os, strutils, streams, strformat,
  macros, sets,
  # Third-party
  yaml,
  snappy,
  # Beacon chain internals
  ../../beacon_chain/spec/[crypto, datatypes, digest],
  ../../beacon_chain/ssz,
  # Test utilities
  ../testutil, ./fixtures_utils

# SSZ tests of consensus objects (minimal/mainnet preset specific)

# Parsing definitions
# ----------------------------------------------------------------

const
  # TODO remove once merge test vectors have more than ssz_static
  SszTestsDirMerge = FixturesDir / "tests-v1.1.0-alpha.4-pre1"
  SSZDir = SszTestsDirMerge/const_preset/"merge"/"ssz_static"
  MAX_OBJECT_SIZE = 10_000_000

type
  SSZHashTreeRoot = object
    # The test files have the values at the "root"
    # so we **must** use "root" as a field name
    root: string
    # Some have a signing_root field
    signing_root {.defaultVal: "".}: string

  # https://github.com/ethereum/eth2.0-specs/blob/v1.0.1/specs/phase0/validator.md#eth1block
  Eth1Block* = object
    timestamp*: uint64
    deposit_root*: Eth2Digest
    deposit_count*: uint64
    # All other eth1 block fields

# Note this only tracks HashTreeRoot
# Checking the values against the yaml file is TODO (require more flexible Yaml parser)

proc checkSSZ(T: type SignedBeaconBlock, dir: string, expectedHash: SSZHashTreeRoot) =
  # Deserialize into a ref object to not fill Nim stack
  let encoded = snappy.decode(readFileBytes(dir/"serialized.ssz_snappy"), MAX_OBJECT_SIZE)
  var deserialized = newClone(sszDecodeEntireInput(encoded, T))

  # SignedBeaconBlocks usually not hashed because they're identified by
  # htr(BeaconBlock), so do it manually
  check: expectedHash.root == "0x" & toLowerASCII($hash_tree_root(
    [hash_tree_root(deserialized.message),
    hash_tree_root(deserialized.signature)]))

  check deserialized.root == hash_tree_root(deserialized.message)
  check SSZ.encode(deserialized[]) == encoded
  check sszSize(deserialized[]) == encoded.len

  # TODO check the value (requires YAML loader)

proc checkSSZ(T: type, dir: string, expectedHash: SSZHashTreeRoot) =
  # Deserialize into a ref object to not fill Nim stack
  let encoded = snappy.decode(readFileBytes(dir/"serialized.ssz_snappy"), MAX_OBJECT_SIZE)
  var deserialized = newClone(sszDecodeEntireInput(encoded, T))

  check: expectedHash.root == "0x" & toLowerASCII($hash_tree_root(deserialized[]))

  check SSZ.encode(deserialized[]) == encoded
  check sszSize(deserialized[]) == encoded.len

  # TODO check the value (requires YAML loader)

proc loadExpectedHashTreeRoot(dir: string): SSZHashTreeRoot =
  var s = openFileStream(dir/"roots.yaml")
  yaml.load(s, result)
  s.close()

# Test runner
# ----------------------------------------------------------------

suite "Official - SSZ consensus objects " & preset():
  doAssert existsDir(SSZDir), "You need to run the \"download_test_vectors.sh\" script to retrieve the official test vectors."
  for pathKind, sszType in walkDir(SSZDir, relative = true):
    doAssert pathKind == pcDir

    test &"  Testing    {sszType}":
      let path = SSZDir/sszType
      for pathKind, sszTestKind in walkDir(path, relative = true):
        doAssert pathKind == pcDir
        let path = SSZDir/sszType/sszTestKind
        for pathKind, sszTestCase in walkDir(path, relative = true):
          let path = SSZDir/sszType/sszTestKind/sszTestCase
          let hash = loadExpectedHashTreeRoot(path)

          case sszType:
          of "AggregateAndProof": checkSSZ(AggregateAndProof, path, hash)
          of "Attestation": checkSSZ(Attestation, path, hash)
          of "AttestationData": checkSSZ(AttestationData, path, hash)
          of "AttesterSlashing": checkSSZ(AttesterSlashing, path, hash)
          of "BeaconBlock": checkSSZ(BeaconBlock, path, hash)
          of "BeaconBlockBody": checkSSZ(BeaconBlockBody, path, hash)
          of "BeaconBlockHeader": checkSSZ(BeaconBlockHeader, path, hash)
          of "BeaconState": checkSSZ(BeaconState, path, hash)

          of "Checkpoint": checkSSZ(Checkpoint, path, hash)
          of "Deposit": checkSSZ(Deposit, path, hash)
          of "DepositData": checkSSZ(DepositData, path, hash)
          of "DepositMessage": checkSSZ(DepositMessage, path, hash)
          of "Eth1Block": checkSSZ(Eth1Block, path, hash)
          of "Eth1Data": checkSSZ(Eth1Data, path, hash)
          of "ExecutionPayload": checkSSZ(ExecutionPayload, path, hash)
          of "ExecutionPayloadHeader": checkSSZ(ExecutionPayloadHeader, path, hash)
          of "Fork": checkSSZ(Fork, path, hash)
          of "ForkData": checkSSZ(ForkData, path, hash)
          of "HistoricalBatch": checkSSZ(HistoricalBatch, path, hash)
          of "IndexedAttestation": checkSSZ(IndexedAttestation, path, hash)
          of "PendingAttestation": checkSSZ(PendingAttestation, path, hash)
          of "PowBlock": discard   # TODO not used so far in SSZ
          of "ProposerSlashing": checkSSZ(ProposerSlashing, path, hash)
          of "SignedAggregateAndProof":
            checkSSZ(SignedAggregateAndProof, path, hash)
          of "SignedBeaconBlock": checkSSZ(SignedBeaconBlock, path, hash)
          of "SignedBeaconBlockHeader":
            checkSSZ(SignedBeaconBlockHeader, path, hash)
          of "SignedVoluntaryExit": checkSSZ(SignedVoluntaryExit, path, hash)
          of "SigningData":
            checkSSZ(SigningData, path, hash)
          of "Validator": checkSSZ(Validator, path, hash)
          of "VoluntaryExit": checkSSZ(VoluntaryExit, path, hash)
          else:
            raise newException(ValueError, "Unsupported test: " & sszType)

summarizeLongTests("FixtureSSZConsensus")
