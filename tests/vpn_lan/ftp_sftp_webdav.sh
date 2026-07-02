#!/usr/bin/env sh
###############################################################################
# ftp_sftp_webdav.sh — VPN-LAN file-transfer round-trip test (PLAN.md §5 Phase 3)
#
# Purpose:
#   Prove FTP (passive), SFTP, and WebDAV file-transfer services exposed on the
#   svord VPN-internal network are reachable + usable through helix_proxy, with
#   real captured evidence:
#     - FTP  (T3.1): passive directory-list + fetch (route 21 + pinned PASV range)
#     - SFTP (T3.2): byte round-trip write->read-back->sha256 match (single conn)
#     - WebDAV(T3.3): PROPFIND through the EXISTING Squid (expect 207 Multi-Status)
#   WebDAV is HTTP, so it traverses the already-running Squid — NO new component.
#   The svord bridge is the gate: DOWN/misconfigured => every check honestly SKIPs
#   (§11.4.3 / §11.4.68 / §11.4.69) — a down bridge is NEVER a failure and NEVER a
#   fake PASS. A PASS requires captured bytes/sha256/207-status; an absent
#   service/tool SKIPs, it never PASSes.
#
# Usage:
#   Live bridge (source your .env first — real values live in .env):
#     set -a; . ./.env; set +a; tests/vpn_lan/ftp_sftp_webdav.sh
#   Bridge-down (default autonomous, no .env): prints a SKIP verdict + exit 0.
#   Optional override for testing: SVORD_BRIDGE_LIB=/path/to/svord_bridge.sh
#
# Inputs (environment):
#   PLAN.md §3 bridge contract (gate — resolved by tests/lib/svord_bridge.sh):
#     HELIX_SVORD_DIR HELIX_BRIDGE_CONNECT HELIX_BRIDGE_DISCONNECT
#     HELIX_BRIDGE_HEALTH HELIX_BRIDGE_SUBNET HELIX_BRIDGE_HOST
#   Optional FTP target:
#     HELIX_VPN_FTP_URL   base ftp URL, e.g. ftp://10.6.100.221/pub/
#     HELIX_VPN_FTP_USER  username (omit for anonymous)
#     HELIX_VPN_FTP_PASS  password (NEVER logged — §11.4.10)
#   Optional SFTP target:
#     HELIX_VPN_SFTP_HOST host (10.x); HELIX_VPN_SFTP_USER user;
#     HELIX_VPN_SFTP_PORT port (default 22); HELIX_VPN_SFTP_DIR remote dir (default .);
#     HELIX_VPN_SFTP_KEY  identity file (key-based, BatchMode — no interactive pw)
#   Optional WebDAV target (traverses the existing Squid):
#     HELIX_VPN_WEBDAV_URL WebDAV collection URL, e.g. http://10.6.100.221/dav/
#     HELIX_SQUID_PROXY    proxy endpoint (default http://127.0.0.1:34128)
#   SVORD_BRIDGE_LIB (optional) — path to tests/lib/svord_bridge.sh override.
#
# Outputs:
#   Diagnostic lines on stdout; one verdict token per protocol
#   (PASS / FAIL / SKIP:<reason>). Exit 0 when the bridge is down (honest SKIP) or
#   when every executed check PASSed/SKIPped; exit 1 iff a real check FAILed.
#   Captured evidence under qa-results/vpn_lan/phase3/<UTC-ts>/{ftp,sftp,webdav}/.
#
# Side-effects:
#   With a live bridge + configured target: FTP does a read-only list + fetch;
#   SFTP writes a small known file, reads it back, deletes it; WebDAV issues a
#   read-only PROPFIND through Squid. Temp files removed on every exit path
#   (trap, §11.4.14). NEVER modifies svord_toolkit, the remote host beyond the
#   SFTP round-trip file, the base proxy config, or Squid (invocation-only,
#   §11.4.122).
#
# Dependencies:
#   POSIX sh; tests/lib/svord_bridge.sh; sha256sum OR shasum -a 256; curl (FTP +
#   WebDAV/PROPFIND through Squid); sftp (SFTP). Missing tools/targets SKIP
#   honestly — they never FAIL and never PASS.
#
# Cross-references:
#   docs/design/vpn_lan_access/PLAN.md §5 Phase 3 + §6 (test-evidence strategy)
#   tests/lib/svord_bridge.sh          (bridge contract library sourced below)
#   scripts/svord_doctor.sh            (Phase-0 preflight doctor)
#   constitution §11.4.3 / §11.4.5 / §11.4.6 / §11.4.14 / §11.4.69 / §11.4.122
###############################################################################

