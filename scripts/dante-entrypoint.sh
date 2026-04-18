#!/usr/bin/env bash
#######################################
# Dante SOCKS5 Dynamic Entrypoint
# Generates config with correct external
# address based on container network mode
#######################################
set -euo pipefail

# Determine the primary IP address for external connections.
# In bridge mode, this is the container's assigned IP.
# In network_mode: host or service:<name>, this is the shared namespace IP.
detect_external_ip() {
    local ip=""

    # Try hostname -i first (works in bridge mode)
    ip=$(hostname -i 2>/dev/null | awk '{print $1}')

    # If it resolved to loopback or failed, try hostname -I
    if [[ -z "$ip" || "$ip" == "127.0.0.1" ]]; then
        ip=$(hostname -I 2>/dev/null | awk '{
            for (i=1; i<=NF; i++) {
                if ($i !~ /^127\./ && $i !~ /^169\.254\./ && $i ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) {
                    print $i
                    exit
                }
            }
        }')
    fi

    echo "$ip"
}

main() {
    local cfg_template="${CFGFILE:-/etc/dante/sockd.conf}"
    local pidfile="${PIDFILE:-/run/sockd.pid}"
    local workers="${WORKERS:-10}"
    local cfg_out="/tmp/sockd-generated.conf"

    local external_ip
    external_ip=$(detect_external_ip)

    if [[ -n "$external_ip" && -f "$cfg_template" ]]; then
        sed "s|external: .*|external: ${external_ip}|" "$cfg_template" > "$cfg_out"
        cfgfile="$cfg_out"
    else
        cfgfile="$cfg_template"
    fi

    exec sockd -f "$cfgfile" -p "$pidfile" -N "$workers"
}

main "$@"
