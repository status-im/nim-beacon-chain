# beacon_chain
# Copyright (c) 2018-2021 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [Defect].}

import
  os, sequtils, strutils, options, json, terminal,
  chronos, chronicles, confutils, stint, json_serialization, ssz_serialization,
  ../filepath,
  ../networking/network_metadata,
  web3, web3/confutils_defs, eth/keys, eth/p2p/discoveryv5/random2,
  stew/io2,
  ../spec/[datatypes, crypto, presets], ../ssz/spec_types,
  ../validators/keystore_management

# Compiled version of /scripts/depositContract.v.py in this repo
# The contract was compiled in Remix (https://remix.ethereum.org/) with vyper (remote) compiler.
const contractCode = staticRead "deposit_contract_code.txt"

type
  Eth1Address = web3.Address

  StartUpCommand {.pure.} = enum
    deploy
    drain
    sendEth
    generateSimulationDeposits
    sendDeposits

  CliConfig = object
    web3Url* {.
      defaultValue: "",
      desc: "URL of the Web3 server to observe Eth1"
      name: "web3-url" }: string

    privateKey* {.
      defaultValue: ""
      desc: "Private key of the controlling account"
      name: "private-key" }: string

    askForKey {.
      defaultValue: false
      desc: "Ask for an Eth1 private key interactively"
      name: "ask-for-key" }: bool

    eth2Network* {.
      desc: "The Eth2 network preset to use"
      name: "network" }: Option[string]

    case cmd* {.command.}: StartUpCommand
    of deploy:
      discard

    of drain:
      drainedContractAddress* {.
        desc: "Address of the contract to drain"
        name: "deposit-contract" }: Eth1Address

    of sendEth:
      toAddress {.name: "to".}: Eth1Address
      valueEth {.name: "eth".}: string

    of generateSimulationDeposits:
      simulationDepositsCount {.
        desc: "The number of validator keystores to generate"
        name: "count" }: Natural

      outValidatorsDir {.
        desc: "A directory to store the generated validator keystores"
        name: "out-validators-dir" }: OutDir

      outSecretsDir {.
        desc: "A directory to store the generated keystore password files"
        name: "out-secrets-dir" }: OutDir

      outDepositsFile {.
        desc: "A LaunchPad deposits file to write"
        name: "out-deposits-file" }: OutFile

    of sendDeposits:
      depositsFile {.
        desc: "A LaunchPad deposits file"
        name: "deposits-file" }: InputFile

      depositContractAddress {.
        desc: "Address of the deposit contract"
        name: "deposit-contract" }: Eth1Address

      minDelay {.
        defaultValue: 0.0
        desc: "Minimum possible delay between making two deposits (in seconds)"
        name: "min-delay" }: float

      maxDelay {.
        defaultValue: 0.0
        desc: "Maximum possible delay between making two deposits (in seconds)"
        name: "max-delay" }: float

contract(DepositContract):
  proc deposit(pubkey: Bytes48,
               withdrawalCredentials: Bytes32,
               signature: Bytes96,
               deposit_data_root: FixedBytes[32])

  proc drain()

proc deployContract*(web3: Web3, code: string): Future[ReceiptObject] {.async.} =
  var code = code
  if code[1] notin {'x', 'X'}:
    code = "0x" & code
  let tr = EthSend(
    source: web3.defaultAccount,
    data: code,
    gas: Quantity(3000000).some,
    gasPrice: 1.some)

  let r = await web3.send(tr)
  result = await web3.getMinedTransactionReceipt(r)

proc sendEth(web3: Web3, to: Eth1Address, valueEth: int): Future[TxHash] =
  let tr = EthSend(
    source: web3.defaultAccount,
    gas: Quantity(3000000).some,
    gasPrice: 1.some,
    value: some(valueEth.u256 * 1000000000000000000.u256),
    to: some(to))
  web3.send(tr)

type
  DelayGenerator* = proc(): chronos.Duration {.gcsafe, raises: [Defect].}

proc ethToWei(eth: UInt256): UInt256 =
  eth * 1000000000000000000.u256

proc initWeb3(web3Url, privateKey: string): Future[Web3] {.async.} =
  result = await newWeb3(web3Url)
  if privateKey.len != 0:
    result.privateKey = some(PrivateKey.fromHex(privateKey)[])
  else:
    let accounts = await result.provider.eth_accounts()
    doAssert(accounts.len > 0)
    result.defaultAccount = accounts[0]

