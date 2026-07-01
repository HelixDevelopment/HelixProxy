#!/usr/bin/env bash
# =============================================================================
# proxy_socks5_challenge.sh — SOCKS5 forward-proxy anti-bluff Challenge
# -----------------------------------------------------------------------------
# Purpose:      Prove the LIVE SOCKS5 proxy (localhost:51080) actually forwards
#               a real end-user journey — a plain-HTTP GET to a 204 endpoint AND
#               an HTTPS GET — driven through `curl --proxy socks5://...`. The
#               THROUGH-PROXY %{http_code} must match the expected code, cross-
#               checked against a DIRECT fetch of the SAME URL so a third-party
#               outage SKIPs (§11.4.1/§11.4.3) and a proxy-broken-but-site-
#               reachable-directly case FAILs (§11.4.68). Every PASS cites a
#               captured evidence file (§11.4.69/§11.4.2/§11.4.5).
# Usage:        bash challenges/scripts/proxy_socks5_challenge.sh
#               CHALLENGE_EVIDENCE_DIR=<dir> bash .../proxy_socks5_challenge.sh
# Inputs:       Live curl through socks5://localhost:51080 (READ-ONLY client).
#               Env: SOCKS5_PROXY (default socks5://localhost:51080),
#                    SOCKS5_PORT (default 51080),
#                    CHALLENGE_EVIDENCE_DIR (default qa-results/challenges/<ts>),
#                    CURL_MAX_TIME (default 20).
# Outputs:      One structured verdict per sub-probe + an overall verdict line;
#               a captured evidence file <evdir>/socks5/socks5_evidence.txt.
#               Exit: 0 = PASS, 1 = FAIL (real proxy defect), 3 = SKIP (honest
#               non-applicable: third-party/network outage, §11.4.3).
# Side-effects: Live curl only. Never stops/restarts/reconfigures any container.
#               Creates the evidence directory + file under qa-results/.
# Dependencies: bash, curl (with SOCKS5 support), awk, grep;
#               tests/lib/evidence.sh (sourced).
# Cross-refs:   Constitution §11.4.27 (Challenges), §11.4.69, §11.4.1, §11.4.68,
#               §11.4.2/§11.4.5, evidence.sh proxy_conn_verdict / port_is_listening.
# Shell:        POSIX-clean body — parses under `sh -n` AND `bash -n` (§11.4.67).
# =============================================================================

set -u

