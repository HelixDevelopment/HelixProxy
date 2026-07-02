#!/bin/sh
# =============================================================================
# Helix Proxy — Squid dynamic-routing startup wait (D5 fix, §11.4.150)
# =============================================================================
# Purpose:   Avoid the D5 negative-DNS-cache dead-peer bug by making squid's
#            startup cache_peer name resolution succeed on the first try.
# Usage:     Set as the squid image ENTRYPOINT; the ubuntu/squid CMD (e.g.
#            `-f /etc/squid/squid.conf -NYC`) flows through as "$@".
# Inputs:    HELIX_GLUETUN_PEERS   (space-separated peer alias names to wait for;
#                                    default the three MVP profiles)
#            HELIX_PEER_WAIT_SECS  (bounded wait budget, default 60)
#            HELIX_SQUID_BASE_ENTRYPOINT (default /usr/local/bin/entrypoint.sh)
# Outputs:   Execs the base squid entrypoint with the original CMD (never returns).
# Side-effects: none (read-only getent probes; a bounded sleep loop).
# Dependencies: POSIX sh, getent, the ubuntu/squid base entrypoint.
# Cross-refs: docs/design/mullvad_egress/DYNAMIC_ROUTING_FINDINGS.md (D5);
#            config/squid/Containerfile.dynamic (installs + wires this).
# -----------------------------------------------------------------------------
# D5 root cause: Squid resolves cache_peer HOSTNAMES only at STARTUP and caches a
# NEGATIVE DNS result with no reliable retry (squid-cache.org negative_dns_ttl
# docs + squid-users). If squid starts before gluetun's network-aliases (the D1
# fix) are up, the `cache_peer gluetun-<profile>` names cache NXDOMAIN → the peer
# stays DEAD even after gluetun is reachable, and `squid -k reconfigure` does not
# clear it. Fix: wait (bounded) for at least one gluetun-* peer alias to resolve,
# so the startup peer-name resolution is POSITIVE-cached, THEN exec the base
# ubuntu/squid entrypoint unchanged.
#
# Fail-open on timeout is SAFE: the baked squid.dynamic.conf fails CLOSED (branded
# 503 / terminal `deny all`) whenever a peer is unreachable, so starting squid
# after the wait budget NEVER bypasses the fail-closed egress policy (§11.4.68) —
# the wait only avoids the pathological startup negative-cache. Bounded so squid
# can never hang forever waiting.
# =============================================================================
set -eu

PEERS="${HELIX_GLUETUN_PEERS:-gluetun-eu-wg-primary gluetun-apac-ovpn gluetun-us-wg-failover}"
WAIT_SECS="${HELIX_PEER_WAIT_SECS:-60}"
BASE_ENTRYPOINT="${HELIX_SQUID_BASE_ENTRYPOINT:-/usr/local/bin/entrypoint.sh}"

_now() { date +%s; }
_deadline=$(( $(_now) + WAIT_SECS ))
_resolved=0

while [ "$(_now)" -lt "$_deadline" ]; do
	for _p in $PEERS; do
		if getent hosts "$_p" >/dev/null 2>&1; then
			_resolved=1
			printf 'wait-for-gluetun: peer %s resolved — starting squid (peer positive-cached).\n' "$_p"
			break
		fi
	done
	[ "$_resolved" = 1 ] && break
	sleep 2
done

if [ "$_resolved" != 1 ]; then
	printf 'wait-for-gluetun: TIMEOUT after %ss — no gluetun-* peer resolved; starting squid anyway (baked config fails CLOSED — no egress leak).\n' "$WAIT_SECS"
fi

exec "$BASE_ENTRYPOINT" "$@"
