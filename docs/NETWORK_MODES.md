# Network Modes Documentation

## Overview

The Proxy Service supports three network modes to handle different VPN and networking scenarios.

## Mode 1: Host VPN Pass-through (`--host-vpn`)

**Use when:** Host machine is already connected to VPN and you want proxy clients to use it.

```
┌─────────────────────────────────────────────────────────────────┐
│                        HOST MACHINE                              │
│                                                                  │
│  ┌─────────────────┐                                             │
│  │   VPN CLIENT    │─────────────────────────┐                   │
│  │   (System)      │                         │                   │
│  │   - NordVPN     │                         │                   │
│  │   - ExpressVPN  │                         │                   │
│  │   - Mullvad     │                         │                   │
│  │   - Any VPN     │                         │                   │
│  └─────────────────┘                         │                   │
│                                              │                   │
│  ┌───────────────────────────────────────────▼───────────────┐  │
│  │              PROXY CONTAINERS                               │  │
│  │              (network_mode: host)                           │  │
│  │                                                             │  │
│  │  ┌─────────────┐  ┌─────────────┐  ┌─────────────────────┐ │  │
│  │  │   SQUID     │  │   DANTE     │  │      ADMIN          │ │  │
│  │  │  Port 53128  │  │  Port 51080  │  │     Port 58080       │ │  │
│  │  │             │  │             │  │                     │ │  │
│  │  │ Shares host │  │ Shares host │  │    (optional)       │ │  │
│  │  │ network     │  │ network     │  │                     │ │  │
│  │  └─────────────┘  └─────────────┘  └─────────────────────┘ │  │
│  │                                                             │  │
│  └─────────────────────────────────────────────────────────────┘  │
│                                              │                   │
└──────────────────────────────────────────────│───────────────────┘
                                               │
                                               ▼
                                    ┌─────────────────┐
                                    │   VPN SERVER    │
                                    │   (Remote)      │
                                    └────────┬────────┘
                                             │
                                             ▼
                                    ┌─────────────────┐
                                    │    INTERNET     │
                                    └─────────────────┘
```

### Features
- Uses host's existing VPN connection
- No additional VPN configuration needed
- All proxy traffic routes through host VPN
- Containers share host's network namespace

### Requirements
- Host must be connected to VPN before starting proxy
- VPN must route all traffic (not split tunnel)

### Start Command
```bash
./start --host-vpn
```

### Verification
```bash
# Check host IP
curl https://ifconfig.me

# Check proxy IP (should match)
curl --proxy http://localhost:53128 https://ifconfig.me
```

---

## Mode 2: Containerized VPN (`USE_VPN=true`)

**Use when:** You want VPN isolated in a container, or host doesn't have VPN.

```
┌─────────────────────────────────────────────────────────────────┐
│                        HOST MACHINE                              │
│                                                                  │
│  ┌───────────────────────────────────────────────────────────┐  │
│  │                    DOCKER/PODMAN                           │  │
│  │                                                            │  │
│  │  ┌─────────────────┐                                       │  │
│  │  │   PROXY-VPN     │──────────────────────────────┐        │  │
│  │  │   CONTAINER     │                              │        │  │
│  │  │                 │                              │        │  │
│  │  │  ┌───────────┐  │                              │        │  │
│  │  │  │  OpenVPN  │  │                              │        │  │
│  │  │  │  Client   │  │                              │        │  │
│  │  │  └───────────┘  │                              │        │  │
│  │  │                 │                              │        │  │
│  │  │  Profile: vpn   │                              │        │  │
│  │  └────────┬────────┘                              │        │  │
│  │           │                                       │        │  │
│  │           │ network_mode: service:proxy-vpn       │        │  │
│  │           ▼                                       │        │  │
│  │  ┌─────────────────┐  ┌─────────────────┐        │        │  │
│  │  │   SQUID         │  │   DANTE         │        │        │  │
│  │  │   Port 53128     │  │   Port 51080     │        │        │  │
│  │  │                 │  │                 │        │        │  │
│  │  │ Routes through  │  │ Routes through  │        │        │  │
│  │  │ VPN container   │  │ VPN container   │        │        │  │
│  │  └─────────────────┘  └─────────────────┘        │        │  │
│  │                                                   │        │  │
│  └───────────────────────────────────────────────────│────────┘  │
│                                                      │           │
└──────────────────────────────────────────────────────│───────────┘
                                                       │
                                                       ▼
                                            ┌─────────────────┐
                                            │   VPN SERVER    │
                                            └────────┬────────┘
                                                     │
                                                     ▼
                                            ┌─────────────────┐
                                            │    INTERNET     │
                                            └─────────────────┘
```

### Features
- VPN completely isolated in container
- Independent of host VPN status
- Auto-reconnect on disconnect
- Health monitoring

### Requirements
- `.ovpn` configuration file
- VPN credentials (username/password)
- Set `USE_VPN=true` in `.env`

