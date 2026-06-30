#!/usr/bin/env bash
# =============================================================================
# run_analyzer_selftests.sh — master self-validation for all 6 dynamic analyzers
# -----------------------------------------------------------------------------
# Purpose:      Run every dynamic data-plane analyzer's built-in self-test
#               (golden-good MUST PASS, golden-bad MUST FAIL) and aggregate the
#               result. This is the §11.4.107(10) self-validated-analyzer proof
#               and is RUNNABLE TODAY against the bundled fixtures — no live
#               stack, no network. An analyzer that passes its own golden-bad is
#               a bluff gate and this runner exits non-zero.
# Usage:        bash tests/dynamic/analyzers/run_analyzer_selftests.sh
# Output:       Per-analyzer TAP on stdout + an aggregate verdict, tee'd to
#               qa-results/p9-harness/<run-id>/analyzer_selftests.tap (gitignored).
#               Exit 0 iff ALL six analyzers self-validate.
# Dependencies: bash/sh, awk, grep, tr.
# Cross-refs:   Constitution §11.4 / §11.4.69 / §11.4.107 / §1.1; design §13/§14.
# Shell:        POSIX-clean (sh -n + bash -n, §11.4.67).
# =============================================================================
DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$DIR/../../.." && pwd)
RUN_ID=$(date -u +%Y%m%dT%H%M%SZ)
QA_DIR="$REPO_ROOT/qa-results/p9-harness/$RUN_ID"
mkdir -p "$QA_DIR"
OUT="$QA_DIR/analyzer_selftests.tap"

ANALYZERS="
no_leak_analyzer.sh
graceful_503_analyzer.sh
egress_neq_host_analyzer.sh
xcache_hit_analyzer.sh
dns_no_plaintext_53_analyzer.sh
auth_407_analyzer.sh
"

TOTAL=0
FAILED=0

{
printf '# dynamic analyzer self-validation — run-id %s\n' "$RUN_ID"
printf '# repo: %s\n' "$REPO_ROOT"
printf '#\n'
for a in $ANALYZERS; do
    [ -n "$a" ] || continue
    script="$DIR/$a"
    TOTAL=$((TOTAL + 1))
    printf '# ===== %s =====\n' "$a"
    if [ ! -f "$script" ]; then
        printf 'not ok %d - %s MISSING\n' "$TOTAL" "$a"
        FAILED=$((FAILED + 1))
        continue
    fi
    body=$(sh "$script" --selftest 2>&1)
    rc=$?
    printf '%s\n' "$body"
    if [ "$rc" -eq 0 ]; then
        printf 'ok %d - %s self-validated (golden-good PASS + golden-bad FAIL)\n' "$TOTAL" "$a"
    else
        printf 'not ok %d - %s self-test FAILED (rc=%d)\n' "$TOTAL" "$a" "$rc"
        FAILED=$((FAILED + 1))
    fi
    printf '#\n'
done
printf '1..%d\n' "$TOTAL"
printf '# analyzers=%d self_validated=%d failed=%d\n' "$TOTAL" "$((TOTAL - FAILED))" "$FAILED"
if [ "$FAILED" -eq 0 ]; then
    printf '# RESULT: ALL %d DYNAMIC ANALYZERS SELF-VALIDATED — none is a bluff gate\n' "$TOTAL"
else
    printf '# RESULT: %d ANALYZER(S) FAILED SELF-VALIDATION — do NOT ship\n' "$FAILED"
fi
} | tee "$OUT"

printf '\nAnalyzer self-test artefact: %s\n' "$OUT" >&2
if grep -q '^not ok ' "$OUT"; then
    exit 1
fi
exit 0
