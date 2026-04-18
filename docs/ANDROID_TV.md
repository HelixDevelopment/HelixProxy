# Android TV Setup Guide

Complete guide for connecting Android TV (and Google TV) devices to the Proxy Service.

> **Quick Settings**
> - HTTP Proxy: `http://<HOST_IP>:53128`
> - SOCKS5 Proxy: `socks5://<HOST_IP>:51080`
> - Admin Panel: `http://<HOST_IP>:58080`
>
> Replace `<HOST_IP>` with your proxy server's LAN IP.

---

## Table of Contents

1. [Overview](#overview)
2. [Method 1: Wi-Fi Proxy (System-Wide)](#method-1-wi-fi-proxy-system-wide)
3. [Method 2: Per-App SOCKS5 Proxy](#method-2-per-app-socks5-proxy)
4. [Method 3: ADB Global Proxy](#method-3-adb-global-proxy-advanced)
5. [Troubleshooting "Connected, no internet"](#troubleshooting-connected-no-internet)
6. [Recommended Apps](#recommended-apps)
7. [Limitations](#limitations)

---

## Overview

Android TV supports HTTP proxy configuration at the system level through Wi-Fi settings. This routes all apps' web traffic through the proxy.

However, **not all apps respect the system proxy**. Streaming apps (Netflix, Disney+, Prime Video) often use their own networking and may bypass the system proxy. For these cases, SOCKS5 proxy support at the app level or a router-level solution is needed.

### What Works with System Proxy

✅ Web browsers (Chrome, Firefox TV, Puffin)  
✅ YouTube (partial - may use own CDN)  
✅ Google Play Store downloads  
✅ Most ad-supported free streaming apps  
✅ System updates  

### What May NOT Work

❌ Netflix (uses custom networking)  
❌ Disney+ (uses custom networking)  
❌ Amazon Prime Video (uses custom networking)  
❌ Some live TV apps  

For apps that don't respect system proxy, see [Method 2: Per-App SOCKS5](#method-2-per-app-socks5-proxy).

---

## Method 1: Wi-Fi Proxy (System-Wide)

This is the easiest method and works for most apps.

### Step-by-Step Setup

1. **Open Settings**
   - From the Android TV home screen, go to **Settings** (gear icon)

2. **Navigate to Network**
   - Select **Network & Internet** (or just **Network** on some devices)
   - Choose **Wi-Fi**

3. **Select Your Network**
   - Find and select your current Wi-Fi network
   - You may need to click "See all networks" if it's not visible

4. **Open Network Options**
   - Press and hold the **Select/OK** button on your remote
   - Or press the **menu button** (≡) on the remote
   - Select **Modify network** or **Network options**

5. **Show Advanced Options**
   - Scroll down and select **Advanced options**
   - Set **Proxy** to **Manual**

6. **Enter Proxy Settings**

   | Field | Value |
   |-------|-------|
   | Proxy hostname | Your proxy server IP (e.g., `192.168.1.100`) |
   | Proxy port | `53128` |
   | Bypass proxy for | `localhost,127.0.0.1` |

7. **Save**
   - Press **Save** or **Connect**
   - The TV will reconnect to Wi-Fi with the proxy settings

### Visual Guide (Text)

```
Settings → Network & Internet → Wi-Fi
    ↓
[Select your network] → Hold OK / Press Menu
    ↓
"Modify network"
    ↓
"Advanced options" → Proxy: Manual
    ↓
Proxy hostname: 192.168.1.100
Proxy port: 53128
    ↓
Save
```

### Finding Your Proxy IP

On your proxy server, run:

```bash
./status
```

Look for the **Host IP** line under "Local Network Access".

Alternatively:

```bash
ip addr show | grep "inet " | grep -v 127.0.0.1
```

---

## Method 2: Per-App SOCKS5 Proxy

For apps that don't respect the system HTTP proxy, some support SOCKS5 configuration internally.

### Using Kodi with SOCKS5

Kodi supports both HTTP and SOCKS5 proxies:

1. **Kodi → Settings → System → Internet access**
2. Set **Internet connection** to your Wi-Fi
3. Set **Use proxy server**: **Yes**
4. **Proxy type**: **SOCKS5**
5. **Server**: `192.168.1.100`
6. **Port**: `51080`
7. **No proxy for**: `localhost,127.0.0.1`

### Using VLC (Limited Support)

VLC on Android TV does not have built-in proxy support. Use the system proxy method instead.

### Using SmartTubeNext / SmartTube

SmartTubeNext (YouTube alternative for Android TV) supports proxy:

1. **SmartTubeNext → Settings → General → Web proxy**
2. Enable proxy
3. Set HTTP proxy: `192.168.1.100:53128`

> SmartTubeNext is highly recommended for YouTube on Android TV. It blocks ads and supports SponsorBlock.

---

## Method 3: ADB Global Proxy (Advanced)

Using Android Debug Bridge (ADB), you can set a global proxy that applies system-wide at the OS level. This is more forceful than the Wi-Fi proxy method and may work with more apps.

### Prerequisites

- ADB installed on your computer: `sudo apt install android-tools-adb` (Linux) or download [Android SDK Platform Tools](https://developer.android.com/tools/releases/platform-tools)
- Android TV and computer on the same network
- Developer options enabled on Android TV

### Enable Developer Options on Android TV

1. **Settings → Device Preferences → About**
2. Find **Build** and click it 7 times
3. You will see "You are now a developer!"

### Enable Network ADB

1. **Settings → Device Preferences → Developer options**
2. Enable **Network debugging** (or **ADB debugging**)
3. Note the IP address shown (e.g., `192.168.1.50:5555`)

### Set Global Proxy via ADB

On your computer:

```bash
# Connect to Android TV
adb connect 192.168.1.50:5555

# Set global HTTP proxy
adb shell settings put global http_proxy 192.168.1.100:53128

# Verify
adb shell settings get global http_proxy
# Output: 192.168.1.100:53128
```

### Remove Global Proxy

```bash
adb shell settings put global http_proxy :0
```

### Limitations of Global Proxy

- Some apps still bypass it using raw sockets
- System updates may reset it
- Requires ADB access each time you want to change it

---

## Troubleshooting "Connected, no internet"

This is the most common issue when setting up Android TV with a proxy.

### Cause

Android TV performs a connectivity check to `connectivitycheck.gstatic.com` to verify internet access. If this check fails (e.g., the proxy returns an unexpected response), the TV shows "Connected, no internet" even though the proxy works.

### Solutions

#### Solution 1: Verify Proxy is Working

Test from another device on the same network:

```bash
curl --proxy http://192.168.1.100:53128 -s -o /dev/null -w "%{http_code}" http://connectivitycheck.gstatic.com/generate_204
```

If this doesn't return `204`, the proxy has an issue. Check `./status` on the server.

#### Solution 2: Ensure Standard Forward Proxy Mode

The Squid proxy must be in **standard forward proxy mode**, NOT reverse proxy (accelerator) mode.

Verify in `config/squid/squid.conf`:

```
# CORRECT - Standard forward proxy
http_port 53128

# WRONG - Reverse proxy mode (breaks Android TV)
http_port 53128 accel vhost
```

If you changed this, restart: `./restart`

#### Solution 3: Check Firewall

On the proxy server:

```bash
# Check if ports are open to LAN
sudo ufw status | grep -E '53128|51080'

# If not open, allow them
sudo ufw allow from 192.168.0.0/16 to any port 53128	sudo ufw allow from 192.168.0.0/16 to any port 51080
```

#### Solution 4: Bind Address

Ensure `BIND_ADDRESS=0.0.0.0` in `.env` on the proxy server so it accepts connections from all interfaces, not just localhost.

#### Solution 5: Disable Captive Portal Detection (Advanced)

Some Android TV versions can be forced to ignore the connectivity check:

```bash
adb connect 192.168.1.50:5555
adb shell settings put global captive_portal_mode 0
```

> This prevents the TV from showing "no internet" warnings, but doesn't fix underlying proxy issues.

#### Solution 6: Use IP Address Instead of Hostname

Some Android TV versions have DNS issues with proxy hostnames. Always use the **numeric IP address** (e.g., `192.168.1.100`) instead of a hostname.

---

## Recommended Apps

These apps work well with proxy settings on Android TV:

### Streaming

| App | Proxy Support | Notes |
|-----|--------------|-------|
| **SmartTubeNext** | ✅ System + In-app | Best YouTube client for Android TV |
| **Kodi** | ✅ In-app SOCKS5/HTTP | Highly configurable |
| **Plex** | ✅ System proxy | Works with system proxy |
| **Jellyfin** | ✅ System proxy | Open-source alternative to Plex |
| **VLC** | ⚠️ System only | No in-app proxy settings |

### Browsers

| App | Proxy Support | Notes |
|-----|--------------|-------|
| **Chrome** | ✅ System proxy | Built-in, respects system settings |
| **Firefox for TV** | ✅ System proxy | Good privacy features |
| **Puffin TV** | ✅ In-app | Cloud-based, fast |

### Utilities

| App | Proxy Support | Notes |
|-----|--------------|-------|
| **Downloader** | ✅ System proxy | For sideloading APKs |
| **File Commander** | ✅ System proxy | File manager with network support |

---

## Limitations

### DRM Content

Apps with DRM (Digital Rights Management) like Netflix, Disney+, and Prime Video use encrypted connections that:
- May not route through HTTP proxies
- Often use certificate pinning
- Use custom networking stacks

**Solutions**:
1. Use router-level proxy/VPN
2. Use Smart DNS services alongside proxy
3. Cast from a proxied device instead

### Live TV Apps

Many live TV streaming apps (Hulu Live, YouTube TV, Sling) use geo-restrictions:
- HTTP proxy may work for the app interface
- Video streams may use separate CDN endpoints
- SOCKS5 provides better compatibility

### System Updates

System proxy settings apply to most Google services, but system updates may:
- Download from Google servers directly
- Use Google's cache servers (bypassing proxy)

---

## Quick Checklist

- [ ] Proxy server running: `./status` shows healthy
- [ ] Know proxy server IP: `./status` → Local Network Access → Host IP
- [ ] Android TV on same Wi-Fi network as proxy
- [ ] Set Wi-Fi proxy to: `HOST_IP:53128`
- [ ] Test with Chrome or SmartTubeNext first
- [ ] If "no internet", verify Squid is in forward proxy mode
- [ ] Check firewall allows port 53128 from LAN

---

## See Also

- [CLIENT_SETUP.md](CLIENT_SETUP.md) — General client setup for all devices
- [TROUBLESHOOTING.md](TROUBLESHOOTING.md) — Common issues and fixes
- [NETWORK_MODES.md](NETWORK_MODES.md) — VPN vs no-VPN modes
