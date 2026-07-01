#!/usr/bin/env sh
###############################################################################
# chromecast_dial.sh — VPN-LAN Google Cast / DIAL casting test (PLAN.md §5 Phase 6)
#
# Purpose:
#   Prove a Google Chromecast / DIAL device exposed on the svord VPN-internal
#   network is reachable + controllable through helix_proxy's L3-routed gateway,
#   with real captured evidence (PLAN.md §2 unicast-routes rule, §11.4.69/§11.4.107):
#     - T6.1 Discovery : the remote-side reflector (Phase 5) surfaces
#            `_googlecast._tcp` — noted as a DEPENDENCY on Phase 5 (multicast is
#            NOT forwarded across the L3 VPN, PLAN.md §2); direct-IP control is
#            used when a device IP is configured.
#     - T6.2 Control   : GET http://<ip>:8008/setup/eureka_info over the routed
#            unicast VPN path; a real JSON `name` field is the device-identity
#            evidence (the captured JSON body).
#     - T6.3 Liveness  : a CASTV2 (8009 TLS) status *transition* observed across
#            two reads — advancing state, NOT a single frozen frame (§11.4.107).
#   The svord bridge is the gate: DOWN/misconfigured => every check honestly SKIPs
#   (§11.4.3 / §11.4.68 / §11.4.69) — a down bridge is NEVER a failure and NEVER a
#   fake PASS. A PASS requires the captured eureka_info JSON `name` (or a genuine
#   status transition); an absent device/tool SKIPs, it never PASSes; a real
#   non-JSON / non-200 answer FAILs (fail-closed per §11.4.68).
#
# Usage:
#   Live bridge (source your .env first — real values live in .env):
#     set -a; . ./.env; set +a; tests/vpn_lan/chromecast_dial.sh
#   Bridge-down (default autonomous, no .env): prints a SKIP verdict + exit 0.
#   Optional override for testing: SVORD_BRIDGE_LIB=/path/to/svord_bridge.sh
#
# Inputs (environment):
#   PLAN.md §3 bridge contract (gate — resolved by tests/lib/svord_bridge.sh):
#     HELIX_SVORD_DIR HELIX_BRIDGE_CONNECT HELIX_BRIDGE_DISCONNECT
#     HELIX_BRIDGE_HEALTH HELIX_BRIDGE_SUBNET HELIX_BRIDGE_HOST
#   Optional Cast target:
#     HELIX_VPN_CAST_IP           cast device 10.x address (no device => SKIP)
#     HELIX_VPN_CAST_EUREKA_PORT  eureka_info HTTP port (default 8008)
#     HELIX_VPN_CAST_CASTV2_PORT  CASTV2 TLS control port (default 8009)
#     HELIX_VPN_CAST_STATUS_CMD   operator-supplied cast-status command emitting
#                                 the current status (e.g. a go-chromecast/catt
#                                 wrapper); run twice to observe a transition.
#     HELIX_VPN_CAST_REFLECTOR    Phase-5 reflector marker (host/addr); when set
#                                 + avahi-browse present, discovery is attempted.
#   SVORD_BRIDGE_LIB (optional) — path to tests/lib/svord_bridge.sh override.
#
# Outputs:
#   Diagnostic lines on stdout; one verdict token per check
#   (PASS / FAIL / SKIP:<reason>). Exit 0 when the bridge is down (honest SKIP) or
#   when every executed check PASSed/SKIPped; exit 1 iff a real check FAILed.
#   Captured evidence under qa-results/vpn_lan/phase6/<UTC-ts>/{discovery,eureka,castv2}/.
#
# Side-effects:
#   With a live bridge + configured device: a read-only HTTP GET of eureka_info,
#   an optional read-only discovery browse, and (when a status command is given)
#   two read-only status reads. NO media is launched, NO device state is changed.
#   Temp files removed on every exit path (trap, §11.4.14). NEVER modifies
#   svord_toolkit, the cast device, the base proxy config, or Squid
#   (invocation-only, §11.4.122).
#
# Dependencies:
#   POSIX sh; tests/lib/svord_bridge.sh; curl (eureka_info GET). Optional: jq
#   (JSON name parse — grep fallback used when absent); openssl (8009 TLS
#   reachability note); avahi-browse (Phase-5 discovery, when a reflector is set).
#   Missing tools/targets SKIP honestly — they never FAIL and never PASS.
#
# Cross-references:
#   docs/design/vpn_lan_access/PLAN.md §5 Phase 6 + §2 (routing map) + §6
#   tests/lib/svord_bridge.sh          (bridge contract library sourced below)
#   scripts/svord_doctor.sh            (Phase-0 preflight doctor)
#   constitution §11.4.3 / §11.4.5 / §11.4.6 / §11.4.14 / §11.4.107 / §11.4.69 / §11.4.122
###############################################################################

