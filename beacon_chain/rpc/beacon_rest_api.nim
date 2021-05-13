# Copyright (c) 2018-2021 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.
import
  std/[typetraits, sequtils, strutils, deques, sets, options],
  stew/[results, base10],
  chronicles,
  nimcrypto/utils as ncrutils,
  ../beacon_node_common, ../networking/eth2_network,
  ../consensus_object_pools/[blockchain_dag, exit_pool, statedata_helpers],
  ../gossip_processing/gossip_validation,
  ../validators/validator_duties,
  ../spec/[crypto, digest, validator, datatypes, network],
  ../ssz/merkleization,
  ./eth2_json_rest_serialization, ./rest_utils

logScope: topics = "rest_beaconapi"

const
  # https://github.com/ethereum/eth2.0-APIs/blob/master/apis/beacon/states/validator_balances.yaml#L17
  # https://github.com/ethereum/eth2.0-APIs/blob/master/apis/beacon/states/validators.yaml#L17
  MaximumValidatorIds = 30

type
  RestValidatorTuple = tuple
    index: ValidatorIndex
    balance: string
    status: string
    validator: Validator

  RestValidatorBalanceTuple = tuple
    index: ValidatorIndex
    balance: string

  RestBeaconStatesCommitteesTuple* = tuple
    index: CommitteeIndex
    slot: Slot
    validators: seq[ValidatorIndex]

  RestAttestationsFailureTuple* = tuple
    index: uint64
    message: string

proc validateFilter(filters: seq[ValidatorFilter]): Result[ValidatorFilter,
                                                           cstring] =
  var res: ValidatorFilter
  for item in filters:
    if res * item != {}:
      return err("Validator status must be unique")
    res.incl(item)

  if res == {}:
    res = {ValidatorFilterKind.PendingInitialized,
           ValidatorFilterKind.PendingQueued,
           ValidatorFilterKind.ActiveOngoing,
           ValidatorFilterKind.ActiveExiting,
           ValidatorFilterKind.ActiveSlashed,
           ValidatorFilterKind.ExitedUnslashed,
           ValidatorFilterKind.ExitedSlashed,
           ValidatorFilterKind.WithdrawalPossible,
           ValidatorFilterKind.WithdrawalDone}
  ok(res)

proc getStatus(validator: Validator,
               current_epoch: Epoch): Result[ValidatorFilterKind, cstring] =
  if validator.activation_epoch > current_epoch:
    # pending
    if validator.activation_eligibility_epoch == FAR_FUTURE_EPOCH:
      ok(ValidatorFilterKind.PendingInitialized)
    else:
      # validator.activation_eligibility_epoch < FAR_FUTURE_EPOCH:
      ok(ValidatorFilterKind.PendingQueued)
  elif (validator.activation_epoch <= current_epoch) and
       (current_epoch < validator.exit_epoch):
    # active
    if validator.exit_epoch == FAR_FUTURE_EPOCH:
      ok(ValidatorFilterKind.ActiveOngoing)
    elif not validator.slashed:
      # validator.exit_epoch < FAR_FUTURE_EPOCH
      ok(ValidatorFilterKind.ActiveExiting)
    else:
      # validator.exit_epoch < FAR_FUTURE_EPOCH and validator.slashed:
      ok(ValidatorFilterKind.ActiveSlashed)
  elif (validator.exit_epoch <= current_epoch) and
       (current_epoch < validator.withdrawable_epoch):
    # exited
    if not validator.slashed:
      ok(ValidatorFilterKind.ExitedUnslashed)
    else:
      # validator.slashed
      ok(ValidatorFilterKind.ExitedSlashed)
  elif validator.withdrawable_epoch <= current_epoch:
    # withdrawal
    if validator.effective_balance != 0:
      ok(ValidatorFilterKind.WithdrawalPossible)
    else:
      # validator.effective_balance == 0
      ok(ValidatorFilterKind.WithdrawalDone)
  else:
    err("Invalid validator status")

proc toString*(kind: ValidatorFilterKind): string =
  case kind
  of ValidatorFilterKind.PendingInitialized:
    "pending_initialized"
  of ValidatorFilterKind.PendingQueued:
    "pending_queued"
  of ValidatorFilterKind.ActiveOngoing:
    "active_ongoing"
  of ValidatorFilterKind.ActiveExiting:
    "active_exiting"
  of ValidatorFilterKind.ActiveSlashed:
    "active_slashed"
  of ValidatorFilterKind.ExitedUnslashed:
    "exited_unslashed"
  of ValidatorFilterKind.ExitedSlashed:
    "exited_slashed"
  of ValidatorFilterKind.WithdrawalPossible:
    "withdrawal_possible"
  of ValidatorFilterKind.WithdrawalDone:
    "withdrawal_done"

