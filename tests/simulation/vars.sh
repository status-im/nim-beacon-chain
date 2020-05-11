#!/bin/bash

# https://github.com/koalaman/shellcheck/wiki/SC2034
# shellcheck disable=2034
true

PWD_CMD="pwd"
# get native Windows paths on Mingw
uname | grep -qi mingw && PWD_CMD="pwd -W"

cd "$(dirname "$0")"

SIM_ROOT="$($PWD_CMD)"

# Set a default value for the env vars usually supplied by a Makefile
cd "$(git rev-parse --show-toplevel)"
: ${GIT_ROOT:="$($PWD_CMD)"}
cd - &>/dev/null

# When changing these, also update the readme section on running simulation
# so that the run_node example is correct!
NUM_VALIDATORS=${VALIDATORS:-192}
TOTAL_NODES=${NODES:-4}
TOTAL_USER_NODES=${USER_NODES:-0}
TOTAL_SYSTEM_NODES=$(( TOTAL_NODES - TOTAL_USER_NODES ))
MASTER_NODE=$(( TOTAL_NODES - 1 ))

SIMULATION_DIR="${SIM_ROOT}/data"
METRICS_DIR="${SIM_ROOT}/prometheus"
VALIDATORS_DIR="${SIM_ROOT}/validators"
SNAPSHOT_FILE="${SIMULATION_DIR}/state_snapshot.ssz"
NETWORK_BOOTSTRAP_FILE="${SIMULATION_DIR}/bootstrap_nodes.txt"
BEACON_NODE_BIN="${GIT_ROOT}/build/beacon_node"
DEPLOY_DEPOSIT_CONTRACT_BIN="${GIT_ROOT}/build/deposit_contract"
MASTER_NODE_ADDRESS_FILE="${SIMULATION_DIR}/node-${MASTER_NODE}/beacon_node.address"

BASE_P2P_PORT=30000
BASE_RPC_PORT=7000
BASE_METRICS_PORT=8008

if [[ "$USE_GANACHE" == "yes" ]]; then
  WEB3_ARG=--web3-url=ws://localhost:8545
else
  WEB3_ARG=""
  DEPOSIT_CONTRACT_ADDRESS="0x"
fi

