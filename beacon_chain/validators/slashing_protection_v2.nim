# beacon_chain
# Copyright (c) 2018-2021 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [Defect].}

import
  # Standard library
  std/[os, options, typetraits, decls, tables],
  # Status
  stew/byteutils,
  eth/db/[kvstore, kvstore_sqlite3],
  chronicles,
  sqlite3_abi,
  ssz_serialization,
  # Internal
  ../spec/[datatypes, digest, crypto, helpers],
  ./slashing_protection_common

# Requirements
# --------------------------------------------
#
# Overview of slashing and how it ties in with the rest of Eth2.0
#
# EIP 3076:
# https://eips.ethereum.org/EIPS/eip-3076
# https://ethereum-magicians.org/t/eip-3076-validator-client-interchange-format-slashing-protection/
#
# Phase 0 for humans - Validator responsibilities:
# - https://notes.ethereum.org/@djrtwo/Bkn3zpwxB#Validator-responsibilities
#
# Phase 0 spec - Honest Validator - how to avoid slashing
# - https://github.com/ethereum/eth2.0-specs/blob/v1.0.1/specs/phase0/validator.md#how-to-avoid-slashing
#
# In-depth reading on slashing conditions
#
# - Detecting slashing conditions https://hackmd.io/@n0ble/By897a5sH
# - Open issue on writing a slashing detector https://github.com/ethereum/eth2.0-pm/issues/63
# - Casper the Friendly Finality Gadget, Vitalik Buterin and Virgil Griffith
#   https://arxiv.org/pdf/1710.09437.pdf
#   Figure 2
#   An individual validator ν MUST NOT publish two distinct votes,
#   〈ν,s1,t1,h(s1),h(t1) AND〈ν,s2,t2,h(s2),h(t2)〉,
#   such that either:
#   I. h(t1) = h(t2).
#      Equivalently, a validator MUST NOT publish two distinct votes for the same target height.
#   OR
#   II. h(s1) < h(s2) < h(t2) < h(t1).
#      Equivalently, a validator MUST NOT vote within the span of its other votes.
# - Vitalik's annotated spec: https://github.com/ethereum/annotated-spec/blob/d8c51af84f9f309d91c37379c1fcb0810bc5f10a/phase0/beacon-chain.md#proposerslashing
#   1. A proposer can get slashed for signing two distinct headers at the same slot.
#   2. An attester can get slashed for signing
#      two attestations that together violate
#      the Casper FFG slashing conditions.
# - https://github.com/ethereum/eth2.0-specs/blob/v1.0.1/specs/phase0/validator.md#ffg-vote
#   The "source" is the current_justified_epoch
#   The "target" is the current_epoch
#
# Reading on weak subjectivity
# - https://notes.ethereum.org/@adiasg/weak-subjectvity-eth2
# - https://www.symphonious.net/2019/11/27/exploring-ethereum-2-weak-subjectivity-period/
# - https://ethresear.ch/t/weak-subjectivity-under-the-exit-queue-model/5187
#
# Reading of interop serialization format
# - Import/export format: https://hackmd.io/@sproul/Bk0Y0qdGD
# - Tests: https://github.com/eth2-clients/slashing-protection-interchange-tests
#
# Relaxation for Nimbus
#
# We are not building a slashing detector but only protecting
# attached validator from slashing, hence we make the following assumptions
#
# 1. We only need to store specific validators signed blocks and attestations
# 2. We assume that our node is synced past
#    the last finalized epoch
#    hence we only need to keep track of blocks and attestations
#    since the last finalized epoch and we don't need to care
#    about the weak subjectivity period.
#    i.e. if `Node.isSynced()` returns false
#    a node skips its validator duties and doesn't invoke slashing protection.
#    and `isSynced` syncs at least up to the blockchain last finalized epoch.
#
# Hence the database or key-value store should support
#
# Queries
# 1. db.signedBlockExistsFor(validator, slot) -> bool
# 2. db.attestationExistsFor(validator, target_epoch) -> bool
# 3. db.attestationSurrounding(validator, source_epoch, target_epoch)
# 4. db.attestationSurrounded(validator, source_epoch, target_epoch)
#
# Update
# 1. db.registerBlock(validator, slot, block_root)
# 2. db.registerAttestation(validator, source_epoch, target_epoch, attestation_root)
#
# Maintenance
# 1. db.prune(finalized_epoch)
#
# Interop
# 1. db.import(json)
# 2. db.export(json)
# 3. db.export(json, validator)
# 4. db.export(json, seq[validator])
#
# Additionally after EIP3067 slashing protection requires
# a "low watermark" protection that can be used
# instead of keeping track of the whole history (and allows pruning)
# In that case we need the following queries
#
# 1. db.signedBlockMinimalSlot (EIP3067 condition 2)
# 2. db.signedAttMinimalSourceEpoch (EIP3067 condition 4)
# 3. db.signedAttMinimalTargetEpoch (EIP3067 condition 5)

# Technical Discussion
# --------------------------------------------
#
# TODO: Merge with BeaconChainDB?
# - https://stackoverflow.com/questions/21844479/multiple-databases-vs-single-database-with-logically-partitioned-data
#
# Reasons for merging
# - Single database
#
# Reasons for not merging
# - BeaconChainDB is about the beacon node itself
#   while slashing protection is about validators
# - BeaconChainDB is append-only
#   while slashing protection will be pruned
#   at each finalization.
#   Hence we might want different backend in the future
# - In a VC/BN split configuration the slashing protection
#   may be better attached to the VC. (VC: Validator Client, BN: Beacon Node)
# - The slashing protection DB only held cryptographic hashes
#   and epoch/slot integers which are uncompressible
#   while BeaconChainDB is snappy-compressed.

