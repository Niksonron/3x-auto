#!/usr/bin/env bash
# RU relay server installation script for 3x-ui VPN automation
# This script sets up the relay server with security hardening and iptables forwarding.
# It must NOT install 3x-ui on the relay server.

set -euo pipefail

# Determine script directory to source dependencies
RELAY_SETUP_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ----------------------------------------------------------------------------
# Source common utilities
# ----------------------------------------------------------------------------

# shellcheck source=../common/logging.sh
source "${RELAY_SETUP_SCRIPT_DIR}/../common/logging.sh"

# shellcheck source=../common/os-detection.sh
source "${RELAY_SETUP_SCRIPT_DIR}/../common/os-detection.sh"

# shellcheck source=../common/load-config.sh
source "${RELAY_SETUP_SCRIPT_DIR}/../common/load-config.sh"

# shellcheck source=../common/validate-config.sh
source "${RELAY_SETUP_SCRIPT_DIR}/../common/validate-config.sh"

# shellcheck source=../common/ssh-hardening.sh
source "${RELAY_SETUP_SCRIPT_DIR}/../common/ssh-hardening.sh"

# shellcheck source=../common/ufw-config.sh
source "${RELAY_SETUP_SCRIPT_DIR}/../common/ufw-config.sh"

# shellcheck source=../common/fail2ban-config.sh
source "${RELAY_SETUP_SCRIPT_DIR}/../common/fail2ban-config.sh"

# ----------------------------------------------------------------------------
# Relay-specific functions
# ----------------------------------------------------------------------------

# Check if 3x-ui is installed (should not be on relay server)
check_no_3xui() {
    log_info "Checking that 3x-ui is not installed on relay server"
    
    # Check for xray process
    if pgrep -x xray >/dev/null 2>&1; then
        die "xray process detected. This appears to be a foreign VPS with 3x-ui installed. Relay server must NOT have 3x-ui."
    fi
    
    # Check for 3x-ui service
    if systemctl list-unit-files | grep -q 3x-ui; then
        die "3x-ui service detected. Relay server must NOT have 3x-ui installed."
    fi
    
    log_success "No 3x-ui detected (as expected for relay server)"
}

# Enable IP forwarding
enable_ip_forwarding() {
    log_info "Enabling IP forwarding"
    
    # Check current value
    local current_value
    current_value=$(sysctl -n net.ipv4.ip_forward)
    
    if [[ "${current_value}" -eq 1 ]]; then
        log_info "IP forwarding already enabled"
    else
        # Enable temporarily
        sysctl -w net.ipv4.ip_forward=1
        
        # Enable persistently in /etc/sysctl.conf
        if grep -q "^net.ipv4.ip_forward=" /etc/sysctl.conf; then
            # Update existing line
            sed -i 's/^net.ipv4.ip_forward=.*/net.ipv4.ip_forward=1/' /etc/sysctl.conf
        else
            # Add new line
            echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
        fi
        
        log_success "IP forwarding enabled persistently"
    fi
}

# Install iptables-persistent (non-interactively)
install_iptables_persistent() {
    log_info "Installing iptables-persistent for rule persistence"
    
    detect_os
    
    # Check if already installed
    if dpkg -l | grep -q iptables-persistent; then
        log_info "iptables-persistent already installed"
        return 0
    fi
    
    # Install non-interactively by preselecting configuration
    # Use debconf-set-selections to avoid interactive prompts
    echo "iptables-persistent iptables-persistent/autosave_v4 boolean true" | debconf-set-selections
    echo "iptables-persistent iptables-persistent/autosave_v6 boolean true" | debconf-set-selections
    
    "${PKG_MANAGER}" "${PKG_UPDATE}"
    "${PKG_MANAGER}" "${PKG_INSTALL}" iptables-persistent
    
    log_success "iptables-persistent installed"
}

# Get default network interface
get_default_interface() {
    ip route show default | awk '/default/ {print $5}'
}

# Check if iptables NAT rule already exists
# Arguments: $1 - foreign IP, $2 - port
nat_rule_exists() {
    local foreign_ip="$1"
    local port="$2"
    
    # Use iptables -C to check if rule exists (returns 0 if exists)
    iptables -t nat -C PREROUTING -p tcp --dport "${port}" -j DNAT --to-destination "${foreign_ip}:${port}" 2>/dev/null
}

# Add iptables NAT rule if not present
add_iptables_nat_rule() {
    local foreign_ip="$1"
    local port="$2"
    
    log_info "Adding iptables NAT rule: forward port ${port} to ${foreign_ip}"
    
    if nat_rule_exists "${foreign_ip}" "${port}"; then
        log_info "NAT rule already exists"
        return 0
    fi
    
    # Add DNAT rule
    iptables -t nat -A PREROUTING -p tcp --dport "${port}" -j DNAT --to-destination "${foreign_ip}:${port}"
    
    log_success "NAT rule added"
}