proc installBeaconApiHandlers*(router: var RestRouter, node: BeaconNode) =
  # https://ethereum.github.io/eth2.0-APIs/#/Beacon/getGenesis
  router.api(MethodGet, "/api/eth/v1/beacon/genesis") do () -> RestApiResponse:
    return RestApiResponse.jsonResponse(
      (
        genesis_time: getStateField(node.chainDag.headState, genesis_time),
        genesis_validators_root:
          getStateField(node.chainDag.headState, genesis_validators_root),
        genesis_fork_version: node.runtimePreset.GENESIS_FORK_VERSION
      )
    )

  # https://ethereum.github.io/eth2.0-APIs/#/Beacon/getStateRoot
  router.api(MethodGet, "/api/eth/v1/beacon/states/{state_id}/root") do (
    state_id: StateIdent) -> RestApiResponse:
    let bslot =
      block:
        if state_id.isErr():
          return RestApiResponse.jsonError(Http400, InvalidStateIdValueError,
                                           $state_id.error())
        let bres = node.getBlockSlot(state_id.get())
        if bres.isErr():
          return RestApiResponse.jsonError(Http404, StateNotFoundError,
                                           $bres.error())
        bres.get()
    node.withStateForBlockSlot(bslot):
      return RestApiResponse.jsonResponse((root: hashedState().root))
    return RestApiResponse.jsonError(Http500, InternalServerError)

  # https://ethereum.github.io/eth2.0-APIs/#/Beacon/getStateFork
  router.api(MethodGet, "/api/eth/v1/beacon/states/{state_id}/fork") do (
    state_id: StateIdent) -> RestApiResponse:
    let bslot =
      block:
        if state_id.isErr():
          return RestApiResponse.jsonError(Http400, InvalidStateIdValueError,
                                           $state_id.error())
        let bres = node.getBlockSlot(state_id.get())
        if bres.isErr():
          return RestApiResponse.jsonError(Http404, StateNotFoundError,
                                           $bres.error())
        bres.get()
    node.withStateForBlockSlot(bslot):
      return RestApiResponse.jsonResponse(
        (
          previous_version: getStateField(stateData, fork).previous_version,
          current_version: getStateField(stateData, fork).current_version,
          epoch: getStateField(stateData, fork).epoch
        )
      )
    return RestApiResponse.jsonError(Http500, InternalServerError)

  # https://ethereum.github.io/eth2.0-APIs/#/Beacon/getStateFinalityCheckpoints
  router.api(MethodGet,
             "/api/eth/v1/beacon/states/{state_id}/finality_checkpoints") do (
    state_id: StateIdent) -> RestApiResponse:
    let bslot =
      block:
        if state_id.isErr():
          return RestApiResponse.jsonError(Http400, InvalidStateIdValueError,
                                           $state_id.error())
        let bres = node.getBlockSlot(state_id.get())
        if bres.isErr():
          return RestApiResponse.jsonError(Http404, StateNotFoundError,
                                           $bres.error())
        bres.get()
    node.withStateForBlockSlot(bslot):
      return RestApiResponse.jsonResponse(
        (
          previous_justified:
            getStateField(stateData, previous_justified_checkpoint),
          current_justified:
            getStateField(stateData, current_justified_checkpoint),
          finalized: getStateField(stateData, finalized_checkpoint)
        )
      )
    return RestApiResponse.jsonError(Http500, InternalServerError)

  # https://ethereum.github.io/eth2.0-APIs/#/Beacon/getStateValidators
  router.api(MethodGet, "/api/eth/v1/beacon/states/{state_id}/validators") do (
    state_id: StateIdent, id: seq[ValidatorIdent],
    status: seq[ValidatorFilter]) -> RestApiResponse:
    let bslot =
      block:
        if state_id.isErr():
          return RestApiResponse.jsonError(Http400, InvalidStateIdValueError,
                                           $state_id.error())
        let bres = node.getBlockSlot(state_id.get())
        if bres.isErr():
          return RestApiResponse.jsonError(Http404, StateNotFoundError,
                                           $bres.error())
        bres.get()
    let validatorIds =
      block:
        if id.isErr():
          return RestApiResponse.jsonError(Http400,
                                           InvalidValidatorIdValueError)
        let ires = id.get()
        if len(ires) > MaximumValidatorIds:
          return RestApiResponse.jsonError(Http400,
                                           MaximumNumberOfValidatorIdsError)
        ires

    let validatorsMask =
      block:
        if status.isErr():
          return RestApiResponse.jsonError(Http400,
                                           InvalidValidatorStatusValueError)
        let res = validateFilter(status.get())
        if res.isErr():
          return RestApiResponse.jsonError(Http400,
                                           InvalidValidatorStatusValueError,
                                           $res.error())
        res.get()

    let (keySet, indexSet) =
      block:
        var res1: HashSet[ValidatorPubKey]
        var res2: HashSet[ValidatorIndex]
        for item in validatorIds:
          case item.kind
          of ValidatorQueryKind.Key:
            if item.key in res1:
              return RestApiResponse.jsonError(Http400, UniqueValidatorKeyError)
            res1.incl(item.key)
          of ValidatorQueryKind.Index:
            let vitem =
              block:
                let vres = item.index.toValidatorIndex()
                if vres.isErr():
                  case vres.error()
                  of ValidatorIndexError.TooHighValue:
                    return RestApiResponse.jsonError(Http400,
                                                TooHighValidatorIndexValueError)
                  of ValidatorIndexError.UnsupportedValue:
                    return RestApiResponse.jsonError(Http500,
                                            UnsupportedValidatorIndexValueError)
                vres.get()

            if vitem in res2:
              return RestApiResponse.jsonError(Http400,
                                               UniqueValidatorIndexError)
            res2.incl(vitem)
        (res1, res2)

    node.withStateForBlockSlot(bslot):
      let current_epoch = get_current_epoch(node.chainDag.headState)
      var res: seq[RestValidatorTuple]
      for index, validator in getStateField(stateData, validators).pairs():
        let includeFlag =
          (len(keySet) == 0) and (len(indexSet) == 0) or
          (len(indexSet) > 0 and (ValidatorIndex(index) in indexSet)) or
          (len(keySet) > 0 and (validator.pubkey in keySet))
        let sres = validator.getStatus(current_epoch)
        if sres.isOk():
          let vstatus = sres.get()
          let statusFlag = vstatus in validatorsMask
          if includeFlag and statusFlag:
            res.add((
              index: ValidatorIndex(index),
              balance:
                Base10.toString(getStateField(stateData, balances)[index]),
              status: toString(vstatus),
              validator: validator
            ))
      return RestApiResponse.jsonResponse(res)

    return RestApiResponse.jsonError(Http500, InternalServerError)

  # https://ethereum.github.io/eth2.0-APIs/#/Beacon/getStateValidator
  router.api(MethodGet,
          "/api/eth/v1/beacon/states/{state_id}/validators/{validator_id}") do (
    state_id: StateIdent, validator_id: ValidatorIdent) -> RestApiResponse:
    let bslot =
      block:
        if state_id.isErr():
          return RestApiResponse.jsonError(Http400, InvalidStateIdValueError,
                                           $state_id.error())
        let bres = node.getBlockSlot(state_id.get())
        if bres.isErr():
          return RestApiResponse.jsonError(Http404, StateNotFoundError,
                                           $bres.error())
        bres.get()
    if validator_id.isErr():
      return RestApiResponse.jsonError(Http400, InvalidValidatorIdValueError,
                                       $validator_id.error())
    node.withStateForBlockSlot(bslot):
      let current_epoch = get_current_epoch(node.chainDag.headState)
      let vid = validator_id.get()
      case vid.kind
      of ValidatorQueryKind.Key:
        for index, validator in getStateField(stateData, validators).pairs():
          if validator.pubkey == vid.key:
            let sres = validator.getStatus(current_epoch)
            if sres.isOk():
              return RestApiResponse.jsonResponse(
                (
                  index: ValidatorIndex(index),
                  balance:
                    Base10.toString(getStateField(stateData, balances)[index]),
                  status: toString(sres.get()),
                  validator: validator
                )
              )
            else:
              return RestApiResponse.jsonError(Http400,
                                               ValidatorStatusNotFoundError)
        return RestApiResponse.jsonError(Http404, ValidatorNotFoundError)
      of ValidatorQueryKind.Index:
        let vindex =
          block:
            let vres = vid.index.toValidatorIndex()
            if vres.isErr():
              case vres.error()
              of ValidatorIndexError.TooHighValue:
                return RestApiResponse.jsonError(Http400,
                                                TooHighValidatorIndexValueError)
              of ValidatorIndexError.UnsupportedValue:
                return RestApiResponse.jsonError(Http500,
                                            UnsupportedValidatorIndexValueError)
            vres.get()

        if uint64(vindex) >= uint64(len(getStateField(stateData, validators))):
          return RestApiResponse.jsonError(Http404, ValidatorNotFoundError)
        let validator = getStateField(stateData, validators)[vindex]
        let sres = validator.getStatus(current_epoch)
        if sres.isOk():
          return RestApiResponse.jsonResponse(
            (
              index: vindex,
              balance: Base10.toString(getStateField(stateData, balances)[vindex]),
              status: toString(sres.get()),
              validator: validator
            )
          )
        else:
          return RestApiResponse.jsonError(Http400,
                                           ValidatorStatusNotFoundError)
    return RestApiResponse.jsonError(Http500, InternalServerError)

  # https://ethereum.github.io/eth2.0-APIs/#/Beacon/getStateValidatorBalances
  router.api(MethodGet,
             "/api/eth/v1/beacon/states/{state_id}/validator_balances") do (
    state_id: StateIdent, id: seq[ValidatorIdent]) -> RestApiResponse:
    let bslot =
      block:
        if state_id.isErr():
          return RestApiResponse.jsonError(Http400, InvalidStateIdValueError,
                                           $state_id.error())
        let bres = node.getBlockSlot(state_id.get())
        if bres.isErr():
          return RestApiResponse.jsonError(Http404, StateNotFoundError,
                                           $bres.error())
        bres.get()
    let validatorIds =
      block:
        if id.isErr():
          return RestApiResponse.jsonError(Http400,
                                           InvalidValidatorIdValueError)
        let ires = id.get()
        if len(ires) > MaximumValidatorIds:
          return RestApiResponse.jsonError(Http400,
                                           MaximumNumberOfValidatorIdsError)
        ires
    let (keySet, indexSet) =
      block:
        var res1: HashSet[ValidatorPubKey]
        var res2: HashSet[ValidatorIndex]
        for item in validatorIds:
          case item.kind
          of ValidatorQueryKind.Key:
            if item.key in res1:
              return RestApiResponse.jsonError(Http400,
                                               UniqueValidatorKeyError)
            res1.incl(item.key)
          of ValidatorQueryKind.Index:
            let vitem =
              block:
                let vres = item.index.toValidatorIndex()
                if vres.isErr():
                  case vres.error()
                  of ValidatorIndexError.TooHighValue:
                    return RestApiResponse.jsonError(Http400,
                                                TooHighValidatorIndexValueError)
                  of ValidatorIndexError.UnsupportedValue:
                    return RestApiResponse.jsonError(Http500,
                                            UnsupportedValidatorIndexValueError)
                vres.get()
            if vitem in res2:
              return RestApiResponse.jsonError(Http400,
                                               UniqueValidatorIndexError)
            res2.incl(vitem)
        (res1, res2)
    node.withStateForBlockSlot(bslot):
      let current_epoch = get_current_epoch(node.chainDag.headState)
      var res: seq[RestValidatorBalanceTuple]
      for index, validator in getStateField(stateData, validators).pairs():
        let includeFlag =
          (len(keySet) == 0) and (len(indexSet) == 0) or
          (len(indexSet) > 0 and (ValidatorIndex(index) in indexSet)) or
          (len(keySet) > 0 and (validator.pubkey in keySet))
        let sres = validator.getStatus(current_epoch)
        if sres.isOk():
          let vstatus = sres.get()
          if includeFlag:
            res.add((
              index: ValidatorIndex(index),
              balance:
                Base10.toString(getStateField(stateData, balances)[index]),
            ))
      return RestApiResponse.jsonResponse(res)

    return RestApiResponse.jsonError(Http500, InternalServerError)

  # https://ethereum.github.io/eth2.0-APIs/#/Beacon/getEpochCommittees
  router.api(MethodGet,
             "/api/eth/v1/beacon/states/{state_id}/committees") do (
    state_id: StateIdent, epoch: Option[Epoch], index: Option[CommitteeIndex],
    slot: Option[Slot]) -> RestApiResponse:
    let bslot =
      block:
        if state_id.isErr():
          return RestApiResponse.jsonError(Http400, InvalidStateIdValueError,
                                           $state_id.error())
        let bres = node.getBlockSlot(state_id.get())
        if bres.isErr():
          return RestApiResponse.jsonError(Http404, StateNotFoundError,
                                           $bres.error())
        bres.get()
    let vepoch =
      if epoch.isSome():
        let repoch = epoch.get()
        if repoch.isErr():
          return RestApiResponse.jsonError(Http400, InvalidEpochValueError,
                                           $repoch.error())
        let res = repoch.get()
        if res > MaxEpoch:
          return RestApiResponse.jsonError(Http400, EpochOverflowValueError)
        some(res)
      else:
        none[Epoch]()
    let vindex =
      if index.isSome():
        let rindex = index.get()
        if rindex.isErr():
          return RestApiResponse.jsonError(Http400,
                                           InvalidCommitteeIndexValueError,
                                           $rindex.error())
        some(rindex.get())
      else:
        none[CommitteeIndex]()
    let vslot =
      if slot.isSome():
        let rslot = slot.get()
        if rslot.isErr():
          return RestApiResponse.jsonError(Http400, InvalidSlotValueError,
                                           $rslot.error())
        some(rslot.get())
      else:
        none[Slot]()
    node.withStateForBlockSlot(bslot):
      proc getCommittee(slot: Slot,
                       index: CommitteeIndex): RestBeaconStatesCommitteesTuple =
        let validators = get_beacon_committee(state, slot, index,
                                              cache).mapIt(it)
        (index: index, slot: slot, validators: validators)

      proc forSlot(slot: Slot, cindex: Option[CommitteeIndex],
                   res: var seq[RestBeaconStatesCommitteesTuple]) =
        let committees_per_slot =
          get_committee_count_per_slot(state, Epoch(slot), cache)

        if cindex.isNone:
          for committee_index in 0'u64 ..< committees_per_slot:
            res.add(getCommittee(slot, CommitteeIndex(committee_index)))
        else:
          let idx = cindex.get()
          if uint64(idx) < committees_per_slot:
            res.add(getCommittee(slot, CommitteeIndex(idx)))

      var res: seq[RestBeaconStatesCommitteesTuple]
      let qepoch =
        if vepoch.isNone:
          compute_epoch_at_slot(getStateField(stateData, slot))
        else:
          vepoch.get()

      if vslot.isNone():
        for i in 0 ..< SLOTS_PER_EPOCH:
          forSlot(compute_start_slot_at_epoch(qepoch) + i, vindex, res)
      else:
        forSlot(vslot.get(), vindex, res)

      return RestApiResponse.jsonResponse(res)

    return RestApiResponse.jsonError(Http500, InternalServerError)

  # https://ethereum.github.io/eth2.0-APIs/#/Beacon/getBlockHeaders
  router.api(MethodGet, "/api/eth/v1/beacon/headers") do (
    slot: Option[Slot], parent_root: Option[Eth2Digest]) -> RestApiResponse:
    # TODO (cheatfate): This call is not complete, because structure
    # of database do not allow to query blocks by `parent_root`.
    let qslot =
      if slot.isSome():
        let rslot = slot.get()
        if rslot.isErr():
          return RestApiResponse.jsonError(Http400, InvalidSlotValueError,
                                           $rslot.error())
        rslot.get()
      else:
        node.chainDag.head.slot

    if parent_root.isSome():
      let rroot = parent_root.get()
      if rroot.isErr():
        return RestApiResponse.jsonError(Http400, InvalidParentRootValueError,
                                         $rroot.error())
      return RestApiResponse.jsonError(Http500, NoImplementationError)

    let bdata =
      block:
        let head =
          block:
            let res = node.getCurrentHead(qslot)
            if res.isErr():
              return RestApiResponse.jsonError(Http404, SlotNotFoundError,
                                               $res.error())
            res.get()
        let blockSlot = head.atSlot(qslot)
        if isNil(blockSlot.blck):
          return RestApiResponse.jsonError(Http404, BlockNotFoundError)
        node.chainDag.get(blockSlot.blck)

    return RestApiResponse.jsonResponse(
      (
        root: bdata.data.root,
        canonical: bdata.refs.isAncestorOf(node.chainDag.head),
        header: (
          message: (
            slot: bdata.data.message.slot,
            proposer_index: bdata.data.message.proposer_index,
            parent_root: bdata.data.message.parent_root,
            state_root: bdata.data.message.state_root,
            body_root: bdata.data.message.body.hash_tree_root()
          ),
          signature: bdata.data.signature
        )
      )
    )

  # https://ethereum.github.io/eth2.0-APIs/#/Beacon/getBlockHeader
  router.api(MethodGet, "/api/eth/v1/beacon/headers/{block_id}") do (
    block_id: BlockIdent) -> RestApiResponse:
    let bdata =
      block:
        if block_id.isErr():
          return RestApiResponse.jsonError(Http400, InvalidBlockIdValueError,
                                           $block_id.error())
        let res = node.getBlockDataFromBlockIdent(block_id.get())
        if res.isErr():
          return RestApiResponse.jsonError(Http404, BlockNotFoundError)
        res.get()

    return RestApiResponse.jsonResponse(
      (
        root: bdata.data.root,
        canonical: bdata.refs.isAncestorOf(node.chainDag.head),
        header: (
          message: (
            slot: bdata.data.message.slot,
            proposer_index: bdata.data.message.proposer_index,
            parent_root: bdata.data.message.parent_root,
            state_root: bdata.data.message.state_root,
            body_root: bdata.data.message.body.hash_tree_root()
          ),
          signature: bdata.data.signature
        )
      )
    )

  # https://ethereum.github.io/eth2.0-APIs/#/Beacon/publishBlock
  router.api(MethodPost, "/api/eth/v1/beacon/blocks") do (
    contentBody: Option[ContentBody]) -> RestApiResponse:
    let blck =
      block:
        if contentBody.isNone():
          return RestApiResponse.jsonError(Http400, EmptyRequestBodyError)
        let dres = decodeBody(SignedBeaconBlock, contentBody.get())
        if dres.isErr():
          return RestApiResponse.jsonError(Http400, InvalidBlockObjectError,
                                           $dres.error())
        dres.get()
    let head = node.chainDag.head
    if not(node.isSynced(head)):
      return RestApiResponse.jsonError(Http503, BeaconNodeInSyncError)

    if head.slot >= blck.message.slot:
      node.network.broadcast(getBeaconBlocksTopic(node.forkDigest), blck)
      return RestApiResponse.jsonError(Http202, BlockValidationError)
    else:
      let res = await proposeSignedBlock(node, head, AttachedValidator(), blck)
      if res == head:
        node.network.broadcast(getBeaconBlocksTopic(node.forkDigest), blck)
        return RestApiResponse.jsonError(Http202, BlockValidationError)
      else:
        return RestApiResponse.jsonError(Http200, BlockValidationSuccess)

  # https://ethereum.github.io/eth2.0-APIs/#/Beacon/getBlock
  router.api(MethodGet, "/api/eth/v1/beacon/blocks/{block_id}") do (
    block_id: BlockIdent) -> RestApiResponse:
    let bdata =
      block:
        if block_id.isErr():
          return RestApiResponse.jsonError(Http400, InvalidBlockIdValueError,
                                           $block_id.error())
        let res = node.getBlockDataFromBlockIdent(block_id.get())
        if res.isErr():
          return RestApiResponse.jsonError(Http404, BlockNotFoundError)
        res.get()
    return RestApiResponse.jsonResponse(bdata.data)

  # https://ethereum.github.io/eth2.0-APIs/#/Beacon/getBlockRoot
  router.api(MethodGet, "/api/eth/v1/beacon/blocks/{block_id}/root") do (
    block_id: BlockIdent) -> RestApiResponse:
    let bdata =
      block:
        if block_id.isErr():
          return RestApiResponse.jsonError(Http400, InvalidBlockIdValueError,
                                           $block_id.error())
        let res = node.getBlockDataFromBlockIdent(block_id.get())
        if res.isErr():
          return RestApiResponse.jsonError(Http404, BlockNotFoundError)
        res.get()
    return RestApiResponse.jsonResponse((root: bdata.data.root))

  # https://ethereum.github.io/eth2.0-APIs/#/Beacon/getBlockAttestations
  router.api(MethodGet,
             "/api/eth/v1/beacon/blocks/{block_id}/attestations") do (
    block_id: BlockIdent) -> RestApiResponse:
    let bdata =
      block:
        if block_id.isErr():
          return RestApiResponse.jsonError(Http400, InvalidBlockIdValueError,
                                           $block_id.error())
        let res = node.getBlockDataFromBlockIdent(block_id.get())
        if res.isErr():
          return RestApiResponse.jsonError(Http404, BlockNotFoundError)
        res.get()
    return RestApiResponse.jsonResponse(
      bdata.data.message.body.attestations.asSeq()
    )

  # https://ethereum.github.io/eth2.0-APIs/#/Beacon/getPoolAttestations
  router.api(MethodGet, "/api/eth/v1/beacon/pool/attestations") do (
    slot: Option[Slot],
    committee_index: Option[CommitteeIndex]) -> RestApiResponse:
    let vindex =
      if committee_index.isSome():
        let rindex = committee_index.get()
        if rindex.isErr():
          return RestApiResponse.jsonError(Http400,
                                           InvalidCommitteeIndexValueError,
                                           $rindex.error())
        some(rindex.get())
      else:
        none[CommitteeIndex]()
    let vslot =
      if slot.isSome():
        let rslot = slot.get()
        if rslot.isErr():
          return RestApiResponse.jsonError(Http400, InvalidSlotValueError,
                                           $rslot.error())
        some(rslot.get())
      else:
        none[Slot]()
    var res: seq[Attestation]
    for item in node.attestationPool[].attestations(vslot, vindex):
      res.add(item)
    return RestApiResponse.jsonResponse(res)

  # https://ethereum.github.io/eth2.0-APIs/#/Beacon/submitPoolAttestations
  router.api(MethodPost, "/api/eth/v1/beacon/pool/attestations") do (
    contentBody: Option[ContentBody]) -> RestApiResponse:
    let attestations =
      block:
        if contentBody.isNone():
          return RestApiResponse.jsonError(Http400, EmptyRequestBodyError)
        let dres = decodeBody(seq[Attestation], contentBody.get())
        if dres.isErr():
          return RestApiResponse.jsonError(Http400,
                                           InvalidAttestationObjectError,
                                           $dres.error())
        dres.get()

    var failures: seq[RestAttestationsFailureTuple]
    for atindex, attestation in attestations.pairs():
      if not await node.sendAttestation(attestation):
        failures.add(
          (index: uint64(atindex), message: "Attestation failed validation"))

    if len(failures) > 0:
      return RestApiResponse.jsonErrorList(Http400, AttestationValidationError,
                                           failures)
    else:
      return RestApiResponse.jsonError(Http200, AttestationValidationSuccess)

  # https://ethereum.github.io/eth2.0-APIs/#/Beacon/getPoolAttesterSlashings
  router.api(MethodGet, "/api/eth/v1/beacon/pool/attester_slashings") do (
    ) -> RestApiResponse:
    var res: seq[AttesterSlashing]
    if isNil(node.exitPool):
      return RestApiResponse.jsonResponse(res)
    let length = len(node.exitPool.attester_slashings)
    res = newSeqOfCap[AttesterSlashing](length)
    for item in node.exitPool.attester_slashings.items():
      res.add(item)
    return RestApiResponse.jsonResponse(res)

  # https://ethereum.github.io/eth2.0-APIs/#/Beacon/submitPoolAttesterSlashings
  router.api(MethodPost, "/api/eth/v1/beacon/pool/attester_slashings") do (
    contentBody: Option[ContentBody]) -> RestApiResponse:
    let slashing =
      block:
        if contentBody.isNone():
          return RestApiResponse.jsonError(Http400, EmptyRequestBodyError)
        let dres = decodeBody(AttesterSlashing, contentBody.get())
        if dres.isErr():
          return RestApiResponse.jsonError(Http400,
                                           InvalidAttesterSlashingObjectError,
                                           $dres.error())
        let res = dres.get()
        let vres = node.exitPool[].validateAttesterSlashing(res)
        if vres.isErr():
          return RestApiResponse.jsonError(Http400,
                                           AttesterSlashingValidationError,
                                           $vres.error())
        res
    node.sendAttesterSlashing(slashing)
    return RestApiResponse.jsonError(Http200, AttesterSlashingValidationSuccess)

  # https://ethereum.github.io/eth2.0-APIs/#/Beacon/getPoolProposerSlashings
  router.api(MethodGet, "/api/eth/v1/beacon/pool/proposer_slashings") do (
    ) -> RestApiResponse:
    var res: seq[ProposerSlashing]
    if isNil(node.exitPool):
      return RestApiResponse.jsonResponse(res)
    let length = len(node.exitPool.proposer_slashings)
    res = newSeqOfCap[ProposerSlashing](length)
    for item in node.exitPool.proposer_slashings.items():
      res.add(item)
    return RestApiResponse.jsonResponse(res)

  # https://ethereum.github.io/eth2.0-APIs/#/Beacon/submitPoolProposerSlashings
  router.api(MethodPost, "/api/eth/v1/beacon/pool/proposer_slashings") do (
    contentBody: Option[ContentBody]) -> RestApiResponse:
    let slashing =
      block:
        if contentBody.isNone():
          return RestApiResponse.jsonError(Http400, EmptyRequestBodyError)
        let dres = decodeBody(ProposerSlashing, contentBody.get())
        if dres.isErr():
          return RestApiResponse.jsonError(Http400,
                                           InvalidProposerSlashingObjectError,
                                           $dres.error())
        let res = dres.get()
        let vres = node.exitPool[].validateProposerSlashing(res)
        if vres.isErr():
          return RestApiResponse.jsonError(Http400,
                                           ProposerSlashingValidationError,
                                           $vres.error())
        res
    node.sendProposerSlashing(slashing)
    return RestApiResponse.jsonError(Http200, ProposerSlashingValidationSuccess)

  # https://ethereum.github.io/eth2.0-APIs/#/Beacon/getPoolVoluntaryExits
  router.api(MethodGet, "/api/eth/v1/beacon/pool/voluntary_exits") do (
    ) -> RestApiResponse:
    var res: seq[SignedVoluntaryExit]
    if isNil(node.exitPool):
      return RestApiResponse.jsonResponse(res)
    let length = len(node.exitPool.voluntary_exits)
    res = newSeqOfCap[SignedVoluntaryExit](length)
    for item in node.exitPool.voluntary_exits.items():
      res.add(item)
    return RestApiResponse.jsonResponse(res)

  # https://ethereum.github.io/eth2.0-APIs/#/Beacon/submitPoolVoluntaryExit
  router.api(MethodPost, "/api/eth/v1/beacon/pool/voluntary_exits") do (
    contentBody: Option[ContentBody]) -> RestApiResponse:
    let exit =
      block:
        if contentBody.isNone():
          return RestApiResponse.jsonError(Http400, EmptyRequestBodyError)
        let dres = decodeBody(SignedVoluntaryExit, contentBody.get())
        if dres.isErr():
          return RestApiResponse.jsonError(Http400,
                                           InvalidVoluntaryExitObjectError,
                                           $dres.error())
        let res = dres.get()
        let vres = node.exitPool[].validateVoluntaryExit(res)
        if vres.isErr():
          return RestApiResponse.jsonError(Http400,
                                           VoluntaryExitValidationError,
                                           $vres.error())
        res
    node.sendVoluntaryExit(exit)
    return RestApiResponse.jsonError(Http200, VoluntaryExitValidationSuccess)

  router.redirect(
    MethodGet,
    "/eth/v1/beacon/genesis",
    "/api/eth/v1/beacon/genesis"
  )
  router.redirect(
    MethodGet,
    "/eth/v1/beacon/states/{state_id}/root",
    "/api/eth/v1/beacon/states/{state_id}/root"
  )
  router.redirect(
    MethodGet,
    "/eth/v1/beacon/states/{state_id}/fork",
    "/api/eth/v1/beacon/states/{state_id}/fork"
  )
  router.redirect(
    MethodGet,
    "/eth/v1/beacon/states/{state_id}/finality_checkpoints",
    "/api/eth/v1/beacon/states/{state_id}/finality_checkpoints"
  )
  router.redirect(
    MethodGet,
    "/eth/v1/beacon/states/{state_id}/validators",
    "/api/eth/v1/beacon/states/{state_id}/validators"
  )
  router.redirect(
    MethodGet,
    "/eth/v1/beacon/states/{state_id}/validators/{validator_id}",
    "/api/eth/v1/beacon/states/{state_id}/validators/{validator_id}"
  )
  router.redirect(
    MethodGet,
    "/eth/v1/beacon/states/{state_id}/validator_balances",
    "/api/eth/v1/beacon/states/{state_id}/validator_balances"
  )
  router.redirect(
    MethodGet,
    "/eth/v1/beacon/states/{state_id}/committees",
    "/api/eth/v1/beacon/states/{state_id}/committees"
  )
  router.redirect(
    MethodGet,
    "/eth/v1/beacon/headers",
    "/api/eth/v1/beacon/headers"
  )
  router.redirect(
    MethodGet,
    "/eth/v1/beacon/headers/{block_id}",
    "/api/eth/v1/beacon/headers/{block_id}"
  )
  router.redirect(
    MethodPost,
    "/eth/v1/beacon/blocks",
    "/api/eth/v1/beacon/blocks"
  )
  router.redirect(
    MethodGet,
    "/eth/v1/beacon/blocks/{block_id}",
    "/api/eth/v1/beacon/blocks/{block_id}"
  )
  router.redirect(
    MethodGet,
    "/eth/v1/beacon/blocks/{block_id}/root",
    "/api/eth/v1/beacon/blocks/{block_id}/root"
  )
  router.redirect(
    MethodGet,
    "/eth/v1/beacon/blocks/{block_id}/attestations",
    "/api/eth/v1/beacon/blocks/{block_id}/attestations"
  )
  router.redirect(
    MethodGet,
    "/eth/v1/beacon/pool/attestations",
    "/api/eth/v1/beacon/pool/attestations"
  )
  router.redirect(
    MethodPost,
    "/eth/v1/beacon/pool/attester_slashings",
    "/api/eth/v1/beacon/pool/attester_slashings"
  )
  router.redirect(
    MethodGet,
    "/eth/v1/beacon/pool/attester_slashings",
    "/api/eth/v1/beacon/pool/attester_slashings"
  )
  router.redirect(
    MethodPost,
    "/eth/v1/beacon/pool/proposer_slashings",
    "/api/eth/v1/beacon/pool/proposer_slashings"
  )
  router.redirect(
    MethodGet,
    "/eth/v1/beacon/pool/proposer_slashings",
    "/api/eth/v1/beacon/pool/proposer_slashings"
  )
  router.redirect(
    MethodPost,
    "/eth/v1/beacon/pool/voluntary_exits",
    "/api/eth/v1/beacon/pool/voluntary_exits"
  )
  router.redirect(
    MethodGet,
    "/eth/v1/beacon/pool/voluntary_exits",
    "/api/eth/v1/beacon/pool/voluntary_exits"
  )