# SQLite primitives
# --------------------------------------------
# For now we choose to enforce the SQLite backend as a DB (and not a KV-Store)
#
# Cons
# 1. Harder to switch away from a DB than from a KV-Store
#
# Pros
# 1. No need for adhoc per-validator range queries implementation using LinkedList
#    with high potential of bug (as found in audit)
# 2. uses robust and fuzzed SQLite codepath
# 3. Straightforward pruning
# 4. Can be maintained and inspected with standard tooling
#
# In particular the following query leads to complex code with a KV store
#
# Select 1 from attestations
# where validator = '0x1234ABCDEF'
# AND (
#   -- Don't publish distinct vote for the same target
#   (target_epoch = candidate_target_epoch)
#   -- surrounded vote
#   OR
#   (source_epoch < candidate_source_epoch and candidate_target_epoch < target_epoch)
#   -- surrounding vote
#   OR
#   (candidate_source_epoch < source_epoch and target_epoch < candidate_target_epoch)
# )
#
# Note, with SQLite splitting into multiple small queries is also efficient
# as it is embedded in the application: https://www.sqlite.org/np1queryprob.html

# Future optimizations
# --------------------------------------------
# To limit disk IO we might want to keep a data-structure in memory.
# Surround voting detection is very similar to:
# - Collision detection in games
# - point of interest localisation in geographical DBs or maps
#
# A reasonable acceleration structure would be:
# - O(log n) for adding new attestations
# - O(log n) to check for surround voting.
# - O(n) space usage
#
# Suitable inspirations may be:
# - Bounding Volume Hierarchy and Axis-ligned Bounding Boxes from collision detection
# - R-Trees from geospatial data processing and maps
# - Kd-Trees from both
# - less common structures like quadtrees and octrees
#
# See also optimizing a slashing detector for the whole chain
# - https://github.com/protolambda/eth2-surround
# - Detecting slashing conditions https://hackmd.io/@n0ble/By897a5sH
# - Open issue on writing a slashing detector https://github.com/ethereum/eth2.0-pm/issues/63

type
  SlashingProtectionDB_v2* = ref object
    ## Database storing the blocks attested
    ## by validators attached to a beacon node
    ## or validator client.
    # For now we commit to using SqLite
    # Splitting attestations queries
    # into small queries is fine with SqLite
    # https://www.sqlite.org/np1queryprob.html
    backend: SqStoreRef
    # Cached queries - write
    sqlInsertValidator: SqliteStmt[PubKeyBytes, void]
    sqlInsertAtt: SqliteStmt[(ValidatorInternalID, int64, int64, Hash32), void]
    sqlInsertBlock: SqliteStmt[(ValidatorInternalID, int64, Hash32), void]
    sqlPruneValidatorBlocks: SqliteStmt[(ValidatorInternalID, int64), void]
    sqlPruneValidatorAttestations: SqliteStmt[(ValidatorInternalID, int64, int64), void]
    sqlPruneAfterFinalizationBlocks: SqliteStmt[int64, void]
    sqlPruneAfterFinalizationAttestations: SqliteStmt[(int64, int64), void]
    # Cached queries - read
    sqlGetValidatorInternalID: SqliteStmt[PubKeyBytes, ValidatorInternalID]
    sqlAttForSameTargetEpoch: SqliteStmt[(ValidatorInternalID, int64), Hash32]
    sqlAttSurrounds: SqliteStmt[(ValidatorInternalID, int64, int64, int64, int64), (int64, int64, Hash32)]
    sqlAttMinSourceTargetEpochs: SqliteStmt[ValidatorInternalID, (int64, int64)]
    sqlBlockForSameSlot: SqliteStmt[(ValidatorInternalID, int64), Hash32]
    sqlBlockMinSlot: SqliteStmt[ValidatorInternalID, int64]

    internalIds: Table[ValidatorIndex, ValidatorInternalID]

  ValidatorInternalID = int64
    ## Validator internal ID in the DB
    ## This is cached to cost querying cost

  Hash32 = array[32, byte]

func version*(_: type SlashingProtectionDB_v2): static int =
  # version history:
  # 1 -> https://github.com/status-im/nimbus-eth2/pull/1643, based on KV-store
  2

# Internal
# -------------------------------------------------------------

{.push raises: [Defect].}
logScope:
  topics = "antislash"

template dispose(sqlStmt: SqliteStmt) =
  discard sqlite3_finalize((ptr sqlite3_stmt) sqlStmt)

proc setupDB(db: SlashingProtectionDB_v2, genesis_validators_root: Eth2Digest) =
  ## Initial setup of the DB
  # Naming:
  # - We use the same naming as https://eips.ethereum.org/EIPS/eip-3076
  #   and Lighthouse to allow loading/exporting without the Intermediate
  #   interchange format (provided we agree on a metadata format as well)
  #
  # - https://github.com/sigp/lighthouse/blob/v1.1.0/validator_client/slashing_protection/src/slashing_database.rs#L59-L88
  #
  # Differences
  # - Lighthouse uses public_key instead of pubkey as in spec

  block: # Metadata
    db.backend.exec("""
      CREATE TABLE metadata(
          slashing_db_version INTEGER,
          genesis_validators_root BLOB NOT NULL
      );
    """).expect("DB should be working and \"metadata\" should not exist")

    # TODO: db.backend.exec does not take parameters
    var rootTuple: tuple[bytes: Hash32]
    rootTuple[0] = genesis_validators_root.data
    db.backend.exec("""
      INSERT INTO
        metadata(slashing_db_version, genesis_validators_root)
      VALUES
        (""" & $db.typeof().version() & """, ?);
    """, rootTuple
    ).expect("Metadata initialized in the DB")

  block: # Tables
    db.backend.exec("""
      CREATE TABLE validators(
          id INTEGER PRIMARY KEY,
          public_key BLOB NOT NULL UNIQUE
      );
    """).expect("DB should be working and \"validators\" should not exist")

    # signing_root can be non-unique, as signing_root is not mandatory
    # and we can use a default value.
    db.backend.exec("""
      CREATE TABLE signed_blocks(
          validator_id INTEGER NOT NULL,
          slot INTEGER NOT NULL,
          signing_root BLOB NOT NULL,
          FOREIGN KEY(validator_id) REFERENCES validators(id)
          UNIQUE (validator_id, slot)
      );
    """).expect("DB should be working and \"blocks\" should not exist")

    # signing_root can be non-unique, as signing_root is not mandatory
    # and we can use a default value.
    db.backend.exec("""
      CREATE TABLE signed_attestations(
          validator_id INTEGER NOT NULL,
          source_epoch INTEGER NOT NULL,
          target_epoch INTEGER NOT NULL,
          signing_root BLOB NOT NULL,
          FOREIGN KEY(validator_id) REFERENCES validators(id)
          UNIQUE (validator_id, target_epoch)
      );
    """).expect("DB should be working and \"attestations\" should not exist")

