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

BOOTSTRAP_ARG=""

if [[ ! -z "$1" ]]; then
  BOOTSTRAP_NODE_ID=$1
  shift
else
  BOOTSTRAP_NODE_ID=$BOOTSTRAP_NODE
fi

BOOTSTRAP_ADDRESS_FILE="${SIMULATION_DIR}/node-${BOOTSTRAP_NODE_ID}/beacon_node.enr"

if [[ "$NODE_ID" != "$BOOTSTRAP_NODE" ]]; then
  BOOTSTRAP_ARG="--bootstrap-file=$BOOTSTRAP_ADDRESS_FILE"
fi

# set up the environment
# shellcheck source=/dev/null
source "${SIM_ROOT}/../../env.sh"

cd "$GIT_ROOT"

NODE_DATA_DIR="${SIMULATION_DIR}/node-$NODE_ID"
NODE_VALIDATORS_DIR=$NODE_DATA_DIR/validators/
NODE_SECRETS_DIR=$NODE_DATA_DIR/secrets/

PORT=$(( BASE_P2P_PORT + NODE_ID ))

NAT_ARG="--nat:extip:127.0.0.1"
if [ "${NAT:-}" == "1" ]; then
  NAT_ARG="--nat:any"
fi

rm -rf "$NODE_VALIDATORS_DIR"
mkdir -p "$NODE_VALIDATORS_DIR"

rm -rf "$NODE_SECRETS_DIR"
mkdir -p "$NODE_SECRETS_DIR"

VALIDATORS_PER_NODE=$(( NUM_VALIDATORS / (TOTAL_NODES - 1) ))

if [[ $NODE_ID -lt $BOOTSTRAP_NODE ]]; then
  # if using validator client binaries in addition to beacon nodes
  # we will split the keys for this instance in half between the BN and the VC
  if [ "${BN_VC_VALIDATOR_SPLIT:-}" == "yes" ]; then
    ATTACHED_VALIDATORS=$((VALIDATORS_PER_NODE / 2))
  else
    ATTACHED_VALIDATORS=$VALIDATORS_PER_NODE
  fi

  pushd "$VALIDATORS_DIR" >/dev/null
  for VALIDATOR in $(ls | tail -n +$(( ($VALIDATORS_PER_NODE * $NODE_ID) + 1 )) | head -n $ATTACHED_VALIDATORS); do
      cp -a "$VALIDATOR" "$NODE_VALIDATORS_DIR"
      cp -a "$SECRETS_DIR/$VALIDATOR" "$NODE_SECRETS_DIR"
    done
  popd >/dev/null
fi

rm -rf "$NODE_DATA_DIR/dump"
mkdir -p "$NODE_DATA_DIR/dump"

SNAPSHOT_ARG=""
if [ -f "${SNAPSHOT_FILE}" ]; then
  SNAPSHOT_ARG="--state-snapshot=${SNAPSHOT_FILE}"
fi

DEPOSIT_CONTRACT_ARGS=""
if [ -f "${DEPOSIT_CONTRACT_FILE}" ]; then
  DEPOSIT_CONTRACT_ARGS="--deposit-contract=$(cat $DEPOSIT_CONTRACT_FILE) $WEB3_ARG"
fi

cd "$NODE_DATA_DIR"

$BEACON_NODE_BIN \
  --log-level=${LOG_LEVEL:-DEBUG} \
  $BOOTSTRAP_ARG \
  --data-dir=$NODE_DATA_DIR \
  --secrets-dir=$NODE_SECRETS_DIR \
  --node-name=$NODE_ID \
  --tcp-port=$PORT \
  --udp-port=$PORT \
  $SNAPSHOT_ARG \
  $NAT_ARG \
  $DEPOSIT_CONTRACT_ARGS \
  --rpc \
  --rpc-address="127.0.0.1" \
  --rpc-port="$(( $BASE_RPC_PORT + $NODE_ID ))" \
  --metrics \
  --metrics-address="127.0.0.1" \
  --metrics-port="$(( $BASE_METRICS_PORT + $NODE_ID ))" \
  ${ADDITIONAL_BEACON_NODE_ARGS} \
  "$@"
