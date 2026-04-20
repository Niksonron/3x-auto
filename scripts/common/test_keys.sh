#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
source ./reality-utils.sh
echo "Testing generate_reality_keys..."
unset PRIVATE_KEY PUBLIC_KEY
generate_reality_keys
echo "PRIVATE_KEY=$PRIVATE_KEY"
echo "PUBLIC_KEY=$PUBLIC_KEY"