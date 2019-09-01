import
  os, ospaths, strutils, strformat,
  chronicles, chronos, blscurve, nimcrypto, json_serialization, web3, stint,
  spec/[datatypes, digest, crypto], conf, time, ssz, interop

contract(DepositContract):
  proc deposit(pubkey: Bytes48, withdrawalCredentials: Bytes32, signature: Bytes96)

proc writeTextFile(filename: string, contents: string) =
  writeFile(filename, contents)
  echo "Wrote ", filename

proc writeFile(filename: string, value: auto) =
  Json.saveFile(filename, value, pretty = true)
  echo "Wrote ", filename

proc ethToWei(eth: UInt256): UInt256 =
  eth * 1000000000000000000.u256

proc generateDeposits*(
    totalValidators: int, outputDir: string, randomKeys: bool): seq[Deposit] =
  info "Generating deposits", totalValidators, outputDir, randomKeys
  for i in 0 ..< totalValidators:
    let
      v = validatorFileBaseName(i)
      depositFn = outputDir / v & ".deposit.json"
      privKeyFn = outputDir / v & ".privkey"

    if existsFile(depositFn) and existsFile(privKeyFn):
      try:
        result.add Json.loadFile(depositFn, Deposit)
        continue
      except: # CatchableError?
        discard

    let
      privKey = if randomKeys: ValidatorPrivKey.random
                else: makeInteropPrivKey(i)
      pubKey = privKey.pubKey()

    let dp = makeDeposit(pubKey, privKey)

    writeTextFile(privKeyFn, $privKey)
    writeFile(depositFn, dp)

    result.add(dp)

proc sendDeposits*(
    deposits: seq[Deposit],
    depositWeb3Url, depositContractAddress: string) {.async.} =
  let
    web3 = await newWeb3(depositWeb3Url)
    contractAddress = Address.fromHex(depositContractAddress)
    eth1Addresses = await web3.provider.eth_accounts()

  for i, dp in deposits:
    web3.defaultAccount = eth1Addresses[i]
    let depositContract = web3.contractSender(DepositContract, contractAddress)
    let tx = await depositContract.deposit(
      Bytes48(dp.data.pubKey.getBytes()),
      Bytes32(dp.data.withdrawal_credentials.data),
      Bytes96(dp.data.signature.getBytes())).send(value = 32.u256.ethToWei)

when isMainModule:
  import confutils

  cli do (totalValidators: int = 125000,
          outputDir: string = "validators",
          randomKeys: bool = false,
          depositWeb3Url: string = "",
          depositContractAddress: string = ""):
    let deposits = generateDeposits(totalValidators, outputDir, randomKeys)

    if depositWeb3Url.len() > 0 and depositContractAddress.len() > 0:
      waitFor sendDeposits(deposits, depositWeb3Url, depositContractAddress)
