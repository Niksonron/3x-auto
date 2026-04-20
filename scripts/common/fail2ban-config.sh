#!/usr/bin/env bash
# fail2ban configuration utilities for 3x-ui VPN automation
# Source this file in your bash scripts to configure fail2ban.

set -euo pipefail

# Check if functions already defined to allow idempotent sourcing
if ! command -v configure_fail2ban >/dev/null 2>&1; then
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
    # fail2ban Configuration Functions
    # ------------------------------------------------------------------------
    
    install_fail2ban() {
        log_info "Checking if fail2ban is installed"
        if command -v fail2ban-client >/dev/null 2>&1; then
            log_info "fail2ban is already installed"
            return 0
        fi
        
        log_info "Installing fail2ban"
        detect_os
        "${PKG_MANAGER}" "${PKG_UPDATE}"
        "${PKG_MANAGER}" "${PKG_INSTALL}" fail2ban
        log_success "fail2ban installed successfully"
    }

    # Set a jail option in jail.local (idempotent)
    # Usage: set_jail_option "JAIL" "OPTION" "VALUE"
    set_jail_option() {
        local jail="$1"
        local option="$2"
        local value="$3"
        local config_file="/etc/fail2ban/jail.local"
        
        log_info "Setting jail option: [${jail}] ${option} = ${value}"
        
        # Backup config file if not already backed up and config file exists
        if [[ -f "${config_file}" && ! -f "${config_file}.backup" ]]; then
            cp "${config_file}" "${config_file}.backup"
            log_info "Backed up jail.local to ${config_file}.backup"
        fi
        
        # Create jail.local if it doesn't exist
        if [[ ! -f "${config_file}" ]]; then
            touch "${config_file}"
            chmod 644 "${config_file}"
        fi
        
        # Escape option for regex and value for replacement
        local escaped_option
        escaped_option=$(escape_sed_regex "$option")
        
        # Pattern to match line within the jail section
        # Matches optional whitespace, optional comment, optional whitespace, option, whitespace, anything
        local line_pattern="^[[:space:]]*#?[[:space:]]*${escaped_option}[[:space:]]*=.*"
        local new_line="${option} = ${value}"
        local escaped_new_line
        escaped_new_line=$(escape_sed_replacement "${option} = ${value}")
        
        # Check if the jail section exists
        if ! grep -q "^[[:space:]]*\[${jail}\][[:space:]]*$" "${config_file}"; then
            # Jail section doesn't exist, append it
            printf '\n[%s]\n%s\n' "${jail}" "${new_line}" >> "${config_file}"
            log_info "Created [${jail}] section with ${option} setting"
            return 0
        fi
        
        # Jail section exists, find lines between this jail section and next section
        local jail_start_line
        jail_start_line=$(grep -n "^[[:space:]]*\[${jail}\][[:space:]]*$" "${config_file}" | cut -d: -f1 | head -1)
        local next_section_line
        next_section_line=$(awk -v start="${jail_start_line}" 'NR > start && /^[[:space:]]*\[/ {print NR; exit}' "${config_file}")
        
        # If no next section, use end of file
        if [[ -z "${next_section_line}" ]]; then
            next_section_line=$(wc -l < "${config_file}" | awk '{print $1 + 1}')
        fi
        
        # Check if option already set with correct value within the jail section
        if sed -n "${jail_start_line},${next_section_line}p" "${config_file}" | grep -E -q "^[[:space:]]*${option}[[:space:]]*=[[:space:]]*${value}[[:space:]]*$"; then
            log_info "Jail option ${option} already set to ${value} in [${jail}]"
            return 0
        fi
        
        # Replace existing line (commented or not) within the jail section
        sed -i "${jail_start_line},${next_section_line}s|${line_pattern}|${escaped_new_line}|" "${config_file}"
        
        # If no replacement happened (line not present), append within jail section
        if ! sed -n "${jail_start_line},${next_section_line}p" "${config_file}" | grep -q "^[[:space:]]*${option}[[:space:]]*="; then
            # Insert after jail section start line
            sed -i "${jail_start_line}a ${escaped_new_line}" "${config_file}"
        fi
    }

    configure_fail2ban_ssh_jail() {
        log_info "Configuring fail2ban SSH jail"
        
        local bantime="${FAIL2BAN_BANTIME:-600}"
        local findtime="${FAIL2BAN_FINDTIME:-600}"
        local maxretry="${FAIL2BAN_MAXRETRY:-5}"
        
        # Ensure sshd jail is enabled
        set_jail_option "sshd" "enabled" "true"
        set_jail_option "sshd" "bantime" "${bantime}"
        set_jail_option "sshd" "findtime" "${findtime}"
        set_jail_option "sshd" "maxretry" "${maxretry}"
        
        log_success "SSH jail configured (bantime=${bantime}s, findtime=${findtime}s, maxretry=${maxretry})"
    }
    
    configure_fail2ban_web_jails_if_needed() {
        log_info "Checking if web service jails are needed"
        
        # Check if reverse proxy is enabled
        if [[ "${ENABLE_REVERSE_PROXY:-false}" != "true" ]]; then
            log_info "Reverse proxy not enabled, skipping web service jails"
            return 0
        fi
        
        # Enable nginx jail if nginx is installed
        if command -v nginx >/dev/null 2>&1; then
            log_info "nginx detected, enabling nginx-http-auth jail"
            set_jail_option "nginx-http-auth" "enabled" "true"
            log_success "nginx-http-auth jail enabled"
        else
            log_info "nginx not installed, skipping nginx jail"
        fi
        
        # Enable caddy jail if caddy is installed
        if command -v caddy >/dev/null 2>&1; then
            log_info "caddy detected, enabling caddy jail"
            set_jail_option "caddy" "enabled" "true"
            log_success "caddy jail enabled"
        fi
        
        log_success "Web service jails configuration completed"
    }
    
    enable_fail2ban_service() {
        log_info "Enabling and starting fail2ban service"
        
        # Test configuration before starting
        log_info "Testing fail2ban configuration"
        if ! fail2ban-client --test; then
            die "fail2ban configuration test failed. Check /etc/fail2ban/jail.local for errors."
        fi
        
        # Detect systemd vs sysvinit
        if systemctl is-active fail2ban >/dev/null 2>&1 || systemctl is-active fail2ban-server >/dev/null 2>&1; then
            log_info "Using systemd to manage fail2ban service"
            # Enable service if not already enabled
            if ! systemctl is-enabled fail2ban >/dev/null 2>&1 && ! systemctl is-enabled fail2ban-server >/dev/null 2>&1; then
                systemctl enable fail2ban 2>/dev/null || systemctl enable fail2ban-server 2>/dev/null
                log_info "fail2ban service enabled for startup"
            fi
            # Restart service (reload configuration)
            systemctl restart fail2ban 2>/dev/null || systemctl restart fail2ban-server 2>/dev/null
            log_success "fail2ban service restarted via systemctl"
        elif service fail2ban status >/dev/null 2>&1 || service fail2ban-server status >/dev/null 2>&1; then
            log_info "Using sysvinit to manage fail2ban service"
            # Update rc.d links (enable)
            update-rc.d fail2ban defaults 2>/dev/null || update-rc.d fail2ban-server defaults 2>/dev/null
            # Restart service
            service fail2ban restart 2>/dev/null || service fail2ban-server restart 2>/dev/null
            log_success "fail2ban service restarted via service"
        else
            die "Cannot determine fail2ban service manager"
        fi
        
        # Verify service is running
        sleep 2
        if fail2ban-client status >/dev/null 2>&1; then
            log_success "fail2ban service is running"
        else
            die "fail2ban service failed to start"
        fi
    }
    
    output_fail2ban_status() {
        log_info "fail2ban status:"
        
        # Show fail2ban version
        if command -v fail2ban-client >/dev/null 2>&1; then
            fail2ban-client --version || true
        fi
        
        # Show overall status
        log_info "Overall status:"
        fail2ban-client status 2>/dev/null || log_error "fail2ban service not running"
        
        # Show SSH jail status if enabled
        log_info "SSH jail status:"
        fail2ban-client status sshd 2>/dev/null || log_info "SSH jail not active"
        
        # Show nginx jail status if enabled
        if [[ "${ENABLE_REVERSE_PROXY:-false}" == "true" ]] && command -v nginx >/dev/null 2>&1; then
            log_info "nginx jail status:"
            fail2ban-client status nginx-http-auth 2>/dev/null || log_info "nginx jail not active"
        fi
        
        # Show caddy jail status if enabled
        if [[ "${ENABLE_REVERSE_PROXY:-false}" == "true" ]] && command -v caddy >/dev/null 2>&1; then
            log_info "caddy jail status:"
            fail2ban-client status caddy 2>/dev/null || log_info "caddy jail not active"
        fi
    }
    
    configure_fail2ban() {
        log_info "Starting fail2ban configuration"
        
        local backup_file="/etc/fail2ban/jail.local.backup"
        local jail_config_validated=false
        
        # Cleanup function: restore backup if configuration validation failed
        cleanup_fail2ban() {
            if [[ "$jail_config_validated" != "true" && -f "$backup_file" ]]; then
                log_info "Restoring jail.local from backup due to error"
                cp "$backup_file" /etc/fail2ban/jail.local 2>/dev/null || true
            fi
        }
        setup_trap 'cleanup_fail2ban'
        
        # Backup existing jail.local if it exists
        if [[ -f "/etc/fail2ban/jail.local" && ! -f "$backup_file" ]]; then
            cp "/etc/fail2ban/jail.local" "$backup_file"
            log_info "Backed up jail.local to $backup_file"
        fi
        
        # Step 1: Install fail2ban
        install_fail2ban
        
        # Step 2: Configure SSH jail
        configure_fail2ban_ssh_jail
        
        # Step 3: Configure web jails if needed
        configure_fail2ban_web_jails_if_needed
        
        # Validate configuration before enabling service
        log_info "Validating fail2ban configuration"
        if fail2ban-client --test; then
            jail_config_validated=true
            log_success "fail2ban configuration validation passed"
        else
            die "fail2ban configuration validation failed. Check /etc/fail2ban/jail.local for errors."
        fi
        
        # Step 4: Enable and start service
        enable_fail2ban_service
        
        # Step 5: Output status
        output_fail2ban_status
        
        log_success "fail2ban configuration completed successfully"
    }
    
    # Export functions for use in other scripts
    export -f install_fail2ban configure_fail2ban_ssh_jail configure_fail2ban_web_jails_if_needed \
             enable_fail2ban_service output_fail2ban_status configure_fail2ban
    
    # If script is executed directly (not sourced), run configure_fail2ban
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
        configure_fail2ban
    fi
fi