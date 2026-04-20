# Troubleshooting Guide

This guide helps you diagnose and fix common problems that may occur during deployment or operation of the cascading VPN infrastructure.

## General Diagnostics

### Health‑Check Script
The first step when something isn’t working is to run the health‑check script:

```bash
./health‑check.sh --all
```

It will test SSH connectivity, firewall status, service health, port accessibility, and outbound connectivity. Look for any `FAIL` or `ERROR` lines in the output.

### Log Files
- **Installation logs**: The scripts log to stdout with timestamps. If you redirected output, check the log file.
- **3x‑ui service**: `sudo journalctl -u 3x‑ui -f`
- **Xray service**: `sudo journalctl -u xray -f`
- **WARP service**: `sudo journalctl -u warp‑svc -f`
- **UFW logs**: `sudo tail -f /var/log/ufw.log`
- **Fail2ban logs**: `sudo tail -f /var/log/fail2ban.log`

## Common Issues

### SSH Connection Refused

**Symptoms**:
- Installation script fails with “Connection refused” or “Permission denied”.
- You cannot SSH into the server manually.

**Causes**:
1. SSH port (default 22) is blocked by the cloud provider’s firewall.
2. UFW is enabled and not allowing the SSH port.
3. SSH daemon is not running.
4. The SSH public key is not present in `~/.ssh/authorized_keys`.

**Solutions**:
- **Cloud provider firewall**: Check the security group / firewall rules of your VPS and ensure TCP port 22 (or your custom `SSH_PORT`) is allowed for your IP.
- **UFW**: If UFW is active, temporarily disable it with `sudo ufw disable` (on the affected server) and try again. After successful SSH login, re‑enable UFW and add the SSH port rule: `sudo ufw allow 22/tcp`.
- **SSH service**: Ensure the SSH daemon is running: `sudo systemctl status ssh`.
- **SSH key**: Verify that the `SSH_PUBLIC_KEY` in your `.env` matches the public key you added to the server’s `authorized_keys`. You can manually add it with:
  ```bash
  echo "your‑public‑key‑here" >> ~/.ssh/authorized_keys
  ```

### UFW Blocking Required Ports

**Symptoms**:
- VLESS/Reality port is inaccessible (client cannot connect).
- 3x‑ui panel is not reachable.
- Health‑check reports “Port XXX not open”.

**Solutions**:
1. List current UFW rules: `sudo ufw status`.
2. Allow the missing port:
   ```bash
   sudo ufw allow 443/tcp   # VLESS_PORT
   sudo ufw allow 2053/tcp  # PANEL_PORT (if panel is directly exposed)
   ```
3. If you enabled reverse proxy, also allow ports 80 and 443 for nginx/certbot:
   ```bash
   sudo ufw allow 80/tcp
   sudo ufw allow 443/tcp
   ```
4. Reload UFW: `sudo ufw reload`.

**Note**: The installation scripts are supposed to configure UFW automatically. If they missed a rule, you can run the UFW configuration script manually:

```bash
cd scripts/common
./ufw‑config.sh
```

### 3x‑ui Panel Not Accessible

**Symptoms**:
- You cannot reach `http://FOREIGN_VPS_IP:2053` (or `https://DOMAIN`).
- Health‑check reports “3x‑ui service not running”.

**Diagnosis**:
1. Check if the service is running:
   ```bash
   sudo systemctl status 3x‑ui
   ```
   If it’s inactive, start it: `sudo systemctl start 3x‑ui`.
2. Check if the panel port is open on the foreign VPS firewall (UFW and cloud provider firewall).
3. If you enabled reverse proxy, verify nginx is running:
   ```bash
   sudo systemctl status nginx
   ```
   and that the domain points to the foreign VPS IP (`dig DOMAIN`).

**Solutions**:
- **Service not starting**: Check the 3x‑ui logs (`journalctl -u 3x‑ui`) for errors. Common issues include port conflict (another service using 2053) or missing Xray binary.
- **Forgotten password**: If you lost the auto‑generated panel password, you can reset it by editing the 3x‑ui database:
  ```bash
  sqlite3 /etc/3x‑ui/x‑ui.db "UPDATE users SET password = '$(echo -n 'new‑password' | sha256sum | cut -d' ' -f1)' WHERE username = 'admin';"
  ```
  Replace `'new‑password'` with your desired password.

### VLESS/Reality Handshake Fails

**Symptoms**:
- Client connects but immediately disconnects.
- Xray logs show “invalid reality signature” or “no matching server name”.

**Causes**:
1. Reality parameters mismatch between server and client.
2. `SERVER_NAMES` or `DEST` point to a domain that no longer supports TLS 1.3 or is unreachable from the foreign VPS.
3. The Reality private/public key pair changed after installation.

**Solutions**:
- **Verify Reality parameters**:
  - In the 3x‑ui panel, go to **Inbounds**, edit the VLESS inbound, and check the Reality settings.
  - Compare with the client configuration (`client‑configs/*.txt`). Ensure `serverName`, `publicKey`, and `shortId` match.
- **Regenerate Reality keys**:
  - On the foreign VPS, stop 3x‑ui: `sudo systemctl stop 3x‑ui`.
  - Delete the inbound and recreate it with the same parameters (the script `scripts/foreign/configure‑vless‑reality.sh` can do this idempotently).
  - Or manually update the inbound JSON in 3x‑ui.
- **Change `SERVER_NAMES`/`DEST`**:
  - Choose a reliable, high‑uptime domain like `cloudflare.com`, `www.google.com`, `github.com`.
  - Ensure the foreign VPS can reach that domain on port 443 (test with `curl -I https://cloudflare.com`).

### WARP Not Connecting

