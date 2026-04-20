# Installation Guide

This guide walks you through deploying the cascading VPN infrastructure using the 3x‑ui automation scripts.

## Prerequisites

### Server Requirements
- Two virtual private servers (VPS) with public IPv4 addresses:
  - **RU relay server**: Located in Russia (or any region you wish to relay from). Minimal resources (1 CPU, 512 MB RAM) are sufficient.
  - **Foreign VPS**: Located outside Russia (or any target region). Recommended: 1 CPU, 1 GB RAM.
- Both servers must run **Ubuntu 20.04+ / 22.04+** or **Debian 11+ / 12+**. Other distributions are not supported.
- Root or sudo privileges on both servers.

### Network Requirements
- The RU relay server must be able to reach the foreign VPS via its public IP (no firewall blocking between them).
- The foreign VPS must have outbound Internet access (direct or via WARP).
- If you plan to use a reverse proxy for the 3x‑ui panel, a domain name pointing to the foreign VPS is required.

### Preparation Steps
1. **Generate an SSH key pair** on your local machine (if you don’t have one):
   ```bash
   ssh-keygen -t ed25519 -f ~/.ssh/vpn_rsa -N ''
   ```
2. **Add your public key** to both servers’ `~/.ssh/authorized_keys` (usually done during VPS provisioning).
3. **Note the public IP addresses** of both servers (referred to as `RU_RELAY_IP` and `FOREIGN_VPS_IP`).

## Configuration

All deployment parameters are defined in a single `.env` file.

1. **Clone the repository** on your local machine or a jump host:
   ```bash
   git clone https://github.com/your-org/3x-ui.git
   cd 3x-ui
   ```
2. **Copy the configuration template**:
   ```bash
   cp .env.example .env
   ```
3. **Edit `.env`** with your favorite editor and fill in the values:

   ### Server IPs
   ```bash
   RU_RELAY_IP="192.0.2.10"           # Public IP of the RU relay server
   FOREIGN_VPS_IP="203.0.113.20"      # Public IP of the foreign VPS
   ```

   ### SSH Access
   ```bash
   SSH_USER="root"                    # User with sudo privileges
   SSH_PUBLIC_KEY="ssh‑ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI…"   # Contents of your public key
   ```

   ### VLESS Settings
   ```bash
   VLESS_PORT="443"                   # Port for VLESS/Reality (commonly 443, 8443, 2053)
   UUID=""                            # Leave empty to auto‑generate, or provide your own
   TRANSPORT="TCP"                    # Must be TCP for Reality
   SECURITY="reality"                 # Must be reality
   ```

   ### Reality Masking Parameters
   ```bash
   SERVER_NAMES="cloudflare.com"      # Comma‑separated list of domains for TLS handshake
   DEST="cloudflare.com:443"          # Real server to mimic (domain:port)
   SHORT_IDS=""                       # Leave empty to auto‑generate 8‑character hex IDs
   PRIVATE_KEY=""                     # Leave empty to auto‑generate
   PUBLIC_KEY=""                      # Leave empty to auto‑generate
   ```

   ### Optional Features
   ```bash
   ENABLE_WARP="false"                # Set true to route foreign server traffic via Cloudflare WARP
   ENABLE_REVERSE_PROXY="false"       # Set true to hide 3x‑ui panel behind nginx with TLS
   DOMAIN=""                          # Required if reverse proxy enabled (e.g., panel.example.com)
   ```

   ### Advanced Settings (optional)
   ```bash
   SSH_PORT="22"
   PANEL_PORT="2053"
   PANEL_USERNAME="admin"
   PANEL_PASSWORD=""                  # Leave empty to let the installer generate a random password
   ```

4. **Generate missing parameters** (optional). If you left `UUID`, `PRIVATE_KEY`, `PUBLIC_KEY`, or `SHORT_IDS` empty, the scripts will generate them automatically during installation. You can also generate them manually:
   - UUID: `uuidgen` or `cat /proc/sys/kernel/random/uuid`
   - Reality key pair: install `xray` and run `xray x25519`, or use the built‑in openssl method.

## Deployment

The main installation script `install.sh` orchestrates the entire deployment. You can deploy both servers at once, or each server separately.

### Option 1: Deploy Both Servers (Recommended)
Run the following command from the project root:
```bash
./install.sh --all
```

The script will:
1. Load and validate your `.env` configuration.
2. Connect to the **RU relay server**, apply security hardening (SSH, UFW, fail2ban), and set up iptables forwarding rules.
3. Connect to the **foreign VPS**, install 3x‑ui, configure VLESS+Reality inbound, set up optional WARP and reverse proxy, and create outbound routing.
4. Generate client configuration files (`direct‑outbound.txt` and `warp‑outbound.txt`) in the `client‑configs/` directory.
5. Run a health‑check to verify the infrastructure.

### Option 2: Deploy Servers Separately
If you prefer to stage the deployment, or if the servers are provisioned at different times:

**Deploy only the RU relay server:**
```bash
./install.sh --relay
```

**Deploy only the foreign VPS (with 3x‑ui):**
```bash
./install.sh --foreign
```

You can run the scripts multiple times; they are idempotent and will not duplicate existing configurations.