CHALLENGE_NAME="proxy_socks5"

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
SOCKS_PROXY=${SOCKS5_PROXY:-socks5://localhost:51080}
SOCKS_PORT=${SOCKS5_PORT:-51080}
MAX_TIME=${CURL_MAX_TIME:-20}
RUN_TS=$(date -u +%Y%m%dT%H%M%SZ)
EVIDENCE_DIR=${CHALLENGE_EVIDENCE_DIR:-$REPO_ROOT/qa-results/challenges/$RUN_TS}
OUT_DIR="$EVIDENCE_DIR/socks5"
mkdir -p "$OUT_DIR"
EV="$OUT_DIR/socks5_evidence.txt"

N_PASS=0; N_FAIL=0; N_SKIP=0

# curl_code <proxy|direct> <url> <hdrfile-or-empty> -> http_code (000 on failure)
curl_code() {
    _mode=$1; _url=$2; _hdr=$3
    if [ "$_mode" = "proxy" ]; then
        if [ -n "$_hdr" ]; then
            curl -sS -D "$_hdr" -o /dev/null -w '%{http_code}' \
                --max-time "$MAX_TIME" --proxy "$SOCKS_PROXY" "$_url" 2>/dev/null || printf '000'
        else
            curl -sS -o /dev/null -w '%{http_code}' \
                --max-time "$MAX_TIME" --proxy "$SOCKS_PROXY" "$_url" 2>/dev/null || printf '000'
        fi
    else
        curl -sS -o /dev/null -w '%{http_code}' \
            --max-time "$MAX_TIME" "$_url" 2>/dev/null || printf '000'
    fi
}

run_probe() {
    _label=$1; _url=$2; _expected=$3
    _hdr="$OUT_DIR/${_label}_response_headers.txt"
    : > "$_hdr"
    _pcode=$(curl_code proxy "$_url" "$_hdr"); [ -n "$_pcode" ] || _pcode=000
    _dcode=$(curl_code direct "$_url" "");      [ -n "$_dcode" ] || _dcode=000
    if port_is_listening "$SOCKS_PORT"; then _listen=yes; else _listen=no; fi
    _verdict=$(proxy_conn_verdict "$_pcode" "$_dcode" "$_expected" "$_listen")

    {
        printf '\n--- sub-probe: %s ---\n' "$_label"
        printf 'url=%s\n' "$_url"
        printf 'expected_codes=%s\n' "$_expected"
        printf 'socks_http_code=%s  direct_http_code=%s  port_%s_listening=%s\n' \
            "$_pcode" "$_dcode" "$SOCKS_PORT" "$_listen"
        printf 'verdict=%s\n' "$_verdict"
        printf 'response_headers (through socks5):\n'
        grep -iE '^HTTP/|^Via:|^Cache-Control:|^Server:|^Content-Type:' "$_hdr" 2>/dev/null \
            | sed 's/^/  /' || true
    } >> "$EV"

    case "$_verdict" in
        PASS)
            printf '[%s] PASS socks=%s direct=%s (expected %s)\n' "$_label" "$_pcode" "$_dcode" "$_expected"
            N_PASS=$((N_PASS + 1)) ;;
        FAIL)
            printf '[%s] FAIL socks=%s but direct=%s reachable (expected %s) — proxy defect\n' \
                "$_label" "$_pcode" "$_dcode" "$_expected"
            N_FAIL=$((N_FAIL + 1)) ;;
        SKIP:*)
            _reason=${_verdict#SKIP:}
            printf '[%s] SKIP (%s) socks=%s direct=%s\n' "$_label" "$_reason" "$_pcode" "$_dcode"
            N_SKIP=$((N_SKIP + 1)) ;;
    esac
}

{
    printf '=== %s challenge — run %s ===\n' "$CHALLENGE_NAME" "$RUN_TS"
    printf 'socks_proxy=%s  socks_port=%s  max_time=%ss\n' "$SOCKS_PROXY" "$SOCKS_PORT" "$MAX_TIME"
    printf 'discipline: socks code cross-checked vs DIRECT fetch of same URL\n'
} > "$EV"

echo "=== $CHALLENGE_NAME challenge ==="
echo "socks=$SOCKS_PROXY  evidence=$EV"

# Sub-probe 1: plain-HTTP 204 through SOCKS5.
run_probe "socks_204" "http://www.gstatic.com/generate_204" "204"
# Sub-probe 2: HTTPS through SOCKS5.
run_probe "socks_https" "https://example.com/" "200"

{
    printf '\n--- aggregate: pass=%d fail=%d skip=%d ---\n' "$N_PASS" "$N_FAIL" "$N_SKIP"
} >> "$EV"

echo
if [ "$N_FAIL" -gt 0 ]; then
    echo "OVERALL=FAIL ($N_FAIL sub-probe(s) proved a real proxy defect)"
    printf 'OVERALL=FAIL\n' >> "$EV"
    exit 1
fi
if [ "$N_PASS" -gt 0 ]; then
    printf 'OVERALL=PASS\n' >> "$EV"
    echo "OVERALL=PASS"
    ab_pass_with_evidence "SOCKS5 proxy forwards real traffic (204 + HTTPS) via $SOCKS_PROXY" "$EV"
    exit 0
fi
printf 'OVERALL=SKIP:network_unreachable_external\n' >> "$EV"
echo "OVERALL=SKIP:network_unreachable_external"
ab_skip_with_reason "SOCKS5 proxy (no reachable endpoint to prove forwarding)" "network_unreachable_external"
exit 3