proc checkDB(db: SlashingProtectionDB_v2, genesis_validators_root: Eth2Digest) =
  ## Check the metadata of the DB
  let selectStmt = db.backend.prepareStmt(
    "SELECT * FROM metadata;",
    NoParams, (int64, Hash32),
    managed = false # manual memory management
  ).get()

  var version: int64
  var root: Eth2Digest
  let status = selectStmt.exec do (res: (int64, Hash32)):
    version = res[0]
    root.data = res[1]

  selectStmt.dispose()

  doAssert status.isOk()
  doAssert version == db.typeof().version(),
    "Incorrect database version: " & $version & "\n" &
    "but expected: " & $db.typeof().version()
  doAssert root == genesis_validators_root,
    "Invalid database genesis validator root: " & root.data.toHex() & "\n" &
    "but expected: " & genesis_validators_root.data.toHex()

proc setupCachedQueries(db: SlashingProtectionDB_v2) =
  ## Create prepared queries for reuse

  # Note: assuming pruning every finalized epochs
  # we keep at most 64 attestations per validators
  # an index would likely be overkill.

  # Insertions
  # --------------------------------------------------------
  db.sqlInsertValidator = db.backend.prepareStmt("""
    INSERT INTO
      validators(public_key)
    VALUES
      (?);
  """, PubKeyBytes, void).get()

  db.sqlInsertAtt = db.backend.prepareStmt("""
    INSERT INTO signed_attestations(
      validator_id,
      source_epoch,
      target_epoch,
      signing_root)
    VALUES
      (?,?,?,?);
  """, (ValidatorInternalID, int64, int64, Hash32), void).get()

  db.sqlInsertBlock = db.backend.prepareStmt("""
    INSERT INTO signed_blocks(
      validator_id,
      slot,
      signing_root)
    VALUES
      (?,?,?);
    """, (ValidatorInternalID, int64, Hash32), void
  ).get()

  # Read internal validator ID
  # --------------------------------------------------------
  db.sqlGetValidatorInternalID = db.backend.prepareStmt(
    "SELECT id from validators WHERE public_key = ?;",
    PubKeyBytes, ValidatorInternalID
  ).get()

  # Inspect attestations
  # --------------------------------------------------------
  db.sqlAttForSameTargetEpoch = db.backend.prepareStmt("""
    SELECT
      signing_root
    FROM
      signed_attestations
    WHERE 1=1
      and validator_id = ?
      and target_epoch = ?
    """, (ValidatorInternalID, int64), Hash32
  ).get()

  db.sqlAttSurrounds = db.backend.prepareStmt("""
    SELECT
      source_epoch, target_epoch, signing_root
    FROM
      signed_attestations
    WHERE 1=1
      and validator_id = ?
      and ((source_epoch < ? and ? < target_epoch) OR
           (? < source_epoch and target_epoch < ?))
    LIMIT 1
    """, (ValidatorInternalID, int64, int64, int64, int64), (int64, int64, Hash32)
  ).get()

  # By default an aggregate always return a value
  # which can be NULL in SQLite.
  # However this is translated to 0 by the backend.
  # It is better to drop NULL and returns no result
  # if there is actually no result since we always
  # check SQLite status.The "GROUP BY NULL" clause drops NULL
  db.sqlAttMinSourceTargetEpochs = db.backend.prepareStmt("""
    SELECT
      MIN(source_epoch), MIN(target_epoch)
    FROM
      signed_attestations
    WHERE
      validator_id = ?
    GROUP BY
      NULL
    """, ValidatorInternalID, (int64, int64)
  ).get()

  # Inspect blocks
  # --------------------------------------------------------
  db.sqlBlockForSameSlot = db.backend.prepareStmt("""
    SELECT
      signing_root
    FROM
      signed_blocks
    WHERE 1=1
      and validator_id = ?
      and slot = ?
    """, (ValidatorInternalID, int64), Hash32
  ).get()

  # The "GROUP BY NULL" clause drops NULL
  # which makes aggregate queries more robust.
  db.sqlBlockMinSlot = db.backend.prepareStmt("""
    SELECT
      MIN(slot)
    FROM
      signed_blocks
    WHERE 1=1
      and validator_id = ?
    GROUP BY
      NULL
    """, ValidatorInternalID, int64
  ).get()

  # Pruning
  # --------------------------------------------------------

  db.sqlPruneValidatorBlocks = db.backend.prepareStmt("""
    DELETE
    FROM
      signed_blocks AS sb1
    WHERE 1=1
      and sb1.validator_id = ?
      and sb1.slot < ?
      -- Keep the most recent slot per validator
      -- even if we make a mistake and call a slot too far in the future
      and sb1.slot <> (
        SELECT MAX(sb2.slot)
        FROM signed_blocks AS sb2
        WHERE sb2.validator_id = sb1.validator_id
      )
    """, (ValidatorInternalID, int64), void
  ).get()

  db.sqlPruneValidatorAttestations = db.backend.prepareStmt("""
    DELETE
    FROM
      signed_attestations AS sa1
    WHERE 1=1
      and sa1.validator_id = ?
      and sa1.source_epoch < ?
      and sa1.target_epoch < ?
      -- Keep the most recent source_epoch per validator
      and sa1.source_epoch <> (
          SELECT MAX(sas.source_epoch)
          FROM signed_attestations AS sas
          WHERE sa1.validator_id = sas.validator_id
      )
      -- And the most recent target_epoch per validator
      -- even if we make a mistake and call an epoch too far in the future
      and sa1.target_epoch <> (
          SELECT MAX(sat.target_epoch)
          FROM signed_attestations AS sat
          WHERE sa1.validator_id = sat.validator_id
      )
    """, (ValidatorInternalID, int64, int64), void
  ).get()

  # Important:
  # The query plan MUST NOT involve correlated subqueries for speed concerns on 2000+ validators.
  # use temporary tables or views instead

  db.sqlPruneAfterFinalizationBlocks = db.backend.prepareStmt("""
    WITH max_proposer_slot AS (
      SELECT
        validator_id,
        MAX(slot) AS max_slot
      FROM
        signed_blocks
      GROUP BY
        validator_id
      ORDER BY
        validator_id
    )
    DELETE
    FROM
      signed_blocks
    -- Delete everything except ...
    WHERE ROWID NOT IN (
      SELECT sb.ROWID
      FROM
        signed_blocks sb
      LEFT JOIN
        max_proposer_slot on max_proposer_slot.validator_id = sb.validator_id
      WHERE
        -- last finalized slot or later
        sb.slot >= ?
        -- also keep the most recent slot per validator
        or sb.slot = max_proposer_slot.max_slot
    )
    """, int64, void
  ).get()

  db.sqlPruneAfterFinalizationAttestations = db.backend.prepareStmt("""
    WITH
      max_source AS (
        SELECT
          validator_id,
          MAX(source_epoch) AS max_source_epoch
        FROM
          signed_attestations
        GROUP BY
          validator_id
        ORDER BY
          validator_id
      ),
      max_target AS (
        SELECT
          validator_id,
          MAX(target_epoch) AS max_target_epoch
        FROM
          signed_attestations
        GROUP BY
          validator_id
        ORDER BY
          validator_id
      )
    DELETE
    FROM
      signed_attestations
    -- Delete everything except ...
    WHERE ROWID NOT IN (
      SELECT sa.ROWID
      FROM
        signed_attestations sa
      LEFT JOIN
        max_source on max_source.validator_id = sa.validator_id
      LEFT JOIN
        max_target on max_target.validator_id = sa.validator_id
      WHERE
        -- last finalized epochs or later
        source_epoch >= ?
        or target_epoch >= ?
        -- Keep the most recent source_epoch per validator
        or sa.source_epoch = max_source.max_source_epoch
        -- And the most recent target_epoch per validator
        or sa.target_epoch = max_target.max_target_epoch
    )
     """, (int64, int64), void
  ).get()

