# beacon_chain
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at http://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at http://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  # Standard library
  os, unittest, strutils, streams, strformat,
  macros, sets,
  # Status libraries
  stint, stew/bitseqs,
  # Third-party
  yaml,
  # Beacon chain internals
  ../../beacon_chain/spec/[datatypes, digest],
  ../../beacon_chain/ssz,
  # Test utilities
  ../testutil

# SSZ tests of consensus objects (minimal/mainnet preset specific)

# Parsing definitions
# ----------------------------------------------------------------

const
  FixturesDir = currentSourcePath.rsplit(DirSep, 1)[0] / "fixtures"
  SSZDir = FixturesDir/"tests-v0.9.1"/const_preset/"phase0"/"ssz_static"

type
  SSZHashTreeRoot = object
    # The test files have the values at the "root"
    # so we **must** use "root" as a field name
    root: string
    # Some have a signing_root field
    signing_root: string

# Make signing root optional
setDefaultValue(SSZHashTreeRoot, signing_root, "")

# Note this onyl tracks HashTreeRoot and SigningRoot
# Checking the values against the yaml file is TODO (require more flexible Yaml parser)
const Unsupported = toHashSet([
    "AggregateAndProof",    # Type for signature aggregation - not implemented
    # "Attestation",        #
    # "AttestationData",    #
    # "AttesterSlashing",   #
    # "BeaconBlock",        #
    # "BeaconBlockBody",    #
    # "BeaconBlockHeader",  #
    # "BeaconState",        # OK on minimal, KO on mainnet
    # "Checkpoint",         #
    # "Deposit",            #
    # "DepositData",        #
    # "Eth1Data",           #
    # "Fork",               #
    # "HistoricalBatch",    #
    # "IndexedAttestation", #
    # "PendingAttestation", # OK on minimal, KO on mainnet
    # "ProposerSlashing",   #
    "Validator",            # HashTreeRoot KO
    # "VoluntaryExit"       #
  ])

const UnsupportedMainnet = toHashSet([
    "PendingAttestation",   # HashTreeRoot KO
    "BeaconState",
    "AttesterSlashing",
    "BeaconBlockBody",
    "IndexedAttestation",
    "Attestation",
    "BeaconBlock"
  ])

type Skip = enum
  SkipNone
  SkipHashTreeRoot
  SkipSigningRoot

proc checkSSZ(T: typedesc, dir: string, expectedHash: SSZHashTreeRoot, skip = SkipNone) =
  # Deserialize into a ref object to not fill Nim stack
  var deserialized: ref T
  new deserialized
  deserialized[] = SSZ.loadFile(dir/"serialized.ssz", T)

  # echo "Dir: ", dir
  if not(skip == SkipHashTreeRoot):
    check: expectedHash.root == "0x" & toLowerASCII($deserialized.hashTreeRoot())
  if expectedHash.signing_root != "" and not(skip == SkipSigningRoot):
    check: expectedHash.signing_root == "0x" & toLowerASCII($deserialized[].signingRoot())

  # TODO check the value

proc loadExpectedHashTreeRoot(dir: string): SSZHashTreeRoot =
  var s = openFileStream(dir/"roots.yaml")
  yaml.load(s, result)
  s.close()

# Test runner
# ----------------------------------------------------------------

proc runSSZtests() =
  doAssert existsDir(SSZDir), "You need to run the \"download_test_vectors.sh\" script to retrieve the official test vectors."
  for pathKind, sszType in walkDir(SSZDir, relative = true):
    assert pathKind == pcDir
    if sszType in Unsupported:
      test &"  Skipping   {sszType:20}   consensus object ✗✗✗":
        discard
      continue

    when const_preset == "mainnet":
      if sszType in UnsupportedMainnet:
        test &"  Skipping   {sszType:20}   consensus object ✗✗✗ (skipped on mainnet-only)":
          discard
        continue

    test &"  Testing    {sszType:20}   consensus object ✓✓✓":
      let path = SSZDir/sszType
      for pathKind, sszTestKind in walkDir(path, relative = true):
        assert pathKind == pcDir
        let path = SSZDir/sszType/sszTestKind
        for pathKind, sszTestCase in walkDir(path, relative = true):
          let path = SSZDir/sszType/sszTestKind/sszTestCase
          let hash = loadExpectedHashTreeRoot(path)

          case sszType:
          # of "AggregateAndProof": checkSSZ(AggregateAndProof, path, hash)
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
          of "Eth1Data": checkSSZ(Eth1Data, path, hash)
          of "Fork": checkSSZ(Fork, path, hash)
          of "HistoricalBatch": checkSSZ(HistoricalBatch, path, hash)
          of "IndexedAttestation": checkSSZ(IndexedAttestation, path, hash)
          of "PendingAttestation": checkSSZ(PendingAttestation, path, hash)
          of "ProposerSlashing": checkSSZ(ProposerSlashing, path, hash)
          of "Validator": checkSSZ(VoluntaryExit, path, hash)
          of "VoluntaryExit": checkSSZ(VoluntaryExit, path, hash)
          else:
            raise newException(ValueError, "Unsupported test: " & sszType)

suite "Official - 0.9.1 - SSZ consensus objects " & preset():
  runSSZtests()