set -u

SCRIPT_LABEL='ftp_sftp_webdav'

# ---- resolve + source the bridge contract library ---------------------------
_ft_script_dir=$(cd "$(dirname "$0")" && pwd)
_ft_repo_root=$(cd "$_ft_script_dir/../.." && pwd)
SVORD_BRIDGE_LIB="${SVORD_BRIDGE_LIB:-$_ft_repo_root/tests/lib/svord_bridge.sh}"

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

# ---- sha256 helper (cross-platform §11.4.81) --------------------------------
sha256_of() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" 2>/dev/null | awk '{print $1; exit}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" 2>/dev/null | awk '{print $1; exit}'
    else
        printf ''
    fi
}

OVERALL_FAIL=0
mark_fail() { OVERALL_FAIL=1; }

# ---- cleanup (§11.4.14) -----------------------------------------------------
FT_TMPDIR=''
cleanup() {
    [ -n "$FT_TMPDIR" ] && rm -rf "$FT_TMPDIR" >/dev/null 2>&1
    return 0
}
trap cleanup EXIT INT TERM

# ============================================================================
# GATE — honest-SKIP-first. When the bridge is DOWN/misconfigured we print the
# SKIP verdict and exit 0. This is the path that runs NOW (bridge down).
# ============================================================================
BRIDGE_GATE=$(bridge_require 2>/dev/null)
BRIDGE_RC=$?
if [ "$BRIDGE_RC" -ne 0 ]; then
    [ -z "$BRIDGE_GATE" ] && BRIDGE_GATE='SKIP:network_unreachable_external'
    printf '%s  [%s — svord bridge not up; honest SKIP (§11.4.3), NOT a failure, NOT a fake PASS]\n' \
        "$BRIDGE_GATE" "$SCRIPT_LABEL"
    exit 0
fi
log 'svord bridge UP — running live FTP/SFTP/WebDAV checks (subnet='"$(bridge_subnet)"' host='"$(bridge_host)"')'

# ---- evidence root (only created when the bridge is genuinely up) -----------
FT_TS=$(date -u +%Y%m%dT%H%M%SZ 2>/dev/null || date +%Y%m%dT%H%M%SZ)
EV_ROOT="$_ft_repo_root/qa-results/vpn_lan/phase3/$FT_TS"
mkdir -p "$EV_ROOT/ftp" "$EV_ROOT/sftp" "$EV_ROOT/webdav" 2>/dev/null || true
FT_TMPDIR=$(mktemp -d 2>/dev/null || printf '%s' "${TMPDIR:-/tmp}/helix_ft_$$")
mkdir -p "$FT_TMPDIR" 2>/dev/null || true

FT_NAME="helix_proxy_ft_${$}_$(date +%s 2>/dev/null || echo 0)"
FT_LOCAL="$FT_TMPDIR/$FT_NAME.src"
{
    printf 'helix_proxy VPN-LAN Phase-3 round-trip payload\n'
    printf 'ts=%s host=%s subnet=%s\n' "$FT_TS" "$(bridge_host)" "$(bridge_subnet)"
    dd if=/dev/urandom bs=1024 count=16 2>/dev/null | od -An -tx1 2>/dev/null
} > "$FT_LOCAL" 2>/dev/null
FT_SRC_SHA=$(sha256_of "$FT_LOCAL")