# TODO: async functions should note take `seq` inputs because
#       this leads to full copies.
proc sendDeposits*(deposits: seq[LaunchPadDeposit],
                   web3Url, privateKey: string,
                   depositContractAddress: Eth1Address,
                   delayGenerator: DelayGenerator = nil) {.async.} =
  notice "Sending deposits",
    web3 = web3Url,
    depositContract = depositContractAddress

  var web3 = await initWeb3(web3Url, privateKey)
  let depositContract = web3.contractSender(DepositContract,
                                            Address depositContractAddress)
  for i, launchPadDeposit in deposits:
    let dp = launchPadDeposit as DepositData

    while true:
      try:
        let tx = depositContract.deposit(
          Bytes48(dp.pubKey.toRaw()),
          Bytes32(dp.withdrawal_credentials.data),
          Bytes96(dp.signature.toRaw()),
          FixedBytes[32](hash_tree_root(dp).data))

        let status = await tx.send(value = 32.u256.ethToWei, gasPrice = 1)

        info "Deposit sent", status = $status

        if delayGenerator != nil:
          await sleepAsync(delayGenerator())

        break
      except CatchableError:
        await sleepAsync(60.seconds)
        web3 = await initWeb3(web3Url, privateKey)

{.pop.} # TODO confutils.nim(775, 17) Error: can raise an unlisted exception: ref IOError
proc main() {.async.} =
  var cfg = CliConfig.load()
  let rng = keys.newRng()

  if cfg.cmd == StartUpCommand.generateSimulationDeposits:
    let
      mnemonic = generateMnemonic(rng[])
      seed = getSeed(mnemonic, KeyStorePass.init "")
      runtimePreset = getRuntimePresetForNetwork(cfg.eth2Network)

    let vres = secureCreatePath(string cfg.outValidatorsDir)
    if vres.isErr():
      warn "Could not create validators folder",
           path = string cfg.outValidatorsDir, err = ioErrorMsg(vres.error)

    let sres = secureCreatePath(string cfg.outSecretsDir)
    if sres.isErr():
      warn "Could not create secrets folder",
           path = string cfg.outSecretsDir, err = ioErrorMsg(sres.error)

    let deposits = generateDeposits(
      runtimePreset,
      rng[],
      seed,
      0, cfg.simulationDepositsCount,
      string cfg.outValidatorsDir,
      string cfg.outSecretsDir)

    if deposits.isErr:
      fatal "Failed to generate deposits", err = deposits.error
      quit 1

    let launchPadDeposits =
      mapIt(deposits.value, LaunchPadDeposit.init(runtimePreset, it))

    Json.saveFile(string cfg.outDepositsFile, launchPadDeposits)
    notice "Deposit data written", filename = cfg.outDepositsFile
    quit 0

  var deposits: seq[LaunchPadDeposit]
  if cfg.cmd == StartUpCommand.sendDeposits:
    deposits = Json.loadFile(string cfg.depositsFile, seq[LaunchPadDeposit])

  if cfg.askForKey:
    var
      privateKey: TaintedString
      reasonForKey = ""

    if cfg.cmd == StartUpCommand.sendDeposits:
      let
        depositsWord = if deposits.len > 1: "deposits" else: "deposit"
        totalEthNeeded = 32 * deposits.len
      reasonForKey = " in order to make your $1 (you'll need access to $2 ETH)" %
                     [depositsWord, $totalEthNeeded]

    echo "Please enter your Goerli Eth1 private key in hex form (e.g. 0x1a2...f3c)" &
          reasonForKey

    if not readPasswordFromStdin("> ", privateKey):
      error "Failed to read an Eth1 private key from standard input"

    if privateKey.len > 0:
      cfg.privateKey = privateKey.string

  let web3 = await initWeb3(cfg.web3Url, cfg.privateKey)

  case cfg.cmd
  of StartUpCommand.deploy:
    let receipt = await web3.deployContract(contractCode)
    echo receipt.contractAddress.get, ";", receipt.blockHash

  of StartUpCommand.drain:
    let sender = web3.contractSender(DepositContract,
                                     cfg.drainedContractAddress)
    discard await sender.drain().send(gasPrice = 1)

  of StartUpCommand.sendEth:
    echo await sendEth(web3, cfg.toAddress, cfg.valueEth.parseInt)

  of StartUpCommand.sendDeposits:
    var delayGenerator: DelayGenerator
    if not (cfg.maxDelay > 0.0):
      cfg.maxDelay = cfg.minDelay
    elif cfg.minDelay > cfg.maxDelay:
      echo "The minimum delay should not be larger than the maximum delay"
      quit 1

    if cfg.maxDelay > 0.0:
      delayGenerator = proc (): chronos.Duration =
        let
          minDelay = (cfg.minDelay*1000).int64
          maxDelay = (cfg.maxDelay*1000).int64
        chronos.milliseconds (rng[].rand(maxDelay - minDelay) + minDelay)

    await sendDeposits(deposits, cfg.web3Url, cfg.privateKey,
                       cfg.depositContractAddress, delayGenerator)

  of StartUpCommand.generateSimulationDeposits:
    # This is handled above before the case statement
    discard

when isMainModule: waitFor main()
