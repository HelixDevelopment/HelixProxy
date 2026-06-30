#!/usr/bin/env bash
# =============================================================================
# parse_check.sh — §11.4.67 target-shell parseability gate for the dynamic tree
# -----------------------------------------------------------------------------
# Purpose:      Assert every shell script under tests/dynamic/ parses cleanly
#               under BOTH `sh -n` AND `bash -n` (no bash-only construct outside
#               an eval). This is the re-runnable §11.4.67 pre-build gate for the
#               P9 harness; wire it into the project pre_build sweep in P10.
# Usage:        bash tests/dynamic/parse_check.sh
# Output:       One OK/FAIL line per script + a summary, tee'd to
#               qa-results/p9-harness/<run-id>/parse_check.log (gitignored).
#               Exit 0 iff every in-scope script parses under both shells.
# Shell:        POSIX-clean (sh -n + bash -n).
# Cross-refs:   §11.4.67; design §13.
# =============================================================================
DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$DIR/../.." && pwd)
RUN_ID=$(date -u +%Y%m%dT%H%M%SZ)
QA_DIR="$REPO_ROOT/qa-results/p9-harness/$RUN_ID"
mkdir -p "$QA_DIR"
OUT="$QA_DIR/parse_check.log"

TOTAL=0; BAD=0
{
printf '# dynamic-tree parseability gate — run-id %s\n' "$RUN_ID"
# Enumerate every *.sh under tests/dynamic (depth-N).
for f in $(find "$DIR" -type f -name '*.sh' | sort); do
    TOTAL=$((TOTAL + 1))
    e1=$(sh -n "$f" 2>&1); r1=$?
    e2=$(bash -n "$f" 2>&1); r2=$?
    if [ "$r1" -eq 0 ] && [ "$r2" -eq 0 ]; then
        printf 'OK   %s\n' "${f#"$REPO_ROOT"/}"
    else
        printf 'FAIL %s\n' "${f#"$REPO_ROOT"/}"
        [ -n "$e1" ] && printf '  sh -n: %s\n' "$e1"
        [ -n "$e2" ] && printf '  bash -n: %s\n' "$e2"
        BAD=$((BAD + 1))
    fi
done
printf '# scripts=%d clean=%d failed=%d\n' "$TOTAL" "$((TOTAL - BAD))" "$BAD"
if [ "$BAD" -eq 0 ]; then
    printf '# RESULT: ALL %d dynamic scripts parse under sh -n AND bash -n\n' "$TOTAL"
else
    printf '# RESULT: %d script(s) FAILED parseability — fix at source (§11.4.67)\n' "$BAD"
fi
} | tee "$OUT"

grep -q '^FAIL ' "$OUT" && exit 1
exit 0
