#!/usr/bin/env bash
# Reverse proxy setup script for 3x-ui VPN automation
# Installs nginx and configures reverse proxy to 3x-ui panel with TLS.

set -euo pipefail

# Check if functions already defined to allow idempotent sourcing
if ! command -v setup_reverse_proxy >/dev/null 2>&1; then
    # Determine script directory to source dependencies
    SETUP_REVERSE_PROXY_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    
    # Source logging utilities
    # shellcheck source=../common/logging.sh
    source "${SETUP_REVERSE_PROXY_SCRIPT_DIR}/../common/logging.sh"
    
    # Source OS detection utilities
    # shellcheck source=../common/os-detection.sh
    source "${SETUP_REVERSE_PROXY_SCRIPT_DIR}/../common/os-detection.sh"
    
    # Source configuration loading utilities
    # shellcheck source=../common/load-config.sh
    source "${SETUP_REVERSE_PROXY_SCRIPT_DIR}/../common/load-config.sh"
    
    # Source configuration validation utilities
    # shellcheck source=../common/validate-config.sh
    source "${SETUP_REVERSE_PROXY_SCRIPT_DIR}/../common/validate-config.sh"
    
    # ------------------------------------------------------------------------
    # Reverse Proxy Installation Functions
    # ------------------------------------------------------------------------
    
    # Check if nginx is already installed
    # Returns 0 if installed, 1 otherwise
    is_nginx_installed() {
        if command -v nginx >/dev/null 2>&1; then
            log_info "nginx is already installed"
            return 0
        fi
        return 1
    }
    
    # Install nginx
    # Usage: install_nginx
    install_nginx() {
        log_info "Installing nginx"
        
        if is_nginx_installed; then
            log_info "nginx already installed, skipping"
            return 0
        fi
        
        detect_os
        "${PKG_MANAGER}" "${PKG_UPDATE}"
        "${PKG_MANAGER}" "${PKG_INSTALL}" nginx
        log_success "nginx installed successfully"
    }
    
    # Check if nginx reverse proxy is already configured for 3x-ui
    # Returns 0 if configured, 1 otherwise
    is_nginx_reverse_proxy_configured() {
        local site_file="/etc/nginx/sites-available/3x-ui"
        local enabled_link="/etc/nginx/sites-enabled/3x-ui"
        
        if [[ -f "$site_file" && -L "$enabled_link" ]]; then
            log_info "nginx reverse proxy configuration detected"
            return 0
        fi
        return 1
    }
    
    # Configure nginx reverse proxy for 3x-ui
    # Usage: configure_nginx_reverse_proxy
    configure_nginx_reverse_proxy() {
        log_info "Configuring nginx reverse proxy for 3x-ui"
        
        if is_nginx_reverse_proxy_configured; then
            log_info "nginx reverse proxy already configured, skipping"
            return 0
        fi
        
        # Validate DOMAIN is set and valid
        validate_required "DOMAIN"
        validate_domain "DOMAIN"
        
        # Validate PANEL_PORT is set (default 2053 from load-config)
        local panel_port="${PANEL_PORT:-2053}"
        
        # Create nginx site configuration
        local site_file="/etc/nginx/sites-available/3x-ui"
        local site_content
        site_content=$(cat <<EOF
# 3x-ui reverse proxy configuration
server {
    listen 80;
    server_name ${DOMAIN};
    return 301 https://\$server_name\$request_uri;
}

server {
    listen 443 ssl http2;
    server_name ${DOMAIN};
    
    # SSL configuration (to be filled by certbot)
    ssl_certificate /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;
    include /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;
    
    # Security headers
    add_header X-Frame-Options DENY;
    add_header X-Content-Type-Options nosniff;
    add_header X-XSS-Protection "1; mode=block";
    
    # Proxy settings
    location / {
        proxy_pass http://127.0.0.1:${panel_port};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF
        )
        
        # Write configuration file
        echo "$site_content" > "$site_file"
        log_success "nginx site configuration written to $site_file"
        
        # Create symlink in sites-enabled
        ln -sf "$site_file" "/etc/nginx/sites-enabled/"
        log_success "nginx site enabled"
        
        # Test nginx configuration
        if ! nginx -t; then
            log_error "nginx configuration test failed"
            die "Please check nginx configuration"
        fi
        
        log_success "nginx reverse proxy configuration completed"
    }
    
    # Check if SSL certificate is already obtained for domain
    # Returns 0 if certificate exists, 1 otherwise
    is_ssl_certificate_obtained() {
        local cert_dir="/etc/letsencrypt/live/${DOMAIN}"
        if [[ -d "$cert_dir" && -f "$cert_dir/fullchain.pem" && -f "$cert_dir/privkey.pem" ]]; then
            log_info "SSL certificate for ${DOMAIN} already exists"
            return 0
        fi
        return 1
    }
    
    # Obtain SSL certificate using certbot
    # Usage: obtain_ssl_certificate
    obtain_ssl_certificate() {
        log_info "Obtaining SSL certificate for ${DOMAIN}"
        
        if is_ssl_certificate_obtained; then
            log_info "SSL certificate already exists, skipping"
            return 0
        fi
        
        # Install certbot and nginx plugin
        detect_os
        if ! command -v certbot >/dev/null 2>&1; then
            log_info "Installing certbot"
            "${PKG_MANAGER}" "${PKG_INSTALL}" certbot python3-certbot-nginx
        fi
        
        # Obtain certificate (non-interactive)
        log_info "Requesting Let's Encrypt certificate"
        if ! certbot --nginx --non-interactive --agree-tos --no-eff-email --domains "${DOMAIN}" --redirect; then
            log_error "Failed to obtain SSL certificate"
            die "Certbot failed. Check DNS and ensure domain points to this server."
        fi
        
        log_success "SSL certificate obtained successfully"
    }
    
    # Restart nginx service
    # Usage: restart_nginx
    restart_nginx() {
        log_info "Restarting nginx service"
        if systemctl restart nginx; then
            log_success "nginx restarted successfully"
        else
            log_error "Failed to restart nginx"
            die "nginx service restart failed"
        fi
    }
    
    # Main reverse proxy setup function
    # Usage: setup_reverse_proxy
    setup_reverse_proxy() {
        log_info "Starting reverse proxy setup"
        
        # Ensure script is run as root
        if [[ $EUID -ne 0 ]]; then
            die "This script must be run as root (use sudo)"
        fi
        
        # Setup trap for cleanup
        setup_trap 'log_error "Reverse proxy setup failed. Check logs for details."'
        
        # Load configuration (ensures variables are exported)
        load_config
        
        # Check if reverse proxy is enabled
        if [[ "${ENABLE_REVERSE_PROXY:-false}" != "true" ]]; then
            log_info "Reverse proxy not enabled, skipping setup"
            return 0
        fi
        
        # Validate required configuration
        validate_required "DOMAIN"
        validate_domain "DOMAIN"
        
        log_info "Setting up reverse proxy for domain: ${DOMAIN}"
        
        # Install nginx
        install_nginx
        
        # Configure nginx reverse proxy
        configure_nginx_reverse_proxy
        
        # Obtain SSL certificate
        obtain_ssl_certificate
        
        # Restart nginx to apply changes
        restart_nginx
        
        log_success "Reverse proxy setup completed successfully"
        log_info "Panel accessible at: https://${DOMAIN}"
    }
    
    # Export functions for use in other scripts
    export -f is_nginx_installed install_nginx is_nginx_reverse_proxy_configured \
             configure_nginx_reverse_proxy is_ssl_certificate_obtained \
             obtain_ssl_certificate restart_nginx setup_reverse_proxy
    
    # If script is executed directly (not sourced), run setup_reverse_proxy
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
        
        # Run setup
        setup_reverse_proxy
    fi
fi