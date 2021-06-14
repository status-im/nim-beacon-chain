# Copyright (c) 2018-2021 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.
import
  std/[typetraits, strutils, deques, sets, options],
  stew/[results, base10],
  chronicles,
  nimcrypto/utils as ncrutils,
  ../beacon_node_common, ../networking/eth2_network,
  ../consensus_object_pools/[blockchain_dag, spec_cache, attestation_pool],
  ../gossip_processing/gossip_validation,
  ../validators/validator_duties,
  ../spec/[crypto, digest, forkedbeaconstate_helpers, network],
  ../spec/datatypes/base,
  ../ssz/merkleization,
  ./eth2_json_rest_serialization, ./rest_utils

logScope: topics = "rest_validatorapi"

proc installValidatorApiHandlers*(router: var RestRouter, node: BeaconNode) =
  # https://ethereum.github.io/eth2.0-APIs/#/Validator/getAttesterDuties
  router.api(MethodPost, "/api/eth/v1/validator/duties/attester/{epoch}") do (
    epoch: Epoch, contentBody: Option[ContentBody]) -> RestApiResponse:
    let indexList =
      block:
        if contentBody.isNone():
          return RestApiResponse.jsonError(Http400, EmptyRequestBodyError)
        let dres = decodeBody(seq[RestValidatorIndex], contentBody.get())
        if dres.isErr():
          return RestApiResponse.jsonError(Http400,
                                           InvalidValidatorIndexValueError,
                                           $dres.error())
        var res: seq[ValidatorIndex]
        let items = dres.get()
        for item in items:
          let vres = item.toValidatorIndex()
          if vres.isErr():
            case vres.error()
            of ValidatorIndexError.TooHighValue:
              return RestApiResponse.jsonError(Http400,
                                               TooHighValidatorIndexValueError)
            of ValidatorIndexError.UnsupportedValue:
              return RestApiResponse.jsonError(Http500,
                                            UnsupportedValidatorIndexValueError)
          res.add(vres.get())
        if len(res) == 0:
          return RestApiResponse.jsonError(Http400,
                                           EmptyValidatorIndexArrayError)
        res
    let qepoch =
      block:
        if epoch.isErr():
          return RestApiResponse.jsonError(Http400, InvalidEpochValueError,
                                           $epoch.error())
        let res = epoch.get()
        if res > MaxEpoch:
          return RestApiResponse.jsonError(Http400, EpochOverflowValueError)
        res
    let qhead =
      block:
        let res = node.getCurrentHead(qepoch)
        if res.isErr():
          return RestApiResponse.jsonError(Http503, BeaconNodeInSyncError)
        res.get()
    let droot =
      if qepoch >= Epoch(2):
        qhead.atSlot(compute_start_slot_at_epoch(qepoch - 1) - 1).blck.root
      else:
        node.dag.genesis.root
    let duties =
      block:
        var res: seq[RestAttesterDuty]
        let epochRef = node.dag.getEpochRef(qhead, qepoch)
        let committees_per_slot = get_committee_count_per_slot(epochRef)
        for i in 0 ..< SLOTS_PER_EPOCH:
          let slot = compute_start_slot_at_epoch(qepoch) + i
          for committee_index in 0'u64 ..< committees_per_slot:
            let commitee = get_beacon_committee(
              epochRef, slot, CommitteeIndex(committee_index)
            )
            for index_in_committee, validator_index in commitee:
              if validator_index in indexList:
                let validator_key = epochRef.validatorKey(validator_index)
                if validator_key.isSome():
                  res.add(
                    RestAttesterDuty(
                      pubkey: validator_key.get().toPubKey(),
                      validator_index: validator_index,
                      committee_index: CommitteeIndex(committee_index),
                      committee_length: lenu64(commitee),
                      committees_at_slot: committees_per_slot,
                      validator_committee_index:
                        ValidatorIndex(index_in_committee),
                      slot: slot
                    )
                  )
        res
    return RestApiResponse.jsonResponseWRoot(duties, droot)

  # https://ethereum.github.io/eth2.0-APIs/#/Validator/getProposerDuties
  router.api(MethodGet, "/api/eth/v1/validator/duties/proposer/{epoch}") do (
    epoch: Epoch) -> RestApiResponse:
    let qepoch =
      block:
        if epoch.isErr():
          return RestApiResponse.jsonError(Http400, InvalidEpochValueError,
                                           $epoch.error())
        let res = epoch.get()
        if res > MaxEpoch:
          return RestApiResponse.jsonError(Http400, EpochOverflowValueError)
        res
    let qhead =
      block:
        let res = node.getCurrentHead(qepoch)
        if res.isErr():
          return RestApiResponse.jsonError(Http503, BeaconNodeInSyncError)
        res.get()
    let droot =
      if qepoch >= Epoch(2):
        qhead.atSlot(compute_start_slot_at_epoch(qepoch - 1) - 1).blck.root
      else:
        node.dag.genesis.root
    let duties =
      block:
        var res: seq[RestProposerDuty]
        let epochRef = node.dag.getEpochRef(qhead, qepoch)
        for i, bp in epochRef.beacon_proposers:
          if i == 0 and qepoch == 0:
            # Fix for https://github.com/status-im/nimbus-eth2/issues/2488
            # Slot(0) at Epoch(0) do not have a proposer.
            continue

          if bp.isSome():
            res.add(
              RestProposerDuty(
                pubkey: epochRef.validatorKey(bp.get()).get().toPubKey(),
                validator_index: bp.get(),
                slot: compute_start_slot_at_epoch(qepoch) + i
              )
            )
        res
    return RestApiResponse.jsonResponseWRoot(duties, droot)

  # https://ethereum.github.io/eth2.0-APIs/#/Validator/produceBlock
  router.api(MethodGet, "/api/eth/v1/validator/blocks/{slot}") do (
    slot: Slot, randao_reveal: Option[ValidatorSig],
    graffiti: Option[GraffitiBytes]) -> RestApiResponse:
    let message =
      block:
        let qslot =
          block:
            if slot.isErr():
              return RestApiResponse.jsonError(Http400, InvalidSlotValueError,
                                               $slot.error())
            slot.get()

        let qrandao =
          if randao_reveal.isNone():
            return RestApiResponse.jsonError(Http400, MissingRandaoRevealValue)
          else:
            let res = randao_reveal.get()
            if res.isErr():
              return RestApiResponse.jsonError(Http400,
                                               InvalidRandaoRevealValue,
                                               $res.error())
            res.get()
        let qgraffiti =
          if graffiti.isNone():
            defaultGraffitiBytes()
          else:
            let res = graffiti.get()
            if res.isErr():
              return RestApiResponse.jsonError(Http400,
                                               InvalidGraffitiBytesValye,
                                               $res.error())
            res.get()
        let qhead =
          block:
            let res = node.getCurrentHead(qslot)
            if res.isErr():
              if not(node.isSynced(node.dag.head)):
                return RestApiResponse.jsonError(Http503, BeaconNodeInSyncError)
              else:
                return RestApiResponse.jsonError(Http400, NoHeadForSlotError,
                                                 $res.error())
            res.get()
        let proposer = node.dag.getProposer(qhead, qslot)
        if proposer.isNone():
          return RestApiResponse.jsonError(Http400, ProposerNotFoundError)
        let res = await makeBeaconBlockForHeadAndSlot(
          node, qrandao, proposer.get(), qgraffiti, qhead, qslot)
        if res.isNone():
          return RestApiResponse.jsonError(Http400, BlockProduceError)
        res.get()

    return RestApiResponse.jsonResponse(message)

  # https://ethereum.github.io/eth2.0-APIs/#/Validator/produceAttestationData
  router.api(MethodGet, "/api/eth/v1/validator/attestation_data") do (
    slot: Option[Slot],
    committee_index: Option[CommitteeIndex]) -> RestApiResponse:
    let adata =
      block:
        let qslot =
          block:
            if slot.isNone():
              return RestApiResponse.jsonError(Http400, MissingSlotValueError)
            let res = slot.get()
            if res.isErr():
              return RestApiResponse.jsonError(Http400, InvalidSlotValueError,
                                               $res.error())
            res.get()
        let qindex =
          block:
            if committee_index.isNone():
              return RestApiResponse.jsonError(Http400,
                                               MissingCommitteeIndexValueError)
            let res = committee_index.get()
            if res.isErr():
              return RestApiResponse.jsonError(Http400,
                                               InvalidCommitteeIndexValueError,
                                               $res.error())
            res.get()
        let qhead =
          block:
            let res = node.getCurrentHead(qslot)
            if res.isErr():
              return RestApiResponse.jsonError(Http503, BeaconNodeInSyncError)
            res.get()
        let epochRef = node.dag.getEpochRef(qhead, qslot.epoch)
        makeAttestationData(epochRef, qhead.atSlot(qslot), qindex)
    return RestApiResponse.jsonResponse(adata)

  # https://ethereum.github.io/eth2.0-APIs/#/Validator/getAggregatedAttestation
  router.api(MethodGet, "/api/eth/v1/validator/aggregate_attestation") do (
    attestation_data_root: Option[Eth2Digest],
    slot: Option[Slot]) -> RestApiResponse:
    let attestation =
      block:
        let qslot =
          block:
            if slot.isNone():
              return RestApiResponse.jsonError(Http400, MissingSlotValueError)
            let res = slot.get()
            if res.isErr():
              return RestApiResponse.jsonError(Http400, InvalidSlotValueError,
                                               $res.error())
            res.get()
        let qroot =
          block:
            if attestation_data_root.isNone():
              return RestApiResponse.jsonError(Http400,
                                           MissingAttestationDataRootValueError)
            let res = attestation_data_root.get()
            if res.isErr():
              return RestApiResponse.jsonError(Http400,
                             InvalidAttestationDataRootValueError, $res.error())
            res.get()
        let res = node.attestationPool[].getAggregatedAttestation(qslot, qroot)
        if res.isNone():
          return RestApiResponse.jsonError(Http400,
                                          UnableToGetAggregatedAttestationError)
        res.get()
    return RestApiResponse.jsonResponse(attestation)

  # https://ethereum.github.io/eth2.0-APIs/#/Validator/publishAggregateAndProofs
  router.api(MethodPost, "/api/eth/v1/validator/aggregate_and_proofs") do (
    contentBody: Option[ContentBody]) -> RestApiResponse:
    let proofs =
      block:
        if contentBody.isNone():
          return RestApiResponse.jsonError(Http400, EmptyRequestBodyError)
        let dres = decodeBody(seq[SignedAggregateAndProof], contentBody.get())
        if dres.isErr():
          return RestApiResponse.jsonError(Http400,
                                           InvalidAggregateAndProofObjectError,
                                           $dres.error())
        dres.get()

    for item in proofs:
      let wallTime = node.processor.getCurrentBeaconTime()
      let res = await node.attestationPool.validateAggregate(
        node.processor.batchCrypto, item, wallTime
      )
      if res.isErr():
        return RestApiResponse.jsonError(Http400,
                                         AggregateAndProofValidationError,
                                         $res.error())
      node.network.broadcast(node.topicAggregateAndProofs, item)

    return RestApiResponse.jsonError(Http200,
                                     AggregateAndProofValidationSuccess)

  # https://ethereum.github.io/eth2.0-APIs/#/Validator/prepareBeaconCommitteeSubnet
  router.api(MethodPost,
             "/api/eth/v1/validator/beacon_committee_subscriptions") do (
    contentBody: Option[ContentBody]) -> RestApiResponse:
    # TODO (cheatfate): This call could not be finished because more complex
    # peer manager implementation needed.
    let requests =
      block:
        if contentBody.isNone():
          return RestApiResponse.jsonError(Http400, EmptyRequestBodyError)
        let dres = decodeBody(seq[RestCommitteeSubscription],
                              contentBody.get())
        if dres.isErr():
          return RestApiResponse.jsonError(Http400,
                                           InvalidSubscriptionRequestValueError,
                                           $dres.error())
        dres.get()
    if not(node.isSynced(node.dag.head)):
      return RestApiResponse.jsonError(Http503, BeaconNodeInSyncError)

    for request in requests:
      if uint64(request.committee_index) >= uint64(MAX_COMMITTEES_PER_SLOT):
        return RestApiResponse.jsonError(Http400,
                                         InvalidCommitteeIndexValueError)
      let validator_pubkey =
        block:
          let idx = request.validator_index
          if uint64(idx) >=
                           lenu64(getStateField(node.dag.headState.data, validators)):
            return RestApiResponse.jsonError(Http400,
                                             InvalidValidatorIndexValueError)
          getStateField(node.dag.headState.data, validators)[idx].pubkey

      let wallSlot = node.beaconClock.now.slotOrZero
      if wallSlot > request.slot + 1:
        return RestApiResponse.jsonError(Http400, SlotFromThePastError)
      let epoch = request.slot.epoch
      if epoch >= wallSlot.epoch and epoch - wallSlot.epoch > 1:
        return RestApiResponse.jsonError(Http400,
                                         SlotNotInNextWallSlotEpochError)
      let head =
        block:
          let res = node.getCurrentHead(epoch)
          if res.isErr():
            return RestApiResponse.jsonError(Http400, NoHeadForSlotError,
                                             $res.error())
          res.get()
      let epochRef = node.dag.getEpochRef(head, epoch)
      let subnet = uint8(compute_subnet_for_attestation(
        get_committee_count_per_slot(epochRef), request.slot,
        request.committee_index)
      )
    return RestApiResponse.jsonError(Http500, NoImplementationError)

  router.redirect(
    MethodPost,
    "/eth/v1/validator/duties/attester/{epoch}",
    "/api/eth/v1/validator/duties/attester/{epoch}"
  )
  router.redirect(
    MethodGet,
    "/eth/v1/validator/duties/proposer/{epoch}",
    "/api/eth/v1/validator/duties/proposer/{epoch}"
  )
  router.redirect(
    MethodGet,
    "/eth/v1/validator/blocks/{slot}",
    "/api/eth/v1/validator/blocks/{slot}"
  )
  router.redirect(
    MethodGet,
    "/eth/v1/validator/attestation_data",
    "/api/eth/v1/validator/attestation_data"
  )
  router.redirect(
    MethodGet,
    "/eth/v1/validator/aggregate_attestation",
    "/api/eth/v1/validator/aggregate_attestation"
  )
  router.redirect(
    MethodPost,
    "/eth/v1/validator/aggregate_and_proofs",
    "/api/eth/v1/validator/aggregate_and_proofs"
  )
  router.redirect(
    MethodPost,
    "/eth/v1/validator/beacon_committee_subscriptions",
    "/api/eth/v1/validator/beacon_committee_subscriptions"
  )

