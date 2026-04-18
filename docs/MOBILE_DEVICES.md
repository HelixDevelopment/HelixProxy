# Mobile Device Proxy Setup

How to configure iOS/iPadOS and Android phones/tablets to use the Proxy Service.

> **Quick Reference**
> - HTTP Proxy: `http://<HOST_IP>:53128`
> - SOCKS5 Proxy: `socks5://<HOST_IP>:51080`
>
> Replace `<HOST_IP>` with your proxy server's LAN IP.

---

## Table of Contents

1. [iOS (iPhone / iPad)](#ios-iphone--ipad)
2. [Android (Phone / Tablet)](#android-phone--tablet)
3. [Mobile Browsers](#mobile-browsers)
4. [Per-App Proxy](#per-app-proxy)
5. [Testing on Mobile](#testing-on-mobile)
6. [Troubleshooting](#troubleshooting)

---

## iOS (iPhone / iPad)

iOS supports HTTP proxy configuration per Wi-Fi network. All apps using standard URL sessions will respect this setting.

### Wi-Fi Proxy Setup

1. **Settings → Wi-Fi**
2. Tap the **ⓘ** (info) button next to your connected network
3. Scroll to **HTTP Proxy**
4. Select **Manual**
5. Fill in:

   | Field | Value |
   |-------|-------|
   | Server | `192.168.1.100` |
   | Port | `53128` |
   | Authentication | Off (unless you enabled proxy auth) |

6. Tap **Save** (top right)

### iOS Limitations

- iOS Wi-Fi proxy only supports **HTTP** (not SOCKS5)
- System-wide; applies to all apps using URLSession
- Some apps (Netflix, banking apps) may bypass proxy using custom networking
- No per-app proxy without jailbreak

### Shortcuts Automation (Auto-Enable Proxy)

You can create a Shortcut to quickly toggle proxy:

1. **Shortcuts app → Automation → Create Personal Automation**
2. Select **Wi-Fi** → Choose your home network
3. Add action: **Open URL** → `prefs:root=WIFI`
4. This opens Wi-Fi settings when you connect

> Unfortunately, iOS Shortcuts cannot directly modify proxy settings due to sandboxing.

### Using a VPN App with Proxy

Some VPN apps on iOS support proxy chaining:

1. Install a VPN app that supports SOCKS5 (e.g., Shadowrocket, Surge)
2. Configure the VPN app to use your proxy as the upstream
3. This creates: **iOS → VPN App → Your Proxy → Internet**

### Config Profile (Advanced)

For enterprise-managed devices, create a configuration profile:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>PayloadContent</key>
    <array>
        <dict>
            <key>UserDefinedName</key>
            <string>Home Proxy</string>
            <key>ProxyType</key>
            <string>Manual</string>
            <key>ProxyServer</key>
            <string>192.168.1.100</string>
            <key>ProxyPort</key>
            <integer>53128</integer>
            <key>PayloadType</key>
            <string>com.apple.wifi.managed</string>
            <key>PayloadIdentifier</key>
            <string>com.example.proxy.wifi</string>
            <key>PayloadUUID</key>
            <string>A1B2C3D4-E5F6-7890-ABCD-EF1234567890</string>
            <key>PayloadVersion</key>
            <integer>1</integer>
        </dict>
    </array>
</dict>
</plist>
```

Save as `.mobileconfig` and install via Safari or Apple Configurator.

---

## Android (Phone / Tablet)

Android supports both system-wide Wi-Fi proxy and per-app proxy configuration.

### Wi-Fi Proxy Setup (System-Wide)

1. **Settings → Network & Internet → Wi-Fi**
2. Long-press your connected network → **Modify**
3. Tap **Advanced options**
4. Set **Proxy** to **Manual**
5. Fill in:

   | Field | Value |
   |-------|-------|
   | Proxy hostname | `192.168.1.100` |
   | Proxy port | `53128` |
   | Bypass proxy for | `localhost,127.0.0.1` |

6. Tap **Save**

### Samsung One UI

Samsung devices may have slightly different menus:

1. **Settings → Connections → Wi-Fi**
2. Tap gear icon next to network
3. **Advanced → Proxy → Manual**
4. Enter proxy settings

### Xiaomi MIUI

1. **Settings → Wi-Fi**
2. Tap arrow (▶) next to network
3. **Proxy settings → Manual**
4. Enter hostname and port

### Per-App Proxy (No Root)

Some apps allow proxy configuration internally:

#### Chrome
- Uses system proxy by default
- No separate proxy settings in mobile Chrome

#### Firefox
1. **Firefox → Menu (≡) → Settings**
2. **Network → Connection**
3. Select **Manual**
4. HTTP Proxy: `192.168.1.100:53128`
5. SOCKS Host: `192.168.1.100:51080`

#### Telegram
1. **Settings → Data and Storage → Proxy**
2. Add Proxy → SOCKS5
3. Server: `192.168.1.100`, Port: `51080`

#### Discord
Discord does not support proxy on mobile. Use system proxy.

#### YouTube
YouTube does not support in-app proxy. Uses system proxy.

### Global Proxy with ADB (Advanced)

For Android phones, you can set a global proxy via ADB (similar to Android TV):

```bash
# Enable USB debugging on phone first
adb shell settings put global http_proxy 192.168.1.100:53128

# To remove
adb shell settings put global http_proxy :0
```

### Proxy Apps (Third-Party)

These apps can provide per-app or system-wide proxy without root:

| App | Type | Notes |
|-----|------|-------|
| **NetGuard** | VPN + Proxy | No root, firewall + proxy |
| **ProxyDroid** | Root required | Full system proxy |
| **Postern** | VPN service | SOCKS5/HTTP proxy app |
| **Drony** | VPN service | SOCKS5/HTTP proxy app |

#### Using Drony

1. Install Drony from Google Play
2. Open Drony → **Settings**
3. Under **Network**, set:
   - **Local proxy port**: `8118`
   - **Upstream proxy**: `192.168.1.100:53128`
4. Enable Drony VPN
5. Apps now route through Drony → Your Proxy

---

## Mobile Browsers

### Firefox (iOS & Android)

Firefox is the only major mobile browser with built-in proxy settings:

1. **Menu (≡) → Settings**
2. **Network → Connection**
3. Select **Manual proxy configuration**
4. Enter HTTP proxy: `192.168.1.100:53128`

### Chrome (iOS & Android)

Chrome uses system proxy settings. No in-app proxy configuration.

### Safari (iOS)

Safari uses iOS system proxy (Wi-Fi settings). No in-app proxy configuration.

### Brave (iOS & Android)

Brave uses system proxy settings.

### Opera Mini

Opera Mini uses Opera's servers by default (compression proxy). This is separate from your proxy.

---

## Per-App Proxy

### Apps with Built-in Proxy Support

| App | Platform | Proxy Type | Setup Path |
|-----|----------|------------|------------|
| Telegram | iOS/Android | SOCKS5 | Settings → Data → Proxy |
| Signal | Android only | HTTP/SOCKS | Not officially supported |
| WhatsApp | Neither | — | No proxy support |
| Instagram | Neither | — | No proxy support |
| TikTok | Neither | — | No proxy support |

### Using Shadowrocket (iOS - Paid)

Shadowrocket is a powerful proxy client for iOS:

1. Install from App Store (~$3)
2. Tap **+** → Type: HTTP
3. Server: `192.168.1.100`, Port: `53128`
4. Save and connect

### Using Surge (iOS - Paid)

Surge is an advanced networking tool:

1. Install from App Store
2. Create a new profile
3. Add HTTP proxy: `192.168.1.100:53128`
4. Enable proxy

---

## Testing on Mobile

### Test HTTP Proxy

1. Open browser
2. Visit: `http://connectivitycheck.gstatic.com/generate_204`
3. Should load (blank page with 204 status)

### Check Your IP

Visit on your mobile browser:
- `https://ifconfig.me` — shows your external IP
- Should show proxy/VPN IP if proxy is working

### Test Speed

- `https://fast.com` — Netflix speed test
- `https://speedtest.net` — Ookla speed test

### DNS Leak Test

Visit `https://dnsleaktest.com` on mobile:
- Should show DNS servers matching proxy location
- If it shows your ISP's DNS, the proxy isn't routing DNS

---

## Troubleshooting

### iOS: Apps Not Working

Some apps bypass iOS system proxy:
- Banking apps (security)
- Netflix, Disney+ (custom networking)
- Games (raw sockets)

**Solution**: These apps require a VPN-based proxy (like Shadowrocket or Surge).

### Android: "Connected, no internet"

Same as Android TV issue:
1. Verify proxy server works from another device
2. Ensure Squid is in forward proxy mode (not reverse proxy)
3. Check firewall on proxy server

### Battery Drain

Using a proxy app (like Drony or a VPN client) adds battery usage:
- Consider using Wi-Fi proxy instead (no extra battery)
- Or only enable proxy when needed

### Mobile Data

Wi-Fi proxy settings do NOT apply to mobile data. For mobile data proxy:
- iOS: Use a VPN app (Shadowrocket, Surge)
- Android: Use a proxy app (Drony, Postern) or ADB global proxy

---

## See Also

- [CLIENT_SETUP.md](CLIENT_SETUP.md) — General client setup
- [ANDROID_TV.md](ANDROID_TV.md) — Android TV specific guide
- [BROWSERS.md](BROWSERS.md) — Desktop browser setup
