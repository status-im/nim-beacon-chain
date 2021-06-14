# beacon_chain
# Copyright (c) 2019-2021 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at http://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at http://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [Defect].}

import
  # Status
  chronicles, chronos,
  stew/results,
  eth/keys,
  # Internals
  ../spec/[
    datatypes, crypto, digest, helpers, signatures_batch],
  ../consensus_object_pools/[
    blockchain_dag, block_quarantine,
    attestation_pool, exit_pool,
    block_pools_types, spec_cache
  ],
  ".."/[beacon_node_types, beacon_clock]

export BrHmacDrbgContext

logScope:
  topics = "gossip_checks"

# Batched gossip validation
# ----------------------------------------------------------------

type
  BatchResult* {.pure.} = enum
    Valid
    Invalid
    Timeout

  Eager = proc(): bool {.gcsafe, raises: [Defect].} ##\
  ## Callback that returns true if eager processing should be done to lower
  ## latency at the expense of spending more cycles validating things, creating
  ## a crude timesharing priority mechanism.

  Batch* = object
    created: Moment
    pendingBuffer: seq[SignatureSet]
    resultsBuffer: seq[Future[BatchResult]]

  BatchCrypto* = object
    # Each batch is bounded by BatchedCryptoSize (16) which was chosen:
    # - based on "nimble bench" in nim-blscurve
    #   so that low power devices like Raspberry Pi 4 can process
    #   that many batched verifications within 20ms
    # - based on the accumulation rate of attestations and aggregates
    #   in large instances which were 12000 per slot (12s)
    #   hence 1 per ms (but the pattern is bursty around the 4s mark)
    # The number of batches is bounded by time - batch validation is skipped if
    # we can't process them in the time that one slot takes, and we return
    # timeout instead which prevents the gossip layer from forwarding the
    # batch.
    batches: seq[ref Batch]
    eager: Eager ##\
    ## Eager is used to enable eager processing of attestations when it's
    ## prudent to do so (instead of leaving the CPU for other, presumably more
    ## important work like block processing)
    sigVerifCache: BatchedBLSVerifierCache ##\
    ## A cache for batch BLS signature verification contexts
    rng: ref BrHmacDrbgContext  ##\
    ## A reference to the Nimbus application-wide RNG
    pruneTime: Moment ## :ast time we had to prune something

const
  # We cap waiting for an idle slot in case there's a lot of network traffic
  # taking up all CPU - we don't want to _completely_ stop processing
  # attestations - doing so also allows us to benefit from more batching /
  # larger network reads when under load.
  BatchAttAccumTime = 10.milliseconds

  # Threshold for immediate trigger of batch verification.
  # A balance between throughput and worst case latency.
  # At least 6 so that the constant factors
  # (RNG for blinding and Final Exponentiation)
  # are amortized,
  # but not too big as we need to redo checks one-by-one if one failed.
  BatchedCryptoSize = 16

proc new*(
    T: type BatchCrypto, rng: ref BrHmacDrbgContext, eager: Eager): ref BatchCrypto =
  (ref BatchCrypto)(rng: rng, eager: eager, pruneTime: Moment.now())

func len(batch: Batch): int =
  doAssert batch.resultsBuffer.len() == batch.pendingBuffer.len()
  batch.resultsBuffer.len()

func full(batch: Batch): bool =
  batch.len() >= BatchedCryptoSize

proc clear(batch: var Batch) =
  batch.pendingBuffer.setLen(0)
  batch.resultsBuffer.setLen(0)

proc skip(batch: var Batch) =
  for res in batch.resultsBuffer.mitems():
    res.complete(BatchResult.Timeout)
  batch.clear() # release memory early