# Add MASQUERADE rule if not present
add_iptables_masquerade_rule() {
    local interface="${1:-}"
    
    if [[ -z "${interface}" ]]; then
        log_error "Cannot determine default interface for MASQUERADE rule"
        return 1
    fi
    
    log_info "Adding MASQUERADE rule for interface: ${interface}"
    
    # Check if MASQUERADE rule already exists in POSTROUTING chain
    if iptables -t nat -C POSTROUTING -o "${interface}" -j MASQUERADE 2>/dev/null; then
        log_info "MASQUERADE rule already exists for ${interface}"
        return 0
    fi
    
    # Add MASQUERADE rule
    iptables -t nat -A POSTROUTING -o "${interface}" -j MASQUERADE
    
    log_success "MASQUERADE rule added"
}

# Save iptables rules persistently
save_iptables_rules() {
    log_info "Saving iptables rules persistently"
    
    if command -v netfilter-persistent >/dev/null 2>&1; then
        netfilter-persistent save
    elif command -v iptables-save >/dev/null 2>&1; then
        # Fallback: manually save to /etc/iptables/rules.v4
        iptables-save > /etc/iptables/rules.v4
        log_info "iptables rules saved to /etc/iptables/rules.v4"
    else
        log_error "Cannot save iptables rules: netfilter-persistent not found"
        return 1
    fi
    
    log_success "iptables rules saved"
}

# Test connectivity to foreign server
test_connectivity() {
    local foreign_ip="$1"
    local port="$2"
    
    log_info "Testing connectivity to ${foreign_ip}:${port}"
    
    # Try TCP connection with timeout
    if timeout 2 bash -c "cat < /dev/null > /dev/tcp/${foreign_ip}/${port}" 2>/dev/null; then
        log_success "Connectivity test passed: ${foreign_ip}:${port} is reachable"
        return 0
    else
        log_error "Connectivity test failed: cannot reach ${foreign_ip}:${port}"
        log_error "Check firewall rules and that foreign server is listening on port ${port}"
        return 1
    fi
}

# Main setup function
setup_relay() {
    log_info "Starting RU relay server setup"
    
    # Ensure script is run as root
    if [[ $EUID -ne 0 ]]; then
        die "This script must be run as root (use sudo)"
    fi
    
    # Load configuration
    load_config
    
    # Validate required configuration
    validate_required "FOREIGN_VPS_IP"
    validate_required "VLESS_PORT"
    validate_required "SSH_USER"
    validate_required "SSH_PUBLIC_KEY"
    
    # Validate IP address format
    validate_ip "FOREIGN_VPS_IP"
    
    # Validate port
    validate_port "VLESS_PORT"
    
    # Validate SSH public key format
    validate_ssh_public_key "${SSH_PUBLIC_KEY}"
    
    # ------------------------------------------------------------------------
    # Security hardening
    # ------------------------------------------------------------------------
    log_info "Applying security hardening"
    
    harden_ssh "${SSH_USER}" "${SSH_PUBLIC_KEY}"
    configure_ufw
    configure_fail2ban
    
    # ------------------------------------------------------------------------
    # Ensure 3x-ui is not installed
    # ------------------------------------------------------------------------
    check_no_3xui
    
    # ------------------------------------------------------------------------
    # IP forwarding and iptables configuration
    # ------------------------------------------------------------------------
    enable_ip_forwarding
    install_iptables_persistent
    
    local default_interface
    default_interface=$(get_default_interface)
    
    add_iptables_nat_rule "${FOREIGN_VPS_IP}" "${VLESS_PORT}"
    add_iptables_masquerade_rule "${default_interface}"
    
    save_iptables_rules
    
    # ------------------------------------------------------------------------
    # Test connectivity
    # ------------------------------------------------------------------------
    test_connectivity "${FOREIGN_VPS_IP}" "${VLESS_PORT}"
    
    # ------------------------------------------------------------------------
    # Summary
    # ------------------------------------------------------------------------
    log_success "RU relay server setup completed successfully"
    log_info "Summary:"
    log_info "  - Security hardening applied (SSH, UFW, fail2ban)"
    log_info "  - IP forwarding enabled"
    log_info "  - iptables NAT rule added: port ${VLESS_PORT} → ${FOREIGN_VPS_IP}:${VLESS_PORT}"
    log_info "  - iptables MASQUERADE rule added for interface ${default_interface}"
    log_info "  - iptables rules persisted"
    log_info "  - Connectivity to foreign server verified"
}

# ----------------------------------------------------------------------------
# Main script execution
# ----------------------------------------------------------------------------
main() {
    # Setup trap for cleanup (no cleanup needed currently, but pattern)
    setup_trap "echo 'Cleanup completed'"
    
    setup_relay
}

# Run main only if script is executed directly (not sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main
fi