# DB Multiversioning
# -------------------------------------------------------------

func getRawDBHandle*(db: SlashingProtectionDB_v2): SqStoreRef =
  ## Get the underlying raw DB handle
  db.backend

proc getMetadataTable_DbV2*(db: SlashingProtectionDB_v2): Option[Eth2Digest] =
  ## Check if the DB has v2 metadata
  ## and get its genesis root
  let existenceStmt = db.backend.prepareStmt("""
    SELECT 1
     FROM sqlite_master
     WHERE 1=1
       and type='table'
       and name='metadata'
    """, NoParams, int64,
    managed = false # manual memory management
  ).get()

  var hasV2: int64
  let v2exists = existenceStmt.exec do (res: int64):
    hasV2 = res

  existenceStmt.dispose()


  if v2exists.isErr():
    return none(Eth2Digest)
  elif hasV2 == 0:
    return none(Eth2Digest)

  let selectStmt = db.backend.prepareStmt(
    "SELECT * FROM metadata;",
    NoParams, (int64, Hash32),
    managed = false # manual memory management
  ).get()

  var version: int64
  var root: Eth2Digest
  let status = selectStmt.exec do (res: (int64, Hash32)):
    version = res[0]
    root.data = res[1]

  selectStmt.dispose()

  if status.isOk():
    # Privacy, don't display the user private path
    if version != db.typeof.version():
      fatal "Incorrect DB version",
        found = version,
        expected = db.typeof.version()
      quit 1
    return some(root)
  else:
    return none(Eth2Digest)

proc initCompatV1*(T: type SlashingProtectionDB_v2,
           genesis_validators_root: Eth2Digest,
           basePath: string,
           dbname: string
     ): tuple[db: SlashingProtectionDB_v2, requiresMigration: bool] =
  ## Initialize a new slashing protection database
  ## or load an existing one with matching genesis root
  ## `dbname` MUST not be ending with .sqlite3

  let alreadyExists = fileExists(basepath/dbname&".sqlite3")

  result.db = T(backend: SqStoreRef.init(
      basePath, dbname,
    ).get())
  if alreadyExists and result.db.getMetadataTable_DbV2().isSome():
    result.db.checkDB(genesis_validators_root)
    result.requiresMigration = false
  elif alreadyExists:
    result.db.setupDB(genesis_validators_root)
    result.requiresMigration = true
  else:
    result.db.setupDB(genesis_validators_root)
    result.requiresMigration = false

  # Cached queries
  result.db.setupCachedQueries()

# Resource Management
# -------------------------------------------------------------

proc init*(T: type SlashingProtectionDB_v2,
           genesis_validators_root: Eth2Digest,
           basePath: string,
           dbname: string): T =
  ## Initialize a new slashing protection database
  ## or load an existing one with matching genesis root
  ## `dbname` MUST not be ending with .sqlite3

  let alreadyExists = fileExists(basepath/dbname&".sqlite3")

  result = T(backend: SqStoreRef.init(basePath, dbname, keyspaces = []).get())
  if alreadyExists:
    result.checkDB(genesis_validators_root)
  else:
    result.setupDB(genesis_validators_root)

  # Cached queries
  result.setupCachedQueries()

proc loadUnchecked*(
       T: type SlashingProtectionDB_v2,
       basePath, dbname: string, readOnly: bool
     ): SlashingProtectionDB_v2 {.raises:[Defect, IOError].}=
  ## Load a slashing protection DB
  ## Note: This is for conversion usage in ncli_slashing
  ##       this doesn't check the genesis validator root
  ##
  ## Privacy: This leaks user folder hierarchy in case the file does not exist
  let path = basepath/dbname&".sqlite3"
  let alreadyExists = fileExists(path)
  if not alreadyExists:
    raise newException(IOError, "DB '" & path & "' does not exist.")
  result = T(backend: SqStoreRef.init(basePath, dbname, readOnly = readOnly).get())

  # Cached queries
  result.setupCachedQueries()

