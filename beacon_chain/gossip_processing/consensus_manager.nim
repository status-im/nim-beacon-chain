# beacon_chain
# Copyright (c) 2018-2021 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [Defect].}

import
  chronicles, chronos,
  ../spec/[crypto, datatypes],
  ../consensus_object_pools/[blockchain_dag, attestation_pool],

  # not ideal
  ../eth1/eth1_monitor

# TODO: Move to "consensus_object_pools" folder

type
  ConsensusManager* = object
    expectedSlot: Slot
    expectedBlockReceived: Future[bool]

    # Validated & Verified
    # ----------------------------------------------------------------
    chainDag*: ChainDAGRef
    attestationPool*: ref AttestationPool

    # Missing info
    # ----------------------------------------------------------------
    quarantine*: QuarantineRef

    # Eth1 integration for merge
    # ----------------------------------------------------------------
    eth1Monitor*: Eth1Monitor

# Initialization
# ------------------------------------------------------------------------------

proc new*(T: type ConsensusManager,
          chainDag: ChainDAGRef,
          attestationPool: ref AttestationPool,
          quarantine: QuarantineRef,
          eth1Monitor: Eth1Monitor
         ): ref ConsensusManager =
  (ref ConsensusManager)(
    chainDag: chainDag,
    attestationPool: attestationPool,
    quarantine: quarantine,
    eth1Monitor: eth1Monitor
  )

# Consensus Management
# -----------------------------------------------------------------------------------

proc checkExpectedBlock(self: var ConsensusManager) =
  if self.expectedBlockReceived == nil:
    return

  if self.chainDag.head.slot < self.expectedSlot:
    return

  self.expectedBlockReceived.complete(true)
  self.expectedBlockReceived = nil # Don't keep completed futures around!

proc expectBlock*(self: var ConsensusManager, expectedSlot: Slot): Future[bool] =
  ## Return a future that will complete when a head is selected whose slot is
  ## equal or greater than the given slot, or a new expectation is created
  if self.expectedBlockReceived != nil:
    # Reset the old future to not leave it hanging.. an alternative would be to
    # cancel it, but it doesn't make any practical difference for now
    self.expectedBlockReceived.complete(false)

  let fut = newFuture[bool]("ConsensusManager.expectBlock")
  self.expectedSlot = expectedSlot
  self.expectedBlockReceived = fut

  # It might happen that by the time we're expecting a block, it might have
  # already been processed!
  self.checkExpectedBlock()

  return fut

proc updateHead*(self: var ConsensusManager, wallSlot: Slot) =
  ## Trigger fork choice and update the DAG with the new head block
  ## This does not automatically prune the DAG after finalization
  ## `pruneFinalized` must be called for pruning.

  # Grab the new head according to our latest attestation data
  let newHead = self.attestationPool[].selectHead(wallSlot)
  if newHead.isNil():
    warn "Head selection failed, using previous head",
      head = shortLog(self.chainDag.head), wallSlot
    return

  # Store the new head in the chain DAG - this may cause epochs to be
  # justified and finalized
  self.chainDag.updateHead(newHead, self.quarantine)

  self.checkExpectedBlock()

proc pruneStateCachesAndForkChoice*(self: var ConsensusManager) =
  ## Prune unneeded and invalidated data after finalization
  ## - the DAG state checkpoints
  ## - the DAG EpochRef
  ## - the attestation pool/fork choice

  # Cleanup DAG & fork choice if we have a finalized head
  if self.chainDag.needStateCachesAndForkChoicePruning():
    self.chainDag.pruneStateCachesDAG()
    self.attestationPool[].prune()
