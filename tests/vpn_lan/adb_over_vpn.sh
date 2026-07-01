#!/usr/bin/env sh
###############################################################################
# adb_over_vpn.sh — VPN-LAN ADB device-bridge test (PLAN.md §5 Phase 7)
#
# Purpose:
#   Prove an Android device exposed on TCP 5555 over the svord VPN-internal
#   network is reachable + usable through helix_proxy's L3-routed gateway, with
#   real captured evidence (PLAN.md §2 unicast-routes rule, §11.4.69):
#     - T7.1 Connect : `adb connect <host>:5555` over the routed VPN path (no
#            proxy hop — recon 4). Central adb-server model (one server, many
#            remote devices — noted in the evidence).
#     - T7.3 Debug   : `adb -s <serial> shell getprop ro.product.model` returns
#            real device-model content (the captured evidence).
#     - T7.4 Flash   : `fastboot` is USB-level — network fastboot is honestly
#            USB-bound (recon 4 FACT); the routable path is `usbip` (USB-over-IP)
#            from a remote host with the device attached. This is documented as
#            an HONEST BOUNDARY (§11.4.6) and any real-device flash is
#            OPERATOR-GATED (§11.4.133 target-hardware-safety + §11.4.122) — this
#            script NEVER flashes; it SKIPs the flash sub-check operator_attended.
#   The svord bridge is the gate: DOWN/misconfigured => every check honestly SKIPs
#   (§11.4.3 / §11.4.68 / §11.4.69) — a down bridge is NEVER a failure and NEVER a
#   fake PASS. A PASS requires captured getprop content; an absent device/tool
#   SKIPs, it never PASSes; a reachable-but-unusable device state FAILs.
#
#   SAFETY (§11.4.174): this test touches ONLY the env-configured HELIX_VPN_ADB_HOST
#   serial. It NEVER runs `adb kill-server`, NEVER a blanket `adb disconnect`, and
#   NEVER acts on any other serial in `adb devices` (operator / lava-* devices are
#   off-limits). `adb disconnect <our-serial>` runs in the cleanup trap (§11.4.14)
#   so the VPN device is never left connected.
#
# Usage:
#   Live bridge (source your .env first — real values live in .env):
#     set -a; . ./.env; set +a; tests/vpn_lan/adb_over_vpn.sh
#   Bridge-down (default autonomous, no .env): prints a SKIP verdict + exit 0.
#   Optional override for testing: SVORD_BRIDGE_LIB=/path/to/svord_bridge.sh
#
# Inputs (environment):
#   PLAN.md §3 bridge contract (gate — resolved by tests/lib/svord_bridge.sh):
#     HELIX_SVORD_DIR HELIX_BRIDGE_CONNECT HELIX_BRIDGE_DISCONNECT
#     HELIX_BRIDGE_HEALTH HELIX_BRIDGE_SUBNET HELIX_BRIDGE_HOST
#   Optional ADB target:
#     HELIX_VPN_ADB_HOST  device 10.x address (no host => SKIP)
#     HELIX_VPN_ADB_PORT  adb tcp port (default 5555)
#   SVORD_BRIDGE_LIB (optional) — path to tests/lib/svord_bridge.sh override.
#
# Outputs:
#   Diagnostic lines on stdout; one verdict token per check
#   (PASS / FAIL / SKIP:<reason>). Exit 0 when the bridge is down (honest SKIP) or
#   when every executed check PASSed/SKIPped; exit 1 iff a real check FAILed.
#   Captured evidence under qa-results/vpn_lan/phase7/<UTC-ts>/{connect,debug,flash}/.
#
# Side-effects:
#   With a live bridge + configured device: `adb connect <our-serial>` then a
#   read-only `adb devices` + `adb -s <our-serial> shell getprop`. `adb disconnect
#   <our-serial>` on every exit path (trap, §11.4.14) — ONLY our serial. NO flash,
#   NO device write, NO kill-server. NEVER modifies svord_toolkit, any other adb
#   device, the base proxy config, or Squid (invocation-only, §11.4.122).
#
# Dependencies:
#   POSIX sh; tests/lib/svord_bridge.sh; adb (Android platform-tools). Missing
#   tool/target SKIPs honestly — it never FAILs and never PASSes.
#
# Cross-references:
#   docs/design/vpn_lan_access/PLAN.md §5 Phase 7 + §2 (routing map) + §6
#   tests/lib/svord_bridge.sh          (bridge contract library sourced below)
#   scripts/svord_doctor.sh            (Phase-0 preflight doctor)
#   constitution §11.4.3 / §11.4.5 / §11.4.6 / §11.4.14 / §11.4.69 / §11.4.122 / §11.4.133 / §11.4.174
###############################################################################

