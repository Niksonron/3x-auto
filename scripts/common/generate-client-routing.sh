#!/usr/bin/env bash
# Client routing configuration generator for 3x-ui VPN automation
# Generates routing rules based on geoip/geosite data (RU→direct, default→proxy).
# Output format is JSON compatible with Xray/V2Ray clients.

set -euo pipefail

# Check if functions already defined to allow idempotent sourcing
if ! command -v generate_client_routing >/dev/null 2>&1; then
    # Determine script directory to source dependencies
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    
    # Source logging utilities
    # shellcheck source=logging.sh
    source "${SCRIPT_DIR}/logging.sh"
    
    # ------------------------------------------------------------------------
    # Routing Generation Functions
    # ------------------------------------------------------------------------
    
    # Generate a JSON routing object with RU→direct and default→proxy rules.
    # Usage: generate_client_routing [direct_tag] [proxy_tag] [domain_strategy]
    # Arguments:
    #   direct_tag      - outbound tag for direct traffic (default: "direct")
    #   proxy_tag       - outbound tag for proxy traffic (default: "proxy")
    #   domain_strategy - routing domain strategy (default: "AsIs")
    # Output: JSON string containing complete "routing" object.
    generate_client_routing() {
        local direct_tag="${1:-direct}"
        local proxy_tag="${2:-proxy}"
        local domain_strategy="${3:-AsIs}"
        
        cat <<EOF
{
  "domainStrategy": "${domain_strategy}",
  "rules": [
    {
      "type": "field",
      "ip": ["geoip:ru"],
      "outboundTag": "${direct_tag}"
    },
    {
      "type": "field",
      "domain": ["geosite:ru"],
      "outboundTag": "${direct_tag}"
    },
    {
      "type": "field",
      "port": "0-65535",
      "outboundTag": "${proxy_tag}"
    }
  ]
}
EOF
    }
    
    # Generate routing JSON and write it to a file.
    # Usage: generate_client_routing_file <output_path> [direct_tag] [proxy_tag] [domain_strategy]
    # Arguments:
    #   output_path     - path where JSON will be written (required)
    #   direct_tag, proxy_tag, domain_strategy - same as generate_client_routing
    generate_client_routing_file() {
        if [[ $# -lt 1 ]]; then
            log_error "Usage: generate_client_routing_file <output_path> [direct_tag] [proxy_tag] [domain_strategy]"
            return 1
        fi
        local output_path="$1"
        local direct_tag="${2:-direct}"
        local proxy_tag="${3:-proxy}"
        local domain_strategy="${4:-AsIs}"
        
        log_info "Generating client routing configuration..."
        log_info "Direct tag: ${direct_tag}, Proxy tag: ${proxy_tag}, Domain strategy: ${domain_strategy}"
        
        generate_client_routing "${direct_tag}" "${proxy_tag}" "${domain_strategy}" > "${output_path}"
        
        if [[ -f "${output_path}" ]]; then
            log_success "Routing configuration written to ${output_path}"
        else
            log_error "Failed to write routing configuration to ${output_path}"
            return 1
        fi
    }
    
    # Validate that supplied tags are alphanumeric (basic sanity check).
    # Usage: validate_routing_tags <direct_tag> <proxy_tag>
    # Returns 0 if valid, 1 otherwise.
    validate_routing_tags() {
        local direct_tag="$1"
        local proxy_tag="$2"
        local alnum_regex='^[a-zA-Z0-9_-]+$'
        
        if [[ ! "${direct_tag}" =~ ${alnum_regex} ]]; then
            log_error "Invalid direct tag '${direct_tag}': must be alphanumeric (including underscores and hyphens)"
            return 1
        fi
        if [[ ! "${proxy_tag}" =~ ${alnum_regex} ]]; then
            log_error "Invalid proxy tag '${proxy_tag}': must be alphanumeric (including underscores and hyphens)"
            return 1
        fi
        return 0
    }
    
    # ------------------------------------------------------------------------
    # Export functions for use in other scripts
    # ------------------------------------------------------------------------
    
    export -f generate_client_routing generate_client_routing_file validate_routing_tags
    
    # ------------------------------------------------------------------------
    # Main function for direct script execution
    # ------------------------------------------------------------------------
    
    main() {
        # Parse optional arguments
        local direct_tag="direct"
        local proxy_tag="proxy"
        local domain_strategy="AsIs"
        local output_file=""
        
        while [[ $# -gt 0 ]]; do
            case "$1" in
                --direct-tag)
                    direct_tag="$2"
                    shift 2
                    ;;
                --proxy-tag)
                    proxy_tag="$2"
                    shift 2
                    ;;
                --domain-strategy)
                    domain_strategy="$2"
                    shift 2
                    ;;
                --output)
                    output_file="$2"
                    shift 2
                    ;;
                --help|-h)
                    cat <<HELP
Usage: $0 [OPTIONS]

Generate client-side routing rules for VLESS clients.

Options:
  --direct-tag TAG      Outbound tag for direct traffic (default: direct)
  --proxy-tag TAG       Outbound tag for proxy traffic (default: proxy)
  --domain-strategy STR Routing domain strategy (default: AsIs)
  --output FILE         Write JSON to FILE instead of stdout
  --help, -h            Show this help message

Outputs a JSON routing object with rules:
  1. Russian IPs (geoip:ru) → direct tag
  2. Russian domains (geosite:ru) → direct tag
  3. All other traffic (port 0-65535) → proxy tag

Example:
  $0 --direct-tag freedom --proxy-tag vless --output routing.json
HELP
                    exit 0
                    ;;
                *)
                    log_error "Unknown option: $1"
                    log_error "Use --help for usage"
                    exit 1
                    ;;
            esac
        done
        
        # Validate tags (basic check)
        if ! validate_routing_tags "${direct_tag}" "${proxy_tag}"; then
            exit 1
        fi
        
        # Generate routing JSON
        local routing_json
        routing_json="$(generate_client_routing "${direct_tag}" "${proxy_tag}" "${domain_strategy}")"
        
        # Output to file or stdout
        if [[ -n "${output_file}" ]]; then
            echo "${routing_json}" > "${output_file}"
            log_info "Routing configuration written to ${output_file}"
        else
            echo "${routing_json}"
        fi
    }
    
    # If script is executed directly (not sourced), run main
    if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
        main "$@"
    fi
fi