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
. "$DIR/../lib/analyzer_common.sh"

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

if [ "$base" -gt 0 ] && [ "$grow" -le "$GROWTH_PCT" ]; then
    ab_pass_with_evidence "$SUITE bounded working set (growth=${grow}% <= ${GROWTH_PCT}%)" "$QA/memory.evidence"
    exit $?
fi
ac_fail "$SUITE" "[reason: baseline=$base last=$last growth=${grow}% > ${GROWTH_PCT}% (or no samples) — see $QA/memory.evidence]"
exit 1
