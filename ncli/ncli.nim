import
  std/[os, strutils, stats],
  confutils, chronicles, json_serialization, ssz_serialization,
  stew/byteutils,
  ../research/simutils,
  ../beacon_chain/spec/[
    crypto, datatypes, digest, forkedbeaconstate_helpers, helpers, state_transition],
  ../beacon_chain/extras,
  ../beacon_chain/networking/network_metadata,
  ../beacon_chain/ssz/spec_types

type
  Cmd* = enum
    hashTreeRoot = "Compute hash tree root of SSZ object"
    pretty = "Pretty-print SSZ object"
    transition = "Run state transition function"
    slots = "Apply empty slots"

  NcliConf* = object

    eth2Network* {.
      desc: "The Eth2 network preset to use"
      name: "network" }: Option[string]

    # TODO confutils argument pragma doesn't seem to do much; also, the cases
    # are largely equivalent, but this helps create command line usage text
    case cmd* {.command}: Cmd
    of hashTreeRoot:
      htrKind* {.
        argument
        desc: "kind of SSZ object: attester_slashing, attestation, signed_block, block, block_body, block_header, deposit, deposit_data, eth1_data, state, proposer_slashing, or voluntary_exit"}: string

      htrFile* {.
        argument
        desc: "filename of SSZ or JSON-encoded object of which to compute hash tree root"}: string

    of pretty:
      prettyKind* {.
        argument
        desc: "kind of SSZ object: attester_slashing, attestation, signed_block, block, block_body, block_header, deposit, deposit_data, eth1_data, state, proposer_slashing, or voluntary_exit"}: string

      prettyFile* {.
        argument
        desc: "filename of SSZ or JSON-encoded object to pretty-print"}: string

    of transition:
      preState* {.
        argument
        desc: "State to which to apply specified block"}: string

      blck* {.
        argument
        desc: "Block to apply to preState"}: string

      postState* {.
        argument
        desc: "Filename of state resulting from applying blck to preState"}: string

      verifyStateRoot* {.
        argument
        desc: "Verify state root (default true)"
        defaultValue: true}: bool

    of slots:
      preState2* {.
        argument
        desc: "State to which to apply specified block"}: string

      slot* {.
        argument
        desc: "Block to apply to preState"}: uint64

      postState2* {.
        argument
        desc: "Filename of state resulting from applying blck to preState"}: string

proc doTransition(conf: NcliConf) =
  let
    stateY = (ref ForkedHashedBeaconState)(
      hbsPhase0: HashedBeaconState(
        data: SSZ.loadFile(conf.preState, BeaconState)),
      beaconStateFork: forkPhase0
    )
    blckX = SSZ.loadFile(conf.blck, SignedBeaconBlock)
    flags = if not conf.verifyStateRoot: {skipStateRootValidation} else: {}

  stateY.hbsPhase0.root = hash_tree_root(stateY[])

  var
    cache = StateCache()
    rewards = RewardInfo()
  if not state_transition(getRuntimePresetForNetwork(conf.eth2Network),
                          stateY[], blckX, cache, rewards, flags, noRollback):
    error "State transition failed"
    quit 1
  else:
    SSZ.saveFile(conf.postState, stateY.hbsPhase0.data)

proc doSlots(conf: NcliConf) =
  type
    Timers = enum
      tLoadState = "Load state from file"
      tApplySlot = "Apply slot"
      tApplyEpochSlot = "Apply epoch slot"
      tSaveState = "Save state to file"

  var timers: array[Timers, RunningStat]
  let
    stateY = withTimerRet(timers[tLoadState]): (ref ForkedHashedBeaconState)(
      hbsPhase0: HashedBeaconState(
        data: SSZ.loadFile(conf.preState2, BeaconState)),
      beaconStateFork: forkPhase0
    )

  stateY.hbsPhase0.root = hash_tree_root(stateY[])

  var
    cache = StateCache()
    rewards = RewardInfo()
  for i in 0'u64..<conf.slot:
    let isEpoch = (getStateField(stateY[], slot) + 1).isEpoch
    withTimer(timers[if isEpoch: tApplyEpochSlot else: tApplySlot]):
      doAssert process_slots(
        stateY[], getStateField(stateY[], slot) + 1, cache, rewards, {},
        FAR_FUTURE_SLOT)

  withTimer(timers[tSaveState]):
    SSZ.saveFile(conf.postState, stateY.hbsPhase0.data)

  printTimers(false, timers)

proc doSSZ(conf: NcliConf) =
  let (kind, file) =
    case conf.cmd:
    of hashTreeRoot: (conf.htrKind, conf.htrFile)
    of pretty: (conf.prettyKind, conf.prettyFile)
    else:
      raiseAssert "doSSZ() only implements hashTreeRoot and pretty commands"

  template printit(t: untyped) {.dirty.} =
    let v = newClone(
      if cmpIgnoreCase(ext, ".ssz") == 0:
        SSZ.loadFile(file, t)
      elif cmpIgnoreCase(ext, ".json") == 0:
        JSON.loadFile(file, t)
      else:
        echo "Unknown file type: ", ext
        quit 1
    )

    case conf.cmd:
    of hashTreeRoot:
      when t is SignedBeaconBlock:
        echo hash_tree_root(v.message).data.toHex()
      else:
        echo hash_tree_root(v[]).data.toHex()
    of pretty:
      echo JSON.encode(v[], pretty = true)
    else:
      raiseAssert "doSSZ() only implements hashTreeRoot and pretty commands"

  let ext = splitFile(file).ext

  case kind
  of "attester_slashing": printit(AttesterSlashing)
  of "attestation": printit(Attestation)
  of "signed_block": printit(SignedBeaconBlock)
  of "block": printit(BeaconBlock)
  of "block_body": printit(BeaconBlockBody)
  of "block_header": printit(BeaconBlockHeader)
  of "deposit": printit(Deposit)
  of "deposit_data": printit(DepositData)
  of "eth1_data": printit(Eth1Data)
  of "state": printit(BeaconState)
  of "proposer_slashing": printit(ProposerSlashing)
  of "voluntary_exit": printit(VoluntaryExit)

when isMainModule:
  let conf = NcliConf.load()

  case conf.cmd:
  of hashTreeRoot: doSSZ(conf)
  of pretty: doSSZ(conf)
  of transition: doTransition(conf)
  of slots: doSlots(conf)
