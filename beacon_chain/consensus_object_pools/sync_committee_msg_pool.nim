# beacon_chain
# Copyright (c) 2018-2021 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [Defect].}

import
  sets,
  ../spec/digest,
  ../spec/datatypes/altair,
  ../beacon_node_types,
  ./block_pools_types

proc init*(T: type SyncCommitteeMsgPool): SyncCommitteeMsgPool =
  discard

proc clearPerSlotData*(pool: var SyncCommitteeMsgPool) =
  clear pool.seenAggregateByAuthor
  clear pool.seenByAuthor
  clear pool.bestAggregates
  clear pool.blockVotes

proc addMsg*(pool: var SyncCommitteeMsgPool,
             # TODO Break down the `msg` object in 2 separate params
             # and change the signature to be `Cooked`, so we can put
             # the validity assumption at the caller site.
             msg: SyncCommitteeMessage,
             subnetId: SubnetId,
             positionInSubnet: uint64) =
  if msg.beacon_block_root notin pool.blockVotes:
    pool.blockVotes[msg.beacon_block_root] = @[]

  try:
    pool.blockVotes[msg.beacon_block_root].add TrustedSyncCommitteeMsg(
      subnetId: subnetId,
      positionInSubnet: positionInSubnet,
      signature: msg.signature.load.get)
  except KeyError:
    raiseAssert "We have checked for the key upfront"

proc computeAggregateSig(contribution: var SyncCommitteeContribution,
                         votes: seq[TrustedSyncCommitteeMsg],
                         subnetId: SubnetId) =
  var
    aggregateSig {.noInit.}: AggregateSignature
    initialized = false

  for vote in votes:
    if vote.subnetId != subnetId:
      continue

    if not initialized:
      initialized = true
      aggregateSig.init(vote.signature)
    else:
      aggregateSig.aggregate(vote.signature)

    contribution.aggregation_bits.setBit vote.positionInSubnet

  contribution.signature = aggregateSig.finish.toValidatorSig

proc produceContribution*(
    pool: SyncCommitteeMsgPool,
    slot: Slot,
    head: BlockRef,
    subnetId: SubnetId): SyncCommitteeContribution =
  result.slot = slot
  result.beacon_block_root = head.root
  result.subcommittee_index = uint64 subnetId

  if head.root in pool.blockVotes:
    try:
      result.computeAggregateSig(pool.blockVotes[head.root], subnetId)
    except KeyError:
      raiseAssert "We have checked for the key upfront"
  else:
    result.signature = default(ValidatorSig)

proc addAggregateAux(bestVotes: var BestSyncSubcommitteeContributions,
                     contribution: SyncCommitteeContribution) =
  let totalParticipants = countOnes(contribution.aggregation_bits)
  if totalParticipants > bestVotes[contribution.subcommittee_index].totalParticipants:
    bestVotes[contribution.subcommittee_index] =
      BestSyncSubcommitteeContribution(
        totalParticipants: totalParticipants,
        participationBits: contribution.aggregation_bits,
        signature: contribution.signature.load.get)

proc addAggregate*(pool: var SyncCommitteeMsgPool,
                   msg: SignedContributionAndProof) =
  template blockRoot: auto = msg.message.contribution.beacon_block_root

  if blockRoot notin pool.bestAggregates:
    var bestContributions: BestSyncSubcommitteeContributions

    let totalParticipants = countOnes(msg.message.contribution.aggregation_bits)

    bestContributions[msg.message.contribution.subcommittee_index] =
      BestSyncSubcommitteeContribution(
        totalParticipants: totalParticipants,
        participationBits: msg.message.contribution.aggregation_bits,
        signature: msg.message.contribution.signature.load.get)

    pool.bestAggregates[blockRoot] = bestContributions
  else:
    try:
      addAggregateAux(pool.bestAggregates[blockRoot], msg.message.contribution)
    except KeyError:
      raiseAssert "We have checked for the key upfront"

proc prodeuceSyncAggregateAux(votes: BestSyncSubcommitteeContributions): SyncAggregate =
  var
    aggregateSig {.noInit.}: AggregateSignature
    initialized = false

  for subnetId in 0 ..< SYNC_COMMITTEE_SUBNET_COUNT:
    if votes[subnetId].totalParticipants == 0:
      continue

    for pos, value in votes[subnetId].participationBits:
      if value:
        let globalPos = subnetId * SYNC_SUBCOMMITTE_SIZE + pos
        result.sync_committee_bits.setBit globalPos

    if not initialized:
      initialized = true
      aggregateSig.init(votes[subnetId].signature)
    else:
      aggregateSig.aggregate(votes[subnetId].signature)

  if initialized:
    result.sync_committee_signature = aggregateSig.finish.toValidatorSig
  else:
    result.sync_committee_signature = default(ValidatorSig)

proc produceSyncAggregate*(
    pool: SyncCommitteeMsgPool,
    head: BlockRef): SyncAggregate =
  if head.root in pool.bestAggregates:
    try:
      prodeuceSyncAggregateAux(pool.bestAggregates[head.root])
    except KeyError:
      raiseAssert "We have checked for the key upfront"
  else:
    default(SyncAggregate)

