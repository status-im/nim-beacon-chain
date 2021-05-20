# beacon_chain
# Copyright (c) 2018-2021 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [Defect].}

import
  std/[parseutils, sequtils, strutils, deques, sets],
  stew/results,
  json_rpc/servers/httpserver,
  chronicles,
  nimcrypto/utils as ncrutils,
  ../beacon_node_common,
  ../networking/eth2_network,
  ../validators/validator_duties,
  ../gossip_processing/gossip_validation,
  ../consensus_object_pools/blockchain_dag,
  ../spec/[crypto, digest, datatypes, validator, network],
  ../spec/eth2_apis/callsigs_types,
  ../ssz/merkleization,
  ./rpc_utils, ./eth2_json_rpc_serialization

logScope: topics = "beaconapi"

type
  RpcServer = RpcHttpServer

  ValidatorQuery = object
    keyset: HashSet[ValidatorPubKey]
    ids: seq[uint64]

  StatusQuery = object
    statset: HashSet[string]

template unimplemented() =
  raise (ref CatchableError)(msg: "Unimplemented")

proc parsePubkey(str: string): ValidatorPubKey {.raises: [Defect, ValueError].} =
  const expectedLen = RawPubKeySize * 2 + 2
  if str.len != expectedLen: # +2 because of the `0x` prefix
    raise newException(ValueError,
      "A hex public key should be exactly " & $expectedLen & " characters. " &
      $str.len & " provided")
  let pubkeyRes = fromHex(ValidatorPubKey, str)
  if pubkeyRes.isErr:
    raise newException(ValueError, "Not a valid public key")
  return pubkeyRes[]

proc createIdQuery(ids: openArray[string]): Result[ValidatorQuery, string] =
  # validatorIds array should have maximum 30 items, and all items should be
  # unique.
  if len(ids) > 30:
    return err("The number of ids exceeds the limit")

  # All ids in validatorIds must be unique.
  if len(ids) != len(toHashSet(ids)):
    return err("ids array must have unique item")

  var res = ValidatorQuery(
    keyset: initHashSet[ValidatorPubKey](),
    ids: newSeq[uint64]()
  )

  for item in ids:
    if item.startsWith("0x"):
      if len(item) != RawPubKeySize * 2 + 2:
        return err("Incorrect hexadecimal key")
      let pubkeyRes = ValidatorPubKey.fromHex(item)
      if pubkeyRes.isErr:
        return err("Incorrect public key")
      res.keyset.incl(pubkeyRes.get())
    else:
      var tmp: uint64
      try:
        if parseBiggestUInt(item, tmp) != len(item):
          return err("Incorrect index value")
      except ValueError:
        return err("Cannot parse index value: " & item)
      res.ids.add(tmp)
  ok(res)

proc createStatusQuery(status: openArray[string]): Result[StatusQuery, string] =
  const AllowedStatuses = [
    "pending", "pending_initialized", "pending_queued",
    "active", "active_ongoing", "active_exiting", "active_slashed",
    "exited", "exited_unslashed", "exited_slashed",
    "withdrawal", "withdrawal_possible", "withdrawal_done"
  ]

  if len(status) > len(AllowedStatuses):
    return err("The number of statuses exceeds the limit")

  var res = StatusQuery(statset: initHashSet[string]())

  # All ids in validatorIds must be unique.
  if len(status) != len(toHashSet(status)):
    return err("Status array must have unique items")

  for item in status:
    if item notin AllowedStatuses:
      return err("Invalid status requested")
    case item
    of "pending":
      res.statset.incl("pending_initialized")
      res.statset.incl("pending_queued")
    of "active":
      res.statset.incl("active_ongoing")
      res.statset.incl("active_exiting")
      res.statset.incl("active_slashed")
    of "exited":
      res.statset.incl("exited_unslashed")
      res.statset.incl("exited_slashed")
    of "withdrawal":
      res.statset.incl("withdrawal_possible")
      res.statset.incl("withdrawal_done")
    else:
      res.statset.incl(item)

