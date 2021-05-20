#!/bin/bash

# Copyright (c) 2020-2021 Status Research & Development GmbH. Licensed under
# either of:
# - Apache License, version 2.0
# - MIT license
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

# Mostly a duplication of "tests/simulation/{start.sh,run_node.sh}", but with a focus on
# replicating testnets as closely as possible, which means following the Docker execution labyrinth.

set -e

cd "$(dirname "${BASH_SOURCE[0]}")"/..

####################
# argument parsing #
####################

GETOPT_BINARY="getopt"
if uname | grep -qi darwin; then
  # macOS
  GETOPT_BINARY="/usr/local/opt/gnu-getopt/bin/getopt"
  [[ -f "$GETOPT_BINARY" ]] || { echo "GNU getopt not installed. Please run 'brew install gnu-getopt'. Aborting."; exit 1; }
fi

! ${GETOPT_BINARY} --test > /dev/null
if [ ${PIPESTATUS[0]} != 4 ]; then
  echo '`getopt --test` failed in this environment.'
  exit 1
fi

OPTS="ht:n:d:g"
LONGOPTS="help,testnet:,nodes:,data-dir:,with-ganache,stop-at-epoch:,disable-htop,disable-vc,enable-logtrace,log-level:,base-port:,base-rpc-port:,base-metrics-port:,reuse-existing-data-dir,timeout:"

# default values
TESTNET="1"
NUM_NODES="10"
DATA_DIR="local_testnet_data"
USE_HTOP="1"
USE_VC="1"
USE_GANACHE="0"
LOG_LEVEL="DEBUG"
BASE_PORT="9000"
BASE_METRICS_PORT="8008"
BASE_RPC_PORT="7000"
REUSE_EXISTING_DATA_DIR="0"
ENABLE_LOGTRACE="0"
STOP_AT_EPOCH_FLAG=""
TIMEOUT_DURATION="0"

print_help() {
  cat <<EOF
Usage: $(basename "$0") --testnet <testnet number> [OTHER OPTIONS] -- [BEACON NODE OPTIONS]
E.g.: $(basename "$0") --testnet ${TESTNET} --nodes ${NUM_NODES} --stop-at-epoch 5 --data-dir "${DATA_DIR}" # defaults
CI run: $(basename "$0") --disable-htop -- --verify-finalization

  -h, --help                  this help message
  -t, --testnet               testnet number (default: ${TESTNET})
  -n, --nodes                 number of nodes to launch (default: ${NUM_NODES})
  -g, --with-ganache          simulate a genesis event based on a deposit contract
  -s, --stop-at-epoch         stop simulation at epoch (default: infinite)
  -d, --data-dir              directory where all the node data and logs will end up
                              (default: "${DATA_DIR}")
  --base-port                 bootstrap node's Eth2 traffic port (default: ${BASE_PORT})
  --base-rpc-port             bootstrap node's RPC port (default: ${BASE_RPC_PORT})
  --base-metrics-port         bootstrap node's metrics server port (default: ${BASE_METRICS_PORT})
  --disable-htop              don't use "htop" to see the nimbus_beacon_node processes
  --disable-vc                don't use validator client binaries for validators (by default validators are split 50/50 between beacon nodes and validator clients)
  --enable-logtrace           display logtrace asr analysis
  --log-level                 set the log level (default: ${LOG_LEVEL})
  --reuse-existing-data-dir   instead of deleting and recreating the data dir, keep it and reuse everything we can from it
  --timeout                   timeout in seconds (default: ${TIMEOUT_DURATION} - no timeout)
EOF
}

! PARSED=$(${GETOPT_BINARY} --options=${OPTS} --longoptions=${LONGOPTS} --name "$0" -- "$@")
if [ ${PIPESTATUS[0]} != 0 ]; then
  # getopt has complained about wrong arguments to stdout
  exit 1
fi