### Configuration
```bash
# .env file
USE_VPN=true
VPN_USERNAME=your_username
VPN_PASSWORD=your_password
VPN_OVPN_PATH=/path/to/config.ovpn
```

### Start Command
```bash
./start
```

### Verification
```bash
# Check VPN container status
./status

# Check proxy IP (should be VPN IP)
curl --proxy http://localhost:53128 https://ifconfig.me
```

---

## Mode 3: No VPN (`--no-vpn` or `USE_VPN=false`)

**Use when:** You only need caching, no VPN required.

```
┌─────────────────────────────────────────────────────────────────┐
│                        HOST MACHINE                              │
│                                                                  │
│  ┌───────────────────────────────────────────────────────────┐  │
│  │                    DOCKER/PODMAN                           │  │
│  │                                                            │  │
│  │  ┌─────────────────┐  ┌─────────────────┐                 │  │
│  │  │   SQUID         │  │   DANTE         │                 │  │
│  │  │   Port 53128     │  │   Port 51080     │                 │  │
│  │  │                 │  │                 │                 │  │
│  │  │  Bridge         │  │  Bridge         │                 │  │
│  │  │  Network        │  │  Network        │                 │  │
│  │  │  (Isolated)     │  │  (Isolated)     │                 │  │
│  │  └────────┬────────┘  └────────┬────────┘                 │  │
│  │           │                    │                          │  │
│  │           └────────┬───────────┘                          │  │
│  │                    │                                      │  │
│  │           ┌────────▼────────┐                             │  │
│  │           │  Bridge Network │                             │  │
│  │           │  (proxy-net)    │                             │  │
│  │           └────────┬────────┘                             │  │
│  │                    │                                      │  │
│  └────────────────────│──────────────────────────────────────┘  │
│                       │                                          │
└───────────────────────│──────────────────────────────────────────┘
                        │
                        ▼
               ┌─────────────────┐
               │    INTERNET     │
               │   (Direct)      │
               └─────────────────┘
```

### Features
- Direct internet connection
- Bridge network isolation
- Caching still works
- No VPN overhead

### Start Command
```bash
./start --no-vpn
```

---

## Comparison Table

| Feature | Host VPN (`--host-vpn`) | Containerized VPN | No VPN (`--no-vpn`) |
|---------|------------------------|-------------------|---------------------|
| **VPN Source** | Host system | Container | None |
| **Network Mode** | `host` | `service:vpn` | `bridge` |
| **Port Binding** | Automatic | Automatic | Manual mapping |
| **Isolation** | None (shares host) | Full | Partial |
| **VPN Config** | Not needed | Required | N/A |
| **Performance** | Best | Good | Best |
| **Use Case** | Host has VPN | Dedicated proxy | Caching only |

## Decision Flow

```
                    ┌─────────────────────┐
                    │  Do you need VPN?   │
                    └──────────┬──────────┘
                               │
              ┌────────────────┼────────────────┐
              │ YES            │                │ NO
              ▼                │                ▼
     ┌────────────────┐       │       ┌────────────────┐
     │ Is host already│       │       │ Use NO VPN     │
     │ on VPN?        │       │       │ mode           │
     └───────┬────────┘       │       └────────────────┘
             │                │
     ┌───────┼───────┐        │
     │ YES   │   NO  │        │
     ▼       │       ▼        │
┌─────────┐  │  ┌─────────┐   │
│ HOST-VPN│  │  │CONTAINER│   │
│ mode    │  │  │VPN mode │   │
└─────────┘  │  └─────────┘   │
             │                │
```

## Common Scenarios

### Scenario 1: Personal Laptop with VPN
```bash
# Laptop has NordVPN running
./start --host-vpn

# All devices on network can use proxy with VPN
```

### Scenario 2: Dedicated Server
```bash
# Server with VPN credentials
USE_VPN=true
VPN_USERNAME=user
VPN_PASSWORD=pass
VPN_OVPN_PATH=/etc/openvpn/config.ovpn

./start  # Containerized VPN
```

### Scenario 3: Local Caching Only
```bash
# No VPN needed, just caching
./start --no-vpn
```

## Troubleshooting

### Host VPN mode not working

1. **Check host VPN is active**
   ```bash
   curl https://ifconfig.me  # Should show VPN IP
   ```

2. **Check container network**
   ```bash
   podman exec proxy-squid curl https://ifconfig.me
   ```

3. **Verify network mode**
   ```bash
   podman inspect proxy-squid | grep NetworkMode
   # Should show "host"
   ```

### Port conflicts in host mode

Host mode means containers bind directly to host ports. If ports are in use:

```bash
# Check what's using port
ss -tuln | grep 53128

# Change port in .env
HTTP_PROXY_PORT=3129
```

### DNS issues

Host mode shares host's DNS. If issues:

```bash
# Check host DNS
cat /etc/resolv.conf

# Test from container
podman exec proxy-squid nslookup google.com
```
