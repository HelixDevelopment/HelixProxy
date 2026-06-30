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
# Baseline:     BENCH_BASELINE (default qa-results/p9-harness/bench_baseline.p95);
#               absent => budget-only check + the run writes the file so future
#               runs gain the regression check.
# RED_MODE:     §11.4.115. RED_MODE=1 expects p95 > budget (regression
#               reproduced); RED_MODE=0 GREEN guard asserts within budget.
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

SUITE="benchmark"
RUN_ID=$(date -u +%Y%m%dT%H%M%SZ)
QA="$(ac_qa_dir p9-harness)/${SUITE}_${RUN_ID}"
mkdir -p "$QA"
PROXY=$(dyn_stack_proxy_url)
N=${BENCH_N:-200}
TARGET=${BENCH_TARGET:-http://target-a.internal/}
BUDGET=${BENCH_P95_BUDGET_MS:-800}
REGRESS_PCT=${BENCH_REGRESS_PCT:-25}
BASELINE=${BENCH_BASELINE:-$(ac_qa_dir p9-harness)/bench_baseline.p95}
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
regress=""
if [ -n "$base_p95" ] && [ "$base_p95" -gt 0 ] 2>/dev/null; then
    regress=$(awk -v a="$p95" -v b="$base_p95" 'BEGIN { printf "%d", ((a - b) * 100) / b }')
fi
{
    printf 'p50=%sms p95=%sms p99=%sms budget_p95=%sms baseline_p95=%sms regress_pct=%s\n' \
        "$p50" "$p95" "$p99" "$BUDGET" "${base_p95:-none}" "${regress:-n/a}"
} > "$QA/benchmark.evidence"
cat "$SERIES" >> "$QA/benchmark.evidence"

if dyn_red_mode; then
    if [ "$p95" -gt "$BUDGET" ]; then
        ab_pass_with_evidence "$SUITE RED-baseline reproduced p95 regression (${p95}ms > ${BUDGET}ms)" "$QA/benchmark.evidence"
        exit $?
    fi
    ac_fail "$SUITE RED-baseline" "[reason: p95=${p95}ms within budget — no regression to reproduce]"
    exit 1
fi

within_budget=0
[ "$p95" -le "$BUDGET" ] && [ "$p95" -gt 0 ] && within_budget=1
no_regress=1
if [ -n "$regress" ] && [ "$regress" -gt "$REGRESS_PCT" ] 2>/dev/null; then no_regress=0; fi

if [ "$within_budget" -eq 1 ] && [ "$no_regress" -eq 1 ]; then
    # Record / refresh the baseline for future regression checks.
    printf '%s\n' "$p95" > "$BASELINE" 2>/dev/null || true
    ab_pass_with_evidence "$SUITE p95=${p95}ms <= ${BUDGET}ms, no regression" "$QA/benchmark.evidence"
    exit $?
fi
ac_fail "$SUITE" "[reason: p95=${p95}ms budget=${BUDGET}ms within=$within_budget regress=${regress:-n/a}% (max ${REGRESS_PCT}%) — see $QA/benchmark.evidence]"
exit 1
