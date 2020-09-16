# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or https://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or https://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  # Standard library
  std/[unittest, os],
  # Status lib
  eth/db/kvstore,
  stew/results,
  nimcrypto/utils,
  # Internal
  ../../beacon_chain/validator_slashing_protection,
  ../../beacon_chain/spec/[datatypes, digest, crypto, presets],
  # Test utilies
  ../testutil

static: doAssert UseSlashingProtection, "The test was compiled without slashing protection, pass -d:UseSlashingProtection=true"

template wrappedTimedTest(name: string, body: untyped) =
  # `check` macro takes a copy of whatever it's checking, on the stack!
  block: # Symbol namespacing
    proc wrappedTest() =
      timedTest name:
        body
    wrappedTest()

func fakeRoot(index: SomeInteger): Eth2Digest =
  ## Create fake roots
  ## Those are just the value serialized in big-endian
  ## We prevent zero hash special case via a power of 2 prefix
  result.data[0 ..< 8] = (1'u64 shl 32 + index.uint64).toBytesBE()

func fakeValidator(index: SomeInteger): ValidatorPubKey =
  ## Create fake validator public key
  result = ValidatorPubKey(kind: OpaqueBlob)
  result.blob[0 ..< 8] = (1'u64 shl 48 + index.uint64).toBytesBE()

func hexToDigest(hex: string): Eth2Digest =
  result = Eth2Digest.fromHex(hex)

suiteReport "Slashing Protection DB - Interchange" & preset():
  # https://hackmd.io/@sproul/Bk0Y0qdGD#Format-1-Complete
  wrappedTimedTest "Smoke test - Complete format" & preset():
    let genesis_validators_root = hexToDigest"0x04700007fabc8282644aed6d1c7c9e21d38a03a0c4ba193f3afe428824b3a673"
    block: # export
      let db = SlashingProtectionDB.init(genesis_validators_root, kvStore MemStoreRef.init())

      let pubkey = ValidatorPubKey
                    .fromHex"0xb845089a1457f811bfc000588fbb4e713669be8ce060ea6be3c6ece09afc3794106c91ca73acda5e5457122d58723bed"
                    .get()
      db.registerBlock(
        pubkey,
        Slot 81952,
        hexToDigest"0x4ff6f743a43f3b4f95350831aeaf0a122a1a392922c45d804280284a69eb850b"
      )
      # db.registerBlock(
      #   pubkey,
      #   Slot 81951,
      #   fakeRoot(65535)
      # )

      db.registerAttestation(
        pubkey,
        source = Epoch 2290,
        target = Epoch 3007,
        hexToDigest"0x587d6a4f59a58fe24f406e0502413e77fe1babddee641fda30034ed37ecc884d"
      )
      db.registerAttestation(
        pubkey,
        source = Epoch 2290,
        target = Epoch 3008,
        fakeRoot(65535)
      )

      db.toSPDIF(currentSourcePath.parentDir/"test_complete_export_slashing_protection.json")

    block: # import - zero root db
      let db2 = SlashingProtectionDB.init(Eth2Digest(), kvStore MemStoreRef.init())

      doAssert db2.fromSPDIF(currentSourcePath.parentDir/"test_complete_export_slashing_protection.json")
      db2.toSPDIF(currentSourcePath.parentDir/"test_complete_export_slashing_protection_roundtrip1.json")

    block: # import - same root db
      let db3 = SlashingProtectionDB.init(genesis_validators_root, kvStore MemStoreRef.init())

      doAssert db3.fromSPDIF(currentSourcePath.parentDir/"test_complete_export_slashing_protection.json")
      db3.toSPDIF(currentSourcePath.parentDir/"test_complete_export_slashing_protection_roundtrip2.json")

    block: # import - invalid root db
      let invalid_genvalroot = hexToDigest"0x1234"
      let db3 = SlashingProtectionDB.init(invalid_genvalroot, kvStore MemStoreRef.init())

      doAssert not db3.fromSPDIF(currentSourcePath.parentDir/"test_complete_export_slashing_protection.json")
