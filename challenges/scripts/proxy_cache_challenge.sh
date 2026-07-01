#!/usr/bin/env bash
# =============================================================================
# proxy_cache_challenge.sh — Squid cache-HIT anti-bluff Challenge
# -----------------------------------------------------------------------------
# Purpose:      Prove the LIVE HTTP proxy (localhost:53128) caches. A cacheable
#               plain-HTTP URL is fetched TWICE through the proxy; the AUTHORITATIVE
#               proof is a Squid TCP_*HIT result code for THAT url in the Squid
#               access.log (asserted via evidence.sh assert_cache_hit) — an
#               X-Cache header or an Age field alone is forgeable and is NEVER
#               accepted as the verdict (§11.4.69/§11.4.107 discipline). If the
#               access.log is not reachable/readable, the challenge SKIPs with
#               the closed-set reason topology_unsupported (§11.4.3) — it does
#               NOT fake a PASS. The client-side double-fetch (response codes +
#               Via + Age headers) is captured as supplementary evidence either way.
# Usage:        bash challenges/scripts/proxy_cache_challenge.sh
#               CHALLENGE_EVIDENCE_DIR=<dir> bash .../proxy_cache_challenge.sh
# Inputs:       Live curl through http://localhost:53128 (READ-ONLY client use);
#               the Squid access.log resolved from the project config.
#               Env: HTTP_PROXY_URL (default http://localhost:53128),
#                    HTTP_PROXY_PORT (default 53128),
#                    CACHE_URL (default http://example.com/),
#                    SQUID_ACCESS_LOG (override the resolved log path),
#                    LOG_DIR (default ./logs; container /var/log/squid maps here),
#                    CHALLENGE_EVIDENCE_DIR (default qa-results/challenges/<ts>),
#                    CURL_MAX_TIME (default 20).
# Outputs:      A connectivity-precondition verdict, then either the assert_cache_hit
#               verdict (PASS/FAIL) or an honest topology SKIP; a captured evidence
#               file <evdir>/cache/cache_evidence.txt.
#               Exit: 0 = PASS, 1 = FAIL (proxy defect / cacheable url never HITs),
#               3 = SKIP (outage OR access.log unreadable — honest, never faked).
# Side-effects: Live curl only. Never stops/restarts/reconfigures any container.
#               Reads (never writes) the Squid access.log. Creates the evidence
#               directory + file under qa-results/.
# Dependencies: bash, curl, awk, grep; tests/lib/evidence.sh (sourced).
# Cross-refs:   Constitution §11.4.27 (Challenges), §11.4.69 (sink evidence),
#               §11.4.107 (forgeable-header discipline), §11.4.3 (honest SKIP),
#               §11.4.68 (no fail-open), evidence.sh assert_cache_hit / proxy_conn_verdict.
# Shell:        POSIX-clean body — parses under `sh -n` AND `bash -n` (§11.4.67).
# =============================================================================

set -u

CHALLENGE_NAME="proxy_cache"

# --- Locate repo root -------------------------------------------------------
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
find_repo_root() {
    d=$1
    while [ "$d" != "/" ]; do
        if [ -f "$d/tests/lib/evidence.sh" ]; then
            printf '%s\n' "$d"; return 0
        fi
        d=$(dirname "$d")
    done
    return 1
}
REPO_ROOT=$(find_repo_root "$SCRIPT_DIR" || true)
if [ -z "${REPO_ROOT:-}" ]; then
    echo "FAIL: cannot locate tests/lib/evidence.sh from $SCRIPT_DIR" >&2
    exit 1
fi
# shellcheck source=/dev/null
. "$REPO_ROOT/tests/lib/evidence.sh"