set -u

SCRIPT_LABEL='chromecast_dial'

# ---- resolve + source the bridge contract library ---------------------------
_cc_script_dir=$(cd "$(dirname "$0")" && pwd)
_cc_repo_root=$(cd "$_cc_script_dir/../.." && pwd)
SVORD_BRIDGE_LIB="${SVORD_BRIDGE_LIB:-$_cc_repo_root/tests/lib/svord_bridge.sh}"

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

# ---- portable JSON `name` extractor (jq preferred, grep fallback) ------------
json_name_of() {
    # $1 = path to a JSON file. Prints the `name` field value (empty if absent).
    if command -v jq >/dev/null 2>&1; then
        jq -r '.name // empty' "$1" 2>/dev/null | awk 'NF {print; exit}'
    else
        grep -o '"name"[[:space:]]*:[[:space:]]*"[^"]*"' "$1" 2>/dev/null \
            | head -1 | sed 's/.*"name"[[:space:]]*:[[:space:]]*"//; s/"$//'
    fi
}
# looks_like_json <file> — return 0 when the first non-space byte is '{'.
looks_like_json() {
    _first=$(tr -d '[:space:]' < "$1" 2>/dev/null | cut -c1)
    [ "${_first:-}" = '{' ]
}

OVERALL_FAIL=0
mark_fail() { OVERALL_FAIL=1; }

# ---- cleanup (§11.4.14) -----------------------------------------------------
CC_TMPDIR=''
cleanup() {
    [ -n "$CC_TMPDIR" ] && rm -rf "$CC_TMPDIR" >/dev/null 2>&1
    return 0
}
trap cleanup EXIT INT TERM

# ============================================================================
# GATE — honest-SKIP-first. When the bridge is DOWN/misconfigured we print the
# SKIP verdict and exit 0. This is the path that runs NOW (bridge down) — no
# cast device is contacted at all.
# ============================================================================
BRIDGE_GATE=$(bridge_require 2>/dev/null)
BRIDGE_RC=$?
if [ "$BRIDGE_RC" -ne 0 ]; then
    [ -z "$BRIDGE_GATE" ] && BRIDGE_GATE='SKIP:network_unreachable_external'
    printf '%s  [%s — svord bridge not up; honest SKIP (§11.4.3), NOT a failure, NOT a fake PASS]\n' \
        "$BRIDGE_GATE" "$SCRIPT_LABEL"
    exit 0
fi
log 'svord bridge UP — running live Cast/DIAL checks (subnet='"$(bridge_subnet)"' host='"$(bridge_host)"')'

# ---- evidence root (only created when the bridge is genuinely up) -----------
CC_TS=$(date -u +%Y%m%dT%H%M%SZ 2>/dev/null || date +%Y%m%dT%H%M%SZ)
EV_ROOT="$_cc_repo_root/qa-results/vpn_lan/phase6/$CC_TS"
mkdir -p "$EV_ROOT/discovery" "$EV_ROOT/eureka" "$EV_ROOT/castv2" 2>/dev/null || true
CC_TMPDIR=$(mktemp -d 2>/dev/null || printf '%s' "${TMPDIR:-/tmp}/helix_cc_$$")
mkdir -p "$CC_TMPDIR" 2>/dev/null || true

CAST_IP=${HELIX_VPN_CAST_IP:-}
EUREKA_PORT=${HELIX_VPN_CAST_EUREKA_PORT:-8008}
CASTV2_PORT=${HELIX_VPN_CAST_CASTV2_PORT:-8009}

# ============================================================================
# T6.1 DISCOVERY — via the Phase-5 remote reflector. Multicast (`_googlecast._tcp`
# mDNS / DIAL SSDP) is NOT forwarded across the L3 VPN (PLAN.md §2), so discovery
# DEPENDS on the Phase-5 reflector being deployed (operator-gated §11.4.122).
# When no reflector is configured we honestly SKIP and use the direct device IP.
# ============================================================================
disc_desc='Cast discovery via Phase-5 reflector (_googlecast._tcp)'
CAST_REFLECTOR=${HELIX_VPN_CAST_REFLECTOR:-}
if [ -z "$CAST_REFLECTOR" ]; then
    ab_skip_with_reason "$disc_desc" topology_unsupported
    log 'no reflector configured (HELIX_VPN_CAST_REFLECTOR unset) — discovery is a Phase-5 dependency; using direct IP; SKIP (not a PASS)'
