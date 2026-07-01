#!/usr/bin/env bash
# =============================================================================
# proxy_forward_benchmark.sh — §11.4.169 BENCHMARK/performance suite for the
#                              LIVE forward proxy
# -----------------------------------------------------------------------------
# Purpose:      Measure forward-proxy request LATENCY (p50/p95/p99 + min/max/mean)
#               and sequential THROUGHPUT (successful requests per wall-second)
#               against the LIVE HTTP forward proxy (Squid, 127.0.0.1:53128).
#               Drives N (default 200) sequential plain-HTTP requests through the
#               proxy to a 204-returning endpoint, records EVERY request's
#               %{http_code} + %{time_total} to a captured latency.txt (the
#               anti-bluff evidence — the verdict rests on captured per-request
#               samples, never a summary number), computes a nearest-rank
#               percentile distribution, and PASSes ONLY when it captured >= N
#               successful 204s. A shortfall fails LOUD (§11.4.1): it is a real
#               proxy defect (FAIL) when the SAME target is reachable directly,
#               and an honest topology / external-outage SKIP (§11.4.3) otherwise
#               — NEVER a fabricated PASS and NEVER fake numbers (§11.4.6).
# Usage:        bash tests/benchmark/proxy_forward_benchmark.sh
#               # host-safety caps applied by the conductor's invocation:
#               GOMAXPROCS=2 nice -n 19 ionice -c 3 \
#                   bash tests/benchmark/proxy_forward_benchmark.sh
#               BENCH_N=200 PROXY_ADDR=127.0.0.1:53128 \
#                   bash tests/benchmark/proxy_forward_benchmark.sh
# Inputs:       Live curl through http://$PROXY_ADDR (READ-ONLY client use).
#               Env: PROXY_ADDR (default 127.0.0.1:53128),
#                    BENCH_TARGET (default http://www.gstatic.com/generate_204),
#                    BENCH_EXPECT (default "204"),
#                    BENCH_N (default 200), CURL_MAX_TIME (default 20),
#                    BENCH_EVIDENCE_DIR
#                       (default qa-results/benchmark/proxy_forward_<ts>).
# Outputs:      A captured latency.txt (N raw samples + min/max/mean +
#               p50/p95/p99 + throughput req/s), a benchmark.evidence summary,
#               and one structured PASS/FAIL/SKIP verdict citing latency.txt.
#               Exit: 0 = PASS (>= N successful 204s, latency captured),
#                     1 = FAIL (real proxy defect: proxy dropped requests while
#                         the SAME target is reachable directly),
#                     3 = SKIP (honest non-applicable: proxy/topology or endpoint
#                         unreachable, §11.4.3).
# Side-effects: Live curl only. NEVER stops/starts/restarts/reconfigures any
#               container and never touches operator resources. Creates the
#               evidence dir under qa-results/ (gitignored). `trap` cleanup
#               removes the scratch dir on every exit path (§11.4.14).
# Dependencies: bash, curl, awk, sort, grep; tests/lib/evidence.sh (sourced).
# Resources:    shell + curl only; single sequential request stream (no burst),
#               well under the §12.6 60% host-memory ceiling. Conductor wraps
#               with GOMAXPROCS=2 nice -n 19 ionice -c 3.
# Cross-refs:   §11.4.169 (benchmarking/performance test-type coverage) /
#               §11.4.85 (sibling stress suite) / §11.4.69 (captured evidence) /
#               §11.4.1 (no false-FAIL / no silent short PASS) / §11.4.68 (no
#               fail-open) / §11.4.6 (no fake numbers) / §11.4.107;
#               evidence.sh proxy_conn_verdict / port_is_listening / _code_in /
#               ab_pass_with_evidence / ab_skip_with_reason.
# Shell:        POSIX-clean body — parses under `sh -n` AND `bash -n` (§11.4.67).
# Related:      tests/stress/proxy_forward_stress.sh (§11.4.85 stress sibling).
# Last verified: 2026-07-01
# =============================================================================

set -u

SUITE="proxy_forward_benchmark"

