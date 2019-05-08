import
  os, ospaths, strutils, strformat,
  chronos, blscurve, nimcrypto, json_serialization, confutils,
  spec/[datatypes, digest, crypto], conf, time, ssz,
  ../tests/testutil

proc writeTextFile(filename: string, contents: string) =
  writeFile(filename, contents)
  echo "Wrote ", filename

proc writeFile(filename: string, value: auto) =
  Json.saveFile(filename, value, pretty = true)
  echo "Wrote ", filename

cli do (totalValidators: int = 125000,
        outputDir: string = "validators",
        generateFakeKeys = false):

  for i in 0 ..< totalValidators:
    let
      v = validatorFileBaseName(i)
      depositFn = outputDir / v & ".deposit.json"
      privKeyFn = outputDir / v & ".privkey"

    if existsFile(depositFn) and existsFile(privKeyFn):
      continue

    let
      privKey = if generateFakeKeys: makeFakeValidatorPrivKey(i)
                else: ValidatorPrivKey.random
      pubKey = privKey.pubKey()

    let
      withdrawalCredentials = makeFakeHash(i)

      proofOfPossessionData = DepositInput(
        pubkey: pubKey,
        withdrawal_credentials: withdrawalCredentials)

      proofOfPossession = bls_sign(
        privkey, hash_tree_root(proofOfPossessionData).data,
        0 # TODO - domain
        )

    let
      deposit = Deposit(
        data: DepositData(
          amount: MAX_EFFECTIVE_BALANCE,
          timestamp: 0, # TODO https://github.com/ethereum/eth2.0-specs/pull/834
          deposit_input: DepositInput(
            pubkey: pubKey,
            proof_of_possession: proofOfPossession,
            withdrawal_credentials: withdrawalCredentials)))

    writeTextFile(privKeyFn, $privKey)
    writeFile(depositFn, deposit)

  if generateFakeKeys:
    echo "Keys generated by this tool are only for testing!"
