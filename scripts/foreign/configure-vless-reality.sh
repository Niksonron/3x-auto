#!/usr/bin/env bash
# VLESS+Reality configuration script for 3x-ui VPN automation
# Creates VLESS inbound with Reality security via 3x-ui API.

set -euo pipefail

# Check if functions already defined to allow idempotent sourcing
if ! command -v configure_vless_reality >/dev/null 2>&1; then
    # Determine script directory to source dependencies
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    
    # Source logging utilities
    # shellcheck source=../common/logging.sh
    source "${SCRIPT_DIR}/../common/logging.sh"
    
    # Source OS detection utilities (optional, for package installation)
    # shellcheck source=../common/os-detection.sh
    source "${SCRIPT_DIR}/../common/os-detection.sh"
    
    # Source configuration loading utilities
    # shellcheck source=../common/load-config.sh
    source "${SCRIPT_DIR}/../common/load-config.sh"
    
    # Source configuration validation utilities
    # shellcheck source=../common/validate-config.sh
    source "${SCRIPT_DIR}/../common/validate-config.sh"
    
    # ------------------------------------------------------------------------
    # 3x-ui API Authentication Functions
    # ------------------------------------------------------------------------
    
    # Check if 3x-ui panel is accessible
    # Returns 0 if panel responds, 1 otherwise
    is_panel_accessible() {
        local panel_url="http://127.0.0.1:${PANEL_PORT:-2053}"
        if curl -s -f --max-time 5 "${panel_url}" >/dev/null 2>&1; then
            log_info "3x-ui panel is accessible at ${panel_url}"
            return 0
        else
            log_error "3x-ui panel not accessible at ${panel_url}"
            return 1
        fi
    }
    
    # Authenticate to 3x-ui panel and obtain session cookie
    # Sets global COOKIE_JAR file path and SESSION_COOKIE variable
    # Usage: authenticate_to_panel
    authenticate_to_panel() {
        log_info "Authenticating to 3x-ui panel..."
        
        local panel_url="http://127.0.0.1:${PANEL_PORT:-2053}"
        local login_url="${panel_url}/login"
        local login_payload
        
        # Use default username "admin" if PANEL_USERNAME not set
        local username="${PANEL_USERNAME:-admin}"
        local password="${PANEL_PASSWORD:-}"
        
        if [[ -z "${password}" ]]; then
            die "PANEL_PASSWORD is required for 3x-ui authentication. Please set it in .env or use installer-generated password."
        fi
        
        # Create temporary cookie jar
        COOKIE_JAR="$(mktemp)"
        log_info "Using cookie jar: ${COOKIE_JAR}"
        
        # Construct login payload (3x-ui expects username and password)
        login_payload="username=${username}&password=${password}"
        
        # Perform login request
        local login_response
        login_response=$(curl -s -c "${COOKIE_JAR}" -b "${COOKIE_JAR}" -X POST \
            -H "Content-Type: application/x-www-form-urlencoded" \
            -d "${login_payload}" \
            "${login_url}" 2>&1 || true)
        
        # Check if login succeeded (look for session cookie)
        if grep -q "session=" "${COOKIE_JAR}" 2>/dev/null; then
            log_success "Authentication successful"
            SESSION_COOKIE="session=$(grep "session" "${COOKIE_JAR}" | awk '{print $NF}')"
            export SESSION_COOKIE
        else
            log_error "Authentication failed. Check credentials."
            log_error "Response: ${login_response}"
            rm -f "${COOKIE_JAR}"
            exit 1
        fi
    }
    
    # ------------------------------------------------------------------------
    # Inbound Management Functions
    # ------------------------------------------------------------------------
    
    # Check if inbound already exists on given port
    # Returns 0 if inbound exists, 1 otherwise
    # Usage: inbound_exists <port>
    inbound_exists() {
        local port="$1"
        log_info "Checking if inbound exists on port ${port}..."
        
        local panel_url="http://127.0.0.1:${PANEL_PORT:-2053}"
        local list_url="${panel_url}/panel/api/inbounds/list"
        
        # Ensure authentication is done
        if [[ -z "${SESSION_COOKIE:-}" ]]; then
            authenticate_to_panel
        fi
        
        # Fetch inbound list
        local response
        response=$(curl -s -f --max-time 10 -b "${COOKIE_JAR}" "${list_url}" 2>&1 || true)
        
        if [[ -z "${response}" ]]; then
            log_error "Failed to fetch inbound list"
            return 1
        fi
        
        # Check if response contains the port (basic check)
        if echo "${response}" | grep -q "\"port\":${port}" 2>/dev/null; then
            log_info "Inbound found on port ${port}"
            return 0
        else
            log_info "No inbound found on port ${port}"
            return 1
        fi
    }
    
    # Construct JSON payload for VLESS+Reality inbound
    # Usage: build_inbound_payload
    # Outputs JSON string
    build_inbound_payload() {
        # Validate required Reality parameters
        validate_required "SERVER_NAMES"
        validate_required "DEST"
        validate_required "SHORT_IDS"
        validate_required "PRIVATE_KEY"
        validate_required "PUBLIC_KEY"
        
        # Format serverNames as JSON array
        local server_names_json="["
        local IFS=','
        local domains
        read -ra domains <<< "${SERVER_NAMES}"
        for domain in "${domains[@]}"; do
            domain="${domain#"${domain%%[![:space:]]*}"}"
            domain="${domain%"${domain##*[![:space:]]}"}"
            server_names_json="${server_names_json}\"${domain}\","
        done
        # Remove trailing comma and close array
        server_names_json="${server_names_json%,}]"
        
        # Format shortIds as JSON array
        local short_ids_json="["
        local ids
        read -ra ids <<< "${SHORT_IDS}"
        for id in "${ids[@]}"; do
            id="${id#"${id%%[![:space:]]*}"}"
            id="${id%"${id##*[![:space:]]}"}"
            short_ids_json="${short_ids_json}\"${id}\","
        done
        short_ids_json="${short_ids_json%,}]"
        
        # Build settings JSON (clients array)
        local settings_json="{\"clients\":[{\"id\":\"${UUID}\",\"flow\":\"\",\"email\":\"default\"}]}"
        
        # Build streamSettings JSON
        local stream_settings_json="{\"network\":\"tcp\",\"security\":\"reality\",\"realitySettings\":{\"serverNames\":${server_names_json},\"dest\":\"${DEST}\",\"shortIds\":${short_ids_json},\"privateKey\":\"${PRIVATE_KEY}\",\"publicKey\":\"${PUBLIC_KEY}\"}}"
        
        # Build full inbound JSON payload
        local payload="{\"listen\":\"0.0.0.0\",\"port\":${VLESS_PORT},\"protocol\":\"vless\",\"settings\":${settings_json},\"streamSettings\":${stream_settings_json},\"tag\":\"inbound-${VLESS_PORT}\",\"sniffing\":{\"enabled\":true,\"destOverride\":[\"http\",\"tls\"]}}"
        
        echo "${payload}"
    }
    
    # Add inbound via 3x-ui API
    # Usage: add_inbound <json_payload>
    add_inbound() {
        local payload="$1"
        log_info "Adding inbound via 3x-ui API..."
        
        local panel_url="http://127.0.0.1:${PANEL_PORT:-2053}"
        local add_url="${panel_url}/panel/api/inbounds/add"
        
        # Ensure authentication is done
        if [[ -z "${SESSION_COOKIE:-}" ]]; then
            authenticate_to_panel
        fi
        
        log_info "Sending payload to ${add_url}"
        log_info "Payload: ${payload}"
        
        # Send POST request
        local response
        response=$(curl -s -f --max-time 30 -b "${COOKIE_JAR}" \
            -X POST \
            -H "Content-Type: application/json" \
            -d "${payload}" \
            "${add_url}" 2>&1 || true)
        
        # Check response
        if [[ -n "${response}" ]]; then
            log_info "API response: ${response}"
            # Check for success indicator (adjust based on actual API response)
            if echo "${response}" | grep -q "\"success\":true" 2>/dev/null; then
                log_success "Inbound added successfully"
                return 0
            elif echo "${response}" | grep -q "already exists" 2>/dev/null; then
                log_info "Inbound already exists (according to API)"
                return 0
            else
                log_error "Failed to add inbound. Response: ${response}"
                return 1
            fi
        else
            log_error "No response from API"
            return 1
        fi
    }
    
    # Verify inbound appears in list after creation
    # Usage: verify_inbound_added <port>
    verify_inbound_added() {
        local port="$1"
        log_info "Verifying inbound on port ${port} appears in list..."
        
        # Wait a moment for the panel to update
        sleep 2
        
        if inbound_exists "${port}"; then
            log_success "Inbound verification passed"
            return 0
        else
            log_error "Inbound verification failed - inbound not found after creation"
            return 1
        fi
    }
    
    # ------------------------------------------------------------------------
    # Cleanup Function
    # ------------------------------------------------------------------------
    
    # Cleanup temporary files (cookie jar)
    # Usage: cleanup_resources
    cleanup_resources() {
        if [[ -n "${COOKIE_JAR:-}" && -f "${COOKIE_JAR}" ]]; then
            rm -f "${COOKIE_JAR}"
            log_info "Cleaned up cookie jar: ${COOKIE_JAR}"
        fi
    }
    
    # ------------------------------------------------------------------------
    # Main Configuration Function
    # ------------------------------------------------------------------------
    
    # Main function to configure VLESS+Reality inbound
    # Usage: configure_vless_reality
    configure_vless_reality() {
        log_info "Starting VLESS+Reality configuration"
        
        # Setup trap for cleanup
        setup_trap 'cleanup_resources; log_error "VLESS+Reality configuration failed. Check logs for details."'
        
        # Load configuration (ensures variables are exported)
        load_config
        
        # Validate required parameters (already done by load_config, but double-check)
        validate_required "VLESS_PORT"
        validate_required "UUID"
        
        # Check if panel is accessible
        if ! is_panel_accessible; then
            die "3x-ui panel not accessible. Ensure 3x-ui is installed and running."
        fi
        
        # Check if inbound already exists
        if inbound_exists "${VLESS_PORT}"; then
            log_info "VLESS+Reality inbound already exists on port ${VLESS_PORT}, skipping creation."
            return 0
        fi
        
        # Build inbound payload
        local payload
        payload="$(build_inbound_payload)"
        
        # Add inbound
        if add_inbound "${payload}"; then
            # Verify inbound added
            verify_inbound_added "${VLESS_PORT}"
        else
            die "Failed to add inbound"
        fi
        
        # Cleanup cookie jar
        cleanup_resources
        
        log_success "VLESS+Reality configuration completed successfully"
        log_info "VLESS inbound created on port ${VLESS_PORT} with Reality security"
    }
    
    # Export functions for use in other scripts
    export -f is_panel_accessible authenticate_to_panel inbound_exists \
             build_inbound_payload add_inbound verify_inbound_added configure_vless_reality
    
    # If script is executed directly (not sourced), run configure_vless_reality
    if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
        # Load configuration (assumes .env in project root)
        SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
        CONFIG_FILE="$(cd "${SCRIPT_DIR}/../.." && pwd)/.env"
        if [[ -f "${CONFIG_FILE}" ]]; then
            # shellcheck source=/dev/null
            source "${CONFIG_FILE}"
        else
            log_error "Configuration file not found: ${CONFIG_FILE}"
            log_error "Copy .env.example to .env and fill in required parameters."
            exit 1
        fi
        
        # Run configuration
        configure_vless_reality
    fi
fi