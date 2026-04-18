# Troubleshooting Guide

## Common Issues and Solutions

### Service Won't Start

#### Symptoms
- `./start` command fails
- Containers exit immediately
- Error messages in logs

#### Diagnosis

```bash
# Check container runtime
./init --check

# View logs
./logs/proxy.log
podman logs proxy-squid
```

#### Solutions

1. **Port already in use**
   ```bash
   # Find process using port
   ss -tuln | grep 53128
   # Kill process or change port in .env
   ```

2. **Permission denied**
   ```bash
   # Fix permissions
   chmod +x init start stop status cache
   ```

3. **Missing dependencies**
   ```bash
   # Install Docker or Podman
   # Ubuntu/Debian
   sudo apt install docker.io docker-compose
   
   # Fedora
   sudo dnf install podman podman-compose
   ```

4. **Configuration errors**
   ```bash
   # Validate .env
   ./init --check
   ```

---

### VPN Not Connecting

#### Symptoms
- VPN container exits
- IP not masked
- Connection timeouts

#### Diagnosis

```bash
# Check VPN container status
podman ps -a | grep vpn

# View VPN logs
podman logs proxy-vpn

# Check configuration
cat .env | grep VPN
```

#### Solutions

1. **Invalid credentials**
   ```bash
   # Verify in .env
   VPN_USERNAME=correct_username
   VPN_PASSWORD=correct_password
   ```

2. **Missing .ovpn file**
   ```bash
   # Check file exists
   ls -la $VPN_OVPN_PATH
   
   # Update path in .env
   VPN_OVPN_PATH=/correct/path/to/config.ovpn
   ```

3. **Permission issues**
   ```bash
   # Check .ovpn permissions
   chmod 644 $VPN_OVPN_PATH
   ```

4. **Network issues**
   ```bash
   # Test VPN server connectivity
   ping $(grep remote config.ovpn | awk '{print $2}')
   ```

---

### Cache Not Working

#### Symptoms
- No cache growth
- High bandwidth usage
- Slow repeated requests

#### Diagnosis

```bash
# Check cache stats
./cache stats

# Check Squid logs
tail -f logs/squid/cache.log

# Verify cache directory
ls -la $CACHE_DIR/squid
```

#### Solutions

1. **Cache directory not writable**
   ```bash
   # Fix permissions
   chmod -R 755 $CACHE_DIR
   chown -R $PUID:$PGID $CACHE_DIR
   ```

2. **Cache full**
   ```bash
   # Clear cache
   ./cache clear
   
   # Or increase limit
   CACHE_MAX_SIZE_GB=100
   ```

3. **Squid configuration error**
   ```bash
   # Test config
   podman exec proxy-squid squid -k parse
   
   # Rebuild config
   ./init
   ```

4. **Objects not cacheable**
   - Check `Cache-Control` headers
   - Review refresh patterns
   - Enable HTTPS inspection for HTTPS caching

---

### Connection Refused

#### Symptoms
- "Connection refused" errors
- Timeout when connecting
- Proxy not responding

#### Diagnosis

```bash
# Check if service running
./status

# Check port binding
ss -tuln | grep -E '53128|51080'

# Test local connection
curl --proxy http://localhost:53128 http://example.com
```

#### Solutions

1. **Service not running**
   ```bash
   ./start
   ```

2. **Wrong port**
   ```bash
   # Check configured port
   cat .env | grep PORT
   ```

3. **Firewall blocking**
   ```bash
   # Allow ports
   sudo ufw allow 53128/tcp
   sudo ufw allow 51080/tcp
   ```

4. **Bind address wrong**
   ```bash
   # Use 0.0.0.0 for all interfaces
   BIND_ADDRESS=0.0.0.0
   ```

---

### DNS Resolution Fails

#### Symptoms
- "DNS resolution failed" errors
- Can ping IPs but not domains
- Host not found errors

#### Diagnosis

```bash
# Test DNS
nslookup google.com

# Check DNS config
cat /etc/resolv.conf

# Test via proxy
curl --proxy http://localhost:53128 http://google.com
```

#### Solutions

1. **Configure DNS servers**
   ```bash
   DNS_SERVERS=8.8.8.8,8.8.4.4
   ```

2. **Enable DNS caching**
   ```bash
   DNS_CACHING_ENABLED=true
   DNS_CACHE_TTL=3600
   ```

3. **VPN DNS issues**
   - Check .ovpn file for DNS settings
   - Add `dhcp-option DNS 8.8.8.8` to .ovpn

---

### High Memory Usage

