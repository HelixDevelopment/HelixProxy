# Browser Proxy Configuration Guide

How to configure popular web browsers to use the Proxy Service.

> **Quick Reference**
> - HTTP Proxy: `http://<HOST_IP>:53128`
> - SOCKS5 Proxy: `socks5://<HOST_IP>:51080`
>
> Replace `<HOST_IP>` with your proxy server's LAN IP.

---

## Table of Contents

1. [Firefox](#firefox)
2. [Chrome / Edge / Brave](#chrome--edge--brave)
3. [Safari (macOS)](#safari-macos)
4. [Safari (iOS/iPadOS)](#safari-iosipados)
5. [Opera](#opera)
6. [Vivaldi](#vivaldi)
7. [Tor Browser](#tor-browser)
8. [Browser Extensions](#browser-extensions)

---

## Firefox

Firefox has the best built-in proxy support of all major browsers.

### Manual Configuration

1. Open **Settings** (≡ menu → Settings)
2. Scroll to **Network Settings** at the bottom
3. Click **Settings...** button
4. Select **Manual proxy configuration**
5. Fill in:

   | Field | Value |
   |-------|-------|
   | HTTP Proxy | `192.168.1.100` |
   | Port | `53128` |
   | HTTPS Proxy | `192.168.1.100` |
   | Port | `53128` |
   | SOCKS Host | `192.168.1.100` |
   | Port | `51080` |
   | SOCKS v5 | ✅ Checked |

6. ✅ Check **Proxy DNS when using SOCKS v5** (highly recommended)
7. Click **OK**

### Using SOCKS5 Only (All Traffic)

For maximum privacy, route everything through SOCKS5:

1. Follow steps above
2. Leave HTTP/HTTPS fields empty
3. Only fill in **SOCKS Host**: `192.168.1.100`, Port: `51080`
4. ✅ Check **Proxy DNS when using SOCKS v5**

### PAC File (Auto-Config)

For conditional proxy (only certain sites):

1. In Network Settings, select **Automatic proxy configuration URL**
2. Enter: `http://192.168.1.100:58080/proxy.pac` (if you host a PAC file)

Or create a local PAC file:

```javascript
function FindProxyForURL(url, host) {
    // Proxy everything
    return "PROXY 192.168.1.100:53128; SOCKS5 192.168.1.100:51080";
}
```

Save as `proxy.pac` and point Firefox to `file:///path/to/proxy.pac`.

### About:config Advanced Settings

For power users:

1. Type `about:config` in the address bar
2. Accept the warning
3. Search for these settings:

| Preference | Value | Description |
|------------|-------|-------------|
| `network.proxy.socks_remote_dns` | `true` | DNS through SOCKS |
| `network.proxy.socks_version` | `5` | SOCKS version |
| `network.proxy.type` | `1` | Manual proxy |

---

## Chrome / Edge / Brave

Chromium-based browsers use the **system proxy settings** by default on most platforms. For manual configuration, use extensions.

### Windows

Chrome uses Windows system proxy settings:

1. **Settings → Network & Internet → Proxy**
2. Configure system-wide proxy (see [CLIENT_SETUP.md](CLIENT_SETUP.md))
3. Chrome automatically picks it up

### macOS

Chrome uses macOS system proxy settings:

1. **System Settings → Network → [Connection] → Details → Proxies**
2. Configure HTTP/HTTPS/SOCKS proxies
3. Chrome automatically picks it up

### Linux

Chrome respects the `HTTP_PROXY` environment variable:

```bash
# Launch Chrome with proxy
google-chrome --proxy-server="http://192.168.1.100:53128"

# Or for SOCKS5
google-chrome --proxy-server="socks5://192.168.1.100:51080"
```

For permanent setup, add to `~/.bashrc`:

```bash
export HTTP_PROXY="http://192.168.1.100:53128"
```

### Extension: SwitchyOmega (Recommended)

**SwitchyOmega** is the best proxy manager for Chromium browsers.

#### Installation

1. Install from [Chrome Web Store](https://chrome.google.com/webstore/detail/proxy-switchyomega/padekgcemlokbadohgkifijomclgigif)
2. Click the extension icon → Options

#### Configuration

1. Click **New profile** → **Proxy Profile**
2. Name it "Home Proxy"
3. Under **HTTP proxy**:
   - Server: `192.168.1.100`
   - Port: `53128`
4. Under **SOCKS5 proxy**:
   - Server: `192.168.1.100`
   - Port: `51080`
5. Click **Apply changes**

#### Using SwitchyOmega

- Click the extension icon
- Select **Home Proxy** to enable
- Select **System Proxy** or **Direct** to disable

#### Auto Switch (Conditional Proxy)

1. Create a new **Switch Profile**
2. Add rules:
   - Condition: `Host wildcard`, Pattern: `*.youtube.com`, Profile: Home Proxy
   - Condition: `Host wildcard`, Pattern: `*.netflix.com`, Profile: Home Proxy
3. Set default to **Direct**

---

## Safari (macOS)

Safari uses macOS system proxy settings.

### Setup

1. **System Settings → Network**
2. Select your connection (Wi-Fi or Ethernet)
3. Click **Details**
4. Go to **Proxies** tab
5. Enable:
   - **Web Proxy (HTTP)**: `192.168.1.100:53128`
   - **Secure Web Proxy (HTTPS)**: `192.168.1.100:53128`
   - **SOCKS Proxy**: `192.168.1.100:51080`
6. Click **OK**

> Safari does not support per-browser proxy. It always uses system settings.

---

## Safari (iOS/iPadOS)

Safari on iOS/iPadOS uses the system proxy configured in Wi-Fi settings.

See [MOBILE_DEVICES.md](MOBILE_DEVICES.md#ios-iphone--ipad) for iOS proxy setup.

---

## Opera

Opera has a built-in VPN, but you can also configure external proxies.

### Using System Proxy

Opera uses system proxy settings by default.

### Using Extension

Install **SwitchyOmega** from the Opera Add-ons store (same as Chrome instructions above).

---

## Vivaldi

Vivaldi has excellent built-in proxy support.

### Setup

1. **Settings → Network**
2. Under **Proxy**, select **Manual**
3. Fill in:
   - HTTP: `192.168.1.100:53128`
   - HTTPS: `192.168.1.100:53128`
   - SOCKS5: `192.168.1.100:51080`

---

## Tor Browser

Tor Browser already routes through Tor. Adding another proxy creates a proxy chain.

### Using Proxy with Tor

1. Open **Settings → Connection**
2. Click **Settings** next to "Configure how Tor Browser connects to the internet"
3. Select **Use proxy**
4. Fill in your proxy details
5. This creates: **Browser → Your Proxy → Tor → Internet**

> Be careful: This changes your Tor entry node to your proxy server.

---

## Browser Extensions

### Recommended Extensions

| Extension | Browser | Features |
|-----------|---------|----------|
| **Proxy SwitchyOmega** | Chrome/Edge/Brave/Opera | Auto-switch, PAC, multiple profiles |
| **FoxyProxy** | Firefox/Chrome | Pattern-based switching, SOCKS5 support |
| **Proxy Privacy Ruler** | Firefox | Simple on/off toggle |
| **SmartProxy** | Firefox/Chrome | Automatic proxy based on rules |

### FoxyProxy (Firefox)

1. Install [FoxyProxy Basic](https://addons.mozilla.org/firefox/addon/foxyproxy-basic/)
2. Click extension icon → Options
3. Click **Add**
4. Title: `Home Proxy`
5. Type: `HTTP`
6. Hostname: `192.168.1.100`
7. Port: `53128`
8. Save and enable

---

## Testing Browser Proxy

After configuration, verify:

1. Visit `https://ifconfig.me` — should show proxy/VPN IP, not your real IP
2. Visit `https://dnsleaktest.com` — DNS should match proxy location
3. Test speed at `https://fast.com` or `https://speedtest.net`

---

## See Also

- [CLIENT_SETUP.md](CLIENT_SETUP.md) — General client setup
- [MOBILE_DEVICES.md](MOBILE_DEVICES.md) — Mobile browser setup
- [ANDROID_TV.md](ANDROID_TV.md) — Android TV browsers