proc close*(db: SlashingProtectionDB_v2) =
  ## Close a slashing protection database
  db.backend.close()

# DB Queries
# -------------------------------------------------------------

proc foundAnyResult(status: KVResult[bool]): bool {.inline.}=
  ## Checks a DB query status for errors
  ## Then returns true if any result was found
  ## and false otherwise.
  ## There are 2 layers to a DB result
  ## 1. Did the query result in error.
  ##    This is a logic bug and crashes NBC in this proc.
  ## 2. Did the query return any line.
  status.expect("DB is not corrupted and query is working")

proc getValidatorInternalID(
       db: SlashingProtectionDB_v2,
       index: Option[ValidatorIndex],
       validator: ValidatorPubKey): Option[ValidatorInternalID] =
  ## Retrieve a validator internal ID
  if index.isSome():
    # Validator keys are mapped to internal id:s instead of using the
    # validator index - this allows importing keys without knowing the
    # state but has the unfortunate consequence of introducing an indirection
    # that must be kept updated at some cost. In a future version of the
    # database, one could consider a simplified design that directly uses the
    # validator index. In the meantime, this cache avoids some of the
    # unnecessary read traffic when checking and registering entries.
    db.internalIds.withValue(index.get(), internal) do:
      return some(internal[])

  let serializedPubkey = validator.toRaw() # Miracl/BLST to bytes
  var valID: ValidatorInternalID
  let status = db.sqlGetValidatorInternalID.exec(serializedPubkey) do (res: ValidatorInternalID):
    valID = res

  # Note: we enforce at the DB level that if the pubkey exists it is unique.
  if status.foundAnyResult():
    if index.isSome():
      db.internalIds[index.get()] = valID
    some(valID)
  else:
    none(ValidatorInternalID)

proc checkSlashableBlockProposalOther(
       db: SlashingProtectionDB_v2,
       valID: ValidatorInternalID,
       slot: Slot
     ): Result[void, BadProposal] =
  ## Returns an error if the specified validator
  ## already proposed a block for the specified slot.
  ## This would lead to slashing.
  ## The error contains the blockroot that was already proposed
  ##
  ## Returns success otherwise
  # TODO distinct type for the result block root

  # EIP-3067 - Low-watermark
  # Detect h(t1) <= h(t2)
  # ---------------------------------
  block:
    # Condition 2 at https://eips.ethereum.org/EIPS/eip-3076
    # Low-watermark. This is not in the Eth2 official spec
    # but a client standard.
    #
    # > Refuse to sign any block with
    # > slot <= min(b.slot for b in data.signed_blocks if b.pubkey == proposer_pubkey),
    # > except if it is a repeat signing as determined by the signing_root.

    var minSlot: int64
    let status = db.sqlBlockMinSlot.exec(valID) do (res: int64):
      minSlot = res
    if status.foundAnyResult():
      # 6 second (minimal preset) slots => overflow at ~1.75 trillion years
      # under minimal preset, and twice that under mainnet preset
      doAssert slot <= high(int64).uint64

      if int64(slot) <= minSlot:
        return err(BadProposal(
          kind: MinSlotViolation,
          minSlot: Slot minSlot,
          candidateSlot: slot
        ))

  ok()

proc checkSlashableBlockProposalDoubleProposal(
       db: SlashingProtectionDB_v2,
       valID: ValidatorInternalID,
       slot: Slot
     ): Result[void, BadProposal] =
  ## Returns an error if the specified validator
  ## already proposed a block for the specified slot.
  ## This would lead to slashing.
  ## The error contains the blockroot that was already proposed
  ##
  ## Returns success otherwise
  # TODO distinct type for the result block root

  # Casper FFG 1st slashing condition
  # Detect h(t1) = h(t2)
  # ---------------------------------
  block:
    # Condition 1 at https://eips.ethereum.org/EIPS/eip-3076
    var root: ETH2Digest
    let status = db.sqlBlockForSameSlot.exec(
          (valID, int64 slot)
        ) do (res: Hash32):
      root.data = res

    # Note: we enforce at the DB level that if (pubkey, slot) exists it maps to a unique block root.
    #
    # It's possible to allow republishing an already signed block here (Lighthouse does it)
    # AFAIK repeat signing only happens if the node crashes after saving to the DB and
    # there is still time to redo the validator work but:
    # - will the validator have reconstructed the same state in memory?
    #   for example if the validator has different attestations
    #   it can't reconstruct the previous signed block anyway.
    # - it is useful if the validator couldn't gossip.
    # Rather than adding Result "Ok" and Result "OkRepeatSigning"
    # and an extra Eth2Digest comparison for that case, we just refuse repeat signing.
    if status.foundAnyResult():
      # Conflicting block exist
      return err(BadProposal(
        kind: DoubleProposal,
        existing_block: root))

  ok()

proc checkSlashableBlockProposal*(
       db: SlashingProtectionDB_v2,
       index: Option[ValidatorIndex],
       validator: ValidatorPubKey,
       slot: Slot
     ): Result[void, BadProposal] =
  ## Returns an error if the specified validator
  ## already proposed a block for the specified slot.
  ## This would lead to slashing.
  ## The error contains the blockroot that was already proposed
  ##
  ## Returns success otherwise
  # TODO distinct type for the result block root

  let valID = block:
    let id = db.getValidatorInternalID(index, validator)
    if id.isNone():
      notice "No slashing protection data - first block proposal?",
        validator = validator,
        slot = slot
      return ok()
    else:
      id.unsafeGet()

  ? checkSlashableBlockProposalDoubleProposal(db, valID, slot)
  ? checkSlashableBlockProposalOther(db, valID, slot)

  ok()

