#!/usr/bin/env bash
# =============================================================================
# memory_soak_suite.sh — §11.4.169 memory soak (no unbounded growth)
# -----------------------------------------------------------------------------
# Purpose:      Drive a sustained request soak against the live `dynamic` stack
#               while sampling the control-plane / helper RSS, and assert the
#               working set does NOT grow without bound (a leak). Records
#               min/max/first/last/mean RSS (§11.4.24 style) and PASSes only when
#               the post-warmup last sample is within MEM_GROWTH_PCT of the
#               post-warmup baseline (bounded), citing the sample series.
# Status:       AUTHORED FOR P10. SKIPs-with-reason today (no live stack /
#               no RSS-sampling hook) — honest non-evidence, never a fake PASS.
# Sampling:     operator supplies HELIX_MEM_RSS_CMD that prints the summed RSS in
#               KB of the process(es) under test (e.g. the acl-helper + healthd)
#               — config injection §11.4.28; no hardcoded process discovery here.
# RED_MODE:     §11.4.115. RED_MODE=1 expects unbounded growth (leak reproduced);
#               RED_MODE=0 GREEN guard asserts the working set is bounded.
# Usage:        bash tests/dynamic/suites/memory_soak_suite.sh
# Env:          MEM_REQUESTS (default 500), MEM_WARMUP (default 50),
#               MEM_TARGET (default http://target-a.internal/),
#               MEM_GROWTH_PCT (max allowed last-vs-baseline growth %, default 20).
# Resources:    shell+curl only; bounded request count; §12.6 60% host ceiling.
# Shell:        POSIX-clean (sh -n + bash -n, §11.4.67).
# Cross-refs:   §11.4.169 / §11.4.24 / §11.4.85 / §11.4.69 / §11.4.115; design §13.
# =============================================================================
DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=/dev/null
# Idempotent: on normal execution $0 resolves DIR and this sources the lib; when
# the §11.4.135 guard has ALREADY sourced analyzer_common.sh (its $0-based DIR
# would be wrong here), skip the re-source so a failed `.` never aborts the guard.
command -v dyn_red_mode >/dev/null 2>&1 || . "$DIR/../lib/analyzer_common.sh"

# ---------------------------------------------------------------------------
# Pure growth-verdict classifier (single-source, §11.4.107(10)/§11.4.6/§11.4.69).
# Exercised BOTH by the GREEN body below AND by the §11.4.135 regression guard
# tests/regression/memory_soak_degenerate_sample_test.sh, which sources this file
# with MEMSOAK_SOURCE_ONLY=1 (defines the function, runs NO soak / NO side
# effects) — no divergent copy of the classification logic.
#
# mem_soak_classify <baseline> <last> <growth_pct> <max_growth_pct>
#   Emits one of: "PASS|<detail>" | "SKIP|<detail>" | "FAIL|<detail>".
#   §11.4.6/§11.4.69 no-absence-as-evidence: a DEGENERATE final sample (last<=0)
#   with a valid baseline means HELIX_MEM_RSS_CMD died mid-soak — growth then
#   computes to (0-base)*100/base = -100% which would spuriously satisfy
#   "growth <= max" and score a sampler-death as "bounded". Such a run is
#   MISSING EVIDENCE (honest SKIP), NEVER a bounded PASS.
mem_soak_classify() {
    _ms_b=$1; _ms_l=$2; _ms_g=$3; _ms_gp=$4
    if [ "$_ms_b" -gt 0 ] 2>/dev/null && [ "$_ms_l" -le 0 ] 2>/dev/null; then
        printf 'SKIP|degenerate final RSS sample (baseline=%s last=%s growth=%s%%) — HELIX_MEM_RSS_CMD failed mid-soak; not evidence of a bounded working set' \
            "$_ms_b" "$_ms_l" "$_ms_g"
        return 0
    fi
    if [ "$_ms_b" -gt 0 ] 2>/dev/null && [ "$_ms_g" -le "$_ms_gp" ] 2>/dev/null; then
        printf 'PASS|bounded working set (growth=%s%% <= %s%%)' "$_ms_g" "$_ms_gp"
        return 0
    fi
    printf 'FAIL|baseline=%s last=%s growth=%s%% > %s%% (or no samples)' \
        "$_ms_b" "$_ms_l" "$_ms_g" "$_ms_gp"
    return 0
}

# Sourced for its function only (regression guard) — stop before any side effect.
if [ "${MEMSOAK_SOURCE_ONLY:-0}" = "1" ]; then return 0 2>/dev/null || exit 0; fi

