# Proxy Service Architecture

## Overview

The Proxy Service is a containerized network proxy solution providing HTTP/HTTPS and SOCKS5 proxy capabilities with optional VPN routing and intelligent caching.

## System Components

```
┌─────────────────────────────────────────────────────────────────────────┐
│                              PROXY SERVICE                               │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│  ┌───────────────────────────────────────────────────────────────────┐  │
│  │                        CONTAINER RUNTIME                          │  │
│  │                    (Docker / Podman)                              │  │
│  └───────────────────────────────────────────────────────────────────┘  │
│                                                                          │
│  ┌─────────────────┐  ┌─────────────────┐  ┌─────────────────────────┐  │
│  │   PROXY-VPN     │  │  PROXY-SQUID    │  │     PROXY-DANTE         │  │
│  │                 │  │                 │  │                         │  │
│  │ ┌─────────────┐ │  │ ┌─────────────┐ │  │ ┌─────────────────────┐ │  │
│  │ │  OpenVPN    │ │  │ │   Squid     │ │  │ │      Dante          │ │  │
│  │ │  Client     │ │  │ │   Proxy     │ │  │ │      SOCKS          │ │  │
│  │ │             │ │  │ │             │ │  │ │      Proxy          │ │  │
│  │ └─────────────┘ │  │ └─────────────┘ │  │ └─────────────────────┘ │  │
│  │                 │  │                 │  │                         │  │
│  │ Profile: vpn    │  │ Profile: *      │  │ Profile: *              │  │
│  │ Port: -         │  │ Port: 53128      │  │ Port: 51080              │  │
│  └────────┬────────┘  └────────┬────────┘  └────────────┬────────────┘  │
│           │                    │                        │               │
│           │    ┌───────────────┴────────────────────────┘               │
│           │    │                                                        │
│           ▼    ▼                                                        │
│  ┌───────────────────────────────────────────────────────────────────┐  │
│  │                         SHARED VOLUMES                            │  │
│  │                                                                   │  │
│  │  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐               │  │
│  │  │   Cache     │  │    Logs     │  │   Config    │               │  │
│  │  │   Storage   │  │   Storage   │  │   Files     │               │  │
│  │  └─────────────┘  └─────────────┘  └─────────────┘               │  │
│  └───────────────────────────────────────────────────────────────────┘  │
│                                                                          │
│  ┌─────────────────┐  ┌─────────────────┐  ┌─────────────────────────┐  │
│  │  PROXY-ADMIN    │  │ CACHE-INVALID.  │  │     VPN-MONITOR         │  │
│  │  (Caddy)        │  │  (Scheduler)    │  │     (Watcher)           │  │
│  │  Port: 58080     │  │  Periodic       │  │     Health Checks       │  │
│  └─────────────────┘  └─────────────────┘  └─────────────────────────┘  │
│                                                                          │
└─────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
                         ┌─────────────────┐
                         │   INTERNET /    │
                         │   VPN SERVER    │
                         └─────────────────┘
```

## Data Flow

### HTTP Request Flow (Without VPN)

```
Client                    Squid                    Origin Server
  │                         │                           │
  │  HTTP Request           │                           │
  │ ───────────────────────>│                           │
  │                         │                           │
  │                    Cache Check                      │
  │                         │                           │
  │                    [Cache Miss]                     │
  │                         │                           │
  │                         │  HTTP Request             │
  │                         │──────────────────────────>│
  │                         │                           │
  │                         │  HTTP Response            │
  │                         │<──────────────────────────│
  │                         │                           │
  │                    Store in Cache                   │
  │                         │                           │
  │  HTTP Response          │                           │
  │ <───────────────────────│                           │
  │                         │                           │
```

### HTTP Request Flow (With VPN)

```
Client    Squid    VPN Container    VPN Server    Origin
  │         │           │               │           │
  │ Request │           │               │           │
  │ ───────>│           │               │           │
  │         │           │               │           │
  │         │ Encrypted │               │           │
  │         │ Tunnel    │               │           │
  │         │ ─────────>│               │           │
  │         │           │               │           │
  │         │           │ Via VPN Tunnel│           │
  │         │           │ ─────────────>│           │
  │         │           │               │           │
  │         │           │               │ Request   │
  │         │           │               │ ─────────>│
  │         │           │               │           │
  │         │           │               │ Response  │
  │         │           │               │ <─────────│
  │         │           │               │           │
  │ Response│ Response  │ Response      │           │
  │ <───────│ <─────────│ <─────────────│           │
  │         │           │               │           │
```

## Container Profiles

### Profile: `vpn`

Activated when `USE_VPN=true`

Services:
- `proxy-vpn`: OpenVPN client container
- `proxy-squid`: Squid (network: service:proxy-vpn)
- `proxy-dante`: Dante (network: service:proxy-vpn)
- `proxy-admin`: Admin interface
- `cache-invalidator`: Cache cleanup
- `vpn-monitor`: VPN health monitoring

