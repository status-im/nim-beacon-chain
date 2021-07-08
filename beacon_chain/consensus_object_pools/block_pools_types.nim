# beacon_chain
# Copyright (c) 2018-2021 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [Defect].}

import
  # Standard library
  std/[sets, tables, hashes],
  # Status libraries
  stew/endians2, chronicles,
  eth/keys,
  # Internals
  ../spec/[crypto, digest, signatures_batch, forkedbeaconstate_helpers],
  ../spec/datatypes/[phase0, altair],
  ".."/[beacon_chain_db, beacon_clock, extras]

export sets, tables

# #############################################
#
#            Quarantine & DAG
#
# #############################################
#
# The Quarantine and DagChain data structures
# keep track respectively of unsafe blocks coming from the network
# and blocks that underwent verification and have a resolved path to
# the last finalized block known.

type
  BlockError* = enum
    MissingParent ##\
      ## We don't know the parent of this block so we can't tell if it's valid
      ## or not - it'll go into the quarantine and be reexamined when the parent
      ## appears or be discarded if finality obsoletes it

    Unviable ##\
      ## Block is from a different history / fork than the one we're interested
      ## in (based on our finalized checkpoint)

    Invalid ##\
      ## Block is broken / doesn't apply cleanly - whoever sent it is fishy (or
      ## we're buggy)
    Old
    Duplicate

  QuarantineRef* = ref object
    ## Keeps track of unsafe blocks coming from the network
    ## and that cannot be added to the chain
    ##
    ## This only stores valid blocks that cannot be linked to the
    ## ChainDAGRef DAG due to missing ancestor(s).
    ##
    ## Invalid blocks are dropped immediately.

    orphansPhase0*: Table[(Eth2Digest, ValidatorSig), phase0.SignedBeaconBlock] ##\
    ## Phase 0 Blocks that have passed validation but that we lack a link back
    ## to tail for - when we receive a "missing link", we can use this data to
    ## build an entire branch

    orphansAltair*: Table[(Eth2Digest, ValidatorSig), altair.SignedBeaconBlock] ##\
    ## Altair Blocks that have passed validation, but that we lack a link back
    ## to tail for - when we receive a "missing link", we can use this data to
    ## build an entire branch

    missing*: Table[Eth2Digest, MissingBlock] ##\
    ## Roots of blocks that we would like to have (either parent_root of
    ## unresolved blocks or block roots of attestations)

    sigVerifCache*: BatchedBLSVerifierCache ##\
    ## A cache for batch BLS signature verification contexts
    rng*: ref BrHmacDrbgContext  ##\
    ## A reference to the Nimbus application-wide RNG

    inAdd*: bool

  MissingBlock* = object
    tries*: int

  FetchRecord* = object
    root*: Eth2Digest

  KeyedBlockRef* = object
    # Special wrapper for BlockRef used in ChainDAG.blocks that allows lookup
    # by root without keeping a Table that keeps a separate copy of the digest
    # At the time of writing, a Table[Eth2Digest, BlockRef] adds about 100mb of
    # unnecessary overhead.
    data: BlockRef

  ChainDAGRef* = ref object
    ## Pool of blocks responsible for keeping a DAG of resolved blocks.
    ##
    ## It is responsible for the following
    ##
    ## - Handle requests and updates to the "ColdDB" which
    ##   holds the canonical chain.
    ## - Maintain a direct acyclic graph (DAG) of
    ##   candidate chains from the last
    ##   finalized block.
    ##
    ## When a chain becomes finalized, it is saved in the ColdDB,
    ## the rejected candidates are discarded and this pool
    ## is pruned, only keeping the last finalized block.
    ##
    ## The last finalized block is called the tail block.

    # -----------------------------------
    # ColdDB - Canonical chain

    db*: BeaconChainDB ##\
      ## ColdDB - Stores the canonical chain

    beaconClock*: BeaconClock

    # -----------------------------------
    # ChainDAGRef - DAG of candidate chains

    blocks*: HashSet[KeyedBlockRef] ##\
    ## Directed acyclic graph of blocks pointing back to a finalized block on the chain we're
    ## interested in - we call that block the tail

    genesis*: BlockRef ##\
    ## The genesis block of the network

    tail*: BlockRef ##\
    ## The earliest finalized block we know about

    heads*: seq[BlockRef] ##\
    ## Candidate heads of candidate chains

    finalizedHead*: BlockSlot ##\
    ## The latest block that was finalized according to the block in head
    ## Ancestors of this block are guaranteed to have 1 child only.

    # -----------------------------------
    # Pruning metadata

    lastPrunePoint*: BlockSlot ##\
    ## The last prune point
    ## We can prune up to finalizedHead

    # -----------------------------------
    # Rewinder - Mutable state processing

    headState*: StateData ##\
    ## State given by the head block - must only be updated in `updateHead` -
    ## always matches dag.head

    epochRefState*: StateData ##\
      ## State used to produce epochRef instances - must only be used in
      ## `getEpochRef`

    clearanceState*: StateData ##\
      ## Cached state used during block clearance - must only be used in
      ## clearance module

    updateFlags*: UpdateFlags

    cfg*: RuntimeConfig

    epochRefs*: array[32, EpochRef] ##\
      ## Cached information about a particular epoch ending with the given
      ## block - we limit the number of held EpochRefs to put a cap on
      ## memory usage

    forkDigests*: ForkDigestsRef
      ## Cached copy of the fork digests associated with the current
      ## database. We use a ref type to facilitate sharing this small
      ## value with other components which don't have access to the
      ## full ChainDAG.

  EpochKey* = object
    ## The epoch key fully determines the shuffling for proposers and
    ## committees in a beacon state - the epoch level information in the state
    ## is derived from the last known block in the particular history _before_
    ## the beginning of that epoch, and then advanced with slot processing to
    ## the epoch start - we call this block the "epoch ancestor" in other parts
    ## of the code.
    epoch*: Epoch
    blck*: BlockRef

  EpochRef* = ref object
    dag*: ChainDAGRef
    key*: EpochKey
    current_justified_checkpoint*: Checkpoint
    finalized_checkpoint*: Checkpoint
    eth1_data*: Eth1Data
    eth1_deposit_index*: uint64
    beacon_proposers*: array[SLOTS_PER_EPOCH, Option[ValidatorIndex]]
    shuffled_active_validator_indices*: seq[ValidatorIndex]
    # TODO this updates at a lower cadence
    #      (once per EPOCHS_PER_SYNC_COMMITTEE_PERIOD epochs)
    sync_committee*: seq[ValidatorIndex]

    # balances, as used in fork choice
    effective_balances_bytes*: seq[byte]

  BlockRef* = ref object
    ## Node in object graph guaranteed to lead back to tail block, and to have
    ## a corresponding entry in database.
    ## Block graph should form a tree - in particular, there are no cycles.

    root*: Eth2Digest ##\
    ## Root that can be used to retrieve block data from database

    parent*: BlockRef ##\
    ## Not nil, except for the tail

    slot*: Slot # could calculate this by walking to root, but..

  BlockData* = object
    ## Body and graph in one

    data*: ForkedTrustedSignedBeaconBlock # We trust all blocks we have a ref for
    refs*: BlockRef

  StateData* = object
    data*: ForkedHashedBeaconState

    blck*: BlockRef ##\
    ## The block associated with the state found in data

  BlockSlot* = object
    ## Unique identifier for a particular fork and time in the block chain -
    ## normally, there's a block for every slot, but in the case a block is not
    ## produced, the chain progresses anyway, producing a new state for every
    ## slot.
    blck*: BlockRef
    slot*: Slot ##\
      ## Slot time for this BlockSlot which may differ from blck.slot when time
      ## has advanced without blocks

  OnPhase0BlockAdded* = proc(
    blckRef: BlockRef,
    blck: phase0.TrustedSignedBeaconBlock,
    epochRef: EpochRef) {.gcsafe, raises: [Defect].}

  OnAltairBlockAdded* = proc(
    blckRef: BlockRef,
    blck: altair.TrustedSignedBeaconBlock,
    epochRef: EpochRef) {.gcsafe, raises: [Defect].}