proc pruneBatchQueue(batchCrypto: ref BatchCrypto) =
  let
    now = Moment.now()

  # If batches haven't been processed for more than 12 seconds
  while batchCrypto.batches.len() > 0:
    if batchCrypto.batches[0][].created + SECONDS_PER_SLOT.int64.seconds > now:
      break
    if batchCrypto.pruneTime + SECONDS_PER_SLOT.int64.seconds > now:
      notice "Batch queue pruned, skipping attestation validation",
        batches = batchCrypto.batches.len()
      batchCrypto.pruneTime = Moment.now()
    batchCrypto.batches[0][].skip()
    batchCrypto.batches.delete(0)

proc processBatch(batchCrypto: ref BatchCrypto) =
  ## Process one batch, if there is any

  # Pruning the queue here makes sure we catch up with processing if need be
  batchCrypto.pruneBatchQueue() # Skip old batches

  if batchCrypto[].batches.len() == 0:
    # No more batches left, they might have been eagerly processed or pruned
    return

  let
    batch = batchCrypto[].batches[0]
    batchSize = batch[].len()
  batchCrypto[].batches.del(0)

  if batchSize == 0:
    # Nothing to do in this batch, can happen when a batch is created without
    # there being any signatures successfully added to it
    return

  trace "batch crypto - starting",
    batchSize

  let startTick = Moment.now()

  var secureRandomBytes: array[32, byte]
  batchCrypto[].rng[].brHmacDrbgGenerate(secureRandomBytes)

  # TODO: For now only enable serial batch verification
  let ok = batchVerifySerial(
    batchCrypto.sigVerifCache,
    batch.pendingBuffer,
    secureRandomBytes)

  trace "batch crypto - finished",
    batchSize,
    cryptoVerified = ok,
    batchDur = Moment.now() - startTick

  if ok:
    for res in batch.resultsBuffer.mitems():
      res.complete(BatchResult.Valid)
  else:
    # Batched verification failed meaning that some of the signature checks
    # failed, but we don't know which ones - check each signature separately
    # instead
    debug "batch crypto - failure, falling back",
      batchSize
    for i, res in batch.resultsBuffer.mpairs():
      let ok = blsVerify batch[].pendingBuffer[i]
      res.complete(if ok: BatchResult.Valid else: BatchResult.Invalid)

  batch[].clear() # release memory early

proc deferCryptoProcessing(batchCrypto: ref BatchCrypto) {.async.} =
  ## Process pending crypto check after some time has passed - the time is
  ## chosen such that there's time to fill the batch but not so long that
  ## latency across the network is negatively affected
  await sleepAsync(BatchAttAccumTime)

  # Take the first batch in the queue and process it - if eager processing has
  # stolen it already, that's fine
  batchCrypto.processBatch()

proc getBatch(batchCrypto: ref BatchCrypto): (ref Batch, bool) =
  # Get a batch suitable for attestation processing - in particular, attestation
  # batches might be skipped
  batchCrypto.pruneBatchQueue()

  if batchCrypto.batches.len() == 0 or
      batchCrypto.batches[^1][].full():
    # There are no batches in progress - start a new batch and schedule a
    # deferred task to eventually handle it
    let batch = (ref Batch)(created: Moment.now())
    batchCrypto[].batches.add(batch)
    (batch, true)
  else:
    let batch = batchCrypto[].batches[^1]
    # len will be 0 when the batch was created but nothing added to it
    # because of early failures
    (batch, batch[].len() == 0)
proc scheduleBatch(batchCrypto: ref BatchCrypto, fresh: bool) =
  if fresh:
    # Every time we start a new round of batching, we need to launch a deferred
    # task that will compute the result of the batch eventually in case the
    # batch is never filled or eager processing is blocked
    asyncSpawn batchCrypto.deferCryptoProcessing()

  if batchCrypto.batches.len() > 0 and
      batchCrypto.batches[0][].full() and
      batchCrypto.eager():
    # If there's a full batch, process it eagerly assuming the callback allows
    batchCrypto.processBatch()

