#!/usr/bin/env bash
# =============================================================================
# run_proxy_challenges.sh — forward-proxy Challenge-bank runner
# -----------------------------------------------------------------------------
# Purpose:      Execute the helix_proxy forward-proxy anti-bluff Challenge bank
#               (HTTP forward, SOCKS5 forward, Squid cache) against the LIVE
#               running proxy under host-safety resource caps, tally
#               PASS/FAIL/SKIP, and write a summary + per-challenge evidence
#               under qa-results/challenges/<run-ts>/. Exits non-zero ONLY on a
#               real FAIL (a §11.4.1 script-crash or an unexpected rc is treated
#               as FAIL, never silently passed); an honest SKIP is NOT a failure.
# Usage:        bash challenges/scripts/run_proxy_challenges.sh
# Inputs:       The three sibling challenge scripts; env passed through:
#                    HTTP_PROXY_URL / HTTP_PROXY_PORT / SOCKS5_PROXY / SOCKS5_PORT
#                    / CACHE_URL / SQUID_ACCESS_LOG / LOG_DIR / CURL_MAX_TIME.
# Outputs:      qa-results/challenges/<run-ts>/summary.txt   (tally + verdicts),
#               qa-results/challenges/<run-ts>/<name>.log    (per-challenge stdout),
#               qa-results/challenges/<run-ts>/evidence/...  (captured evidence).
#               Exit: 0 = no FAIL (all PASS/SKIP), 1 = >=1 FAIL.
# Side-effects: Runs each challenge under `GOMAXPROCS=2 nice -n 19 ionice -c 3`
#               (host-safety §12.6/§12.9; caps degrade gracefully if a tool is
#               absent). Live curl only — never touches any container.
# Dependencies: bash; the three challenge scripts; nice/ionice (optional).
# Cross-refs:   Constitution §11.4.27 (Challenges), §11.4.69, §11.4.1 (crash=FAIL),
#               §12.6/§12.9 (host resource caps), §11.4.89 (bounded execution).
# Shell:        POSIX-clean body — parses under `sh -n` AND `bash -n` (§11.4.67).
# =============================================================================

set -u

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

RUN_TS=$(date -u +%Y%m%dT%H%M%SZ)
RUN_DIR="$REPO_ROOT/qa-results/challenges/$RUN_TS"
EVIDENCE_DIR="$RUN_DIR/evidence"
SUMMARY="$RUN_DIR/summary.txt"
mkdir -p "$EVIDENCE_DIR"

# --- Host-safety resource caps (degrade gracefully if a tool is absent) -----
GOMAXPROCS=2
export GOMAXPROCS
export CHALLENGE_EVIDENCE_DIR="$EVIDENCE_DIR"

CAPS=""
if command -v nice >/dev/null 2>&1;   then CAPS="nice -n 19"; fi
if command -v ionice >/dev/null 2>&1; then CAPS="$CAPS ionice -c 3"; fi

CHALLENGES="proxy_forward_http_challenge.sh proxy_socks5_challenge.sh proxy_cache_challenge.sh"

N_PASS=0; N_FAIL=0; N_SKIP=0
RESULT_LINES=""

{
    printf '=== helix_proxy forward-proxy Challenge bank — run %s ===\n' "$RUN_TS"
    printf 'repo=%s\n' "$REPO_ROOT"
    printf 'caps=GOMAXPROCS=%s %s\n' "$GOMAXPROCS" "$CAPS"
    printf 'evidence_dir=%s\n\n' "$EVIDENCE_DIR"
} | tee "$SUMMARY"

for ch in $CHALLENGES; do
    ch_path="$SCRIPT_DIR/$ch"
    name=$(basename "$ch" .sh)
    log="$RUN_DIR/$name.log"
    if [ ! -f "$ch_path" ]; then
        echo "--- $name: MISSING ($ch_path) -> FAIL ---" | tee -a "$SUMMARY"
        N_FAIL=$((N_FAIL + 1))
        RESULT_LINES="$RESULT_LINES\n$name  FAIL  (script missing)"
        continue
    fi
    echo "--- running $name ---" | tee -a "$SUMMARY"
    # shellcheck disable=SC2086
    $CAPS bash "$ch_path" > "$log" 2>&1
    rc=$?
    cat "$log"
    case "$rc" in
        0) verdict="PASS"; N_PASS=$((N_PASS + 1)) ;;
        3) verdict="SKIP"; N_SKIP=$((N_SKIP + 1)) ;;
        *) verdict="FAIL"; N_FAIL=$((N_FAIL + 1)) ;;
    esac
    over=$(grep -E '^OVERALL' "$log" 2>/dev/null | tail -n1)
    [ -n "$over" ] || over="(no OVERALL line; rc=$rc)"
    echo "--- $name -> $verdict (rc=$rc) $over ---" | tee -a "$SUMMARY"
    echo | tee -a "$SUMMARY"
    RESULT_LINES="$RESULT_LINES\n$name  $verdict  rc=$rc  $over"
done

TOTAL=$((N_PASS + N_FAIL + N_SKIP))
{
    printf '=== TALLY (%s) ===\n' "$RUN_TS"
    printf 'total=%d  PASS=%d  FAIL=%d  SKIP=%d\n' "$TOTAL" "$N_PASS" "$N_FAIL" "$N_SKIP"
    # shellcheck disable=SC2059
    printf "$RESULT_LINES\n"
    printf '\nevidence_dir=%s\n' "$EVIDENCE_DIR"
    if [ "$N_FAIL" -gt 0 ]; then
        printf 'RESULT: FAIL (%d real proxy defect(s))\n' "$N_FAIL"
    else
        printf 'RESULT: OK (no FAIL; PASS=%d SKIP=%d — SKIPs are honest non-applicable per §11.4.3)\n' \
            "$N_PASS" "$N_SKIP"
    fi
} | tee -a "$SUMMARY"

echo
echo "summary: $SUMMARY"

[ "$N_FAIL" -eq 0 ] || exit 1
exit 0