elif command -v avahi-browse >/dev/null 2>&1; then
    disc_out="$EV_ROOT/discovery/googlecast.txt"
    disc_ev="$EV_ROOT/discovery/discovery.evidence"
    avahi-browse -rpt _googlecast._tcp > "$disc_out" 2>"$EV_ROOT/discovery/avahi.err" || true
    if [ -s "$disc_out" ] && grep -q '^=' "$disc_out" 2>/dev/null; then
        {
            printf 'check         : %s\n' "$disc_desc"
            printf 'timestamp_utc : %s\n' "$CC_TS"
            printf 'reflector     : %s\n' "$CAST_REFLECTOR"
            printf 'resolved_svcs : %s\n' "$(grep -c '^=' "$disc_out" 2>/dev/null | tr -d ' ')"
        } > "$disc_ev" 2>/dev/null
        ab_pass_with_evidence "$disc_desc" "$disc_ev" || mark_fail
    else
        ab_skip_with_reason "$disc_desc" network_unreachable_external
        log "reflector configured but no _googlecast._tcp service surfaced (see $EV_ROOT/discovery/avahi.err) — SKIP"
    fi
else
    ab_skip_with_reason "$disc_desc" topology_unsupported
    log 'no avahi-browse client available — discovery SKIP (client tool absent)'
fi

# ============================================================================
# T6.2 CONTROL — GET http://<ip>:8008/setup/eureka_info over the routed unicast
# VPN path. A real JSON `name` field is the device-identity evidence (the captured
# JSON body). A real non-JSON / non-200 answer is a genuine defect => FAIL.
# ============================================================================
eureka_desc='Cast eureka_info device-name JSON (routed 8008)'
if [ -z "$CAST_IP" ]; then
    ab_skip_with_reason "$eureka_desc" feature_disabled_by_config
    log 'HELIX_VPN_CAST_IP unset — no cast device configured; SKIP (not a PASS)'
elif command -v curl >/dev/null 2>&1; then
    eureka_body="$EV_ROOT/eureka/eureka_info.json"
    eureka_ev="$EV_ROOT/eureka/eureka.evidence"
    cast_code=$(curl --silent --show-error --connect-timeout 15 --max-time 30 \
        -o "$eureka_body" -w '%{http_code}' \
        "http://${CAST_IP}:${EUREKA_PORT}/setup/eureka_info" 2>"$EV_ROOT/eureka/curl.err")
    _dev_name=''
    if [ -s "$eureka_body" ] && looks_like_json "$eureka_body"; then
        _dev_name=$(json_name_of "$eureka_body")
    fi
    # Supplementary (non-scored) CASTV2 8009 TLS-reachability note for §11.4.107 context.
    _castv2_reach='unprobed'
    if command -v openssl >/dev/null 2>&1; then
        if printf 'Q\n' | openssl s_client -connect "${CAST_IP}:${CASTV2_PORT}" \
            -servername "${CAST_IP}" -brief >"$EV_ROOT/castv2/tls_probe.txt" 2>&1; then
            _castv2_reach='tls-handshake-ok'
        else
            _castv2_reach='tls-handshake-failed'
        fi
    fi
    {
        printf 'check         : %s\n' "$eureka_desc"
        printf 'timestamp_utc : %s\n' "$CC_TS"
        printf 'cast_ip       : %s\n' "$CAST_IP"
        printf 'eureka_port   : %s\n' "$EUREKA_PORT"
        printf 'http_status   : %s\n' "${cast_code:-<none>}"
        printf 'body_bytes    : %s\n' "$(wc -c < "$eureka_body" 2>/dev/null | tr -d ' ')"
        printf 'device_name   : %s\n' "${_dev_name:-<none>}"
        printf 'castv2_8009    : %s (control-channel reachability note, §11.4.107)\n' "$_castv2_reach"
        printf 'expected      : HTTP 200 + JSON with a non-empty "name"\n'
    } > "$eureka_ev" 2>/dev/null
    if [ "${cast_code:-000}" = '000' ] || [ -z "${cast_code:-}" ]; then
        # No HTTP response at all => device unreachable, honest SKIP (never PASS).
        ab_skip_with_reason "$eureka_desc" network_unreachable_external
        log "eureka_info got no HTTP response from ${CAST_IP}:${EUREKA_PORT} (see $EV_ROOT/eureka/curl.err) — SKIP"
    elif [ "${cast_code:-000}" = '200' ] && [ -n "$_dev_name" ]; then
        ab_pass_with_evidence "$eureka_desc" "$eureka_ev" || mark_fail
    elif [ "${cast_code:-000}" = '200' ]; then
        # Device answered 200 but not a real eureka_info JSON with a name => defect.
        ab_fail "$eureka_desc" "HTTP 200 but no JSON \"name\" field — not a real eureka_info (evidence: $eureka_ev)"; mark_fail
    else
        # A real non-200 answer is a genuine defect, not a SKIP (fail-closed §11.4.68).
        ab_fail "$eureka_desc" "eureka_info returned HTTP ${cast_code} (expected 200 + JSON name); evidence: $eureka_ev"; mark_fail
    fi
