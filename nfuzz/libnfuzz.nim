# Required for deserialisation of ValidatorSig in Attestation due to
# https://github.com/nim-lang/Nim/issues/11225

import
  stew/ptrops, stew/ranges/ptr_arith, chronicles, ssz_serialization,
  ../beacon_chain/extras,
  ../beacon_chain/spec/[
    beaconstate, crypto, datatypes, digest, forkedbeaconstate_helpers, presets,
      validator, state_transition, state_transition_block],
  ../beacon_chain/ssz/spec_types

type
  AttestationInput = object
    state: BeaconState
    attestation: Attestation
  AttesterSlashingInput = object
    state: BeaconState
    attesterSlashing: AttesterSlashing
  BlockInput = object
    state: BeaconState
    beaconBlock: SignedBeaconBlock
  BlockHeaderInput = BlockInput
  DepositInput = object
    state: BeaconState
    deposit: Deposit
  ProposerSlashingInput = object
    state: BeaconState
    proposerSlashing: ProposerSlashing
  VoluntaryExitInput = object
    state: BeaconState
    exit: SignedVoluntaryExit
  # This and AssertionError are raised to indicate programming bugs
  # A wrapper to allow exception tracking to identify unexpected exceptions
  FuzzCrashError = object of CatchableError

# TODO: change ptr uint to ptr csize_t when available in newer Nim version.
proc copyState(state: BeaconState, xoutput: ptr byte,
    xoutput_size: ptr uint): bool {.raises: [FuzzCrashError, Defect].} =
  var resultState =
    try:
      SSZ.encode(state)
    except IOError as e:
      # Shouldn't occur as the writer isn't a file
      raise newException(FuzzCrashError, "Unexpected failure to serialize.", e)

  if unlikely(resultState.len.uint > xoutput_size[]):
    let msg = (
      "Not enough xoutput buffer provided to nimbus harness. Provided: " &
      $(xoutput_size[]) &
      "Required: " &
      $resultState.len.uint
    )
    raise newException(FuzzCrashError, msg)
  xoutput_size[] = resultState.len.uint
  # TODO: improvement might be to write directly to buffer with xoutputStream
  # and SszWriter (but then need to ensure length doesn't overflow)
  copyMem(xoutput, unsafeAddr resultState[0], xoutput_size[])
  result = true

template decodeAndProcess(typ, process: untyped): bool =
  let flags {.inject.} = if disable_bls: {skipBlsValidation} else: {}

  var
    cache {.used, inject.} = StateCache()
    data {.inject.} = newClone(
      try:
        SSZ.decode(input, typ)
      except MalformedSszError as e:
        raise newException(
          FuzzCrashError,
          "Malformed SSZ, likely bug in preprocessing.", e)
      except SszSizeMismatchError as e:
        raise newException(
          FuzzCrashError,
          "SSZ size mismatch, likely bug in preprocessing.", e)
    )
  let processOk =
    try:
      process
    except IOError as e:
      raise newException(
        FuzzCrashError, "Unexpected  (logging?) IOError in state transition", e,
      )
    except ValueError as e:
      raise newException(
        FuzzCrashError,
        "Unexpected  (logging?) IOError in state transition", e)
    except Exception as e:
      # TODO why an Exception?
      # Lots of vendor code looks like it might raise a bare exception type
      raise newException(FuzzCrashError, "Unexpected Exception in state transition", e)

  if processOk:
    copyState(data.state, xoutput, xoutput_size)
  else:
    false

proc nfuzz_attestation(input: openArray[byte], xoutput: ptr byte,
    xoutput_size: ptr uint, disable_bls: bool): bool {.exportc, raises: [FuzzCrashError, Defect].} =
  decodeAndProcess(AttestationInput):
    process_attestation(data.state, data.attestation, flags, cache).isOk

proc nfuzz_attester_slashing(input: openArray[byte], xoutput: ptr byte,
    xoutput_size: ptr uint, disable_bls: bool): bool {.exportc, raises: [FuzzCrashError, Defect].} =
  decodeAndProcess(AttesterSlashingInput):
    process_attester_slashing(data.state, data.attesterSlashing, flags, cache).isOk

proc nfuzz_block(input: openArray[byte], xoutput: ptr byte,
    xoutput_size: ptr uint, disable_bls: bool): bool {.exportc, raises: [FuzzCrashError, Defect].} =
  # There's not a perfect approach here, but it's not worth switching the rest
  # and requiring HashedBeaconState (yet). So to keep consistent, puts wrapper
  # only in one function.
  proc state_transition(
      preset: RuntimePreset, data: auto, blck: auto, flags: auto,
      rollback: RollbackForkedHashedProc): auto =
    var
      fhState = (ref ForkedHashedBeaconState)(
        hbsPhase0: HashedBeaconState(
          data: data.state, root: hash_tree_root(data.state)),
        beaconStateFork: forkPhase0)
      cache = StateCache()
      rewards = RewardInfo()
    result =
      state_transition(
        preset, fhState[], blck, cache, rewards, flags, rollback)
    data.state = fhState.hbsPhase0.data

  decodeAndProcess(BlockInput):
    state_transition(defaultRuntimePreset, data, data.beaconBlock, flags, noRollback)

proc nfuzz_block_header(input: openArray[byte], xoutput: ptr byte,
    xoutput_size: ptr uint, disable_bls: bool): bool {.exportc, raises: [FuzzCrashError, Defect].} =
  decodeAndProcess(BlockHeaderInput):
    process_block_header(data.state, data.beaconBlock.message, flags, cache).isOk

proc nfuzz_deposit(input: openArray[byte], xoutput: ptr byte,
    xoutput_size: ptr uint, disable_bls: bool): bool {.exportc, raises: [FuzzCrashError, Defect].} =
  decodeAndProcess(DepositInput):
    process_deposit(defaultRuntimePreset, data.state, data.deposit, flags).isOk

proc nfuzz_proposer_slashing(input: openArray[byte], xoutput: ptr byte,
    xoutput_size: ptr uint, disable_bls: bool): bool {.exportc, raises: [FuzzCrashError, Defect].} =
  decodeAndProcess(ProposerSlashingInput):
    process_proposer_slashing(data.state, data.proposerSlashing, flags, cache).isOk

proc nfuzz_voluntary_exit(input: openArray[byte], xoutput: ptr byte,
    xoutput_size: ptr uint, disable_bls: bool): bool {.exportc, raises: [FuzzCrashError, Defect].} =
  decodeAndProcess(VoluntaryExitInput):
    process_voluntary_exit(data.state, data.exit, flags, cache).isOk

# Note: Could also accept raw input pointer and access list_size + seed here.
# However, list_size needs to be known also outside this proc to allocate xoutput.
# TODO: rework to copy immediatly in an uint8 openArray, considering we have to
# go over the list anyhow?
proc nfuzz_shuffle(input_seed: ptr byte, xoutput: var openArray[uint64]): bool
    {.exportc, raises: [Defect].} =
  var seed: Eth2Digest
  # Should be OK as max 2 bytes are passed by the framework.
  let list_size = xoutput.len

  copyMem(addr(seed.data), input_seed, sizeof(seed.data))

  var shuffled_seq: seq[ValidatorIndex]
  for i in 0..<list_size:
    shuffled_seq.add i.ValidatorIndex
  shuffle_list(shuffled_seq, seed)

  for i in 0..<list_size:
    # ValidatorIndex is currently wrongly uint32 so we copy this 1 by 1,
    # assumes passed xoutput is zeroed.
    copyMem(offset(addr xoutput, i), shuffled_seq[i].unsafeAddr,
      sizeof(ValidatorIndex))

  true
