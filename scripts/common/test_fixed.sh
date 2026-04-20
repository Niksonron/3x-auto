#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
source ./reality-utils.sh
echo "Testing generate_reality_keys..."
unset PRIVATE_KEY PUBLIC_KEY
generate_reality_keys
echo "PRIVATE_KEY=$PRIVATE_KEY"
echo "PUBLIC_KEY=$PUBLIC_KEY"
# Validate keys are base64 32-byte strings
echo "$PRIVATE_KEY" | base64 -d | wc -c | grep -q 32
echo "$PUBLIC_KEY" | base64 -d | wc -c | grep -q 32
echo "Key length validation passed."
# Test validation function
export SERVER_NAMES="example.com"
export DEST="example.com:443"
validate_reality_params
echo "All tests passed."