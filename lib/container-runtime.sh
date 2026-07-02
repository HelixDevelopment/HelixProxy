#!/usr/bin/env bash
#######################################
# Container Runtime Detection Library
# Shared functions for Docker/Podman detection
#######################################

set -euo pipefail

# Only set SCRIPT_DIR if not already set
if [[ -z "${SCRIPT_DIR:-}" ]]; then
    readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi

# Only set PROJECT_ROOT if not already set
# When SCRIPT_DIR is pre-set by a calling script (start/init), it IS the project root.
# When auto-set by this file, SCRIPT_DIR is the lib/ directory and PROJECT_ROOT is one level up.
if [[ -z "${PROJECT_ROOT:-}" ]]; then
    if [[ "$(basename "$SCRIPT_DIR")" == "lib" ]]; then
        readonly PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
    else
        readonly PROJECT_ROOT="$SCRIPT_DIR"
    fi
fi

#######################################
# Detect available container runtime
# Prefers Podman over Docker for rootless operation
# Globals:
#   None
# Arguments:
#   None
# Outputs:
#   Writes runtime name to stdout (podman, docker, or none)
# Returns:
#   0 always
#######################################
detect_container_runtime() {
    if command -v podman &> /dev/null; then
        echo "podman"
    elif command -v docker &> /dev/null; then
        echo "docker"
    else
        echo "none"
    fi
}

#######################################
# Get compose command based on runtime
# Globals:
#   None
# Arguments:
#   $1 - Container runtime (podman or docker)
# Outputs:
#   Writes compose command to stdout
# Returns:
#   0 always
#######################################
get_compose_cmd() {
    local runtime="$1"
    
    case "$runtime" in
        podman)
            if command -v podman-compose &> /dev/null; then
                echo "podman-compose"
            else
                echo "podman compose"
            fi
            ;;
        docker)
            if command -v docker-compose &> /dev/null; then
                echo "docker-compose"
            else
                echo "docker compose"
            fi
            ;;
        *)
            echo ""
            ;;
    esac
}

#######################################
# Check if compose command is available
# Globals:
#   None
# Arguments:
#   None
# Outputs:
#   None (sets global variables)
# Returns:
#   0 if available, 1 otherwise
#######################################
check_compose_available() {
    local runtime
    runtime=$(detect_container_runtime)
    
    if [[ "$runtime" == "none" ]]; then
        echo "[ERROR] No container runtime found. Install Docker or Podman." >&2
        return 1
    fi
    
    local compose_cmd
    compose_cmd=$(get_compose_cmd "$runtime")
    
    if [[ -z "$compose_cmd" ]]; then
        echo "[ERROR] No compose command found for $runtime" >&2
        return 1
    fi
    
    return 0
}

#######################################
# Initialize runtime environment
# Sets CONTAINER_RUNTIME and COMPOSE_CMD global variables
# Globals:
#   CONTAINER_RUNTIME - set to detected or configured runtime
#   COMPOSE_CMD - set to appropriate compose command
# Arguments:
#   None
# Outputs:
#   Status messages
# Returns:
#   0 on success, 1 on failure
#######################################
init_runtime() {
    local configured_runtime="${CONTAINER_RUNTIME:-auto}"
    
    if [[ "$configured_runtime" == "auto" ]]; then
        CONTAINER_RUNTIME=$(detect_container_runtime)
    else
        CONTAINER_RUNTIME="$configured_runtime"
    fi
    
    if [[ "$CONTAINER_RUNTIME" == "none" ]]; then
        echo "[ERROR] No container runtime available" >&2
        return 1
    fi
    
    COMPOSE_CMD=$(get_compose_cmd "$CONTAINER_RUNTIME")
    
    if [[ -z "$COMPOSE_CMD" ]]; then
        echo "[ERROR] Compose not available for $CONTAINER_RUNTIME" >&2
        return 1
    fi
    
    export CONTAINER_RUNTIME
    export COMPOSE_CMD
    
    return 0
}