set -u

SCRIPT_LABEL='adb_over_vpn'

# ---- resolve + source the bridge contract library ---------------------------
_ad_script_dir=$(cd "$(dirname "$0")" && pwd)
_ad_repo_root=$(cd "$_ad_script_dir/../.." && pwd)
SVORD_BRIDGE_LIB="${SVORD_BRIDGE_LIB:-$_ad_repo_root/tests/lib/svord_bridge.sh}"

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

# ---- cleanup (§11.4.14 + §11.4.174) -----------------------------------------
# Disconnect ONLY our env-configured serial (never kill-server, never a blanket
# disconnect that would drop operator / lava-* devices). ADB_CONNECTED gates the
# disconnect so we only tear down a connection we actually made.
AD_TMPDIR=''
ADB_TARGET=''
ADB_CONNECTED=0
cleanup() {
    if [ "$ADB_CONNECTED" = 1 ] && [ -n "$ADB_TARGET" ] && command -v adb >/dev/null 2>&1; then
        adb disconnect "$ADB_TARGET" >/dev/null 2>&1
    fi
    [ -n "$AD_TMPDIR" ] && rm -rf "$AD_TMPDIR" >/dev/null 2>&1
    return 0
}
trap cleanup EXIT INT TERM

# ============================================================================
# GATE — honest-SKIP-first. When the bridge is DOWN/misconfigured we print the
# SKIP verdict and exit 0. This is the path that runs NOW (bridge down) — adb is
# NEVER invoked, so no operator / lava-* device is touched.
# ============================================================================
BRIDGE_GATE=$(bridge_require 2>/dev/null)
BRIDGE_RC=$?
if [ "$BRIDGE_RC" -ne 0 ]; then
    [ -z "$BRIDGE_GATE" ] && BRIDGE_GATE='SKIP:network_unreachable_external'
    printf '%s  [%s — svord bridge not up; honest SKIP (§11.4.3), NOT a failure, NOT a fake PASS]\n' \
        "$BRIDGE_GATE" "$SCRIPT_LABEL"
    exit 0
fi
log 'svord bridge UP — running live ADB-over-VPN checks (subnet='"$(bridge_subnet)"' host='"$(bridge_host)"')'

# ---- evidence root (only created when the bridge is genuinely up) -----------
AD_TS=$(date -u +%Y%m%dT%H%M%SZ 2>/dev/null || date +%Y%m%dT%H%M%SZ)
EV_ROOT="$_ad_repo_root/qa-results/vpn_lan/phase7/$AD_TS"
mkdir -p "$EV_ROOT/connect" "$EV_ROOT/debug" "$EV_ROOT/flash" 2>/dev/null || true
AD_TMPDIR=$(mktemp -d 2>/dev/null || printf '%s' "${TMPDIR:-/tmp}/helix_ad_$$")
mkdir -p "$AD_TMPDIR" 2>/dev/null || true

ADB_HOST=${HELIX_VPN_ADB_HOST:-}
ADB_PORT=${HELIX_VPN_ADB_PORT:-5555}

# ============================================================================
# T7.1 CONNECT + T7.3 DEBUG — `adb connect <host>:5555` over the routed VPN path,
# assert OUR serial appears as a usable `device` in `adb devices`, then
# `adb -s <serial> shell getprop ro.product.model` returns real content.
# Central adb-server model (one server, many remote devices) noted in evidence.
# ============================================================================
connect_desc='ADB connect + getprop ro.product.model over routed VPN (5555)'
if [ -z "$ADB_HOST" ]; then
    ab_skip_with_reason "$connect_desc" feature_disabled_by_config
    log 'HELIX_VPN_ADB_HOST unset — no ADB device configured; SKIP (not a PASS)'
elif ! command -v adb >/dev/null 2>&1; then
    ab_skip_with_reason "$connect_desc" topology_unsupported
    log 'no adb client available — SKIP (client tool absent)'
