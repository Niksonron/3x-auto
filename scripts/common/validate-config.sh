#!/usr/bin/env bash
# Configuration validation utilities for 3x-ui VPN automation
# Source this file in your bash scripts to validate configuration parameters.

set -euo pipefail

# Check if functions already defined to allow idempotent sourcing
if ! command -v validate_config >/dev/null 2>&1; then
    # Determine script directory to source dependencies
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    
    # Source logging utilities
    # shellcheck source=logging.sh
    source "${SCRIPT_DIR}/logging.sh"
    
    # Source OS detection utilities (optional, for future compatibility)
    # shellcheck source=os-detection.sh
    source "${SCRIPT_DIR}/os-detection.sh"
    
    # ------------------------------------------------------------------------
    # Validation Functions
    # ------------------------------------------------------------------------
    
    # Validate that a required variable is set (non-empty)
    # Usage: validate_required "VAR_NAME"
    validate_required() {
        local var_name="$1"
        local var_value="${!var_name:-}"
        
        if [[ -z "${var_value}" ]]; then
            die "Configuration error: ${var_name} is required but empty or not set."
        fi
    }
    
    # Validate IPv4 address format (basic regex)
    # Usage: validate_ip "VAR_NAME"
    validate_ip() {
        local var_name="$1"
        local var_value="${!var_name:-}"
        
        # IPv4 regex validating octet ranges 0-255
        local ipv4_regex='^((25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)$'
        
        if [[ ! "${var_value}" =~ ${ipv4_regex} ]]; then
            die "Configuration error: ${var_name} must be a valid IPv4 address (got: '${var_value}')."
        fi
    }
    
    # Validate port number (1-65535)
    # Usage: validate_port "VAR_NAME"
    validate_port() {
        local var_name="$1"
        local var_value="${!var_name:-}"
        
        # Check if it's a positive integer
        if [[ ! "${var_value}" =~ ^[0-9]+$ ]]; then
            die "Configuration error: ${var_name} must be a numeric port (got: '${var_value}')."
        fi
        
        # Check range
        if (( var_value < 1 || var_value > 65535 )); then
            die "Configuration error: ${var_name} must be between 1 and 65535 (got: ${var_value})."
        fi
    }
    
    # Validate UUID format (RFC 4122 version 4)
    # Usage: validate_uuid "VAR_NAME"
    validate_uuid() {
        local var_name="$1"
        local var_value="${!var_name:-}"
        
        local uuid_regex='^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
        
        if [[ ! "${var_value}" =~ ${uuid_regex} ]]; then
            die "Configuration error: ${var_name} must be a valid UUID v4 (got: '${var_value}')."
        fi
    }
    
    # Validate domain name format (basic validation)
    # Usage: validate_domain "VAR_NAME"
    validate_domain() {
        local var_name="$1"
        local var_value="${!var_name:-}"
        
        # Basic domain regex: letters, digits, hyphens, dots; at least one dot
        local domain_regex='^([a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$'
        
        if [[ ! "${var_value}" =~ ${domain_regex} ]]; then
            die "Configuration error: ${var_name} must be a valid domain name (got: '${var_value}')."
        fi
    }
    # Validate SERVER_NAMES (comma-separated domain list)
    # Usage: validate_server_names "VAR_NAME"
    validate_server_names() {
        local var_name="$1"
        local var_value="${!var_name:-}"
        
        # Split by comma, trim spaces
        local IFS=','
        local domains
        read -ra domains <<< "${var_value}"
        
        for domain in "${domains[@]}"; do
            domain="${domain#"${domain%%[![:space:]]*}"}"
            domain="${domain%"${domain##*[![:space:]]}"}"
            if [[ -z "${domain}" ]]; then
                die "Configuration error: ${var_name} contains empty domain entry."
            fi
            local domain_regex='^([a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$'
            if [[ ! "${domain}" =~ ${domain_regex} ]]; then
                die "Configuration error: ${var_name} contains invalid domain '${domain}'."
            fi
        done
    }
    
    # Validate DEST (domain:port format)
    # Usage: validate_dest "VAR_NAME"
    validate_dest() {
        local var_name="$1"
        local var_value="${!var_name:-}"
        
        # Check format domain:port
        if [[ ! "${var_value}" =~ ^([^:]+):([0-9]+)$ ]]; then
            die "Configuration error: ${var_name} must be in format 'domain:port' (got: '${var_value}')."
        fi
        
        local domain="${BASH_REMATCH[1]}"
        local port="${BASH_REMATCH[2]}"
        
        # Validate domain (allow domain or IP)
        local domain_regex='^([a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$'
        local ip_regex='^((25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)$'
        if [[ ! "${domain}" =~ ${domain_regex} ]] && [[ ! "${domain}" =~ ${ip_regex} ]]; then
            die "Configuration error: ${var_name} domain part must be a valid domain or IPv4 address (got: '${domain}')."
        fi
        
        # Validate port range
        if (( port < 1 || port > 65535 )); then
            die "Configuration error: ${var_name} port must be between 1 and 65535 (got: ${port})."
        fi
    }
    
    # Validate SHORT_IDS (optional comma-separated hex strings)
    # Usage: validate_short_ids "VAR_NAME"
    validate_short_ids() {
        local var_name="$1"
        local var_value="${!var_name:-}"
        
        # If empty, skip validation (will be auto-generated)
        if [[ -z "${var_value}" ]]; then
            return 0
        fi
        
        local IFS=','
        local ids
        read -ra ids <<< "${var_value}"
        
        for id in "${ids[@]}"; do
            id="${id#"${id%%[![:space:]]*}"}"
            id="${id%"${id##*[![:space:]]}"}"
            if [[ -z "${id}" ]]; then
                die "Configuration error: ${var_name} contains empty shortId entry."
            fi
            # 1-8 hex characters
            if [[ ! "${id}" =~ ^[0-9a-fA-F]{1,8}$ ]]; then
                die "Configuration error: ${var_name} contains invalid shortId '${id}' (must be 1-8 hex characters)."
            fi
        done
    }
    
    # Validate boolean (true/false) value
    # Usage: validate_boolean "VAR_NAME"
    validate_boolean() {
        local var_name="$1"
        local var_value="${!var_name:-}"
        
        # If empty, treat as false (default)
        if [[ -z "${var_value}" ]]; then
            return 0
        fi
        
        if [[ "${var_value}" != "true" && "${var_value}" != "false" ]]; then
            die "Configuration error: ${var_name} must be 'true' or 'false' (got: '${var_value}')."
        fi
    }

    # ------------------------------------------------------------------------
    # Main Validation Function
    # ------------------------------------------------------------------------
    
    # Validate all required configuration parameters
    # Usage: validate_config
    validate_config() {
        log_info "Validating configuration parameters..."
        
        # Required server IPs
        validate_required "RU_RELAY_IP"
        validate_ip "RU_RELAY_IP"
        validate_required "FOREIGN_VPS_IP"
        validate_ip "FOREIGN_VPS_IP"
        
        # SSH configuration
        validate_required "SSH_USER"
        validate_required "SSH_PUBLIC_KEY"
        
        # VLESS protocol
        validate_required "VLESS_PORT"
        validate_port "VLESS_PORT"
        validate_required "UUID"
        validate_uuid "UUID"
        
        # Transport and security (fixed values)
        if [[ "${TRANSPORT:-TCP}" != "TCP" ]]; then
            die "Configuration error: TRANSPORT must be 'TCP' (got: '${TRANSPORT:-}')."
        fi
        if [[ "${SECURITY:-reality}" != "reality" ]]; then
            die "Configuration error: SECURITY must be 'reality' (got: '${SECURITY:-}')."
        fi
        
        # Reality parameters
        validate_required "SERVER_NAMES"
        validate_server_names "SERVER_NAMES"
        validate_dest "DEST"
        # Optional: SHORT_IDS, PRIVATE_KEY, PUBLIC_KEY can be empty (will be generated)
        validate_short_ids "SHORT_IDS"
        
        # Optional features validation
        validate_boolean "ENABLE_WARP"
        validate_boolean "ENABLE_REVERSE_PROXY"
        
        # Domain validation if reverse proxy enabled
        if [[ "${ENABLE_REVERSE_PROXY:-false}" == "true" ]]; then
            validate_required "DOMAIN"
            validate_domain "DOMAIN"
        fi
        
        log_success "Configuration validation passed."
    }
    
    # Export functions for use in other scripts
    export -f validate_required validate_ip validate_port validate_uuid validate_domain validate_server_names validate_dest validate_short_ids validate_boolean validate_config
    
    # If script is executed directly (not sourced), run validation
    if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
        validate_config
    fi
fi