#######################################
# Load environment variables from .env files
# Priority: .env > .env.local
# Globals:
#   All variables from .env files
# Arguments:
#   None
# Outputs:
#   Status messages
# Returns:
#   0 always
#######################################
load_environment() {
    local env_files=(
        "$PROJECT_ROOT/.env"
        "$PROJECT_ROOT/.env.local"
    )
    
    for env_file in "${env_files[@]}"; do
        if [[ -f "$env_file" ]]; then
            set -a
            source "$env_file"
            set +a
            echo "[INFO] Loaded environment from: $env_file"
        fi
    done
    
    export CACHE_DIR="${CACHE_DIR:-$PROJECT_ROOT/cache}"
    export LOG_DIR="${LOG_DIR:-$PROJECT_ROOT/logs}"

    # Resolve relative paths to absolute against PROJECT_ROOT
    if [[ "${CACHE_DIR}" != /* ]]; then
        CACHE_DIR="$PROJECT_ROOT/$CACHE_DIR"
    fi
    if [[ "${LOG_DIR}" != /* ]]; then
        LOG_DIR="$PROJECT_ROOT/$LOG_DIR"
    fi
    export HTTP_PROXY_PORT="${HTTP_PROXY_PORT:-34128}"
    export SOCKS_PROXY_PORT="${SOCKS_PROXY_PORT:-34080}"
    export PROXY_ADMIN_PORT="${PROXY_ADMIN_PORT:-34088}"
    export USE_VPN="${USE_VPN:-false}"
    export TZ="${TZ:-UTC}"
    export PUID="${PUID:-1000}"
    export PGID="${PGID:-1000}"
    export LOG_LEVEL="${LOG_LEVEL:-info}"
    export CACHE_MAX_SIZE_GB="${CACHE_MAX_SIZE_GB:-50}"
}

#######################################
# Check if a container is running
# Globals:
#   CONTAINER_RUNTIME
# Arguments:
#   $1 - Container name
# Outputs:
#   None
# Returns:
#   0 if running, 1 otherwise
#######################################
is_container_running() {
    local container_name="$1"
    
    case "$CONTAINER_RUNTIME" in
        podman)
            podman ps --format '{{.Names}}' | grep -q "^${container_name}$"
            ;;
        docker)
            docker ps --format '{{.Names}}' | grep -q "^${container_name}$"
            ;;
        *)
            return 1
            ;;
    esac
}

#######################################
# Get container status
# Globals:
#   CONTAINER_RUNTIME
# Arguments:
#   $1 - Container name
# Outputs:
#   Container status string
# Returns:
#   0 always
#######################################
get_container_status() {
    local container_name="$1"
    
    case "$CONTAINER_RUNTIME" in
        podman)
            podman ps -a --format '{{.Status}}' --filter "name=^${container_name}$" 2>/dev/null || echo "not found"
            ;;
        docker)
            docker ps -a --format '{{.Status}}' --filter "name=^${container_name}$" 2>/dev/null || echo "not found"
            ;;
        *)
            echo "unknown"
            ;;
    esac
}

#######################################
# Log message with timestamp and level
# Globals:
#   LOG_LEVEL
# Arguments:
#   $1 - Log level (debug, info, warn, error)
#   $2 - Message
# Outputs:
#   Formatted log message to stdout
# Returns:
#   0 always
#######################################
log() {
    local level="$1"
    local message="$2"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    local level_priority=0
    case "$level" in
        debug) level_priority=0 ;;
        info)  level_priority=1 ;;
        warn)  level_priority=2 ;;
        error) level_priority=3 ;;
    esac
    
    local current_priority=1
    case "${LOG_LEVEL:-info}" in
        debug) current_priority=0 ;;
        info)  current_priority=1 ;;
        warn)  current_priority=2 ;;
        error) current_priority=3 ;;
    esac
    
    if [[ $level_priority -ge $current_priority ]]; then
        echo "[$timestamp] [$level] $message"
    fi
}

#######################################
# Create necessary directories
# Globals:
#   CACHE_DIR, LOG_DIR, PROJECT_ROOT
# Arguments:
#   None
# Outputs:
#   Status messages
# Returns:
#   0 on success
#######################################
create_directories() {
    mkdir -p "$CACHE_DIR"
    mkdir -p "$LOG_DIR"
    mkdir -p "$PROJECT_ROOT/config/squid"
    mkdir -p "$PROJECT_ROOT/config/dante"

    if [[ "$USE_VPN" == "true" ]]; then
        mkdir -p "$PROJECT_ROOT/vpn"
    fi

    # Rootless-Podman bind-mount writability (BUGFIX #38 — proxy crash-loop).
    # Under rootless Podman the host uid (you) maps to the container's root, but
    # squid drops privileges to its non-root `proxy` user, which is remapped to a
    # high subuid that owns NONE of these host-created dirs. Without world-write
    # the squid container FATALs on "Cannot open '/var/log/squid/access.log' for
    # writing" and crash-loops, so the proxy never serves a single request. This
    # mirrors the existing chmod 777 of the cache bind-mount in `init_cache`.
    # Regression guard: tests/regression/log_dir_writable_test.sh.
    chmod 777 "$LOG_DIR"

    log "info" "Directories created"
}

#######################################
# Check VPN connection status
# Globals:
#   None
# Arguments:
#   None
# Outputs:
#   VPN status (connected/disconnected/unknown)
# Returns:
#   0 if connected, 1 otherwise
#######################################
check_vpn_status() {
    if ! is_container_running "proxy-vpn"; then
        echo "disconnected"
        return 1
    fi
    
    case "$CONTAINER_RUNTIME" in
        podman)
            if podman exec proxy-vpn ping -c 1 -W 2 8.8.8.8 &>/dev/null; then
                echo "connected"
                return 0
            fi
            ;;
        docker)
            if docker exec proxy-vpn ping -c 1 -W 2 8.8.8.8 &>/dev/null; then
                echo "connected"
                return 0
            fi
            ;;
    esac
    
    echo "disconnected"
    return 1
}

#######################################
# Get current cache statistics
# Globals:
#   CACHE_DIR
# Arguments:
#   None
# Outputs:
#   Cache stats (size, files, etc.)
# Returns:
#   0 on success
#######################################
get_cache_stats() {
    if [[ ! -d "$CACHE_DIR" ]]; then
        echo "Cache directory not found: $CACHE_DIR"
        return 1
    fi
    
    local total_size
    total_size=$(du -sh "$CACHE_DIR" 2>/dev/null | cut -f1)
    
    local file_count
    file_count=$(find "$CACHE_DIR" -type f 2>/dev/null | wc -l)
    
    local dir_count
    dir_count=$(find "$CACHE_DIR" -type d 2>/dev/null | wc -l)
    
    echo "Cache Statistics:"
    echo "  Location: $CACHE_DIR"
    echo "  Total Size: $total_size"
    echo "  Files: $file_count"
    echo "  Directories: $dir_count"
}
