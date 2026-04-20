#!/usr/bin/env bash
# Common logging and error handling utilities for 3x-ui VPN automation
# Source this file in your bash scripts to use standardized logging.

set -euo pipefail

# Check if functions already defined to allow idempotent sourcing
if ! command -v log_info >/dev/null 2>&1; then
    # Color support detection: only use colors if output is a terminal
    if [[ -t 1 ]]; then
        __color_red="\033[0;31m"
        __color_green="\033[0;32m"
        __color_blue="\033[0;34m"
        __color_reset="\033[0m"
    else
        __color_red=""
        __color_green=""
        __color_blue=""
        __color_reset=""
    fi

    log_info() {
        printf "${__color_blue}[INFO]${__color_reset} %s\n" "$(date -Is) $*"
    }

    log_error() {
        printf "${__color_red}[ERROR]${__color_reset} %s\n" "$(date -Is) $*" >&2
    }

    log_success() {
        printf "${__color_green}[SUCCESS]${__color_reset} %s\n" "$(date -Is) $*"
    }

    # Helper to exit with error message
    die() {
        log_error "$*"
        exit 1
    }
fi

# Setup trap for cleanup. Usage: setup_trap "cleanup_command"
# Appends to existing traps to avoid overwriting.
setup_trap() {
    local cmd="$1"
    # Get existing trap command for EXIT, INT, TERM signals
    local existing_trap
    existing_trap=$(trap -p EXIT | cut -d"'" -f2)
    if [[ -n "$existing_trap" ]]; then
        cmd="$existing_trap; $cmd"
    fi
    trap -- "$cmd" EXIT INT TERM
}

# Export functions so they're available in sourced scripts
export -f log_info log_error log_success die setup_trap