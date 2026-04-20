#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
source ./reality-utils.sh
echo "Testing new openssl branch..."
unset PRIVATE_KEY PUBLIC_KEY
generate_reality_keys
echo "PRIVATE_KEY=$PRIVATE_KEY"
echo "PUBLIC_KEY=$PUBLIC_KEY"
# Validate length
echo "$PRIVATE_KEY" | base64 -d | wc -c | grep -q 32
echo "$PUBLIC_KEY" | base64 -d | wc -c | grep -q 32
echo "Success."