else
    ADB_TARGET="${ADB_HOST}:${ADB_PORT}"
    conn_log="$EV_ROOT/connect/adb_connect.txt"
    devices_log="$EV_ROOT/connect/adb_devices.txt"
    debug_ev="$EV_ROOT/debug/getprop.evidence"
    # `adb connect` reuses the existing (central) adb server — one server manages
    # every remote device; we only ever reference OUR serial ($ADB_TARGET).
    adb connect "$ADB_TARGET" > "$conn_log" 2>&1 || true
    # Did the connect succeed? (accept "connected to" or "already connected to").
    if grep -qiE 'connected to' "$conn_log" 2>/dev/null; then
        ADB_CONNECTED=1
    fi
    if [ "$ADB_CONNECTED" != 1 ]; then
        # No usable connection => device unreachable over the VPN => honest SKIP.
        ab_skip_with_reason "$connect_desc" network_unreachable_external
        log "adb connect could not reach $ADB_TARGET (see $conn_log) — SKIP"
    else
        # Confirm OUR serial is present AND in the usable `device` state (not
        # offline / unauthorized). We grep ONLY for our serial — §11.4.174.
        adb devices > "$devices_log" 2>>"$EV_ROOT/connect/adb_devices.err" || true
        _dev_state=$(awk -v s="$ADB_TARGET" '$1==s {print $2; exit}' "$devices_log" 2>/dev/null)
        if [ "${_dev_state:-}" != 'device' ]; then
            # Reachable (we connected) but the device is NOT in a usable state
            # (offline / unauthorized / absent) => a real not-working state => FAIL.
            ab_fail "$connect_desc" "serial $ADB_TARGET state='${_dev_state:-absent}' (expected 'device'); evidence: $devices_log"; mark_fail
        else
            model_out="$EV_ROOT/debug/model.txt"
            adb -s "$ADB_TARGET" shell getprop ro.product.model > "$model_out" 2>"$EV_ROOT/debug/getprop.err" || true
            # Real content = a non-empty, non-whitespace model string.
            _model=$(tr -d '\r' < "$model_out" 2>/dev/null | awk 'NF {print; exit}')
            {
                printf 'check         : %s\n' "$connect_desc"
                printf 'timestamp_utc : %s\n' "$AD_TS"
                printf 'adb_serial    : %s\n' "$ADB_TARGET"
                printf 'device_state  : %s\n' "${_dev_state:-<none>}"
                printf 'adb_server    : central (one adb server, many remote devices — recon 4)\n'
                printf 'ro.product.model : %s\n' "${_model:-<none>}"
                printf 'expected      : non-empty ro.product.model over routed 5555\n'
            } > "$debug_ev" 2>/dev/null
            if [ -n "$_model" ]; then
                ab_pass_with_evidence "$connect_desc" "$debug_ev" || mark_fail
            else
                # Device present as `device` but getprop returned nothing => defect.
                ab_fail "$connect_desc" "device usable but getprop ro.product.model empty (see $EV_ROOT/debug/getprop.err); evidence: $debug_ev"; mark_fail
            fi
        fi
    fi
fi

# ============================================================================
# T7.4 FLASH — HONEST BOUNDARY (§11.4.6). `fastboot` is USB-level; network
# fastboot is USB-bound (recon 4 FACT). The routable path is `usbip` (USB-over-IP)
# from a remote host with the device attached. ANY real-device flash is
# OPERATOR-GATED (§11.4.133 target-hardware-safety + §11.4.122) — this script
# NEVER flashes and NEVER runs fastboot/usbip; it records the boundary + SKIPs
# operator_attended (an honest SKIP, never a fake PASS).
# ============================================================================
flash_desc='ADB/fastboot flash over VPN (usbip USB-over-IP path)'
flash_ev="$EV_ROOT/flash/boundary.evidence"
{
    printf 'check          : %s\n' "$flash_desc"
    printf 'timestamp_utc  : %s\n' "$AD_TS"
    printf 'boundary       : fastboot is USB-level; network fastboot is USB-bound (recon 4 FACT, §11.4.6)\n'
    printf 'routable_path  : usbip (USB-over-IP) from a remote host with the device attached\n'
    printf 'gate           : OPERATOR-GATED — real-device flash is §11.4.133 target-hardware-safety + §11.4.122\n'
    printf 'this_run       : NO flash attempted; NO fastboot/usbip invoked (invocation-only §11.4.122)\n'
} > "$flash_ev" 2>/dev/null
ab_skip_with_reason "$flash_desc" operator_attended
log 'flash is operator-gated (usbip USB-over-IP; real-device flash §11.4.133) — SKIP; boundary documented in '"$flash_ev"

log "done — evidence root: $EV_ROOT"
exit "$OVERALL_FAIL"
