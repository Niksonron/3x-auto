#!/usr/bin/env bash
# SSH hardening utilities for 3x-ui VPN automation
# Source this file in your bash scripts to apply SSH security hardening.

set -euo pipefail

# Check if functions already defined to allow idempotent sourcing
if ! command -v harden_ssh >/dev/null 2>&1; then
    # Determine script directory to source dependencies
    SSH_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    
    # Source logging utilities
    # shellcheck source=logging.sh
    source "${SSH_SCRIPT_DIR}/logging.sh"
    
    # Source OS detection utilities
    # shellcheck source=os-detection.sh
    source "${SSH_SCRIPT_DIR}/os-detection.sh"
    
    # Source configuration validation utilities
    # shellcheck source=validate-config.sh
    source "${SSH_SCRIPT_DIR}/validate-config.sh"
    
    # ------------------------------------------------------------------------
    # Utility Functions
    # ------------------------------------------------------------------------
    
    # Escape string for use in sed regex pattern (escape . * [ ] ^ $ / \)
    escape_sed_regex() {
        printf '%s' "$1" | sed -e 's/[][\.^$*\/]/\\&/g'
    }
    
    # Escape string for use in sed replacement (escape & and \)
    escape_sed_replacement() {
        printf '%s' "$1" | sed -e 's/[&\\]/\\&/g'
    }
    
    # ------------------------------------------------------------------------
    # SSH Hardening Functions
    # ------------------------------------------------------------------------
    
    # Validate SSH public key format
    # Usage: validate_ssh_public_key "SSH_PUBLIC_KEY"
    validate_ssh_public_key() {
        local key="$1"
        
        # Basic validation for common SSH public key formats
        if [[ ! "${key}" =~ ^(ssh-(rsa|ed25519)|ecdsa-sha2-nistp(256|384|521)) ]]; then
            die "Invalid SSH public key format. Must start with ssh-rsa, ssh-ed25519, or ecdsa-sha2-nistp*."
        fi
    }
    
    # Ensure SSH public key is present in authorized_keys for the SSH user
    # Usage: ensure_ssh_key "SSH_USER" "SSH_PUBLIC_KEY"
    ensure_ssh_key() {
        local ssh_user="$1"
        local ssh_key="$2"
        
        log_info "Ensuring SSH public key is present for user: ${ssh_user}"
        
        # Determine home directory
        local home_dir
        if [[ "${ssh_user}" == "root" ]]; then
            home_dir="/root"
        else
            home_dir="/home/${ssh_user}"
        fi
        
        local ssh_dir="${home_dir}/.ssh"
        local auth_keys="${ssh_dir}/authorized_keys"
        
        # Create .ssh directory if it doesn't exist
        if [[ ! -d "${ssh_dir}" ]]; then
            mkdir -p "${ssh_dir}"
            chmod 700 "${ssh_dir}"
            chown "${ssh_user}:${ssh_user}" "${ssh_dir}"
            log_info "Created SSH directory: ${ssh_dir}"
        fi
        
        # Create authorized_keys file if it doesn't exist
        if [[ ! -f "${auth_keys}" ]]; then
            touch "${auth_keys}"
            chmod 600 "${auth_keys}"
            chown "${ssh_user}:${ssh_user}" "${auth_keys}"
            log_info "Created authorized_keys file: ${auth_keys}"
        fi
        
        # Check if key already present
        if grep -qF "${ssh_key}" "${auth_keys}"; then
            log_info "SSH public key already present in authorized_keys"
            return 0
        fi
        
        # Append key
        echo "${ssh_key}" >> "${auth_keys}"
        log_success "Added SSH public key to authorized_keys"
    }
    
    # Set SSH daemon option in sshd_config (idempotent)
    # Usage: set_sshd_option "KEY" "VALUE"
    set_sshd_option() {
        local key="$1"
        local value="$2"
        local config_file="/etc/ssh/sshd_config"
        
        log_info "Setting SSH option: ${key} ${value}"
        
        # Backup config file if config file exists and backup doesn't exist
        if [[ -f "${config_file}" && ! -f "${config_file}.backup" ]]; then
            cp "${config_file}" "${config_file}.backup"
            log_info "Backed up sshd_config to ${config_file}.backup"
        fi
        
        # Escape key for regex
        local escaped_key
        escaped_key=$(escape_sed_regex "$key")
        
        # Pattern to match line (optional whitespace, optional #, whitespace, key, whitespace, anything)
        local line_pattern="^[[:space:]]*#?[[:space:]]*${escaped_key}[[:space:]]+.*"
        local new_line="${key} ${value}"
        local escaped_new_line
        escaped_new_line=$(escape_sed_replacement "${key} ${value}")
        
        # Check if line already matches desired value (exact match)
        if grep -E -q "^[[:space:]]*${key}[[:space:]]+${value}[[:space:]]*$" "${config_file}"; then
            log_info "SSH option ${key} already set to ${value}"
            return 0
        fi
        
        # Replace any existing line (commented or not) with new line
        sed -i -E "s|${line_pattern}|${escaped_new_line}|" "${config_file}"
        
        # If no replacement happened (line not present), append
        if ! grep -q "^[[:space:]]*${key}[[:space:]]" "${config_file}"; then
            echo "${new_line}" >> "${config_file}"
        fi
    }
    
    # Test SSH configuration before restarting service
    # Usage: test_sshd_config
    test_sshd_config() {
        log_info "Testing SSH configuration with sshd -t"
        if sshd -t; then
            log_success "SSH configuration test passed"
        else
            die "SSH configuration test failed. Check /etc/ssh/sshd_config for errors."
        fi
    }
    
    # Restart SSH service safely
    # Usage: restart_sshd
    restart_sshd() {
        log_info "Restarting SSH service"
        
        # Detect systemd vs sysvinit
        if systemctl is-active ssh >/dev/null 2>&1 || systemctl is-active sshd >/dev/null 2>&1; then
            systemctl restart ssh sshd 2>/dev/null || true
            log_success "SSH service restarted via systemctl"
        elif service ssh status >/dev/null 2>&1 || service sshd status >/dev/null 2>&1; then
            service ssh restart || service sshd restart
            log_success "SSH service restarted via service"
        else
            die "Cannot determine SSH service manager"
        fi
    }
    
    # Main SSH hardening function
    # Usage: harden_ssh
    harden_ssh() {
        log_info "Starting SSH hardening"

        # Validate required environment variables
        : "${SSH_USER:?SSH_USER is required}"
        : "${SSH_PUBLIC_KEY:?SSH_PUBLIC_KEY is required}"

        # Setup trap for cleanup
        local backup_file="/etc/ssh/sshd_config.backup"
        local sshd_config_validated=false

        cleanup_ssh() {
            if [[ "$sshd_config_validated" != "true" && -f "$backup_file" ]]; then
                log_info "Restoring sshd_config from backup due to error"
                cp "$backup_file" /etc/ssh/sshd_config
            fi
        }
        setup_trap 'cleanup_ssh'

        # Validate SSH public key
        validate_ssh_public_key "${SSH_PUBLIC_KEY}"
        
        # Ensure SSH key is present for the SSH user
        ensure_ssh_key "${SSH_USER}" "${SSH_PUBLIC_KEY}"
        
        # Configure SSH daemon options
        set_sshd_option "PasswordAuthentication" "no"
        set_sshd_option "PermitRootLogin" "prohibit-password"
        set_sshd_option "PubkeyAuthentication" "yes"
        set_sshd_option "ChallengeResponseAuthentication" "no"
        
        # Test configuration before restart
        test_sshd_config
        sshd_config_validated=true
        
        # Restart SSH service
        restart_sshd
        
        log_success "SSH hardening completed successfully"
    }
    
    # Export functions for use in other scripts
    export -f validate_ssh_public_key ensure_ssh_key set_sshd_option test_sshd_config restart_sshd harden_ssh
    
    # If script is executed directly (not sourced), run harden_ssh
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
        
        # Run hardening
        harden_ssh
    fi
fi