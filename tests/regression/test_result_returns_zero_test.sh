#!/bin/sh
#######################################################################
# §11.4.135 regression guard — BUGFIX-0003
# tests/run-tests.sh `test_result` must return 0 (no set -e suite abort)
#
# Purpose:
#   Prove the test-suite reporting helper `test_result` ALWAYS returns 0,
#   even on a FAIL with no message. If it returns non-zero (the pre-fix
#   bug: the `[[ -n "$message" ]] &&` short-circuit was the last command),
#   then whenever such a test_result is the LAST command of a test
#   function, that function returns non-zero and `set -euo pipefail`
#   aborts the whole suite mid-run — most tests never execute and no
#   summary prints (BUGFIX-0003, sibling of BUGFIX-0001).
#
# What it actually does (NOT a grep):
#   GREEN — extracts the REAL `test_result` from tests/run-tests.sh, runs
#   it under `set -euo pipefail` with a no-message FAIL, and asserts the
#   process survives (exit 0).
#   RED   — runs a faithful PRE-FIX replica (ends on the bare `&&`
#   short-circuit) and asserts it aborts.
#
# §11.4.115 polarity switch (RED_MODE):
#   RED_MODE=0 (default GREEN guard) — PASS iff the REAL test_result
#              survives a no-message FAIL under set -e (defect ABSENT).
#   RED_MODE=1 (reproduce) — PASS iff the pre-fix replica aborts under
#              set -e (defect REPRODUCED).
#
# Usage:
#   tests/regression/test_result_returns_zero_test.sh
#   RED_MODE=1 tests/regression/test_result_returns_zero_test.sh
#
# Inputs:   RED_MODE (env, default 0). No CLI args.
# Outputs:  PASS/FAIL verdict + evidence file under
#           qa-results/regression/bugfix0003/. Exit 0 = PASS, 1 = FAIL.
# Side-effects: writes one temp probe script (removed on exit) + one
#               evidence file.
# Dependencies: bash (test_result uses bash `[[ ]]`/`local`), mktemp.
# Cross-references:
#   - Fix: tests/run-tests.sh test_result() `return 0`.
#   - BUGFIX log: docs/issues/fixed/BUGFIXES.md (BUGFIX-0003).
#######################################################################
set -eu

RED_MODE="${RED_MODE:-0}"
REPO_ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
EVID_DIR="$REPO_ROOT/qa-results/regression/bugfix0003"
mkdir -p "$EVID_DIR"
EVID_FILE="$EVID_DIR/test_result_returns_zero.$$.txt"

PROBE="$(mktemp)"
trap 'rm -f "$PROBE"' EXIT INT TERM

{
    echo 'set -euo pipefail'
    echo 'RED=""; GREEN=""; YELLOW=""; NC=""'
    echo 'TESTS_RUN=0; TESTS_PASSED=0; TESTS_FAILED=0'
    if [ "$RED_MODE" = "1" ]; then
        # Faithful PRE-FIX replica: last command is the bare `&&` short-circuit,
        # which returns 1 when $message is empty (exactly the BUGFIX-0003 defect).
        printf '%s\n' \
            'test_result() {' \
            '    local name="$1"; local result="$2"; local message="${3:-}"' \
            '    if [[ "$result" == "PASS" ]]; then' \
            '        echo "PASS: $name"' \
            '    else' \
            '        echo "FAIL: $name"' \
            '        [[ -n "$message" ]] && echo "  -> $message"' \
            '    fi' \
            '}'
    else
        # Extract the REAL, current test_result from the tracked suite.
        awk '/^test_result\(\) \{/{f=1} f{print} /^\}/{if(f){exit}}' \
            "$REPO_ROOT/tests/run-tests.sh"
    fi
    echo 'test_result "guard probe" "FAIL"'   # FAIL with NO message = the trigger
    echo 'echo __SURVIVED__'
} >"$PROBE"

probe_out="$(bash "$PROBE" 2>&1)" && probe_rc=0 || probe_rc=$?
survived=no
case "$probe_out" in
    *__SURVIVED__*) survived=yes ;;
esac

verdict=FAIL
exit_code=1
if [ "$RED_MODE" = "1" ]; then
    # RED: PASS iff defect reproduced (replica aborted — did NOT survive).
    if [ "$survived" = "no" ] && [ "$probe_rc" -ne 0 ]; then
        verdict=PASS; exit_code=0
        msg="RED reproduced: pre-fix test_result aborts under set -e on a no-message FAIL (rc=$probe_rc, SURVIVED absent)"
    else
        msg="RED could-not-reproduce: pre-fix replica survived (rc=$probe_rc) — finding per 11.4.7"
    fi
else
    # GREEN guard: PASS iff the REAL test_result survives a no-message FAIL.
    if [ "$survived" = "yes" ] && [ "$probe_rc" -eq 0 ]; then
        verdict=PASS; exit_code=0
        msg="GREEN: real test_result returns 0 on a no-message FAIL (suite does not abort under set -e)"
    else
        msg="REGRESSION: test_result aborts the suite on a no-message FAIL (rc=$probe_rc, SURVIVED=$survived) — BUGFIX-0003 reverted"
    fi
fi

{
    echo "BUGFIX-0003 regression guard — test_result must return 0"
    echo "timestamp_utc: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "RED_MODE: $RED_MODE"
    echo "probe_rc: $probe_rc"
    echo "survived: $survived"
    echo "verdict: $verdict"
    echo "detail: $msg"
} >"$EVID_FILE"

echo "[$verdict] BUGFIX-0003 test_result-returns-zero (RED_MODE=$RED_MODE): $msg"
echo "evidence: $EVID_FILE"
exit "$exit_code"
