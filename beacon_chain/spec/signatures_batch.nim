# beacon_chain
# Copyright (c) 2018-2021 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [Defect].}

import
  # Status lib
  blscurve,
  stew/[byteutils, results],
  # Internal
  "."/[
    crypto, datatypes, helpers, presets, beaconstate, digest,
    forkedbeaconstate_helpers]

# Otherwise, error.
import chronicles

export SignatureSet, BatchedBLSVerifierCache, batchVerify, batchVerifySerial, batchVerifyParallel

func `$`*(s: SignatureSet): string =
  "(pubkey: 0x" & s.pubkey.toHex() &
    ", signing_root: 0x" & s.message.toHex() &
    ", signature: 0x" & s.signature.toHex() & ')'

# Important:
#   - Due to lazy loading, when we do crypto verification
#     and only then state-transition verification,
#     there is no guarantee that pubkeys and signatures received are valid
#     unlike when Nimbus did eager loading which ensured they were correct beforehand

template loadOrExit(signature: ValidatorSig, error: cstring):
    untyped =
  ## Load a BLS signature from a raw signature
  ## Exits the **caller** with false if the signature is invalid
  let sig = signature.load()
  if sig.isNone:
    return err(error) # this exits the calling scope, as templates are inlined.
  sig.unsafeGet()

func addSignatureSet[T](
      sigs: var seq[SignatureSet],
      pubkey: CookedPubKey,
      sszObj: T,
      signature: CookedSig,
      fork: Fork,
      genesis_validators_root: Eth2Digest,
      epoch: Epoch,
      domain: DomainType) =
  ## Add a new signature set triplet (pubkey, message, signature)
  ## to a collection of signature sets for batch verification.
  ## Can return false if `signature` wasn't deserialized to a valid BLS signature.
  let signing_root = compute_signing_root(
      sszObj,
      get_domain(
        fork, domain,
        epoch,
        genesis_validators_root
      )
    ).data

  sigs.add((
    blscurve.PublicKey(pubkey),
    signing_root,
    blscurve.Signature(signature)
  ))

proc aggregateAttesters(
      validatorIndices: openArray[uint64],
      validatorKeys: auto,
     ): Result[CookedPubKey, cstring] =
  if validatorIndices.len == 0:
    # Aggregation spec requires non-empty collection
    # - https://tools.ietf.org/html/draft-irtf-cfrg-bls-signature-04
    # Eth2 spec requires at least one attesting index in attestation
    # - https://github.com/ethereum/eth2.0-specs/blob/v1.0.1/specs/phase0/beacon-chain.md#is_valid_indexed_attestation
    return err("aggregateAttesters: no attesting indices")

  let
    firstKey = validatorKeys.load(validatorIndices[0])

  if not firstKey.isSome():
    return err("aggregateAttesters: invalid attesting index")

  var attestersAgg{.noInit.}: AggregatePublicKey

  attestersAgg.init(firstKey.get())
  for i in 1 ..< validatorIndices.len:
    let key = validatorKeys.load(validatorIndices[i])
    if not key.isSome():
      return err("aggregateAttesters: invalid attesting index")
    attestersAgg.aggregate(key.get())

  ok(finish(attestersAgg))

proc addIndexedAttestation(
      sigs: var seq[SignatureSet],
      attestation: IndexedAttestation,
      validatorKeys: auto,
      state: ForkedHashedBeaconState,
     ): Result[void, cstring] =
  ## Add an indexed attestation for batched BLS verification
  ## purposes
  ## This only verifies cryptography, checking that
  ## the indices are sorted and unique is not checked for example.

  let aggPk =
    ? aggregateAttesters(attestation.attesting_indices.asSeq(), validatorKeys)

  sigs.addSignatureSet(
          aggPK,
          attestation.data,
          attestation.signature.loadOrExit(
            "addIndexedAttestation: cannot load signature"),
          getStateField(state, fork),
          getStateField(state, genesis_validators_root),
          attestation.data.target.epoch,
          DOMAIN_BEACON_ATTESTER)
  ok()

proc addAttestation(
      sigs: var seq[SignatureSet],
      attestation: Attestation,
      validatorKeys: auto,
      state: ForkedHashedBeaconState,
      cache: var StateCache
     ): Result[void, cstring] =

  var inited = false
  var attestersAgg{.noInit.}: AggregatePublicKey
  for valIndex in state.get_attesting_indices(
                    attestation.data,
                    attestation.aggregation_bits,
                    cache
                  ):
    if not inited: # first iteration
      attestersAgg.init(validatorKeys.load(valIndex).get())
      inited = true
    else:
      attestersAgg.aggregate(validatorKeys.load(valIndex).get())

  if not inited:
    # There were no attesters
    return err("addAttestation: no attesting indices")

  let attesters = finish(attestersAgg)

  sigs.addSignatureSet(
          attesters,
          attestation.data,
          attestation.signature.loadOrExit(
            "addAttestation: cannot load signature"),
          getStateField(state, fork),
          getStateField(state, genesis_validators_root),
          attestation.data.target.epoch,
          DOMAIN_BEACON_ATTESTER)

  ok()