proc checkSlashableAttestationDoubleVote(
       db: SlashingProtectionDB_v2,
       valID: ValidatorInternalID,
       source: Epoch,
       target: Epoch): Result[void, BadVote] =
  # Sanity
  # ---------------------------------
  if source > target:
    return err(BadVote(kind: TargetPrecedesSource))

  # Casper FFG 1st slashing condition
  # Detect h(t1) = h(t2)
  # ---------------------------------
  block:
    # Condition 3 part 1/3 at https://eips.ethereum.org/EIPS/eip-3076
    var root: ETH2Digest

    # Overflows in 14 trillion years (minimal) or 112 trillion years (mainnet)
    doAssert target <= high(int64).uint64

    let status = db.sqlAttForSameTargetEpoch.exec(
          (valID, int64 target)
        ) do (res: Hash32):
      root.data = res

    # Note: we enforce at the DB level that if (pubkey, target) exists it maps to a unique block root.
    if status.foundAnyResult():
      # Conflicting attestation exist, log by caller
      return err(BadVote(
        kind: DoubleVote,
        existingAttestation: root
      ))

  ok()

proc checkSlashableAttestationOther(
       db: SlashingProtectionDB_v2,
       valID: ValidatorInternalID,
       source: Epoch,
       target: Epoch): Result[void, BadVote] =
  # Simple double votes are protected by the unique index on the database table
  # - this function checks everything else!

  ## Returns an error if the specified validator
  ## already voted for the specified slot
  ## or would vote in a contradiction to previous votes
  ## (surrounding vote or surrounded vote).
  ##
  ## Returns success otherwise
  # TODO distinct type for the result attestation root

  # Sanity
  # ---------------------------------
  if source > target:
    return err(BadVote(kind: TargetPrecedesSource))

  # Casper FFG 2nd slashing condition
  # -> Surrounded vote
  # Detect h(s1) < h(s2) < h(t2) < h(t1)
  # -> Surrounding vote
  # Detect h(s2) < h(s1) < h(t1) < h(t2)
  # ---------------------------------
  block:
    # Condition 3 part 2/3 at https://eips.ethereum.org/EIPS/eip-3076
    # Condition 3 part 3/3 at https://eips.ethereum.org/EIPS/eip-3076
    var root: ETH2Digest
    var db_source, db_target: Epoch

    # Overflows in 14 trillion years (minimal) or 112 trillion years (mainnet)
    doAssert source <= high(int64).uint64
    doAssert target <= high(int64).uint64

    let status = db.sqlAttSurrounds.exec(
          (valID, int64 source, int64 target, int64 source, int64 target)
        ) do (res: tuple[source, target: int64, root: Hash32]):
      db_source = Epoch res.source
      db_target = Epoch res.target
      root.data = res.root

    # Note: we enforce at the DB level that if (pubkey, target) exists it maps to a unique block root.
    if status.foundAnyResult():
      # Conflicting attestation exist, log by caller
      # s1 < s2 < t2 < t1
      return err(BadVote(
        kind: SurroundVote,
        existingAttestationRoot: root,
        sourceExisting: db_source,
        targetExisting: db_target,
        sourceSlashable: source,
        targetSlashable: target
      ))

  # EIP-3067 - Low-watermark
  # Detect h(s1) < h(s2), h(t1) <= h(t2)
  # ---------------------------------
  # Source check is strict inequality
  block:
    # Conditions 4 and 5 at https://eips.ethereum.org/EIPS/eip-3076
    # Low-watermark. This is not in the Eth2 official spec
    # but a client standard.
    #
    # > Refuse to sign any attestation with source epoch less than the minimum source epoch present in that signer’s attestations
    # > Refuse to sign any attestation with target epoch less than or equal to the minimum target epoch present in that signer’s attestations
    var minSourceEpoch, minTargetEpoch: int64
    let status = db.sqlAttMinSourceTargetEpochs.exec(
          valID
        ) do (res: tuple[source, target: int64]):
      minSourceEpoch = res.source
      minTargetEpoch = res.target

    if status.foundAnyResult():
      # Overflows in 14 trillion years (minimal) or 112 trillion years (mainnet)
      doAssert source <= high(int64).uint64

      if source.int64 < minSourceEpoch:
        return err(BadVote(
          kind: MinSourceViolation,
          minSource: Epoch minSourceEpoch,
          candidateSource: source
        ))

      # Overflows in 14 trillion years (minimal) or 112 trillion years (mainnet)
      doAssert target <= high(int64).uint64

      if target.int64 <= minTargetEpoch:
        return err(BadVote(
          kind: MinTargetViolation,
          minTarget: Epoch minSourceEpoch,
          candidateTarget: target
        ))

  ok()

proc checkSlashableAttestation*(
       db: SlashingProtectionDB_v2,
       index: Option[ValidatorIndex],
       validator: ValidatorPubKey,
       source: Epoch,
       target: Epoch
     ): Result[void, BadVote] =
  if source > target:
    return err(BadVote(kind: TargetPrecedesSource))

  let valID = block:
    let id = db.getValidatorInternalID(index, validator)
    if id.isNone():
      notice "No slashing protection data - first attestation?",
        validator, source, target
      return ok()
    else:
      id.unsafeGet()

  ? checkSlashableAttestationDoubleVote(db, valID, source, target)
  ? checkSlashableAttestationOther(db, valID, source, target)

  ok()

# DB update
# --------------------------------------------

proc registerValidator(db: SlashingProtectionDB_v2, validator: ValidatorPubKey) =
  ## Get validator from the database
  ## or register it
  ## Assumes the validator does not exist
  let serializedPubkey = validator.toRaw() # Miracl/BLST to bytes
  let status = db.sqlInsertValidator.exec(serializedPubkey)
  doAssert status.isOk()

proc getOrRegisterValidator(
       db: SlashingProtectionDB_v2,
       index: Option[ValidatorIndex],
       validator: ValidatorPubKey): ValidatorInternalID =
  ## Get validator from the database
  ## or register it and then return it
  let id = db.getValidatorInternalID(index, validator)
  if id.isNone():
    info "No slashing protection data for validator - initiating",
      validator = validator

    db.registerValidator(validator)
    let id = db.getValidatorInternalID(index, validator)
    doAssert id.isSome()
    id.unsafeGet()
  else:
    id.unsafeGet()