**Symptoms**:
- Health‑check reports “WARP not connected”.
- `warp‑cli status` shows “Status: Disconnected”.
- The `warp‑outbound.txt` configuration still shows the VPS IP instead of a Cloudflare IP.

**Diagnosis**:
1. Check WARP service status:
   ```bash
   sudo systemctl status warp‑svc
   ```
2. Check connectivity:
   ```bash
   sudo warp‑cli status
   ```
   Look for `Status: Connected` and a Cloudflare IP under `IPv4`.

**Solutions**:
- **Re‑register WARP**:
  ```bash
  sudo warp‑cli register
  sudo warp‑cli connect
  ```
- **If WARP installation failed** (e.g., due to network issues), you can re‑run the WARP installation script:
  ```bash
  cd scripts/foreign
  ./install‑warp.sh
  ```
- **Fallback to direct outbound**: If WARP persistently fails, you can disable it by setting `ENABLE_WARP="false"` in `.env` and re‑running the installation for the foreign server only (`./install.sh --foreign`). The script will remove WARP and reconfigure routing to use direct outbound.

### Routing Not Working (Russian Traffic Still Proxied)

**Symptoms**:
- All traffic, including Russian sites, goes through the proxy (you see the foreign IP on Russian sites).
- Client‑side routing rules appear to be ignored.

**Causes**:
1. The geoip/geosite database used by your client may not contain up‑to‑date Russian IP ranges.
2. The routing rules in the generated JSON may be malformed.
3. Your client may not support the `geoip:ru` / `geosite:ru` syntax.

**Solutions**:
- **Update geo databases**: Some clients (like v2rayN) allow you to update the geoip/geosite files. Check your client’s settings.
- **Test with a known Russian IP**: Add a manual rule for a specific Russian IP (e.g., `93.158.134.0/24` for Yandex) to verify routing works.
- **Check generated routing JSON**: Look at the `routing` section in `direct‑outbound.txt`. It should contain two rules: one with `"geoip:ru"` and `"geosite:ru"` that goes to `"direct"`, and a catch‑all rule that goes to `"proxy‑direct"` (or `"proxy‑warp"`).
- **Use a different client**: Try another VLESS client to see if the issue is client‑specific.

### iptables Forwarding Broken on Relay Server

**Symptoms**:
- Traffic reaches the RU relay server but is not forwarded to the foreign VPS.
- `curl` from the relay server to the foreign VPS’s `VLESS_PORT` works, but clients cannot connect.

**Diagnosis**:
1. Check iptables NAT rules:
   ```bash
   sudo iptables -t nat -L -n -v
   ```
   Look for a DNAT rule that forwards `VLESS_PORT` to `FOREIGN_VPS_IP:VLESS_PORT`.
2. Ensure IP forwarding is enabled:
   ```bash
   cat /proc/sys/net/ipv4/ip_forward
   ```
   Should output `1`.

**Solutions**:
- **Re‑run the relay setup script**:
  ```bash
  cd scripts/relay
  ./setup‑relay.sh
  ```
- **Enable IP forwarding permanently**:
  ```bash
  echo "net.ipv4.ip_forward=1" | sudo tee -a /etc/sysctl.conf
  sudo sysctl -p
  ```
- **Check default interface**: The script detects the default network interface automatically. If your server has multiple interfaces, you may need to adjust the `INTERFACE` variable in the script.

### Fail2ban Blocking Legitimate Connections

**Symptoms**:
- You (or your users) are suddenly unable to SSH or access the panel.
- `sudo fail2ban‑client status` shows many banned IPs.

**Solutions**:
- **Unban your IP**:
  ```bash
  sudo fail2ban‑client set sshd unbanip YOUR_IP
  ```
- **Adjust fail2ban settings**:
  Edit `/etc/fail2ban/jail.local` and increase `maxretry` or `findtime` for the `sshd` jail, then restart fail2ban:
  ```bash
  sudo systemctl restart fail2ban
  ```
- **Whitelist your IP**:
  Add your IP to `ignoreip` in the jail configuration.

### Certificate Renewal Issues (Reverse Proxy)

**Symptoms**:
- After a few months, the TLS certificate for your domain expires, and the panel becomes inaccessible over HTTPS.

**Solutions**:
- **Renew manually**:
  ```bash
  sudo certbot renew --nginx
  ```
- **Automate renewal**: Certbot sets up a systemd timer by default. Check it with `systemctl list‑timers | grep certbot`. If it’s inactive, enable it:
  ```bash
  sudo systemctl enable certbot‑renew.timer
  sudo systemctl start certbot‑renew.timer
  ```

## Performance Issues

### High Latency
- The cascade adds at least one extra hop. Expect slightly higher latency than a direct connection.
- If latency is excessive, check the network route between the relay and foreign VPS (use `mtr` or `traceroute`).
- Consider using a foreign VPS geographically closer to the relay server.

### Low Throughput
- Ensure both servers have sufficient CPU and network resources.
- Check for bandwidth throttling by the VPS provider.
- VLESS+Reality over TCP adds some overhead, but it should still provide near‑line speeds. If throughput is far below expectation, verify that the servers are not using overly aggressive TCP congestion control.

## Getting Help

If you cannot resolve an issue after following this guide:

1. **Collect logs**:
   - Output of `./health‑check.sh --all --verbose`.
   - Relevant journal entries (`journalctl -u 3x‑ui --since "2 hours ago"`).
   - Your `.env` file (with sensitive values redacted).

2. **Open an issue** on the project repository, attaching the collected information and a clear description of the problem.

3. **Community support**: Check the 3x‑ui Telegram channel or Xray/V2Ray communities for help with Reality or client configuration.

---

**Remember**: The automation scripts are idempotent. If you’re unsure, you can safely re‑run `./install.sh --relay` or `./install.sh --foreign` to fix configuration drift. Always backup your `.env` file first.