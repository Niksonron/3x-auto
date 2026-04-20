#!/usr/bin/env bash
# 3x-ui installation script for 3x-ui VPN automation
# Installs 3x-ui panel on foreign server using official installation method.

set -euo pipefail

# Check if functions already defined to allow idempotent sourcing
if ! command -v install_3xui >/dev/null 2>&1; then
    # Determine script directory to source dependencies
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    
    # Source logging utilities
    # shellcheck source=../common/logging.sh
    source "${SCRIPT_DIR}/../common/logging.sh"
    
    # Source OS detection utilities
    # shellcheck source=../common/os-detection.sh
    source "${SCRIPT_DIR}/../common/os-detection.sh"
    
    # Source configuration loading utilities
    # shellcheck source=../common/load-config.sh
    source "${SCRIPT_DIR}/../common/load-config.sh"
    
    # ------------------------------------------------------------------------
    # 3x-ui Installation Functions
    # ------------------------------------------------------------------------
    
    # Check if 3x-ui is already installed
    # Returns 0 if installed, 1 otherwise
    is_3xui_installed() {
        # Check for 3x-ui service
        if systemctl list-unit-files | grep -q 3x-ui; then
            log_info "3x-ui service detected"
            return 0
        fi
        
        # Check for xray binary (installed by 3x-ui)
        if command -v xray >/dev/null 2>&1; then
            log_info "xray binary detected (3x-ui likely installed)"
            return 0
        fi
        
        # Check for 3x-ui binary
        if [[ -f /usr/local/x-ui/x-ui ]] || [[ -f /usr/local/bin/x-ui ]]; then
            log_info "3x-ui binary detected"
            return 0
        fi
        
        return 1
    }
    
    # Wait for 3x-ui service to be active (max 30 seconds)
    # Returns 0 if service becomes active, 1 otherwise
    wait_for_3xui_service() {
        local max_attempts=30
        local wait_seconds=1
        local attempt=1
        
        log_info "Waiting for 3x-ui service to become active (max ${max_attempts}s)"
        
        while [[ $attempt -le $max_attempts ]]; do
            # Check for service name variants
            if systemctl is-active --quiet 3x-ui 2>/dev/null || systemctl is-active --quiet x-ui 2>/dev/null; then
                log_info "3x-ui service is active after ${attempt} attempts"
                return 0
            fi
            
            # Also check via xray binary (service might be xray)
            if systemctl is-active --quiet xray 2>/dev/null; then
                log_info "xray service is active after ${attempt} attempts"
                return 0
            fi
            
            sleep "$wait_seconds"
            attempt=$((attempt + 1))
        done
        
        log_error "3x-ui service did not become active after ${max_attempts} seconds"
        return 1
    }
    
    # Extract installer password from output
    # Usage: extract_installer_password "output"
    # Sets global PANEL_PASSWORD_INSTALLER if found
    extract_installer_password() {
        local output="$1"
        # Try to find password line (common patterns)
        local password_line
        password_line=$(echo "$output" | grep -i "password" | head -1)
        if [[ -n "$password_line" ]]; then
            # Extract password (word after "password:" or "password =")
            local password
            password=$(echo "$password_line" | sed -n 's/.*[Pp]assword[[:space:]]*[:=][[:space:]]*//p' | awk '{print $1}')
            if [[ -n "$password" ]]; then
                PANEL_PASSWORD_INSTALLER="$password"
                log_info "Extracted installer-generated password"
            fi
        fi
        # Try to find username line
        local username_line
        username_line=$(echo "$output" | grep -i "username" | head -1)
        if [[ -n "$username_line" ]]; then
            local username
            username=$(echo "$username_line" | sed -n 's/.*[Uu]sername[[:space:]]*[:=][[:space:]]*//p' | awk '{print $1}')
            if [[ -n "$username" ]]; then
                PANEL_USERNAME_INSTALLER="$username"
                log_info "Extracted installer-generated username: $username"
            fi
        fi
    }
    
    # Install 3x-ui using official installation method
    # Usage: install_3xui_panel
    install_3xui_panel() {
        log_info "Installing 3x-ui panel"
        
        # Check if already installed
        if is_3xui_installed; then
            log_info "3x-ui is already installed, skipping installation"
            return 0
        fi
        
        # Ensure curl is available
        detect_os
        if ! command -v curl >/dev/null 2>&1; then
            log_info "Installing curl"
            "${PKG_MANAGER}" "${PKG_UPDATE}"
            "${PKG_MANAGER}" "${PKG_INSTALL}" curl
        fi
        
        # Run official installer
        # The installer may prompt for inputs; we'll accept defaults
        log_info "Running official 3x-ui installer from GitHub"
        # Using versioned installer for stability
        # The installer will auto-generate admin credentials and output them
        # Capture installer output to extract credentials
        local installer_output
        local installer_log_file
        local installer_exit_code
        local tee_exit_code
        
        installer_log_file=$(mktemp)
        
        # Setup trap to clean up temp file on exit
        cleanup_installer() {
            if [[ -f "$installer_log_file" ]]; then
                rm -f "$installer_log_file"
            fi
        }
        setup_trap 'cleanup_installer'
        
        if [[ -t 1 ]]; then
            log_info "Installer output (live):"
            bash <(curl -Ls https://raw.githubusercontent.com/3x-ui/3x-ui/master/install.sh) 2>&1 | tee "$installer_log_file"
        else
            log_info "Installer running in non-interactive mode, capturing output..."
            bash <(curl -Ls https://raw.githubusercontent.com/3x-ui/3x-ui/master/install.sh) 2>&1 | tee "$installer_log_file" >/dev/null
        fi
        
        # Capture exit codes
        installer_exit_code="${PIPESTATUS[0]}"
        tee_exit_code="${PIPESTATUS[1]}"
        
        if [[ "$installer_exit_code" -ne 0 || "$tee_exit_code" -ne 0 ]]; then
            log_error "Installer failed with exit codes: bash=$installer_exit_code, tee=$tee_exit_code"
            log_error "Check installer output in $installer_log_file"
            exit 1
        fi
        
        installer_output=$(cat "$installer_log_file")
        cleanup_installer
        
        # Extract installer-generated credentials
        extract_installer_password "$installer_output"
        
        # Wait for service to become active
        if ! wait_for_3xui_service; then
            log_warning "3x-ui service not active, but installation may have succeeded"
        fi
        
        # Verify installation succeeded
        if ! is_3xui_installed; then
            log_error "3x-ui installation seems to have failed"
            exit 1
        fi
        
        log_success "3x-ui installation completed"
    }

    # Upgrade 3x-ui panel to latest version
    # Usage: upgrade_3xui_panel
    upgrade_3xui_panel() {
        log_info "Upgrading 3x-ui panel to latest version"
        
        # Ensure curl is available
        detect_os
        if ! command -v curl >/dev/null 2>&1; then
            log_info "Installing curl"
            "${PKG_MANAGER}" "${PKG_UPDATE}"
            "${PKG_MANAGER}" "${PKG_INSTALL}" curl
        fi
        
        # Run official installer (will upgrade if already installed)
        log_info "Running official 3x-ui installer from GitHub"
        local installer_output
        local installer_log_file
        local installer_exit_code
        local tee_exit_code
        
        installer_log_file=$(mktemp)
        
        # Setup trap to clean up temp file on exit
        cleanup_installer() {
            if [[ -f "$installer_log_file" ]]; then
                rm -f "$installer_log_file"
            fi
        }
        setup_trap 'cleanup_installer'
        
        if [[ -t 1 ]]; then
            log_info "Installer output (live):"
            bash <(curl -Ls https://raw.githubusercontent.com/3x-ui/3x-ui/master/install.sh) 2>&1 | tee "$installer_log_file"
        else
            log_info "Installer running in non-interactive mode, capturing output..."
            bash <(curl -Ls https://raw.githubusercontent.com/3x-ui/3x-ui/master/install.sh) 2>&1 | tee "$installer_log_file" >/dev/null
        fi
        
        # Capture exit codes
        installer_exit_code="${PIPESTATUS[0]}"
        tee_exit_code="${PIPESTATUS[1]}"
        
        if [[ "$installer_exit_code" -ne 0 || "$tee_exit_code" -ne 0 ]]; then
            log_error "Installer failed with exit codes: bash=$installer_exit_code, tee=$tee_exit_code"
            log_error "Check installer output in $installer_log_file"
            exit 1
        fi
        
        installer_output=$(cat "$installer_log_file")
        cleanup_installer
        
        # Extract installer-generated credentials (in case they changed)
        extract_installer_password "$installer_output"
        
        # Wait for service to become active
        if ! wait_for_3xui_service; then
            log_warning "3x-ui service not active, but upgrade may have succeeded"
        fi
        
        # Verify installation succeeded
        if ! is_3xui_installed; then
            log_error "3x-ui upgrade seems to have failed"
            exit 1
        fi
        
        log_success "3x-ui upgrade completed"
    }

    # Configure 3x-ui admin credentials (if provided)
    # Usage: configure_3xui_credentials
    configure_3xui_credentials() {
        log_info "Configuring 3x-ui admin credentials"
        
        # Use config credentials if provided, otherwise use installer-generated ones
        if [[ -n "${PANEL_PASSWORD_INSTALLER:-}" && -z "${PANEL_PASSWORD:-}" ]]; then
            PANEL_PASSWORD="${PANEL_PASSWORD_INSTALLER}"
            log_info "Using installer-generated password"
        fi
        if [[ -n "${PANEL_USERNAME_INSTALLER:-}" && -z "${PANEL_USERNAME:-}" ]]; then
            PANEL_USERNAME="${PANEL_USERNAME_INSTALLER}"
            log_info "Using installer-generated username: ${PANEL_USERNAME}"
        fi
        
        # If PANEL_USERNAME and PANEL_PASSWORD are both set in config, we could attempt to set them.
        # However, 3x-ui does not provide a CLI for credential configuration.
        # For now, we'll log a message that credential configuration from config is not yet implemented.
        if [[ -n "${PANEL_PASSWORD:-}" && "${PANEL_PASSWORD}" != "${PANEL_PASSWORD_INSTALLER:-}" ]]; then
            log_info "Note: Custom PANEL_PASSWORD is set but cannot be applied automatically."
            log_info "You will need to change password manually in the panel after login."
        fi
        
        # Ensure service is running (check both service name variants)
        if systemctl is-active --quiet 3x-ui 2>/dev/null || systemctl is-active --quiet x-ui 2>/dev/null; then
            log_info "3x-ui service is already running"
        else
            log_info "Starting 3x-ui service"
            # Try both service names
            if systemctl enable --now 3x-ui 2>/dev/null; then
                log_info "Started 3x-ui service (name: 3x-ui)"
            elif systemctl enable --now x-ui 2>/dev/null; then
                log_info "Started 3x-ui service (name: x-ui)"
            else
                log_error "Failed to start 3x-ui service (tried both '3x-ui' and 'x-ui')"
                exit 1
            fi
        fi
        
        # Wait for service to be ready
        sleep 3
        
        log_success "3x-ui credentials configured"
    }
    
    # Output panel access information
    # Usage: output_panel_info
    output_panel_info() {
        log_info "=== 3x-ui Panel Access Information ==="
        log_info "Panel URL: http://${FOREIGN_VPS_IP:-<foreign-server-ip>}:${PANEL_PORT:-2053}"
        log_info "Username: ${PANEL_USERNAME:-admin}"
        if [[ -n "${PANEL_PASSWORD:-}" ]]; then
            log_info "Password: ${PANEL_PASSWORD}"
        else
            log_info "Password: <generated-by-installer> (check installer output above)"
        fi
        log_info "======================================"
        log_info "Note: If password was not set, check installer output above for generated password."
        log_info "You can change password after login in the panel settings."
    }
    
    # Main installation function
    # Usage: install_3xui
    install_3xui() {
        log_info "Starting 3x-ui installation"
        
        # Setup trap for cleanup (if needed)
        setup_trap 'log_error "3x-ui installation failed. Check logs for details."'
        
        # Load configuration (ensures variables are exported)
        load_config
        
        # Install panel
        install_3xui_panel
        
        # Configure credentials
        configure_3xui_credentials
        
        # Output access information
        output_panel_info
        
        log_success "3x-ui installation completed successfully"
    }
    
    # Export functions for use in other scripts
    export -f is_3xui_installed install_3xui_panel upgrade_3xui_panel configure_3xui_credentials \
             output_panel_info install_3xui
    
    # If script is executed directly (not sourced), run install_3xui
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
        
        # Run installation
        install_3xui
    fi
fi