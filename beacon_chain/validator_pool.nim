import
  tables,
  chronos, chronicles,
  spec/[datatypes, crypto, digest, helpers], ssz,
  beacon_node_types


proc init*(T: type ValidatorPool): T =
  result.validators = initTable[ValidatorPubKey, AttachedValidator]()

template count*(pool: ValidatorPool): int =
  pool.validators.len

proc addLocalValidator*(pool: var ValidatorPool,
                        pubKey: ValidatorPubKey,
                        privKey: ValidatorPrivKey) =
  let v = AttachedValidator(pubKey: pubKey,
                            kind: inProcess,
                            privKey: privKey)
  pool.validators[pubKey] = v

  info "Local validator attached", pubKey, validator = shortLog(v)

proc getValidator*(pool: ValidatorPool,
                   validatorKey: ValidatorPubKey): AttachedValidator =
  pool.validators.getOrDefault(validatorKey)

proc signBlockProposal*(v: AttachedValidator, state: BeaconState, slot: Slot,
                        blockRoot: Eth2Digest): Future[ValidatorSig] {.async.} =
  if v.kind == inProcess:
    await sleepAsync(chronos.milliseconds(1))
    result = bls_sign(v.privKey, blockRoot.data,
      get_domain(state, DOMAIN_BEACON_PROPOSER, compute_epoch_of_slot(slot)))
  else:
    # TODO:
    # send RPC
    discard

proc signAttestation*(v: AttachedValidator,
                      attestation: AttestationData): Future[ValidatorSig] {.async.} =
  # TODO: implement this
  if v.kind == inProcess:
    await sleepAsync(chronos.milliseconds(1))

    let attestationRoot = hash_tree_root(attestation)
    # TODO: Avoid the allocations belows
    var dataToSign = @(attestationRoot.data) & @[0'u8]
    # TODO: Use `domain` here
    let domain = 0'u64
    result = bls_sign(v.privKey, dataToSign, domain)
  else:
    # TODO:
    # send RPC
    discard

func genRandaoReveal*(k: ValidatorPrivKey, state: BeaconState, slot: Slot):
    ValidatorSig =
  # Off-by-one? I often get slot == state.slot but the check was "doAssert slot > state.slot" (Mamy)
  doAssert slot >= state.slot, "input slot: " & $shortLog(slot) & " - beacon state slot: " & $shortLog(state.slot)
  bls_sign(k, hash_tree_root(compute_epoch_of_slot(slot).uint64).data,
    get_domain(state, DOMAIN_RANDAO, compute_epoch_of_slot(slot)))

func genRandaoReveal*(v: AttachedValidator, state: BeaconState, slot: Slot):
    ValidatorSig =
  genRandaoReveal(v.privKey, state, slot)
