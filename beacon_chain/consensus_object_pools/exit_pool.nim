# beacon_chain
# Copyright (c) 2020-2021 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [Defect].}

import
  # Standard libraries
  std/[deques, intsets, tables],
  # Status libraries
  chronicles,
  # Internal
  ../spec/[crypto, datatypes, helpers],
  "."/[blockchain_dag, block_quarantine],
  ../beacon_node_types

export beacon_node_types, intsets

logScope: topics = "exitpool"

const
  ATTESTER_SLASHINGS_BOUND* = MAX_ATTESTER_SLASHINGS * 2
  PROPOSER_SLASHINGS_BOUND* = MAX_PROPOSER_SLASHINGS * 2
  VOLUNTARY_EXITS_BOUND* = MAX_VOLUNTARY_EXITS * 2

proc init*(
    T: type ExitPool, chainDag: ChainDAGRef, quarantine: QuarantineRef): T =
  ## Initialize an ExitPool from the chainDag `headState`
  T(
    # Allow for filtering out some exit messages during block production
    attester_slashings:
      initDeque[AttesterSlashing](initialSize = ATTESTER_SLASHINGS_BOUND.int),
    proposer_slashings:
      initDeque[ProposerSlashing](initialSize = PROPOSER_SLASHINGS_BOUND.int),
    voluntary_exits:
      initDeque[SignedVoluntaryExit](initialSize = VOLUNTARY_EXITS_BOUND.int),
    chainDag: chainDag,
    quarantine: quarantine
   )

func addExitMessage*(subpool: var auto, exitMessage, bound: auto) =
  # Prefer newer to older exit messages
  while subpool.lenu64 >= bound:
    discard subpool.popFirst()

  subpool.addLast(exitMessage)
  doAssert subpool.lenu64 <= bound

iterator getValidatorIndices(attester_slashing: AttesterSlashing): uint64 =
  # TODO rely on sortedness and do this sans memory allocations, but it's only
  # when producing a beacon block, which is rare bottlenecked elsewhere.
  let
    attestation_1_indices =
      attester_slashing.attestation_1.attesting_indices.asSeq
    attestation_2_indices =
      attester_slashing.attestation_2.attesting_indices.asSeq
    attester_slashed_indices =
      toIntSet(attestation_1_indices) * toIntSet(attestation_2_indices)

  for validator_index in attester_slashed_indices:
    yield validator_index.uint64

iterator getValidatorIndices(proposer_slashing: ProposerSlashing): uint64 =
  yield proposer_slashing.signed_header_1.message.proposer_index

iterator getValidatorIndices(voluntary_exit: SignedVoluntaryExit): uint64 =
  yield voluntary_exit.message.validator_index.uint64

# TODO stew/sequtils2
template allIt(s, pred: untyped): bool =
  # https://github.com/nim-lang/Nim/blob/version-1-2/lib/pure/collections/sequtils.nim#L640-L662
  # without the items(...)
  var result = true
  for it {.inject.} in s:
    if not pred:
      result = false
      break
  result

func getExitMessagesForBlock[T](
    subpool: var Deque[T], pool: var ExitPool, bound: uint64): seq[T] =
  # Approach taken here is to simply collect messages, effectively, a circular
  # buffer and only re-validate that they haven't already found themselves out
  # of the network eventually via some exit message at block construction time
  # at which point we use exit_epoch. It doesn't matter which of these message
  # types has triggered that exit, as the validation on incoming messages will
  # find it to either be IGNORE (if it's the same type of exit message) or, if
  # it's a different type, REJECT. Neither is worth packaging into BeaconBlock
  # messages we broadcast.
  #
  # Beyond that, no other criterion of the exit messages' validity changes from
  # when they were created, so given that we validated them to start with, they
  # otherwise remain as valid as when we received them. There's no need to thus
  # re-validate them on their way out.
  #
  # This overall approach handles a scenario wherein we receive an exit message
  # over gossip and put it in the pool; receive a block X, with that message in
  # it, and select it as head; then orphan block X and build instead on X-1. If
  # this occurs, only validating after the fact ensures that we still broadcast
  # out those exit messages that were in orphaned block X by not having eagerly
  # removed them, if we have the chance.
  while true:
    if subpool.len == 0 or result.lenu64 >= bound:
      break

    # Prefer recent messages
    let exit_message = subpool.popLast()

    if allIt(
        getValidatorIndices(exit_message),
        getStateField(pool.chainDag.headState, validators)[it].exit_epoch !=
          FAR_FUTURE_EPOCH):
      # A beacon block exit message already targeted all these validators
      continue

    result.add exit_message

  subpool.clear()
  doAssert result.lenu64 <= bound

func getAttesterSlashingsForBlock*(pool: var ExitPool):
                                   seq[AttesterSlashing] =
  ## Retrieve attester slashings that may be added to a new block
  getExitMessagesForBlock[AttesterSlashing](
    pool.attester_slashings, pool, MAX_ATTESTER_SLASHINGS)

func getProposerSlashingsForBlock*(pool: var ExitPool):
                                   seq[ProposerSlashing] =
  ## Retrieve proposer slashings that may be added to a new block
  getExitMessagesForBlock[ProposerSlashing](
    pool.proposer_slashings, pool, MAX_PROPOSER_SLASHINGS)

func getVoluntaryExitsForBlock*(pool: var ExitPool):
                                seq[SignedVoluntaryExit] =
  ## Retrieve voluntary exits that may be added to a new block
  getExitMessagesForBlock[SignedVoluntaryExit](
    pool.voluntary_exits, pool, MAX_VOLUNTARY_EXITS)