# read getopt's output this way to handle the quoting right
eval set -- "$PARSED"
while true; do
  case "$1" in
    -h|--help)
      print_help
      exit
      ;;
    -t|--testnet)
      TESTNET="$2"
      shift 2
      ;;
    -n|--nodes)
      NUM_NODES="$2"
      shift 2
      ;;
    -d|--data-dir)
      DATA_DIR="$2"
      shift 2
      ;;
    -g|--with-ganache)
      USE_GANACHE="1"
      shift
      ;;
    --stop-at-epoch)
      STOP_AT_EPOCH_FLAG="--stop-at-epoch=$2"
      shift 2
      ;;
    --disable-htop)
      USE_HTOP="0"
      shift
      ;;
    --disable-vc)
      USE_VC="0"
      shift
      ;;
    --enable-logtrace)
      ENABLE_LOGTRACE="1"
      shift
      ;;
    --log-level)
      LOG_LEVEL="$2"
      shift 2
      ;;
    --base-port)
      BASE_PORT="$2"
      shift 2
      ;;
    --base-rpc-port)
      BASE_RPC_PORT="$2"
      shift 2
      ;;
    --base-metrics-port)
      BASE_METRICS_PORT="$2"
      shift 2
      ;;
    --reuse-existing-data-dir)
      REUSE_EXISTING_DATA_DIR="1"
      shift
      ;;
    --timeout)
      TIMEOUT_DURATION="$2"
      shift 2
      ;;
    --)
      shift
      break
      ;;
    *)
      echo "argument parsing error"
      print_help
      exit 1
  esac
done

