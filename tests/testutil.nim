# beacon_chain
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at http://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at http://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  options, milagro_crypto,
  ../beacon_chain/[extras, ssz, state_transition],
  ../beacon_chain/spec/[crypto, datatypes, digest, helpers]

const
  randaoRounds = 100

func makeValidatorPrivKey(i: int): ValidatorPrivKey =
  var i = i + 1 # 0 does not work, as private key...
  copyMem(result.x[0].addr, i.addr, min(sizeof(result.x), sizeof(i)))

func makeFakeHash(i: int): Eth2Digest =
  copyMem(result.data[0].addr, i.unsafeAddr, min(sizeof(result.data), sizeof(i)))

func hackPrivKey(v: ValidatorRecord): ValidatorPrivKey =
  ## Extract private key, per above hack
  var i: int
  copyMem(
    i.addr, v.withdrawal_credentials.data[0].unsafeAddr,
    min(sizeof(v.withdrawal_credentials.data), sizeof(i)))
  makeValidatorPrivKey(i)

func hackReveal(v: ValidatorRecord): Eth2Digest =
  result = v.withdrawal_credentials
  for i in 0..randaoRounds:
    let tmp = repeat_hash(result, 1)
    if tmp == v.randao_commitment:
      return
    result = tmp
  raise newException(Exception, "can't find randao hack value")

func makeDeposit(i: int): Deposit =
  ## Ugly hack for now: we stick the private key in withdrawal_credentials
  ## which means we can repro private key and randao reveal from this data,
  ## for testing :)
  let
    privkey = makeValidatorPrivKey(i)
    pubkey = privkey.fromSigKey()
    withdrawal_credentials = makeFakeHash(i)
    randao_commitment = repeat_hash(withdrawal_credentials, randaoRounds)
    pop = signMessage(privkey, hash_tree_root(
      (pubkey, withdrawal_credentials, randao_commitment)))

  Deposit(
    deposit_data: DepositData(
      deposit_parameters: DepositParameters(
        pubkey: pubkey,
        proof_of_possession: pop,
        withdrawal_credentials: withdrawal_credentials,
        randao_commitment: randao_commitment
      ),
      value: MAX_DEPOSIT * GWEI_PER_ETH,
    )
  )

func makeInitialDeposits*(n = EPOCH_LENGTH): seq[Deposit] =
  for i in 0..<n.int:
    result.add makeDeposit(i + 1)

func makeGenesisBlock*(state: BeaconState): BeaconBlock =
  BeaconBlock(
    slot: INITIAL_SLOT_NUMBER,
    state_root: Eth2Digest(data: hash_tree_root(state))
  )

func getNextBeaconProposerIndex*(state: BeaconState): Uint24 =
  # TODO: this works but looks wrong - we update the slot in the state without
  #       updating corresponding data - this works because the state update
  #       code does the same - updates slot, then uses that slot when calling
  #       beacon_proposer_index, then finally updates the shuffling at the end!
  var next_state = state
  next_state.slot += 1
  get_beacon_proposer_index(next_state, next_state.slot)

proc makeBlock*(state: BeaconState, previous_block: BeaconBlock): BeaconBlock =
  # Create a block for `state.slot + 1` - like a block proposer would do!
  # It's a bit awkward - in order to produce a block for N+1, we need to
  # calculate what the state will look like after that block has been applied,
  # because the block includes the state root.

  let
    # Index from the new state, but registry from the old state.. hmm...
    proposer = state.validator_registry[getNextBeaconProposerIndex(state)]

  var
    # In order to reuse the state transition function, we first create a dummy
    # block that has some fields set, and use that to generate the state as it
    # would look with the new block applied.
    new_block = BeaconBlock(
      slot: state.slot + 1,

      # TODO is this checked anywhere?
      #      https://github.com/ethereum/eth2.0-specs/issues/336
      parent_root: Eth2Digest(data: hash_tree_root(previous_block)),
      state_root: Eth2Digest(), # we need the new state first
      randao_reveal: hackReveal(proposer),
      candidate_pow_receipt_root: Eth2Digest(), # TODO
      signature: ValidatorSig(), # we need the rest of the block first!
      body: BeaconBlockBody() # TODO throw in stuff here...
    )

  let
    next_state = updateState(state, previous_block, some(new_block), true)
  assert next_state.block_ok

  # Ok, we have the new state as it would look with the block applied - now we
  # can set the state root in order to be able to create a valid signature
  new_block.state_root = Eth2Digest(data: hash_tree_root(next_state.state))

  let
    proposerPrivkey = hackPrivKey(proposer)

    # Once we've collected all the state data, we sign the block data along with
    # some book-keeping values
    signed_data = ProposalSignedData(
      slot: new_block.slot,
      shard: BEACON_CHAIN_SHARD_NUMBER,
      block_root: Eth2Digest(data: hash_tree_root(new_block))
    )
    proposal_hash = hash_tree_root(signed_data)

  assert proposerPrivkey.fromSigKey() == proposer.pubkey,
    "signature key should be derived from private key! - wrong privkey?"

  # We have a signature - put it in the block and we should be done!
  new_block.signature =
    # TODO domain missing!
    signMessage(proposerPrivkey, proposal_hash)

  assert bls_verify(
    proposer.pubkey,
    proposal_hash, new_block.signature,
    get_domain(state.fork_data, state.slot, DOMAIN_PROPOSAL)),
    "we just signed this message - it should pass verification!"

  new_block
