# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or https://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or https://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.used.}

import
  # Standard library
  std/[unittest, os],
  # Status lib
  eth/db/kvstore,
  stew/results,
  # Internal
  ../../beacon_chain/validators/slashing_protection,
  ../../beacon_chain/spec/[datatypes, digest, crypto, presets],
  # Test utilies
  ../testutil

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
  result = ValidatorPubKey()
  result.blob[0 ..< 8] = (1'u64 shl 48 + index.uint64).toBytesBE()

proc sqlite3db_delete(basepath, dbname: string) =
  removeFile(basepath / dbname&".sqlite3-shm")
  removeFile(basepath / dbname&".sqlite3-wal")
  removeFile(basepath / dbname&".sqlite3")

const TestDir = ""
const TestDbName = "test_slashprot"

# Reminder of SQLite constraints for fake data:
# attestations:
# - all fields are NOT NULL
# - attestation_root is unique
# - (validator_id, target_epoch)
# blocks:
# - all fields are NOT NULL
# - block_root is unique
# - (validator_id, slot)

suiteReport "Slashing Protection DB" & preset():
  wrappedTimedTest "Empty database" & preset():
    sqlite3db_delete(TestDir, TestDbName)
    let db = SlashingProtectionDB.init(
               default(Eth2Digest),
               TestDir,
               TestDbName
             )
    defer:
      db.close()
      sqlite3db_delete(TestDir, TestDbName)

    check:
      db.checkSlashableBlockProposal(
        fakeValidator(1234),
        slot = Slot 1
      ).isOk()
      db.checkSlashableAttestation(
        fakeValidator(1234),
        source = Epoch 1,
        target = Epoch 2
      ).isOk()
      db.checkSlashableAttestation(
        fakeValidator(1234),
        source = Epoch 2,
        target = Epoch 1
      ).error.kind == TargetPrecedesSource

  wrappedTimedTest "SP for block proposal - linear append":
    sqlite3db_delete(TestDir, TestDbName)
    let db = SlashingProtectionDB.init(
               default(Eth2Digest),
               TestDir,
               TestDbName
             )
    defer:
      db.close()
      sqlite3db_delete(TestDir, TestDbName)

    db.registerBlock(
      fakeValidator(100),
      Slot 10,
      fakeRoot(100)
    )
    db.registerBlock(
      fakeValidator(111),
      Slot 15,
      fakeRoot(111)
    )
    check:
      # Slot occupied by same validator
      db.checkSlashableBlockProposal(
        fakeValidator(100),
        slot = Slot 10
      ).isErr()
      # Slot occupied by another validator
      db.checkSlashableBlockProposal(
        fakeValidator(100),
        slot = Slot 15
      ).isOk()
      # Slot occupied by same validator
      db.checkSlashableBlockProposal(
        fakeValidator(111),
        slot = Slot 15
      ).isErr()

      # Slot inoccupied
      db.checkSlashableBlockProposal(
        fakeValidator(255),
        slot = Slot 20
      ).isOk()

    db.registerBlock(
      fakeValidator(255),
      slot = Slot 20,
      fakeRoot(4321)
    )

    check:
      # Slot now occupied
      db.checkSlashableBlockProposal(
        fakeValidator(255),
        slot = Slot 20
      ).isErr()

  wrappedTimedTest "SP for block proposal - backtracking append":
    sqlite3db_delete(TestDir, TestDbName)
    let db = SlashingProtectionDB.init(
               default(Eth2Digest),
               TestDir,
               TestDbName
             )
    defer:
      db.close()
      sqlite3db_delete(TestDir, TestDbName)

    # last finalized block
    db.registerBlock(
      fakeValidator(0),
      Slot 0,
      fakeRoot(0)
    )

    db.registerBlock(
      fakeValidator(100),
      Slot 10,
      fakeRoot(10)
    )
    db.registerBlock(
      fakeValidator(100),
      Slot 20,
      fakeRoot(20)
    )
    for i in 0 ..< 30:
      if i > 10 and i != 20: # MinSlotViolation and DupSlot
        let status = db.checkSlashableBlockProposal(
          fakeValidator(100),
          Slot i
        )
        doAssert status.isOk, "error: " & $status
      else:
        let status = db.checkSlashableBlockProposal(
          fakeValidator(100),
          Slot i
        )
        doAssert status.isErr, "error: " & $status
    db.registerBlock(
      fakeValidator(100),
      Slot 15,
      fakeRoot(15)
    )
    for i in 0 ..< 30:
      if i > 10 and i notin {15, 20}: # MinSlotViolation and DupSlot
        let status = db.checkSlashableBlockProposal(
          fakeValidator(100),
          Slot i
        )
        doAssert status.isOk, "error: " & $status
      else:
        let status = db.checkSlashableBlockProposal(
          fakeValidator(100),
          Slot i
        )
        doAssert status.isErr, "error: " & $status
        check:
          db.checkSlashableBlockProposal(
            fakeValidator(0xDEADBEEF),
            Slot i
          ).isOk()
    db.registerBlock(
      fakeValidator(100),
      Slot 12,
      fakeRoot(12)
    )
    db.registerBlock(
      fakeValidator(100),
      Slot 17,
      fakeRoot(17)
    )
    for i in 0 ..< 30:
      if i > 10 and i notin {12, 15, 17, 20}:
        let status = db.checkSlashableBlockProposal(
          fakeValidator(100),
          Slot i
        )
        doAssert status.isOk, "error: " & $status
      else:
        let status = db.checkSlashableBlockProposal(
          fakeValidator(100),
          Slot i
        )
        doAssert status.isErr, "error: " & $status
        check:
          db.checkSlashableBlockProposal(
            fakeValidator(0xDEADBEEF),
            Slot i
          ).isOk()
    db.registerBlock(
      fakeValidator(100),
      Slot 29,
      fakeRoot(29)
    )
    for i in 0 ..< 30:
      if i > 10 and i notin {12, 15, 17, 20, 29}:
        let status = db.checkSlashableBlockProposal(
          fakeValidator(100),
          Slot i
        )
        doAssert status.isOk, "error: " & $status
      else:
        let status = db.checkSlashableBlockProposal(
          fakeValidator(100),
          Slot i
        )
        doAssert status.isErr, "error: " & $status
        check:
          db.checkSlashableBlockProposal(
            fakeValidator(0xDEADBEEF),
            Slot i
          ).isOk()

  wrappedTimedTest "SP for same epoch attestation target - linear append":
    sqlite3db_delete(TestDir, TestDbName)
    let db = SlashingProtectionDB.init(
               default(Eth2Digest),
               TestDir,
               TestDbName
             )
    defer:
      db.close()
      sqlite3db_delete(TestDir, TestDbName)

    db.registerAttestation(
      fakeValidator(100),
      Epoch 0, Epoch 10,
      fakeRoot(100)
    )
    db.registerAttestation(
      fakeValidator(111),
      Epoch 0, Epoch 15,
      fakeRoot(111)
    )
    check:
      # Epoch occupied by same validator
      db.checkSlashableAttestation(
        fakeValidator(100),
        Epoch 0, Epoch 10,
      ).error.kind == DoubleVote
      # Epoch occupied by another validator
      db.checkSlashableAttestation(
        fakeValidator(100),
        Epoch 0, Epoch 15
      ).isOk()
      # Epoch occupied by same validator
      db.checkSlashableAttestation(
        fakeValidator(111),
        Epoch 0, Epoch 15
      ).error.kind == DoubleVote

      # Epoch inoccupied
      db.checkSlashableAttestation(
        fakeValidator(255),
        Epoch 0, Epoch 20
      ).isOk()

    db.registerAttestation(
      fakeValidator(255),
      Epoch 0, Epoch 20,
      fakeRoot(4321)
    )

    check:
      # Epoch now occupied
      db.checkSlashableAttestation(
        fakeValidator(255),
        Epoch 0, Epoch 20
      ).error.kind == DoubleVote

  wrappedTimedTest "SP for surrounded attestations":
    block:
      sqlite3db_delete(TestDir, TestDbName)
      let db = SlashingProtectionDB.init(
                default(Eth2Digest),
                TestDir,
                TestDbName
              )
      defer:
        db.close()
        sqlite3db_delete(TestDir, TestDbName)

      db.registerAttestation(
        fakeValidator(100),
        Epoch 10, Epoch 20,
        fakeRoot(20)
      )

      check:
        db.checkSlashableAttestation(
          fakeValidator(100),
          Epoch 11, Epoch 19
        ).error.kind == SurroundedVote
        db.checkSlashableAttestation(
          fakeValidator(200),
          Epoch 11, Epoch 19
        ).isOk
        db.checkSlashableAttestation(
          fakeValidator(100),
          Epoch 11, Epoch 21
        ).isOk

    block:
      sqlite3db_delete(TestDir, TestDbName)
      let db = SlashingProtectionDB.init(
                default(Eth2Digest),
                TestDir,
                TestDbName
              )
      defer:
        db.close()
        sqlite3db_delete(TestDir, TestDbName)

      db.registerAttestation(
        fakeValidator(100),
        Epoch 0, Epoch 1,
        fakeRoot(1)
      )

      db.registerAttestation(
        fakeValidator(100),
        Epoch 10, Epoch 20,
        fakeRoot(20)
      )

      check:
        db.checkSlashableAttestation(
          fakeValidator(100),
          Epoch 11, Epoch 19
        ).error.kind == SurroundedVote
        db.checkSlashableAttestation(
          fakeValidator(200),
          Epoch 11, Epoch 19
        ).isOk
        db.checkSlashableAttestation(
          fakeValidator(100),
          Epoch 11, Epoch 21
        ).isOk
        # TODO: is that possible?
        db.checkSlashableAttestation(
          fakeValidator(100),
          Epoch 9, Epoch 19
        ).isOk


  wrappedTimedTest "SP for surrounding attestations":
    block:
      sqlite3db_delete(TestDir, TestDbName)
      let db = SlashingProtectionDB.init(
                default(Eth2Digest),
                TestDir,
                TestDbName
              )
      defer:
        db.close()
        sqlite3db_delete(TestDir, TestDbName)

      db.registerAttestation(
        fakeValidator(100),
        Epoch 10, Epoch 20,
        fakeRoot(20)
      )

      check:
        db.checkSlashableAttestation(
          fakeValidator(100),
          Epoch 9, Epoch 21
        ).error.kind == SurroundingVote
        db.checkSlashableAttestation(
          fakeValidator(100),
          Epoch 0, Epoch 21
        ).error.kind == SurroundingVote

    block:
      sqlite3db_delete(TestDir, TestDbName)
      let db = SlashingProtectionDB.init(
                default(Eth2Digest),
                TestDir,
                TestDbName
              )
      defer:
        db.close()
        sqlite3db_delete(TestDir, TestDbName)

      db.registerAttestation(
        fakeValidator(100),
        Epoch 0, Epoch 1,
        fakeRoot(1)
      )

      db.registerAttestation(
        fakeValidator(100),
        Epoch 10, Epoch 20,
        fakeRoot(20)
      )

      check:
        db.checkSlashableAttestation(
          fakeValidator(100),
          Epoch 9, Epoch 21
        ).error.kind == SurroundingVote
        db.checkSlashableAttestation(
          fakeValidator(100),
          Epoch 0, Epoch 21
        ).error.kind == SurroundingVote

  wrappedTimedTest "Attestation ordering #1698":
    block:
      sqlite3db_delete(TestDir, TestDbName)
      let db = SlashingProtectionDB.init(
                default(Eth2Digest),
                TestDir,
                TestDbName
              )
      defer:
        db.close()
        sqlite3db_delete(TestDir, TestDbName)

      db.registerAttestation(
        fakeValidator(100),
        Epoch 1, Epoch 2,
        fakeRoot(2)
      )

      db.registerAttestation(
        fakeValidator(100),
        Epoch 8, Epoch 10,
        fakeRoot(10)
      )

      db.registerAttestation(
        fakeValidator(100),
        Epoch 14, Epoch 15,
        fakeRoot(15)
      )

      # The current list is, 2 -> 10 -> 15

      db.registerAttestation(
        fakeValidator(100),
        Epoch 3, Epoch 6,
        fakeRoot(6)
      )

      # The current list is 2 -> 6 -> 10 -> 15

      check:
        db.checkSlashableAttestation(
          fakeValidator(100),
          Epoch 7, Epoch 11
        ).error.kind == SurroundingVote

  wrappedTimedTest "Test valid attestation #1699":
    block:
      sqlite3db_delete(TestDir, TestDbName)
      let db = SlashingProtectionDB.init(
                default(Eth2Digest),
                TestDir,
                TestDbName
              )
      defer:
        db.close()
        sqlite3db_delete(TestDir, TestDbName)

      db.registerAttestation(
        fakeValidator(100),
        Epoch 10, Epoch 20,
        fakeRoot(20)
      )

      db.registerAttestation(
        fakeValidator(100),
        Epoch 40, Epoch 50,
        fakeRoot(50)
      )

      check:
        db.checkSlashableAttestation(
          fakeValidator(100),
          Epoch 20, Epoch 30
        ).isOk