proc getStatus(validator: Validator,
               current_epoch: Epoch): Result[string, string] =
  if validator.activation_epoch > current_epoch:
    # pending
    if validator.activation_eligibility_epoch == FAR_FUTURE_EPOCH:
      ok("pending_initialized")
    else:
      # validator.activation_eligibility_epoch < FAR_FUTURE_EPOCH:
      ok("pending_queued")
  elif (validator.activation_epoch <= current_epoch) and
       (current_epoch < validator.exit_epoch):
    # active
    if validator.exit_epoch == FAR_FUTURE_EPOCH:
      ok("active_ongoing")
    elif not validator.slashed:
      # validator.exit_epoch < FAR_FUTURE_EPOCH
      ok("active_exiting")
    else:
      # validator.exit_epoch < FAR_FUTURE_EPOCH and validator.slashed:
      ok("active_slashed")
  elif (validator.exit_epoch <= current_epoch) and
       (current_epoch < validator.withdrawable_epoch):
    # exited
    if not validator.slashed:
      ok("exited_unslashed")
    else:
      # validator.slashed
      ok("exited_slashed")
  elif validator.withdrawable_epoch <= current_epoch:
    # withdrawal
    if validator.effective_balance != 0:
      ok("withdrawal_possible")
    else:
      # validator.effective_balance == 0
      ok("withdrawal_done")
  else:
    err("Invalid validator status")

proc getBlockDataFromBlockId(node: BeaconNode, blockId: string): BlockData {.raises: [Defect, CatchableError].} =
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