proc registerBlock*(
       db: SlashingProtectionDB_v2,
       index: Option[ValidatorIndex],
       validator: ValidatorPubKey,
       slot: Slot, block_root: Eth2Digest): Result[void, BadProposal] =
  ## Add a block to the slashing protection DB
  ## `checkSlashableBlockProposal` MUST be run
  ## before to ensure no overwrite.
  let valID = db.getOrRegisterValidator(index, validator)

  # 6 second (minimal preset) slots => overflow at ~1.75 trillion years under
  # minimal preset, and twice that with mainnet preset
  doAssert slot <= high(int64).uint64

  let check = checkSlashableBlockProposalOther(db, valID, slot)
  if check.isErr():
    # Check for double vote to get more accurate error information
    ? checkSlashableBlockProposalDoubleProposal(db, valID, slot)
    return check

  let status = db.sqlInsertBlock.exec(
    (valID, int64 slot, block_root.data))
  if status.isErr():
    # Inserting primarily fails when the constraint for double proposals is
    # violated but may also happen due to disk full and other storage issues -
    # in any case, we'll return an error so that production is halted
    ? checkSlashableBlockProposalDoubleProposal(db, valID, slot)
    # If this was not a slashing error, it must have been a database error
    return err(BadProposal(
      kind: BadProposalKind.DatabaseError,
      message: status.error))

  ok()

proc registerBlock*(
       db: SlashingProtectionDB_v2,
       validator: ValidatorPubKey,
       slot: Slot, block_root: Eth2Digest): Result[void, BadProposal] =
  registerBlock(db, none(ValidatorIndex), validator, slot, block_root)

proc registerAttestation*(
       db: SlashingProtectionDB_v2,
       index: Option[ValidatorIndex],
       validator: ValidatorPubKey,
       source, target: Epoch,
       attestation_root: Eth2Digest): Result[void, BadVote] =
  ## Add an attestation to the slashing protection DB
  ## `checkSlashableAttestation` MUST be run
  ## before to ensure no overwrite.
  if source > target:
    return err(BadVote(kind: TargetPrecedesSource))

  let valID = db.getOrRegisterValidator(index, validator)

  # Double votes caught by database index!
  let check = checkSlashableAttestationOther(db, valID, source, target)

  if check.isErr():
    # Check for double vote to get more accurate error information
    ? checkSlashableAttestationDoubleVote(db, valID, source, target)
    return check

  # Overflows in 14 trillion years (minimal) or 112 trillion years (mainnet)
  doAssert source <= high(int64).uint64
  doAssert target <= high(int64).uint64

  let status = db.sqlInsertAtt.exec(
    (valID, int64 source, int64 target,
    attestation_root.data))
  if status.isErr():
    # Inserting primarily fails when the constraint for double votes is
    # violated but may also happen due to disk full and other storage issues -
    # in any case, we'll return an error so that production is halted
    ? checkSlashableAttestationDoubleVote(db, valID, source, target)
    # If this was not a slashing error, it must have been a database error
    return err(BadVote(
      kind: BadVoteKind.DatabaseError,
      message: status.error))

  ok()

proc registerAttestation*(
       db: SlashingProtectionDB_v2,
       validator: ValidatorPubKey,
       source, target: Epoch,
       attestation_root: Eth2Digest): Result[void, BadVote] =
  registerAttestation(
    db, none(ValidatorIndex), validator, source, target, attestation_root)
# DB maintenance
# --------------------------------------------
proc pruneBlocks*(
    db: SlashingProtectionDB_v2,
    index: Option[ValidatorIndex],
    validator: ValidatorPubkey, newMinSlot: Slot) =
  ## Prune all blocks from a validator before the specified newMinSlot
  ## This is intended for interchange import to ensure
  ## that in case of a gap, we don't allow signing in that gap.
  let valID = db.getOrRegisterValidator(index, validator)
  let status = db.sqlPruneValidatorBlocks.exec(
    (valID, int64 newMinSlot))
  doAssert status.isOk(),
    "SQLite error when pruning validator blocks: " & $status.error & "\n" &
    "for validator: 0x" & validator.toHex() & ", newMinSlot: " & $newMinSlot

proc pruneBlocks*(
    db: SlashingProtectionDB_v2,
    validator: ValidatorPubkey, newMinSlot: Slot) =
  pruneBlocks(db, none(ValidatorIndex), validator, newMinSlot)

proc pruneAttestations*(
       db: SlashingProtectionDB_v2,
       index: Option[ValidatorIndex],
       validator: ValidatorPubkey,
       newMinSourceEpoch: int64,
       newMinTargetEpoch: int64) =
  ## Prune all blocks from a validator before the specified newMinSlot
  ## This is intended for interchange import.
  ## Negative source/target epoch of -1 can be received if no attestation was imported
  ## In that case nothing is done (since we used signed int in SQLite)
  let valID = db.getOrRegisterValidator(index, validator)

  let status = db.sqlPruneValidatorAttestations.exec(
    (valID, newMinSourceEpoch, newMinTargetEpoch))
  doAssert status.isOk(),
    "SQLite error when pruning validator attestations: " & $status.error & "\n" &
    "for validator: 0x" & validator.toHex() &
    ", newSourceEpoch: " & $newMinSourceEpoch &
    ", newTargetEpoch: " & $newMinTargetEpoch

proc pruneAttestations*(
       db: SlashingProtectionDB_v2,
       validator: ValidatorPubkey,
       newMinSourceEpoch: int64,
       newMinTargetEpoch: int64) =
  pruneAttestations(
    db, none(ValidatorIndex), validator, newMinSourceEpoch, newMinTargetEpoch)