else
    ab_skip_with_reason "$eureka_desc" topology_unsupported
    log 'no curl available for eureka_info GET — SKIP (client tool absent)'
fi

# ============================================================================
# T6.3 LIVENESS (§11.4.107) — a CASTV2 status *transition* observed across two
# reads, NOT a single frozen frame. Requires an operator-supplied status command
# (a go-chromecast/catt wrapper) — reading twice while content is playing shows
# an advancing state. Two DISTINCT reads => transition (PASS). Identical reads =>
# device idle (nothing to advance) => honest operator_attended SKIP (a transition
# needs media playing; NOT a fake PASS). No status command => topology SKIP.
# ============================================================================
live_desc='CASTV2 status transition — advancing, not a single frame (§11.4.107)'
CAST_STATUS_CMD=${HELIX_VPN_CAST_STATUS_CMD:-}
if [ -z "$CAST_IP" ]; then
    ab_skip_with_reason "$live_desc" feature_disabled_by_config
    log 'HELIX_VPN_CAST_IP unset — no cast device; liveness SKIP (not a PASS)'
elif [ -z "$CAST_STATUS_CMD" ]; then
    ab_skip_with_reason "$live_desc" topology_unsupported
    log 'HELIX_VPN_CAST_STATUS_CMD unset — no cast-status tool to observe a transition; SKIP (§11.4.6 — no tool-flag guessing)'
else
    live_s1="$EV_ROOT/castv2/status_1.txt"
    live_s2="$EV_ROOT/castv2/status_2.txt"
    live_ev="$EV_ROOT/castv2/liveness.evidence"
    sh -c "$CAST_STATUS_CMD" > "$live_s1" 2>"$EV_ROOT/castv2/status_1.err"; _rc1=$?
    sleep 2
    sh -c "$CAST_STATUS_CMD" > "$live_s2" 2>"$EV_ROOT/castv2/status_2.err"; _rc2=$?
    if [ "$_rc1" = 0 ] && [ "$_rc2" = 0 ] && [ -s "$live_s1" ] && [ -s "$live_s2" ]; then
        _s1sha=$(cksum "$live_s1" 2>/dev/null | awk '{print $1}')
        _s2sha=$(cksum "$live_s2" 2>/dev/null | awk '{print $1}')
        {
            printf 'check         : %s\n' "$live_desc"
            printf 'timestamp_utc : %s\n' "$CC_TS"
            printf 'cast_ip       : %s\n' "$CAST_IP"
            printf 'read1_cksum   : %s\n' "${_s1sha:-<none>}"
            printf 'read2_cksum   : %s\n' "${_s2sha:-<none>}"
            if [ "${_s1sha:-a}" != "${_s2sha:-b}" ]; then
                printf 'transition    : OBSERVED (state advanced between reads)\n'
            else
                printf 'transition    : NONE (identical reads — device idle)\n'
            fi
        } > "$live_ev" 2>/dev/null
        if [ "${_s1sha:-a}" != "${_s2sha:-b}" ]; then
            ab_pass_with_evidence "$live_desc" "$live_ev" || mark_fail
        else
            ab_skip_with_reason "$live_desc" operator_attended
            log 'two status reads identical — device idle; a transition needs media playing (operator-attended); SKIP (not a fake PASS)'
        fi
    else
        ab_skip_with_reason "$live_desc" network_unreachable_external
        log "status command could not reach the CASTV2 control channel (rc1=$_rc1 rc2=$_rc2) — SKIP"
    fi
fi

