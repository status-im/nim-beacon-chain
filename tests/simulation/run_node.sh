#!/bin/bash

set -e

NODE_ID=${1}
shift

# Read in variables
# shellcheck source=/dev/null
source "$(dirname "$0")/vars.sh"

if [[ ! -z "$1" ]]; then
  ADDITIONAL_BEACON_NODE_ARGS=$1
  shift
else
  ADDITIONAL_BEACON_NODE_ARGS=""
fi

if [[ ! -z "$1" ]]; then
  BOOTSTRAP_NODE_ID=$1
  BOOTSTRAP_ADDRESS_FILE="${SIMULATION_DIR}/node-${BOOTSTRAP_NODE_ID}/beacon_node.address"
  shift
else
  BOOTSTRAP_NODE_ID=$MASTER_NODE
  BOOTSTRAP_ADDRESS_FILE=$NETWORK_BOOTSTRAP_FILE
fi

# set up the environment
# shellcheck source=/dev/null
source "${SIM_ROOT}/../../env.sh"

cd "$GIT_ROOT"

DATA_DIR="${SIMULATION_DIR}/node-$NODE_ID"
PORT=$(( BASE_P2P_PORT + NODE_ID ))

NAT_ARG="--nat:extip:127.0.0.1"
if [ "${NAT:-}" == "1" ]; then
  NAT_ARG="--nat:any"
fi

mkdir -p "$DATA_DIR/validators"
rm -f $DATA_DIR/validators/*

if [[ $NODE_ID -lt $TOTAL_NODES ]]; then
  VALIDATORS_PER_NODE=$((NUM_VALIDATORS / TOTAL_NODES))
  VALIDATORS_PER_NODE_HALF=$((VALIDATORS_PER_NODE / 2))
  FIRST_VALIDATOR_IDX=$(( VALIDATORS_PER_NODE * NODE_ID ))
  # if using validator client binaries in addition to beacon nodes
  # we will split the keys for this instance in half between the BN and the VC
  if [ "${SPLIT_VALIDATORS_BETWEEN_BN_AND_VC:-}" == "yes" ]; then
    LAST_VALIDATOR_IDX=$(( FIRST_VALIDATOR_IDX + VALIDATORS_PER_NODE_HALF - 1 ))
  else
    LAST_VALIDATOR_IDX=$(( FIRST_VALIDATOR_IDX + VALIDATORS_PER_NODE - 1 ))
  fi

  pushd "$VALIDATORS_DIR" >/dev/null
    cp $(seq -s " " -f v%07g.privkey $FIRST_VALIDATOR_IDX $LAST_VALIDATOR_IDX) "$DATA_DIR/validators"
  popd >/dev/null
fi

rm -rf "$DATA_DIR/dump"
mkdir -p "$DATA_DIR/dump"

SNAPSHOT_ARG=""
if [ -f "${SNAPSHOT_FILE}" ]; then
  SNAPSHOT_ARG="--state-snapshot=${SNAPSHOT_FILE}"
fi

cd "$DATA_DIR"

# if you want tracing messages, add "--log-level=TRACE" below
$BEACON_NODE_BIN \
  --log-level=${LOG_LEVEL:-DEBUG} \
  --bootstrap-file=$BOOTSTRAP_ADDRESS_FILE \
  --data-dir=$DATA_DIR \
  --node-name=$NODE_ID \
  --tcp-port=$PORT \
  --udp-port=$PORT \
  $SNAPSHOT_ARG \
  $NAT_ARG \
  $WEB3_ARG \
  --deposit-contract=$DEPOSIT_CONTRACT_ADDRESS \
  --rpc \
  --rpc-address="127.0.0.1" \
  --rpc-port="$(( $BASE_RPC_PORT + $NODE_ID ))" \
  --metrics \
  --metrics-address="127.0.0.1" \
  --metrics-port="$(( $BASE_METRICS_PORT + $NODE_ID ))" \
  ${ADDITIONAL_BEACON_NODE_ARGS} \
  "$@"