### Profile: `no-vpn`

Activated when `USE_VPN=false` (default)

Services:
- `proxy-squid`: Squid (direct network)
- `proxy-dante`: Dante (direct network)
- `proxy-admin`: Admin interface
- `cache-invalidator`: Cache cleanup

## Network Architecture

### Bridge Network: `proxy-net`

```
Network: proxy-net (172.28.0.0/16)
├── proxy-vpn       (172.28.0.2)  [VPN mode only]
├── proxy-squid     (172.28.0.3)
├── proxy-dante     (172.28.0.4)
├── proxy-admin     (172.28.0.5)
├── cache-invalidator (172.28.0.6)
└── vpn-monitor     (172.28.0.7)  [VPN mode only]
```

### Port Mapping

| Host Port | Container Port | Service | Protocol |
|-----------|---------------|---------|----------|
| 53128 | 53128 | proxy-squid | HTTP/HTTPS |
| 51080 | 51080 | proxy-dante | SOCKS5 |
| 58080 | 80 | proxy-admin | HTTP |

## Cache Architecture

### Cache Directory Structure

```
CACHE_DIR/
├── squid/                    # Squid cache
│   ├── 00/                   # Level 1 directories
│   │   ├── 00/               # Level 2 directories
│   │   │   └── cached_files  # Actual cached content
│   │   └── ...
│   └── ...
│
└── streaming/                # Streaming cache
    ├── video/                # Video chunks
    ├── audio/                # Audio chunks
    └── manifest/             # Manifest files
```

### Cache Decision Tree

```
                    ┌─────────────┐
                    │   Request   │
                    └──────┬──────┘
                           │
                    ┌──────▼──────┐
                    │ Cacheable?  │
                    └──────┬──────┘
                           │
              ┌────────────┼────────────┐
              │ Yes        │            │ No
              ▼            │            ▼
       ┌───────────┐       │     ┌───────────┐
       │ In Cache? │       │     │   Fetch   │
       └─────┬─────┘       │     │  Directly │
             │             │     └───────────┘
      ┌──────┼──────┐      │
      │ Yes  │   No │      │
      ▼      │      ▼      │
┌──────────┐ │ ┌──────────┐│
│  Fresh?  │ │ │  Fetch   ││
└────┬─────┘ │ │ & Cache  ││
     │       │ └──────────┘│
  ┌──┼──┐    │             │
  │Y │ N│    │             │
  ▼  ▼  ▼    │             │
Serve Reval. │             │
      │      │             │
      └──────┴─────────────┘
```

## Security Model

### Network Isolation

1. **Container Network**: Isolated bridge network for inter-container communication
2. **VPN Container**: Dedicated network namespace for VPN traffic
3. **Service Binding**: Configurable bind address for external access

### Access Control

```
┌─────────────────────────────────────────┐
│           ACCESS CONTROL                │
├─────────────────────────────────────────┤
│                                         │
│  ┌─────────────────────────────────┐   │
│  │     ALLOWED_NETWORKS            │   │
│  │  (CIDR notation)                │   │
│  │  192.168.0.0/16                 │   │
│  │  10.0.0.0/8                     │   │
│  │  172.16.0.0/12                  │   │
│  └─────────────────────────────────┘   │
│                                         │
│  ┌─────────────────────────────────┐   │
│  │     PROXY_AUTH                  │   │
│  │  (Optional authentication)      │   │
│  │  Username + Password            │   │
│  └─────────────────────────────────┘   │
│                                         │
│  ┌─────────────────────────────────┐   │
│  │     TLS/SSL                     │   │
│  │  (Optional HTTPS inspection)    │   │
│  └─────────────────────────────────┘   │
│                                         │
└─────────────────────────────────────────┘
```

## High Availability

### Health Checks

| Service | Check Method | Interval | Timeout |
|---------|-------------|----------|---------|
| proxy-vpn | ping 8.8.8.8 | 30s | 10s |
| proxy-squid | squid -k check | 30s | 10s |
| proxy-dante | pgrep sockd | 30s | 10s |
| proxy-admin | caddy validate | 60s | 10s |

### Auto-Recovery

1. **Container Restart**: `restart: unless-stopped` policy
2. **VPN Reconnection**: Automatic on disconnect detection
3. **Service Dependencies**: Proper startup ordering with `depends_on`

## Performance Considerations

### Resource Allocation

| Service | CPU | Memory | Disk I/O |
|---------|-----|--------|----------|
| proxy-squid | Medium | High | High |
| proxy-dante | Low | Low | Low |
| proxy-vpn | Low | Low | Medium |
| proxy-admin | Low | Low | Low |

### Optimization Tips

1. **Cache Memory**: Increase `CACHE_MEMORY_SIZE_MB` for hot cache
2. **Connection Limits**: Adjust `MAX_CONNECTIONS` based on load
3. **Disk Speed**: Use SSD for cache directory
4. **Network**: Use dedicated network interface for high traffic
