#!/usr/bin/env bash
# =============================================================================
# run_all_suites.sh — orchestrate the dynamic data-plane test-type suites
# -----------------------------------------------------------------------------
# Purpose:      Run every §11.4.169 dynamic data-plane suite (stress, chaos,
#               concurrency/race, ddos/flood, memory soak, benchmark) and
#               aggregate PASS / FAIL / SKIP. Suites drive the live `dynamic`
#               stack; when it is absent (today — design-only) every suite emits
#               an HONEST §11.4.69 SKIP-with-reason and this orchestrator records
#               it as SKIP (never a fake PASS). Exit 0 iff there is NO FAIL.
# Usage:        bash tests/dynamic/suites/run_all_suites.sh
#               HELIX_DYNAMIC_STACK=1 HELIX_PROXY_URL=... [RED_MODE=1] bash ...
# Output:       Per-suite verdict on stdout + an aggregate, tee'd to
#               qa-results/p9-harness/<run-id>/suite_results.txt (gitignored).
#               Exit 0 = no FAIL (all PASS or honest SKIP); 1 = >=1 FAIL.
# Shell:        POSIX-clean (sh -n + bash -n, §11.4.67).
# Cross-refs:   §11.4.69 / §11.4.85 / §11.4.169 / §11.4.115; design §13.
# =============================================================================
DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$DIR/../../.." && pwd)
RUN_ID=$(date -u +%Y%m%dT%H%M%SZ)
QA_DIR="$REPO_ROOT/qa-results/p9-harness/$RUN_ID"
mkdir -p "$QA_DIR"
OUT="$QA_DIR/suite_results.txt"

SUITES="
stress_suite.sh
chaos_suite.sh
concurrency_race_suite.sh
ddos_flood_suite.sh
memory_soak_suite.sh
benchmark_suite.sh
"

PASS=0; FAIL=0; SKIP=0; TOTAL=0

{
printf '# dynamic data-plane suite run — run-id %s (RED_MODE=%s)\n' "$RUN_ID" "${RED_MODE:-0}"
printf '# stack: HELIX_DYNAMIC_STACK=%s proxy=%s\n' "${HELIX_DYNAMIC_STACK:-0}" "${HELIX_PROXY_URL:-<default>}"
printf '#\n'
for s in $SUITES; do
    [ -n "$s" ] || continue
    script="$DIR/$s"
    TOTAL=$((TOTAL + 1))
    printf '# ===== %s =====\n' "$s"
    if [ ! -f "$script" ]; then
        printf 'FAIL: %s [reason: suite script missing]\n' "$s"
        FAIL=$((FAIL + 1))
        continue
    fi
    body=$(sh "$script" 2>&1)
    printf '%s\n' "$body"
    # Classify by the LAST verdict line the suite emitted.
    verdict=$(printf '%s\n' "$body" | grep -E '^(PASS|FAIL|SKIP):' | tail -n 1)
    case "$verdict" in
        PASS:*) PASS=$((PASS + 1)) ;;
        SKIP:*) SKIP=$((SKIP + 1)) ;;
        FAIL:*) FAIL=$((FAIL + 1)) ;;
        *)      FAIL=$((FAIL + 1)); printf 'FAIL: %s [reason: no PASS/FAIL/SKIP verdict emitted]\n' "$s" ;;
    esac
    printf '#\n'
done
printf '# ===== aggregate =====\n'
printf '# suites=%d PASS=%d SKIP=%d FAIL=%d\n' "$TOTAL" "$PASS" "$SKIP" "$FAIL"
if [ "$FAIL" -eq 0 ]; then
    if [ "$PASS" -eq 0 ]; then
        printf '# RESULT: NO FAILURES — all %d suites honest-SKIPped (live dynamic stack absent; run in P10)\n' "$SKIP"
    else
        printf '# RESULT: NO FAILURES — %d PASS (evidence-cited) + %d honest SKIP\n' "$PASS" "$SKIP"
    fi
else
    printf '# RESULT: %d SUITE FAILURE(S) — investigate per §11.4.102\n' "$FAIL"
fi
} | tee "$OUT"

printf '\nSuite results artefact: %s\n' "$OUT" >&2
grep -q '^FAIL:' "$OUT" && exit 1
exit 0
