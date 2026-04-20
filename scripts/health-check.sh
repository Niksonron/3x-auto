#!/usr/bin/env bash
# Health-check script for 3x-ui VPN automation
# Verifies infrastructure health after deployment.
#
# Inputs:
#   - .env configuration file (required parameters: RU_RELAY_IP, FOREIGN_VPS_IP, SSH_USER, etc.)
#   - SSH key authentication to both servers (already configured by installation)
# Outputs:
#   - Comprehensive health report printed to stdout
#   - Exit code 0 if all critical checks pass, 1 otherwise
# Usage:
#   ./scripts/health-check.sh [--relay|--foreign|--all|--help]

set -euo pipefail

# Check if functions already defined to allow idempotent sourcing
if ! command -v health_check_all >/dev/null 2>&1; then
    # Determine script directory to source dependencies
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    
    # Source logging utilities
    # shellcheck source=common/logging.sh
    source "${SCRIPT_DIR}/common/logging.sh"
    
    # Source OS detection utilities (optional, for package detection)
    # shellcheck source=common/os-detection.sh
    source "${SCRIPT_DIR}/common/os-detection.sh"
    
    # Source configuration loading utilities
    # shellcheck source=common/load-config.sh
    source "${SCRIPT_DIR}/common/load-config.sh"
    
    # Source configuration validation utilities
    # shellcheck source=common/validate-config.sh
    # source "${SCRIPT_DIR}/common/validate-config.sh"  # Already sourced by load-config.sh
    
    # ------------------------------------------------------------------------
    # Global variables and defaults
    # ------------------------------------------------------------------------
    HEALTH_CHECK_RESULTS=()
    CRITICAL_FAILURE=0
    
    # ------------------------------------------------------------------------
    # Remote execution helper
    # ------------------------------------------------------------------------
    run_remote() {
        local host="$1"
        shift
        local cmd="$*"
        # Use SSH with strict options; assume SSH key authentication is configured
        ssh -o ConnectTimeout=5 -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
            "${SSH_USER}@${host}" "$cmd"
    }
    
    # ------------------------------------------------------------------------
    # Result recording
    # ------------------------------------------------------------------------
    record_result() {
        local check_name="$1"
        local status="$2"  # "PASS", "FAIL", "WARN"
        local message="$3"
        HEALTH_CHECK_RESULTS+=("${check_name}|${status}|${message}")
        if [[ "$status" == "FAIL" ]]; then
            CRITICAL_FAILURE=1
        fi
    }
    
    # ------------------------------------------------------------------------
    # Check: SSH accessibility
    # ------------------------------------------------------------------------
    check_ssh() {
        local host="$1"
        local check_name="SSH accessibility to ${host}"
        log_info "Checking ${check_name}..."
        if run_remote "$host" true; then
            log_success "${check_name}: OK"
            record_result "$check_name" "PASS" "SSH connection successful"
        else
            log_error "${check_name}: FAILED"
            record_result "$check_name" "FAIL" "SSH connection failed"
        fi
    }
    
    # ------------------------------------------------------------------------
    # Check: UFW status
    # ------------------------------------------------------------------------
    check_ufw() {
        local host="$1"
        local check_name="UFW status on ${host}"
        log_info "Checking ${check_name}..."
        local ufw_status
        if ufw_status=$(run_remote "$host" "sudo ufw status verbose 2>/dev/null"); then
            # Check if UFW is active
            if echo "$ufw_status" | grep -q "Status: active"; then
                log_success "${check_name}: active"
                # Verify SSH and VLESS ports are allowed
                local ssh_allowed=0
                local vless_allowed=0
                if echo "$ufw_status" | grep -E "^${SSH_PORT:-22}[[:space:]]+ALLOW" >/dev/null; then
                    ssh_allowed=1
                fi
                if echo "$ufw_status" | grep -E "^${VLESS_PORT:-443}[[:space:]]+ALLOW" >/dev/null; then
                    vless_allowed=1
                fi
                local msg="UFW active"
                if [[ $ssh_allowed -eq 1 && $vless_allowed -eq 1 ]]; then
                    msg="$msg, SSH and VLESS ports allowed"
                    record_result "$check_name" "PASS" "$msg"
                else
                    msg="$msg, but missing allowed ports (SSH:$ssh_allowed, VLESS:$vless_allowed)"
                    record_result "$check_name" "WARN" "$msg"
                fi
            else
                log_info "${check_name}: inactive"
                record_result "$check_name" "WARN" "UFW inactive"
            fi
        else
            log_error "${check_name}: cannot query UFW"
            record_result "$check_name" "FAIL" "Failed to query UFW status"
        fi
    }
    
    # ------------------------------------------------------------------------
    # Check: fail2ban status
    # ------------------------------------------------------------------------
    check_fail2ban() {
        local host="$1"
        local check_name="fail2ban status on ${host}"
        log_info "Checking ${check_name}..."
        if run_remote "$host" "sudo fail2ban-client status sshd 2>/dev/null"; then
            log_success "${check_name}: sshd jail active"
            record_result "$check_name" "PASS" "fail2ban sshd jail active"
        else
            log_info "${check_name}: sshd jail not active or fail2ban not installed"
            record_result "$check_name" "WARN" "fail2ban sshd jail not active"
        fi
    }
    
    # ------------------------------------------------------------------------
    # Check: 3x-ui service status (foreign only)
    # ------------------------------------------------------------------------
    check_3xui_service() {
        local host="$1"
        local check_name="3x-ui service status on ${host}"
        log_info "Checking ${check_name}..."
        # Try common service names
        if run_remote "$host" "systemctl is-active --quiet xray 2>/dev/null"; then
            log_success "${check_name}: xray service active"
            record_result "$check_name" "PASS" "xray service active"
            # Additionally check panel accessibility via local API
            check_panel_accessibility "$host"
        elif run_remote "$host" "systemctl is-active --quiet x-ui 2>/dev/null"; then
            log_success "${check_name}: x-ui service active"
            record_result "$check_name" "PASS" "x-ui service active"
            check_panel_accessibility "$host"
        else
            log_error "${check_name}: neither xray nor x-ui service active"
            record_result "$check_name" "FAIL" "3x-ui service not active"
        fi
    }
    
    check_panel_accessibility() {
        local host="$1"
        local check_name="3x-ui panel accessibility on ${host}"
        log_info "Checking ${check_name}..."
        # Try to reach panel API (no authentication required for /login maybe)
        if run_remote "$host" "curl -fsSL --max-time 5 http://localhost:2053/panel/api/inbounds/list 2>/dev/null"; then
            log_success "${check_name}: panel API accessible"
            record_result "$check_name" "PASS" "Panel API accessible"
        else
            log_info "${check_name}: panel API not accessible (service may be starting)"
            record_result "$check_name" "WARN" "Panel API not accessible"
        fi
    }
    
    # ------------------------------------------------------------------------
    # Check: WARP status (foreign only, if enabled)
    # ------------------------------------------------------------------------
    check_warp() {
        local host="$1"
        local check_name="WARP status on ${host}"
        log_info "Checking ${check_name}..."
        if [[ "${ENABLE_WARP:-false}" != "true" ]]; then
            log_info "WARP not enabled, skipping"
            record_result "$check_name" "PASS" "WARP not enabled (skip)"
            return 0
        fi
        # Check WARP service
        if run_remote "$host" "systemctl is-active --quiet warp-svc 2>/dev/null"; then
            # Check connection status
            local warp_status
            if warp_status=$(run_remote "$host" "warp-cli status 2>/dev/null"); then
                if echo "$warp_status" | grep -i "connected" >/dev/null; then
                    log_success "${check_name}: connected"
                    # Verify external IP is Cloudflare range (basic check)
                    local warp_ip
                    if warp_ip=$(run_remote "$host" "curl --interface wgcf --connect-timeout 10 --max-time 20 ifconfig.me 2>/dev/null"); then
                        if [[ "$warp_ip" =~ ^104\.28\. ]] || [[ "$warp_ip" =~ ^172\.64\. ]]; then
                            log_success "WARP IP ($warp_ip) appears to be Cloudflare"
                            record_result "$check_name" "PASS" "WARP connected, IP $warp_ip"
                        else
                            log_info "WARP IP ($warp_ip) not in expected Cloudflare range"
                            record_result "$check_name" "WARN" "WARP connected but IP $warp_ip not Cloudflare"
                        fi
                    else
                        log_info "Could not fetch WARP external IP"
                        record_result "$check_name" "WARN" "WARP connected but IP fetch failed"
                    fi
                else
                    log_error "${check_name}: not connected"
                    record_result "$check_name" "FAIL" "WARP service running but not connected"
                fi
            else
                log_error "${check_name}: cannot query warp-cli"
                record_result "$check_name" "FAIL" "warp-cli command failed"
            fi
        else
            log_error "${check_name}: warp-svc not active"
            record_result "$check_name" "FAIL" "WARP service not active"
        fi
    }
    
    # ------------------------------------------------------------------------
    # Check: VLESS/Reality port accessibility
    # ------------------------------------------------------------------------
    check_vless_port() {
        local relay_host="$1"
        local foreign_host="$2"
        local check_name="VLESS port ${VLESS_PORT:-443} accessibility from ${relay_host} to ${foreign_host}"
        log_info "Checking ${check_name}..."
        # Use netcat on relay to test foreign port
        if run_remote "$relay_host" "nc -z -w 5 ${foreign_host} ${VLESS_PORT:-443}"; then
            log_success "${check_name}: port open"
            record_result "$check_name" "PASS" "Port accessible"
        else
            log_error "${check_name}: port closed or unreachable"
            record_result "$check_name" "FAIL" "Port not accessible"
        fi
    }
    
    # ------------------------------------------------------------------------
    # Check: direct/warp outbound connectivity
    # ------------------------------------------------------------------------
    check_outbound_connectivity() {
        local host="$1"
        local check_name="Outbound connectivity on ${host}"
        log_info "Checking ${check_name}..."
        # Direct outbound via default interface
        local direct_ip
        if direct_ip=$(run_remote "$host" "curl --connect-timeout 10 --max-time 20 ifconfig.me 2>/dev/null"); then
            log_success "Direct outbound IP: $direct_ip"
            record_result "${check_name} (direct)" "PASS" "Direct outbound works, IP $direct_ip"
        else
            log_error "Direct outbound failed"
            record_result "${check_name} (direct)" "FAIL" "Direct outbound failed"
        fi
        # WARP outbound if enabled
        if [[ "${ENABLE_WARP:-false}" == "true" ]]; then
            local warp_ip
            if warp_ip=$(run_remote "$host" "curl --interface wgcf --connect-timeout 10 --max-time 20 ifconfig.me 2>/dev/null"); then
                log_success "WARP outbound IP: $warp_ip"
                record_result "${check_name} (WARP)" "PASS" "WARP outbound works, IP $warp_ip"
                # Ensure IPs differ
                if [[ "$direct_ip" != "$warp_ip" ]]; then
                    log_success "Direct and WARP IPs differ (expected)"
                else
                    log_info "Direct and WARP IPs are identical (may indicate WARP not routing)"
                fi
            else
                log_error "WARP outbound failed"
                record_result "${check_name} (WARP)" "FAIL" "WARP outbound failed"
            fi
        fi
    }
    
    # ------------------------------------------------------------------------
    # Health check orchestrators
    # ------------------------------------------------------------------------
    health_check_relay() {
        log_info "=== Health check for RU relay server (${RU_RELAY_IP}) ==="
        check_ssh "${RU_RELAY_IP}"
        check_ufw "${RU_RELAY_IP}"
        check_fail2ban "${RU_RELAY_IP}"
        # Relay-specific: check iptables forwarding rules?
        # Not required by acceptance criteria, but could be added.
    }
    
    health_check_foreign() {
        log_info "=== Health check for foreign VPS (${FOREIGN_VPS_IP}) ==="
        check_ssh "${FOREIGN_VPS_IP}"
        check_ufw "${FOREIGN_VPS_IP}"
        check_fail2ban "${FOREIGN_VPS_IP}"
        check_3xui_service "${FOREIGN_VPS_IP}"
        check_warp "${FOREIGN_VPS_IP}"
        check_outbound_connectivity "${FOREIGN_VPS_IP}"
    }
    
    health_check_all() {
        log_info "Starting comprehensive health check for VPN infrastructure"
        health_check_relay
        health_check_foreign
        check_vless_port "${RU_RELAY_IP}" "${FOREIGN_VPS_IP}"
    }
    
    # ------------------------------------------------------------------------
    # Summary report
    # ------------------------------------------------------------------------
    print_summary() {
        log_info "=== Health Check Summary ==="
        local pass=0 fail=0 warn=0
        for result in "${HEALTH_CHECK_RESULTS[@]}"; do
            IFS='|' read -r check_name status message <<< "$result"
            case "$status" in
                PASS) ((pass++)) ;;
                FAIL) ((fail++)) ;;
                WARN) ((warn++)) ;;
            esac
            printf "%-50s %-6s %s\n" "$check_name" "[$status]" "$message"
        done
        log_info "Total: $pass PASS, $warn WARN, $fail FAIL"
    }
    
    # ------------------------------------------------------------------------
    # Argument parsing
    # ------------------------------------------------------------------------
    show_help() {
        cat <<EOF
3x-ui VPN Automation Health Check

Usage: $0 [OPTION]

Options:
    --relay       Check RU relay server only
    --foreign     Check foreign VPS only  
    --all         Check complete infrastructure (default)
    --help        Show this help message

Examples:
    $0 --all          # Full health check
    $0 --relay        # Check relay only
    $0 --foreign      # Check foreign only

Configuration:
    Ensure .env file is present with required parameters.
EOF
    }
    
    parse_args() {
        TARGET="all"
        if [[ $# -eq 0 ]]; then
            # default
            return 0
        fi
        case "$1" in
            --relay)
                TARGET="relay"
                ;;
            --foreign)
                TARGET="foreign"
                ;;
            --all)
                TARGET="all"
                ;;
            --help)
                show_help
                exit 0
                ;;
            *)
                log_error "Unknown argument: $1"
                show_help
                exit 1
                ;;
        esac
    }
    
    main() {
        parse_args "$@"
        load_config
        case "$TARGET" in
            relay)
                health_check_relay
                ;;
            foreign)
                health_check_foreign
                ;;
            all)
                health_check_all
                ;;
        esac
        print_summary
        if [[ $CRITICAL_FAILURE -eq 0 ]]; then
            log_success "All critical checks passed"
            exit 0
        else
            log_error "One or more critical checks failed"
            exit 1
        fi
    }
    
    # Export functions for testing (optional)
    export -f run_remote record_result check_ssh check_ufw check_fail2ban \
        check_3xui_service check_panel_accessibility check_warp check_vless_port \
        check_outbound_connectivity health_check_relay health_check_foreign \
        health_check_all print_summary
    
    # If script is executed directly (not sourced), run main
    if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
        main "$@"
    fi
fi