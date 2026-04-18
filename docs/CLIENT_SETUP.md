# Client Setup Guide

Complete guide for configuring every type of device to use the Proxy Service.

> **Quick Reference**
> - HTTP Proxy: `http://<HOST_IP>:53128`
> - HTTPS Proxy: `http://<HOST_IP>:53128` (same as HTTP)
> - SOCKS5 Proxy: `socks5://<HOST_IP>:51080`
> - Admin Panel: `http://<HOST_IP>:58080`

Replace `<HOST_IP>` with your proxy server's LAN IP address (e.g., `10.151.90.249`).
Run `./status` on the proxy server to see your exact connection details.

---

## Table of Contents

1. [Finding Your Host IP](#finding-your-host-ip)
2. [Desktop Operating Systems](#desktop-operating-systems)
3. [Web Browsers](#web-browsers)
4. [Mobile Devices](#mobile-devices)
5. [Android TV](#android-tv)
6. [Gaming Consoles](#gaming-consoles)
7. [Smart TVs & Streaming Devices](#smart-tvs--streaming-devices)
8. [Other Devices](#other-devices)
9. [Per-App Proxy Configuration](#per-app-proxy-configuration)
10. [Verifying Your Connection](#verifying-your-connection)

---

## Finding Your Host IP

Before configuring any client, you need the proxy server's IP address on your local network.

### On the Proxy Server

```bash
# Linux
ip addr show | grep "inet " | grep -v 127.0.0.1

# Or use the status script
./status
```

### Common IP Ranges

- Home networks usually use `192.168.x.x` or `10.x.x.x`
- The proxy must be on the same network as your clients
- Ensure `BIND_ADDRESS=0.0.0.0` in `.env` to accept LAN connections

---

## Desktop Operating Systems

### Linux

#### Temporary (Current Shell Only)

```bash
export HTTP_PROXY="http://192.168.1.100:53128"
export HTTPS_PROXY="http://192.168.1.100:53128"
export ALL_PROXY="socks5://192.168.1.100:51080"
export NO_PROXY="localhost,127.0.0.1,.local"
```

#### Permanent (All Users)

Edit `/etc/environment`:

```bash
HTTP_PROXY="http://192.168.1.100:53128"
HTTPS_PROXY="http://192.168.1.100:53128"
NO_PROXY="localhost,127.0.0.1,.local,192.168.0.0/16,10.0.0.0/8"
```

Log out and back in for changes to take effect.

#### Permanent (Current User Only)

Add to `~/.bashrc`, `~/.zshrc`, or `~/.profile`:

```bash
export HTTP_PROXY="http://192.168.1.100:53128"
export HTTPS_PROXY="http://192.168.1.100:53128"
export ALL_PROXY="socks5://192.168.1.100:51080"
export NO_PROXY="localhost,127.0.0.1,.local"
```

#### GNOME/KDE Desktop (GUI)

1. **Settings → Network → Proxy**
2. Select **Manual**
3. HTTP Proxy: `192.168.1.100`, Port: `53128`
4. HTTPS Proxy: `192.168.1.100`, Port: `53128`
5. SOCKS Host: `192.168.1.100`, Port: `51080`
6. Ignore Hosts: `localhost,127.0.0.1,.local`

#### APT Package Manager (Debian/Ubuntu)

Create `/etc/apt/apt.conf.d/proxy.conf`:

```
Acquire::http::Proxy "http://192.168.1.100:53128";
Acquire::https::Proxy "http://192.168.1.100:53128";
```

#### DNF/YUM (RHEL/CentOS/Fedora)

Add to `/etc/dnf/dnf.conf`:

```
proxy=http://192.168.1.100:53128
```

#### Docker/Podman

Create/edit `~/.config/containers/containers.conf` (Podman) or `/etc/docker/daemon.json` (Docker):

```json
{
  "http-proxy": "http://192.168.1.100:53128",
  "https-proxy": "http://192.168.1.100:53128",
  "no-proxy": "localhost,127.0.0.1"
}
```

#### Git

```bash
git config --global http.proxy http://192.168.1.100:53128
git config --global https.proxy http://192.168.1.100:53128
```

#### curl/wget

```bash
# curl (one-time)
curl --proxy http://192.168.1.100:53128 https://example.com

# wget (one-time)
wget --proxy=on -e http_proxy=http://192.168.1.100:53128 https://example.com
```

---

### macOS

#### System-Wide (GUI)

1. **System Settings → Network**
2. Select your active connection (Wi-Fi or Ethernet)
3. Click **Details**
4. Go to **Proxies** tab
5. Enable:
   - **Web Proxy (HTTP)**: Server `192.168.1.100`, Port `53128`
   - **Secure Web Proxy (HTTPS)**: Server `192.168.1.100`, Port `53128`
   - **SOCKS Proxy**: Server `192.168.1.100`, Port `51080`
6. Click **OK**

#### Terminal (zsh/bash)

Add to `~/.zshrc` or `~/.bash_profile`:

```bash
export HTTP_PROXY="http://192.168.1.100:53128"
export HTTPS_PROXY="http://192.168.1.100:53128"
export ALL_PROXY="socks5://192.168.1.100:51080"
export NO_PROXY="localhost,127.0.0.1,.local"
```

#### Homebrew

```bash
export HOMEBREW_PROXY="http://192.168.1.100:53128"
```

---

### Windows

#### System-Wide (Settings)

1. **Settings → Network & Internet → Proxy**
2. Under "Manual proxy setup", click **Set up**
3. Toggle **Use a proxy server: ON**
4. Proxy IP address: `192.168.1.100`
5. Port: `53128`
6. Click **Save**

> **Note**: Windows system proxy only supports HTTP/HTTPS. For SOCKS5, use browser extensions or individual app settings.

#### PowerShell (Current Session)

```powershell
$env:HTTP_PROXY = "http://192.168.1.100:53128"
$env:HTTPS_PROXY = "http://192.168.1.100:53128"
```

#### Command Prompt

```cmd
set HTTP_PROXY=http://192.168.1.100:53128
set HTTPS_PROXY=http://192.168.1.100:53128
```

#### Environment Variables (Permanent)

1. Press `Win + R`, type `sysdm.cpl`, press Enter
2. **Advanced → Environment Variables**
3. Under "User variables", click **New**
4. Variable name: `HTTP_PROXY`, Value: `http://192.168.1.100:53128`
5. Repeat for `HTTPS_PROXY`

#### Windows Subsystem for Linux (WSL)

Add to `~/.bashrc` inside WSL:

```bash
export HTTP_PROXY="http://$(cat /etc/resolv.conf | grep nameserver | awk '{print $2}'):53128"
export HTTPS_PROXY="$HTTP_PROXY"
```

> WSL uses a virtual network. Use the Windows host IP from `/etc/resolv.conf`.

---

## Web Browsers

See [BROWSERS.md](BROWSERS.md) for detailed browser-specific configuration.

Quick links:
- [Firefox Setup](BROWSERS.md#firefox)
- [Chrome Setup](BROWSERS.md#chrome--edge--brave)
- [Safari Setup](BROWSERS.md#safari-macos)

---

## Mobile Devices

See [MOBILE_DEVICES.md](MOBILE_DEVICES.md) for detailed mobile configuration.

Quick links:
- [iOS Setup](MOBILE_DEVICES.md#ios-iphone--ipad)
- [Android Setup](MOBILE_DEVICES.md#android-phone--tablet)

---

## Android TV

See [ANDROID_TV.md](ANDROID_TV.md) for the complete Android TV setup guide.

> Android TV is one of the most common use cases for this proxy. The dedicated guide covers:
> - Wi-Fi proxy configuration
> - App-level proxy with SOCKS5
> - Resolving "Connected, no internet" issues
> - Recommended apps that support SOCKS5

---

## Gaming Consoles

Most gaming consoles do **not** support HTTP proxy configuration directly. However, you can route console traffic through the proxy using these methods:

### Method 1: Router-Level Proxy (Recommended)

Configure your router to route all traffic through the proxy server:

1. Access router admin panel (usually `192.168.1.1` or `192.168.0.1`)
2. Look for **WAN Settings** or **Internet Settings**
3. Some routers support proxy settings in the WAN configuration
4. Set HTTP proxy to `192.168.1.100:53128`

> **Note**: Not all routers support this. Check your router manual.

### Method 2: Secondary Router/AP with Proxy

Use a travel router or old router with OpenWrt/DD-WRT:

1. Install OpenWrt/DD-WRT on a secondary router
2. Connect secondary router to main network via WAN
3. Configure transparent proxy on the secondary router
4. Connect gaming console to secondary router's Wi-Fi

### Method 3: Windows Internet Connection Sharing (ICS)

On a Windows PC:

1. Connect PC to proxy (system proxy settings)
2. Enable Internet Connection Sharing
3. Share the proxy connection to an Ethernet port
4. Connect console to PC via Ethernet

### Supported Consoles

| Console | Native Proxy Support | Notes |
|---------|---------------------|-------|
| PlayStation 5 | ❌ No | Use router-level or PC sharing |
| PlayStation 4 | ❌ No | Use router-level or PC sharing |
| Xbox Series X/S | ❌ No | Use router-level or PC sharing |
| Xbox One | ❌ No | Use router-level or PC sharing |
| Nintendo Switch | ❌ No | Use router-level or PC sharing |
| Steam Deck | ✅ Yes | Linux desktop - use system proxy |

---

## Smart TVs & Streaming Devices

### General Smart TVs (Samsung, LG, Sony, etc.)

Most Smart TVs have limited proxy support:

1. **Network Settings → Wi-Fi → Advanced**
2. Some models show a **Proxy** option
3. If available, set:
   - Proxy Type: **Manual**
   - Server: `192.168.1.100`
   - Port: `53128`

> Most Smart TVs do NOT have proxy settings. Use router-level configuration instead.

### Apple TV

Apple TV does **not** support proxy configuration directly.

**Workarounds**:
1. Configure proxy on your router
2. Use a VPN-enabled router
3. Share connection from a Mac via Ethernet:
   - Mac: System Settings → General → Sharing → Internet Sharing
   - Share from Wi-Fi to Ethernet (with proxy enabled)
   - Connect Apple TV to Mac via Ethernet

### Amazon Fire TV / Fire Stick

Fire TV OS is Android-based and supports proxy:

1. **Settings → Network**
2. Select your Wi-Fi network
3. Press the menu button (≡) on remote
4. Select **Advanced**
5. Set **Proxy** to **Manual**
6. Proxy hostname: `192.168.1.100`
7. Proxy port: `53128`

> Fire TV apps may not respect system proxy. Use [ADB](https://developer.amazon.com/docs/fire-tv/connecting-adb-to-device.html) to set global proxy:
> ```bash
> adb connect <FIRE_TV_IP>
> adb shell settings put global http_proxy 192.168.1.100:53128
> ```

### Chromecast / Google TV

Chromecast devices do **not** support proxy configuration.

**Workarounds**:
1. Configure proxy at router level
2. Use a DNS-based solution (Smart DNS) alongside proxy
3. Cast from a device that is already using the proxy

### Roku

Roku devices do **not** support proxy configuration.

**Workarounds**:
1. Router-level proxy configuration
2. Use a VPN-enabled router

---

## Other Devices

### Raspberry Pi / Single Board Computers

```bash
# Add to /etc/environment
HTTP_PROXY="http://192.168.1.100:53128"
HTTPS_PROXY="http://192.168.1.100:53128"

# Or for apt
sudo nano /etc/apt/apt.conf.d/proxy.conf
# Add: Acquire::http::Proxy "http://192.168.1.100:53128";
```

### Network Printers

Most printers do not support proxy. For firmware updates:
1. Temporarily disable proxy on the host
2. Or download firmware manually via proxy and install via USB

### IoT Devices (Smart Home)

IoT devices generally cannot use HTTP proxies. For devices that need internet:
1. Whitelist their IPs in your router to bypass proxy
2. Or use a separate VLAN without proxy

### NAS (Synology, QNAP, etc.)

Most NAS systems support proxy in their network settings:

**Synology DSM**:
1. Control Panel → Network → Proxy
2. Enable proxy, enter `192.168.1.100:53128`

**QNAP QTS**:
1. Control Panel → Network & Virtual Switch → Proxy
2. Enter proxy settings

---

## Per-App Proxy Configuration

Many applications have their own proxy settings that override system settings.

### Command-Line Tools

| Tool | Command |
|------|---------|
| curl | `curl --proxy http://192.168.1.100:53128 URL` |
| wget | `wget --proxy=on -e http_proxy=http://192.168.1.100:53128 URL` |
| npm | `npm config set proxy http://192.168.1.100:53128` |
| pip | `pip install --proxy http://192.168.1.100:53128 package` |
| gem | `gem install package -p http://192.168.1.100:53128` |
| conda | `conda config --set proxy_servers.http http://192.168.1.100:53128` |
| go | `export HTTP_PROXY=http://192.168.1.100:53128` |
| rust/cargo | `export HTTP_PROXY=http://192.168.1.100:53128` |

### Development Tools

**VS Code**:
1. Open Settings (Ctrl+,)
2. Search "proxy"
3. Set `http.proxy`: `http://192.168.1.100:53128`

**IntelliJ IDEA / Android Studio**:
1. File → Settings → Appearance & Behavior → System Settings → HTTP Proxy
2. Select **Manual proxy configuration**
3. HTTP: `192.168.1.100:53128`

**Postman**:
1. Settings → Proxy
2. Toggle **Global Proxy Configuration**
3. Proxy Server: `192.168.1.100:53128`

### Media Players

**VLC**:
1. Tools → Preferences → Advanced
2. Input/Codecs → Network caching
3. VLC does not support HTTP proxy for streaming directly

**Kodi**:
1. Settings → System → Internet access
2. Set HTTP proxy: `192.168.1.100:53128`

---

## Verifying Your Connection

After configuring any device, verify the proxy is working:

### Test HTTP Proxy

```bash
curl --proxy http://192.168.1.100:53128 -s -o /dev/null -w "%{http_code}" http://connectivitycheck.gstatic.com/generate_204
# Expected: 204
```

### Test HTTPS Proxy

```bash
curl --proxy http://192.168.1.100:53128 -s -o /dev/null -w "%{http_code}" https://www.google.com
# Expected: 200
```

### Test SOCKS5 Proxy

```bash
curl --proxy socks5h://192.168.1.100:51080 -s -o /dev/null -w "%{http_code}" https://www.google.com
# Expected: 200
```

### Check Your External IP

```bash
curl --proxy http://192.168.1.100:53128 https://ifconfig.me
```

If using VPN, this should show the VPN server's IP, not your home IP.

---

## Troubleshooting Client Connections

### "Connected, no internet" (Android TV / Mobile)

1. Verify proxy is running: `./status` on server
2. Test from another device on same network
3. Check firewall: `sudo ufw allow 53128/tcp && sudo ufw allow 51080/tcp`
4. Ensure `BIND_ADDRESS=0.0.0.0` in server's `.env`
5. Try connecting via IP instead of hostname

### Connection Refused

1. Verify proxy server IP is correct
2. Check ports are listening: `ss -tlnp | grep -E '53128|51080'`
3. Ensure proxy and client are on same network
4. Check if VPN profile is needed: `./start --no-vpn`

### Slow Performance

1. Check cache stats: `./cache stats`
2. Monitor server resources: `podman stats`
3. Test without proxy for comparison
4. Consider enabling VPN for better routing

---

## See Also

- [Android TV Guide](ANDROID_TV.md) — Detailed Android TV setup
- [Browser Guide](BROWSERS.md) — Chrome, Firefox, Edge, Safari
- [Mobile Devices Guide](MOBILE_DEVICES.md) — iOS and Android
- [TROUBLESHOOTING.md](TROUBLESHOOTING.md) — Common issues
- [NETWORK_MODES.md](NETWORK_MODES.md) — VPN vs no-VPN modes
