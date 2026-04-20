#!/usr/bin/env bash
# OS detection and compatibility utilities for 3x-ui VPN automation
# Source this file in your bash scripts to detect OS and set package manager variables.

set -euo pipefail

# Check if functions already defined to allow idempotent sourcing
if ! command -v detect_os >/dev/null 2>&1; then
    # Simple logging functions if logging.sh not sourced
    if ! command -v log_error >/dev/null 2>&1; then
        # Color support detection: only use colors if output is a terminal
        if [[ -t 2 ]]; then
            __color_red="\033[0;31m"
            __color_reset="\033[0m"
        else
            __color_red=""
            __color_reset=""
        fi
        log_error() {
            printf "%s[ERROR]%s %s\n" "$__color_red" "$__color_reset" "$(date -Is) $*" >&2
        }
    fi

    detect_os() {
        # Source /etc/os-release if available
        if [[ -f /etc/os-release ]]; then
            # shellcheck source=/dev/null
            . /etc/os-release
            OS_ID="${ID:-}"
            OS_VERSION="${VERSION_ID:-}"
            OS_CODENAME="${VERSION_CODENAME:-}"
        else
            # Fallback to lsb_release
            if command -v lsb_release >/dev/null 2>&1; then
                OS_ID=$(lsb_release -is | tr '[:upper:]' '[:lower:]')
                OS_VERSION=$(lsb_release -rs)
                OS_CODENAME=$(lsb_release -cs)
            else
                log_error "Cannot detect OS: /etc/os-release not found and lsb_release not available."
                exit 1
            fi
        fi

        # Validate supported OS
        case "${OS_ID}" in
            ubuntu|debian)
                # Valid OS
                ;;
            *)
                log_error "Unsupported OS detected: ${OS_ID}"
                log_error "This automation only supports Ubuntu and Debian."
                exit 1
                ;;
        esac

        # Export OS variables for use in other scripts
        export OS_ID OS_VERSION OS_CODENAME
    }

    # Set package manager variables
    # Use apt if available (newer Ubuntu/Debian), otherwise apt-get
    if command -v apt >/dev/null 2>&1; then
        PKG_MANAGER="apt"
    else
        PKG_MANAGER="apt-get"
    fi
    PKG_INSTALL="install -y"
    PKG_UPDATE="update"
    PKG_UPGRADE="upgrade -y"

    # Export variables for use in other scripts
    export PKG_MANAGER PKG_INSTALL PKG_UPDATE PKG_UPGRADE

    # Export functions
    export -f detect_os log_error
fi