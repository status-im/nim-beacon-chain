import
  stats, os, strformat, times,
  ssz_serialization,
  ../tests/testblockutil,
  ../beacon_chain/[extras, beacon_chain_db],
  ../beacon_chain/ssz/spec_types,
  ../beacon_chain/spec/[
    beaconstate, crypto, datatypes, digest, forkedbeaconstate_helpers,
    helpers, presets],
  ../beacon_chain/consensus_object_pools/[blockchain_dag, block_pools_types],
  ../beacon_chain/eth1/eth1_monitor

template withTimer*(stats: var RunningStat, body: untyped) =
  # TODO unify timing somehow
  let start = cpuTime()

  block:
    body

  let stop = cpuTime()
  stats.push stop - start

template withTimerRet*(stats: var RunningStat, body: untyped): untyped =
  let start = cpuTime()
  let tmp = block:
    body
  let stop = cpuTime()
  stats.push stop - start

  tmp

func verifyConsensus*(state: BeaconState, attesterRatio: auto) =
  if attesterRatio < 0.63:
    doAssert state.current_justified_checkpoint.epoch == 0
    doAssert state.finalized_checkpoint.epoch == 0

  # Quorum is 2/3 of validators, and at low numbers, quantization effects
  # can dominate, so allow for play above/below attesterRatio of 2/3.
  if attesterRatio < 0.72:
    return

  let current_epoch = get_current_epoch(state)
  if current_epoch >= 3:
    doAssert state.current_justified_checkpoint.epoch + 1 >= current_epoch
  if current_epoch >= 4:
    doAssert state.finalized_checkpoint.epoch + 2 >= current_epoch

func verifyConsensus*(state: ForkedHashedBeaconState, attesterRatio: auto) =
  if attesterRatio < 0.63:
    doAssert getStateField(state, current_justified_checkpoint).epoch == 0
    doAssert getStateField(state, finalized_checkpoint).epoch == 0

  # Quorum is 2/3 of validators, and at low numbers, quantization effects
  # can dominate, so allow for play above/below attesterRatio of 2/3.
  if attesterRatio < 0.72:
    return

  let current_epoch = get_current_epoch(state)
  if current_epoch >= 3:
    doAssert getStateField(
      state, current_justified_checkpoint).epoch + 1 >= current_epoch
  if current_epoch >= 4:
    doAssert getStateField(
      state, finalized_checkpoint).epoch + 2 >= current_epoch

proc loadGenesis*(validators: Natural, validate: bool):
                 (ref HashedBeaconState, DepositContractSnapshot) =
  let
    genesisFn =
      &"genesis_{const_preset}_{validators}_{SPEC_VERSION}.ssz"
    contractSnapshotFn =
      &"deposit_contract_snapshot_{const_preset}_{validators}_{SPEC_VERSION}.ssz"
    res = (ref HashedBeaconState)()

  if fileExists(genesisFn) and fileExists(contractSnapshotFn):
    res.data = SSZ.loadFile(genesisFn, BeaconState)
    res.root = hash_tree_root(res.data)
    if res.data.slot != GENESIS_SLOT:
      echo "Can only start from genesis state"
      quit 1

    if res.data.validators.len != validators:
      echo &"Supplied genesis file has {res.data.validators.len} validators, while {validators} where requested, running anyway"

    echo &"Loaded {genesisFn}..."

    # TODO check that the private keys are interop keys

    let contractSnapshot = SSZ.loadFile(contractSnapshotFn,
                                        DepositContractSnapshot)
    (res, contractSnapshot)
  else:
    echo "Genesis file not found, making one up (use nimbus_beacon_node createTestnet to make one)"

    echo "Preparing validators..."
    let
      flags = if validate: {} else: {skipBlsValidation}
      deposits = makeInitialDeposits(validators.uint64, flags)

    echo "Generating Genesis..."
    var merkleizer = init DepositsMerkleizer
    for d in deposits:
      merkleizer.addChunk hash_tree_root(d).data
    let contractSnapshot = DepositContractSnapshot(
      depositContractState: merkleizer.toDepositContractState)

    res.data = initialize_beacon_state_from_eth1(
      defaultRuntimePreset,
      Eth2Digest(),
      0,
      deposits,
      flags)[]

    res.root = hash_tree_root(res.data)

    echo &"Saving to {genesisFn}..."
    SSZ.saveFile(genesisFn, res.data)
    echo &"Saving to {contractSnapshotFn}..."
    SSZ.saveFile(contractSnapshotFn, contractSnapshot)

    (res, contractSnapshot)

proc printTimers*[Timers: enum](
  validate: bool,
  timers: array[Timers, RunningStat]
) =
  proc fmtTime(t: float): string = &"{t * 1000 :>12.3f}, "

  echo "All time are ms"
  echo &"{\"Average\" :>12}, {\"StdDev\" :>12}, {\"Min\" :>12}, " &
    &"{\"Max\" :>12}, {\"Samples\" :>12}, {\"Test\" :>12}"

  if not validate:
    echo "Validation is turned off meaning that no BLS operations are performed"

  for t in Timers:
    echo fmtTime(timers[t].mean), fmtTime(timers[t].standardDeviationS),
      fmtTime(timers[t].min), fmtTime(timers[t].max), &"{timers[t].n :>12}, ",
      $t

proc printTimers*[Timers: enum](
    state: BeaconState, attesters: RunningStat, validate: bool,
    timers: array[Timers, RunningStat]) =
  echo "Validators: ", state.validators.len, ", epoch length: ", SLOTS_PER_EPOCH
  echo "Validators per attestation (mean): ", attesters.mean
  printTimers(validate, timers)

proc printTimers*[Timers: enum](
    state: ForkedHashedBeaconState, attesters: RunningStat, validate: bool,
    timers: array[Timers, RunningStat]) =
  echo "Validators: ", getStateField(state, validators).len, ", epoch length: ", SLOTS_PER_EPOCH
  echo "Validators per attestation (mean): ", attesters.mean
  printTimers(validate, timers)