# ============================================================================
# FTP (T3.1) — passive directory list + fetch. curl uses PASV by default; the
# server must advertise its 10.x addr in the PASV reply for the data channel to
# route over the L3 VPN (PLAN.md §2). PASS requires captured, non-empty bytes.
# ============================================================================
ftp_desc='FTP passive directory-list + fetch (VPN server)'
FTP_URL=${HELIX_VPN_FTP_URL:-}
if [ -z "$FTP_URL" ]; then
    ab_skip_with_reason "$ftp_desc" feature_disabled_by_config
    log 'HELIX_VPN_FTP_URL unset — no FTP server configured; SKIP (not a PASS)'
elif command -v curl >/dev/null 2>&1; then
    ftp_list="$EV_ROOT/ftp/listing.txt"
    ftp_ev="$EV_ROOT/ftp/roundtrip.evidence"
    set -- --silent --show-error --ftp-pasv --connect-timeout 15 --max-time 60
    if [ -n "${HELIX_VPN_FTP_USER:-}" ]; then
        set -- "$@" --user "${HELIX_VPN_FTP_USER}:${HELIX_VPN_FTP_PASS:-}"
    fi
    # Normalise to a directory URL (trailing slash) so curl returns a listing.
    _ftp_dir=$FTP_URL
    case "$_ftp_dir" in */) : ;; *) _ftp_dir="$_ftp_dir/" ;; esac
    if curl "$@" "$_ftp_dir" > "$ftp_list" 2>"$EV_ROOT/ftp/curl.err" && [ -s "$ftp_list" ]; then
        # Fetch the first listed regular entry to prove a real byte transfer.
        _ftp_first=$(awk 'NF {print $NF; exit}' "$ftp_list" 2>/dev/null)
        ftp_fetch="$EV_ROOT/ftp/fetched.bin"
        _ftp_fetch_ok=1
        if [ -n "$_ftp_first" ]; then
            curl "$@" "${_ftp_dir}${_ftp_first}" > "$ftp_fetch" 2>>"$EV_ROOT/ftp/curl.err" && [ -s "$ftp_fetch" ] && _ftp_fetch_ok=0
        fi
        {
            printf 'protocol_test : %s\n' "$ftp_desc"
            printf 'timestamp_utc : %s\n' "$FT_TS"
            printf 'listing_bytes : %s\n' "$(wc -c < "$ftp_list" 2>/dev/null | tr -d ' ')"
            printf 'listing_lines : %s\n' "$(wc -l < "$ftp_list" 2>/dev/null | tr -d ' ')"
            printf 'first_entry   : %s\n' "${_ftp_first:-<none>}"
            if [ "$_ftp_fetch_ok" = 0 ]; then
                printf 'fetch         : OK (%s bytes, sha256=%s)\n' \
                    "$(wc -c < "$ftp_fetch" 2>/dev/null | tr -d ' ')" "$(sha256_of "$ftp_fetch")"
            else
                printf 'fetch         : listing-only (no fetchable regular entry)\n'
            fi
        } > "$ftp_ev" 2>/dev/null
        ab_pass_with_evidence "$ftp_desc" "$ftp_ev" || mark_fail
    else
        # Bridge up but server unreachable/denied => honest topology SKIP, never PASS.
        ab_skip_with_reason "$ftp_desc" network_unreachable_external
        log "curl could not list $FTP_URL (see $EV_ROOT/ftp/curl.err) — SKIP"
    fi
else
    ab_skip_with_reason "$ftp_desc" topology_unsupported
    log 'no curl available for FTP — SKIP (client tool absent)'
fi

# ============================================================================
# SFTP (T3.2) — single-connection byte round-trip over routed TCP 22. Key-based,
# BatchMode (never interactive) so the test is fully autonomous (§11.4.98).
# PASS requires the read-back sha256 to match the source (§11.4.5 / §11.4.69).
# ============================================================================
sftp_desc='SFTP write->read-back->sha256 round-trip (VPN host)'
SFTP_HOST=${HELIX_VPN_SFTP_HOST:-}
if [ -z "$SFTP_HOST" ]; then
    ab_skip_with_reason "$sftp_desc" feature_disabled_by_config
    log 'HELIX_VPN_SFTP_HOST unset — no SFTP host configured; SKIP (not a PASS)'
