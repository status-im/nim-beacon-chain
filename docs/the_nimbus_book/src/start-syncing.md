
# Start syncing

If you're joining a network that has already launched, you need to ensure that your beacon node is [completely synced](./keep-an-eye.md#keep-track-of-your-syncing-progress) before submitting your deposit.

This is particularly important if you are joining a network that's been running for a while.

### Testnet

To start syncing the `pyrmont` testnet , from the `nimbus-eth2` repository, run:

```
 ./run-pyrmont-beacon-node.sh
```

### Mainnet

> **Note:** Mainnet won't launch before December 1st.


To start monitoring the eth1 mainnet chain for deposits, from the `nimbus-eth2` repository, run:

```
 ./run-mainnet-beacon-node.sh
```

### Web3 provider URL
You should see the following prompt:

```
To monitor the Eth1 validator deposit contract, you'll need to pair
the Nimbus beacon node with a Web3 provider capable of serving Eth1
event logs. This could be a locally running Eth1 client such as Geth
or a cloud service such as Infura. For more information please see
our setup guide:

https://status-im.github.io/nimbus-eth2/eth1.html

Please enter a Web3 provider URL:
```

If you're running a local geth instance, geth accepts connections from the loopback interface (`127.0.0.1`), with default WebSocket port `8546`. This means that your default Web3 provider URL should be: 
```
ws://127.0.0.1:8546
```

>**Note:** If you're using [your own Infura endpoint](./infura-guide), you should enter that instead.

Once you've entered your Web3 provider URL, you should see the following output:

```
INF 2020-11-18 11:25:33.487+01:00 Launching beacon node
...
INF 2020-11-18 11:25:34.556+01:00 Loading block dag from database            topics="beacnde" tid=19985314 file=nimbus_beacon_node.nim:198 path=build/data/shared_pyrmont_0/db
INF 2020-11-18 11:25:35.921+01:00 Block dag initialized
INF 2020-11-18 11:25:37.073+01:00 Generating new networking key
...
```


### Command line options

You can pass any `nimbus_beacon_node` options to the `pyrmont` and `mainnet` scripts. For example, if you wanted to launch Nimbus on `pyrmont` with a different base port, say `9100`, you would run:

```
./run-pyrmont-beacon-node.sh --tcp-port=9100 --udp-port=9100
```

To see a list of the command line options availabe to you, with descriptions, navigate to the `build` directory and run:

```
./nimbus_beacon_node --help
```
