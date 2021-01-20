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
else
  BOOTSTRAP_ARG="--netkey-file=network_key.json --netkey-insecure-password"
fi

# set up the environment
# shellcheck source=/dev/null
source "${SIM_ROOT}/../../env.sh"

cd "$GIT_ROOT"

NODE_DATA_DIR="${SIMULATION_DIR}/node-$NODE_ID"
NODE_VALIDATORS_DIR=$NODE_DATA_DIR/validators/
MAKEDIR=$GIT_ROOT/scripts/makedir.sh
COPYFILE=$GIT_ROOT/scripts/copyfile.sh

PORT=$(( BASE_P2P_PORT + NODE_ID ))

NAT_ARG="--nat:extip:127.0.0.1"
if [ "${NAT:-}" == "1" ]; then
  NAT_ARG="--nat:any"
fi

"$MAKEDIR" "$NODE_DATA_DIR"

rm -rf "$NODE_VALIDATORS_DIR"
"$MAKEDIR" "$NODE_VALIDATORS_DIR"

VALIDATORS_PER_NODE=$(( NUM_VALIDATORS / (TOTAL_NODES - 1) ))
if [ "${USE_BN_VC_VALIDATOR_SPLIT:-}" == "yes" ]; then
  # if using validator client binaries in addition to beacon nodes we will
  # split the keys for this instance in half between the BN and the VC
  # and the validators for the BNs will be from the first half of all validators
  VALIDATORS_PER_NODE=$((VALIDATORS_PER_NODE / 2 ))
fi

if [[ $NODE_ID -lt $BOOTSTRAP_NODE ]]; then
  pushd "$VALIDATORS_DIR" >/dev/null
  for VALIDATOR in $(ls | tail -n +$(( ($VALIDATORS_PER_NODE * $NODE_ID) + 1 )) | head -n $VALIDATORS_PER_NODE); do
      "$COPYFILE" "$VALIDATOR" "$NODE_VALIDATORS_DIR"
    done
  popd >/dev/null
fi

rm -rf "$NODE_DATA_DIR/dump"
"$MAKEDIR" "$NODE_DATA_DIR/dump"

SNAPSHOT_ARG=""
if [ -f "${SNAPSHOT_FILE}" ]; then
  SNAPSHOT_ARG="--finalized-checkpoint-state=${SNAPSHOT_FILE}"
fi

cd "$NODE_DATA_DIR"

$BEACON_NODE_BIN \
  --log-level=${LOG_LEVEL:-DEBUG} \
  $BOOTSTRAP_ARG \
  --network=$NETWORK_METADATA_FILE \
  --data-dir=$NODE_DATA_DIR \
  --node-name=$NODE_ID \
  --tcp-port=$PORT \
  --udp-port=$PORT \
  $SNAPSHOT_ARG \
  $NAT_ARG \
  $WEB3_ARG \
  --rpc \
  --rpc-address="127.0.0.1" \
  --rpc-port="$(( $BASE_RPC_PORT + $NODE_ID ))" \
  --metrics \
  --metrics-address="127.0.0.1" \
  --metrics-port="$(( $BASE_METRICS_PORT + $NODE_ID ))" \
  --key-insecure-password=true \
  --non-interactive=true \
  ${ADDITIONAL_BEACON_NODE_ARGS} \
  "$@"
