# Network stats and monitoring

> ⚠️  This page concerns the [Pyrmont](https://pyrmont.launchpad.ethereum.org/) testnet. If you have made a mainnet deposit, you do not need to connect to eth2 quite yet. Mainnet [Genesis](https://hackmd.io/@benjaminion/genesis) date has been set to [December 1st](https://blog.ethereum.org/2020/11/04/eth2-quick-update-no-19/). This page will be updated nearer the time.

eth2stats is a network monitoring suite for your beacon node + validator client.

It consists of a [command-line-interface](https://github.com/Alethio/eth2stats-client) (to help you query your node's API), and an [associated website](https://eth2stats.io/medalla-testnet) (which allows you to monitor your node from anywhere).

In this guide we'll take you through how to get eth2stats running on your local machine, and how to hook your node up to the website.

## Prerequisites

Knowledge of both [git](https://www.learnenough.com/git-tutorial/getting_started) and [command line basics](https://www.learnenough.com/command-line-tutorial/basics), and a working [Golang](https://golang.org/dl/) environment.

## Guide

### 1. Clone the eth2stats repository

```
git clone https://github.com/Alethio/eth2stats-client.git
```

### 2. Move into the repository

```
cd eth2stats-client
```

### 3. Build the executable

```
make build
```

### 4. Add your node to eth2stats.io


#### 1. Click on add node
![](https://i.imgur.com/1ofuj4E.png)

#### 2. Configure name and client type
![](https://i.imgur.com/iQfwAit.png)

#### 3. Copy the command
Click on `Compile from source` and copy the command at the bottom.
![](https://i.imgur.com/biT5HkJ.png)

### 5. Build and run your node with metrics enabled

From your `nimbus-eth2` repository, run:
```
make NIMFLAGS="-d:insecure" nimbus_beacon_node
```

Followed by:

```
./run-pyrmont-beacon-node.sh
```

### 6. Run eth2stats

From your `eth2stats-client` repository, **run the command you copied in step 4.3:**
```
./eth2stats-client run \
--eth2stats.node-name="roger" \
--data.folder ~/.eth2stats/data \
--eth2stats.addr="grpc.pyrmont.eth2.wtf:8080" --eth2stats.tls=false \
--beacon.type="nimbus" \
--beacon.addr="http://localhost:9190" \
--beacon.metrics-addr="http://localhost:8008/metrics"
```

Your node should now be displayed on [https://pyrmont.eth2.wtf/](https://pyrmont.eth2.wtf/) :)





