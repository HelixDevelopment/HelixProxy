#!/usr/bin/env bash
# =============================================================================
# proxy_cache_challenge.sh — Squid cache-HIT anti-bluff Challenge
# -----------------------------------------------------------------------------
# Purpose:      Prove the LIVE HTTP proxy (localhost:34128) caches. A reliably-
#               cacheable plain-HTTP URL (default: a Debian mirror README) is
#               fetched TWICE through the proxy; the AUTHORITATIVE proof is a Squid
#               TCP_*HIT result code for THAT url in the Squid access.log (asserted
#               via evidence.sh assert_cache_hit) — an X-Cache header or an Age
#               field alone is forgeable and is NEVER accepted as the verdict
#               (§11.4.69/§11.4.107 discipline). The access.log is read INSIDE the
#               Squid container by default (`podman exec proxy-squid` — the
#               rootless-container log is owned by a subuid, mode 0640, so it is
#               typically NOT host-readable), falling back to a host-readable path;
#               the length is snapshotted BEFORE the fetches and only the appended
#               lines are inspected (a stale HIT can never satisfy the gate,
#               mirroring proxy_acl_security.sh S4). If NO log source is reachable,
#               the challenge SKIPs with the closed-set reason topology_unsupported
#               (§11.4.3) — it does NOT fake a PASS. The client-side double-fetch
#               (response codes + Via + Age headers) is captured as supplementary
#               evidence either way.
# Usage:        bash challenges/scripts/proxy_cache_challenge.sh
#               CHALLENGE_EVIDENCE_DIR=<dir> bash .../proxy_cache_challenge.sh
# Inputs:       Live curl through http://localhost:34128 (READ-ONLY client use);
#               the Squid access.log read inside the container (READ-ONLY) or from
#               the host fallback path resolved from the project config.
#               Env: HTTP_PROXY_URL (default http://localhost:34128),
#                    HTTP_PROXY_PORT (default 34128),
#                    CACHE_URL (default http://ftp.debian.org/debian/README),
#                    SQUID_CONTAINER (default proxy-squid — authoritative log read),
#                    SQUID_CONTAINER_LOG (default /var/log/squid/access.log),
#                    SQUID_ACCESS_LOG (override the resolved HOST fallback path),
#                    LOG_DIR (default ./logs; container /var/log/squid maps here),
#                    CHALLENGE_EVIDENCE_DIR (default qa-results/challenges/<ts>),
#                    CURL_MAX_TIME (default 20).
# Outputs:      A connectivity-precondition verdict, then either the assert_cache_hit
#               verdict (PASS/FAIL) or an honest topology SKIP; a captured evidence
#               file <evdir>/cache/cache_evidence.txt.
#               Exit: 0 = PASS, 1 = FAIL (proxy defect / cacheable url never HITs),
#               3 = SKIP (outage OR access.log unreadable — honest, never faked).
# Side-effects: Live curl only. Never stops/starts/restarts/reconfigures any
#               container. Reads (never writes) the Squid access.log via a
#               READ-ONLY `podman exec ... wc -l/tail` (or the host file). Creates
#               the evidence directory + files under qa-results/.
# Dependencies: bash, curl, awk, grep; podman (for the authoritative container-log
#               read; absent -> host fallback -> honest SKIP); tests/lib/evidence.sh.
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
PROXY_URL=${HTTP_PROXY_URL:-http://localhost:34128}
PROXY_PORT=${HTTP_PROXY_PORT:-34128}
# Default is a reliably-cacheable plain-HTTP static asset (a Debian mirror README
# served with a cache-permitting Cache-Control) — fetched twice it yields a Squid
# TCP_MEM_HIT. Overridable for other topologies. NOTE: many origins forbid caching
# (example.com, code.jquery.com return TCP_MISS twice; a 204/301 is never a HIT) —
# picking such a url is a legitimate way to negate the gate (no HIT -> not PASS).
CACHE_URL=${CACHE_URL:-http://ftp.debian.org/debian/README}
MAX_TIME=${CURL_MAX_TIME:-20}
# Authoritative access.log is read INSIDE the Squid container by default (the
# rootless-container log is owned by a subuid and is typically NOT host-readable).
SQUID_CTR=${SQUID_CONTAINER:-proxy-squid}
SQUID_CTR_LOG=${SQUID_CONTAINER_LOG:-/var/log/squid/access.log}
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

# --- Resolve the AUTHORITATIVE access.log source + snapshot its length -------
# Prefer reading the log INSIDE the Squid container (the log is owned by a
# rootless-container subuid, mode 0640 — typically NOT host-readable); fall back
# to a host-readable path. Mirrors tests/security/proxy_acl_security.sh S4: read
# the current length BEFORE the fetches so we later inspect ONLY the lines this
# run appends (a stale HIT from an earlier run can never satisfy the assertion).
log_len() {   # $1 = container|host -> current line-count, or empty on failure
    case "$1" in
        container) podman exec "$SQUID_CTR" sh -c "wc -l < '$SQUID_CTR_LOG'" 2>/dev/null | tr -dc '0-9' ;;
        host)      wc -l < "$ACCESS_LOG" 2>/dev/null | tr -dc '0-9' ;;
    esac
}
log_tail_from() {   # $1 = container|host  $2 = after-this-line-number
    _from=$(( $2 + 1 ))
    case "$1" in
        container) podman exec "$SQUID_CTR" sh -c "tail -n +$_from '$SQUID_CTR_LOG'" 2>/dev/null ;;
        host)      tail -n +"$_from" "$ACCESS_LOG" 2>/dev/null ;;
    esac
}
LOG_SRC=none; LOG_BEFORE=0
if _lb=$(log_len container) && [ -n "$_lb" ]; then
    LOG_SRC=container; LOG_BEFORE=$_lb
