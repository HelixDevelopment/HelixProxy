#!/usr/bin/env bash
# =============================================================================
# benchmark_suite.sh — §11.4.169 performance / benchmark (p50/p95/p99 vs baseline)
# -----------------------------------------------------------------------------
# Purpose:      Measure per-request latency through the live `dynamic` stack,
#               compute p50/p95/p99 from real captured per-request times, and
#               assert (a) p95 is within an absolute BUDGET and (b) — when a
#               recorded baseline exists — there is no regression beyond a
#               tolerance vs that baseline. Records the full latency series +
#               percentiles as the captured evidence (§11.4.69); a regression vs
#               baseline is a finding (§11.4.169 benchmarking clause).
# Status:       AUTHORED FOR P10. SKIPs-with-reason today (no live stack) —
#               honest non-evidence, never a fake PASS.
# Baseline:     BENCH_BASELINE (default tests/dynamic/baselines/benchmark_p95.baseline
#               — a COMMITTED, TRACKED path so the ratchet persists across clean
#               runs and actually gates; NOT a gitignored qa-results throwaway,
#               which never persisted and silently disarmed the ratchet). ABSENT
#               => the run SEEDS the committed baseline from THIS real measurement
#               and SKIPs-with-reason — NEVER a silent budget-only PASS
#               (§11.4.169(13) / §11.4.1). PRESENT => compare p95 vs baseline;
#               growth > BENCH_REGRESS_PCT is a regression FAIL (a finding). The
#               baseline is seeded ONCE and NEVER auto-refreshed on PASS (auto-
#               refresh would let regressions ratchet-drift in silently).
# RED_MODE:     §11.4.115. RED_MODE=1 expects p95 > budget (breach reproduced);
#               RED_MODE=0 GREEN guard asserts within budget + no regression.
# Usage:        bash tests/dynamic/suites/benchmark_suite.sh
# Env:          BENCH_N (samples, default 200), BENCH_TARGET (default
#               http://target-a.internal/), BENCH_P95_BUDGET_MS (default 800),
#               BENCH_REGRESS_PCT (max allowed p95 growth vs baseline, default 25).
# Resources:    shell+curl only; bounded sample count; §12.6 60% host ceiling.
# Shell:        POSIX-clean (sh -n + bash -n, §11.4.67).
# Cross-refs:   §11.4.169 / §11.4.24 / §11.4.50 / §11.4.69 / §11.4.115; design §13.
# =============================================================================
DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=/dev/null
. "$DIR/../lib/analyzer_common.sh"

# ----------------------------------------------------------------------------
# bench_regression_verdict — PURE §11.4.169(13) benchmark ratchet classifier.
# No network, no file I/O; extractable + fixture-driven by the standing guard
# tests/regression/benchmark_baseline_ratchet_test.sh (§1.1 / §11.4.135).
# Args:  <p95_ms> <budget_ms> <baseline_p95_ms | 0-or-empty = absent> <regress_pct>
# Prints EXACTLY one of:
#   PASS             p95 within budget AND within tolerance vs the baseline
#   FAIL:budget      p95 unmeasured (<=0) OR exceeds the absolute budget
#   FAIL:regression  p95 grew > regress_pct vs the recorded baseline (a finding)
#   SEED             no usable baseline yet — caller seeds it + SKIPs (NEVER a
#                    silent budget-only PASS)
# ----------------------------------------------------------------------------
bench_regression_verdict() {
    _brv_p95=$1
    _brv_budget=$2
    _brv_base=$3
    _brv_pct=$4
    if [ -z "$_brv_p95" ] || ! [ "$_brv_p95" -gt 0 ] 2>/dev/null; then
        printf 'FAIL:budget\n'; return 0
    fi
    if [ "$_brv_p95" -gt "$_brv_budget" ] 2>/dev/null; then
        printf 'FAIL:budget\n'; return 0
    fi
    if [ -z "$_brv_base" ] || ! [ "$_brv_base" -gt 0 ] 2>/dev/null; then
        printf 'SEED\n'; return 0
    fi
    _brv_growth=$(awk -v a="$_brv_p95" -v b="$_brv_base" 'BEGIN { printf "%d", ((a - b) * 100) / b }')
    if [ "$_brv_growth" -gt "$_brv_pct" ] 2>/dev/null; then
        printf 'FAIL:regression\n'; return 0
    fi
    printf 'PASS\n'; return 0
}

