#!/usr/bin/env bash
# Update script for 3x-ui VPN automation
# Performs safe updates of 3x-ui and WARP components, backs up configuration,
# and runs health-check after update.

set -euo pipefail

# Check if functions already defined to allow idempotent sourcing
if ! command -v update_all >/dev/null 2>&1; then
    # Determine script directory to source dependencies
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    
    # Source logging utilities
    # shellcheck source=common/logging.sh
    source "${SCRIPT_DIR}/common/logging.sh"
    
    # Source OS detection utilities
    # shellcheck source=common/os-detection.sh
    source "${SCRIPT_DIR}/common/os-detection.sh"
    
    # Source configuration loading utilities
    # shellcheck source=common/load-config.sh
    source "${SCRIPT_DIR}/common/load-config.sh"
    
    # Source health-check utilities (for invocation)
    # shellcheck source=health-check.sh
    if [[ -f "${SCRIPT_DIR}/health-check.sh" ]]; then
        source "${SCRIPT_DIR}/health-check.sh"
    fi
    
    # Source 3x-ui installation utilities (for install_3xui_panel)
    # shellcheck source=foreign/install-3xui.sh
    source "${SCRIPT_DIR}/foreign/install-3xui.sh"
    
    # Source WARP installation utilities (for is_warp_installed etc.)
    # shellcheck source=foreign/install-warp.sh
    source "${SCRIPT_DIR}/foreign/install-warp.sh"
    
    # ------------------------------------------------------------------------
    # Update Functions
    # ------------------------------------------------------------------------
    
    # Backup configuration files
    # Usage: backup_config
    backup_config() {
        log_info "Backing up configuration files"
        
        local timestamp
        timestamp=$(date -Is | tr ':' '-')
        local backup_dir="${SCRIPT_DIR}/../backups"
        mkdir -p "${backup_dir}"
        
        # Backup .env file
        if [[ -f "${SCRIPT_DIR}/../.env" ]]; then
            local env_backup="${backup_dir}/env.backup.${timestamp}"
            cp "${SCRIPT_DIR}/../.env" "${env_backup}"
            log_info "Backed up .env to ${env_backup}"
        fi
        
        # Backup 3x-ui config if exists
        local xui_configs=(
            "/usr/local/x-ui/config.json"
            "/etc/3x-ui/config.json"
            "/usr/local/bin/x-ui/config.json"
        )
        for config in "${xui_configs[@]}"; do
            if [[ -f "${config}" ]]; then
                local config_backup="${backup_dir}/$(basename "${config}").backup.${timestamp}"
                cp "${config}" "${config_backup}"
                log_info "Backed up ${config} to ${config_backup}"
                break
            fi
        done
        
        # Backup iptables rules if relay
        if [[ -f "/etc/iptables/rules.v4" ]]; then
            local iptables_backup="${backup_dir}/iptables-rules.v4.backup.${timestamp}"
            cp "/etc/iptables/rules.v4" "${iptables_backup}"
            log_info "Backed up iptables rules to ${iptables_backup}"
        fi
        
        log_success "Configuration backup completed"
    }
    
    # Restore configuration from backups (on error)
    # Usage: restore_config
    restore_config() {
        log_info "Restoring configuration from backups (if needed)"
        # Currently we rely on trap cleanup for individual steps.
        # This function can be extended if needed.
        log_info "Manual restoration may be required; backups are in ${backup_dir:-<unknown>}"
    }
    
    # Get current installed 3x-ui version
    # Returns version string or "unknown"
    get_current_3xui_version() {
        local version_file="/usr/local/x-ui/version"
        if [[ -f "${version_file}" ]]; then
            cat "${version_file}" 2>/dev/null | head -1 | tr -d '[:space:]'
            return
        fi
        # Try to get version from xray binary
        if command -v xray >/dev/null 2>&1; then
            local xray_output
            xray_output=$(xray -v 2>&1 | head -1)
            # Extract version number (e.g., "Xray 1.8.11" -> "1.8.11")
            if [[ "${xray_output}" =~ ([0-9]+\.[0-9]+\.[0-9]+) ]]; then
                echo "${BASH_REMATCH[1]}"
                return
            fi
        fi
        echo "unknown"
    }
    
    # Get latest 3x-ui version from GitHub releases
    # Returns version tag (e.g., "v1.0.0") or empty string on error
    get_latest_3xui_version() {
        local api_url="https://api.github.com/repos/3x-ui/3x-ui/releases/latest"
        local tag_name
        if command -v jq >/dev/null 2>&1; then
            tag_name=$(curl -fsSL "${api_url}" 2>/dev/null | jq -r .tag_name 2>/dev/null || echo "")
        else
            # fallback: grep for tag_name
            tag_name=$(curl -fsSL "${api_url}" 2>/dev/null | grep -o '"tag_name": *"[^"]*"' | cut -d'"' -f4 || echo "")
        fi
        echo "${tag_name}"
    }
    
    # Update 3x-ui panel if newer version available
    # Usage: update_3xui_panel
    update_3xui_panel() {
        log_info "Checking for 3x-ui updates"
        
        local current_version
        current_version=$(get_current_3xui_version)
        log_info "Current 3x-ui version: ${current_version}"
        
        local latest_version
        latest_version=$(get_latest_3xui_version)
        if [[ -z "${latest_version}" ]]; then
            log_info "Could not fetch latest 3x-ui version; skipping update check"
            return 0
        fi
        log_info "Latest 3x-ui version: ${latest_version}"
        
        # Normalize versions: strip leading 'v'
        local normalized_current="${current_version#v}"
        local normalized_latest="${latest_version#v}"
        
        # Compare versions (simple string equality)
        if [[ "${normalized_current}" == "${normalized_latest}" ]]; then
            log_info "3x-ui is already at latest version, skipping update"
            return 0
        fi
        
        log_info "New version available, updating 3x-ui..."
        
        # Run upgrade function (will upgrade if newer version)
        upgrade_3xui_panel
        
        # Update version file
        local version_file="/usr/local/x-ui/version"
        mkdir -p "$(dirname "${version_file}")"
        echo "${latest_version}" > "${version_file}"
        log_success "3x-ui updated to ${latest_version}"
    }
    
    # Update WARP client if newer version available
    # Usage: update_warp_client
    update_warp_client() {
        log_info "Checking for WARP client updates"
        
        # Check if WARP is enabled
        if [[ "${ENABLE_WARP:-false}" != "true" ]]; then
            log_info "WARP is disabled (ENABLE_WARP=false), skipping update"
            return 0
        fi
        
        # Ensure WARP is installed
        if ! is_warp_installed; then
            log_info "WARP client not installed, skipping update"
            return 0
        fi
        
        detect_os
        log_info "Updating WARP client packages"
        ${PKG_MANAGER} ${PKG_UPDATE}
        ${PKG_MANAGER} install --only-upgrade cloudflare-warp
        
        # Ensure WARP service is still connected
        if is_warp_connected; then
            log_success "WARP client updated and connected"
        else
            log_info "WARP client updated but not connected; attempting to reconnect"
            connect_warp || true
        fi
    }
    
    # Run health-check after update
    # Usage: run_health_check
    run_health_check() {
        log_info "Running health-check after update"
        if command -v health_check >/dev/null 2>&1; then
            health_check
        elif [[ -f "${SCRIPT_DIR}/health-check.sh" ]]; then
            # Execute health-check script directly
            bash "${SCRIPT_DIR}/health-check.sh"
        else
            log_info "Health-check script not found; skipping health verification"
        fi
    }
    
    # Main update function
    # Usage: update_all
    update_all() {
        log_info "Starting 3x-ui VPN automation update"
        
        # Setup trap for cleanup
        local update_failed=false
        cleanup_update() {
            if [[ "${update_failed}" == "true" ]]; then
                log_error "Update failed; check logs and restore backups if necessary"
                restore_config
            fi
        }
        setup_trap 'cleanup_update'
        
        # Load configuration (ensures variables are exported)
        load_config
        
        # Backup configuration
        backup_config
        
        # Update components
        update_3xui_panel || update_failed=true
        update_warp_client || update_failed=true
        
        if [[ "${update_failed}" == "true" ]]; then
            log_error "One or more updates failed; see logs above"
            exit 1
        fi
        
        # Run health-check
        run_health_check
        
        log_success "Update completed successfully"
    }
    
    # Export functions for use in other scripts
    export -f backup_config restore_config get_current_3xui_version get_latest_3xui_version \
             update_3xui_panel update_warp_client run_health_check update_all
    
    # If script is executed directly (not sourced), run update_all
    if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
        # Load configuration (assumes .env in project root)
        SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
        CONFIG_FILE="$(cd "${SCRIPT_DIR}/.." && pwd)/.env"
        if [[ -f "${CONFIG_FILE}" ]]; then
            # shellcheck source=/dev/null
            source "${CONFIG_FILE}"
        else
            log_error "Configuration file not found: ${CONFIG_FILE}"
            log_error "Copy .env.example to .env and fill in required parameters."
            exit 1
        fi
        
        # Run update
        update_all
    fi
fi