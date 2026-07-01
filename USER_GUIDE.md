# Proxy Service - User Guide

Complete guide for setting up, configuring, and using the Proxy Service.

## Table of Contents

1. [Installation](#installation)
2. [Configuration](#configuration)
3. [Starting and Stopping](#starting-and-stopping)
4. [Client Setup](#client-setup)
5. [Android TV](#android-tv)
6. [VPN Setup](#vpn-setup)
7. [Cache Management](#cache-management)
8. [Monitoring](#monitoring)
9. [Advanced Configuration](#advanced-configuration)
10. [FAQ](#faq)

## Quick Reference

- HTTP Proxy: `http://<HOST_IP>:53128`
- HTTPS Proxy: `http://<HOST_IP>:53128`
- SOCKS5 Proxy: `socks5://<HOST_IP>:51080`
- Admin Panel: `http://<HOST_IP>:58080`

---

## Installation

### Prerequisites

- **Container Runtime**: Docker or Podman
- **Compose Tool**: docker-compose, podman-compose, or built-in compose
- **VPN Config** (optional): .ovpn configuration file from your VPN provider

### Step 1: Clone Repository

```bash
git clone git@github.com:vasic-digital/Proxy.git
cd Proxy
```

### Step 2: Configure Environment

```bash
cp .env.example .env
nano .env  # or your preferred editor
```

### Step 3: Initialize

```bash
./init
```

This creates:
- Configuration files
- Cache directories
- VPN auth file (if VPN enabled)

### Step 4: Start Service

```bash
./start
```

---

## Configuration

### Basic Settings

Edit `.env` file:

```bash
# Network ports
HTTP_PROXY_PORT=53128      # HTTP/HTTPS proxy
SOCKS_PROXY_PORT=51080     # SOCKS5 proxy
PROXY_ADMIN_PORT=58080     # Admin web interface

# Cache settings
CACHE_DIR=/path/to/cache
CACHE_MAX_SIZE_GB=50
CACHE_MAX_AGE_DAYS=30

# Logging
LOG_LEVEL=info
LOG_DIR=./logs
```

### VPN Settings

```bash
USE_VPN=true
VPN_USERNAME=your_username
VPN_PASSWORD=your_password
VPN_OVPN_PATH=/path/to/config.ovpn
VPN_AUTO_RECONNECT=true
```

### Authentication

```bash
PROXY_AUTH_ENABLED=true
PROXY_USERNAME=your_proxy_user
PROXY_PASSWORD=your_proxy_pass
```

### Network Access Control

```bash
# Allowed networks (comma-separated CIDR)
ALLOWED_NETWORKS=192.168.0.0/16,10.0.0.0/8,172.16.0.0/12

# Bind to specific interface
BIND_ADDRESS=0.0.0.0  # All interfaces
# or
BIND_ADDRESS=192.168.1.100  # Specific IP
```

---

## Starting and Stopping

### Start Commands

```bash
# Normal start
./start

# Start without VPN
./start --no-vpn

# Verbose output
./start -v

# Pull latest images first
./start --pull

# Show status after start
./start --status
```

### Stop Commands

```bash
# Normal stop
./stop

# Stop and remove containers
./stop --remove

# Stop, remove containers and images
./stop --purge

# Stop and clear cache
./stop --clean-cache
```

### Restart Commands

```bash
# Normal restart
./restart

# Restart with cache clear
./restart --clean-cache

# Verbose restart
./restart -v
```

---

## Client Setup

### Finding Your Host IP

```bash
# Linux
ip addr show | grep "inet " | grep -v 127.0.0.1

# macOS
ifconfig | grep "inet " | grep -v 127.0.0.1
```

### Linux Clients

#### Temporary (Current Shell)

```bash
export HTTP_PROXY="http://192.168.1.100:53128"
export HTTPS_PROXY="http://192.168.1.100:53128"
export ALL_PROXY="socks5://192.168.1.100:51080"
```

#### Permanent (All Users)

Add to `/etc/environment`:

```
HTTP_PROXY="http://192.168.1.100:53128"
HTTPS_PROXY="http://192.168.1.100:53128"
NO_PROXY="localhost,127.0.0.1,.local"
```

#### APT (Debian/Ubuntu)

Create `/etc/apt/apt.conf.d/proxy.conf`:

```
Acquire::http::Proxy "http://192.168.1.100:53128";
Acquire::https::Proxy "http://192.168.1.100:53128";
```

#### YUM/DNF (RHEL/CentOS/Fedora)

Add to `/etc/dnf/dnf.conf` or `/etc/yum.conf`:

```
proxy=http://192.168.1.100:53128
```

### macOS Clients

#### System-wide

1. System Preferences → Network
2. Select network → Advanced → Proxies
3. Enable HTTP/HTTPS proxy
4. Web Proxy Server: `192.168.1.100:53128`

#### Terminal (zsh)

Add to `~/.zshrc`:

```bash
export HTTP_PROXY="http://192.168.1.100:53128"
export HTTPS_PROXY="http://192.168.1.100:53128"
```

### Windows Clients

#### System-wide

1. Settings → Network & Internet → Proxy
2. Enable "Use a proxy server"
3. Address: `192.168.1.100`, Port: `53128`

#### PowerShell

```powershell
$env:HTTP_PROXY = "http://192.168.1.100:53128"
$env:HTTPS_PROXY = "http://192.168.1.100:53128"
```

#### Command Prompt

```cmd
set HTTP_PROXY=http://192.168.1.100:53128
set HTTPS_PROXY=http://192.168.1.100:53128
```

### Mobile Devices

#### iOS

1. Settings → Wi-Fi → (network) → Configure Proxy
2. Select "Manual"
3. Server: `192.168.1.100`, Port: `53128`

#### Android

1. Settings → Wi-Fi → (network) → Modify
2. Advanced options → Proxy → Manual
3. Hostname: `192.168.1.100`, Port: `53128`

### Browser Configuration

See [docs/BROWSERS.md](docs/BROWSERS.md) for detailed browser setup.

Quick configuration:

#### Firefox

1. Settings → General → Network Settings → Settings
2. Select "Manual proxy configuration"
3. HTTP Proxy: `192.168.1.100`, Port: `53128`
4. SOCKS Host: `192.168.1.100`, Port: `51080`, Type: SOCKS v5
5. Check "Proxy DNS when using SOCKS v5"

#### Chrome/Edge/Brave

Use system proxy settings or install SwitchyOmega extension:

1. Install SwitchyOmega from Chrome Web Store
2. Create new profile → Proxy Profile
3. HTTP: `192.168.1.100:53128`
4. SOCKS5: `192.168.1.100:51080`

---

## Android TV

Android TV is one of the most popular use cases for this proxy service. See the dedicated guide for complete setup instructions:

**[→ Android TV Setup Guide](docs/ANDROID_TV.md)**

Quick setup:

1. **Settings → Network & Internet → Wi-Fi**
2. Select your network → **Modify network**
3. **Advanced options** → Proxy: **Manual**
4. Proxy hostname: `<HOST_IP>`
5. Proxy port: `53128`
6. **Save**

> If you see "Connected, no internet", the Squid proxy must be in standard forward proxy mode (not reverse/accel mode). Run `./init && ./restart` to regenerate the correct configuration.

---

## VPN Setup

### Getting VPN Configuration

1. Subscribe to a VPN provider (NordVPN, ExpressVPN, Mullvad, etc.)
2. Download OpenVPN configuration files
3. Select a server location

### Configuration Steps

```bash
# 1. Copy .ovpn file to project
cp ~/Downloads/server.ovpn ./vpn-config.ovpn

# 2. Edit .env
nano .env
```

Add VPN settings:

```bash
USE_VPN=true
VPN_USERNAME=your_email@example.com
VPN_PASSWORD=your_vpn_password
VPN_OVPN_PATH=/absolute/path/to/vpn-config.ovpn
```

### Verify VPN Connection

```bash
# Start with VPN
./start

# Check VPN status
./status -v

# Verify IP is masked
curl --proxy http://localhost:53128 https://ifconfig.me
```

### VPN Troubleshooting

#### Connection Fails

1. Check credentials
2. Verify .ovpn file path
3. Check container logs:
   ```bash
   podman logs proxy-vpn
   ```

#### DNS Leaks

Add to `.env`:

```bash
DNS_SERVERS=1.1.1.1,1.0.0.1
```

---

## Cache Management

### Viewing Cache Status

```bash
# Basic statistics
./cachectl stats

# Size breakdown
./cachectl size

# List cached content
./cachectl list
```

### Clearing Cache

```bash
# Clear with confirmation
./cachectl clear

# Force clear
./cachectl clear -f
```

### Manual Invalidation

```bash
# Remove stale files
./cachectl invalidate

# Trim to specific size
./cachectl trim 30  # 30 GB
```

### Automatic Invalidation

Configured in `.env`:

```bash
CACHE_AUTO_INVALIDATE=true
CACHE_INVALIDATE_INTERVAL=24  # hours
CACHE_MAX_AGE_DAYS=30
```

### Streaming Cache

```bash
# Enable streaming cache
STREAMING_CACHE_ENABLED=true

# Configure streaming domains
STREAMING_DOMAINS=youtube.com,googlevideo.com,cdn

# Streaming cache size
STREAMING_CACHE_MAX_SIZE_GB=20
```

---

## Monitoring

### Service Status

```bash
# Basic status
./status

# Detailed status
./status -v

# JSON output (for scripting)
./status --json

# Continuous monitoring
./status --watch
```

### Admin Panel

Access at: `http://HOST_IP:58080`

Features:
- Real-time service status
- Cache statistics
- Connection information
- Configuration overview

### Log Files

```bash
# Proxy logs
tail -f logs/proxy.log

# Squid access log
tail -f logs/squid/access.log

# Squid cache log
tail -f logs/squid/cache.log

# VPN log
podman logs -f proxy-vpn
```

### Health Checks

```bash
# HTTP proxy health
curl --proxy http://localhost:53128 http://connectivitycheck.gstatic.com/generate_204

# SOCKS proxy health
curl --proxy socks5://localhost:51080 http://connectivitycheck.gstatic.com/generate_204

# Admin health
curl http://localhost:58080/health
```

---

## Advanced Configuration

### Custom DNS

```bash
DNS_SERVERS=8.8.8.8,8.8.4.4,1.1.1.1
DNS_CACHING_ENABLED=true
DNS_CACHE_TTL=3600
```

### Performance Tuning

```bash
# Maximum concurrent connections
MAX_CONNECTIONS=4096

# Connection timeout
CONNECTION_TIMEOUT=60

# Cache memory
CACHE_MEMORY_SIZE_MB=512
```

### Ad Blocking

```bash
BLOCK_ADS=true
BLOCK_MALICIOUS=true
# Optional custom blocklist
BLOCKLIST_FILE=./config/blocklist.txt
```

### Custom Squid Configuration

Edit `config/squid/squid.conf` for advanced settings:

```bash
# Add custom refresh patterns
refresh_pattern -i youtube.* 10080 90% 43200 override-expire

# Add custom ACLs
acl mynetwork src 192.168.1.0/24
http_access allow mynetwork
```

---

## FAQ

### Q: Can I use both HTTP and SOCKS proxies?

**A:** Yes, both run simultaneously on different ports. HTTP proxy on 53128, SOCKS on 51080.

### Q: How do I know if VPN is working?

**A:** Check your external IP:
```bash
curl --proxy http://localhost:53128 https://ifconfig.me
```

### Q: Why is caching not working for HTTPS?

**A:** HTTPS content is encrypted. Enable HTTPS inspection (MITM) for HTTPS caching, but this requires certificate setup.

### Q: How do I restrict access to specific IPs?

**A:** Set `ALLOWED_NETWORKS` in `.env`:
```bash
ALLOWED_NETWORKS=192.168.1.0/24
```

### Q: Cache is growing too large

**A:** Reduce `CACHE_MAX_SIZE_GB` or enable automatic invalidation:
```bash
CACHE_MAX_SIZE_GB=30
CACHE_AUTO_INVALIDATE=true
```

### Q: VPN disconnects frequently

**A:** Enable auto-reconnect:
```bash
VPN_AUTO_RECONNECT=true
VPN_HEALTH_INTERVAL=30
```

### Q: Can I run this on a remote server?

**A:** Yes. Update `BIND_ADDRESS=0.0.0.0` and configure firewall to allow access.

### Q: How do I debug connection issues?

**A:** Check logs and enable verbose mode:
```bash
LOG_LEVEL=debug
./start -v
tail -f logs/proxy.log
```

---

## Additional Documentation

- [Client Setup Guide](docs/CLIENT_SETUP.md) — All devices (consoles, smart TVs, NAS, etc.)
- [Android TV Guide](docs/ANDROID_TV.md) — Android TV / Google TV
- [Browser Guide](docs/BROWSERS.md) — Firefox, Chrome, Edge, Safari
- [Mobile Devices](docs/MOBILE_DEVICES.md) — iOS and Android phones/tablets
- [Network Modes](docs/NETWORK_MODES.md) — VPN vs no-VPN explained
- [Architecture](docs/ARCHITECTURE.md) — System design
- [Caching](docs/CACHE.md) — Cache management
- [Troubleshooting](docs/TROUBLESHOOTING.md) — Common issues

## Support

For issues and feature requests:
- GitHub Issues: https://github.com/vasic-digital/Proxy/issues
- Check `docs/` directory for detailed documentation
