#!/usr/bin/env bash

# Main installation script for 3x-ui VPN Automation
# Usage: ./install.sh [--relay|--foreign|--all] [--help]

set -euo pipefail

# --- Configuration ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/.env"
LOG_DIR="${SCRIPT_DIR}/logs"

# --- Source common utilities ---
# shellcheck source=scripts/common/logging.sh
source "${SCRIPT_DIR}/scripts/common/logging.sh"

# shellcheck source=scripts/common/os-detection.sh
source "${SCRIPT_DIR}/scripts/common/os-detection.sh"

# shellcheck source=scripts/common/load-config.sh
source "${SCRIPT_DIR}/scripts/common/load-config.sh"

# --- Cleanup traps ---
cleanup() {
    log_info "Cleaning up..."
    # Placeholder for any cleanup tasks
}
setup_trap cleanup

# --- Help function ---
show_help() {
    cat <<EOF
3x-ui VPN Automation Installer

Usage: $0 [OPTION]

Options:
    --relay       Install and configure RU relay server only
    --foreign     Install and configure foreign VPS (3x-ui) only
    --all         Full deployment (relay + foreign)
    --help        Show this help message

Examples:
    $0 --all          # Deploy complete infrastructure
    $0 --relay        # Deploy only RU relay server
    $0 --foreign      # Deploy only foreign VPS

Configuration:
    Copy .env.example to .env and fill in required parameters before running.

EOF
}

# --- Argument parsing ---
parse_args() {
    if [[ $# -eq 0 ]]; then
        log_error "No arguments provided. Use --help for usage."
        exit 1
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

# --- Main installation routine ---
install_relay() {
    log_info "Installing RU relay server..."
    "${SCRIPT_DIR}/scripts/relay/setup-relay.sh"
    log_success "RU relay installation completed"
}

install_foreign() {
    log_info "Installing foreign VPS with 3x-ui..."
    
    # Install 3x-ui panel
    "${SCRIPT_DIR}/scripts/foreign/install-3xui.sh"
    
    # Configure VLESS+Reality inbound
    "${SCRIPT_DIR}/scripts/foreign/configure-vless-reality.sh"
    
    # Install WARP if enabled
    if [[ "${ENABLE_WARP:-false}" == "true" ]]; then
        "${SCRIPT_DIR}/scripts/foreign/install-warp.sh"
    else
        log_info "WARP installation disabled (ENABLE_WARP=false)"
    fi
    
    # Configure outbounds (direct and optionally WARP)
    "${SCRIPT_DIR}/scripts/foreign/configure-outbounds.sh"
    
    # Configure server-side routing
    "${SCRIPT_DIR}/scripts/foreign/configure-server-routing.sh"
    
    # Setup reverse proxy if enabled
    if [[ "${ENABLE_REVERSE_PROXY:-false}" == "true" ]]; then
        "${SCRIPT_DIR}/scripts/foreign/setup-reverse-proxy.sh"
    else
        log_info "Reverse proxy disabled (ENABLE_REVERSE_PROXY=false)"
    fi
    
    log_success "Foreign VPS installation completed"
}

main() {
    log_info "Starting 3x-ui VPN Automation deployment"
    
    # Load and validate configuration
    load_config "${CONFIG_FILE}"

    # Create logs directory
    mkdir -p "${LOG_DIR}"

    case "${TARGET:-}" in
        relay)
            install_relay
            ;;
        foreign)
            install_foreign
            ;;
        all)
            install_relay
            install_foreign
            ;;
        *)
            log_error "Installation target not set. This should not happen."
            exit 1
            ;;
    esac

    # Run health-check for the installed component(s)
    log_info "Running health check..."
    case "${TARGET:-}" in
        relay)
            "${SCRIPT_DIR}/scripts/health-check.sh" --relay
            ;;
        foreign)
            "${SCRIPT_DIR}/scripts/health-check.sh" --foreign
            ;;
        all)
            "${SCRIPT_DIR}/scripts/health-check.sh" --all
            ;;
    esac

    log_success "Deployment completed successfully!"
}

# --- Entry point ---
parse_args "$@"
main