proc installBeaconApiHandlers*(rpcServer: RpcServer, node: BeaconNode) {.
    raises: [Exception].} = # TODO fix json-rpc
  rpcServer.rpc("get_v1_beacon_genesis") do () -> BeaconGenesisTuple:
    return (
      genesis_time: getStateField(node.chainDag.headState, genesis_time),
      genesis_validators_root:
        getStateField(node.chainDag.headState, genesis_validators_root),
      genesis_fork_version: node.runtimePreset.GENESIS_FORK_VERSION
    )

  rpcServer.rpc("get_v1_beacon_states_root") do (stateId: string) -> Eth2Digest:
    withStateForStateId(stateId):
      return hashedState.root

  rpcServer.rpc("get_v1_beacon_states_fork") do (stateId: string) -> Fork:
    withStateForStateId(stateId):
      return getStateField(stateData, fork)

  rpcServer.rpc("get_v1_beacon_states_finality_checkpoints") do (
      stateId: string) -> BeaconStatesFinalityCheckpointsTuple:
    withStateForStateId(stateId):
      return (previous_justified:
                getStateField(stateData, previous_justified_checkpoint),
              current_justified:
                getStateField(stateData, current_justified_checkpoint),
              finalized: getStateField(stateData, finalized_checkpoint))

  rpcServer.rpc("get_v1_beacon_states_stateId_validators") do (
      stateId: string, validatorIds: Option[seq[string]],
      status: Option[seq[string]]) -> seq[BeaconStatesValidatorsTuple]:
    var vquery: ValidatorQuery
    var squery: StatusQuery
    let current_epoch = getStateField(node.chainDag.headState, slot).epoch

    template statusCheck(status, statusQuery, vstatus, current_epoch): bool =
      if status.isNone():
        true
      else:
        if vstatus in squery.statset:
          true
        else:
          false

    var res: seq[BeaconStatesValidatorsTuple]

    withStateForStateId(stateId):
      if status.isSome:
        let sqres = createStatusQuery(status.get())
        if sqres.isErr:
          raise newException(CatchableError, sqres.error)
        squery = sqres.get()

      if validatorIds.isSome:
        let vqres = createIdQuery(validatorIds.get())
        if vqres.isErr:
          raise newException(CatchableError, vqres.error)
        vquery = vqres.get()

      if validatorIds.isNone():
        for index, validator in getStateField(stateData, validators).pairs():
          let sres = validator.getStatus(current_epoch)
          if sres.isOk:
            let vstatus = sres.get()
            let includeFlag = statusCheck(status, squery, vstatus,
                                          current_epoch)
            if includeFlag:
              res.add((validator: validator,
                       index: uint64(index),
                       status: vstatus,
                       balance: getStateField(stateData, balances)[index]))
      else:
        for index in vquery.ids:
          if index < lenu64(getStateField(stateData, validators)):
            let validator = getStateField(stateData, validators)[index]
            let sres = validator.getStatus(current_epoch)
            if sres.isOk:
              let vstatus = sres.get()
              let includeFlag = statusCheck(status, squery, vstatus,
                                            current_epoch)
              if includeFlag:
                vquery.keyset.excl(validator.pubkey)
                res.add((validator: validator,
                         index: uint64(index),
                         status: vstatus,
                         balance: getStateField(stateData, balances)[index]))

        for index, validator in getStateField(stateData, validators).pairs():
          if validator.pubkey in vquery.keyset:
            let sres = validator.getStatus(current_epoch)
            if sres.isOk:
              let vstatus = sres.get()
              let includeFlag = statusCheck(status, squery, vstatus,
                                            current_epoch)
              if includeFlag:
                res.add((validator: validator,
                         index: uint64(index),
                         status: vstatus,
                         balance: getStateField(stateData, balances)[index]))
    return res

  rpcServer.rpc("get_v1_beacon_states_stateId_validators_validatorId") do (
      stateId: string, validatorId: string) -> BeaconStatesValidatorsTuple:
    let current_epoch = getStateField(node.chainDag.headState, slot).epoch
    let vqres = createIdQuery([validatorId])
    if vqres.isErr:
      raise newException(CatchableError, vqres.error)
    let vquery = vqres.get()

    withStateForStateId(stateId):
      if len(vquery.ids) > 0:
        let index = vquery.ids[0]
        if index < lenu64(getStateField(stateData, validators)):
          let validator = getStateField(stateData, validators)[index]
          let sres = validator.getStatus(current_epoch)
          if sres.isOk:
            return (validator: validator, index: uint64(index),
                    status: sres.get(),
                    balance: getStateField(stateData, balances)[index])
          else:
            raise newException(CatchableError, "Incorrect validator's state")
      else:
        for index, validator in getStateField(stateData, validators).pairs():
          if validator.pubkey in vquery.keyset:
            let sres = validator.getStatus(current_epoch)
            if sres.isOk:
              return (validator: validator, index: uint64(index),
                      status: sres.get(),
                      balance: getStateField(stateData, balances)[index])
            else:
              raise newException(CatchableError, "Incorrect validator's state")

  rpcServer.rpc("get_v1_beacon_states_stateId_validator_balances") do (
      stateId: string, validatorsId: Option[seq[string]]) -> seq[BalanceTuple]:

    var res: seq[BalanceTuple]
    withStateForStateId(stateId):
      if validatorsId.isNone():
        for index, value in getStateField(stateData, balances).pairs():
          let balance = (index: uint64(index), balance: value)
          res.add(balance)
      else:
        let vqres = createIdQuery(validatorsId.get())
        if vqres.isErr:
          raise newException(CatchableError, vqres.error)

        var vquery = vqres.get()
        for index in vquery.ids:
          if index < lenu64(getStateField(stateData, validators)):
            let validator = getStateField(stateData, validators)[index]
            vquery.keyset.excl(validator.pubkey)
            let balance = (index: uint64(index),
                           balance: getStateField(stateData, balances)[index])
            res.add(balance)

        for index, validator in getStateField(stateData, validators).pairs():
          if validator.pubkey in vquery.keyset:
            let balance = (index: uint64(index),
                           balance: getStateField(stateData, balances)[index])
            res.add(balance)
    return res

  rpcServer.rpc("get_v1_beacon_states_stateId_committees_epoch") do (
      stateId: string, epoch: Option[uint64], index: Option[uint64],
      slot: Option[uint64]) -> seq[BeaconStatesCommitteesTuple]:
    withStateForStateId(stateId):
      proc getCommittee(slot: Slot,
                        index: CommitteeIndex): BeaconStatesCommitteesTuple =
        let vals = get_beacon_committee(state, slot, index, cache).mapIt(it.uint64)
        return (index: index.uint64, slot: slot.uint64, validators: vals)

      proc forSlot(slot: Slot, res: var seq[BeaconStatesCommitteesTuple]) =
        let committees_per_slot =
          get_committee_count_per_slot(state, slot.epoch, cache)

        if index.isNone:
          for committee_index in 0'u64..<committees_per_slot:
            res.add(getCommittee(slot, committee_index.CommitteeIndex))
        else:
          if index.get() < committees_per_slot:
            res.add(getCommittee(slot, CommitteeIndex(index.get())))

      var res: seq[BeaconStatesCommitteesTuple]

      let qepoch =
        if epoch.isNone:
          compute_epoch_at_slot(getStateField(stateData, slot))
        else:
          Epoch(epoch.get())

      if slot.isNone:
        for i in 0 ..< SLOTS_PER_EPOCH:
          forSlot(compute_start_slot_at_epoch(qepoch) + i, res)
      else:
        forSlot(Slot(slot.get()), res)

      return res

  rpcServer.rpc("get_v1_beacon_headers") do (
      slot: Option[uint64], parent_root: Option[string]) ->
      seq[BeaconHeadersTuple]:
    unimplemented()

  rpcServer.rpc("get_v1_beacon_headers_blockId") do (
      blockId: string) ->
      tuple[canonical: bool, header: SignedBeaconBlockHeader]:
    let bd = node.getBlockDataFromBlockId(blockId)
    let tsbb = bd.data
    static: doAssert tsbb.signature is TrustedSig and
              sizeof(ValidatorSig) == sizeof(tsbb.signature)
    result.header.signature = cast[ValidatorSig](tsbb.signature)

    result.header.message.slot = tsbb.message.slot
    result.header.message.proposer_index = tsbb.message.proposer_index
    result.header.message.parent_root = tsbb.message.parent_root
    result.header.message.state_root = tsbb.message.state_root
    result.header.message.body_root = tsbb.message.body.hash_tree_root()

    result.canonical = bd.refs.isAncestorOf(node.chainDag.head)

  rpcServer.rpc("post_v1_beacon_blocks") do (blck: SignedBeaconBlock) -> int:
    if not(node.syncManager.inProgress):
      raise newException(CatchableError,
                         "Beacon node is currently syncing, try again later.")
    let head = node.chainDag.head
    if head.slot >= blck.message.slot:
      node.network.broadcast(getBeaconBlocksTopic(node.forkDigest), blck)
      # The block failed validation, but was successfully broadcast anyway.
      # It was not integrated into the beacon node's database.
      return 202
    else:
      let res = await proposeSignedBlock(node, head, AttachedValidator(), blck)
      if res == head:
        node.network.broadcast(getBeaconBlocksTopic(node.forkDigest), blck)
        # The block failed validation, but was successfully broadcast anyway.
        # It was not integrated into the beacon node''s database.
        return 202
      else:
        # The block was validated successfully and has been broadcast.
        # It has also been integrated into the beacon node's database.
        return 200

  rpcServer.rpc("get_v1_beacon_blocks_blockId") do (
      blockId: string) -> TrustedSignedBeaconBlock:
    return node.getBlockDataFromBlockId(blockId).data

  rpcServer.rpc("get_v1_beacon_blocks_blockId_root") do (
      blockId: string) -> Eth2Digest:
    return node.getBlockDataFromBlockId(blockId).data.message.state_root

  rpcServer.rpc("get_v1_beacon_blocks_blockId_attestations") do (
      blockId: string) -> seq[TrustedAttestation]:
    return node.getBlockDataFromBlockId(blockId).data.message.body.attestations.asSeq

  rpcServer.rpc("get_v1_beacon_pool_attestations") do (
      slot: Option[uint64], committee_index: Option[uint64]) ->
      seq[AttestationTuple]:

    var res: seq[AttestationTuple]

    let qslot =
      if slot.isSome():
        some(Slot(slot.get()))
      else:
        none[Slot]()

    let qindex =
      if committee_index.isSome():
        some(CommitteeIndex(committee_index.get()))
      else:
        none[CommitteeIndex]()

    for item in node.attestationPool[].attestations(qslot, qindex):
      let atuple = (
        aggregation_bits: "0x" & ncrutils.toHex(item.aggregation_bits.bytes),
        data: item.data,
        signature: item.signature
      )
      res.add(atuple)

    return res

  rpcServer.rpc("post_v1_beacon_pool_attestations") do (
      attestation: Attestation) -> bool:
    return await node.sendAttestation(attestation)

  rpcServer.rpc("get_v1_beacon_pool_attester_slashings") do (
      ) -> seq[AttesterSlashing]:
    var res: seq[AttesterSlashing]
    if isNil(node.exitPool):
      return res
    let length = len(node.exitPool.attester_slashings)
    res = newSeqOfCap[AttesterSlashing](length)
    for item in node.exitPool.attester_slashings.items():
      res.add(item)
    return res

  rpcServer.rpc("post_v1_beacon_pool_attester_slashings") do (
      slashing: AttesterSlashing) -> bool:
    if isNil(node.exitPool):
      raise newException(CatchableError, "Exit pool is not yet available!")
    let validity = node.exitPool[].validateAttesterSlashing(slashing)
    if validity.isOk:
      node.sendAttesterSlashing(slashing)
    else:
      raise newException(CatchableError, $(validity.error[1]))
    return true

  rpcServer.rpc("get_v1_beacon_pool_proposer_slashings") do (
      ) -> seq[ProposerSlashing]:
    var res: seq[ProposerSlashing]
    if isNil(node.exitPool):
      return res
    let length = len(node.exitPool.proposer_slashings)
    res = newSeqOfCap[ProposerSlashing](length)
    for item in node.exitPool.proposer_slashings.items():
      res.add(item)
    return res

  rpcServer.rpc("post_v1_beacon_pool_proposer_slashings") do (
      slashing: ProposerSlashing) -> bool:
    if isNil(node.exitPool):
      raise newException(CatchableError, "Exit pool is not yet available!")
    let validity = node.exitPool[].validateProposerSlashing(slashing)
    if validity.isOk:
      node.sendProposerSlashing(slashing)
    else:
      raise newException(CatchableError, $(validity.error[1]))
    return true

  rpcServer.rpc("get_v1_beacon_pool_voluntary_exits") do (
      ) -> seq[SignedVoluntaryExit]:
    var res: seq[SignedVoluntaryExit]
    if isNil(node.exitPool):
      return res
    let length = len(node.exitPool.voluntary_exits)
    res = newSeqOfCap[SignedVoluntaryExit](length)
    for item in node.exitPool.voluntary_exits.items():
      res.add(item)
    return res

  rpcServer.rpc("post_v1_beacon_pool_voluntary_exits") do (
      exit: SignedVoluntaryExit) -> bool:
    if isNil(node.exitPool):
      raise newException(CatchableError, "Exit pool is not yet available!")
    let validity = node.exitPool[].validateVoluntaryExit(exit)
    if validity.isOk:
      node.sendVoluntaryExit(exit)
    else:
      raise newException(CatchableError, $(validity.error[1]))
    return true
