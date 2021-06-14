# beacon_chain
# Copyright (c) 2018-2021 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [Defect].}

import
  stew/endians2, stint, ssz_serialization,
  ./extras,
  spec/[crypto, datatypes, digest, keystore, signatures]

func get_eth1data_stub*(deposit_count: uint64, current_epoch: Epoch): Eth1Data =
  # https://github.com/ethereum/eth2.0-pm/blob/e596c70a19e22c7def4fd3519e20ae4022349390/interop/mocked_eth1data/README.md
  let
    voting_period = current_epoch.uint64 div EPOCHS_PER_ETH1_VOTING_PERIOD

  Eth1Data(
    deposit_root: hash_tree_root(voting_period),
    deposit_count: deposit_count,
    block_hash: hash_tree_root(hash_tree_root(voting_period).data),
  )

func makeInteropPrivKey*(i: int): ValidatorPrivKey =
  var bytes: array[32, byte]
  bytes[0..7] = uint64(i).toBytesLE()

  let
    # BLS381-12 curve order - same as milagro but formatted different
    curveOrder =
      "52435875175126190479447740508185965837690552500527637822603658699938581184513".parse(UInt256)

    privkeyBytes = eth2digest(bytes)
    key = (UInt256.fromBytesLE(privkeyBytes.data) mod curveOrder).toBytesBE()

  ValidatorPrivKey.fromRaw(key).get

const eth1BlockHash* = block:
  var x: Eth2Digest
  for v in x.data.mitems: v = 0x42
  x

func makeDeposit*(
    preset: RuntimePreset,
    pubkey: ValidatorPubKey, privkey: ValidatorPrivKey, epoch = 0.Epoch,
    amount: Gwei = MAX_EFFECTIVE_BALANCE.Gwei,
    flags: UpdateFlags = {}): DepositData =
  result = DepositData(
    amount: amount,
    pubkey: pubkey,
    withdrawal_credentials: makeWithdrawalCredentials(pubkey))

  if skipBLSValidation notin flags:
    result.signature = preset.get_deposit_signature(result, privkey).toValidatorSig()

