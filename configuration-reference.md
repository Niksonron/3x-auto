# Configuration Reference

This document explains every parameter in the `.env` configuration file used by the 3x‑ui VPN automation scripts.

## File Location & Usage

- **Template**: `.env.example` – copy this file to `.env` and fill in the values.
- **Loading**: All scripts source `.env` via `scripts/common/load‑config.sh`, which also sets default values and generates missing parameters.
- **Validation**: `scripts/common/validate‑config.sh` checks parameter formats before any installation steps.

## Parameter Sections

### 1. Server IP Addresses

#### `RU_RELAY_IP`
- **Description**: Public IPv4 address of the RU relay server (the server located in Russia or your relay region).
- **Required**: Yes
- **Format**: Valid IPv4 address (e.g., `192.0.2.10`).
- **Validation**: Must be a reachable IP; script will attempt SSH connectivity.
- **Example**: `RU_RELAY_IP="192.0.2.10"`

#### `FOREIGN_VPS_IP`
- **Description**: Public IPv4 address of the foreign VPS (the server that runs 3x‑ui and acts as egress point).
- **Required**: Yes
- **Format**: Valid IPv4 address (e.g., `203.0.113.20`).
- **Validation**: Must be a reachable IP; script will attempt SSH connectivity.
- **Example**: `FOREIGN_VPS_IP="203.0.113.20"`

### 2. SSH Access Configuration

#### `SSH_USER`
- **Description**: Username for SSH access to both servers. This user must have sudo privileges (or be root).
- **Required**: Yes
- **Default**: `"root"`
- **Validation**: Must be a valid Unix username (alphanumeric plus underscores).
- **Example**: `SSH_USER="admin"`

#### `SSH_PUBLIC_KEY`
- **Description**: The **public** SSH key that will be used for authentication. Password authentication will be disabled on both servers.
- **Required**: Yes
- **Format**: A single line from your `~/.ssh/id_ed25519.pub` or `~/.ssh/id_rsa.pub` file.
- **Validation**: Must start with `ssh‑ed25519`, `ssh‑rsa`, `ecdsa‑sha2‑nistp256`, etc.
- **Example**: `SSH_PUBLIC_KEY="ssh‑ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI… user@host"`

#### `SSH_PORT` (optional)
- **Description**: SSH port number. If omitted, the default `22` is used.
- **Required**: No
- **Default**: `"22"`
- **Validation**: Integer between 1 and 65535.
- **Example**: `SSH_PORT="2222"`

### 3. VLESS Protocol Configuration

#### `VLESS_PORT`
- **Description**: TCP port on which the RU relay server will listen for VLESS/Reality traffic. This port must be open on the RU relay server’s firewall.
- **Required**: Yes
- **Default**: `"443"`
- **Validation**: Integer between 1 and 65535; recommended to use a common port (443, 8443, 2053) to blend with normal HTTPS traffic.
- **Example**: `VLESS_PORT="443"`

#### `UUID`
- **Description**: Unique identifier for VLESS connections. If left empty, a random UUID will be generated automatically.
- **Required**: No (auto‑generated if empty)
- **Format**: RFC‑4122 UUID (e.g., `a0b1c2d3‑e4f5‑6789‑abcd‑ef0123456789`).
- **Generation**: Use `uuidgen` or `cat /proc/sys/kernel/random/uuid`.
- **Example**: `UUID="a0b1c2d3‑e4f5‑6789‑abcd‑ef0123456789"`

#### `TRANSPORT`
- **Description**: Transport protocol for VLESS. Currently only `TCP` is supported (required for Reality security).
- **Required**: Yes
- **Default**: `"TCP"`
- **Allowed values**: `"TCP"`
- **Example**: `TRANSPORT="TCP"`

#### `SECURITY`
- **Description**: Security mode for the VLESS inbound. Must be `reality` to use Reality TLS masking.
- **Required**: Yes
- **Default**: `"reality"`
- **Allowed values**: `"reality"`
- **Example**: `SECURITY="reality"`