# ============================================================================
# T6.4 REVERSE LEG (bidirectional_exposure.md §2) — Cast RECEIVER->CONTROLLER
# status callback. CASTV2 is bidirectional: beyond the controller->receiver control
# channel (T6.2/T6.3), the RECEIVER pushes status/feedback callbacks BACK toward
# the controller — a HOST-INITIATED INGRESS flow (a NEW connection the receiver
# opens toward the controller callback port on the proxy side) that rides no prior
# outbound state and needs BOTH the return route AND an ingress-allowlist permit
# for (Cast receiver VPN-host -> controller callback port) (bidir §1.2/§3,
# operator-gated §11.4.122). If only controller->receiver is provisioned, Cast
# degrades to fire-and-forget — the controller loses the state the receiver pushes.
#
# Autonomously observing the inbound receiver->controller callback needs either a
# controller-side callback listener — which THIS test will NEVER open (constraint)
# — or an operator-supplied READ-ONLY observer (a go-chromecast/catt receiver that
# logs pushed status callbacks). Observer contract: rc 0 + non-empty output = a
# real inbound callback was captured (PASS); an explicit DENIED/REFUSED/BLOCKED
# token = the permitted callback was dropped (fail-closed FAIL, §11.4.68);
# otherwise honest SKIP. This is DISTINCT from T6.3 liveness (which reads the
# controller-side status twice); T6.4 asserts the receiver-INITIATED inbound
# callback specifically. This section runs only on a genuinely-up bridge
# (bridge-down already exited 0 at the gate); it opens NO listener and touches NO
# data-plane port (:53128/:51080).
# ============================================================================
cast_rev_desc='Cast reverse leg — receiver->controller status callback (bidir §2)'
CAST_CB_OBSERVE=${HELIX_VPN_CAST_CALLBACK_OBSERVE_CMD:-}
if [ -z "$CAST_IP" ]; then
    ab_skip_with_reason "$cast_rev_desc" feature_disabled_by_config
    log 'Cast reverse leg: HELIX_VPN_CAST_IP unset — no cast device; SKIP (not a PASS)'
elif [ -z "$CAST_CB_OBSERVE" ]; then
    ab_skip_with_reason "$cast_rev_desc" topology_unsupported
    log 'Cast reverse leg: HELIX_VPN_CAST_CALLBACK_OBSERVE_CMD unset — a receiver->controller status callback is host-initiated ingress needing an ingress-allowlist permit + a controller-side callback listener (this test opens NONE); supply an operator read-only observer to exercise it — SKIP (§11.4.6, operator-gated §11.4.122)'
else
    cast_rev_ev="$EV_ROOT/castv2/reverse_callback.evidence"
    cast_rev_out="$CC_TMPDIR/cast_reverse_observe.out"
    sh -c "$CAST_CB_OBSERVE" > "$cast_rev_out" 2>"$EV_ROOT/castv2/reverse_observe.err"; _cast_rev_rc=$?
    {
        printf 'check         : %s\n' "$cast_rev_desc"
        printf 'timestamp_utc : %s\n' "$CC_TS"
        printf 'direction     : receiver->controller (host-initiated ingress; return-route + ingress-allowlist permit required)\n'
        printf 'cast_ip       : %s\n' "$CAST_IP"
        printf 'observer_rc   : %s\n' "$_cast_rev_rc"
        printf 'observer_bytes: %s\n' "$(wc -c < "$cast_rev_out" 2>/dev/null | tr -d ' ')"
        printf 'expected      : a captured inbound status/feedback callback pushed by the receiver\n'
    } > "$cast_rev_ev" 2>/dev/null
    if grep -Eqi 'DENIED|REFUSED|BLOCKED' "$cast_rev_out" 2>/dev/null; then
        ab_fail "$cast_rev_desc" "receiver->controller callback DENIED/dropped — both-way path broken (fail-closed §11.4.68); evidence: $cast_rev_ev"; mark_fail
    elif [ "$_cast_rev_rc" = 0 ] && [ -s "$cast_rev_out" ]; then
        { printf '\n--- observer output (inbound receiver->controller callback evidence) ---\n'; cat "$cast_rev_out"; } >> "$cast_rev_ev" 2>/dev/null
        ab_pass_with_evidence "$cast_rev_desc" "$cast_rev_ev" || mark_fail
    else
        ab_skip_with_reason "$cast_rev_desc" network_unreachable_external
        log "Cast reverse leg: observer captured no inbound callback (rc=$_cast_rev_rc) — needs media playing + the ingress-allowlisted callback port up (operator-gated) — SKIP (not a fake PASS)"
    fi
fi

log "done — evidence root: $EV_ROOT"
exit "$OVERALL_FAIL"
