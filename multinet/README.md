This folder contains scripts for launching the nimbus beacon chain node in a configuration appropriate for [interop](https://github.com/ethereum/eth2.0-pm/tree/master/interop).

## Building

In general, follow the build instructions of `nim-beacon-chain` as documented in the main repo - make sure to set up your build environment with all necessary system libraries as documented there:

### Prerequisites

:warning: To build nimbus, you need to have `rocksdb` and `pcre` installed - see [../](main repo) for instructions.

```bash
# Clone repo

export GIT_LFS_SKIP_SMUDGE=1 # skip LFS
git clone https://github.com/status-im/nim-beacon-chain.git

cd nim-beacon-chain

make # prepare build system (cloning the correct submodules)
make update deps # build dependencies
```

## Running

Look in the scripts for options - the default config is a small setup using the `minimal` state spec.

```
cd multinet

# Create a new genesis 10s in the future
./make_genesis.sh

# You can now start the clients
./run_nimbus.sh
./run_trinity.sh
./run_lighthouse.sh

# Or do all in one step, with multitail
USE_MULTITAIL=1 ./run_all.sh

```

## Tips

The `start.sh` script will help you build a node and set up a state. After building it, you can also run it manually:

```bash
# Build node (and run it, to prime data folder)
./start.sh

# ctrl-c to stop it

# show help
data/beacon_node --help

# Check out network parameters including bootstrap node address (if you want to run your own)
cat data/network.json

# Load environment if you want to run solo:
source ../env..sh

# Run with a specific state
data/beacon_node --dataDir=data/node-0 --network=data/network.json --nodename=0 --tcpPort=50000 --udpPort=50000 --stateSnapshot=file.ssz

# Validators are loaded into a node based on private keys in folder - remove to start without
rm data/node-0/validators/*

data/beacon_node --dataDir=data/node-0 --network=data/network.json --nodename=0 --tcpPort=50000 --udpPort=50000 --stateSnapshot=file.ssz
```

## Diagnostics

```bash
# Nimbus genesis state
less data/state_snapshot.json

# Lighthouse genesis state
curl localhost:5052/beacon/state?slot=0 | python -m json.tool | sed 's/"0x/"/' > /tmp/lighthouse_state.json

# Format nimbus the same
cat data/state_snapshot.json | python -m json.tool | sed 's/"0x/"/' > /tmp/nimbus_state.json

diff -uw /tmp/nimbus_state.json /tmp/lighthouse_state.json
```
