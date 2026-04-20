#!/usr/bin/env bash
# Cloudflare WARP installation script for 3x-ui VPN automation
# Installs and configures Cloudflare WARP client on foreign server.

set -euo pipefail

# Check if functions already defined to allow idempotent sourcing
if ! command -v install_warp >/dev/null 2>&1; then
    # Determine script directory to source dependencies
    INSTALL_WARP_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    
    # Source logging utilities
    # shellcheck source=../common/logging.sh
    source "${INSTALL_WARP_SCRIPT_DIR}/../common/logging.sh"
    
    # Source OS detection utilities
    # shellcheck source=../common/os-detection.sh
    source "${INSTALL_WARP_SCRIPT_DIR}/../common/os-detection.sh"
    
    # Source configuration loading utilities
    # shellcheck source=../common/load-config.sh
    source "${INSTALL_WARP_SCRIPT_DIR}/../common/load-config.sh"
    
    # ------------------------------------------------------------------------
    # WARP Installation Functions
    # ------------------------------------------------------------------------
    
    # Check if WARP client is already installed
    # Returns 0 if installed, 1 otherwise
    is_warp_installed() {
        if command -v warp-cli >/dev/null 2>&1; then
            log_info "WARP client binary detected"
            return 0
        fi
        if systemctl list-unit-files | grep -q warp-svc; then
            log_info "WARP service detected"
            return 0
        fi
        if dpkg -l | grep -q cloudflare-warp; then
            log_info "cloudflare-warp package installed"
            return 0
        fi
        return 1
    }
    
    # Check if WARP is currently connected
    # Returns 0 if connected, 1 otherwise
    is_warp_connected() {
        if ! command -v warp-cli >/dev/null 2>&1; then
            return 1
        fi
        local status_line
        status_line="$(warp-cli status 2>/dev/null | grep -i 'status')"
        local status_lower
        status_lower="$(echo "${status_line}" | tr '[:upper:]' '[:lower:]')"
        if [[ "${status_lower}" == *"connected"* ]]; then
            return 0
        else
            return 1
        fi
    }
    
    # Install WARP client from Cloudflare repository
    # Usage: install_warp_client
    install_warp_client() {
        log_info "Installing Cloudflare WARP client"
        
        # Check if already installed
        if is_warp_installed; then
            log_info "WARP client is already installed, skipping installation"
            return 0
        fi
        
        # Ensure curl and gpg are available
        detect_os
        if ! command -v curl >/dev/null 2>&1; then
            log_info "Installing curl"
            "${PKG_MANAGER}" "${PKG_UPDATE}"
            "${PKG_MANAGER}" "${PKG_INSTALL}" curl
        fi
        if ! command -v gpg >/dev/null 2>&1; then
            log_info "Installing gpg"
            "${PKG_MANAGER}" "${PKG_INSTALL}" gpg
        fi
        
        # Add Cloudflare GPG key (if not already present)
        local keyring_path="/usr/share/keyrings/cloudflare-archive-keyring.gpg"
        if [[ ! -f "${keyring_path}" ]]; then
            log_info "Adding Cloudflare GPG key"
            curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg | gpg --dearmor -o "${keyring_path}"
        else
            log_info "Cloudflare GPG key already exists, skipping"
        fi
        
        # Add Cloudflare repository (if not already present)
        local repo_path="/etc/apt/sources.list.d/cloudflare-warp.list"
        if [[ ! -f "${repo_path}" ]]; then
            log_info "Adding Cloudflare WAPT repository"
            echo "deb [signed-by=${keyring_path}] https://pkg.cloudflare.com/cloudflare-warp $(lsb_release -cs) main" > "${repo_path}"
        else
            log_info "Cloudflare repository already exists, skipping"
        fi
        
        # Update package list and install cloudflare-warp
        log_info "Installing cloudflare-warp package"
        "${PKG_MANAGER}" "${PKG_UPDATE}"
        "${PKG_MANAGER}" "${PKG_INSTALL}" cloudflare-warp
        
        # Verify installation
        if ! is_warp_installed; then
            log_error "WARP installation seems to have failed"
            return 1
        fi
        
        log_success "WARP client installation completed"
    }
    
    # Ensure WARP service is running
    # Usage: ensure_warp_service
    ensure_warp_service() {
        log_info "Ensuring WARP service is running"
        if systemctl is-active --quiet warp-svc 2>/dev/null; then
            log_info "WARP service is already running"
        else
            log_info "Starting WARP service"
            systemctl enable --now warp-svc 2>/dev/null || log_warning "Failed to start WARP service"
        fi
    }
    
    # Register WARP service (if not already registered)
    # Usage: register_warp
    register_warp() {
        log_info "Registering WARP service"
        
        # Check if already registered (warp-cli account shows something)
        local account_output
        if account_output="$(warp-cli account 2>/dev/null)"; then
            if [[ "${account_output}" == *"Missing registration"* ]]; then
                log_info "WARP not registered, proceeding with registration"
            else
                log_info "WARP already registered"
                return 0
            fi
        fi
        
        # Attempt registration (non-interactive)
        if ! warp-cli register 2>&1 | grep -q "Successfully registered"; then
            log_warning "WARP registration may have failed"
            # Continue anyway; connection might still work
        else
            log_info "WARP registration successful"
        fi
    }
    
    # Connect WARP service (if not already connected)
    # Usage: connect_warp
    connect_warp() {
        log_info "Connecting WARP service"
        
        if is_warp_connected; then
            log_info "WARP is already connected"
            return 0
        fi
        
        # Enable warp mode (if not already)
        warp-cli mode warp >/dev/null 2>&1
        
        # Connect
        if warp-cli connect 2>&1 | grep -q "Successfully connected"; then
            log_info "WARP connection successful"
        else
            log_warning "WARP connection may have failed"
            return 1
        fi
        
        # Wait a few seconds for connection to establish
        sleep 5
        
        # Verify connection
        if is_warp_connected; then
            log_success "WARP is connected"
            return 0
        else
            log_error "WARP failed to connect"
            return 1
        fi
    }
    
    # Verify WARP connectivity and external IP
    # Usage: verify_warp_connectivity
    verify_warp_connectivity() {
        log_info "Verifying WARP connectivity"
        
        if ! is_warp_connected; then
            log_error "WARP is not connected"
            return 1
        fi
        
        # Get external IP via WARP
        local warp_ip
        warp_ip="$(curl -fsSL --max-time 10 https://ifconfig.me/ip 2>/dev/null || curl -fsSL --max-time 10 https://api.ipify.org 2>/dev/null || echo "")"
        if [[ -z "${warp_ip}" ]]; then
            log_warning "Could not determine external IP; connectivity test inconclusive"
            return 1
        fi
        
        log_info "WARP external IP: ${warp_ip}"
        
        # Check if IP belongs to Cloudflare ranges (basic check)
        if [[ "${warp_ip}" =~ ^104\\.28\\. || "${warp_ip}" =~ ^104\\.27\\. || "${warp_ip}" =~ ^172\\.64\\. ]]; then
            log_success "External IP appears to be Cloudflare IP (WARP working)"
            return 0
        else
            log_warning "External IP does not appear to be Cloudflare IP (may be direct connection)"
            # Still return success; WARP may be using different IP ranges
            return 0
        fi
    }
    
    # Fallback to direct outbound (disable WARP)
    # Usage: fallback_to_direct
    fallback_to_direct() {
        log_warning "Falling back to direct outbound (WARP not available)"
        
        # Disconnect WARP if connected
        if is_warp_connected; then
            warp-cli disconnect >/dev/null 2>&1 || true
        fi
        
        # Set ENABLE_WARP=false for subsequent steps
        export ENABLE_WARP="false"
        
        log_info "WARP disabled, using direct outbound"
    }
    
    # Main WARP installation function
    # Usage: install_warp
    install_warp() {
        log_info "Starting WARP installation"
        
        # Setup trap for cleanup (if needed)
        setup_trap 'log_error "WARP installation failed. Check logs for details."'
        
        # Load configuration (ensures variables are exported)
        load_config
        
        # Check if WARP is enabled
        if [[ "${ENABLE_WARP:-false}" != "true" ]]; then
            log_info "WARP is disabled (ENABLE_WARP=false), skipping installation"
            return 0
        fi
        
        # Install WARP client
        if ! install_warp_client; then
            log_error "WARP client installation failed, falling back to direct outbound"
            fallback_to_direct
            return 0  # Successfully fell back, continue installation without WARP
        fi
        
        # Ensure WARP service is running
        ensure_warp_service
        
        # Register WARP service
        if ! register_warp; then
            log_warning "WARP registration failed, continuing anyway"
            # Continue anyway; connection might still work
        fi
        
        # Connect WARP service
        if ! connect_warp; then
            log_error "WARP connection failed, falling back to direct outbound"
            fallback_to_direct
            return 0  # Successfully fell back, continue installation without WARP
        fi
        
        # Verify connectivity
        if ! verify_warp_connectivity; then
            log_warning "WARP connectivity verification failed, falling back to direct outbound"
            fallback_to_direct
            return 0  # Successfully fell back, continue installation without WARP
        fi
        
        log_success "WARP installation and configuration completed successfully"
    }
    
    # Export functions for use in other scripts
    export -f is_warp_installed is_warp_connected install_warp_client ensure_warp_service register_warp \
             connect_warp verify_warp_connectivity fallback_to_direct install_warp
    
    # If script is executed directly (not sourced), run install_warp
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
        install_warp
    fi
fi