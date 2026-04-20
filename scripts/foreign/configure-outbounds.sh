#!/usr/bin/env bash
# Outbound routing configuration script for 3x-ui VPN automation
# Creates direct and WARP outbound routes via 3x-ui API.

set -euo pipefail

# Check if functions already defined to allow idempotent sourcing
if ! command -v configure_outbounds >/dev/null 2>&1; then
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
    # 3x-ui API Authentication Functions (reuse from configure-vless-reality.sh)
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
    # Outbound Management Functions
    # ------------------------------------------------------------------------
    
    # Check if outbound already exists with given tag
    # Returns 0 if outbound exists, 1 otherwise
    # Usage: outbound_exists <tag>
    outbound_exists() {
        local tag="$1"
        log_info "Checking if outbound exists with tag '${tag}'..."
        
        local panel_url="http://127.0.0.1:${PANEL_PORT:-2053}"
        local list_url="${panel_url}/panel/api/outbounds/list"
        
        # Ensure authentication is done
        if [[ -z "${SESSION_COOKIE:-}" ]]; then
            authenticate_to_panel
        fi
        
        # Fetch outbound list
        local response
        response=$(curl -s -f --max-time 10 -b "${COOKIE_JAR}" "${list_url}" 2>&1 || true)
        
        if [[ -z "${response}" ]]; then
            log_error "Failed to fetch outbound list"
            return 1
        fi
        
        # Check if response contains the tag (basic check)
        if echo "${response}" | grep -q "\"tag\":\"${tag}\"" 2>/dev/null; then
            log_info "Outbound found with tag '${tag}'"
            return 0
        else
            log_info "No outbound found with tag '${tag}'"
            return 1
        fi
    }
    
    # Build JSON payload for direct outbound
    # Usage: build_direct_outbound_payload
    # Outputs JSON string
    build_direct_outbound_payload() {
        echo '{"protocol":"freedom","tag":"direct-outbound","settings":{}}'
    }
    
    # Build JSON payload for WARP outbound
    # Usage: build_warp_outbound_payload
    # Outputs JSON string
    build_warp_outbound_payload() {
        echo '{"protocol":"freedom","tag":"warp-outbound","settings":{},"streamSettings":{"sockopt":{"interface":"wgcf"}}}'
    }
    
    # Add outbound via 3x-ui API
    # Usage: add_outbound <json_payload>
    add_outbound() {
        local payload="$1"
        log_info "Adding outbound via 3x-ui API..."
        
        local panel_url="http://127.0.0.1:${PANEL_PORT:-2053}"
        local add_url="${panel_url}/panel/api/outbounds/add"
        
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
                log_success "Outbound added successfully"
                return 0
            elif echo "${response}" | grep -q "already exists" 2>/dev/null; then
                log_info "Outbound already exists (according to API)"
                return 0
            else
                log_error "Failed to add outbound. Response: ${response}"
                return 1
            fi
        else
            log_error "No response from API"
            return 1
        fi
    }
    
    # Verify outbound appears in list after creation
    # Usage: verify_outbound_added <tag>
    verify_outbound_added() {
        local tag="$1"
        log_info "Verifying outbound with tag '${tag}' appears in list..."
        
        # Wait a moment for the panel to update
        sleep 2
        
        if outbound_exists "${tag}"; then
            log_success "Outbound verification passed"
            return 0
        else
            log_error "Outbound verification failed - outbound not found after creation"
            return 1
        fi
    }
    
    # Test outbound connectivity by checking external IP
    # For direct outbound, use default route.
    # For WARP outbound, bind to wgcf interface.
    # Usage: test_outbound_connectivity <tag> <description>
    test_outbound_connectivity() {
        local tag="$1"
        local description="$2"
        log_info "Testing ${description} outbound connectivity..."
        
        # Determine interface based on tag
        local interface=""
        local ip_service="https://api.ipify.org"
        local curl_timeout=10
        local curl_cmd="curl -s --max-time ${curl_timeout}"
        
        case "${tag}" in
            "warp-outbound")
                # Check if WARP interface exists
                if ! ip link show wgcf >/dev/null 2>&1; then
                    log_error "WARP interface wgcf not found, cannot test WARP outbound"
                    return 1
                fi
                interface="wgcf"
                ;;
            "direct-outbound")
                # No interface binding
                ;;
            *)
                log_error "Unknown outbound tag: ${tag}"
                return 1
                ;;
        esac
        
        # Build curl command
        if [[ -n "${interface}" ]]; then
            curl_cmd="${curl_cmd} --interface ${interface}"
        fi
        
        # Perform IP check
        log_info "Checking external IP via ${ip_service}"
        local external_ip
        external_ip=$(${curl_cmd} "${ip_service}" 2>&1 || true)
        
        if [[ -z "${external_ip}" ]] || [[ "${external_ip}" =~ "curl:" ]]; then
            log_error "Failed to get external IP for ${description} outbound: ${external_ip}"
            return 1
        else
            log_success "${description} outbound test passed. External IP: ${external_ip}"
            return 0
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
    
    # Main function to configure direct and WARP outbounds
    # Usage: configure_outbounds
    configure_outbounds() {
        log_info "Starting outbound routing configuration"
        
        # Setup trap for cleanup
        setup_trap 'cleanup_resources; log_error "Outbound configuration failed. Check logs for details."'
        
        # Load configuration (ensures variables are exported)
        load_config
        
        # Check if panel is accessible
        if ! is_panel_accessible; then
            die "3x-ui panel not accessible. Ensure 3x-ui is installed and running."
        fi
        
        # Create direct outbound
        if outbound_exists "direct-outbound"; then
            log_info "Direct outbound already exists, skipping creation."
        else
            log_info "Creating direct outbound..."
            local direct_payload
            direct_payload="$(build_direct_outbound_payload)"
            if add_outbound "${direct_payload}"; then
                verify_outbound_added "direct-outbound"
            else
                log_error "Failed to add direct outbound"
                exit 1
            fi
        fi
        
        # Create WARP outbound if enabled
        if [[ "${ENABLE_WARP:-false}" == "true" ]]; then
            log_info "WARP enabled, configuring WARP outbound..."
            # Verify WARP interface exists
            if ! ip link show wgcf >/dev/null 2>&1; then
                log_warning "WARP interface wgcf not found. WARP may not be connected. Skipping WARP outbound."
                return 0
            fi
            
            if outbound_exists "warp-outbound"; then
                log_info "WARP outbound already exists, skipping creation."
            else
                log_info "Creating WARP outbound..."
                local warp_payload
                warp_payload="$(build_warp_outbound_payload)"
                if add_outbound "${warp_payload}"; then
                    verify_outbound_added "warp-outbound"
                else
                    log_error "Failed to add WARP outbound"
                    # Non-fatal error, continue
                fi
            fi
        else
            log_info "WARP not enabled, skipping WARP outbound."
        fi
        
        # Test outbound connectivity
        if ! test_outbound_connectivity "direct-outbound" "direct"; then
            log_info "[WARNING] Direct outbound connectivity test failed, but configuration may still work."
        fi
        if [[ "${ENABLE_WARP:-false}" == "true" ]]; then
            if ! test_outbound_connectivity "warp-outbound" "WARP"; then
                log_info "[WARNING] WARP outbound connectivity test failed, but configuration may still work."
            fi
        fi
        
        # Cleanup cookie jar
        cleanup_resources
        
        log_success "Outbound routing configuration completed successfully"
        log_info "Direct outbound created (tag: direct-outbound)"
        if [[ "${ENABLE_WARP:-false}" == "true" ]]; then
            log_info "WARP outbound created (tag: warp-outbound)"
        fi
    }
    
    # Export functions for use in other scripts
    export -f is_panel_accessible authenticate_to_panel outbound_exists \
             build_direct_outbound_payload build_warp_outbound_payload add_outbound \
             verify_outbound_added test_outbound_connectivity configure_outbounds
    
    # If script is executed directly (not sourced), run configure_outbounds
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
        configure_outbounds
    fi
fi