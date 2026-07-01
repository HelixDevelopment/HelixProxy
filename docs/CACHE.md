# Cache Documentation

## Overview

The Proxy Service implements a comprehensive caching system to reduce bandwidth usage and improve response times.

## Cache Types

### 1. Squid HTTP Cache

The primary caching mechanism for HTTP/HTTPS content.

**Configuration**:
```bash
CACHE_DIR=/path/to/cache/squid
CACHE_MAX_SIZE_GB=50
CACHE_MAX_OBJECT_SIZE_MB=100
CACHE_MIN_OBJECT_SIZE_KB=1
CACHE_MEMORY_SIZE_MB=512
```

**Storage Format**: AUFS (Asynchronous Unlinkable File System)
- Level 1: 16 directories
- Level 2: 256 subdirectories per level 1

### 2. Streaming Cache

Specialized cache for video/audio streaming content.

**Configuration**:
```bash
STREAMING_CACHE_ENABLED=true
STREAMING_CACHE_MAX_SIZE_GB=20
STREAMING_DOMAINS=youtube.com,googlevideo.com
STREAMING_CHUNK_SIZE_KB=256
```

**Features**:
- Chunk-based caching for partial content
- Range request support
- Separate storage from HTTP cache

## Cache Storage

### Directory Structure

```
CACHE_DIR/
├── squid/
│   ├── 00/
│   │   ├── 00/
│   │   │   ├── 00000001  # Cached object
│   │   │   ├── 00000002
│   │   │   └── ...
│   │   ├── 01/
│   │   └── ... (256 dirs)
│   ├── 01/
│   └── ... (16 dirs)
│
└── streaming/
    ├── video/
    │   ├── youtube_abc123_chunk1
    │   └── ...
    ├── audio/
    └── manifest/
```

### Object Naming

Squid stores objects using hexadecimal naming:
- 8-character filename
- Based on hash of URL and headers
- Spread across directory levels

## Cache Policies

### Refresh Patterns

```
Pattern              Min  Percent  Max     Options
─────────────────────────────────────────────────────
^ftp:               1440    20%    10080   -
^gopher:            1440    0%     1440    -
cgi-bin             0       0%     0       -
default (.)         0       20%    4320    -
```

**Explanation**:
- **Min**: Minutes before checking freshness
- **Percent**: Percentage of age for stale check
- **Max**: Maximum age without revalidation

### Cacheability Rules

**Cacheable by default**:
- GET responses
- 200, 203, 300, 301, 302, 307, 410, 404 responses
- Responses with `Cache-Control: public`

**Not cacheable**:
- POST, PUT, DELETE requests
- Responses with `Cache-Control: no-store`
- Responses with `Authorization` header (unless public)
- Responses with `Set-Cookie` header

## Cache Management

### Automatic Invalidation

Run by `cache-invalidator` container:

```bash
# Interval
CACHE_INVALIDATE_INTERVAL=24  # hours

# Max age
CACHE_MAX_AGE_DAYS=30

# Max size
CACHE_MAX_SIZE_GB=50
```

**Process**:
1. Remove files older than `CACHE_MAX_AGE_DAYS`
2. Remove empty directories
3. Trim to `CACHE_MAX_SIZE_GB` if over limit

### Manual Commands

```bash
# View statistics
./cachectl stats

# Clear all cache
./cachectl clear

# Run invalidation
./cachectl invalidate

# Trim to size
./cachectl trim 30
```

### Invalidation Triggers

| Trigger | Action |
|---------|--------|
| Age exceeded | Delete old files |
| Size exceeded | Delete oldest files |
| VPN reconnect | Optionally clear cache |
| Manual command | User-initiated cleanup |

## Cache Hit/Miss Flow

### Cache Hit

```
Request → Squid → Cache Lookup → [HIT] → Response
                       │
                       └── Return cached content immediately
```

### Cache Miss

```
Request → Squid → Cache Lookup → [MISS] → Origin → Response
                       │
                       └── Forward request, store response
```

### Stale Content

```
Request → Squid → Cache Lookup → [STALE] → Revalidate → Response
                       │              │
                       │              └── Check if modified
                       │
                       └── If 304: Return cached
                           If 200: Update and return
```

## Performance Tuning

### Memory Cache

In-memory cache for hot objects:

```bash
CACHE_MEMORY_SIZE_MB=512
```

**Recommendations**:
- 10-20% of total cache size
- Increase for high-traffic scenarios
- Monitor hit ratio to optimize

### Object Size Limits

```bash
# Maximum object size to cache
CACHE_MAX_OBJECT_SIZE_MB=100

# Minimum object size to cache
CACHE_MIN_OBJECT_SIZE_KB=1
```

**Recommendations**:
- Set max to prevent caching large files
- Set min to avoid caching tiny responses
- Adjust based on available disk space

### Disk I/O

For high-traffic scenarios:
- Use SSD for cache directory
- Consider RAID for redundancy
- Monitor disk I/O metrics

## Monitoring

### Cache Statistics

```bash
./cachectl stats
```

Output includes:
- Total size
- File count
- Usage percentage
- Per-cache breakdown

### Squid Cache Manager

Access Squid's built-in cache manager:

```bash
# Via cachemgr.cgi or command line
squidclient mgr:info
squidclient mgr:mem
squidclient mgr:storedir
```

### Key Metrics

| Metric | Description | Target |
|--------|-------------|--------|
| Hit Ratio | % of requests served from cache | > 30% |
| Byte Hit Ratio | % of bytes served from cache | > 20% |
| Request Rate | Requests per second | Varies |
| Response Time | Average response time | < 100ms |

## Streaming Cache Details

### Supported Domains

Configure domains for streaming cache:

```bash
STREAMING_DOMAINS=youtube.com,googlevideo.com,ytimg.com,vimeo.com
```

### Chunk Management

Streaming content is cached in chunks:
- Default chunk size: 256KB
- Range requests handled separately
- Partial content supported

### Video Streaming

For YouTube and similar services:
1. Manifest files cached separately
2. Video segments cached by range
3. Adaptive streaming supported

## Troubleshooting

### Cache Not Growing

1. Check disk space
2. Verify permissions
3. Check Squid logs

### High Miss Ratio

1. Review cacheability rules
2. Check refresh patterns
3. Increase cache size

### Corrupted Cache

```bash
# Stop service
./stop

# Clear cache
./cachectl clear -f

# Rebuild cache structure
./init

# Restart
./start
```

### Cache Directory Full

```bash
# Check size
./cachectl stats

# Trim to size
./cachectl trim 30

# Or increase limit in .env
CACHE_MAX_SIZE_GB=100
```
