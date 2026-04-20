#!/usr/bin/env bash
# UFW configuration utilities for 3x-ui VPN automation
# Source this file in your bash scripts to configure UFW firewall.

set -euo pipefail

# Check if functions already defined to allow idempotent sourcing
if ! command -v configure_ufw >/dev/null 2>&1; then
    # Determine script directory to source dependencies
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    
    # Source logging utilities
    # shellcheck source=logging.sh
    source "${SCRIPT_DIR}/logging.sh"
    
    # Source OS detection utilities
    # shellcheck source=os-detection.sh
    source "${SCRIPT_DIR}/os-detection.sh"
    
    # Source configuration validation utilities
    # shellcheck source=validate-config.sh
    source "${SCRIPT_DIR}/validate-config.sh"
    
    # ------------------------------------------------------------------------
    # UFW Configuration Functions
    # ------------------------------------------------------------------------
    
    # Install UFW if not already installed
    # Usage: install_ufw
    install_ufw() {
        log_info "Checking if UFW is installed"
        
        if command -v ufw >/dev/null 2>&1; then
            log_info "UFW is already installed"
            return 0
        fi
        
        log_info "Installing UFW"
        detect_os
        "${PKG_MANAGER}" "${PKG_UPDATE}"
        "${PKG_MANAGER}" "${PKG_INSTALL}" ufw
        log_success "UFW installed successfully"
    }
    
    # Configure UFW default policies (deny incoming, allow outgoing)
    # Usage: configure_ufw_defaults
    configure_ufw_defaults() {
        log_info "Configuring UFW default policies"
        
        # Set default policy: deny incoming, allow outgoing
        ufw default deny incoming
        ufw default allow outgoing
        
        log_success "UFW default policies configured"
    }
    
    # Allow a port if not already allowed (idempotent)
    # Usage: allow_port "PORT[/PROTOCOL]" ["COMMENT"]
    allow_port() {
        local port="$1"
        local comment="${2:-}"
        
        log_info "Allowing port: ${port} ${comment}"
        
        # Check if rule already exists (match port at start of line, followed by whitespace and ALLOW)
        if ufw status | grep -q -E "^${port}[[:space:]]+ALLOW"; then
            log_info "Port ${port} already allowed"
            return 0
        fi
        
        # Add rule
        if [[ -n "${comment}" ]]; then
            ufw allow "${port}" comment "${comment}"
        else
            ufw allow "${port}"
        fi
        
        log_success "Port ${port} allowed"
    }
    
    # Allow SSH port (configurable via SSH_PORT, default 22)
    # Usage: allow_ssh_port
    allow_ssh_port() {
        local ssh_port="${SSH_PORT:-22}"
        
        # Validate SSH_PORT is a valid port number
        if [[ ! "${ssh_port}" =~ ^[0-9]+$ ]] || (( ssh_port < 1 || ssh_port > 65535 )); then
            die "Invalid SSH_PORT: ${ssh_port}. Must be a number between 1 and 65535."
        fi
        
        allow_port "${ssh_port}/tcp" "SSH"
    }
    
    # Allow VLESS/Reality port (configurable via VLESS_PORT)
    # Usage: allow_vless_port
    allow_vless_port() {
        local vless_port="${VLESS_PORT:-443}"
        
        # Validate VLESS_PORT is a valid port number
        if [[ ! "${vless_port}" =~ ^[0-9]+$ ]] || (( vless_port < 1 || vless_port > 65535 )); then
            die "Invalid VLESS_PORT: ${vless_port}. Must be a number between 1 and 65535."
        fi
        
        allow_port "${vless_port}/tcp" "VLESS/Reality"
    }
    
    # Allow web ports (80, 443) if reverse proxy enabled
    # Usage: allow_web_ports_if_needed
    allow_web_ports_if_needed() {
        # Check if reverse proxy is enabled
        if [[ "${ENABLE_REVERSE_PROXY:-false}" != "true" ]]; then
            log_info "Reverse proxy not enabled, skipping web ports"
            return 0
        fi
        
        log_info "Reverse proxy enabled, allowing HTTP/HTTPS ports"
        allow_port "80/tcp" "HTTP (reverse proxy)"
        allow_port "443/tcp" "HTTPS (reverse proxy)"
    }
    
    # Enable UFW non-interactively
    # Usage: enable_ufw_noninteractive
    enable_ufw_noninteractive() {
        log_info "Enabling UFW (non-interactive)"
        
        # Check if UFW is already enabled
        if ufw status | grep -q "^Status: active"; then
            log_info "UFW is already active"
            return 0
        fi
        
        # Enable UFW with --force to skip confirmation
        ufw --force enable
        
        log_success "UFW enabled successfully"
    }
    
    # Output UFW rules for verification
    # Usage: output_ufw_rules
    output_ufw_rules() {
        log_info "Current UFW rules:"
        ufw status numbered
    }
    
    # Main UFW configuration function
    # Usage: configure_ufw
    configure_ufw() {
        log_info "Starting UFW configuration"
        
        # Setup trap for cleanup
        setup_trap 'log_error "UFW configuration failed. Check logs for details."'
        
        # Install UFW if needed
        install_ufw
        
        # Configure default policies
        configure_ufw_defaults
        
        # Allow required ports
        allow_ssh_port
        allow_vless_port
        allow_web_ports_if_needed
        
        # Enable UFW
        enable_ufw_noninteractive
        
        # Output final rules
        output_ufw_rules
        
        log_success "UFW configuration completed successfully"
    }
    
    # Export functions for use in other scripts
    export -f install_ufw configure_ufw_defaults allow_port allow_ssh_port \
             allow_vless_port allow_web_ports_if_needed enable_ufw_noninteractive \
             output_ufw_rules configure_ufw
    
    # If script is executed directly (not sourced), run configure_ufw
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
        configure_ufw
    fi
fi