SUITE="benchmark"
RUN_ID=$(date -u +%Y%m%dT%H%M%SZ)
QA="$(ac_qa_dir p9-harness)/${SUITE}_${RUN_ID}"
mkdir -p "$QA"
PROXY=$(dyn_stack_proxy_url)
N=${BENCH_N:-200}
TARGET=${BENCH_TARGET:-http://target-a.internal/}
BUDGET=${BENCH_P95_BUDGET_MS:-800}
REGRESS_PCT=${BENCH_REGRESS_PCT:-25}
BASELINE=${BENCH_BASELINE:-$AC_REPO_ROOT/tests/dynamic/baselines/benchmark_p95.baseline}
SERIES="$QA/latency_ms.series"

printf '# %s suite — run-id %s (RED_MODE=%s) n=%d p95_budget=%dms\n' \
    "$SUITE" "$RUN_ID" "${RED_MODE:-0}" "$N" "$BUDGET"

if dyn_skip_if_no_stack "$SUITE ($N latency samples)"; then
    printf '# NOTE: benchmark requires the live stack (P10). Authored + parse-clean today.\n'
    exit 0
fi

: > "$SERIES"
i=1
while [ "$i" -le "$N" ]; do
    t=$(curl -s --max-time 30 -o /dev/null -w '%{time_total}' -x "$PROXY" "$TARGET" 2>/dev/null || printf '0')
    # Convert seconds (float) to integer milliseconds without bc.
    ms=$(awk -v s="$t" 'BEGIN { printf "%d", (s * 1000) + 0.5 }')
    printf '%d\n' "$ms" >> "$SERIES"
    i=$((i + 1))
done

# Percentiles from the sorted series (nearest-rank).
pcts=$(sort -n "$SERIES" | awk '
    { v[NR] = $1 }
    END {
        n = NR
        if (n == 0) { print "0 0 0"; exit }
        p50 = v[int((50 * n + 99) / 100)]
        p95 = v[int((95 * n + 99) / 100)]
        p99 = v[int((99 * n + 99) / 100)]
        printf "%d %d %d\n", p50, p95, p99
    }')
set -- $pcts
p50=$1; p95=$2; p99=$3

base_p95=""
[ -f "$BASELINE" ] && base_p95=$(awk 'NF{print $1; exit}' "$BASELINE" 2>/dev/null)
{
    printf 'p50=%sms p95=%sms p99=%sms budget_p95=%sms baseline_p95=%sms regress_pct_max=%s%%\n' \
        "$p50" "$p95" "$p99" "$BUDGET" "${base_p95:-none}" "$REGRESS_PCT"
} > "$QA/benchmark.evidence"
cat "$SERIES" >> "$QA/benchmark.evidence"

if dyn_red_mode; then
    # §11.4.115 suite-level RED: reproduce a p95 that breaches the absolute budget.
    if [ "$p95" -gt "$BUDGET" ]; then
        ab_pass_with_evidence "$SUITE RED-baseline reproduced p95 budget breach (${p95}ms > ${BUDGET}ms)" "$QA/benchmark.evidence"
        exit $?
    fi
    ac_fail "$SUITE RED-baseline" "[reason: p95=${p95}ms within budget — no breach to reproduce]"
    exit 1
fi

# §11.4.169(13) regression ratchet vs the COMMITTED baseline (seed-once, no
# auto-refresh drift). The verdict is the PURE, fixture-tested classifier — the
# SAME function the standing guard drives with fixtures (§1.1 / §11.4.135), so a
# regressed measurement can never silently PASS.
verdict=$(bench_regression_verdict "$p95" "$BUDGET" "${base_p95:-0}" "$REGRESS_PCT")
case "$verdict" in
    PASS)
        ab_pass_with_evidence "$SUITE p95=${p95}ms <= ${BUDGET}ms, no regression vs baseline ${base_p95}ms (growth <= ${REGRESS_PCT}%)" "$QA/benchmark.evidence"
        exit $?
        ;;
    SEED)
        # First run with no committed baseline: seed it from THIS real
        # measurement, then SKIP — NEVER a silent budget-only PASS
        # (§11.4.169(13) / §11.4.1). Commit the seeded file to arm the ratchet.
        mkdir -p "$(dirname "$BASELINE")" 2>/dev/null || true
        printf '%s\n' "$p95" > "$BASELINE" 2>/dev/null || true
        ab_skip_with_reason "$SUITE regression ratchet not yet armed — seeded committed baseline ${p95}ms at $BASELINE (commit it to arm)" "feature_disabled_by_config"
        exit $?
        ;;
    FAIL:regression)
        ac_fail "$SUITE regression" "[reason: p95=${p95}ms grew > ${REGRESS_PCT}% vs committed baseline ${base_p95}ms — regression finding, see $QA/benchmark.evidence]"
        exit 1
        ;;
    *)
        ac_fail "$SUITE budget" "[reason: p95=${p95}ms vs budget ${BUDGET}ms (unmeasured or over budget) — see $QA/benchmark.evidence]"
        exit 1
        ;;
esac