# Public API
# ------------------------------------------------------

proc addAttestation*(
      sigs: var seq[SignatureSet],
      fork: Fork, genesis_validators_root: Eth2Digest,
      epochRef: auto,
      attestation: Attestation
     ): Result[CookedSig, cstring] =
  ## Add an attestation for batched BLS verification
  ## purposes
  ## This only verifies cryptography
  ##
  ## Returns true if the attestation was added to the batching buffer
  ## Returns false if sanity checks failed (non-empty, keys are valid)
  ## In that case the seq[SignatureSet] is unmodified
  mixin get_attesting_indices, validatorKey

  var inited = false
  var attestersAgg{.noInit.}: AggregatePublicKey
  for valIndex in epochRef.get_attesting_indices(
                    attestation.data,
                    attestation.aggregation_bits):
    if not inited: # first iteration
      attestersAgg.init(epochRef.validatorKey(valIndex).get())
      inited = true
    else:
      attestersAgg.aggregate(epochRef.validatorKey(valIndex).get())

  if not inited:
    # There were no attesters
    return err("addAttestation: no attesting indices")

  let
    attesters = finish(attestersAgg)
    cookedSig = attestation.signature.loadOrExit(
      "addAttestation: cannot load signature")

  sigs.addSignatureSet(
      attesters,
      attestation.data,
      cookedSig,
      fork,
      genesis_validators_root,
      attestation.data.target.epoch,
      DOMAIN_BEACON_ATTESTER)

  ok(CookedSig(cookedSig))

proc addSlotSignature*(
      sigs: var seq[SignatureSet],
      fork: Fork, genesis_validators_root: Eth2Digest,
      slot: Slot,
      pubkey: CookedPubKey,
      signature: ValidatorSig): Result[void, cstring] =
  let epoch = compute_epoch_at_slot(slot)
  sigs.addSignatureSet(
    pubkey,
    sszObj = slot,
    signature.loadOrExit("addSlotSignature: cannot load signature"),
    fork,
    genesis_validators_root,
    epoch,
    DOMAIN_SELECTION_PROOF
  )

  ok()

proc addAggregateAndProofSignature*(
      sigs: var seq[SignatureSet],
      fork: Fork, genesis_validators_root: Eth2Digest,
      aggregate_and_proof: AggregateAndProof,
      pubkey: CookedPubKey,
      signature: ValidatorSig
  ): Result[void, cstring] =

  let epoch = compute_epoch_at_slot(aggregate_and_proof.aggregate.data.slot)
  sigs.addSignatureSet(
    pubkey,
    sszObj = aggregate_and_proof,
    signature.loadOrExit("addAggregateAndProofSignature: cannot load signature"),
    fork,
    genesis_validators_root,
    epoch,
    DOMAIN_AGGREGATE_AND_PROOF
  )

  ok()

