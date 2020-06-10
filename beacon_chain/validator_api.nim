# beacon_chain
# Copyright (c) 2018-2020 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  # Standard library
  tables, strutils,

  # Nimble packages
  stew/[objects],
  chronos, metrics, json_rpc/[rpcserver, jsonmarshal],
  chronicles,

  # Local modules
  spec/[datatypes, digest, crypto, validator, beaconstate, helpers],
  block_pool, ssz/merkleization,
  beacon_node_common, beacon_node_types,
  validator_duties, eth2_network,
  spec/eth2_apis/validator_callsigs_types,
  eth2_json_rpc_serialization

type
  RpcServer* = RpcHttpServer

logScope: topics = "valapi"

proc installValidatorApiHandlers*(rpcServer: RpcServer, node: BeaconNode) =

  # TODO Probably the `beacon` ones (and not `validator`) should be defined elsewhere...
  rpcServer.rpc("get_v1_beacon_states_fork") do (stateId: string) -> Fork:
    notice "== get_v1_beacon_states_fork", stateId = stateId
    result = case stateId:
      of "head":
        discard node.updateHead() # TODO do we need this?
        node.blockPool.headState.data.data.fork
      of "genesis":
        Fork(previous_version: Version(GENESIS_FORK_VERSION),
             current_version: Version(GENESIS_FORK_VERSION),
             epoch: GENESIS_EPOCH)
      of "finalized":
        # TODO
        Fork()
      of "justified":
        # TODO
        Fork()
      else:
        # TODO parse `stateId` as either a number (slot) or a hash (stateRoot)
        Fork()

  # TODO Probably the `beacon` ones (and not `validator`) should be defined elsewhere...
  rpcServer.rpc("get_v1_beacon_genesis") do () -> BeaconGenesisTuple:
    notice "== get_v1_beacon_genesis"
    return BeaconGenesisTuple(genesis_time: node.blockPool.headState.data.data.genesis_time,
                              genesis_validators_root: node.blockPool.headState.data.data.genesis_validators_root,
                              genesis_fork_version: Version(GENESIS_FORK_VERSION))

  rpcServer.rpc("post_v1_beacon_pool_attestations") do (attestation: Attestation) -> bool:
    #notice "== post_v1_beacon_pool_attestations"
    node.sendAttestation(attestation)
    return true

  rpcServer.rpc("get_v1_validator_blocks") do (
      slot: Slot, graffiti: Eth2Digest, randao_reveal: ValidatorSig) -> BeaconBlock:
    notice "== get_v1_validator_blocks", slot = slot
    let head = node.updateHead()

    let proposer = node.blockPool.getProposer(head, slot)
    # TODO how do we handle the case when we cannot return a meaningful block? 404...
    doAssert(proposer.isSome())

    let valInfo = ValidatorInfoForMakeBeaconBlock(kind: viRandao_reveal,
                                                  randao_reveal: randao_reveal)
    let res = makeBeaconBlockForHeadAndSlot(
      node, valInfo, proposer.get()[0], graffiti, head, slot)

    # TODO how do we handle the case when we cannot return a meaningful block? 404...
    doAssert(res.message.isSome())
    return res.message.get(BeaconBlock()) # returning a default if empty

  rpcServer.rpc("post_v1_beacon_blocks") do (body: SignedBeaconBlock) -> bool:
    notice "== post_v1_beacon_blocks"

    logScope: pcs = "block_proposal"
    
    let head = node.updateHead()
    if head.slot >= body.message.slot:
      warn "Skipping proposal, have newer head already",
        headSlot = shortLog(head.slot),
        headBlockRoot = shortLog(head.root),
        slot = shortLog(body.message.slot),
        cat = "fastforward"
      return false
    return head != await proposeSignedBlock(node, head, AttachedValidator(), 
                                            body, hash_tree_root(body.message))

  rpcServer.rpc("get_v1_validator_attestation_data") do (
      slot: Slot, committee_index: CommitteeIndex) -> AttestationData:
    #notice "== get_v1_validator_attestation_data"
    # Obtain the data to form an attestation
    let head = node.updateHead()
    let attestationHead = head.atSlot(slot)
    node.blockPool.withState(node.blockPool.tmpState, attestationHead):
      return makeAttestationData(state, slot, committee_index.uint64, blck.root)

  rpcServer.rpc("get_v1_validator_aggregate_attestation") do (
      attestation_data: AttestationData)-> Attestation:
    notice "== get_v1_validator_aggregate_attestation"

  rpcServer.rpc("post_v1_validator_aggregate_and_proof") do (
      payload: SignedAggregateAndProof) -> bool:
    notice "== post_v1_validator_aggregate_and_proof"
    # TODO is this enough?
    node.network.broadcast(node.topicAggregateAndProofs, payload)
    return true

  rpcServer.rpc("post_v1_validator_duties_attester") do (
      epoch: Epoch, public_keys: seq[ValidatorPubKey]) -> seq[AttesterDuties]:
    notice "== post_v1_validator_duties_attester", epoch = epoch
    discard node.updateHead() # TODO do we need this?
    for pubkey in public_keys:
      let idx = node.blockPool.headState.data.data.validators.asSeq.findIt(it.pubKey == pubkey)
      if idx != -1:
        # TODO this might crash if the requested epoch is further than the BN epoch
        # because of this: `doAssert epoch <= next_epoch`
        let res = node.blockPool.headState.data.data.get_committee_assignment(
          epoch, idx.ValidatorIndex)
        if res.isSome:
          result.add(AttesterDuties(public_key: pubkey,
                                    committee_index: res.get.b,
                                    committee_length: res.get.a.len.uint64,
                                    validator_committee_index: res.get.a.find(idx.ValidatorIndex).uint64,
                                    slot: res.get.c))

  rpcServer.rpc("get_v1_validator_duties_proposer") do (
      epoch: Epoch) -> seq[ValidatorPubkeySlotPair]:
    notice "== get_v1_validator_duties_proposer", epoch = epoch
    let head = node.updateHead()
    for i in 0 ..< SLOTS_PER_EPOCH:
      let currSlot = (compute_start_slot_at_epoch(epoch).int + i).Slot
      let proposer = node.blockPool.getProposer(head, currSlot)
      if proposer.isSome():
        result.add(ValidatorPubkeySlotPair(public_key: proposer.get()[1], slot: currSlot))

  rpcServer.rpc("post_v1_validator_beacon_committee_subscription") do (
      committee_index: CommitteeIndex, slot: Slot, aggregator: bool,
      validator_pubkey: ValidatorPubKey, slot_signature: ValidatorSig):
    notice "== post_v1_validator_beacon_committee_subscription"
    # TODO