proc pruneAfterFinalization*(
       db: SlashingProtectionDB_v2,
       finalizedEpoch: Epoch
     ) =
  ## Prune blocks and attestations after a specified `finalizedEpoch`
  ## The block with the highest slot
  ## and the attestation(s) with the highest source and target epochs
  ## are never pruned.
  ##
  ## This ensures that even if pruning is called with an incorrect epoch
  ## slashing protection can fallback to the minimal / high-watermark protection mode.

  block: # Prune blocks
    let finalizedSlot = compute_start_slot_at_epoch(finalizedEpoch)
    let status = db.sqlPruneAfterFinalizationBlocks
                   .exec(int64 finalizedSlot)
    doAssert status.isOk(),
      "SQLite error when pruning validator attestations: " & $status.error & "\n" &
      "for " &
      "finalizedEpoch: " & $finalizedEpoch &
      ", firstSlotOfFinalizedEpoch: " & $finalizedSlot

  block: # Prune attestations
    let status = db.sqlPruneAfterFinalizationAttestations
                   .exec((int64 finalizedEpoch, int64 finalizedEpoch))
    doAssert status.isOk(),
      "SQLite error when pruning validator attestations: " & $status.error & "\n" &
      "for finalized epoch: " & $finalizedEpoch

# Interchange
# --------------------------------------------

proc toSPDIR*(db: SlashingProtectionDB_v2): SPDIR
             {.raises: [IOError, Defect].} =
  ## Export the full slashing protection database
  ## to a json the Slashing Protection Database Interchange (Complete) Format
  result.metadata.interchange_format_version = "5"

  # genesis_validators_root
  # -----------------------------------------------------
  block:
    let selectRootStmt = db.backend.prepareStmt(
      "SELECT genesis_validators_root FROM metadata;",
      NoParams, Hash32,
      managed = false # manual memory management
    ).get()

    # Can't capture var SPDIR in a closure
    let genesis_validators_root {.byaddr.} = result.metadata.genesis_validators_root
    let status = selectRootStmt.exec do (res: Hash32):
      genesis_validators_root = Eth2Digest0x(ETH2Digest(data: res))
    doAssert status.isOk()

    selectRootStmt.dispose()

  # Validators
  # -----------------------------------------------------
  block:
    let selectValStmt = db.backend.prepareStmt(
      "SELECT public_key FROM validators;",
      NoParams, PubKeyBytes,
      managed = false # manual memory management
    ).get()

    # Can't capture var SPDIR in a closure
    let data {.byaddr.} = result.data
    let status = selectValStmt.exec do (res: PubKeyBytes):
      data.add SPDIR_Validator(pubkey: PubKey0x res)
    doAssert status.isOk()

    selectValStmt.dispose()

  # For each validator found, collect their signatures
  # -----------------------------------------------------
  block:
    let selectBlkStmt = db.backend.prepareStmt("""
      SELECT
        slot, signing_root
      FROM
        signed_blocks b
      INNER JOIN
        validators v on b.validator_id = v.id
      WHERE
        v.public_key = ?
      ORDER BY
        slot ASC
      """, PubKeyBytes, (int64, Hash32),
      managed = false # manual memory management
    ).get()

    let selectAttStmt = db.backend.prepareStmt("""
      SELECT
        source_epoch, target_epoch, signing_root
      FROM
        signed_attestations a
      INNER JOIN
        validators v on a.validator_id = v.id
      WHERE
        v.public_key = ?
      ORDER BY
        target_epoch ASC
      """, PubKeyBytes, (int64, int64, Hash32),
      managed = false # manual memory management
    ).get()

    defer:
      selectBlkStmt.dispose()
      selectAttStmt.dispose()

    for i in 0 ..< result.data.len:
      # Can't capture var SPDIR in a closure
      let validator {.byaddr.} = result.data[i] # alias
      block: # Blocks
        let status = selectBlkStmt.exec(validator.pubkey.PubKeyBytes) do (res: tuple[slot: int64, root: Hash32]):
          validator.signed_blocks.add SPDIR_SignedBlock(
            slot: SlotString res.slot,
            signing_root: Eth2Digest0x(Eth2Digest(data: res.root))
          )
        doAssert status.isOk()
      block: # Attestations
        let status = selectAttStmt.exec(validator.pubkey.PubKeyBytes) do (res: tuple[source, target: int64, root: Hash32]):
          validator.signed_attestations.add SPDIR_SignedAttestation(
            source_epoch: EpochString res.source,
            target_epoch: EpochString res.target,
            signing_root: Eth2Digest0x(Eth2Digest(data: res.root))
          )
        doAssert status.isOk()

proc inclSPDIR*(db: SlashingProtectionDB_v2, spdir: SPDIR): SlashingImportStatus
             {.raises: [SerializationError, IOError, Defect].} =
  ## Import a Slashing Protection Database Intermediate Representation
  ## file into the specified slashing protection DB
  ##
  ## The database must be initialized.
  ## The genesis_validators_root must match or
  ## the DB must have a zero root
  ##
  ## This return true if the import was completed successfully.
  ## It will return false if the import failed.
  ##
  ## If some blocks/votes
  ## are in invalid due to slashing rules, they will be skipped.
  doAssert not db.isNil, "The Slashing Protection DB must be initialized."
  doAssert not db.backend.isNil, "The Slashing Protection DB must be initialized."

  # genesis_validators_root
  # -----------------------------------------------------
  block:
    var dbGenValRoot: ETH2Digest

    let selectRootStmt = db.backend.prepareStmt(
      "SELECT genesis_validators_root FROM metadata;",
      NoParams, Hash32,
      managed = false # manual memory management
    ).get()

    let status = selectRootStmt.exec do (res: Hash32):
      dbGenValRoot.data = res
    doAssert status.isOk()

    selectRootStmt.dispose()

    if dbGenValRoot != default(Eth2Digest) and
         dbGenValRoot != spdir.metadata.genesis_validators_root.Eth2Digest:
      error "The slashing protection database and imported file refer to different blockchains.",
        DB_genesis_validators_root = dbGenValRoot,
        Imported_genesis_validators_root = spdir.metadata.genesis_validators_root.Eth2Digest
      return siFailure

    if not status.get():
      # Query worked but returned no result
      # We assume that the DB wasn't setup or
      # is in an earlier version that used the kvstore table
      db.setupDB(spdir.metadata.genesis_validators_root.Eth2Digest)

    # TODO: dbGenValRoot == default(Eth2Digest)

  db.setupCachedQueries()

  # Create a mutable copy for sorting
  var spdir = spdir
  return db.importInterchangeV5Impl(spdir)
