#!/usr/bin/env bash
# Reality parameter utilities for 3x-ui VPN automation
# Source this file in your bash scripts to generate and validate Reality parameters.

set -euo pipefail

# Check if functions already defined to allow idempotent sourcing
if ! command -v generate_reality_keys >/dev/null 2>&1; then
    # Determine script directory to source dependencies
    REALITY_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    
    # Source logging utilities
    # shellcheck source=logging.sh
    source "${REALITY_SCRIPT_DIR}/logging.sh"
    
    # Source validation utilities (optional)
    # shellcheck source=validate-config.sh
    source "${REALITY_SCRIPT_DIR}/validate-config.sh"
    
    # ------------------------------------------------------------------------
    # Key Generation Functions
    # ------------------------------------------------------------------------
    
    # Generate x25519 key pair for Reality
    # Sets PRIVATE_KEY and PUBLIC_KEY if empty
    generate_reality_keys() {
        # If both keys already set, skip generation
        if [[ -n "${PRIVATE_KEY:-}" && -n "${PUBLIC_KEY:-}" ]]; then
            log_info "Reality keys already provided, skipping generation."
            return 0
        fi
        
        log_info "Generating Reality x25519 key pair..."
        
        local private_key public_key
        
        # Try xray x25519 command first (most reliable)
        if command -v xray >/dev/null 2>&1; then
            log_info "Using xray x25519 command..."
            local xray_output
            xray_output="$(xray x25519)"
            private_key="$(echo "${xray_output}" | awk '/^Private key:/ {print $3}')"
            public_key="$(echo "${xray_output}" | awk '/^Public key:/ {print $3}')"
        # Try openssl
        elif command -v openssl >/dev/null 2>&1; then
            log_info "Using openssl genpkey..."
            # Generate x25519 key pair and extract private/public keys from text output
            local openssl_output
            openssl_output="$(openssl genpkey -algorithm x25519 -text 2>/dev/null)"
            # Extract private key hex lines (after "priv:" line until blank line or "pub:")
            local priv_hex pub_hex
            priv_hex="$(echo "${openssl_output}" | awk '/^priv:/{flag=1; next} /^pub:/{flag=0} flag && /^[[:space:]]*[0-9a-fA-F:]+$/{gsub(/[[:space:]:]/,""); printf "%s", $0}')"
            pub_hex="$(echo "${openssl_output}" | awk '/^pub:/{flag=1; next} flag && /^[[:space:]]*[0-9a-fA-F:]+$/{gsub(/[[:space:]:]/,""); printf "%s", $0}')"
            # Convert hex to binary then base64
            private_key="$(echo "${priv_hex}" | xxd -r -p | base64)"
            public_key="$(echo "${pub_hex}" | xxd -r -p | base64)"
        else
            log_error "Cannot generate Reality keys: neither xray nor openssl found."
            log_error "Please install xray-core or openssl, or provide PRIVATE_KEY and PUBLIC_KEY manually."
            exit 1
        fi
        
        # Validate generated keys are non-empty base64 strings
        if [[ -z "${private_key}" || -z "${public_key}" ]]; then
            log_error "Failed to generate Reality keys (empty output)."
            exit 1
        fi
        
        # Set and export variables
        export PRIVATE_KEY="${PRIVATE_KEY:-$private_key}"
        export PUBLIC_KEY="${PUBLIC_KEY:-$public_key}"
        
        log_info "Generated Reality private key: ${PRIVATE_KEY}"
        log_info "Generated Reality public key: ${PUBLIC_KEY}"
    }
    
    # Generate short IDs for Reality
    # Sets SHORT_IDS if empty
    generate_short_ids() {
        # If SHORT_IDS already set, skip generation
        if [[ -n "${SHORT_IDS:-}" ]]; then
            log_info "Short IDs already provided, skipping generation."
            return 0
        fi
        
        log_info "Generating Reality short IDs..."
        
        # Generate 2 random hex strings of length 8 (typical Reality usage)
        local id1 id2
        id1="$(openssl rand -hex 4 2>/dev/null || od -An -N4 -tx4 /dev/urandom 2>/dev/null | tr -d ' ')"
        id2="$(openssl rand -hex 4 2>/dev/null || od -An -N4 -tx4 /dev/urandom 2>/dev/null | tr -d ' ')"
        
        # Ensure we got output
        if [[ -z "${id1}" || -z "${id2}" ]]; then
            log_error "Failed to generate short IDs."
            exit 1
        fi
        
        export SHORT_IDS="${id1},${id2}"
        log_info "Generated short IDs: ${SHORT_IDS}"
    }
    
    # Validate Reality parameters (wrapper for validation functions)
    validate_reality_params() {
        log_info "Validating Reality parameters..."
        
        validate_server_names "SERVER_NAMES"
        validate_dest "DEST"
        validate_short_ids "SHORT_IDS"
        
        # Validate keys are base64 encoded 32-byte strings (basic check)
        if [[ -n "${PRIVATE_KEY:-}" ]]; then
            if ! echo "${PRIVATE_KEY}" | base64 -d 2>/dev/null | head -c32 | wc -c | grep -q 32; then
                die "PRIVATE_KEY is not a valid base64-encoded 32-byte string."
            fi
        fi
        if [[ -n "${PUBLIC_KEY:-}" ]]; then
            if ! echo "${PUBLIC_KEY}" | base64 -d 2>/dev/null | head -c32 | wc -c | grep -q 32; then
                die "PUBLIC_KEY is not a valid base64-encoded 32-byte string."
            fi
        fi
        
        log_success "Reality parameters validation passed."
    }
    
    # Export functions for use in other scripts
    export -f generate_reality_keys generate_short_ids validate_reality_params
    
    # If script is executed directly (not sourced), run a simple test
    if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
        log_info "Testing Reality utilities..."
        # Set dummy values for required validation parameters
        SERVER_NAMES="example.com"
        DEST="example.com:443"
        export SERVER_NAMES DEST
        generate_reality_keys
        generate_short_ids
        validate_reality_params
        log_success "All Reality utilities working."
    fi
fi