proc getProposerDuties*(epoch: Epoch): RestResponse[DataRestProposerDuties] {.
     rest, endpoint: "/eth/v1/validator/duties/proposer/{epoch}",
     meth: MethodGet.}
  ## https://ethereum.github.io/eth2.0-APIs/#/Validator/getProposerDuties

proc getAttesterDuties*(epoch: Epoch,
                        body: seq[ValidatorIndex]
                       ): RestResponse[DataRestAttesterDuties] {.
     rest, endpoint: "/eth/v1/validator/duties/attester/{epoch}",
     meth: MethodPost.}
  ## https://ethereum.github.io/eth2.0-APIs/#/Validator/getAttesterDuties

proc produceBlock*(slot: Slot, randao_reveal: ValidatorSig,
                   graffiti: GraffitiBytes
                  ): RestResponse[DataRestBeaconBlock] {.
     rest, endpoint: "/eth/v1/validator/blocks/{slot}",
     meth: MethodGet.}
  ## https://ethereum.github.io/eth2.0-APIs/#/Validator/produceBlock

proc produceAttestationData*(slot: Slot,
                             committee_index: CommitteeIndex
                            ): RestResponse[DataRestAttestationData] {.
     rest, endpoint: "/eth/v1/validator/attestation_data",
     meth: MethodGet.}
  ## https://ethereum.github.io/eth2.0-APIs/#/Validator/produceAttestationData

proc getAggregatedAttestation*(attestation_data_root: Eth2Digest,
                               slot: Slot): RestResponse[DataRestAttestation] {.
     rest, endpoint: "/eth/v1/validator/aggregate_attestation"
     meth: MethodGet.}
  ## https://ethereum.github.io/eth2.0-APIs/#/Validator/getAggregatedAttestation

proc publishAggregateAndProofs*(body: seq[SignedAggregateAndProof]
                               ): RestPlainResponse {.
     rest, endpoint: "/eth/v1/validator/aggregate_and_proofs",
     meth: MethodPost.}
  ## https://ethereum.github.io/eth2.0-APIs/#/Validator/publishAggregateAndProofs

proc prepareBeaconCommitteeSubnet*(body: seq[RestCommitteeSubscription]
                                  ): RestPlainResponse {.
     rest, endpoint: "/eth/v1/validator/beacon_committee_subscriptions",
     meth: MethodPost.}
  ## https://ethereum.github.io/eth2.0-APIs/#/Validator/prepareBeaconCommitteeSubnet
