#!/bin/bash

set -e

NODE_ID=${1}
shift

# Read in variables
# shellcheck source=/dev/null
source "$(dirname "$0")/vars.sh"

# set up the environment
# shellcheck source=/dev/null
source "${SIM_ROOT}/../../env.sh"

cd "$GIT_ROOT"

NODE_DATA_DIR="${SIMULATION_DIR}/validator-$NODE_ID"
NODE_VALIDATORS_DIR=$NODE_DATA_DIR/validators/
MAKEDIR=$GIT_ROOT/scripts/makedir.sh
COPYFILE=$GIT_ROOT/scripts/copyfile.sh

rm -rf "$NODE_VALIDATORS_DIR"
"$MAKEDIR" "$NODE_VALIDATORS_DIR"

# we will split the keys for this instance in half between the BN and the VC
# and the validators for the VCs will be from the second half of all validators
VALIDATORS_PER_NODE=$(( (NUM_VALIDATORS / TOTAL_NODES) / 2 ))
VALIDATOR_OFFSET=$((NUM_VALIDATORS / 2))

if [[ $NODE_ID -lt $TOTAL_NODES ]]; then

  pushd "$VALIDATORS_DIR" >/dev/null
  for VALIDATOR in $(ls | tail -n +$(( $VALIDATOR_OFFSET + ($VALIDATORS_PER_NODE * $NODE_ID) + 1 )) | head -n $VALIDATORS_PER_NODE); do
      "$COPYFILE" "$VALIDATOR" "$NODE_VALIDATORS_DIR"
    done
  popd >/dev/null
fi

cd "$NODE_DATA_DIR"

$VALIDATOR_CLIENT_BIN \
  --log-level=${LOG_LEVEL:-DEBUG} \
  --data-dir=$NODE_DATA_DIR \
  --rpc-port="$(( $BASE_RPC_PORT + $NODE_ID ))"