### Installation Output
During installation you will see:
- Timestamped logs of each step.
- Credentials for the 3x‑ui panel (if you didn’t set `PANEL_PASSWORD`).
- A summary of applied firewall rules.
- Any warnings or errors (which will stop the script if critical).

**Important:** The installer extracts the 3x‑ui panel password from the installation output. If you miss it, you can find it in the installer logs or reset it via the panel later.

## Verification

After installation completes, run the health‑check script to ensure everything works:

```bash
./health-check.sh --all
```

It will test:
- SSH connectivity to both servers.
- UFW and fail2ban status.
- 3x‑ui service status.
- WARP connectivity (if enabled).
- VLESS/Reality port accessibility.
- Direct and warp outbound Internet connectivity.

All checks should pass with `OK` status. If any check fails, consult the troubleshooting section below.

### Manual Verification Steps
1. **Access the 3x‑ui panel**:
   - Without reverse proxy: `http://FOREIGN_VPS_IP:2053`
   - With reverse proxy: `https://DOMAIN`
   - Log in with username `admin` and the password shown during installation.

2. **Check the VLESS inbound**:
   - In the 3x‑ui panel, navigate to **Inbounds**. You should see a VLESS inbound with Reality security, using the port you configured.

3. **Test client connectivity**:
   - Use the generated client configuration files (see **Client Configuration Usage** below) to connect with a VLESS client.
   - Verify that Russian resources (e.g., yandex.ru) go directly, while other traffic goes through the proxy (you can check your external IP via `curl ifconfig.me`).

## Post‑Installation Tasks

### Change Default Credentials
It is strongly recommended to change the default 3x‑ui admin password after first login.

### Monitor Logs
- 3x‑ui panel logs: `Journalctl -u 3x‑ui -f`
- Xray logs: `Journalctl -u xray -f`
- Fail2ban logs: `sudo tail -f /var/log/fail2ban.log`

### Update Components
Periodically update 3x‑ui, Xray, and system packages using the provided update script:
```bash
./update.sh
```
The script creates backups before applying updates and runs a health‑check afterward.

### Uninstall / Reset
If you need to remove the VPN configuration, use the uninstall script:
```bash
./uninstall.sh --all
```
It will ask for confirmation and can perform a soft reset (keep configuration files) or a hard reset (remove everything).

## Client Configuration Usage

After a successful installation, two client configuration files are generated in the `client‑configs/` directory:

- `direct‑outbound.txt` – uses the foreign server’s direct outbound (no WARP).
- `warp‑outbound.txt` – routes traffic through Cloudflare WARP (if WARP was enabled).

These files contain a JSON configuration compatible with Xray/V2Ray clients (v2rayN, Shadowrocket, V2RayNG, etc.). They include:
- VLESS server address (RU relay IP) and port.
- UUID and Reality parameters (serverName, publicKey, shortId).
- Client‑side routing rules: **RU traffic → direct outbound**, **all other traffic → proxy**.

### Importing into Clients
1. **v2rayN (Windows)**:
   - Open v2rayN, go to **Servers** → **Import from clipboard** or **Import from file**.
   - Paste the content of `direct‑outbound.txt` (or `warp‑outbound.txt`).
   - The server will appear in the list; right‑click and select **Activate** to connect.

2. **Shadowrocket (iOS)**:
   - Transfer the `.txt` file to your device (AirDrop, email, etc.).
   - In Shadowrocket, tap the **+** icon, choose **Import from file**, and select the file.
   - Tap the new configuration to connect.

3. **V2RayNG (Android)**:
   - Copy the file content to clipboard.
   - Open V2RayNG, tap the **+** icon, choose **Import from clipboard**.
   - The configuration will be parsed; tap the checkmark to save and connect.

### Testing Routing
After connecting, visit a Russian site (e.g., `yandex.ru`) and a non‑Russian site (e.g., `google.com`). Use a tool like `ipleak.net` to verify that your IP changes depending on the destination.

## Troubleshooting

Common issues and solutions are documented in the [Troubleshooting Guide](troubleshooting.md). For quick reference:

- **SSH connection refused**: Ensure the SSH public key is correctly added to the server’s `authorized_keys` and that the SSH port is open in UFW.
- **VLESS port not accessible**: Check UFW rules (`sudo ufw status`) and ensure the port is not blocked by the cloud provider’s firewall.
- **WARP not connecting**: Verify that the foreign VPS has outbound Internet access and that the `cloudflare‑warp` package installed correctly. Check `sudo warp‑cli status`.
- **Reality handshake fails**: Ensure `SERVER_NAMES` and `DEST` point to a real, reachable TLS server (e.g., cloudflare.com). Regenerate Reality keys if needed.
- **3x‑ui panel inaccessible**: Confirm the service is running (`systemctl status 3x‑ui`) and that the panel port is allowed in UFW.

If problems persist, run the health‑check script with verbose output:
```bash
./health-check.sh --all --verbose
```

## Next Steps
- Review the [Configuration Reference](configuration‑reference.md) for detailed parameter explanations.
- Explore advanced routing options by editing the generated client configurations.
- Consider setting up monitoring (e.g., log aggregation) for production use.

---

**Need help?** Open an issue on the project repository with details of your problem and the output of `./health‑check.sh --all`.