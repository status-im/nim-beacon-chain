# beacon_chain
# Copyright (c) 2018-2021 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [Defect].}

import
  std/[deques, intsets, streams, tables],
  stew/endians2,
  ./spec/[digest, crypto],
  ./spec/datatypes/base,
  ./consensus_object_pools/block_pools_types,
  ./fork_choice/fork_choice_types,
  ./validators/slashing_protection

export tables, block_pools_types

const
  ATTESTATION_LOOKBACK* =
    min(24'u64, SLOTS_PER_EPOCH) + MIN_ATTESTATION_INCLUSION_DELAY
    ## The number of slots we'll keep track of in terms of "free" attestations
    ## that potentially could be added to a newly created block

type
  # #############################################
  #
  #             Attestation Pool
  #
  # #############################################
  Validation* = object
    ## Validations collect a set of signatures for a distict attestation - in
    ## eth2, a single bit is used to keep track of which signatures have been
    ## added to the aggregate meaning that only non-overlapping aggregates may
    ## be further combined.
    aggregation_bits*: CommitteeValidatorsBits
    aggregate_signature*: AggregateSignature

  AttestationEntry* = object
    ## Each entry holds the known signatures for a particular, distinct vote
    data*: AttestationData
    committee_len*: int
    singles*: Table[int, CookedSig] ## \
      ## On the attestation subnets, only attestations with a single vote are
      ## allowed - these can be collected separately to top up aggregates with -
      ## here we collect them by mapping index in committee to a vote
    aggregates*: seq[Validation]

  AttestationTable* = Table[Eth2Digest, AttestationEntry]
    ## Depending on the world view of the various validators, they may have
    ## voted on different states - this map keeps track of each vote keyed by
    ## hash_tree_root(AttestationData)

  AttestationPool* = object
    ## The attestation pool keeps track of all attestations that potentially
    ## could be added to a block during block production.
    ## These attestations also contribute to the fork choice, which combines
    ## "free" attestations with those found in past blocks - these votes
    ## are tracked separately in the fork choice.

    candidates*: array[ATTESTATION_LOOKBACK, AttestationTable] ## \
      ## We keep one item per slot such that indexing matches slot number
      ## together with startingSlot

    startingSlot*: Slot ## \
    ## Generally, we keep attestations only until a slot has been finalized -
    ## after that, they may no longer affect fork choice.

    dag*: ChainDAGRef
    quarantine*: QuarantineRef

    forkChoice*: ForkChoice

    nextAttestationEpoch*: seq[tuple[subnet: Epoch, aggregate: Epoch]] ## \
    ## sequence based on validator indices

  ExitPool* = object
    ## The exit pool tracks attester slashings, proposer slashings, and
    ## voluntary exits that could be added to a proposed block.

    attester_slashings*: Deque[AttesterSlashing]  ## \
    ## Not a function of chain DAG branch; just used as a FIFO queue for blocks

    proposer_slashings*: Deque[ProposerSlashing]  ## \
    ## Not a function of chain DAG branch; just used as a FIFO queue for blocks

    voluntary_exits*: Deque[SignedVoluntaryExit]  ## \
    ## Not a function of chain DAG branch; just used as a FIFO queue for blocks

    prior_seen_attester_slashed_indices*: IntSet ##\
    ## Records attester-slashed indices seen.

    prior_seen_proposer_slashed_indices*: IntSet ##\
    ## Records proposer-slashed indices seen.

    prior_seen_voluntary_exit_indices*: IntSet ##\
    ## Records voluntary exit indices seen.

    dag*: ChainDAGRef
    quarantine*: QuarantineRef

  # #############################################
  #
  #              Validator Pool
  #
  # #############################################
  ValidatorKind* = enum
    inProcess
    remote

  ValidatorConnection* = object
    inStream*: Stream
    outStream*: Stream
    pubKeyStr*: string

  AttachedValidator* = ref object
    pubKey*: ValidatorPubKey

    case kind*: ValidatorKind
    of inProcess:
      privKey*: ValidatorPrivKey
    else:
      connection*: ValidatorConnection

    # The index at which this validator has been observed in the chain -
    # it does not change as long as there are no reorgs on eth1 - however, the
    # index might not be valid in all eth2 histories, so it should not be
    # assumed that a valid index is stored here!
    index*: Option[ValidatorIndex]

  ValidatorPool* = object
    validators*: Table[ValidatorPubKey, AttachedValidator]
    slashingProtection*: SlashingProtectionDB

  AttestationSubnets* = object
    enabled*: bool
    stabilitySubnets*: seq[tuple[subnet_id: SubnetId, expiration: Epoch]] ##\
      ## The subnets on which we listen and broadcast gossip traffic to maintain
      ## the health of the network - these are advertised in the ENR
    nextCycleEpoch*: Epoch

    # These encode states in per-subnet state machines
    aggregateSubnets*: BitArray[ATTESTATION_SUBNET_COUNT] ##\
      ## The subnets on which we listen for attestations in order to produce
      ## aggregates
    subscribeSlot*: array[ATTESTATION_SUBNET_COUNT, Slot]
    unsubscribeSlot*: array[ATTESTATION_SUBNET_COUNT, Slot]

    # Used to track the next attestation and proposal slots using an
    # epoch-relative coordinate system. Doesn't need initialization.
    attestingSlots*: array[2, uint32]
    proposingSlots*: array[2, uint32]
    lastCalculatedEpoch*: Epoch

func shortLog*(v: AttachedValidator): string = shortLog(v.pubKey)
