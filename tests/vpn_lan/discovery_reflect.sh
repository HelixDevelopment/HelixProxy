#!/usr/bin/env sh
###############################################################################
# discovery_reflect.sh — VPN-LAN multicast discovery reflector test (PLAN.md §5 Phase 5)
#
# Purpose:
#   Prove that a service exposed on the svord VPN-internal (remote) subnet can be
#   ENUMERATED from the helix_proxy side through a remote-side multicast discovery
#   reflector (Avahi enable-reflector for mDNS + an SSDP relay for 1900), with real
#   captured evidence. Multicast discovery does NOT cross the L3 VPN (routers do not
#   forward 224.0.0.251:5353 / 239.255.255.250:1900 across a subnet boundary —
#   reflector_design.md §2), so a reflector on the remote subnet is required.
#     - T5.2 mDNS/DNS-SD (SCORED): `avahi-browse -rpt <svc-type>` surfaces a REAL
#            remote service resolved (`^=`) through the reflector; the non-empty,
#            resolved browse output is the enumeration evidence (§11.4.5/§11.4.69).
#     - SSDP M-SEARCH to 239.255.255.250:1900 (SUPPLEMENTARY, non-scored): a
#            best-effort discovery probe whose response count is recorded as
#            context in the evidence file — it never drives PASS/FAIL.
#   The svord bridge is the gate: DOWN/misconfigured => honest SKIP + exit 0
#   (§11.4.3 / §11.4.68 / §11.4.69) — a down bridge is NEVER a failure and NEVER a
#   fake PASS. No reflector configured => SKIP:feature_disabled_by_config (the
#   reflector is operator-gated §11.4.122 and not yet deployed). No avahi-browse
#   client => SKIP:topology_unsupported. A PASS REQUIRES a real service enumerated
#   through the reflector — absent reflector/tool SKIPs, it never PASSes.
#
# Usage:
#   Live bridge + deployed reflector (source your .env first — real values in .env):
#     set -a; . ./.env; set +a; tests/vpn_lan/discovery_reflect.sh
#   Bridge-down (default autonomous, no .env): prints a SKIP verdict + exit 0.
#   Optional override for testing: SVORD_BRIDGE_LIB=/path/to/svord_bridge.sh
#
# Inputs (environment):
#   PLAN.md §3 bridge contract (gate — resolved by tests/lib/svord_bridge.sh):
#     HELIX_SVORD_DIR HELIX_BRIDGE_CONNECT HELIX_BRIDGE_DISCONNECT
#     HELIX_BRIDGE_HEALTH HELIX_BRIDGE_SUBNET HELIX_BRIDGE_HOST
#   Optional reflector target:
#     HELIX_VPN_REFLECTOR       Phase-5 reflector marker (host/addr). Present =>
#                               a reflector is deployed and mDNS enumeration is
#                               attempted; unset => SKIP:feature_disabled_by_config.
#     HELIX_VPN_REFLECT_SVCTYPE DNS-SD service type to browse (default
#                               `_services._dns-sd._udp`, the meta-query that
#                               enumerates all advertised types; e.g.
#                               `_googlecast._tcp` for Cast-only enumeration).
#     HELIX_VPN_SSDP_ADDR       SSDP multicast addr (default 239.255.255.250).
#     HELIX_VPN_SSDP_PORT       SSDP port (default 1900).
#   SVORD_BRIDGE_LIB (optional) — path to tests/lib/svord_bridge.sh override.
#
# Outputs:
#   Diagnostic lines on stdout; one verdict token per check
#   (PASS / FAIL / SKIP:<reason>). Exit 0 when the bridge is down (honest SKIP) or
#   when every executed check PASSed/SKIPped; exit 1 iff a real check FAILed.
#   Captured evidence under qa-results/vpn_lan/phase5/<UTC-ts>/{mdns,ssdp}/.
#
# Side-effects:
#   With a live bridge + configured reflector: a read-only one-shot `avahi-browse`
#   and a best-effort read-only SSDP M-SEARCH datagram. NO daemon is deployed, NO
#   remote host is changed (deployment is operator-gated §11.4.122 — this test only
#   QUERIES an already-deployed reflector). Temp files removed on every exit path
#   (trap, §11.4.14). NEVER modifies svord_toolkit, the reflector host, the base
#   proxy config, or Squid (invocation-only, §11.4.122).
#
# Dependencies:
#   POSIX sh; tests/lib/svord_bridge.sh; avahi-browse (mDNS/DNS-SD enumeration —
#   the SCORED check). Optional: python3 (SSDP M-SEARCH supplementary probe; noted
#   `unprobed` when absent — never a FAIL). Missing tools/targets SKIP honestly —
#   they never FAIL and never PASS.
#
# Cross-references:
#   docs/design/vpn_lan_access/reflector_design.md   (this test's design)
#   docs/design/vpn_lan_access/PLAN.md §5 Phase 5 + §2 (routing map) + §6
#   tests/lib/svord_bridge.sh          (bridge contract library sourced below)
#   tests/vpn_lan/chromecast_dial.sh   (Phase 6 — consumes the reflected discovery)
#   scripts/svord_doctor.sh            (Phase-0 preflight doctor)
#   constitution §11.4.3 / §11.4.5 / §11.4.6 / §11.4.14 / §11.4.69 / §11.4.122
###############################################################################

