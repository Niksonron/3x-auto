# 3x-ui VPN Automation

Automated deployment scripts for cascading VPN infrastructure using VLESS + 3x-ui.

## Overview

This project provides automated bash scripts to deploy a two-server cascading VPN infrastructure:

```
Client → RU relay server → Foreign VPS → WARP/Direct → Internet
```

## Key Features

- **Automatic deployment** of RU relay server and foreign VPS
- **Security hardening**: SSH key-only auth, UFW, fail2ban
- **VLESS over TCP with Reality** security masking
- **Dual outbound modes**: direct and Cloudflare WARP
- **Combined routing**: `RU → direct`, `default → proxy` (client & server side)
- **3x-ui panel** management on foreign server only
- **Client configuration** auto-generation (.txt files)
- **Idempotent scripts**: safe for repeated runs
- **Health-check, update, and uninstall** scenarios

## Supported Systems

- Ubuntu 20.04+ / 22.04+
- Debian 11+ / 12+

## Quick Start

### Prerequisites
- Two VPS servers (Ubuntu/Debian) with public IPs.
- SSH key pair for authentication.
- Domain name (optional, for reverse proxy).

### Step 1: Clone and Configure
```bash
git clone [https://github.com/your-org/3x-ui.git](https://github.com/Niksonron/3x-auto)
cd 3x-auto
cp .env.example .env
```
Edit `.env` and fill in at least:
- `RU_RELAY_IP` and `FOREIGN_VPS_IP`
- `SSH_USER` and `SSH_PUBLIC_KEY`
- `VLESS_PORT` (default 443)
- `UUID` (leave empty to auto‑generate)
- Reality parameters (`SERVER_NAMES`, `DEST`)

### Step 2: Deploy
```bash
# Deploy both servers at once
./install.sh --all

# Or deploy separately
./install.sh --relay    # RU relay server
./install.sh --foreign  # Foreign VPS with 3x‑ui
```

### Step 3: Verify
```bash
./health-check.sh --all
```

### Step 4: Use Generated Client Configs
Import the files from `client‑configs/` into your VLESS client (v2rayN, Shadowrocket, etc.). See [Client Configuration Usage](docs/client‑config‑usage.md) for details.

For a complete walkthrough, refer to the [Installation Guide](docs/installation‑guide.md).

## Project Structure

```
.
├── config/                 # Configuration templates
├── scripts/
│   ├── common/            # Shared utilities
│   ├── relay/             # RU relay server setup
│   └── foreign/           # Foreign VPS setup
├── docs/                  # Documentation
├── client-configs/        # Generated client profiles
├── install.sh            # Main installer
├── update.sh             # Update components
├── uninstall.sh          # Remove deployment
└── health-check.sh       # Verify infrastructure
```

## Documentation

- [Installation Guide](docs/installation-guide.md) – Step‑by‑step deployment instructions
- [Configuration Reference](docs/configuration-reference.md) – Detailed explanation of all parameters
- [Client Configuration Usage](docs/client-config-usage.md) – How to import generated configs into VLESS clients
- [Troubleshooting Guide](docs/troubleshooting.md) – Solutions to common problems

For developers:
- [User Stories](user%20stories.md) – Detailed requirements and acceptance criteria
- [AGENTS.md](AGENTS.md) – Development guidance for AI agents
- [PRD](tasks/prd-cascading-vpn-3x-ui.md) – Product Requirements Document
- [Ralph Plan](ralph/prd.json) – Implementation plan for autonomous execution

## Configuration

All deployment parameters are defined in `.env` file:

```bash
# Server IPs
RU_RELAY_IP=""
FOREIGN_VPS_IP=""

# SSH access
SSH_USER=""
SSH_PUBLIC_KEY=""

# VLESS settings
VLESS_PORT=""
UUID=""
TRANSPORT="TCP"
SECURITY="reality"

# Reality parameters
SERVER_NAMES=""
DEST=""
SHORT_IDS=""
PRIVATE_KEY=""
PUBLIC_KEY=""

# Optional features
ENABLE_WARP="false"
ENABLE_REVERSE_PROXY="false"
DOMAIN=""  # if reverse proxy enabled
```

## License

This project is provided as-is for educational and personal use.

## Security Notice

- Always use strong, randomly generated UUIDs and Reality keys
- Keep SSH private keys secure
- Regularly update 3x-ui and system packages
- Monitor server logs for suspicious activity