#### Symptoms
- System running low on memory
- OOM kills
- Slow performance

#### Diagnosis

```bash
# Check container memory
podman stats

# Check cache memory
./cache stats
```

#### Solutions

1. **Reduce cache memory**
   ```bash
   CACHE_MEMORY_SIZE_MB=256
   ```

2. **Limit connections**
   ```bash
   MAX_CONNECTIONS=1024
   ```

3. **Reduce cache size**
   ```bash
   ./cache trim 20
   ```

---

### Slow Performance

#### Symptoms
- Slow page loads
- High latency
- Timeouts

#### Diagnosis

```bash
# Check hit ratio
./cache stats

# Monitor connections
podman exec proxy-squid squidclient mgr:info

# Check network
ping -c 10 8.8.8.8
```

#### Solutions

1. **Increase cache memory**
   ```bash
   CACHE_MEMORY_SIZE_MB=1024
   ```

2. **Optimize refresh patterns**
   - Edit config/squid/squid.conf
   - Add domain-specific patterns

3. **Check VPN latency**
   - Try different VPN server
   - Use closer server location

4. **Network issues**
   - Check bandwidth
   - Look for network congestion

---

### VPN Disconnects Frequently

#### Symptoms
- VPN connection drops
- IP changes unexpectedly
- Connection interruptions

#### Diagnosis

```bash
# Check VPN status
./status

# View VPN logs
podman logs proxy-vpn

# Monitor continuously
./status --watch
```

#### Solutions

1. **Enable auto-reconnect**
   ```bash
   VPN_AUTO_RECONNECT=true
   ```

2. **Add keepalive**
   ```bash
   # Add to .ovpn file
   keepalive 10 60
   ```

3. **Switch servers**
   - Try different VPN server
   - Use more reliable provider

4. **Check network stability**
   - Test without VPN
   - Check ISP issues

---

### Permission Denied Errors

#### Symptoms
- "Permission denied" in logs
- Cannot write to cache
- Cannot read config files

#### Diagnosis

```bash
# Check permissions
ls -la config/
ls -la cache/
ls -la logs/

# Check user/group
id
```

#### Solutions

1. **Fix directory permissions**
   ```bash
   chmod -R 755 config cache logs
   chown -R $PUID:$PGID config cache logs
   ```

2. **Fix file permissions**
   ```bash
   chmod 644 config/squid/squid.conf
   chmod 600 vpn-auth.txt
   ```

3. **Correct PUID/PGID**
   ```bash
   # Get your IDs
   id
   
   # Set in .env
   PUID=1000
   PGID=1000
   ```

---

### Container Crashes

#### Symptoms
- Containers exit unexpectedly
- Restart loops
- Service unavailable

#### Diagnosis

```bash
# Check container status
podman ps -a

# View crash logs
podman logs --tail 100 proxy-squid
podman logs --tail 100 proxy-vpn
```

#### Solutions

1. **Resource limits**
   ```bash
   # Check system resources
   free -h
   df -h
   ```

2. **Configuration error**
   ```bash
   # Rebuild config
   ./init --force
   ```

3. **Image issues**
   ```bash
   # Pull fresh images
   ./start --pull
   ```

4. **Kernel issues** (Podman)
   ```bash
   # Check kernel version
   uname -r
   # Need 4.18+ for rootless Podman
   ```

---

## Diagnostic Commands

### Quick Diagnostics

```bash
# Full system check
./status -v

# Configuration check
./init --check

# Cache health
./cache stats

# Network test
curl --proxy http://localhost:53128 https://ifconfig.me
```

### Log Collection

```bash
# Collect all logs
mkdir -p /tmp/proxy-logs
cp -r logs/* /tmp/proxy-logs/
podman logs proxy-squid > /tmp/proxy-logs/squid.log 2>&1
podman logs proxy-dante > /tmp/proxy-logs/dante.log 2>&1
podman logs proxy-vpn > /tmp/proxy-logs/vpn.log 2>&1

# Create archive
tar -czvf proxy-logs.tar.gz -C /tmp proxy-logs
```

### Network Diagnostics

```bash
# Check ports
ss -tuln | grep -E '53128|51080|58080'

# Test connectivity
ping -c 5 8.8.8.8
traceroute 8.8.8.8

# DNS test
dig google.com
nslookup google.com

# Proxy test
curl -v --proxy http://localhost:53128 http://example.com
```

## Getting Help

1. **Check documentation**: See `docs/` directory
2. **Search issues**: GitHub Issues
3. **Collect diagnostics**: Use log collection above
4. **Open issue**: Include diagnostics and error messages
