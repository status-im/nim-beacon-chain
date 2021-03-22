# Command line options

You can pass any `nimbus_beacon_node` options to the `pyrmont` and `mainnet` scripts. For example, if you wanted to launch Nimbus on mainnet with different base ports than the default `9000/udp` and `9000/tcp`, say `9100/udp` and `9100/tcp`, you would run:

```
./run-mainnet-beacon-node.sh --tcp-port=9100 --udp-port=9100
```

To see a list of the command line options availabe to you, with descriptions, navigate to the `build` directory and run:

```
./nimbus_beacon_node --help
```

You should see the following output:

```
Usage: 

nimbus_beacon_node [OPTIONS]... command

The following options are available:

     --log-level               Sets the log level for process and topics (e.g. "DEBUG;
                               TRACE:discv5,libp2p; REQUIRED:none; DISABLED:none").
     --log-file                Specifies a path for the written Json log file.
     --network                 The Eth2 network to join.
 -d, --data-dir                The directory where nimbus will store all blockchain data.
     --validators-dir          A directory containing validator keystores.
     --secrets-dir             A directory containing validator keystore passwords.
     --wallets-dir             A directory containing wallet files.
     --web3-url                URL of the Web3 server to observe Eth1.
     --non-interactive         Do not display interative prompts. Quit on missing
                               configuration.
     --netkey-file             Source of network (secp256k1) private key file
                               (random|<path>) (default: random).
     --insecure-netkey-password  Use pre-generated INSECURE password for network private key
                               file (default: false).
     --agent-string            Node agent string which is used as identifier in network.
     --subscribe-all-subnets   Subscribe to all attestation subnet topics when gossiping.
 -b, --bootstrap-node          Specifies one or more bootstrap nodes to use when connecting
                               to the network.
     --bootstrap-file          Specifies a line-delimited file of bootstrap Ethereum network
                               addresses.
     --listen-address          Listening address for the Ethereum LibP2P and Discovery v5
                               traffic.
     --tcp-port                Listening TCP port for Ethereum LibP2P traffic, the default is 9000
     --udp-port                Listening UDP port for node discovery, default is 9000
     --max-peers               The maximum number of peers to connect to.
     --nat                     Specify method to use for determining public address. Must be
                               one of: any, none, upnp, pmp, extip:<IP>.
     --enr-auto-update         Discovery can automatically update its ENR with the IP
                               address and UDP port as seen by other nodes it communicates
                               with. This option allows to enable/disable this
                               functionality.
     --weak-subjectivity-checkpoint  Weak subjectivity checkpoint in the format
                               block_root:epoch_number.
     --finalized-checkpoint-state  SSZ file specifying a recent finalized state.
     --finalized-checkpoint-block  SSZ file specifying a recent finalized block.
     --node-name               A name for this node that will appear in the logs. If you set
                               this to 'auto', a persistent automatically generated ID will
                               be selected for each --data-dir folder.
     --graffiti                The graffiti value that will appear in proposed blocks. You
                               can use a 0x-prefixed hex encoded string to specify raw
                               bytes.
     --verify-finalization     Specify whether to verify finalization occurs on schedule,
                               for testing.
     --stop-at-epoch           A positive epoch selects the epoch at which to stop.
     --metrics                 Enable the metrics server.
     --metrics-address         Listening address of the metrics server.
     --metrics-port            Listening HTTP port of the metrics server.
     --status-bar              Display a status bar at the bottom of the terminal screen.
     --status-bar-contents     Textual template for the contents of the status bar.
     --rpc                     Enable the JSON-RPC server.
     --rpc-port                HTTP port for the JSON-RPC service.
     --rpc-address             Listening address of the RPC server.
     --in-process-validators   Disable the push model (the beacon node tells a signing
                               process with the private keys of the validators what to sign
                               and when) and load the validators in the beacon node itself.
     --discv5                  Enable Discovery v5.
     --dump                    Write SSZ dumps of blocks, attestations and states to data
                               dir.
     --doppelganger-detection  Whether to detect whether another validator is be running the
                               same validator keys (default true).

Available sub-commands:

...
```
