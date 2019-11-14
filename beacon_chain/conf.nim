import
  os, options, strformat,
  confutils/defs, chronicles/options as chroniclesOptions,
  spec/[crypto]

export
  defs, enabledLogLevel

const
  DEFAULT_NETWORK* {.strdefine.} = "testnet0"

type
  ValidatorKeyPath* = TypedInputFile[ValidatorPrivKey, Txt, "privkey"]

  StartUpCmd* = enum
    noCommand
    importValidator
    createTestnet
    makeDeposits
    query

  QueryCmd* = enum
    nimQuery
    get

  Eth1Network* = enum
    custom
    mainnet
    rinkeby
    goerli

  BeaconNodeConf* = object
    logLevel* {.
      defaultValue: LogLevel.DEBUG
      desc: "Sets the log level."
      name: "log-level" }: LogLevel

    eth1Network* {.
      defaultValue: goerli
      desc: "The Eth1 network tracked by the beacon node."
      name: "eth1-network" }: Eth1Network

    quickStart* {.
      defaultValue: false
      desc: "Run in quickstart mode"
      name: "quick-start" }: bool

    dataDir* {.
      defaultValue: config.defaultDataDir()
      desc: "The directory where nimbus will store all blockchain data."
      abbr: "d"
      name: "data-dir" }: OutDir

    depositWeb3Url* {.
      defaultValue: ""
      desc: "URL of the Web3 server to observe Eth1."
      name: "web3-url" }: string

    depositContractAddress* {.
      defaultValue: ""
      desc: "Address of the deposit contract."
      name: "deposit-contract" }: string

    statusBarEnabled* {.
      defaultValue: true
      desc: "Display a status bar at the bottom of the terminal screen."
      name: "status-bar" }: bool

    statusBarContents* {.
      defaultValue: "peers: $connected_peers; " &
                    "epoch: $epoch, slot: $epoch_slot/$slots_per_epoch ($slot); " &
                    "finalized epoch: $last_finalized_epoch |" &
                    "ETH: $attached_validators_balance"
      desc: "Textual template for the contents of the status bar."
      name: "status-bar-contents" }: string

    case cmd* {.
      command
      defaultValue: noCommand }: StartUpCmd

    of noCommand:
      bootstrapNodes* {.
        desc: "Specifies one or more bootstrap nodes to use when connecting to the network."
        abbr: "b"
        name: "bootstrap-node" }: seq[string]

      bootstrapNodesFile* {.
        defaultValue: ""
        desc: "Specifies a line-delimited file of bootsrap Ethereum network addresses."
        name: "bootstrap-file" }: InputFile

      tcpPort* {.
        defaultValue: defaultPort(config)
        desc: "TCP listening port."
        name: "tcp-port" }: int

      udpPort* {.
        defaultValue: defaultPort(config)
        desc: "UDP listening port."
        name: "udp-port" }: int

      nat* {.
        desc: "Specify method to use for determining public address. " &
              "Must be one of: any, none, upnp, pmp, extip:<IP>."
        defaultValue: "any" }: string

      validators* {.
        required
        desc: "Path to a validator private key, as generated by makeDeposits."
        abbr: "v"
        name: "validator" }: seq[ValidatorKeyPath]

      stateSnapshot* {.
        desc: "Json file specifying a recent state snapshot."
        abbr: "s"
        name: "state-snapshot" }: Option[InputFile]

      nodeName* {.
        defaultValue: ""
        desc: "A name for this node that will appear in the logs. " &
              "If you set this to 'auto', a persistent automatically generated ID will be seleceted for each --dataDir folder."
        name: "node-name" }: string

      metricsServer* {.
        defaultValue: false
        desc: "Enable the metrics server."
        name: "metrics-server" }: bool

      metricsServerAddress* {.
        defaultValue: "0.0.0.0"
        desc: "Listening address of the metrics server."
        name: "metrics-server-address" }: string # TODO: use a validated type here

      metricsServerPort* {.
        defaultValue: 8008
        desc: "Listening HTTP port of the metrics server."
        name: "metrics-server-port" }: uint16

    of createTestnet:
      validatorsDir* {.
        desc: "Directory containing validator descriptors named 'vXXXXXXX.deposit.json'."
        abbr: "d"
        name: "validators-dir" }: InputDir

      totalValidators* {.
        desc: "The number of validators in the newly created chain."
        name: "total-validators" }: uint64

      firstValidator* {.
        defaultValue: 0
        desc: "Index of first validator to add to validator list."
        name: "first-validator" }: uint64

      lastUserValidator* {.
        defaultValue: config.totalValidators - 1,
        desc: "The last validator index that will free for taking from a testnet participant."
        name: "last-user-validator" }: uint64

      bootstrapAddress* {.
        defaultValue: "127.0.0.1"
        desc: "The public IP address that will be advertised as a bootstrap node for the testnet."
        name: "bootstrap-address" }: string

      bootstrapPort* {.
        defaultValue: defaultPort(config)
        desc: "The TCP/UDP port that will be used by the bootstrap node."
        name: "bootstrap-port" }: int

      genesisOffset* {.
        defaultValue: 5
        desc: "Seconds from now to add to genesis time."
        abbr: "g"
        name: "genesis-offset" }: int

      outputGenesis* {.
        desc: "Output file where to write the initial state snapshot."
        name: "output-genesis" }: OutFile

      withGenesisRoot* {.
        defaultValue: false
        desc: "Include a genesis root in 'network.json'."
        name: "with-genesis-root" }: bool

      outputBootstrapFile* {.
        desc: "Output file with list of bootstrap nodes for the network."
        name: "output-bootstrap-file" }: OutFile

    of importValidator:
      keyFiles* {.
        desc: "File with validator key to be imported (in hex form)."
        name: "keyfile" }: seq[ValidatorKeyPath]

    of makeDeposits:
      totalQuickstartDeposits* {.
        defaultValue: 0
        desc: "Number of quick-start deposits to generate."
        name: "quickstart-deposits" }: int

      totalRandomDeposits* {.
        defaultValue: 0
        desc: "Number of secure random deposits to generate."
        name: "random-deposits" }: int

      depositsDir* {.
        defaultValue: "validators"
        desc: "Folder to write deposits to."
        name: "deposits-dir" }: string

      depositPrivateKey* {.
        defaultValue: ""
        desc: "Private key of the controlling (sending) account",
        name: "deposit-private-key" }: string

    of query:
      case queryCmd* {.
        defaultValue: nimQuery
        command
        desc: "Query the beacon node database and print the result" }: QueryCmd

      of nimQuery:
        nimQueryExpression* {.
          argument
          desc: "Nim expression to evaluate (using limited syntax)" }: string

      of get:
        getQueryPath* {.
          argument
          desc: "REST API path to evaluate" }: string

proc defaultPort*(config: BeaconNodeConf): int =
  9000

proc defaultDataDir*(conf: BeaconNodeConf): string =
  let dataDir = when defined(windows):
    "AppData" / "Roaming" / "Nimbus"
  elif defined(macosx):
    "Library" / "Application Support" / "Nimbus"
  else:
    ".cache" / "nimbus"

  getHomeDir() / dataDir / "BeaconNode"

proc validatorFileBaseName*(validatorIdx: int): string =
  # there can apparently be tops 4M validators so we use 7 digits..
  fmt"v{validatorIdx:07}"