proc collectSignatureSets*(
       sigs: var seq[SignatureSet],
       signed_block: SignedBeaconBlock,
       validatorKeys: auto,
       state: ForkedHashedBeaconState,
       cache: var StateCache): Result[void, cstring] =
  ## Collect all signatures in a single signed block.
  ## This includes
  ## - Block proposer
  ## - Randao Reaveal
  ## - Proposer slashings
  ## - Attester slashings
  ## - Attestations
  ## - VoluntaryExits
  ##
  ## We do not include deposits as they can be invalid per protocol
  ## (secp256k1 signature instead of BLS)

  # Metadata
  # ----------------------------------------------------
  mixin load

  let
    proposer_index = signed_block.message.proposer_index
    proposer_key = validatorKeys.load(proposer_index)
  if not proposer_key.isSome():
    return err("collectSignatureSets: invalid proposer index")

  let epoch = signed_block.message.slot.compute_epoch_at_slot()

  # 1. Block proposer
  # ----------------------------------------------------
  sigs.addSignatureSet(
          proposer_key.get(),
          signed_block.message,
          signed_block.signature.loadOrExit(
            "collectSignatureSets: cannot load signature"),
          getStateField(state, fork),
          getStateField(state, genesis_validators_root),
          epoch,
          DOMAIN_BEACON_PROPOSER)

  # 2. Randao Reveal
  # ----------------------------------------------------
  sigs.addSignatureSet(
          proposer_key.get(),
          epoch,
          signed_block.message.body.randao_reveal.loadOrExit(
            "collectSignatureSets: cannot load randao"),
          getStateField(state, fork),
          getStateField(state, genesis_validators_root),
          epoch,
          DOMAIN_RANDAO)

  # 3. Proposer slashings
  # ----------------------------------------------------
  # Denial-of-service:
  #   SSZ deserialization guarantees that blocks received from random sources
  #   including peer or RPC
  #   have at most MAX_PROPOSER_SLASHINGS proposer slashings.
  for i in 0 ..< signed_block.message.body.proposer_slashings.len:
    # don't use "items" for iterating over large type
    # due to https://github.com/nim-lang/Nim/issues/14421
    # fixed in 1.4.2

    # Alias
    template slashing: untyped = signed_block.message.body.proposer_slashings[i]

    # Proposed block 1
    block:
      let
        header_1 = slashing.signed_header_1
        key_1 = validatorKeys.load(header_1.message.proposer_index)
      if not key_1.isSome():
        return err("collectSignatureSets: invalid slashing proposer index 1")

      let epoch1 = header_1.message.slot.compute_epoch_at_slot()
      sigs.addSignatureSet(
              key_1.get(),
              header_1.message,
              header_1.signature.loadOrExit(
                "collectSignatureSets: cannot load proposer slashing 1 signature"),
              getStateField(state, fork),
              getStateField(state, genesis_validators_root),
              epoch1,
              DOMAIN_BEACON_PROPOSER
            )

    # Conflicting block 2
    block:
      let
        header_2 = slashing.signed_header_2
        key_2 = validatorKeys.load(header_2.message.proposer_index)
      if not key_2.isSome():
        return err("collectSignatureSets: invalid slashing proposer index 2")
      let epoch2 = header_2.message.slot.compute_epoch_at_slot()
      sigs.addSignatureSet(
              key_2.get(),
              header_2.message,
              header_2.signature.loadOrExit(
                "collectSignatureSets: cannot load proposer slashing 2 signature"),
              getStateField(state, fork),
              getStateField(state, genesis_validators_root),
              epoch2,
              DOMAIN_BEACON_PROPOSER
            )

  # 4. Attester slashings
  # ----------------------------------------------------
  # Denial-of-service:
  #   SSZ deserialization guarantees that blocks received from random sources
  #   including peer or RPC
  #   have at most MAX_ATTESTER_SLASHINGS attester slashings.
  for i in 0 ..< signed_block.message.body.attester_slashings.len:
    # don't use "items" for iterating over large type
    # due to https://github.com/nim-lang/Nim/issues/14421
    # fixed in 1.4.2

    # Alias
    template slashing: untyped = signed_block.message.body.attester_slashings[i]

    # Attestation 1
    ? sigs.addIndexedAttestation(slashing.attestation_1, validatorKeys, state)

    # Conflicting attestation 2
    ? sigs.addIndexedAttestation(slashing.attestation_2, validatorKeys, state)

  # 5. Attestations
  # ----------------------------------------------------
  # Denial-of-service:
  #   SSZ deserialization guarantees that blocks received from random sources
  #   including peer or RPC
  #   have at most MAX_ATTESTATIONS attestations.
  for i in 0 ..< signed_block.message.body.attestations.len:
    # don't use "items" for iterating over large type
    # due to https://github.com/nim-lang/Nim/issues/14421
    # fixed in 1.4.2
    ? sigs.addAttestation(
        signed_block.message.body.attestations[i],
        validatorKeys, state, cache)

  # 6. VoluntaryExits
  # ----------------------------------------------------
  # Denial-of-service:
  #   SSZ deserialization guarantees that blocks received from random sources
  #   including peer or RPC
  #   have at most MAX_VOLUNTARY_EXITS voluntary exits.
  for i in 0 ..< signed_block.message.body.voluntary_exits.len:
    # don't use "items" for iterating over large type
    # due to https://github.com/nim-lang/Nim/issues/14421
    # fixed in 1.4.2
    template volex: untyped = signed_block.message.body.voluntary_exits[i]
    let key = validatorKeys.load(volex.message.validator_index)
    if not key.isSome():
      return err("collectSignatureSets: invalid voluntary exit")

    sigs.addSignatureSet(
            key.get(),
            volex.message,
            volex.signature.loadOrExit(
              "collectSignatureSets: cannot load voluntary exit signature"),
            getStateField(state, fork),
            getStateField(state, genesis_validators_root),
            volex.message.epoch,
            DOMAIN_VOLUNTARY_EXIT)

  ok()