proc scheduleAttestationCheck*(
      batchCrypto: ref BatchCrypto,
      fork: Fork, genesis_validators_root: Eth2Digest,
      epochRef: EpochRef,
      attestation: Attestation
     ): Result[(Future[BatchResult], CookedSig), cstring] =
  ## Schedule crypto verification of an attestation
  ##
  ## The buffer is processed:
  ## - when eager processing is enabled and the batch is full
  ## - otherwise after 10ms (BatchAttAccumTime)
  ##
  ## This returns an error if crypto sanity checks failed
  ## and a future with the deferred attestation check otherwise.
  ##
  let (batch, fresh) = batchCrypto.getBatch()

  doAssert batch.pendingBuffer.len < BatchedCryptoSize

  let sig = ? batch
              .pendingBuffer
              .addAttestation(
                fork, genesis_validators_root, epochRef,
                attestation
              )

  let fut = newFuture[BatchResult](
    "batch_validation.scheduleAttestationCheck"
  )

  batch[].resultsBuffer.add(fut)

  batchCrypto.scheduleBatch(fresh)

  return ok((fut, sig))

proc scheduleAggregateChecks*(
      batchCrypto: ref BatchCrypto,
      fork: Fork, genesis_validators_root: Eth2Digest,
      epochRef: EpochRef,
      signedAggregateAndProof: SignedAggregateAndProof
     ): Result[
          (
            tuple[slotCheck, aggregatorCheck, aggregateCheck: Future[BatchResult]],
            CookedSig
          ), cstring] =
  ## Schedule crypto verification of an aggregate
  ##
  ## This involves 3 checks:
  ## - verify_slot_signature
  ## - verify_aggregate_and_proof_signature
  ## - is_valid_indexed_attestation
  ##
  ## The buffer is processed:
  ## - when eager processing is enabled and the batch is full
  ## - otherwise after 10ms (BatchAttAccumTime)
  ##
  ## This returns None if the signatures could not be loaded.
  ## and 3 futures with the deferred aggregate checks otherwise.
  let (batch, fresh) = batchCrypto.getBatch()

  doAssert batch[].pendingBuffer.len < BatchedCryptoSize

  template aggregate_and_proof: untyped = signedAggregateAndProof.message
  template aggregate: untyped = aggregate_and_proof.aggregate

  type R = (
    tuple[slotCheck, aggregatorCheck, aggregateCheck:
      Future[BatchResult]],
    CookedSig)

  # Enqueue in the buffer
  # ------------------------------------------------------
  let aggregator = epochRef.validatorKey(aggregate_and_proof.aggregator_index)
  if not aggregator.isSome():
    return err("scheduleAggregateChecks: invalid aggregator index")
  block:
    if (let v = batch
            .pendingBuffer
            .addSlotSignature(
              fork, genesis_validators_root,
              aggregate.data.slot,
              aggregator.get(),
              aggregate_and_proof.selection_proof
            ); v.isErr()):
      return err(v.error())

  let futSlot = newFuture[BatchResult](
    "batch_validation.scheduleAggregateChecks.slotCheck"
  )
  batch.resultsBuffer.add(futSlot)

  block:
    if (let v = batch
            .pendingBuffer
            .addAggregateAndProofSignature(
              fork, genesis_validators_root,
              aggregate_and_proof,
              aggregator.get(),
              signed_aggregate_and_proof.signature
            ); v.isErr()):
      batchCrypto.scheduleBatch(fresh)
      return err(v.error())

  let futAggregator = newFuture[BatchResult](
    "batch_validation.scheduleAggregateChecks.aggregatorCheck"
  )

  batch.resultsBuffer.add(futAggregator)

  let sig = batch
              .pendingBuffer
              .addAttestation(
                fork, genesis_validators_root, epochRef,
                aggregate
              )
  if sig.isErr():
    batchCrypto.scheduleBatch(fresh)
    return err(sig.error())

  let futAggregate = newFuture[BatchResult](
    "batch_validation.scheduleAggregateChecks.aggregateCheck"
  )
  batch.resultsBuffer.add(futAggregate)

  batchCrypto.scheduleBatch(fresh)

  return ok(((futSlot, futAggregator, futAggregate), sig.get()))
