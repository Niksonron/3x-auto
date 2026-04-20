#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
source ./reality-utils.sh
echo "Sourced successfully"
export SERVER_NAMES="example.com"
export DEST="example.com:443"
generate_reality_keys
generate_short_ids
validate_reality_params
echo "All good"