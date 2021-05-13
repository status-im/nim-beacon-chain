# beacon_chain
# Copyright (c) 2018-2021 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [Defect].}

import
  # Standard library
  std/[tables],

  # Nimble packages
  stew/[objects],
  json_rpc/servers/httpserver,
  chronicles,

  # Local modules
  ../spec/[datatypes, digest, crypto, helpers, network, signatures],
  ../spec/eth2_apis/callsigs_types,
  ../consensus_object_pools/[blockchain_dag, spec_cache, attestation_pool], ../ssz/merkleization,
  ../beacon_node_common, ../beacon_node_types,
  ../validators/validator_duties,
  ../networking/eth2_network,
  ./eth2_json_rpc_serialization,
  ./rpc_utils

logScope: topics = "valapi"

type
  RpcServer* = RpcHttpServer

proc installValidatorApiHandlers*(rpcServer: RpcServer, node: BeaconNode) {.
    raises: [Exception].} = # TODO fix json-rpc
  rpcServer.rpc("get_v1_validator_block") do (
      slot: Slot, graffiti: GraffitiBytes, randao_reveal: ValidatorSig) -> BeaconBlock:
    debug "get_v1_validator_block", slot = slot
    let head = node.doChecksAndGetCurrentHead(slot)
    let proposer = node.chainDag.getProposer(head, slot)
    if proposer.isNone():
      raise newException(CatchableError, "could not retrieve block for slot: " & $slot)
    let message = await makeBeaconBlockForHeadAndSlot(
      node, randao_reveal, proposer.get()[0], graffiti, head, slot)
    if message.isNone():
      raise newException(CatchableError, "could not retrieve block for slot: " & $slot)
    return message.get()

  rpcServer.rpc("post_v1_validator_block") do (body: SignedBeaconBlock) -> bool:
    debug "post_v1_validator_block",
      slot = body.message.slot,
      prop_idx = body.message.proposer_index
    let head = node.doChecksAndGetCurrentHead(body.message.slot)

    if head.slot >= body.message.slot:
      raise newException(CatchableError,
        "Proposal is for a past slot: " & $body.message.slot)
    if head == await proposeSignedBlock(node, head, AttachedValidator(), body):
      raise newException(CatchableError, "Could not propose block")
    return true

  rpcServer.rpc("get_v1_validator_attestation_data") do (
      slot: Slot, committee_index: CommitteeIndex) -> AttestationData:
    debug "get_v1_validator_attestation_data", slot = slot
    let
      head = node.doChecksAndGetCurrentHead(slot)
      epochRef = node.chainDag.getEpochRef(head, slot.epoch)
    return makeAttestationData(epochRef, head.atSlot(slot), committee_index)

  rpcServer.rpc("get_v1_validator_aggregate_attestation") do (
      slot: Slot, attestation_data_root: Eth2Digest)-> Attestation:
    debug "get_v1_validator_aggregate_attestation"
    let res = node.attestationPool[].getAggregatedAttestation(slot, attestation_data_root)
    if res.isSome:
      return res.get
    raise newException(CatchableError, "Could not retrieve an aggregated attestation")

  rpcServer.rpc("post_v1_validator_aggregate_and_proofs") do (
      payload: SignedAggregateAndProof) -> bool:
    debug "post_v1_validator_aggregate_and_proofs"
    node.network.broadcast(node.topicAggregateAndProofs, payload)
    notice "Aggregated attestation sent",
      attestation = shortLog(payload.message.aggregate)

  rpcServer.rpc("get_v1_validator_duties_attester") do (
      epoch: Epoch, public_keys: seq[ValidatorPubKey]) -> seq[AttesterDuties]:
    debug "get_v1_validator_duties_attester", epoch = epoch
    let
      head = node.doChecksAndGetCurrentHead(epoch)
      epochRef = node.chainDag.getEpochRef(head, epoch)
      committees_per_slot = get_committee_count_per_slot(epochRef)
    for i in 0 ..< SLOTS_PER_EPOCH:
      let slot = compute_start_slot_at_epoch(epoch) + i
      for committee_index in 0'u64..<committees_per_slot:
        let committee = get_beacon_committee(
          epochRef, slot, committee_index.CommitteeIndex)
        for index_in_committee, validatorIdx in committee:
          if validatorIdx < epochRef.validator_keys.len.ValidatorIndex:
            let curr_val_pubkey = epochRef.validator_keys[validatorIdx]
            if public_keys.findIt(it == curr_val_pubkey) != -1:
              result.add((public_key: curr_val_pubkey,
                          validator_index: validatorIdx,
                          committee_index: committee_index.CommitteeIndex,
                          committee_length: committee.lenu64,
                          validator_committee_index: index_in_committee.uint64,
                          slot: slot))

  rpcServer.rpc("get_v1_validator_duties_proposer") do (
      epoch: Epoch) -> seq[ValidatorDutiesTuple]:
    debug "get_v1_validator_duties_proposer", epoch = epoch
    let
      head = node.doChecksAndGetCurrentHead(epoch)
      epochRef = node.chainDag.getEpochRef(head, epoch)
    for i in 0 ..< SLOTS_PER_EPOCH:
      if epochRef.beacon_proposers[i].isSome():
        result.add((public_key: epochRef.beacon_proposers[i].get()[1],
                    validator_index: epochRef.beacon_proposers[i].get()[0],
                    slot: compute_start_slot_at_epoch(epoch) + i))

  rpcServer.rpc("post_v1_validator_beacon_committee_subscriptions") do (
      committee_index: CommitteeIndex, slot: Slot, aggregator: bool,
      validator_pubkey: ValidatorPubKey, slot_signature: ValidatorSig) -> bool:
    debug "post_v1_validator_beacon_committee_subscriptions",
      committee_index, slot
    if committee_index.uint64 >= MAX_COMMITTEES_PER_SLOT.uint64:
      raise newException(CatchableError,
        "Invalid committee index")

    if node.syncManager.inProgress:
      raise newException(CatchableError,
        "Beacon node is currently syncing and not serving request on that endpoint")

    let wallSlot = node.beaconClock.now.slotOrZero
    if wallSlot > slot + 1:
      raise newException(CatchableError,
        "Past slot requested")

    let epoch = slot.epoch
    if epoch >= wallSlot.epoch and epoch - wallSlot.epoch > 1:
      raise newException(CatchableError,
        "Slot requested not in current or next wall-slot epoch")

    if not verify_slot_signature(
        getStateField(node.chainDag.headState, fork),
        getStateField(node.chainDag.headState, genesis_validators_root),
        slot, validator_pubkey, slot_signature):
      raise newException(CatchableError,
        "Invalid slot signature")

    let
      head = node.doChecksAndGetCurrentHead(epoch)
      epochRef = node.chainDag.getEpochRef(head, epoch)
      subnet_id = compute_subnet_for_attestation(
        get_committee_count_per_slot(epochRef), slot, committee_index)

    # Either subnet already subscribed or not. If not, subscribe. If it is,
    # extend subscription. All one knows from the API combined with how far
    # ahead one can check for attestation schedule is that it might be used
    # for up to the end of next epoch. Therefore, arrange for subscriptions
    # to last at least that long.
    if not node.attestationSubnets.aggregateSubnets[subnet_id.uint64]:
      # When to subscribe. Since it's not clear when from the API it's first
      # needed, do so immediately.
      node.attestationSubnets.subscribeSlot[subnet_id.uint64] =
        min(node.attestationSubnets.subscribeSlot[subnet_id.uint64], wallSlot)

    node.attestationSubnets.unsubscribeSlot[subnet_id.uint64] =
      max(
        compute_start_slot_at_epoch(epoch + 2),
        node.attestationSubnets.unsubscribeSlot[subnet_id.uint64])
