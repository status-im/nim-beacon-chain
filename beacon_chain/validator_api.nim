# beacon_chain
# Copyright (c) 2018-2020 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  # Standard library
  tables, strutils, parseutils, sequtils,

  # Nimble packages
  stew/[byteutils, objects],
  chronos, metrics, json_rpc/[rpcserver, jsonmarshal],
  chronicles,

  # Local modules
  spec/[datatypes, digest, crypto, validator, helpers],
  block_pools/[chain_dag, spec_cache], ssz/merkleization,
  beacon_node_common, beacon_node_types, attestation_pool,
  validator_duties, eth2_network,
  spec/eth2_apis/callsigs_types,
  eth2_json_rpc_serialization

type
  RpcServer* = RpcHttpServer

logScope: topics = "valapi"

proc toBlockSlot(blckRef: BlockRef): BlockSlot =
  blckRef.atSlot(blckRef.slot)

proc parseRoot(str: string): Eth2Digest =
  return Eth2Digest(data: hexToByteArray[32](str))

proc parsePubkey(str: string): ValidatorPubKey =
  if str.len != RawPubKeySize + 2: # +2 because of the `0x` prefix
    raise newException(CatchableError, "Not a valid public key (too short)")
  let pubkeyRes = fromHex(ValidatorPubKey, str)
  if pubkeyRes.isErr:
    raise newException(CatchableError, "Not a valid public key")
  return pubkeyRes[]

