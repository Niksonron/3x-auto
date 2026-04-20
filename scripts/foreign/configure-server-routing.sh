#!/usr/bin/env bash
# Server-side fallback routing configuration script for 3x-ui VPN automation
# Creates routing rules to handle misclassified RU traffic (geoip:ru, geosite:ru) on foreign server.

set -euo pipefail

# Check if functions already defined to allow idempotent sourcing
if ! command -v configure_server_routing >/dev/null 2>&1; then
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
    # 3x-ui API Authentication Functions (identical to other scripts)
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
    # Routing Management Functions
    # ------------------------------------------------------------------------
    
    # Get current routing configuration from 3x-ui panel
    # Returns JSON string on success, empty string on failure
    # Usage: get_routing_config
    get_routing_config() {
        log_info "Fetching current routing configuration..."
        
        local panel_url="http://127.0.0.1:${PANEL_PORT:-2053}"
        local routing_url="${panel_url}/panel/api/routing/list"
        
        # Ensure authentication is done
        if [[ -z "${SESSION_COOKIE:-}" ]]; then
            authenticate_to_panel
        fi
        
        # Fetch routing config
        local response
        response=$(curl -s -f --max-time 10 -b "${COOKIE_JAR}" "${routing_url}" 2>&1 || true)
        
        if [[ -z "${response}" ]]; then
            log_error "Failed to fetch routing configuration"
            echo ""
            return 1
        fi
        
        # Check if response indicates routing endpoint not found
        if echo "${response}" | grep -q "404" 2>/dev/null; then
            log_warning "Routing API endpoint not found (404). Routing configuration may not be supported."
            echo ""
            return 2
        fi
        
        echo "${response}"
        return 0
    }
    
    # Update routing configuration via 3x-ui API
    # Usage: update_routing_config <json_payload>
    update_routing_config() {
        local payload="$1"
        log_info "Updating routing configuration via 3x-ui API..."
        
        local panel_url="http://127.0.0.1:${PANEL_PORT:-2053}"
        local update_url="${panel_url}/panel/api/routing/update"
        
        # Ensure authentication is done
        if [[ -z "${SESSION_COOKIE:-}" ]]; then
            authenticate_to_panel
        fi
        
        log_info "Sending payload to ${update_url}"
        log_info "Payload: ${payload}"
        
        # Send POST request
        local response
        response=$(curl -s -f --max-time 30 -b "${COOKIE_JAR}" \
            -X POST \
            -H "Content-Type: application/json" \
            -d "${payload}" \
            "${update_url}" 2>&1 || true)
        
        # Check response
        if [[ -n "${response}" ]]; then
            log_info "API response: ${response}"
            # Check for success indicator (adjust based on actual API response)
            if echo "${response}" | grep -q "\"success\":true" 2>/dev/null; then
                log_success "Routing configuration updated successfully"
                return 0
            elif echo "${response}" | grep -q "already exists" 2>/dev/null; then
                log_info "Routing configuration already applied (according to API)"
                return 0
            else
                log_error "Failed to update routing configuration. Response: ${response}"
                return 1
            fi
        else
            log_error "No response from API"
            return 1
        fi
    }
    
    # Build JSON payload for server-side fallback routing
    # Usage: build_routing_payload
    # Outputs JSON string
    build_routing_payload() {
        # Determine default outbound tag
        local default_outbound="direct-outbound"
        if [[ "${ENABLE_WARP:-false}" == "true" ]]; then
            default_outbound="warp-outbound"
        fi
        
        cat <<EOF
{
  "domainStrategy": "AsIs",
  "rules": [
    {
      "type": "field",
      "ip": ["geoip:ru"],
      "outboundTag": "direct-outbound"
    },
    {
      "type": "field",
      "domain": ["geosite:ru"],
      "outboundTag": "direct-outbound"
    },
    {
      "type": "field",
      "port": "0-65535",
      "outboundTag": "${default_outbound}"
    }
  ]
}
EOF
    }
    
    # Check if routing configuration already contains a geoip:ru rule
    # Usage: has_routing_rule <json_config>
    # Returns 0 if rule found, 1 otherwise
    has_routing_rule() {
        local config="$1"
        if [[ -z "${config}" ]]; then
            return 1
        fi
        # Simple check for geoip:ru presence (case-insensitive)
        if echo "${config}" | grep -iq '\"geoip:ru\"'; then
            log_info "Existing geoip:ru rule found in routing configuration"
            return 0
        fi
        return 1
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
    
    # Main function to configure server-side fallback routing
    # Usage: configure_server_routing
    configure_server_routing() {
        log_info "Starting server-side fallback routing configuration"
        
        # Setup trap for cleanup
        setup_trap 'cleanup_resources; log_error "Routing configuration failed. Check logs for details."'
        
        # Load configuration (ensures variables are exported)
        load_config
        
        # Check if panel is accessible
        if ! is_panel_accessible; then
            die "3x-ui panel not accessible. Ensure 3x-ui is installed and running."
        fi
        
        # Get current routing configuration
        local current_config
        current_config="$(get_routing_config)"
        local get_status=$?
        
        # If endpoint not found (status 2), skip configuration with warning
        if [[ ${get_status} -eq 2 ]]; then
            log_warning "Routing API endpoint not available. Skipping server-side routing configuration."
            log_warning "This is expected if 3x-ui does not expose routing API. Fallback routing will not be applied."
            log_success "Server-side routing configuration skipped (API not available)"
            return 0
        fi
        
        # If we cannot fetch config (other error) and status != 0, assume failure
        if [[ ${get_status} -ne 0 ]]; then
            log_error "Failed to retrieve routing configuration"
            return 1
        fi
        
        # Check if routing rule already exists
        if has_routing_rule "${current_config}"; then
            log_info "Server-side fallback routing already configured, skipping update."
            cleanup_resources
            log_success "Server-side routing configuration already present"
            return 0
        fi
        
        # Build new routing payload
        log_info "Building routing payload..."
        local routing_payload
        routing_payload="$(build_routing_payload)"
        
        # Update routing configuration
        if update_routing_config "${routing_payload}"; then
            cleanup_resources
            log_success "Server-side fallback routing configuration completed successfully"
            log_info "Rules added: geoip:ru → direct-outbound, geosite:ru → direct-outbound, default → ${default_outbound:-direct-outbound}"
            return 0
        else
            log_error "Failed to update routing configuration"
            cleanup_resources
            return 1
        fi
    }
    
    # Export functions for use in other scripts
    export -f is_panel_accessible authenticate_to_panel get_routing_config \
             update_routing_config build_routing_payload has_routing_rule \
             configure_server_routing
    
    # If script is executed directly (not sourced), run configure_server_routing
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
        configure_server_routing
    fi
fi