# --- Locate repo root (walk up to tests/lib/evidence.sh) --------------------
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
# shellcheck source=/dev/null
. "$REPO_ROOT/tests/lib/evidence.sh"

# --- Config -----------------------------------------------------------------
PROXY_ADDR=${PROXY_ADDR:-127.0.0.1:53128}
PROXY_URL="http://$PROXY_ADDR"
PROXY_PORT=${PROXY_ADDR##*:}
TARGET=${BENCH_TARGET:-http://www.gstatic.com/generate_204}
EXPECT=${BENCH_EXPECT:-204}
N=${BENCH_N:-200}
MAX_TIME=${CURL_MAX_TIME:-20}
RUN_TS=$(date -u +%Y%m%dT%H%M%SZ)
EVIDENCE_DIR=${BENCH_EVIDENCE_DIR:-$REPO_ROOT/qa-results/benchmark/proxy_forward_$RUN_TS}
mkdir -p "$EVIDENCE_DIR"
SCRATCH="$EVIDENCE_DIR/scratch"
mkdir -p "$SCRATCH"
LAT="$EVIDENCE_DIR/latency.txt"
EV="$EVIDENCE_DIR/benchmark.evidence"

# --- trap cleanup (§11.4.14): drop scratch on every exit path ---------------
# Evidence files under EVIDENCE_DIR are preserved; only the scratch dir is
# removed. This benchmark is single-stream (no background workers to reap).
_bench_cleanup() {
    rm -rf "$SCRATCH" 2>/dev/null || true
}
trap _bench_cleanup EXIT INT TERM

echo "=== $SUITE — run $RUN_TS ==="
echo "proxy=$PROXY_URL  target=$TARGET  N=$N  evidence=$EVIDENCE_DIR"

{
    printf '=== %s benchmark — run %s ===\n' "$SUITE" "$RUN_TS"
    printf 'proxy_url=%s proxy_port=%s max_time=%ss\n' "$PROXY_URL" "$PROXY_PORT" "$MAX_TIME"
    printf 'target=%s expected_codes=%s\n' "$TARGET" "$EXPECT"
    printf 'requests=%d (sequential)\n' "$N"
} > "$EV"

# --- Step 1: N sequential requests; capture per-request code + time ---------
# Per request: append %{time_total} to the latency sample set and count 204s.
# A hung request cannot exceed --max-time (bounds the whole run) and reports 000.
SAMPLES="$SCRATCH/latency_samples.txt"
: > "$SAMPLES"
ok_count=0
wall_start=$(date +%s.%N 2>/dev/null || date +%s)
i=1
while [ "$i" -le "$N" ]; do
    out=$(curl -sS --max-time "$MAX_TIME" -o /dev/null \
        -w '%{http_code} %{time_total}' -x "$PROXY_URL" "$TARGET" 2>/dev/null \
        || printf '000 %s' "$MAX_TIME")
    code=${out%% *}
    ttime=${out##* }
    printf '%s\n' "$ttime" >> "$SAMPLES"
    if _code_in "$code" "$EXPECT"; then ok_count=$((ok_count + 1)); fi
    i=$((i + 1))
done
wall_end=$(date +%s.%N 2>/dev/null || date +%s)

# --- Latency distribution (nearest-rank p50/p95/p99) + throughput -----------
sort -n "$SAMPLES" > "$SCRATCH/latency_sorted.txt" 2>/dev/null || cp "$SAMPLES" "$SCRATCH/latency_sorted.txt"
throughput=$(awk -v s="$wall_start" -v e="$wall_end" -v ok="$ok_count" \
    'BEGIN { d = e - s; if (d <= 0) { printf "0.000"; } else { printf "%.3f", ok / d; } }')
{
    printf '# %s latency distribution — run %s\n' "$SUITE" "$RUN_TS"
    printf '# unit: seconds (curl %%{time_total}); nearest-rank percentiles\n'
    printf '# successful_204=%d/%d wall_seconds=%s throughput_req_per_s=%s\n' \
        "$ok_count" "$N" \
        "$(awk -v s="$wall_start" -v e="$wall_end" 'BEGIN{printf "%.3f", e - s}')" \
        "$throughput"
    awk '
        function pctl(p,   x, idx) {
            x = (p / 100.0) * n
            idx = int(x)
            if (x > idx) idx = idx + 1
            if (idx < 1) idx = 1
            if (idx > n) idx = n
            return a[idx]
        }
        { a[NR] = $1 + 0; s += $1 }
        END {
            n = NR
            if (n == 0) { printf "samples=0 (no latency captured)\n"; exit }
            printf "samples=%d\nmin=%.3f\nmax=%.3f\nmean=%.3f\np50=%.3f\np95=%.3f\np99=%.3f\n", \
                n, a[1], a[n], s / n, pctl(50), pctl(95), pctl(99)
        }
    ' "$SCRATCH/latency_sorted.txt"
    printf '\n# raw samples (seconds):\n'
    cat "$SCRATCH/latency_sorted.txt"
} > "$LAT"

# --- Direct cross-check (§11.4.1 outage vs §11.4.68 real defect) ------------
direct_code=$(curl -sS --max-time "$MAX_TIME" -o /dev/null -w '%{http_code}' "$TARGET" 2>/dev/null || printf '000')
if port_is_listening "$PROXY_PORT"; then listen=yes; else listen=no; fi

{
    printf '\n--- benchmark result ---\n'
    printf 'successful_204=%d/%d\n' "$ok_count" "$N"
    printf 'throughput_req_per_s=%s\n' "$throughput"
    printf 'direct_probe_code=%s port_%s_listening=%s\n' "$direct_code" "$PROXY_PORT" "$listen"
    printf 'latency_file=%s\n' "$LAT"
} >> "$EV"

echo
echo "successful_204=$ok_count/$N throughput=${throughput} req/s direct=$direct_code"
echo "latency: $(awk '/^p50=|^p95=|^p99=/{printf "%s ", $0}' "$LAT" 2>/dev/null)"

# --- Verdict ----------------------------------------------------------------
# GREEN requires >= N captured successful 204s. A shortfall fails LOUD (§11.4.1),
# classified via the same evidence.sh contract the stress sibling uses:
#   ok < N but the SAME target reachable DIRECTLY -> real proxy defect -> FAIL
#     (§11.4.68 no fail-open — never mask a broken proxy as a SKIP).
#   ok < N and direct also fails, port listening   -> external outage -> SKIP
#     (§11.4.1 no false-FAIL of a healthy proxy on a third-party outage).
#   ok < N, direct fails, port NOT listening        -> topology SKIP (§11.4.3).
if [ "$ok_count" -ge "$N" ]; then
    printf 'OVERALL=PASS\n' >> "$EV"
    echo "OVERALL=PASS ($ok_count/$N successful 204s through $PROXY_URL — latency + throughput captured)"
    ab_pass_with_evidence "$SUITE: $ok_count/$N proxied 204s through $PROXY_URL (p50/p95/p99 + throughput=${throughput} req/s captured)" "$LAT"
    exit 0
fi
if _code_in "$direct_code" "$EXPECT"; then
    printf 'OVERALL=FAIL\n' >> "$EV"
    echo "OVERALL=FAIL (only $ok_count/$N proxied 204s but target reachable directly=$direct_code — real proxy defect)"
    _evidence_emit FAIL "$SUITE" "[reason: only $ok_count/$N proxied 204s captured while target reachable directly ($direct_code) — proxy dropped requests; see $EV]"
    exit 1
fi
if [ "$listen" = "no" ] && [ "$direct_code" = "000" ]; then
    printf 'OVERALL=SKIP:topology_unsupported\n' >> "$EV"
    echo "OVERALL=SKIP:topology_unsupported (proxy port not listening, no direct signal)"
    ab_skip_with_reason "$SUITE (proxy :$PROXY_PORT not listening / no reachable endpoint)" "topology_unsupported"
    exit 3
fi
printf 'OVERALL=SKIP:network_unreachable_external\n' >> "$EV"
echo "OVERALL=SKIP:network_unreachable_external (target unreachable via proxy AND directly)"
ab_skip_with_reason "$SUITE (target unreachable via proxy AND directly — outage, not a proxy defect)" "network_unreachable_external"
exit 3