template head*(dag: ChainDAGRef): BlockRef = dag.headState.blck

template epoch*(e: EpochRef): Epoch = e.key.epoch

func shortLog*(v: BlockRef): string =
  # epoch:root when logging epoch, root:slot when logging slot!
  if v.isNil():
    "nil:0"
  else:
    shortLog(v.root) & ":" & $v.slot

func shortLog*(v: BlockSlot): string =
  # epoch:root when logging epoch, root:slot when logging slot!
  if v.blck.isNil():
    "nil:0@" & $v.slot
  elif v.blck.slot == v.slot:
    shortLog(v.blck)
  else: # There was a gap - log it
    shortLog(v.blck) & "@" & $v.slot

func shortLog*(v: EpochKey): string =
  # epoch:root when logging epoch, root:slot when logging slot!
  $v.epoch & ":" & shortLog(v.blck)

func shortLog*(v: EpochRef): string =
  # epoch:root when logging epoch, root:slot when logging slot!
  if v.isNil():
    "0:nil"
  else:
    shortLog(v.key)

chronicles.formatIt BlockSlot: shortLog(it)
chronicles.formatIt BlockRef: shortLog(it)
chronicles.formatIt EpochKey: shortLog(it)
chronicles.formatIt EpochRef: shortLog(it)

func hash*(key: KeyedBlockRef): Hash =
  hash(key.data.root)

func `==`*(a, b: KeyedBlockRef): bool =
  a.data.root == b.data.root

func asLookupKey*(T: type KeyedBlockRef, root: Eth2Digest): KeyedBlockRef =
  # Create a special, temporary BlockRef instance that just has the key set
  KeyedBlockRef(data: BlockRef(root: root))

func init*(T: type KeyedBlockRef, blck: BlockRef): KeyedBlockRef =
  KeyedBlockRef(data: blck)

func blockRef*(key: KeyedBlockRef): BlockRef =
  key.data
