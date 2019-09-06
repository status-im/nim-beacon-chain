import
  sets, deques, tables,
  eth/keys, stew/[bitseqs, endians2],
  spec/[datatypes, crypto, digest],
  beacon_chain_db, conf, mainchain_monitor, eth2_network, time

type

  # #############################################
  #
  #                 Beacon Node
  #
  # #############################################
  BeaconNode* = ref object
    nickname*: string
    network*: Eth2Node
    forkVersion*: array[4, byte]
    networkIdentity*: Eth2NodeIdentity
    networkMetadata*: NetworkMetadata
    requestManager*: RequestManager
    isBootstrapNode*: bool
    bootstrapNodes*: seq[BootstrapAddr]
    db*: BeaconChainDB
    config*: BeaconNodeConf
    attachedValidators*: ValidatorPool
    blockPool*: BlockPool
    attestationPool*: AttestationPool
    mainchainMonitor*: MainchainMonitor
    beaconClock*: BeaconClock
    onBeaconBlock*: proc (node: BeaconNode, blck: BeaconBlock) {.gcsafe.}

    stateCache*: StateData ##\
    ## State cache object that's used as a scratch pad
    ## TODO this is pretty dangerous - for example if someone sets it
    ##      to a particular state then does `await`, it might change - prone to
    ##      async races

    justifiedStateCache*: StateData ##\
    ## A second state cache that's used during head selection, to avoid
    ## state replaying.
    # TODO Something smarter, so we don't need to keep two full copies, wasteful


  # #############################################
  #
  #             Attestation Pool
  #
  # #############################################
  Validation* = object
    aggregation_bits*: CommitteeValidatorsBits
    custody_bits*: CommitteeValidatorsBits ##\
    ## Phase 1 - the handling of this field is probably broken..
    aggregate_signature*: ValidatorSig

  # Per Danny as of 2018-12-21:
  # Yeah, you can do any linear combination of signatures. but you have to
  # remember the linear combination of pubkeys that constructed
  # if you have two instances of a signature from pubkey p, then you need 2*p
  # in the group pubkey because the attestation bitlist is only 1 bit per
  # pubkey right now, attestations do not support this it could be extended to
  # support N overlaps up to N times per pubkey if we had N bits per validator
  # instead of 1
  # We are shying away from this for the time being. If there end up being
  # substantial difficulties in network layer aggregation, then adding bits to
  # aid in supporting overlaps is one potential solution

  AttestationEntry* = object
    data*: AttestationData
    blck*: BlockRef
    validations*: seq[Validation] ## \
    ## Instead of aggregating the signatures eagerly, we simply dump them in
    ## this seq and aggregate only when needed
    ## TODO there are obvious caching opportunities here..

  SlotData* = object
    attestations*: seq[AttestationEntry] ## \
    ## Depending on the world view of the various validators, they may have
    ## voted on different states - here we collect all the different
    ## combinations that validators have come up with so that later, we can
    ## count how popular each world view is (fork choice)
    ## TODO this could be a Table[AttestationData, seq[Validation] or something
    ##      less naive

  UnresolvedAttestation* = object
    attestation*: Attestation
    tries*: int

  AttestationPool* = object
    ## The attestation pool keeps all attestations that are known to the
    ## client - each attestation counts as votes towards the fork choice
    ## rule that determines which block we consider to be the head. The pool
    ## contains both votes that have been included in the chain and those that
    ## have not.

    slots*: Deque[SlotData] ## \
    ## We keep one item per slot such that indexing matches slot number
    ## together with startingSlot

    startingSlot*: Slot ## \
    ## Generally, we keep attestations only until a slot has been finalized -
    ## after that, they may no longer affect fork choice.

    blockPool*: BlockPool

    unresolved*: Table[Eth2Digest, UnresolvedAttestation]

    latestAttestations*: Table[ValidatorPubKey, BlockRef] ##\
    ## Map that keeps track of the most recent vote of each attester - see
    ## fork_choice

  # #############################################
  #
  #                 Block Pool
  #
  # #############################################
  BlockPool* = ref object
    ## Pool of blocks responsible for keeping a graph of resolved blocks as well
    ## as candidates that may yet become part of that graph.
    ## Currently, this type works as a facade to the BeaconChainDB, making
    ## assumptions about the block composition therein.
    ##
    ## The general idea here is that blocks known to us are divided into two
    ## camps - unresolved and resolved. When we start the chain, we have a
    ## genesis state that serves as the root of the graph we're interested in.
    ## Every block that belongs to that chain will have a path to that block -
    ## conversely, blocks that do not are not interesting to us.
    ##
    ## As the chain progresses, some states become finalized as part of the
    ## consensus process. One way to think of that is that the blocks that
    ## come before them are no longer relevant, and the finalized state
    ## is the new genesis from which we build. Thus, instead of tracing a path
    ## to genesis, we can trace a path to any finalized block that follows - we
    ## call the oldest such block a tail block.
    ##
    ## It's important to note that blocks may arrive in any order due to
    ## chainging network conditions - we counter this by buffering unresolved
    ## blocks for some time while trying to establish a path.
    ##
    ## Once a path is established, the block becomes resolved. We store the
    ## graph in memory, in the form of BlockRef objects. This is also when
    ## we forward the block for storage in the database
    ##
    ## TODO evaluate the split of responsibilities between the two
    ## TODO prune the graph as tail moves

    pending*: Table[Eth2Digest, BeaconBlock] ##\
    ## Blocks that have passed validation but that we lack a link back to tail
    ## for - when we receive a "missing link", we can use this data to build
    ## an entire branch

    missing*: Table[Eth2Digest, MissingBlock] ##\
    ## Roots of blocks that we would like to have (either parent_root of
    ## unresolved blocks or block roots of attestations)

    blocks*: Table[Eth2Digest, BlockRef] ##\
    ## Tree of blocks pointing back to a finalized block on the chain we're
    ## interested in - we call that block the tail

    blocksBySlot*: Table[uint64, seq[BlockRef]]

    tail*: BlockRef ##\
    ## The earliest finalized block we know about

    head*: Head ##\
    ## The latest block we know about, that's been chosen as a head by the fork
    ## choice rule

    finalizedHead*: BlockSlot ##\
    ## The latest block that was finalized according to the block in head
    ## Ancestors of this block are guaranteed to have 1 child only.

    db*: BeaconChainDB

    heads*: seq[Head]

  MissingBlock* = object
    slots*: uint64 # number of slots that are suspected missing
    tries*: int

  BlockRef* = ref object {.acyclic.}
    ## Node in object graph guaranteed to lead back to tail block, and to have
    ## a corresponding entry in database.
    ## Block graph should form a tree - in particular, there are no cycles.

    root*: Eth2Digest ##\
    ## Root that can be used to retrieve block data from database

    parent*: BlockRef ##\
    ## Not nil, except for the tail

    children*: seq[BlockRef]
    # TODO do we strictly need this?

    slot*: Slot # TODO could calculate this by walking to root, but..

  BlockData* = object
    ## Body and graph in one

    data*: BeaconBlock
    refs*: BlockRef

  StateData* = object
    data*: HashedBeaconState

    blck*: BlockRef ##\
    ## The block associated with the state found in data - in particular,
    ## blck.state_root == rdata.root

  StateCache* = object
    crosslink_committee_cache*:
      Table[tuple[a: int, b: Eth2Digest], seq[ValidatorIndex]]
    active_validator_indices_cache*:
      Table[Epoch, seq[ValidatorIndex]]
    start_shard_cache*: Table[Epoch, Shard]
    committee_count_cache*: Table[Epoch, uint64]

  BlockSlot* = object
    ## Unique identifier for a particular fork in the block chain - normally,
    ## there's a block for every slot, but in the case a block is not produced,
    ## the chain progresses anyway, producing a new state for every slot.
    blck*: BlockRef
    slot*: Slot

  Head* = object
    blck*: BlockRef
    justified*: BlockSlot

  # #############################################
  #
  #              Validator Pool
  #
  # #############################################
  ValidatorKind* = enum
    inProcess
    remote

  ValidatorConnection* = object

  AttachedValidator* = ref object
    pubKey*: ValidatorPubKey

    case kind*: ValidatorKind
    of inProcess:
      privKey*: ValidatorPrivKey
    else:
      connection*: ValidatorConnection

  ValidatorPool* = object
    validators*: Table[ValidatorPubKey, AttachedValidator]

  RequestManager* = object
    network*: Eth2Node

  NetworkMetadata* = object
    networkId*: uint8
    networkGeneration*: uint64
    genesisRoot*: Eth2Digest
    bootstrapNodes*: seq[BootstrapAddr]
    numShards*: uint64
    slotDuration*: uint64
    slotsPerEpoch*: uint64
    totalValidators*: uint64
    lastUserValidator*: uint64

  FetchRecord* = object
    root*: Eth2Digest
    historySlots*: uint64

proc userValidatorsRange*(d: NetworkMetadata): HSlice[int, int] =
  0 .. d.lastUserValidator.int

proc shortLog*(v: AttachedValidator): string = shortLog(v.pubKey)

proc toGaugeValue*(hash: Eth2Digest): int64 =
  # Only the last 8 bytes are taken into consideration in accordance
  # to the ETH2 metrics spec:
  # https://github.com/ethereum/eth2.0-metrics/blob/6a79914cb31f7d54858c7dd57eee75b6162ec737/metrics.md#interop-metrics
  cast[int64](uint64.fromBytes(hash.data[24..31], littleEndian))