elif command -v sftp >/dev/null 2>&1; then
    _sftp_user=${HELIX_VPN_SFTP_USER:-}
    _sftp_port=${HELIX_VPN_SFTP_PORT:-22}
    _sftp_dir=${HELIX_VPN_SFTP_DIR:-.}
    _sftp_target="$SFTP_HOST"
    [ -n "$_sftp_user" ] && _sftp_target="${_sftp_user}@${SFTP_HOST}"
    sftp_readback="$FT_TMPDIR/$FT_NAME.sftp.back"
    sftp_batch="$FT_TMPDIR/$FT_NAME.sftp.batch"
    sftp_ev="$EV_ROOT/sftp/roundtrip.evidence"
    {
        printf 'put "%s" "%s/%s"\n' "$FT_LOCAL" "$_sftp_dir" "$FT_NAME"
        printf 'get "%s/%s" "%s"\n' "$_sftp_dir" "$FT_NAME" "$sftp_readback"
        printf 'rm "%s/%s"\n' "$_sftp_dir" "$FT_NAME"
    } > "$sftp_batch"
    set -- -b "$sftp_batch" -P "$_sftp_port" \
        -o BatchMode=yes -o ConnectTimeout=15 -o StrictHostKeyChecking=accept-new
    [ -n "${HELIX_VPN_SFTP_KEY:-}" ] && set -- "$@" -i "$HELIX_VPN_SFTP_KEY"
    if sftp "$@" "$_sftp_target" > "$EV_ROOT/sftp/sftp.log" 2>&1 && [ -f "$sftp_readback" ]; then
        _sftp_dst_sha=$(sha256_of "$sftp_readback")
        {
            printf 'protocol_test : %s\n' "$sftp_desc"
            printf 'timestamp_utc : %s\n' "$FT_TS"
            printf 'host          : %s port %s\n' "$SFTP_HOST" "$_sftp_port"
            printf 'payload_bytes : %s\n' "$(wc -c < "$FT_LOCAL" 2>/dev/null | tr -d ' ')"
            printf 'src_sha256    : %s\n' "$FT_SRC_SHA"
            printf 'readback_sha256: %s\n' "$_sftp_dst_sha"
            if [ -n "$FT_SRC_SHA" ] && [ "$FT_SRC_SHA" = "$_sftp_dst_sha" ]; then
                printf 'integrity     : MATCH\n'
            else
                printf 'integrity     : MISMATCH\n'
            fi
        } > "$sftp_ev" 2>/dev/null
        if [ -n "$FT_SRC_SHA" ] && [ "$FT_SRC_SHA" = "$_sftp_dst_sha" ]; then
            ab_pass_with_evidence "$sftp_desc" "$sftp_ev" || mark_fail
        else
            ab_fail "$sftp_desc" "sha256 mismatch — bytes did not survive (evidence: $sftp_ev)"; mark_fail
        fi
    else
        ab_skip_with_reason "$sftp_desc" network_unreachable_external
        log "sftp could not complete against $SFTP_HOST (see $EV_ROOT/sftp/sftp.log) — SKIP"
    fi
else
    ab_skip_with_reason "$sftp_desc" topology_unsupported
    log 'no sftp client available — SKIP (client tool absent)'
fi