# when sourcing env.sh, it will try to execute $@, so empty it
EXTRA_ARGS="$@"
if [[ $# != 0 ]]; then
  shift $#
fi
NETWORK="testnet${TESTNET}"

if [[ "$REUSE_EXISTING_DATA_DIR" == "0" ]]; then
  rm -rf "${DATA_DIR}"
fi

mkdir -m 0700 -p "${DATA_DIR}"

DEPOSITS_FILE="${DATA_DIR}/deposits.json"

VALIDATORS_DIR="${DATA_DIR}/validators"
mkdir -p "${VALIDATORS_DIR}"

SECRETS_DIR="${DATA_DIR}/secrets"
mkdir -p "${SECRETS_DIR}"

NETWORK_DIR="${DATA_DIR}/network_dir"
mkdir -p "${NETWORK_DIR}"

set -a
source "scripts/${NETWORK}.env"
set +a

# Windows detection
if uname | grep -qiE "mingw|msys"; then
  MAKE="mingw32-make"
else
  MAKE="make"
fi

# number of CPU cores
if uname | grep -qi darwin; then
  NPROC="$(sysctl -n hw.logicalcpu)"
else
  NPROC="$(nproc)"
fi

# Build the binaries
BINARIES="nimbus_beacon_node nimbus_signing_process nimbus_validator_client deposit_contract"
if [[ "$ENABLE_LOGTRACE" == "1" ]]; then
  BINARIES="${BINARIES} logtrace"
fi
NETWORK_NIM_FLAGS=$(scripts/load-testnet-nim-flags.sh "${NETWORK}")
$MAKE -j ${NPROC} V=1 LOG_LEVEL="${LOG_LEVEL}" NIMFLAGS="${NIMFLAGS} -d:testnet_servers_image -d:local_testnet --listCmd ${NETWORK_NIM_FLAGS}" ${BINARIES}

PIDS=""

WEB3_ARG="--web3-url=http://127.0.0.1:8545"

STATE_SNAPSHOT_ARG=""
BOOTSTRAP_TIMEOUT=30 # in seconds
DEPOSIT_CONTRACT_ADDRESS="0x0000000000000000000000000000000000000000"
DEPOSIT_CONTRACT_BLOCK="0x0000000000000000000000000000000000000000000000000000000000000000"
NETWORK_METADATA_FILE="${DATA_DIR}/network.json"
NUM_JOBS=${NUM_NODES}

if [[ "$REUSE_EXISTING_DATA_DIR" == "0" ]]; then
  ./build/deposit_contract generateSimulationDeposits \
    --count=${TOTAL_VALIDATORS} \
    --out-validators-dir="${VALIDATORS_DIR}" \
    --out-secrets-dir="${SECRETS_DIR}" \
    --out-deposits-file="${DEPOSITS_FILE}"
fi

if [[ $USE_GANACHE == "0" ]]; then
  GENESIS_OFFSET=30
  BOOTSTRAP_IP="127.0.0.1"

  ./build/nimbus_beacon_node createTestnet \
    --data-dir="${DATA_DIR}" \
    --deposits-file="${DEPOSITS_FILE}" \
    --total-validators=${TOTAL_VALIDATORS} \
    --output-genesis="${NETWORK_DIR}/genesis.ssz" \
    --output-bootstrap-file="${NETWORK_DIR}/bootstrap_nodes.txt" \
    --bootstrap-address=${BOOTSTRAP_IP} \
    --bootstrap-port=${BASE_PORT} \
    --netkey-file=network_key.json \
    --insecure-netkey-password=true \
    --genesis-offset=${GENESIS_OFFSET} # Delay in seconds

  STATE_SNAPSHOT_ARG="--finalized-checkpoint-state=${NETWORK_DIR}/genesis.ssz"
else
  echo "Launching ganache"
  ganache-cli --blockTime 17 --gasLimit 100000000 -e 100000 --verbose > "${DATA_DIR}/log_ganache.txt" 2>&1 &
  PIDS="${PIDS},$!"

  WEB3_ARG="--web3-url=ws://localhost:8545"

  echo "Deploying deposit contract"
  DEPLOY_CMD_OUTPUT=$(./build/deposit_contract deploy $WEB3_ARG)
  # https://stackoverflow.com/questions/918886/how-do-i-split-a-string-on-a-delimiter-in-bash
  OUTPUT_PIECES=(${DEPLOY_CMD_OUTPUT//;/ })
  DEPOSIT_CONTRACT_ADDRESS=${OUTPUT_PIECES[0]}
  DEPOSIT_CONTRACT_BLOCK=${OUTPUT_PIECES[1]}

  echo Contract deployed at "$DEPOSIT_CONTRACT_ADDRESS":"$DEPOSIT_CONTRACT_BLOCK"

  MIN_DELAY=1
  MAX_DELAY=5

  BOOTSTRAP_TIMEOUT=$(( MAX_DELAY * TOTAL_VALIDATORS ))

  ./build/deposit_contract sendDeposits \
    --deposits-file="${DEPOSITS_FILE}" \
    --min-delay=$MIN_DELAY --max-delay=$MAX_DELAY \
    $WEB3_ARG \
    --deposit-contract=${DEPOSIT_CONTRACT_ADDRESS} > "${DATA_DIR}/log_deposit_maker.txt" 2>&1 &

  PIDS="${PIDS},$!"
fi

./scripts/make_prometheus_config.sh \
    --nodes ${NUM_NODES} \
    --base-metrics-port ${BASE_METRICS_PORT} \
    --config-file "${DATA_DIR}/prometheus.yml" || true # TODO: this currently fails on macOS,
                                                       # but it can be considered non-critical

echo Wrote $NETWORK_METADATA_FILE:
tee "$NETWORK_METADATA_FILE" <<EOF
{
  "runtimePreset": {
    "MIN_GENESIS_ACTIVE_VALIDATOR_COUNT": ${TOTAL_VALIDATORS},
    "MIN_GENESIS_TIME": 0,
    "GENESIS_DELAY": 10,
    "GENESIS_FORK_VERSION": "0x00000000",
    "DEPOSIT_CHAIN_ID": 1000,
    "DEPOSIT_NETWORK_ID": 1000
  },
  "depositContractAddress": "${DEPOSIT_CONTRACT_ADDRESS}",
  "depositContractDeployedAt": "${DEPOSIT_CONTRACT_BLOCK}"
}
EOF

# Kill child processes on Ctrl-C/SIGTERM/exit, passing the PID of this shell
# instance as the parent and the target process name as a pattern to the
# "pkill" command.
cleanup() {
  pkill -f -P $$ nimbus_beacon_node &>/dev/null || true
  pkill -f -P $$ nimbus_validator_client &>/dev/null || true
  sleep 2
  pkill -f -9 -P $$ nimbus_beacon_node &>/dev/null || true
  pkill -f -9 -P $$ nimbus_validator_client &>/dev/null || true
}
trap 'cleanup' SIGINT SIGTERM EXIT

dump_logs() {
  LOG_LINES=20
  for LOG in "${DATA_DIR}"/log*.txt; do
    echo "Last ${LOG_LINES} lines of ${LOG}:"
    tail -n ${LOG_LINES} "${LOG}"
    echo "======"
  done
}

dump_logtrace() {
  if [[ "$ENABLE_LOGTRACE" == "1" ]]; then
    find "${DATA_DIR}" -maxdepth 1 -type f -regex '.*/log[0-9]+.txt' | sed -e"s/${DATA_DIR}\//--nodes=/" | sort | xargs ./build/logtrace asr --log-dir="${DATA_DIR}" || true
  fi
}

NODES_WITH_VALIDATORS=${NODES_WITH_VALIDATORS:-4}
BOOTSTRAP_NODE=0
SYSTEM_VALIDATORS=$(( TOTAL_VALIDATORS - USER_VALIDATORS ))
VALIDATORS_PER_NODE=$(( SYSTEM_VALIDATORS / NODES_WITH_VALIDATORS ))
if [ "${USE_VC:-}" == "1" ]; then
  # if using validator client binaries in addition to beacon nodes we will
  # split the keys for this instance in half between the BN and the VC
  # and the validators for the BNs will be from the first half of all validators
  VALIDATORS_PER_NODE=$((VALIDATORS_PER_NODE / 2 ))
  NUM_JOBS=$((NUM_JOBS * 2 ))
fi
VALIDATORS_PER_VALIDATOR=$(( (SYSTEM_VALIDATORS / NODES_WITH_VALIDATORS) / 2 ))
VALIDATOR_OFFSET=$((SYSTEM_VALIDATORS / 2))
BOOTSTRAP_ENR="${DATA_DIR}/node${BOOTSTRAP_NODE}/beacon_node.enr"
NETWORK_KEYFILE="../network_key.json"

for NUM_NODE in $(seq 0 $(( NUM_NODES - 1 ))); do
  if [[ ${NUM_NODE} == ${BOOTSTRAP_NODE} ]]; then
    BOOTSTRAP_ARG="--netkey-file=${NETWORK_KEYFILE} --insecure-netkey-password=true"
  else
    BOOTSTRAP_ARG="--bootstrap-file=${BOOTSTRAP_ENR}"
    # Wait for the master node to write out its address file
    START_TIMESTAMP=$(date +%s)
    while [[ ! -f "${BOOTSTRAP_ENR}" ]]; do
      sleep 0.1
      NOW_TIMESTAMP=$(date +%s)
      if [[ "$(( NOW_TIMESTAMP - START_TIMESTAMP - GENESIS_OFFSET ))" -ge "$BOOTSTRAP_TIMEOUT" ]]; then
        echo "Bootstrap node failed to start in ${BOOTSTRAP_TIMEOUT} seconds. Aborting."
        dump_logs
        exit 1
      fi
    done
  fi

  # Copy validators to individual nodes.
  # The first $NODES_WITH_VALIDATORS nodes split them equally between them, after skipping the first $USER_VALIDATORS.
  NODE_DATA_DIR="${DATA_DIR}/node${NUM_NODE}"
  rm -rf "${NODE_DATA_DIR}"
  mkdir -m 0700 -p "${NODE_DATA_DIR}"
  mkdir -p "${NODE_DATA_DIR}/validators"
  mkdir -p "${NODE_DATA_DIR}/secrets"

  if [[ $NUM_NODE -lt $NODES_WITH_VALIDATORS ]]; then
    if [ "${USE_VC:-}" == "1" ]; then
      VALIDATOR_DATA_DIR="${DATA_DIR}/validator${NUM_NODE}"
      rm -rf "${VALIDATOR_DATA_DIR}"
      mkdir -p "${VALIDATOR_DATA_DIR}/validators"
      mkdir -p "${VALIDATOR_DATA_DIR}/secrets"

      for VALIDATOR in $(ls "${VALIDATORS_DIR}" | tail -n +$(( $USER_VALIDATORS + ($VALIDATORS_PER_VALIDATOR * $NUM_NODE) + 1 + $VALIDATOR_OFFSET )) | head -n $VALIDATORS_PER_VALIDATOR); do
        cp -a "${VALIDATORS_DIR}/$VALIDATOR" "${VALIDATOR_DATA_DIR}/validators/"
        cp -a "${SECRETS_DIR}/${VALIDATOR}" "${VALIDATOR_DATA_DIR}/secrets/"
      done
    fi

    for VALIDATOR in $(ls "${VALIDATORS_DIR}" | tail -n +$(( $USER_VALIDATORS + ($VALIDATORS_PER_NODE * $NUM_NODE) + 1 )) | head -n $VALIDATORS_PER_NODE); do
      cp -a "${VALIDATORS_DIR}/$VALIDATOR" "${NODE_DATA_DIR}/validators/"
      cp -a "${SECRETS_DIR}/${VALIDATOR}" "${NODE_DATA_DIR}/secrets/"
    done
  fi

  ./build/nimbus_beacon_node \
    --non-interactive \
    --nat:extip:127.0.0.1 \
    --network="${NETWORK_METADATA_FILE}" \
    --log-level="${LOG_LEVEL}" \
    --tcp-port=$(( BASE_PORT + NUM_NODE )) \
    --udp-port=$(( BASE_PORT + NUM_NODE )) \
    --max-peers=$(( NUM_NODES - 1 )) \
    --data-dir="${NODE_DATA_DIR}" \
    ${BOOTSTRAP_ARG} \
    ${STATE_SNAPSHOT_ARG} \
    ${WEB3_ARG} \
    ${STOP_AT_EPOCH_FLAG} \
    --rpc \
    --rpc-address="127.0.0.1" \
    --rpc-port="$(( BASE_RPC_PORT + NUM_NODE ))" \
    --metrics \
    --metrics-address="127.0.0.1" \
    --metrics-port="$(( BASE_METRICS_PORT + NUM_NODE ))" \
    --doppelganger-detection=off \
    ${EXTRA_ARGS} \
    > "${DATA_DIR}/log${NUM_NODE}.txt" 2>&1 &

  if [[ "${PIDS}" == "" ]]; then
    PIDS="$!"
  else
    PIDS="${PIDS},$!"
  fi

  if [ "${USE_VC:-}" == "1" ]; then
    ./build/nimbus_validator_client \
      --log-level="${LOG_LEVEL}" \
      ${STOP_AT_EPOCH_FLAG} \
      --data-dir="${VALIDATOR_DATA_DIR}" \
      --rpc-port="$(( BASE_RPC_PORT + NUM_NODE ))" \
      > "${DATA_DIR}/log_val${NUM_NODE}.txt" 2>&1 &
  fi
done

# give the regular nodes time to crash
sleep 5
BG_JOBS="$(jobs | wc -l | tr -d ' ')"
if [[ "$BG_JOBS" != "$NUM_JOBS" ]]; then
  echo "$(( NUM_JOBS - BG_JOBS )) nimbus_beacon_node/nimbus_validator_client instance(s) exited early. Aborting."
  dump_logs
  dump_logtrace
  exit 1
fi

# timeout - implemented with a background job
timeout_reached() {
  echo -e "\nTimeout reached. Aborting.\n"
  cleanup
}
trap 'timeout_reached' SIGALRM

if [[ "${TIMEOUT_DURATION}" != "0" ]]; then
  export PARENT_PID=$$
  ( sleep ${TIMEOUT_DURATION} && kill -ALRM ${PARENT_PID} ) 2>/dev/null & WATCHER_PID=$!
fi

# launch htop or wait for background jobs
if [[ "$USE_HTOP" == "1" ]]; then
  htop -p "$PIDS"
  cleanup
else
  FAILED=0
  for PID in $(echo "$PIDS" | tr ',' ' '); do
    wait "$PID" || FAILED="$(( FAILED += 1 ))"
  done
  if [[ "$FAILED" != "0" ]]; then
    echo "${FAILED} child processes had non-zero exit codes (or exited early)."
    dump_logs
    dump_logtrace
    if [[ "${TIMEOUT_DURATION}" != "0" ]]; then
      pkill -HUP -P ${WATCHER_PID}
    fi
    exit 1
  fi
fi

dump_logtrace

if [[ "${TIMEOUT_DURATION}" != "0" ]]; then
  pkill -HUP -P ${WATCHER_PID}
fi

