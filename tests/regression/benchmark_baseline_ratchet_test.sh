#!/bin/sh
#######################################################################
# §11.4.135 standing regression guard — benchmark baseline ratchet (F6).
#
# Purpose:
#   Prove tests/dynamic/suites/benchmark_suite.sh's §11.4.169(13) performance
#   ratchet actually COMPARES the measured p95 against a recorded baseline — a
#   regressed measurement MUST FAIL, an in-tolerance one MUST PASS, and a
#   first-run-with-no-baseline MUST SEED-and-SKIP (never a silent budget-only
#   PASS, §11.4.1). Pre-fix, the baseline lived on the gitignored qa-results
#   throwaway path so it never persisted -> the comparison never fired -> every
#   run budget-only-PASSed regardless of a real regression (the §11.4.1 bluff).
#
# What it actually does (extracts the REAL pure classifier — NOT a grep, no
# network, no live benchmarking, no containers):
#   GREEN — drives the REAL bench_regression_verdict() (awk-extracted from the
#           tracked suite) with fixture (p95,budget,baseline,pct) tuples and
#           asserts: in-tolerance -> PASS, regressed -> FAIL:regression,
#           absent-baseline -> SEED, over-budget -> FAIL:budget. The decisive
#           anti-bluff assertion is REGRESS=FAIL:regression — a mutation that
#           lets a regressed number PASS flips it to PASS and FAILs this guard.
#   RED   — runs a faithful PRE-FIX replica (budget-only, no baseline compare)
#           against a 50%-regressed-but-within-budget measurement and asserts it
#           PASSes — the bluff reproduced. A RED that cannot reproduce is a
#           §11.4.7 finding.
#
# §11.4.115 polarity switch (RED_MODE):
#   RED_MODE=0 (default GREEN guard) — PASS iff the real verdict gives
#              PASS + FAIL:regression + SEED + FAIL:budget for the four tuples.
#   RED_MODE=1 (reproduce)           — PASS iff the pre-fix replica returns PASS
#              for the regressed-within-budget measurement (the bluff).
#
# Usage:
#   tests/regression/benchmark_baseline_ratchet_test.sh            # GREEN guard
#   RED_MODE=1 tests/regression/benchmark_baseline_ratchet_test.sh # reproduce
#
# Inputs:   RED_MODE (env, default 0). No CLI args.
# Outputs:  PASS/FAIL verdict on stdout + evidence under
#           qa-results/regression/benchmark_baseline_ratchet/. Exit 0=PASS,1=FAIL.
# Dependencies: sh, awk, bash, mktemp.
# Cross-references:
#   - Fix: tests/dynamic/suites/benchmark_suite.sh bench_regression_verdict() +
#     the SEED/PASS/FAIL tail + committed baseline path
#     tests/dynamic/baselines/benchmark_p95.baseline.
#   - Constitution §11.4.169(13) / §11.4.1 / §11.4.115 / §11.4.135 / §1.1.
#   - docs/scripts/benchmark_baseline_ratchet_test.md.
#   - docs/issues/fixed/BUGFIXES.md — F6.
#######################################################################
set -eu

RED_MODE="${RED_MODE:-0}"
REPO_ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
SUITE_SRC="$REPO_ROOT/tests/dynamic/suites/benchmark_suite.sh"
EVID_DIR="$REPO_ROOT/qa-results/regression/benchmark_baseline_ratchet"
mkdir -p "$EVID_DIR"
EVID_FILE="$EVID_DIR/benchmark_baseline_ratchet.$$.txt"

PROBE="$(mktemp)"
trap 'rm -f "$PROBE"' EXIT INT TERM

{
    echo 'set -u'
    if [ "$RED_MODE" = "1" ]; then
        # Faithful PRE-FIX replica: budget-only, NO baseline comparison (the
        # gitignored-throwaway baseline was never present, so a regression was
        # invisible). A 50%-regressed p95 that is still <= budget wrongly PASSes.
        printf '%s\n' \
            '_prefix_bench_verdict() { if [ "$1" -le "$2" ] && [ "$1" -gt 0 ]; then echo PASS; else echo FAIL; fi; }' \
            'echo "REGRESSED=$(_prefix_bench_verdict 1200 2000)"'
    else
        # Extract the REAL current classifier from the tracked suite and drive it
        # with fixtures: baseline=800ms, budget=2000ms, tolerance=25%.
        awk '/^bench_regression_verdict\(\) \{/{f=1} f{print} /^\}/{if(f){exit}}' \
            "$SUITE_SRC"
        printf '%s\n' \
            'echo "INTOL=$(bench_regression_verdict 850 2000 800 25)"' \
            'echo "REGRESS=$(bench_regression_verdict 1200 2000 800 25)"' \
            'echo "SEEDCASE=$(bench_regression_verdict 850 2000 0 25)"' \
            'echo "BUDGET=$(bench_regression_verdict 2500 2000 800 25)"'
    fi
} >"$PROBE"

probe_out="$(bash "$PROBE" 2>&1)" && probe_rc=0 || probe_rc=$?

verdict=FAIL
exit_code=1
if [ "$RED_MODE" = "1" ]; then
    case "$probe_out" in
        *REGRESSED=PASS*)
            verdict=PASS; exit_code=0
            msg="RED reproduced: pre-fix budget-only logic PASSes a 50%-regressed p95 (1200ms vs an 800ms baseline, still <=2000ms budget) — the §11.4.169(13)/§11.4.1 ratchet bluff, rc=$probe_rc"
            ;;
        *)
            msg="RED could-not-reproduce: pre-fix replica did not PASS the regressed measurement (out=$probe_out, rc=$probe_rc) — finding per §11.4.7"
            ;;
    esac
else
    case "$probe_out" in
        *INTOL=PASS*REGRESS=FAIL:regression*SEEDCASE=SEED*BUDGET=FAIL:budget*)
            verdict=PASS; exit_code=0
            msg="GREEN: real ratchet = PASS(in-tolerance) + FAIL:regression(1200 vs 800 baseline, 50% > 25%) + SEED(no baseline) + FAIL:budget(over 2000ms) — a regressed number cannot PASS"
            ;;
        *)
            msg="REGRESSION: ratchet verdict wrong (out=$probe_out, rc=$probe_rc) — a regressed measurement no longer FAILs, an absent baseline no longer SEEDs, or an in-tolerance one no longer PASSes"
            ;;
    esac
fi

{
    echo "benchmark baseline ratchet regression guard — §11.4.169(13)/§11.4.1/§11.4.115/§11.4.135"
    echo "timestamp_utc: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "RED_MODE: $RED_MODE"
    echo "suite_src: $SUITE_SRC"
    echo "probe_rc: $probe_rc"
    echo "probe_out: $probe_out"
    echo "verdict: $verdict"
    echo "detail: $msg"
} >"$EVID_FILE"

echo "[$verdict] benchmark-baseline-ratchet (RED_MODE=$RED_MODE): $msg"
echo "evidence: $EVID_FILE"
exit "$exit_code"
