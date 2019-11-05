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

  StartUpCommand* = enum
    noCommand
    importValidator
    createTestnet
    makeDeposits

  Eth1Network* = enum
    custom
    mainnet
    rinkeby
    goerli

  BeaconNodeConf* = object
    logLevel* {.
      desc: "Sets the log level."
      defaultValue: enabledLogLevel
      longform: "log-level" }: LogLevel

    eth1Network* {.
      desc: "The Eth1 network tracked by the beacon node."
      defaultValue: goerli
      longform: "eth1-network" }: Eth1Network

    quickStart* {.
      desc: "Run in quickstart mode"
      defaultValue: false
      longform: "quick-start" }: bool

    dataDir* {.
      desc: "The directory where nimbus will store all blockchain data."
      defaultValue: config.defaultDataDir()
      shortform: "d"
      longform: "data-dir" }: OutDir

    depositWeb3Url* {.
      desc: "URL of the Web3 server to observe Eth1."
      defaultValue: ""
      longform: "web3-url" }: string

    depositContractAddress* {.
      desc: "Address of the deposit contract."
      defaultValue: ""
      longform: "deposit-contract" }: string

    statusBarEnabled* {.
      desc: "Display a status bar at the bottom of the terminal screen."
      defaultValue: true
      longform: "status-bar" }: bool

    statusBarContents* {.
      desc: ""
      defaultValue: "peers: $connected_peers; " &
                    "epoch: $epoch, slot: $epoch_slot/$slots_per_epoch ($slot); " &
                    "finalized epoch: $last_finalized_epoch |" &
                    "ETH: $attached_validators_balance"
      longform: "status-bar-contents" }: string

    case cmd* {.
      command
      defaultValue: noCommand }: StartUpCommand

    of noCommand:
      bootstrapNodes* {.
        desc: "Specifies one or more bootstrap nodes to use when connecting to the network."
        shortform: "b"
        longform: "bootstrap-node" }: seq[string]

      bootstrapNodesFile* {.
        desc: "Specifies a line-delimited file of bootsrap Ethereum network addresses."
        defaultValue: ""
        longform: "bootstrap-file" }: InputFile

      tcpPort* {.
        desc: "TCP listening port."
        defaultValue: defaultPort(config)
        longform: "tcp-port" }: int

      udpPort* {.
        desc: "UDP listening port."
        defaultValue: defaultPort(config)
        longform: "udp-port" }: int

      nat* {.
        desc: "Specify method to use for determining public address. " &
              "Must be one of: any, none, upnp, pmp, extip:<IP>."
        defaultValue: "any" }: string

      validators* {.
        required
        desc: "Path to a validator private key, as generated by makeDeposits."
        shortform: "v"
        longform: "validator" }: seq[ValidatorKeyPath]

      stateSnapshot* {.
        desc: "Json file specifying a recent state snapshot."
        shortform: "s"
        longform: "state-snapshot" }: Option[InputFile]

      nodeName* {.
        desc: "A name for this node that will appear in the logs. " &
              "If you set this to 'auto', a persistent automatically generated ID will be seleceted for each --dataDir folder."
        defaultValue: ""
        longform: "node-name" }: string

      metricsServer* {.
        desc: "Enable the metrics server."
        defaultValue: false
        longform: "metrics-server" }: bool

      metricsServerAddress* {.
        desc: "Listening address of the metrics server."
        defaultValue: "0.0.0.0"
        longform: "metrics-server-address" }: string # TODO: use a validated type here

      metricsServerPort* {.
        desc: "Listening HTTP port of the metrics server."
        defaultValue: 8008
        longform: "metrics-server-port" }: uint16

    of createTestnet:
      validatorsDir* {.
        desc: "Directory containing validator descriptors named 'vXXXXXXX.deposit.json'."
        shortform: "d"
        longform: "validators-dir" }: InputDir

      totalValidators* {.
        desc: "The number of validators in the newly created chain."
        longform: "total-validators" }: uint64

      firstValidator* {.
        desc: "Index of first validator to add to validator list."
        defaultValue: 0
        longform: "first-validator" }: uint64

      lastUserValidator* {.
        desc: "The last validator index that will free for taking from a testnet participant."
        defaultValue: config.totalValidators - 1,
        longform: "last-user-validator" }: uint64

      bootstrapAddress* {.
        desc: "The public IP address that will be advertised as a bootstrap node for the testnet."
        defaultValue: "127.0.0.1"
        longform: "bootstrap-address" }: string

      bootstrapPort* {.
        desc: "The TCP/UDP port that will be used by the bootstrap node."
        defaultValue: defaultPort(config)
        longform: "bootstrap-port" }: int

      genesisOffset* {.
        desc: "Seconds from now to add to genesis time."
        defaultValue: 5
        shortForm: "g"
        longform: "genesis-offset" }: int

      outputGenesis* {.
        desc: "Output file where to write the initial state snapshot."
        longform: "output-genesis" }: OutFile

      withGenesisRoot* {.
        desc: "Include a genesis root in 'network.json'."
        defaultValue: false
        longform: "with-genesis-root" }: bool

      outputBootstrapFile* {.
        desc: "Output file with list of bootstrap nodes for the network."
        longform: "output-bootstrap-file" }: OutFile

    of importValidator:
      keyFiles* {.
        desc: "File with validator key to be imported (in hex form)."
        longform: "keyfile" }: seq[ValidatorKeyPath]

    of makeDeposits:
      totalQuickstartDeposits* {.
        desc: "Number of quick-start deposits to generate."
        defaultValue: 0
        longform: "quickstart-deposits" }: int

      totalRandomDeposits* {.
        desc: "Number of secure random deposits to generate."
        defaultValue: 0
        longform: "random-deposits" }: int

      depositsDir* {.
        desc: "Folder to write deposits to."
        defaultValue: "validators"
        longform: "deposits-dir" }: string

      depositPrivateKey* {.
        desc: "Private key of the controlling (sending) account",
        defaultValue: ""
        longform: "deposit-private-key" }: string

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
