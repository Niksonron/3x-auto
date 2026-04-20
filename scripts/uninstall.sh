#!/usr/bin/env bash
# Uninstall script for 3x-ui VPN automation
# Safely removes installed components (3x-ui, WARP, iptables rules, UFW rules)
# with optional soft reset (keep configuration) or hard reset (full removal).

set -euo pipefail

# Check if functions already defined to allow idempotent sourcing
if ! command -v uninstall_all >/dev/null 2>&1; then
    # Determine script directory to source dependencies
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    ORIGINAL_SCRIPT_DIR="${SCRIPT_DIR}"
    
    # Source logging utilities
    # shellcheck source=common/logging.sh
    source "${ORIGINAL_SCRIPT_DIR}/common/logging.sh"
    
    # Source OS detection utilities
    # shellcheck source=common/os-detection.sh
    source "${ORIGINAL_SCRIPT_DIR}/common/os-detection.sh"
    
    # Source configuration loading utilities
    # shellcheck source=common/load-config.sh
    source "${ORIGINAL_SCRIPT_DIR}/common/load-config.sh"
    
    # Source configuration validation utilities (already sourced by load-config)
    # shellcheck source=common/validate-config.sh
    # source "${SCRIPT_DIR}/common/validate-config.sh"
    
    # Source UFW configuration utilities (for rule deletion)
    # shellcheck source=common/ufw-config.sh
    source "${ORIGINAL_SCRIPT_DIR}/common/ufw-config.sh"
    
    # Source 3x-ui installation utilities (for detection)
    # shellcheck source=foreign/install-3xui.sh
    source "${ORIGINAL_SCRIPT_DIR}/foreign/install-3xui.sh"
    
    # Source WARP installation utilities (for detection)
    # shellcheck source=foreign/install-warp.sh
    source "${ORIGINAL_SCRIPT_DIR}/foreign/install-warp.sh"
    
    # ------------------------------------------------------------------------
    # Global variables
    # ------------------------------------------------------------------------
    UNINSTALL_MODE="hard"          # hard (remove everything) or soft (keep configs)
    UNINSTALL_TARGET="all"         # relay, foreign, all
    FORCE_CONFIRM=false            # skip interactive confirmation if true
    
    # ------------------------------------------------------------------------
    # Helper Functions
    # ------------------------------------------------------------------------

    # Warning log function (yellow color)
    log_warn() {
        if [[ -t 1 ]]; then
            printf "\033[0;33m[WARN]\033[0m %s\n" "$(date -Is) $*"
        else
            printf "[WARN] %s\n" "$(date -Is) $*"
        fi
    }

    # Confirm destructive action
    # Usage: confirm_action "message"
    # Returns 0 if confirmed, 1 otherwise
    confirm_action() {
        local message="$1"
        
        if [[ "${FORCE_CONFIRM}" == "true" ]]; then
            log_info "Force flag set, skipping confirmation"
            return 0
        fi
        
        # If not a TTY, cannot prompt; assume yes if FORCE_CONFIRM not set?
        if [[ ! -t 0 ]]; then
            log_warn "Not running in interactive terminal; assuming confirmation"
            return 0
        fi
        
        log_warn "================================================================"
        log_warn "WARNING: Destructive action"
        log_warn "$message"
        log_warn "================================================================"
        echo -n "Are you sure you want to proceed? (yes/no): "
        read -r response
        
        if [[ "${response}" =~ ^[Yy][Ee]?[Ss]?$ ]]; then
            log_info "Confirmation received"
            return 0
        else
            log_info "Action cancelled by user"
            return 1
        fi
    }
    
    # Check if running as root
    require_root() {
        if [[ $EUID -ne 0 ]]; then
            die "This script must be run as root (use sudo)"
        fi
    }
    
    # Display summary of actions to be performed
    # Usage: show_summary
    show_summary() {
        log_info "=== Uninstall Summary ==="
        log_info "Target: ${UNINSTALL_TARGET}"
        log_info "Mode: ${UNINSTALL_MODE}"
        log_info "Actions:"
        
        case "${UNINSTALL_TARGET}" in
            relay)
                log_info "  - Remove iptables forwarding rules"
                log_info "  - Remove UFW rules (SSH, VLESS ports)"
                if [[ "${UNINSTALL_MODE}" == "hard" ]]; then
                    log_info "  - Remove configuration backups (if any)"
                fi
                ;;
            foreign)
                log_info "  - Remove 3x-ui panel and Xray service"
                log_info "  - Remove WARP client (if installed)"
                log_info "  - Remove UFW rules (SSH, VLESS, web ports)"
                if [[ "${UNINSTALL_MODE}" == "hard" ]]; then
                    log_info "  - Remove configuration backups (if any)"
                    log_info "  - Remove 3x-ui configuration files"
                fi
                ;;
            all)
                log_info "  - Relay: iptables rules, UFW rules"
                log_info "  - Foreign: 3x-ui, WARP, UFW rules"
                if [[ "${UNINSTALL_MODE}" == "hard" ]]; then
                    log_info "  - Remove all configuration files and backups"
                fi
                ;;
        esac
        
        if [[ "${UNINSTALL_MODE}" == "soft" ]]; then
            log_info "  - Keep configuration files (.env, backups)"
        fi
    }
    
    # ------------------------------------------------------------------------
    # 3x‑ui Removal Functions
    # ------------------------------------------------------------------------
    
    # Check if 3x-ui is installed (reuse from install-3xui.sh)
    # Returns 0 if installed, 1 otherwise
    is_3xui_installed() {
        # Use existing function if already sourced
        if command -v is_3xui_installed >/dev/null 2>&1; then
            is_3xui_installed
            return $?
        fi
        
        # Fallback detection
        if systemctl list-unit-files | grep -q 3x-ui; then
            log_info "3x-ui service detected"
            return 0
        fi
        if command -v xray >/dev/null 2>&1; then
            log_info "xray binary detected (3x-ui likely installed)"
            return 0
        fi
        if [[ -f /usr/local/x-ui/x-ui ]] || [[ -f /usr/local/bin/x-ui ]]; then
            log_info "3x-ui binary detected"
            return 0
        fi
        return 1
    }
    
    # Stop and disable 3x-ui service
    stop_3xui_service() {
        log_info "Stopping 3x-ui service"
        for service in 3x-ui xray; do
            if systemctl is-active --quiet "$service" 2>/dev/null; then
                systemctl stop "$service"
                log_info "Stopped $service"
            fi
        done
        
        log_info "Disabling 3x-ui service"
        for service in 3x-ui xray; do
            if systemctl is-enabled --quiet "$service" 2>/dev/null; then
                systemctl disable "$service"
                log_info "Disabled $service"
            fi
        done
    }
    
    # Remove 3x-ui files and directories
    remove_3xui_files() {
        log_info "Removing 3x-ui files and directories"
        
        # List of directories and files to remove
        local paths=(
            "/usr/local/x-ui"
            "/etc/3x-ui"
            "/usr/local/bin/x-ui"
            "/etc/systemd/system/3x-ui.service"
            "/etc/systemd/system/xray.service"
            "/var/log/x-ui"
            "/var/log/3x-ui"
        )
        
        for path in "${paths[@]}"; do
            if [[ -e "$path" ]]; then
                rm -rf "$path"
                log_info "Removed $path"
            fi
        done
        
        # Remove xray binary if it's from 3x-ui (check if it's in /usr/local/bin/x-ui)
        if command -v xray >/dev/null 2>&1; then
            local xray_path
            xray_path=$(command -v xray)
            if [[ "$xray_path" == "/usr/local/x-ui/xray" ]]; then
                rm -f "$xray_path"
                log_info "Removed Xray binary"
            fi
        fi
    }
    
    # Main 3x-ui removal function
    # Usage: remove_3xui
    remove_3xui() {
        log_info "Removing 3x-ui panel"
        
        if ! is_3xui_installed; then
            log_info "3x-ui is not installed, skipping removal"
            return 0
        fi
        
        stop_3xui_service
        remove_3xui_files
        
        # Reload systemd daemon
        systemctl daemon-reload
        
        log_success "3x-ui removal completed"
    }
    
    # ------------------------------------------------------------------------
    # WARP Removal Functions
    # ------------------------------------------------------------------------
    
    # Check if WARP is installed (reuse from install-warp.sh)
    # Returns 0 if installed, 1 otherwise
    is_warp_installed() {
        # Use existing function if already sourced
        if command -v is_warp_installed >/dev/null 2>&1; then
            is_warp_installed
            return $?
        fi
        
        # Fallback detection
        if dpkg -l | grep -q cloudflare-warp; then
            log_info "WARP client detected via dpkg"
            return 0
        fi
        if command -v warp-cli >/dev/null 2>&1; then
            log_info "warp-cli binary detected"
            return 0
        fi
        return 1
    }
    
    # Stop and disable WARP service
    stop_warp_service() {
        log_info "Stopping WARP service"
        for service in warp-svc warp; do
            if systemctl is-active --quiet "$service" 2>/dev/null; then
                systemctl stop "$service"
                log_info "Stopped $service"
            fi
        done
        
        log_info "Disabling WARP service"
        for service in warp-svc warp; do
            if systemctl is-enabled --quiet "$service" 2>/dev/null; then
                systemctl disable "$service"
                log_info "Disabled $service"
            fi
        done
    }
    
    # Remove WARP client packages
    remove_warp_packages() {
        log_info "Removing WARP client packages"
        
        detect_os
        
        # Remove Cloudflare WARP repository to avoid future updates
        if [[ -f /etc/apt/sources.list.d/cloudflare-client.list ]]; then
            rm -f /etc/apt/sources.list.d/cloudflare-client.list
            log_info "Removed Cloudflare WARP repository"
        fi
        
        # Purge packages
        if dpkg -l | grep -q cloudflare-warp; then
            ${PKG_MANAGER} purge -y cloudflare-warp
            log_success "WARP client packages purged"
        else
            log_info "WARP client packages not found"
        fi
    }
    
    # Main WARP removal function
    # Usage: remove_warp
    remove_warp() {
        log_info "Removing WARP client"
        
        if ! is_warp_installed; then
            log_info "WARP is not installed, skipping removal"
            return 0
        fi
        
        stop_warp_service
        remove_warp_packages
        
        log_success "WARP removal completed"
    }
    
    # ------------------------------------------------------------------------
    # UFW Rule Removal Functions
    # ------------------------------------------------------------------------
    
    # Delete a UFW rule by port/protocol if it exists
    # Usage: delete_ufw_port "PORT[/PROTOCOL]"
    delete_ufw_port() {
        local port="$1"
        local proto="${2:-tcp}"
        local full_port="${port}"
        if [[ ! "$port" =~ / ]]; then
            full_port="${port}/${proto}"
        fi
        
        log_info "Checking for UFW rule: ${full_port}"
        
        # Check if rule exists (match port at start of line, followed by whitespace and ALLOW)
        if ufw status | grep -q -E "^${full_port}[[:space:]]+ALLOW"; then
            log_info "Deleting UFW rule: ${full_port}"
            ufw delete allow "${full_port}"
            log_success "Deleted UFW rule: ${full_port}"
        else
            log_info "UFW rule ${full_port} not found, skipping"
        fi
    }
    
    # Remove UFW rules added by installation
    # Usage: remove_ufw_rules
    remove_ufw_rules() {
        log_info "Removing UFW rules added by installation"
        
        # Delete SSH port rule
        delete_ufw_port "${SSH_PORT:-22}" "tcp"
        
        # Delete VLESS port rule
        delete_ufw_port "${VLESS_PORT:-443}" "tcp"
        
        # Delete web ports if reverse proxy was enabled
        if [[ "${ENABLE_REVERSE_PROXY:-false}" == "true" ]]; then
            delete_ufw_port "80" "tcp"
            delete_ufw_port "443" "tcp"
        fi
        
        log_success "UFW rule removal completed"
    }
    
    # ------------------------------------------------------------------------
    # iptables Rule Removal Functions
    # ------------------------------------------------------------------------
    
    # Check if iptables NAT rule exists (copied from setup-relay.sh)
    # Arguments: $1 - foreign IP, $2 - port
    nat_rule_exists() {
        local foreign_ip="$1"
        local port="$2"
        
        # Use iptables -C to check if rule exists (returns 0 if exists)
        iptables -t nat -C PREROUTING -p tcp --dport "${port}" -j DNAT --to-destination "${foreign_ip}:${port}" 2>/dev/null
    }
    
    # Delete iptables NAT rule if it exists
    # Arguments: $1 - foreign IP, $2 - port
    delete_iptables_nat_rule() {
        local foreign_ip="$1"
        local port="$2"
        
        log_info "Checking for iptables NAT rule: forward port ${port} to ${foreign_ip}"
        
        if nat_rule_exists "${foreign_ip}" "${port}"; then
            log_info "Deleting iptables NAT rule"
            iptables -t nat -D PREROUTING -p tcp --dport "${port}" -j DNAT --to-destination "${foreign_ip}:${port}"
            log_success "Deleted NAT rule"
        else
            log_info "NAT rule not found, skipping"
        fi
    }
    
    # Delete iptables MASQUERADE rule if it exists
    # Arguments: $1 - interface
    delete_iptables_masquerade_rule() {
        local interface="$1"
        
        log_info "Checking for MASQUERADE rule on interface ${interface}"
        
        if iptables -t nat -C POSTROUTING -o "${interface}" -j MASQUERADE 2>/dev/null; then
            log_info "Deleting MASQUERADE rule"
            iptables -t nat -D POSTROUTING -o "${interface}" -j MASQUERADE
            log_success "Deleted MASQUERADE rule"
        else
            log_info "MASQUERADE rule not found, skipping"
        fi
    }
    
    # Get default network interface (copied from setup-relay.sh)
    get_default_interface() {
        ip route show default | awk '/default/ {print $5}'
    }
    
    # Save iptables rules after deletion
    save_iptables_rules() {
        log_info "Saving iptables rules persistently"
        
        if command -v netfilter-persistent >/dev/null 2>&1; then
            netfilter-persistent save
        elif command -v iptables-save >/dev/null 2>&1; then
            iptables-save > /etc/iptables/rules.v4
            log_info "iptables rules saved to /etc/iptables/rules.v4"
        else
            log_error "Cannot save iptables rules: netfilter-persistent not found"
            return 1
        fi
        
        log_success "iptables rules saved"
    }
    
    # Remove iptables rules added by installation
    # Usage: remove_iptables_rules
    remove_iptables_rules() {
        log_info "Removing iptables rules added by installation"
        
        # Load configuration to get FOREIGN_VPS_IP and VLESS_PORT
        load_config
        
        # Validate required configuration
        if [[ -z "${FOREIGN_VPS_IP:-}" ]]; then
            log_error "FOREIGN_VPS_IP not set in configuration, cannot remove iptables rules"
            return 1
        fi
        if [[ -z "${VLESS_PORT:-}" ]]; then
            log_error "VLESS_PORT not set in configuration, cannot remove iptables rules"
            return 1
        fi
        
        # Get default interface
        local default_interface
        default_interface=$(get_default_interface)
        if [[ -z "${default_interface}" ]]; then
            log_error "Cannot determine default network interface"
            return 1
        fi
        
        # Delete rules
        delete_iptables_nat_rule "${FOREIGN_VPS_IP}" "${VLESS_PORT}"
        delete_iptables_masquerade_rule "${default_interface}"
        
        # Save rules
        save_iptables_rules
        
        log_success "iptables rule removal completed"
    }
    
    # ------------------------------------------------------------------------
    # Configuration Cleanup Functions
    # ------------------------------------------------------------------------
    
    # Remove configuration backups (if any)
    # Usage: remove_config_backups
    remove_config_backups() {
        log_info "Removing configuration backups"
        
        local backup_dir="${ORIGINAL_SCRIPT_DIR}/../backups"
        if [[ -d "${backup_dir}" ]]; then
            rm -rf "${backup_dir}"
            log_success "Removed backup directory: ${backup_dir}"
        else
            log_info "No backup directory found, skipping"
        fi
    }
    
    # Remove .env configuration file (only in hard mode)
    # Usage: remove_env_file
    remove_env_file() {
        log_info "Removing .env configuration file"
        
        local env_file="${ORIGINAL_SCRIPT_DIR}/../.env"
        if [[ -f "${env_file}" ]]; then
            rm -f "${env_file}"
            log_success "Removed .env file"
        else
            log_info ".env file not found, skipping"
        fi
    }
    
    # ------------------------------------------------------------------------
    # Orchestration Functions
    # ------------------------------------------------------------------------
    
    # Uninstall relay server components
    # Usage: uninstall_relay
    uninstall_relay() {
        log_info "=== Uninstalling RU relay server components ==="
        
        require_root
        load_config
        
        # Confirm action
        confirm_action "This will remove iptables forwarding rules and UFW rules on the relay server. Network connectivity may be affected." || return 0
        
        show_summary
        
        # Remove iptables rules
        remove_iptables_rules
        
        # Remove UFW rules
        remove_ufw_rules
        
        # Remove config backups if hard mode
        if [[ "${UNINSTALL_MODE}" == "hard" ]]; then
            remove_config_backups
            # Optionally remove .env? Keep as it may be shared.
        fi
        
        log_success "Relay server uninstall completed"
    }
    
    # Uninstall foreign server components
    # Usage: uninstall_foreign
    uninstall_foreign() {
        log_info "=== Uninstalling foreign VPS components ==="
        
        require_root
        load_config
        
        # Confirm action
        confirm_action "This will remove 3x-ui panel, WARP client, and UFW rules on the foreign server. VPN service will be stopped." || return 0
        
        show_summary
        
        # Remove 3x-ui
        remove_3xui
        
        # Remove WARP (if installed)
        if [[ "${ENABLE_WARP:-false}" == "true" ]]; then
            remove_warp
        fi
        
        # Remove UFW rules
        remove_ufw_rules
        
        # Remove config backups and .env if hard mode
        if [[ "${UNINSTALL_MODE}" == "hard" ]]; then
            remove_config_backups
            remove_env_file
        fi
        
        log_success "Foreign VPS uninstall completed"
    }
    
    # Uninstall all components (relay + foreign)
    # Usage: uninstall_all
    uninstall_all() {
        log_info "=== Uninstalling all VPN infrastructure components ==="
        
        # Note: This function assumes it's being run from a central location
        # and will need to handle remote execution for relay vs foreign.
        # For simplicity, we assume the script is run on each server separately.
        # We'll output instructions.
        
        log_info "The '--all' target requires running uninstall on each server."
        log_info "Please run on relay server: sudo ./uninstall.sh --relay --${UNINSTALL_MODE}"
        log_info "Please run on foreign server: sudo ./uninstall.sh --foreign --${UNINSTALL_MODE}"
        log_info "Alternatively, use SSH to run remotely."
        
        # We could implement remote execution via SSH, but for simplicity we'll
        # keep the pattern consistent with other scripts (run on target server).
        # The install.sh handles remote execution via SSH? Not yet.
        # We'll just delegate.
        
        confirm_action "This will uninstall both relay and foreign components. You need to run uninstall on each server separately. Do you want to continue with local uninstall?" || return 0
        
        # Determine which server we're on based on presence of 3x-ui
        if is_3xui_installed; then
            log_info "Detected foreign server (3x-ui installed)"
            uninstall_foreign
        else
            log_info "Assuming relay server (no 3x-ui detected)"
            uninstall_relay
        fi
    }
    
    # ------------------------------------------------------------------------
    # Argument Parsing and Help
    # ------------------------------------------------------------------------
    
    show_help() {
        cat <<EOF
3x-ui VPN Automation Uninstaller

Usage: $0 [OPTIONS]

Options:
    --relay       Uninstall RU relay server components only
    --foreign     Uninstall foreign VPS components only
    --all         Uninstall both relay and foreign components (default)
    --soft        Soft reset: keep configuration files, remove only services
    --hard        Hard reset: remove everything including configuration (default)
    --force       Skip confirmation prompts (use with caution)
    --help        Show this help message

Examples:
    $0 --relay --soft          # Remove relay iptables/UFW rules, keep configs
    $0 --foreign --hard        # Remove 3x-ui, WARP, UFW rules, delete configs
    $0 --all --soft            # Uninstall everything, keep configs (run on each server)

Notes:
    - This script must be run as root (use sudo).
    - For '--all', you need to run the script on both relay and foreign servers.
    - Soft reset keeps .env and backup files; hard reset removes them.

EOF
    }
    
    parse_args() {
        while [[ $# -gt 0 ]]; do
            case "$1" in
                --relay)
                    UNINSTALL_TARGET="relay"
                    ;;
                --foreign)
                    UNINSTALL_TARGET="foreign"
                    ;;
                --all)
                    UNINSTALL_TARGET="all"
                    ;;
                --soft)
                    UNINSTALL_MODE="soft"
                    ;;
                --hard)
                    UNINSTALL_MODE="hard"
                    ;;
                --force)
                    FORCE_CONFIRM=true
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
            shift
        done
    }
    
    # Main uninstall function
    # Usage: main_uninstall
    main_uninstall() {
        log_info "Starting 3x-ui VPN automation uninstall"
        
        parse_args "$@"
        show_summary
        
        case "${UNINSTALL_TARGET}" in
            relay)
                uninstall_relay
                ;;
            foreign)
                uninstall_foreign
                ;;
            all)
                uninstall_all
                ;;
            *)
                log_error "Invalid target: ${UNINSTALL_TARGET}"
                show_help
                exit 1
                ;;
        esac
        
        log_success "Uninstall completed successfully"
    }
    
    # Export functions for use in other scripts
    export -f confirm_action require_root show_summary \
             is_3xui_installed stop_3xui_service remove_3xui_files remove_3xui \
             is_warp_installed stop_warp_service remove_warp_packages remove_warp \
             delete_ufw_port remove_ufw_rules \
             nat_rule_exists delete_iptables_nat_rule delete_iptables_masquerade_rule \
             get_default_interface save_iptables_rules remove_iptables_rules \
             remove_config_backups remove_env_file \
             uninstall_relay uninstall_foreign uninstall_all \
             main_uninstall
    
    # If script is executed directly (not sourced), run main_uninstall
    if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
        main_uninstall "$@"
    fi
fi