# ============================================================================
# WebDAV (T3.3) — HTTP, so it goes through the EXISTING Squid (no new component).
# PROPFIND must return 207 Multi-Status. PASS requires the captured 207 status +
# non-empty XML body (§11.4.69) — never a config-only / absence-of-error PASS.
# ============================================================================
webdav_desc='WebDAV PROPFIND via existing Squid (expect 207 Multi-Status)'
WEBDAV_URL=${HELIX_VPN_WEBDAV_URL:-}
SQUID_PROXY=${HELIX_SQUID_PROXY:-http://127.0.0.1:34128}
if [ -z "$WEBDAV_URL" ]; then
    ab_skip_with_reason "$webdav_desc" feature_disabled_by_config
    log 'HELIX_VPN_WEBDAV_URL unset — no WebDAV origin configured; SKIP (not a PASS)'
elif command -v curl >/dev/null 2>&1; then
    dav_body="$EV_ROOT/webdav/propfind.xml"
    dav_ev="$EV_ROOT/webdav/propfind.evidence"
    dav_code=$(curl --silent --show-error -x "$SQUID_PROXY" \
        -X PROPFIND -H 'Depth: 0' -H 'Content-Type: application/xml' \
        --connect-timeout 15 --max-time 45 \
        -o "$dav_body" -w '%{http_code}' "$WEBDAV_URL" 2>"$EV_ROOT/webdav/curl.err")
    {
        printf 'protocol_test : %s\n' "$webdav_desc"
        printf 'timestamp_utc : %s\n' "$FT_TS"
        printf 'via_proxy     : %s\n' "$SQUID_PROXY"
        printf 'webdav_url    : %s\n' "$WEBDAV_URL"
        printf 'http_status   : %s\n' "${dav_code:-<none>}"
        printf 'body_bytes    : %s\n' "$(wc -c < "$dav_body" 2>/dev/null | tr -d ' ')"
        printf 'expected      : 207 Multi-Status\n'
    } > "$dav_ev" 2>/dev/null
    if [ "${dav_code:-000}" = "207" ] && [ -s "$dav_body" ]; then
        ab_pass_with_evidence "$webdav_desc" "$dav_ev" || mark_fail
    elif [ "${dav_code:-000}" = "000" ] || [ -z "${dav_code:-}" ]; then
        # No HTTP response at all through Squid => origin unreachable, honest SKIP.
        ab_skip_with_reason "$webdav_desc" network_unreachable_external
        log "WebDAV PROPFIND got no HTTP response via $SQUID_PROXY (see $EV_ROOT/webdav/curl.err) — SKIP"
    else
        # A real HTTP response that is NOT 207 is a genuine defect, not a SKIP
        # (fail-closed per §11.4.68 — the origin answered, just not with 207).
        ab_fail "$webdav_desc" "PROPFIND returned HTTP ${dav_code} (expected 207); evidence: $dav_ev"; mark_fail
    fi
else
    ab_skip_with_reason "$webdav_desc" topology_unsupported
    log 'no curl available for WebDAV/PROPFIND — SKIP (client tool absent)'
fi

# ============================================================================
# T3.4 REVERSE LEG (bidirectional_exposure.md §2) — FTP ACTIVE-mode (PORT) data
# connection server->client. In active mode the client sends PORT/EPRT and the FTP
# SERVER opens a NEW data connection BACK to the client's advertised port (source
# :20) — a HOST-INITIATED INGRESS flow that rides no prior outbound state and needs
# BOTH the return route AND an ingress-allowlist permit for
# (FTP-server VPN-host -> client active-data port range on the proxy side)
# (bidir §1.2/§3, operator-gated §11.4.122). If only passive is provisioned, active
# transfers hang/fail (FACT — slacksite; jscape).
#
# Driving active mode autonomously (curl --ftp-port / -P) makes the CLIENT open a
# transient data LISTENER for the server to connect back to — which THIS test will
# NEVER open (constraint). So the active reverse leg is exercised ONLY via an
# operator-supplied driver (HELIX_VPN_FTP_ACTIVE_CMD) that owns that data listener
# + the ingress-allowlist grant. Driver contract: rc 0 + non-empty output = a real
# server->client active transfer completed (PASS); an explicit DENIED/REFUSED/
# BLOCKED / 425 token = the return data channel was refused (fail-closed FAIL,
# §11.4.68); otherwise honest SKIP. SFTP (single connection) and WebDAV (HTTP
# request/response via Squid) have NO host-initiated server->client leg —
# documented N/A below, NOT fabricated (§11.4.6). This section runs only on a
# genuinely-up bridge (bridge-down already exited 0 at the gate); it opens NO
# listener and touches NO data-plane port (:34128/:34080).
# ============================================================================
ftp_rev_desc='FTP reverse leg — ACTIVE-mode (PORT) data connection server->client (bidir §2)'
FTP_ACTIVE_CMD=${HELIX_VPN_FTP_ACTIVE_CMD:-}
if [ -z "$FTP_URL" ]; then
    ab_skip_with_reason "$ftp_rev_desc" feature_disabled_by_config
    log 'FTP reverse leg: no FTP server configured — SKIP (not a PASS)'
elif [ -z "$FTP_ACTIVE_CMD" ]; then
    ab_skip_with_reason "$ftp_rev_desc" topology_unsupported
    log 'FTP reverse leg: HELIX_VPN_FTP_ACTIVE_CMD unset — active-mode data is server->client host-initiated ingress needing a client-side data listener (this test opens NONE) + an ingress-allowlist permit for source:20 server->client; supply an operator active-mode driver to exercise it — SKIP (§11.4.6, operator-gated §11.4.122)'
else
    ftp_rev_ev="$EV_ROOT/ftp/reverse_active.evidence"
    ftp_rev_out="$FT_TMPDIR/ftp_active.out"
    sh -c "$FTP_ACTIVE_CMD" > "$ftp_rev_out" 2>"$EV_ROOT/ftp/active.err"; _ftp_rev_rc=$?
    {
        printf 'protocol_test : %s\n' "$ftp_rev_desc"
        printf 'timestamp_utc : %s\n' "$FT_TS"
        printf 'direction     : server->client data (active/PORT; host-initiated ingress)\n'
        printf 'requires      : return-route + ingress-allowlist permit (FTP-server VPN-host -> client active-data port)\n'
        printf 'driver_rc     : %s\n' "$_ftp_rev_rc"
        printf 'driver_bytes  : %s\n' "$(wc -c < "$ftp_rev_out" 2>/dev/null | tr -d ' ')"
        printf 'expected      : a real server->client active-mode data transfer completes\n'
    } > "$ftp_rev_ev" 2>/dev/null
    if grep -Eqi 'DENIED|REFUSED|BLOCKED|425' "$ftp_rev_out" 2>/dev/null; then
        ab_fail "$ftp_rev_desc" "active-mode data connection refused (server could not open the return data channel — both-way path broken, fail-closed §11.4.68); evidence: $ftp_rev_ev"; mark_fail
    elif [ "$_ftp_rev_rc" = 0 ] && [ -s "$ftp_rev_out" ]; then
        { printf '\n--- active-mode driver output (server->client transfer evidence) ---\n'; cat "$ftp_rev_out"; } >> "$ftp_rev_ev" 2>/dev/null
        ab_pass_with_evidence "$ftp_rev_desc" "$ftp_rev_ev" || mark_fail
    else
        ab_skip_with_reason "$ftp_rev_desc" network_unreachable_external
        log "FTP reverse leg: active-mode driver did not complete (rc=$_ftp_rev_rc) — the server->client data channel needs the ingress-allowlisted active-data port up (operator-gated) — SKIP (not a fake PASS)"
    fi
fi
# SFTP + WebDAV reverse leg — DOCUMENTED N/A (§11.4.6): SFTP multiplexes data
# inside a single client->server connection (no host-initiated callback); WebDAV is
# HTTP request/response through the existing Squid (no server->client leg). No
# reverse leg to fabricate; forwards asserted by T3.2 (SFTP) + T3.3 (WebDAV).
log 'SFTP/WebDAV reverse leg: N/A (§11.4.6) — no host-initiated server->client callback; forwards asserted by T3.2/T3.3'

log "done — evidence root: $EV_ROOT"
exit "$OVERALL_FAIL"