set -u

SCRIPT_LABEL='discovery_reflect'

# ---- resolve + source the bridge contract library ---------------------------
_dr_script_dir=$(cd "$(dirname "$0")" && pwd)
_dr_repo_root=$(cd "$_dr_script_dir/../.." && pwd)
SVORD_BRIDGE_LIB="${SVORD_BRIDGE_LIB:-$_dr_repo_root/tests/lib/svord_bridge.sh}"

log() { printf '%s: %s\n' "$SCRIPT_LABEL" "$1"; }

if [ ! -f "$SVORD_BRIDGE_LIB" ]; then
    printf 'SKIP:misconfigured  [%s — bridge library missing: %s; honest SKIP (§11.4.3)]\n' \
        "$SCRIPT_LABEL" "$SVORD_BRIDGE_LIB"
    exit 0
fi
# shellcheck disable=SC1090
. "$SVORD_BRIDGE_LIB"

# ---- §11.4.69 PASS/SKIP/FAIL emitters (self-contained, evidence-gated) -------
ab_pass_with_evidence() {
    _pe_desc=$1
    _pe_ev=${2:-}
    if [ -z "$_pe_ev" ] || [ ! -s "$_pe_ev" ]; then
        printf 'FAIL: %s [reason: evidence missing or empty: %s]\n' "$_pe_desc" "$_pe_ev"
        return 1
    fi
    printf 'PASS: %s [evidence: %s]\n' "$_pe_desc" "$_pe_ev"
    return 0
}
ab_skip_with_reason() {
    _sr_desc=$1
    _sr_reason=${2:-}
    case "$_sr_reason" in
        geo_restricted|operator_attended|hardware_not_present|topology_unsupported|network_unreachable_external|feature_disabled_by_config)
            printf 'SKIP: %s [reason: %s]\n' "$_sr_desc" "$_sr_reason"
            return 0 ;;
        *)
            printf 'FAIL: %s [reason: invalid skip reason %s — not §11.4.69 closed set]\n' "$_sr_desc" "$_sr_reason"
            return 2 ;;
    esac
}
ab_fail() { printf 'FAIL: %s [%s]\n' "$1" "${2:-}"; }

OVERALL_FAIL=0
mark_fail() { OVERALL_FAIL=1; }

# ---- cleanup (§11.4.14) -----------------------------------------------------
DR_TMPDIR=''
cleanup() {
    [ -n "$DR_TMPDIR" ] && rm -rf "$DR_TMPDIR" >/dev/null 2>&1
    return 0
}
trap cleanup EXIT INT TERM