### 4. Reality Masking Parameters

Reality makes VLESS traffic look like a normal TLS handshake with a popular website. You need to provide a real domain that supports TLS 1.3 (e.g., `cloudflare.com`).

#### `SERVER_NAMES`
- **Description**: Comma‑separated list of domain names that the client will present during the TLS handshake. The first domain is used for client configuration.
- **Required**: Yes
- **Default**: `"cloudflare.com"`
- **Validation**: Each entry must be a valid domain name (no protocol, no port).
- **Example**: `SERVER_NAMES="cloudflare.com,www.google.com"`

#### `DEST`
- **Description**: Real server (domain:port) that the Reality handshake will mimic. This server must be reachable from the foreign VPS and must support TLS 1.3.
- **Required**: Yes
- **Default**: `"cloudflare.com:443"`
- **Format**: `domain:port` (port must be numeric).
- **Example**: `DEST="cloudflare.com:443"`

#### `SHORT_IDS`
- **Description**: Comma‑separated list of short identifiers (1‑8 hex characters each) used by Reality. If left empty, a random 8‑character hex string will be generated.
- **Required**: No (auto‑generated if empty)
- **Format**: Hex characters, e.g., `"a1b2c3d4,e5f67890"`.
- **Validation**: Each short ID must match `[0‑9a‑fA‑F]{1,8}`.
- **Example**: `SHORT_IDS="a1b2c3d4"`

#### `PRIVATE_KEY`
- **Description**: Reality private key (X25519). If left empty, a key pair will be generated automatically.
- **Required**: No (auto‑generated if empty)
- **Format**: 64 hex characters (32‑byte Ed25519 private key converted to X25519).
- **Generation**: Use `xray x25519` or the built‑in openssl method.
- **Example**: `PRIVATE_KEY="0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"`

#### `PUBLIC_KEY`
- **Description**: Reality public key (X25519). If left empty, it will be derived from the generated private key.
- **Required**: No (auto‑generated if empty)
- **Format**: 64 hex characters (32‑byte X25519 public key).
- **Example**: `PUBLIC_KEY="fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210"`

### 5. Optional Features

#### `ENABLE_WARP`
- **Description**: Whether to install and enable Cloudflare WARP on the foreign VPS. If `true`, the foreign server’s outbound traffic will go through WARP, hiding its original IP.
- **Required**: No
- **Default**: `"false"`
- **Allowed values**: `"true"`, `"false"`
- **Note**: WARP installation requires Internet connectivity; if installation fails, the script will fall back to direct outbound and log a warning.
- **Example**: `ENABLE_WARP="true"`

#### `ENABLE_REVERSE_PROXY`
- **Description**: Whether to set up a reverse proxy (nginx with Let’s Encrypt TLS) for the 3x‑ui panel. If `true`, the panel will be accessible via `DOMAIN` over HTTPS.
- **Required**: No
- **Default**: `"false"`
- **Allowed values**: `"true"`, `"false"`
- **Dependency**: Requires a valid `DOMAIN` pointing to the foreign VPS.
- **Example**: `ENABLE_REVERSE_PROXY="true"`

#### `DOMAIN`
- **Description**: Domain name that points to the foreign VPS IP. Used only when `ENABLE_REVERSE_PROXY=true`.
- **Required**: Conditionally (if reverse proxy enabled)
- **Format**: Valid domain name (FQDN) without protocol.
- **Validation**: DNS resolution check is performed during installation.
- **Example**: `DOMAIN="panel.example.com"`

### 6. Advanced Settings (Optional)

#### `PANEL_PORT`
- **Description**: Port on which the 3x‑ui panel will listen (on the foreign VPS). Only change if the default port conflicts with other services.
- **Required**: No
- **Default**: `"2053"`
- **Validation**: Integer between 1 and 65535.
- **Example**: `PANEL_PORT="2053"`

#### `PANEL_USERNAME`
- **Description**: Admin username for the 3x‑ui panel.
- **Required**: No
- **Default**: `"admin"`
- **Validation**: Alphanumeric string.
- **Example**: `PANEL_USERNAME="admin"`

