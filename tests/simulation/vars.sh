#!/bin/bash

PWD_CMD="pwd"
# get native Windows paths on Mingw
uname | grep -qi mingw && PWD_CMD="pwd -W"

cd $(dirname $0)
SIM_ROOT="$($PWD_CMD)"

# Set a default value for the env vars usually supplied by a Makefile
cd $(git rev-parse --show-toplevel)
: ${GIT_ROOT:="$($PWD_CMD)"}
cd - &>/dev/null
: ${SKIP_BUILDS:=""}
: ${BUILD_OUTPUTS_DIR:="$GIT_ROOT/build"}

NUM_VALIDATORS=${VALIDATORS:-1000}
NUM_NODES=${NODES:-4}
NUM_MISSING_NODES=${MISSING_NODES:-0}

SIMULATION_DIR="${SIM_ROOT}/data"
VALIDATORS_DIR="${SIM_ROOT}/validators"
SNAPSHOT_FILE="${SIMULATION_DIR}/state_snapshot.json"
NETWORK_METADATA_FILE="${SIMULATION_DIR}/network.json"
BEACON_NODE_BIN="${BUILD_OUTPUTS_DIR}/beacon_node"
VALIDATOR_KEYGEN_BIN="${BUILD_OUTPUTS_DIR}/validator_keygen"
DEPLOY_DEPOSIT_CONTRACT_BIN="${BUILD_OUTPUTS_DIR}/deploy_deposit_contract"
MASTER_NODE_ADDRESS_FILE="${SIMULATION_DIR}/node-0/beacon_node.address"