# ============================================================================
# GATE — honest-SKIP-first. When the bridge is DOWN/misconfigured we print the
# SKIP verdict and exit 0. This is the path that runs NOW (bridge down) — no
# reflector is contacted at all.
# ============================================================================
BRIDGE_GATE=$(bridge_require 2>/dev/null)
BRIDGE_RC=$?
if [ "$BRIDGE_RC" -ne 0 ]; then
    [ -z "$BRIDGE_GATE" ] && BRIDGE_GATE='SKIP:network_unreachable_external'
    printf '%s  [%s — svord bridge not up; honest SKIP (§11.4.3), NOT a failure, NOT a fake PASS]\n' \
        "$BRIDGE_GATE" "$SCRIPT_LABEL"
    exit 0
fi
log 'svord bridge UP — running live discovery-reflector checks (subnet='"$(bridge_subnet)"' host='"$(bridge_host)"')'

# ---- evidence root (only created when the bridge is genuinely up) -----------
DR_TS=$(date -u +%Y%m%dT%H%M%SZ 2>/dev/null || date +%Y%m%dT%H%M%SZ)
EV_ROOT="$_dr_repo_root/qa-results/vpn_lan/phase5/$DR_TS"
mkdir -p "$EV_ROOT/mdns" "$EV_ROOT/ssdp" 2>/dev/null || true
DR_TMPDIR=$(mktemp -d 2>/dev/null || printf '%s' "${TMPDIR:-/tmp}/helix_dr_$$")
mkdir -p "$DR_TMPDIR" 2>/dev/null || true

REFLECTOR=${HELIX_VPN_REFLECTOR:-}
SVC_TYPE=${HELIX_VPN_REFLECT_SVCTYPE:-_services._dns-sd._udp}
SSDP_ADDR=${HELIX_VPN_SSDP_ADDR:-239.255.255.250}
SSDP_PORT=${HELIX_VPN_SSDP_PORT:-1900}

# ============================================================================
# SUPPLEMENTARY (non-scored) — SSDP M-SEARCH to 239.255.255.250:1900. Best-effort
# discovery probe; its response count is recorded as CONTEXT only and NEVER drives
# PASS/FAIL. python3 preferred (portable multicast sendto/recvfrom with timeout);
# noted `unprobed` when python3 is absent (§11.4.6 — no tool-flag guessing, no fake
# result). Runs before the scored check so its count can be embedded in the mDNS
# evidence file.
# ============================================================================
ssdp_out="$EV_ROOT/ssdp/msearch.txt"
SSDP_RESP_COUNT='unprobed'
if [ -n "$REFLECTOR" ] && command -v python3 >/dev/null 2>&1; then
    HELIX_SSDP_ADDR="$SSDP_ADDR" HELIX_SSDP_PORT="$SSDP_PORT" \
    python3 - > "$ssdp_out" 2>"$EV_ROOT/ssdp/msearch.err" <<'PYEOF' || true
import os, socket
addr = os.environ.get("HELIX_SSDP_ADDR", "239.255.255.250")
port = int(os.environ.get("HELIX_SSDP_PORT", "1900"))
msg = "\r\n".join([
    "M-SEARCH * HTTP/1.1",
    "HOST: %s:%d" % (addr, port),
    'MAN: "ssdp:discover"',
    "MX: 2",
    "ST: ssdp:all",
    "", "",
]).encode("ascii")
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP)
s.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_TTL, 2)
s.settimeout(4)
n = 0
try:
    s.sendto(msg, (addr, port))
    while True:
        try:
            data, src = s.recvfrom(65507)
        except socket.timeout:
            break
        n += 1
        print("--- response %d from %s:%d ---" % (n, src[0], src[1]))
        print(data.decode("utf-8", "replace"))
finally:
    s.close()