SUITE="memory_soak"
RUN_ID=$(date -u +%Y%m%dT%H%M%SZ)
QA="$(ac_qa_dir p9-harness)/${SUITE}_${RUN_ID}"
mkdir -p "$QA"
PROXY=$(dyn_stack_proxy_url)
REQS=${MEM_REQUESTS:-500}
WARMUP=${MEM_WARMUP:-50}
TARGET=${MEM_TARGET:-http://target-a.internal/}
GROWTH_PCT=${MEM_GROWTH_PCT:-20}
SERIES="$QA/rss.series"

printf '# %s suite — run-id %s (RED_MODE=%s) reqs=%d warmup=%d growth<=%d%%\n' \
    "$SUITE" "$RUN_ID" "${RED_MODE:-0}" "$REQS" "$WARMUP" "$GROWTH_PCT"

if dyn_skip_if_no_stack "$SUITE (soak $REQS requests)"; then
    printf '# NOTE: memory soak requires the live stack (P10). Authored + parse-clean today.\n'
    exit 0
fi
if [ -z "${HELIX_MEM_RSS_CMD:-}" ]; then
    ab_skip_with_reason "$SUITE (RSS-sampling hook HELIX_MEM_RSS_CMD not configured)" "feature_disabled_by_config"
    exit 0
fi

: > "$SERIES"
i=1
while [ "$i" -le "$REQS" ]; do
    curl -s --max-time 15 -o /dev/null -x "$PROXY" "$TARGET" 2>/dev/null || true
    # Sample every 10 requests (and always after warmup) to keep the series small.
    if [ "$((i % 10))" -eq 0 ]; then
        rss=$(sh -c "$HELIX_MEM_RSS_CMD" 2>/dev/null | awk 'NF{print $1; exit}')
        rss=${rss:-0}
        printf '%d %d\n' "$i" "$rss" >> "$SERIES"
    fi
    i=$((i + 1))
done

# Compute baseline (first post-warmup sample) + last + min/max + growth%.
stats=$(awk -v warm="$WARMUP" '
    $1 >= warm {
        if (base == "") base = $2
        last = $2
        if (mn == "" || $2 < mn) mn = $2
        if (mx == "" || $2 > mx) mx = $2
        sum += $2; n++
    }
    END {
        if (n == 0) { print "0 0 0 0 0 0"; exit }
        mean = (n > 0) ? int(sum / n) : 0
        grow = (base > 0) ? int(((last - base) * 100) / base) : 0
        printf "%d %d %d %d %d %d\n", base, last, mn, mx, mean, grow
    }' "$SERIES")
set -- $stats
base=$1; last=$2; mn=$3; mx=$4; mean=$5; grow=$6
{
    printf 'samples_post_warmup baseline=%s last=%s min=%s max=%s mean=%s growth_pct=%s\n' \
        "$base" "$last" "$mn" "$mx" "$mean" "$grow"
} > "$QA/memory.evidence"
cat "$SERIES" >> "$QA/memory.evidence"

if dyn_red_mode; then
    if [ "$base" -gt 0 ] && [ "$grow" -gt "$GROWTH_PCT" ]; then
        ab_pass_with_evidence "$SUITE RED-baseline reproduced unbounded growth (${grow}% > ${GROWTH_PCT}%)" "$QA/memory.evidence"
        exit $?
    fi
    ac_fail "$SUITE RED-baseline" "[reason: working set stayed bounded (growth=${grow}%) — no leak to reproduce]"
    exit 1
fi

# §11.4.6/§11.4.69: classify via the single-source verdict function so a
# degenerate final sample (last<=0, growth=-100%) is an honest SKIP (sampler
# failed mid-soak) — NEVER a spurious "bounded" PASS.
MS_CLS=$(mem_soak_classify "$base" "$last" "$grow" "$GROWTH_PCT")
MS_KIND=${MS_CLS%%|*}
MS_DETAIL=${MS_CLS#*|}
case "$MS_KIND" in
    PASS)
        ab_pass_with_evidence "$SUITE $MS_DETAIL" "$QA/memory.evidence"
        exit $?
        ;;
    SKIP)
        ab_skip_with_reason "$SUITE $MS_DETAIL (see $QA/memory.evidence)" "feature_disabled_by_config"
        exit $?
        ;;
    *)
        ac_fail "$SUITE" "[reason: $MS_DETAIL — see $QA/memory.evidence]"
        exit 1
        ;;
esac