elif [ -r "$ACCESS_LOG" ] && _lb=$(log_len host) && [ -n "$_lb" ]; then
    LOG_SRC=host; LOG_BEFORE=$_lb
fi

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
    printf 'resolved_access_log=%s (host fallback)\n' "$ACCESS_LOG"
    printf 'log_source=%s  container=%s  container_log=%s  log_lines_before_fetch=%s\n' \
        "$LOG_SRC" "$SQUID_CTR" "$SQUID_CTR_LOG" "$LOG_BEFORE"
    printf 'authoritative proof = Squid TCP_*HIT for this url in access.log;\n'
    printf 'Via/Age headers captured as SUPPLEMENTARY only (forgeable, never the verdict).\n'
} > "$EV"

echo "=== $CHALLENGE_NAME challenge ==="
echo "proxy=$PROXY_URL  cache_url=$CACHE_URL  log_source=$LOG_SRC (container=$SQUID_CTR host=$ACCESS_LOG)"
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
# Inspect ONLY the lines this run appended (snapshot taken before the fetches) so
# a stale HIT from an earlier run can never satisfy the assertion.
if [ "$LOG_SRC" != none ]; then
    APPENDED="$OUT_DIR/access_appended.log"
    log_tail_from "$LOG_SRC" "$LOG_BEFORE" > "$APPENDED" 2>/dev/null || : > "$APPENDED"
    _nappended=$(wc -l < "$APPENDED" 2>/dev/null | tr -dc '0-9'); [ -n "$_nappended" ] || _nappended=0
    echo "[cache] reading authoritative access.log via $LOG_SRC (lines after $LOG_BEFORE; $_nappended appended) — asserting TCP_*HIT for $CACHE_URL"
    HIT_OUT=$(assert_cache_hit "$APPENDED" "$CACHE_URL")
    HIT_RC=$?
    {
        printf '\n--- authoritative assert_cache_hit (source=%s, appended lines only) ---\n' "$LOG_SRC"
        printf 'log_lines_before_fetch=%s appended_lines=%s\n' "$LOG_BEFORE" "$_nappended"
        printf 'appended result codes for %s:\n' "$CACHE_URL"
        awk -v u="$CACHE_URL" '{c="";r="";for(i=1;i<=NF;i++){if($i ~ /^TCP_[A-Z_]*\/[0-9]+$/)c=$i; if($i=="GET"||$i=="HEAD")r=$(i+1)} if(r==u && c!="")print "  "c}' "$APPENDED" 2>/dev/null
        printf '%s\n' "$HIT_OUT"
    } >> "$EV"
    echo "$HIT_OUT"
    if [ "$HIT_RC" -eq 0 ]; then
        printf 'OVERALL=PASS\n' >> "$EV"
        ab_pass_with_evidence "Squid cache HIT proven via access.log TCP_*HIT for $CACHE_URL (source=$LOG_SRC)" "$EV"
        exit 0
    fi
    echo "OVERALL: FAIL — no TCP_*HIT for a cacheable URL fetched twice"
    printf 'OVERALL=FAIL (no TCP_*HIT in appended access.log lines)\n' >> "$EV"
    exit 1
fi

# No authoritative log source (container exec failed AND host log unreadable)
# -> honest topology SKIP (§11.4.3). Never a faked PASS.
{
    printf '\n--- authoritative proof UNAVAILABLE ---\n'
    printf 'no readable Squid access.log: container %s exec failed AND host %s not readable by %s (uid %s)\n' \
        "$SQUID_CTR" "$ACCESS_LOG" "$(id -un)" "$(id -u)"
    if [ -e "$ACCESS_LOG" ]; then
        printf 'host access.log ownership/mode (rootless-container subuid, not host-readable):\n'
        ls -ln "$ACCESS_LOG" 2>/dev/null | sed 's/^/  /'
    fi
    printf 'OVERALL=SKIP:topology_unsupported\n'
} >> "$EV"
echo "OVERALL: SKIP (topology_unsupported) — Squid access.log not reachable via container ($SQUID_CTR) or host ($ACCESS_LOG); authoritative TCP_*HIT unverifiable (client-side Via/Age captured as supplementary evidence)"
ab_skip_with_reason "Squid cache TCP_*HIT (access.log unreachable via $SQUID_CTR and host $ACCESS_LOG)" "topology_unsupported"
exit 3
