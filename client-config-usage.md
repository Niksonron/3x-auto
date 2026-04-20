# Client Configuration Usage

After a successful installation, the automation scripts generate two client configuration files in the `client‑configs/` directory:

- **`direct‑outbound.txt`** – routes traffic through the foreign VPS using its **direct** outbound (no WARP).
- **`warp‑outbound.txt`** – routes traffic through the foreign VPS using **Cloudflare WARP** (if WARP was enabled during installation).

Both files contain a JSON configuration compatible with Xray/V2Ray‑based clients (v2rayN, Shadowrocket, V2RayNG, etc.). This guide explains how to import and use these configurations.

## Configuration Contents

Each `.txt` file includes:

1. **VLESS outbound** with Reality settings:
   - Server address (`RU_RELAY_IP`) and port (`VLESS_PORT`).
   - UUID (`id`).
   - Reality parameters: `serverName`, `fingerprint`, `publicKey`, `shortId`, `spiderX`.
2. **Routing rules** that implement combined routing:
   - Traffic destined for Russian resources (geoip:ru, geosite:ru) is sent directly from your device (**direct outbound**).
   - All other traffic goes through the VLESS proxy (**proxy‑direct** or **proxy‑warp** outbound).

The routing rules are already embedded in the JSON, so you don’t need to configure them manually.

## Importing into Clients

### v2rayN (Windows)

1. **Copy the configuration**:
   - Open `client‑configs/direct‑outbound.txt` (or `warp‑outbound.txt`) with a text editor and copy the entire content.

2. **Import into v2rayN**:
   - Launch v2rayN.
   - Click the **Servers** menu, then select **Import from clipboard**.
   - Alternatively, use **Import from file** and browse to the `.txt` file.

3. **Activate the server**:
   - The new server will appear in the server list.
   - Right‑click it and choose **Set as active server** (or double‑click).

4. **Verify connection**:
   - Check the system tray icon; it should turn green.
   - Visit [ipleak.net](https://ipleak.net) to see your external IP. For non‑Russian sites you should see the foreign VPS IP (or the WARP IP if using the warp configuration).

### Shadowrocket (iOS)

1. **Transfer the configuration file** to your iOS device:
   - Email the `.txt` file to yourself and open it on the iPhone.
   - Use AirDrop from a Mac.
   - Upload to iCloud Drive or any cloud storage and open from the Files app.

2. **Import into Shadowrocket**:
   - Open Shadowrocket.
   - Tap the **+** icon at the top right.
   - Select **Import from file**.
   - Navigate to the location where you saved the `.txt` file and tap it.

3. **Connect**:
   - The configuration will appear in the server list.
   - Tap the switch next to it to enable the proxy.

4. **Test routing**:
   - Open Safari and visit a Russian website (e.g., `yandex.ru`) and a non‑Russian site (e.g., `google.com`). The Russian site should load with your local ISP, while the other site should show the proxy IP.

### V2RayNG (Android)

1. **Copy the configuration text**:
   - Open the `.txt` file with a text editor and copy all content.

2. **Import into V2RayNG**:
   - Open V2RayNG.
   - Tap the **+** icon at the bottom right.
   - Choose **Import from clipboard**.
   - If the JSON is valid, the configuration will be parsed and saved.

3. **Connect**:
   - The new server appears in the list.
   - Tap the round button next to it to activate.

4. **Check connection status**:
   - The top notification will show “Connected”. You can also see the proxy IP in the app’s main screen.

### Qv2ray (Cross‑Platform)

1. **Open Qv2ray** and go to **Group Editor** (or directly to **Outbound**).

2. **Add a new outbound**:
   - Click **Add** → **VLESS**.
   - Fill in the server address (`RU_RELAY_IP`), port (`VLESS_PORT`), UUID, and Reality settings as shown in the generated JSON.

3. **Import routing rules**:
   - Go to **Routing** and create a new rule set that matches the JSON routing section (geoip:ru → direct, default → proxy).

   Because manual import can be tedious, you can instead:
   - Copy the entire JSON from the `.txt` file.
   - In Qv2ray, use **Import configuration from clipboard** (if supported) or save the JSON as a `.qv2ray` file and import via **File → Import**.

4. **Activate** and test.

## Testing Routing Behavior

To verify that the combined routing works correctly:

1. **Connect** using one of the configurations.
2. **Visit a Russian site** (e.g., `yandex.ru`). While connected, your real IP should be used (the proxy should not be engaged). You can check with [2ip.ru](https://2ip.ru) (a Russian IP checker) – it should show your local IP, not the proxy IP.
3. **Visit a non‑Russian site** (e.g., `google.com`). Your external IP should now be the foreign VPS IP (or the WARP IP if using warp‑outbound).
4. **Use a routing diagnostic tool** like [ipleak.net](https://ipleak.net) – it will show your IP and DNS leaks. Ensure that DNS requests for Russian domains are resolved locally.

## Switching Between Direct and Warp Outbounds

If you enabled WARP during installation, you have two ready‑to‑use configurations. You can switch between them simply by importing the other `.txt` file into your client and activating it.

- **Direct outbound** gives you the foreign VPS’s original IP (slightly faster, but the VPS IP may be flagged by some services).
- **Warp outbound** hides the VPS IP behind Cloudflare’s global network (adds a small latency, but increases anonymity and may bypass some IP‑based blocks).

You can keep both configurations in your client and toggle as needed.

## Advanced Customization

The generated JSON is a standard Xray/V2Ray configuration. You can modify it directly for advanced use cases:

- **Change routing rules**: Edit the `routing.rules` array to add or remove geo‑based rules.
- **Add multiple outbounds**: You can combine both direct and warp outbounds in a single configuration and use routing rules to choose between them based on domain or IP.
- **Adjust Reality parameters**: If you regenerate Reality keys or change `SERVER_NAMES`, update the `streamSettings.realitySettings` section accordingly.

After editing, save the file and re‑import it into your client.

## Troubleshooting Client Connections

- **“Failed to connect”**:
  - Verify that the RU relay server’s firewall (UFW) allows the `VLESS_PORT`.
  - Ensure the foreign VPS is running and the VLESS inbound is active in 3x‑ui.
  - Check that the UUID and Reality keys match between server and client.

- **Russian sites are being proxied**:
  - The geoip/geosite database may not classify the site as Russian. You can add manual domain rules in your client’s routing settings.

- **WARP outbound shows the VPS IP instead of WARP IP**:
  - WARP may not be connected on the foreign VPS. Log into the foreign server and run `sudo warp‑cli status`. If not connected, restart the WARP service: `sudo systemctl restart warp‑svc`.

- **Shadowrocket/V2RayNG says “Invalid configuration”**:
  - Ensure you copied the **entire** JSON content, including the opening `{` and closing `}`. Some clients are strict about trailing commas.

If problems persist, run the health‑check script on the servers to verify the infrastructure is healthy:

```bash
./health‑check.sh --all
```

## Regenerating Client Configs

If you change any parameters (IP, port, UUID, Reality keys) after installation, you can regenerate the client configurations without reinstalling:

```bash
cd scripts/common
./generate‑client‑config.sh
```

The new files will be written to `client‑configs/` (overwriting the previous ones). Then re‑import them into your clients.

## See Also

- [Installation Guide](installation‑guide.md) – step‑by‑step deployment instructions.
- [Configuration Reference](configuration‑reference.md) – detailed explanation of all `.env` parameters.
- [Troubleshooting Guide](troubleshooting.md) – solutions to common issues.