func checkEpochToSlotOverflow(epoch: Epoch) =
  const maxEpoch = compute_epoch_at_slot(not 0'u64)
  if epoch >= maxEpoch:
    raise newException(
      ValueError, "Requesting epoch for which slot would overflow")

proc doChecksAndGetCurrentHead(node: BeaconNode, slot: Slot): BlockRef =
  result = node.chainDag.head
  if not node.isSynced(result):
    raise newException(CatchableError, "Cannot fulfill request until node is synced")
  # TODO for now we limit the requests arbitrarily by up to 2 epochs into the future
  if result.slot + uint64(2 * SLOTS_PER_EPOCH) < slot:
    raise newException(CatchableError, "Requesting way ahead of the current head")

proc doChecksAndGetCurrentHead(node: BeaconNode, epoch: Epoch): BlockRef =
  checkEpochToSlotOverflow(epoch)
  node.doChecksAndGetCurrentHead(epoch.compute_start_slot_at_epoch)

# TODO currently this function throws if the validator isn't found - is this OK?
proc getValidatorInfoFromValidatorId(
    state: BeaconState,
    current_epoch: Epoch,
    validatorId: string,
    status = ""):
    Option[BeaconStatesValidatorsTuple] =
  const allowedStatuses = ["", "pending", "pending_initialized", "pending_queued",
    "active", "active_ongoing", "active_exiting", "active_slashed", "exited",
    "exited_unslashed", "exited_slashed", "withdrawal", "withdrawal_possible",
    "withdrawal_done"]
  if status notin allowedStatuses:
    raise newException(CatchableError, "Invalid status requested")

  let validator = if validatorId.startsWith("0x"):
    let pubkey = parsePubkey(validatorId)
    let idx = state.validators.asSeq.findIt(it.pubKey == pubkey)
    if idx == -1:
      raise newException(CatchableError, "Could not find validator")
    state.validators[idx]
  else:
    var valIdx: BiggestUInt
    if parseBiggestUInt(validatorId, valIdx) != validatorId.len:
      raise newException(CatchableError, "Not a valid index")
    if valIdx > state.validators.lenu64:
      raise newException(CatchableError, "Index out of bounds")
    state.validators[valIdx]

  # time to determine the status of the validator - the code mimics
  # whatever is detailed here: https://hackmd.io/ofFJ5gOmQpu1jjHilHbdQQ
  let actual_status = if validator.activation_epoch > current_epoch:
    # pending
    if validator.activation_eligibility_epoch == FAR_FUTURE_EPOCH:
      "pending_initialized"
    else:
      # validator.activation_eligibility_epoch < FAR_FUTURE_EPOCH:
      "pending_queued"
  elif validator.activation_epoch <= current_epoch and
      current_epoch < validator.exit_epoch:
    # active
    if validator.exit_epoch == FAR_FUTURE_EPOCH:
      "active_ongoing"
    elif not validator.slashed:
      # validator.exit_epoch < FAR_FUTURE_EPOCH
      "active_exiting"
    else:
      # validator.exit_epoch < FAR_FUTURE_EPOCH and validator.slashed:
      "active_slashed"
  elif validator.exit_epoch <= current_epoch and
      current_epoch < validator.withdrawable_epoch:
    # exited
    if not validator.slashed:
      "exited_unslashed"
    else:
      # validator.slashed
      "exited_slashed"
  elif validator.withdrawable_epoch <= current_epoch:
    # withdrawal
    if validator.effective_balance != 0:
      "withdrawal_possible"
    else:
      # validator.effective_balance == 0
      "withdrawal_done"
  else:
    raise newException(CatchableError, "Invalid validator status")

  # if the requested status doesn't match the actual status
  if status != "" and status notin actual_status:
    return none(BeaconStatesValidatorsTuple)

  return some((validator: validator, status: actual_status,
                balance: validator.effective_balance))

proc getBlockSlotFromString(node: BeaconNode, slot: string): BlockSlot =
  if slot.len == 0:
    raise newException(ValueError, "Empty slot number not allowed")
  var parsed: BiggestUInt
  if parseBiggestUInt(slot, parsed) != slot.len:
    raise newException(ValueError, "Not a valid slot number")
  let head = node.doChecksAndGetCurrentHead(parsed.Slot)
  return head.atSlot(parsed.Slot)

proc getBlockDataFromBlockId(node: BeaconNode, blockId: string): BlockData =
  result = case blockId:
    of "head":
      node.chainDag.get(node.chainDag.head)
    of "genesis":
      node.chainDag.getGenesisBlockData()
    of "finalized":
      node.chainDag.get(node.chainDag.finalizedHead.blck)
    else:
      if blockId.startsWith("0x"):
        let blckRoot = parseRoot(blockId)
        let blockData = node.chainDag.get(blckRoot)
        if blockData.isNone:
          raise newException(CatchableError, "Block not found")
        blockData.get()
      else:
        let blockSlot = node.getBlockSlotFromString(blockId)
        if blockSlot.blck.isNil:
          raise newException(CatchableError, "Block not found")
        node.chainDag.get(blockSlot.blck)

proc stateIdToBlockSlot(node: BeaconNode, stateId: string): BlockSlot =
  result = case stateId:
    of "head":
      node.chainDag.head.toBlockSlot()
    of "genesis":
      node.chainDag.getGenesisBlockSlot()
    of "finalized":
      node.chainDag.finalizedHead
    of "justified":
      node.chainDag.head.atEpochStart(
        node.chainDag.headState.data.data.current_justified_checkpoint.epoch)
    else:
      if stateId.startsWith("0x"):
        let blckRoot = parseRoot(stateId)
        let blckRef = node.chainDag.getRef(blckRoot)
        if blckRef.isNil:
          raise newException(CatchableError, "Block not found")
        blckRef.toBlockSlot()
      else:
        node.getBlockSlotFromString(stateId)

# TODO Probably the `beacon` ones should be defined elsewhere...?

proc installValidatorApiHandlers*(rpcServer: RpcServer, node: BeaconNode) =

  let GENESIS_FORK_VERSION = node.config.runtimePreset.GENESIS_FORK_VERSION

  template withStateForStateId(stateId: string, body: untyped): untyped =
    # TODO this can be optimized for the "head" case since that should be most common
    node.chainDag.withState(node.chainDag.tmpState,
                            node.stateIdToBlockSlot(stateId)):
      body

  rpcServer.rpc("get_v1_beacon_genesis") do () -> BeaconGenesisTuple:
    return (genesis_time: node.chainDag.headState.data.data.genesis_time,
             genesis_validators_root:
              node.chainDag.headState.data.data.genesis_validators_root,
             genesis_fork_version: GENESIS_FORK_VERSION)

  rpcServer.rpc("get_v1_beacon_states_root") do (stateId: string) -> Eth2Digest:
    withStateForStateId(stateId):
      return hashedState.root

  rpcServer.rpc("get_v1_beacon_states_fork") do (stateId: string) -> Fork:
    withStateForStateId(stateId):
      return state.fork

  rpcServer.rpc("get_v1_beacon_states_finality_checkpoints") do (
      stateId: string) -> BeaconStatesFinalityCheckpointsTuple:
    withStateForStateId(stateId):
      return (previous_justified: state.previous_justified_checkpoint,
              current_justified: state.current_justified_checkpoint,
              finalized: state.finalized_checkpoint)

  rpcServer.rpc("get_v1_beacon_states_stateId_validators") do (
      stateId: string, validatorIds: seq[string],
      status: string) -> seq[BeaconStatesValidatorsTuple]:
    let current_epoch = get_current_epoch(node.chainDag.headState.data.data)
    withStateForStateId(stateId):
      for validatorId in validatorIds:
        let res = state.getValidatorInfoFromValidatorId(
          current_epoch, validatorId, status)
        if res.isSome():
          result.add(res.get())

  rpcServer.rpc("get_v1_beacon_states_stateId_validators_validatorId") do (
      stateId: string, validatorId: string) -> BeaconStatesValidatorsTuple:
    let current_epoch = get_current_epoch(node.chainDag.headState.data.data)
    withStateForStateId(stateId):
      let res = state.getValidatorInfoFromValidatorId(current_epoch, validatorId)
      if res.isNone:
        # TODO should we raise here? Maybe this is different from the array case...
        raise newException(CatchableError, "Validator status differs")
      return res.get()

  rpcServer.rpc("get_v1_beacon_states_stateId_committees_epoch") do (
      stateId: string, epoch: uint64, index: uint64, slot: uint64) ->
      seq[BeaconStatesCommitteesTuple]:
    checkEpochToSlotOverflow(epoch.Epoch)
    withStateForStateId(stateId):
      proc getCommittee(slot: Slot, index: CommitteeIndex): BeaconStatesCommitteesTuple =
        let vals = get_beacon_committee(state, slot, index, cache).mapIt(it.uint64)
        return (index: index.uint64, slot: slot.uint64, validators: vals)

      proc forSlot(slot: Slot, res: var seq[BeaconStatesCommitteesTuple]) =
        let committees_per_slot =
          get_committee_count_per_slot(state, slot.epoch, cache)
        if index == 0: # TODO this means if the parameter is missing (its optional)
          for committee_index in 0'u64..<committees_per_slot:
            res.add(getCommittee(slot, committee_index.CommitteeIndex))
        else:
          if index >= committees_per_slot:
            raise newException(ValueError, "Committee index out of bounds")
          res.add(getCommittee(slot, index.CommitteeIndex))

      if slot == 0: # TODO this means if the parameter is missing (its optional)
        for i in 0 ..< SLOTS_PER_EPOCH:
          forSlot(compute_start_slot_at_epoch(epoch.Epoch) + i, result)
      else:
        forSlot(slot.Slot, result)

  rpcServer.rpc("get_v1_beacon_headers") do (
      slot: uint64, parent_root: Eth2Digest) -> seq[BeaconHeadersTuple]:
    # @mratsim: I'm adding a toposorted iterator that returns all blocks from last finalization to all heads in the dual fork choice PR @viktor

    # filterIt(dag.blocks.values(), it.blck.slot == slot_of_interest)
    # maybe usesBlockPool.heads ??? or getBlockRange ???

    # https://discordapp.com/channels/613988663034118151/614014714590134292/726095138484518912

    discard # raise newException(CatchableError, "Not implemented") # cannot compile...

  rpcServer.rpc("get_v1_beacon_headers_blockId") do (
      blockId: string) -> tuple[canonical: bool, header: SignedBeaconBlockHeader]:
    let bd = node.getBlockDataFromBlockId(blockId)
    let tsbb = bd.data
    result.header.signature = ValidatorSig.init tsbb.signature.data

    result.header.message.slot = tsbb.message.slot
    result.header.message.proposer_index = tsbb.message.proposer_index
    result.header.message.parent_root = tsbb.message.parent_root
    result.header.message.state_root = tsbb.message.state_root
    result.header.message.body_root = tsbb.message.body.hash_tree_root()

    result.canonical = bd.refs.isAncestorOf(node.chainDag.head)

  rpcServer.rpc("get_v1_beacon_blocks_blockId") do (
      blockId: string) -> TrustedSignedBeaconBlock:
    return node.getBlockDataFromBlockId(blockId).data

  rpcServer.rpc("get_v1_beacon_blocks_blockId_root") do (
      blockId: string) -> Eth2Digest:
    return node.getBlockDataFromBlockId(blockId).data.message.state_root

  rpcServer.rpc("get_v1_beacon_blocks_blockId_attestations") do (
      blockId: string) -> seq[TrustedAttestation]:
    return node.getBlockDataFromBlockId(blockId).data.message.body.attestations.asSeq

  rpcServer.rpc("post_v1_beacon_pool_attestations") do (
      attestation: Attestation) -> bool:
    node.sendAttestation(attestation)
    return true

  rpcServer.rpc("get_v1_config_fork_schedule") do (
      ) -> seq[tuple[epoch: uint64, version: Version]]:
    discard # raise newException(CatchableError, "Not implemented") # cannot compile...

  rpcServer.rpc("get_v1_debug_beacon_states_stateId") do (
      stateId: string) -> BeaconState:
    withStateForStateId(stateId):
      return state

  rpcServer.rpc("get_v1_validator_block") do (
      slot: Slot, graffiti: GraffitiBytes, randao_reveal: ValidatorSig) -> BeaconBlock:
    debug "get_v1_validator_block", slot = slot
    let head = node.doChecksAndGetCurrentHead(slot)
    let proposer = node.chainDag.getProposer(head, slot)
    if proposer.isNone():
      raise newException(CatchableError, "could not retrieve block for slot: " & $slot)
    let valInfo = ValidatorInfoForMakeBeaconBlock(kind: viRandao_reveal,
                                                  randao_reveal: randao_reveal)
    let res = await makeBeaconBlockForHeadAndSlot(
      node, valInfo, proposer.get()[0], graffiti, head, slot)
    if res.message.isNone():
      raise newException(CatchableError, "could not retrieve block for slot: " & $slot)
    return res.message.get()

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

  rpcServer.rpc("get_v1_validator_attestation") do (
      slot: Slot, committee_index: CommitteeIndex) -> AttestationData:
    debug "get_v1_validator_attestation", slot = slot
    let
      head = node.doChecksAndGetCurrentHead(slot)
      epochRef = node.chainDag.getEpochRef(head, slot.epoch)
    return makeAttestationData(epochRef, head.atSlot(slot), committee_index.uint64)

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
            let curr_val_pubkey = epochRef.validator_keys[validatorIdx].initPubKey
            if public_keys.findIt(it == curr_val_pubkey) != -1:
              result.add((public_key: curr_val_pubkey,
                          validator_index: validatorIdx,
                          committee_index: committee_index.CommitteeIndex,
                          committee_length: committee.lenu64,
                          validator_committee_index: index_in_committee.uint64,
                          slot: slot))

  rpcServer.rpc("get_v1_validator_duties_proposer") do (
      epoch: Epoch) -> seq[ValidatorPubkeySlotPair]:
    debug "get_v1_validator_duties_proposer", epoch = epoch
    let
      head = node.doChecksAndGetCurrentHead(epoch)
      epochRef = node.chainDag.getEpochRef(head, epoch)
    for i in 0 ..< SLOTS_PER_EPOCH:
      if epochRef.beacon_proposers[i].isSome():
        result.add((public_key: epochRef.beacon_proposers[i].get()[1].initPubKey(),
                    slot: compute_start_slot_at_epoch(epoch) + i))

  rpcServer.rpc("post_v1_validator_beacon_committee_subscriptions") do (
      committee_index: CommitteeIndex, slot: Slot, aggregator: bool,
      validator_pubkey: ValidatorPubKey, slot_signature: ValidatorSig) -> bool:
    debug "post_v1_validator_beacon_committee_subscriptions"
    raise newException(CatchableError, "Not implemented")
