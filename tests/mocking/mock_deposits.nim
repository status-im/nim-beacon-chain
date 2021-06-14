# beacon_chain
# Copyright (c) 2018-2020 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

# Mocking deposits and genesis deposits
# ---------------------------------------------------------------

import
  # Standard library
  std/math,

  ssz_serialization,

  # Specs
  ../../beacon_chain/spec/[datatypes, crypto, digest,
                           keystore, signatures, presets],

  # Internals
  ../../beacon_chain/extras,
  ../../beacon_chain/eth1/merkle_minimal,

  # Mocking procs
  ./mock_validator_keys

func mockDepositData(
        pubkey: ValidatorPubKey,
        amount: uint64,
      ): DepositData =
  # Insecurely use pubkey as withdrawal key
  DepositData(
    pubkey: pubkey,
    withdrawal_credentials: makeWithdrawalCredentials(pubkey),
    amount: amount,
  )

func mockDepositData(
        pubkey: ValidatorPubKey,
        privkey: ValidatorPrivKey,
        amount: uint64,
        # withdrawal_credentials: Eth2Digest,
        flags: UpdateFlags = {}
      ): DepositData =
  var ret = mockDepositData(pubkey, amount)
  if skipBlsValidation notin flags:
    ret.signature = defaultRuntimePreset.get_deposit_signature(ret, privkey).toValidatorSig()
  ret

template mockGenesisDepositsImpl(
        result: seq[DepositData],
        validatorCount: uint64,
        amount: untyped,
        flags: UpdateFlags = {},
        updateAmount: untyped,
      ) =
  # Genesis deposits with varying amounts

  # NOTE: prefer to er on the side of caution and generate a valid Deposit
  # (it can still be skipped later).
  if skipBlsValidation in flags:
    # 1st loop - build deposit data
    for valIdx in 0 ..< validatorCount:
      # Directly build the Deposit in-place for speed
      result.setLen(valIdx + 1)

      updateAmount

      # DepositData
      result[valIdx] = mockDepositData(MockPubKeys[valIdx], amount)
  else: # With signing
    var depositsDataHash: seq[Eth2Digest]
    var depositsData: seq[DepositData]

    # 1st loop - build deposit data
    for valIdx in 0 ..< validatorCount:
      # Directly build the Deposit in-place for speed
      result.setLen(valIdx + 1)

      updateAmount

      # DepositData
      result[valIdx] = mockDepositData(
        MockPubKeys[valIdx], MockPrivKeys[valIdx], amount, flags)

      depositsData.add result[valIdx]
      depositsDataHash.add hash_tree_root(result[valIdx])

proc mockGenesisBalancedDeposits*(
        validatorCount: uint64,
        amountInEth: Positive,
        flags: UpdateFlags = {}
      ): seq[DepositData] =
  ## The amount should be strictly positive
  ## - 1 is the minimum deposit amount (MIN_DEPOSIT_AMOUNT)
  ## - 16 is the ejection balance (EJECTION_BALANCE)
  ## - 32 is the max effective balance (MAX_EFFECTIVE_BALANCE)
  ##   ETH beyond do not contribute more for staking.
  ##
  ## Only validators with 32 ETH will be active at genesis

  let amount = amountInEth.uint64 * 10'u64^9
  mockGenesisDepositsImpl(result, validatorCount,amount,flags):
    discard

proc mockUpdateStateForNewDeposit*(
       state: var BeaconState,
       validator_index: uint64,
       amount: uint64,
       # withdrawal_credentials: Eth2Digest
       flags: UpdateFlags
    ): Deposit =


  # TODO withdrawal credentials

  result.data = mockDepositData(
    MockPubKeys[validator_index],
    MockPrivKeys[validator_index],
    amount,
    # withdrawal_credentials: Eth2Digest
    flags
  )

  var result_seq = @[result]
  attachMerkleProofs(result_seq)
  result.proof = result_seq[0].proof

  # TODO: this logic from the eth2.0-specs test suite seems strange
  #       but confirmed by running it
  state.eth1_deposit_index = 0
  state.eth1_data.deposit_root =
     hash_tree_root(List[DepositData, 2'i64^DEPOSIT_CONTRACT_TREE_DEPTH](@[result.data]))
  state.eth1_data.deposit_count = 1
