# Changelog

All notable changes to the Proxy Service project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Planned
- HTTPS inspection (MITM) for HTTPS caching
- WireGuard VPN support
- Web-based configuration UI
- Metrics and monitoring (Prometheus)
- Load balancing support
- Multiple VPN server support
- Custom DNS blocklists
- Ad blocking integration

## [1.1.0] - 2026-04-18

### Added
- Comprehensive device setup documentation
  - `docs/CLIENT_SETUP.md` - Complete guide for desktops, browsers, mobiles, gaming consoles, smart TVs, NAS, IoT, and per-app proxy
  - `docs/ANDROID_TV.md` - Detailed Android TV / Google TV setup with Wi-Fi proxy, per-app SOCKS5, ADB global proxy, and troubleshooting
  - `docs/BROWSERS.md` - Browser-specific proxy configuration (Firefox, Chrome, Edge, Brave, Safari, Opera, Vivaldi, Tor)
  - `docs/MOBILE_DEVICES.md` - iOS and Android setup with per-app proxy and third-party proxy apps
- Dynamic Dante entrypoint script (`scripts/dante-entrypoint.sh`) for automatic external IP detection across all network modes

### Fixed
- Dante SOCKS5 proxy failing in rootless Podman bridge networking
  - Changed `external: eth0` to dynamic hostname/IP resolution
  - Switched `proxy-dante-standalone` from host networking to bridge with published ports
  - Updated deprecated Dante config keywords (`method` → `socksmethod`, `pass` → `socks pass`)
- Squid HTTP proxy returning 403/invalid responses for HTTPS CONNECT requests
  - Changed from reverse proxy (`accel vhost`) to standard forward proxy mode
  - Restores Android TV "connected, no internet" fix
- Dante healthcheck using `pgrep` which is not available in the `vimagick/dante` image
  - Changed to `pidof` which is available
- Admin panel HTML showing incorrect ports (`553128` instead of `53128`, `551080` instead of `51080`)
- All documentation updated to use correct 5xxxx port range consistently

### Changed
- `proxy-dante-standalone` now uses bridge networking with port publishing instead of `network_mode: host`
- All three Dante services (`proxy-dante`, `proxy-dante-host`, `proxy-dante-standalone`) now mount the dynamic entrypoint
- Port numbers standardized across all configs and documentation:
  - HTTP Proxy: 53128
  - SOCKS5 Proxy: 51080
  - Admin Panel: 58080

## [1.0.0] - 2024-03-26

### Added
- Initial release of Proxy Service
- HTTP/HTTPS caching proxy using Squid
- SOCKS5 proxy using Dante
- VPN routing support with OpenVPN
- Automatic VPN reconnection on disconnect
- Comprehensive caching with invalidation mechanisms
- Streaming cache for video/audio content
- Admin web interface for monitoring
- Cache management CLI tool
- Status monitoring with JSON output
- Docker/Podman dual runtime support
- Profile-based service configuration
- Extensive documentation
  - Architecture documentation
  - Cache system documentation
  - VPN configuration guide
  - Troubleshooting guide
  - User manual

### Core Scripts
- `init` - Environment initialization
- `start` - Start all services
- `stop` - Stop all services
- `restart` - Restart services
- `status` - Check service status
- `cache` - Cache management tool

### Configuration
- Environment-based configuration via `.env`
- Configurable ports for all services
- Network access control via CIDR
- Optional proxy authentication
- VPN health monitoring
- Automatic cache invalidation

### Services
- `proxy-squid` - HTTP/HTTPS caching proxy
- `proxy-dante` - SOCKS5 proxy
- `proxy-vpn` - OpenVPN client (optional)
- `proxy-admin` - Web admin interface
- `cache-invalidator` - Automatic cache cleanup
- `vpn-monitor` - VPN health monitoring

### Features
- Network-wide proxy access
- VPN traffic routing for all clients
- Intelligent content caching
- Bandwidth optimization
- Privacy protection via VPN
- Auto-recovery on failures
- Health checks for all services

### Documentation
- README.md - Project overview
- USER_GUIDE.md - Comprehensive user manual
- docs/ARCHITECTURE.md - System architecture
- docs/CACHE.md - Cache documentation
- docs/VPN.md - VPN configuration guide
- docs/TROUBLESHOOTING.md - Common issues
- CONTRIBUTING.md - Contribution guidelines

### Tests
- Comprehensive test suite
- Environment validation
- Configuration validation
- Container runtime detection
- Port availability checks
- Cache functionality tests
- VPN configuration tests