# --- Config -----------------------------------------------------------------
PROXY_URL=${HTTP_PROXY_URL:-http://localhost:53128}
PROXY_PORT=${HTTP_PROXY_PORT:-53128}
CACHE_URL=${CACHE_URL:-http://example.com/}
MAX_TIME=${CURL_MAX_TIME:-20}
RUN_TS=$(date -u +%Y%m%dT%H%M%SZ)
EVIDENCE_DIR=${CHALLENGE_EVIDENCE_DIR:-$REPO_ROOT/qa-results/challenges/$RUN_TS}
OUT_DIR="$EVIDENCE_DIR/cache"
mkdir -p "$OUT_DIR"
EV="$OUT_DIR/cache_evidence.txt"

# --- Resolve the Squid access.log path from project config ------------------
# docker-compose.yml maps container /var/log/squid -> ${LOG_DIR:-./logs}; the
# access_log lives at <LOG_DIR>/access.log. Honour an explicit override first,
# then a LOG_DIR from .env, then the compose default ./logs.
resolve_access_log() {
    if [ -n "${SQUID_ACCESS_LOG:-}" ]; then
        printf '%s\n' "$SQUID_ACCESS_LOG"; return 0
    fi
    _ld=${LOG_DIR:-}
    if [ -z "$_ld" ] && [ -f "$REPO_ROOT/.env" ]; then
        _ld=$(grep -E '^[[:space:]]*LOG_DIR=' "$REPO_ROOT/.env" 2>/dev/null \
            | tail -n1 | sed 's/^[[:space:]]*LOG_DIR=//' | tr -d '"' | tr -d "'")
    fi
    [ -n "$_ld" ] || _ld="$REPO_ROOT/logs"
    case "$_ld" in
        /*) : ;;                       # absolute
        ./*) _ld="$REPO_ROOT/${_ld#./}" ;;
        *)  _ld="$REPO_ROOT/$_ld" ;;
    esac
    printf '%s/access.log\n' "$_ld"
}
ACCESS_LOG=$(resolve_access_log)

# --- curl double-fetch, capturing headers -----------------------------------
curl_fetch() {
    _hdr=$1
    curl -sS -D "$_hdr" -o /dev/null -w '%{http_code}' \
        --max-time "$MAX_TIME" -x "$PROXY_URL" "$CACHE_URL" 2>/dev/null || printf '000'
}

HDR1="$OUT_DIR/fetch1_headers.txt"
HDR2="$OUT_DIR/fetch2_headers.txt"
: > "$HDR1"; : > "$HDR2"

{
    printf '=== %s challenge — run %s ===\n' "$CHALLENGE_NAME" "$RUN_TS"
    printf 'proxy_url=%s  cache_url=%s  max_time=%ss\n' "$PROXY_URL" "$CACHE_URL" "$MAX_TIME"
    printf 'resolved_access_log=%s\n' "$ACCESS_LOG"
    printf 'authoritative proof = Squid TCP_*HIT for this url in access.log;\n'
    printf 'Via/Age headers captured as SUPPLEMENTARY only (forgeable, never the verdict).\n'
} > "$EV"

echo "=== $CHALLENGE_NAME challenge ==="
echo "proxy=$PROXY_URL  cache_url=$CACHE_URL  access_log=$ACCESS_LOG"
echo "evidence=$EV"

CODE1=$(curl_fetch "$HDR1"); [ -n "$CODE1" ] || CODE1=000
# brief settle so Squid can store the first response before the second request
sleep 1
CODE2=$(curl_fetch "$HDR2"); [ -n "$CODE2" ] || CODE2=000
DIRECT=$(curl -sS -o /dev/null -w '%{http_code}' --max-time "$MAX_TIME" "$CACHE_URL" 2>/dev/null || printf '000')
[ -n "$DIRECT" ] || DIRECT=000
if port_is_listening "$PROXY_PORT"; then LISTEN=yes; else LISTEN=no; fi

{
    printf '\n--- client-side double-fetch (supplementary) ---\n'
    printf 'fetch1_code=%s  fetch2_code=%s  direct_code=%s  port_%s_listening=%s\n' \
        "$CODE1" "$CODE2" "$DIRECT" "$PROXY_PORT" "$LISTEN"
    printf 'fetch2 cache-relevant headers:\n'
    grep -iE '^HTTP/|^Via:|^Age:|^X-Cache:|^Cache-Control:|^Expires:' "$HDR2" 2>/dev/null \
        | sed 's/^/  /' || true
} >> "$EV"

# --- Connectivity precondition (expected 200 for example.com) ---------------
PRE=$(proxy_conn_verdict "$CODE2" "$DIRECT" "200" "$LISTEN")
printf '\nconnectivity precondition verdict=%s (proxy=%s direct=%s)\n' "$PRE" "$CODE2" "$DIRECT" >> "$EV"

case "$PRE" in
    FAIL)
        echo "OVERALL: FAIL — proxy could not fetch $CACHE_URL but it is reachable directly (defect)"
        printf 'OVERALL=FAIL (connectivity precondition)\n' >> "$EV"
        exit 1 ;;
    SKIP:*)
        _r=${PRE#SKIP:}
        echo "OVERALL: SKIP ($_r) — cache url not reachable to exercise caching"
        printf 'OVERALL=SKIP:%s (connectivity precondition)\n' "$_r" >> "$EV"
        ab_skip_with_reason "cache challenge (cache url unreachable)" "$_r"
        exit 3 ;;
esac

echo "[precondition] PASS proxy fetched $CACHE_URL twice (codes $CODE1/$CODE2)"

# --- Authoritative cache proof: TCP_*HIT in the Squid access.log ------------
if [ -r "$ACCESS_LOG" ]; then
    echo "[cache] access.log readable — asserting TCP_*HIT for $CACHE_URL"
    HIT_OUT=$(assert_cache_hit "$ACCESS_LOG" "$CACHE_URL")
    HIT_RC=$?
    printf '\n--- authoritative assert_cache_hit ---\n%s\n' "$HIT_OUT" >> "$EV"
    echo "$HIT_OUT"
    if [ "$HIT_RC" -eq 0 ]; then
        printf 'OVERALL=PASS\n' >> "$EV"
        ab_pass_with_evidence "Squid cache HIT proven via access.log TCP_*HIT for $CACHE_URL" "$EV"
        exit 0
    fi
    echo "OVERALL: FAIL — no TCP_*HIT for a cacheable URL fetched twice"
    printf 'OVERALL=FAIL (no TCP_*HIT)\n' >> "$EV"
    exit 1
fi

# access.log present-but-unreadable OR absent -> honest topology SKIP (§11.4.3).
{
    printf '\n--- authoritative proof UNAVAILABLE ---\n'
    if [ -e "$ACCESS_LOG" ]; then
        printf 'access.log exists but is NOT readable by %s (uid %s):\n' "$(id -un)" "$(id -u)"
        ls -ln "$ACCESS_LOG" 2>/dev/null | sed 's/^/  /'
        printf '  (rootless-container subuid ownership; reading it would require container\n'
        printf '   access, which this READ-ONLY-client challenge does not perform)\n'
    else
        printf 'access.log does not exist at %s\n' "$ACCESS_LOG"
    fi
    printf 'OVERALL=SKIP:topology_unsupported\n'
} >> "$EV"
echo "OVERALL: SKIP (topology_unsupported) — Squid access.log not readable; authoritative TCP_*HIT unverifiable (client-side Via/Age captured as supplementary evidence)"
ab_skip_with_reason "Squid cache TCP_*HIT (access.log $ACCESS_LOG not readable)" "topology_unsupported"
exit 3
