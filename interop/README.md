This folder contains scripts for launching the nimbus beacon chain node in a configuration appropriate for [interop](https://github.com/ethereum/eth2.0-pm/tree/master/interop).

## Building

In general, follow the build instructions of `nim-beacon-chain` as documented in the main repo - make sure to set up your build environment with all necessary system libraries as documented there:

```bash
# Clone repo
git clone https://github.com/status-im/nim-beacon-chain.git

cd nim-beacon-chain

make # prepare build system (cloning the correct submodules)
make update # build dependencies
```

## Running

Look in the scripts for options - the default config is a small setup using the `minimal` state spec.

```
# Clear data from previous run, then start a new simulation
rm -rf data ; ./start.sh

# In a separate terminal, can run another beacon node, such as lighthouse:
./run_lighthouse.sh
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
