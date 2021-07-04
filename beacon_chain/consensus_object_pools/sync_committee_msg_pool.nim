# beacon_chain
# Copyright (c) 2018-2021 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [Defect].}

import
  sets,
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

proc produceContribution*(
    pool: SyncCommitteeMsgPool,
    slot: Slot,
    head: BlockRef,
    committeeIdx: uint64): SyncCommitteeContribution =
  # TODO
  discard

proc produceSyncAggregate*(
    pool: SyncCommitteeMsgPool,
    head: BlockRef): SyncAggregate =
  discard