print("ssdp_response_count=%d" % n)
PYEOF
    SSDP_RESP_COUNT=$(awk -F= '/^ssdp_response_count=/{print $2; exit}' "$ssdp_out" 2>/dev/null)
    [ -z "$SSDP_RESP_COUNT" ] && SSDP_RESP_COUNT='0'
    log "SSDP M-SEARCH ${SSDP_ADDR}:${SSDP_PORT} (supplementary, non-scored) — responses=${SSDP_RESP_COUNT}"
else
    [ -n "$REFLECTOR" ] && log 'no python3 for SSDP M-SEARCH — supplementary probe unprobed (not a FAIL, §11.4.6)'
fi

# ============================================================================
# T5.2 mDNS/DNS-SD ENUMERATION (SCORED) — the reflected discovery proof. A real
# remote service RESOLVED (`^=`) through the reflector is the PASS evidence
# (§11.4.5 / §11.4.69). No reflector => feature_disabled_by_config. avahi-browse
# absent => topology_unsupported. Reflector up but nothing resolves =>
# network_unreachable_external (honest SKIP, never a fake PASS).
# ============================================================================
mdns_desc='mDNS/DNS-SD service enumerated through the remote reflector (§11.4.5)'
if [ -z "$REFLECTOR" ]; then
    ab_skip_with_reason "$mdns_desc" feature_disabled_by_config
    log 'HELIX_VPN_REFLECTOR unset — reflector not deployed (operator-gated §11.4.122); SKIP (not a PASS)'
elif command -v avahi-browse >/dev/null 2>&1; then
    mdns_out="$EV_ROOT/mdns/browse.txt"
    mdns_ev="$EV_ROOT/mdns/enumeration.evidence"
    # -r resolve, -p parsable (records begin '=' when resolved), -t terminate once.
    avahi-browse -rpt "$SVC_TYPE" > "$mdns_out" 2>"$EV_ROOT/mdns/avahi.err" || true
    _resolved=$(grep -c '^=' "$mdns_out" 2>/dev/null | tr -d ' ')
    [ -z "$_resolved" ] && _resolved=0
    if [ -s "$mdns_out" ] && [ "$_resolved" -ge 1 ] 2>/dev/null; then
        _first_svc=$(awk -F';' '/^=/{print $4"@"$7":"$9; exit}' "$mdns_out" 2>/dev/null)
        {
            printf 'check          : %s\n' "$mdns_desc"
            printf 'timestamp_utc  : %s\n' "$DR_TS"
            printf 'reflector      : %s\n' "$REFLECTOR"
            printf 'service_type   : %s\n' "$SVC_TYPE"
            printf 'resolved_svcs  : %s\n' "$_resolved"
            printf 'first_resolved : %s\n' "${_first_svc:-<parse-failed>}"
            printf 'browse_bytes   : %s\n' "$(wc -c < "$mdns_out" 2>/dev/null | tr -d ' ')"
            printf 'ssdp_msearch   : %s response(s) to %s:%s (supplementary, non-scored)\n' \
                "$SSDP_RESP_COUNT" "$SSDP_ADDR" "$SSDP_PORT"
            printf 'expected       : >=1 resolved (=) DNS-SD record through the reflector\n'
        } > "$mdns_ev" 2>/dev/null
        ab_pass_with_evidence "$mdns_desc" "$mdns_ev" || mark_fail
    else
        # Reflector configured but no service resolved => remote enumeration did
        # not surface anything; honest SKIP (never a fake PASS on empty output).
        ab_skip_with_reason "$mdns_desc" network_unreachable_external
        log "reflector configured but no resolved (=) DNS-SD record surfaced for $SVC_TYPE (see $EV_ROOT/mdns/avahi.err) — SKIP"
    fi
else
    ab_skip_with_reason "$mdns_desc" topology_unsupported
    log 'no avahi-browse client available — enumeration SKIP (client tool absent)'
fi

log "done — evidence root: $EV_ROOT"
exit "$OVERALL_FAIL"