#### `PANEL_PASSWORD`
- **Description**: Admin password for the 3x‑ui panel. If left empty, the installer will generate a random password and display it in the logs.
- **Required**: No
- **Default**: `""` (empty → auto‑generate)
- **Validation**: Minimum length 8 characters (enforced by 3x‑ui).
- **Example**: `PANEL_PASSWORD="MyStrongPassword123"`

#### `ROUTING_RU_GEOIP` (not yet implemented)
- **Description**: GeoIP/Geosite rule for identifying Russian traffic. Currently fixed to `"geosite:category‑ru"`.
- **Required**: No
- **Default**: `"geosite:category‑ru"`
- **Example**: `ROUTING_RU_GEOIP="geosite:category‑ru"`

## Auto‑Generation of Missing Parameters

If you leave the following parameters empty, the scripts will generate appropriate values:

| Parameter    | Generation Method                                                                 |
|--------------|-----------------------------------------------------------------------------------|
| `UUID`       | `uuidgen` (or `/proc/sys/kernel/random/uuid` fallback)                           |
| `SHORT_IDS`  | Random 8‑character hex string generated by `openssl rand -hex 4`                 |
| `PRIVATE_KEY`| `xray x25519` if xray is available, otherwise `openssl genpkey` + `xxd` conversion |
| `PUBLIC_KEY` | Derived from the generated private key                                            |
| `PANEL_PASSWORD` | Random 16‑character alphanumeric string                                       |

The generated values are **exported to the environment** and can be reused across script runs. If you want to keep the same values, copy them from the installation logs into your `.env` file.

## Validation Rules

Each parameter is validated before installation. The validation script (`validate‑config.sh`) checks:

- **Required parameters** are non‑empty (except those that can be auto‑generated).
- **IP addresses** match IPv4 format.
- **Ports** are integers within 1–65535.
- **UUID** matches RFC‑4122 format (if provided).
- **Domain names** are syntactically valid (if provided).
- **Boolean flags** are either `"true"` or `"false"`.
- **SSH public key** starts with a known key type.

If validation fails, the script prints a clear error and exits with code 1.

## Environment Variable Export

All parameters are exported as environment variables (uppercase) after sourcing `.env`. They are used by subsequent scripts. You can also use them manually, e.g.:

```bash
source .env
echo "VLESS port is $VLESS_PORT"
```

## Example `.env` File

```bash
# Server IPs
RU_RELAY_IP="192.0.2.10"
FOREIGN_VPS_IP="203.0.113.20"

# SSH
SSH_USER="root"
SSH_PUBLIC_KEY="ssh‑ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI…"
SSH_PORT="22"

# VLESS
VLESS_PORT="443"
UUID=""
TRANSPORT="TCP"
SECURITY="reality"

# Reality
SERVER_NAMES="cloudflare.com,www.google.com"
DEST="cloudflare.com:443"
SHORT_IDS=""
PRIVATE_KEY=""
PUBLIC_KEY=""

# Optional features
ENABLE_WARP="false"
ENABLE_REVERSE_PROXY="false"
DOMAIN=""

# Advanced
PANEL_PORT="2053"
PANEL_USERNAME="admin"
PANEL_PASSWORD=""
```

## Overriding Defaults

Default values are set in `scripts/common/load‑config.sh`. If you need to change a default permanently, edit that file. For temporary overrides, simply set the variable in your `.env` file (it will override the default).

## Security Considerations

- **Never commit `.env`** to version control (it is listed in `.gitignore`).
- **Use strong randomness** for UUID and Reality keys (the auto‑generation uses cryptographically secure random sources).
- **Keep your SSH private key secure**; the public key is placed on the servers, but the private key should remain only on your local machine.
- **Change the default 3x‑ui password** after first login.

---

For further details, refer to the [Installation Guide](installation‑guide.md) or the [Troubleshooting Guide](troubleshooting.md).