# VPN Configuration Guide

## Overview

The Proxy Service can route all traffic through a VPN tunnel, ensuring privacy and access to geo-restricted content.

## VPN Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                      PROXY SERVICE                          │
│                                                             │
│  ┌─────────────┐    ┌─────────────┐    ┌─────────────┐    │
│  │   CLIENT    │───>│   PROXY     │───>│    VPN      │    │
│  │  REQUEST    │    │  (Squid)    │    │  CONTAINER  │    │
│  └─────────────┘    └─────────────┘    └──────┬──────┘    │
│                                                 │            │
│                                                 │ Encrypted  │
│                                                 │ Tunnel     │
└─────────────────────────────────────────────────│────────────┘
                                                  │
                                                  ▼
                                         ┌─────────────┐
                                         │ VPN SERVER  │
                                         │  (Remote)   │
                                         └──────┬──────┘
                                                │
                                                ▼
                                         ┌─────────────┐
                                         │  INTERNET   │
                                         └─────────────┘
```

## Supported VPN Providers

### Tested Providers

| Provider | Protocol | Notes |
|----------|----------|-------|
| NordVPN | OpenVPN | Recommended |
| ExpressVPN | OpenVPN | Works well |
| Mullvad | OpenVPN/WireGuard | WireGuard requires config |
| PIA | OpenVPN | Works well |
| ProtonVPN | OpenVPN | Works well |
| Surfshark | OpenVPN | Works well |

### Requirements

- OpenVPN protocol support
- .ovpn configuration file
- Username/password credentials (or certificate)

## Configuration

### Step 1: Get VPN Configuration

1. Log into your VPN provider's website
2. Download OpenVPN configuration files
3. Select a server location
4. Extract the .ovpn file

### Step 2: Configure Environment

Edit `.env`:

```bash
# Enable VPN
USE_VPN=true

# VPN Credentials
VPN_USERNAME=your_username
VPN_PASSWORD=your_password

# Path to .ovpn file (absolute path recommended)
VPN_OVPN_PATH=/absolute/path/to/config.ovpn

# Auto-reconnect on disconnect
VPN_AUTO_RECONNECT=true

# Health check interval (seconds)
VPN_HEALTH_INTERVAL=30
```

### Step 3: Start Service

```bash
./start
```

### Step 4: Verify Connection

```bash
# Check VPN status
./status

# Verify IP is masked
curl --proxy http://localhost:53128 https://ifconfig.me
```

## VPN Container Details

### Image: dperson/openvpn-client

Features:
- Lightweight Alpine-based image
- Automatic firewall configuration
- Health check support
- DNS leak prevention

### Capabilities Required

```yaml
cap_add:
  - NET_ADMIN
devices:
  - /dev/net/tun:/dev/net/tun
```

### Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `VPNFILES` | VPN config directory | /vpn |
| `FIREWALL` | Enable firewall | on |
| `ROUTE_DELAY` | Delay before adding routes | 5 |
| `PING` | Health check interval | 30 |

## Health Monitoring

### Built-in Health Check

```yaml
healthcheck:
  test: ["CMD", "ping", "-c", "1", "-W", "5", "8.8.8.8"]
  interval: 30s
  timeout: 10s
  retries: 3
```

### VPN Monitor Container

The `vpn-monitor` container:
- Monitors VPN connectivity every 30 seconds
- Triggers auto-reconnect on disconnect
- Optionally invalidates cache on reconnect

### Manual Health Check

```bash
# Via status script
./status

# Direct check
podman exec proxy-vpn ping -c 1 8.8.8.8
```

## Auto-Reconnect

### Configuration

```bash
VPN_AUTO_RECONNECT=true
```

### Behavior

1. VPN disconnects
2. Monitor detects disconnection
3. Container is restarted
4. Connection is re-established
5. Optional cache invalidation

### Cache Invalidation on Reconnect

```bash
CACHE_INVALIDATE_ON_VPN_RECONNECT=true
```

Use this when:
- Switching VPN servers
- Geographic location changes
- Content access restrictions

## DNS Configuration

### Prevent DNS Leaks

```bash
DNS_SERVERS=1.1.1.1,1.0.0.1
```

### Use VPN DNS

Most .ovpn files include DNS settings. If not:

1. Edit .ovpn file
2. Add:
   ```
   dhcp-option DNS 10.8.0.1
   ```
   (Replace with VPN's DNS server)

### Verify No Leaks

```bash
# Check DNS
curl --proxy http://localhost:53128 https://dnsleaktest.com
```

## Multiple VPN Servers

### Method 1: Multiple .ovpn Files

```bash
# Switch between configs
VPN_OVPN_PATH=/path/to/server1.ovpn  # US server
VPN_OVPN_PATH=/path/to/server2.ovpn  # EU server
```

### Method 2: Dynamic Server Selection

Some providers allow server selection in .ovpn:
```
remote-random
remote server1.provider.com 1194
remote server2.provider.com 1194
```

## Troubleshooting

### Connection Fails

**Symptoms**: VPN container won't start or exits immediately

**Solutions**:
1. Check credentials in `.env`
2. Verify .ovpn file path
3. Check .ovpn file permissions
4. View logs:
   ```bash
   podman logs proxy-vpn
   ```

### DNS Not Working

**Symptoms**: Can ping IPs but not domains

**Solutions**:
1. Add DNS servers to `.env`:
   ```bash
   DNS_SERVERS=1.1.1.1,8.8.8.8
   ```
2. Check .ovpn for DNS settings
3. Verify firewall allows DNS

### Slow Connection

**Symptoms**: High latency, slow speeds

**Solutions**:
1. Try different server
2. Use UDP instead of TCP:
   ```
   proto udp
   ```
3. Add compression:
   ```
   comp-lzo yes
   ```

### Disconnections

**Symptoms**: VPN drops periodically

**Solutions**:
1. Enable auto-reconnect:
   ```bash
   VPN_AUTO_RECONNECT=true
   ```
2. Add keepalive to .ovpn:
   ```
   keepalive 10 60
   ```
3. Check provider's server status

### Kill Switch

To ensure no traffic escapes VPN:

1. The container includes built-in firewall
2. All non-VPN traffic is blocked
3. Only DNS and VPN traffic allowed

## Advanced Configuration

### Custom .ovpn Settings

Add to your .ovpn file:

```
# Faster connection
fast-io
tun-mtu 1500
mssfix 1450

# Better reliability
persist-key
persist-tun
resolv-retry infinite

# Security
cipher AES-256-GCM
auth SHA256
tls-version-min 1.2
```

### Split Tunneling

To route only specific traffic through VPN:

1. Not supported by default
2. Would require custom routing rules
3. Contact maintainers if needed

### WireGuard Support

Currently, only OpenVPN is supported. WireGuard support may be added in future versions.

## Security Best Practices

1. **Use Strong Encryption**: AES-256-GCM or ChaCha20
2. **Enable Kill Switch**: Built-in by default
3. **Check for Leaks**: Regularly test DNS and WebRTC
4. **Keep Updated**: Regularly update .ovpn files
5. **Rotate Servers**: Change servers periodically

## Verification Checklist

- [ ] VPN container running: `./status`
- [ ] IP is masked: `curl --proxy http://localhost:53128 https://ifconfig.me`
- [ ] DNS not leaking: Use online DNS leak test
- [ ] No WebRTC leaks: Test in browser
- [ ] Kill switch working: Stop VPN, verify no traffic
