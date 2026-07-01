#!/usr/bin/env bash
# =============================================================================
# proxy_forward_stress.sh — §11.4.85/§11.4.169 STRESS suite for the LIVE proxy
# -----------------------------------------------------------------------------
# Purpose:      Sustained-load + concurrent-contention stress against the LIVE
#               HTTP forward proxy (Squid, localhost:53128). Drives N>=100
#               sequential HTTPS-CONNECT requests through the proxy PLUS a
#               concurrent burst (>=10 parallel), captures each request's
#               %{http_code} + %{time_total} to its OWN file (the B3 bluff fix —
#               a verdict never rests on a background job's exit status), records
#               a p50/p95/p99 latency distribution to a captured latency.txt, and
#               PASSes only when EVERY request succeeded (204/200 through the
#               proxy) with no deadlock (every request returned within --max-time)
#               and no crash. Corroborated by a captured Squid `Via:` header on a
#               representative plain-HTTP probe (hard client-side proof the bytes
#               transited proxy-squid). Every PASS cites captured evidence
#               (§11.4.69) — never a metadata-only PASS.
# Usage:        bash tests/stress/proxy_forward_stress.sh
#               # host-safety caps applied by the conductor's invocation:
#               GOMAXPROCS=2 nice -n 19 ionice -c 3 \
#                   bash tests/stress/proxy_forward_stress.sh
#               STRESS_SEQ=100 STRESS_CONC=10 bash tests/stress/proxy_forward_stress.sh
# Inputs:       Live curl through http://localhost:53128 (READ-ONLY client use).
#               Env: HTTP_PROXY_URL (default http://localhost:53128),
#                    HTTP_PROXY_PORT (default 53128),
#                    STRESS_TARGET (default https://www.gstatic.com/generate_204),
#                    STRESS_EXPECT (default "204 200"),
#                    STRESS_VIA_TARGET (default http://www.gstatic.com/generate_204),
#                    STRESS_SEQ (default 100), STRESS_CONC (default 10),
#                    CURL_MAX_TIME (default 20),
#                    STRESS_EVIDENCE_DIR (default qa-results/stress/proxy_forward_<ts>).
# Outputs:      Per-request code/time files, a captured latency.txt (samples +
#               min/max/mean + p50/p95/p99), a stress.evidence summary, and one
#               structured PASS/FAIL/SKIP verdict.
#               Exit: 0 = PASS, 1 = FAIL (real proxy defect / dropped requests),
#               3 = SKIP (honest non-applicable: proxy/topology or endpoint
#               unreachable, §11.4.3).
# Side-effects: Live curl only. NEVER stops/starts/restarts/reconfigures any
#               container and never touches operator resources. Creates the
#               evidence dir under qa-results/ (gitignored). `trap` cleanup reaps
#               background workers + removes the scratch dir on every exit path
#               (§11.4.14).
# Dependencies: bash, curl, awk, sort, grep; tests/lib/evidence.sh (sourced).
# Resources:    shell + curl only; concurrency bounded by STRESS_CONC; well under
#               the §12.6 60% host-memory ceiling. Conductor wraps with
#               GOMAXPROCS=2 nice -n 19 ionice -c 3.
# Cross-refs:   §11.4.85 (stress) / §11.4.169 (test-type coverage) / §11.4.69
#               (captured sink evidence) / §11.4.1 (no false-FAIL on outage) /
#               §11.4.68 (no fail-open) / §11.4.50 (deterministic) / §11.4.107;
#               evidence.sh proxy_conn_verdict / port_is_listening / _code_in.
# Shell:        POSIX-clean body — parses under `sh -n` AND `bash -n` (§11.4.67).
# =============================================================================

set -u

SUITE="proxy_forward_stress"

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
PROXY_URL=${HTTP_PROXY_URL:-http://localhost:53128}
PROXY_PORT=${HTTP_PROXY_PORT:-53128}
TARGET=${STRESS_TARGET:-https://www.gstatic.com/generate_204}
VIA_TARGET=${STRESS_VIA_TARGET:-http://www.gstatic.com/generate_204}
EXPECT=${STRESS_EXPECT:-204 200}
SEQ=${STRESS_SEQ:-100}
CONC=${STRESS_CONC:-10}
MAX_TIME=${CURL_MAX_TIME:-20}
RUN_TS=$(date -u +%Y%m%dT%H%M%SZ)
EVIDENCE_DIR=${STRESS_EVIDENCE_DIR:-$REPO_ROOT/qa-results/stress/proxy_forward_$RUN_TS}
mkdir -p "$EVIDENCE_DIR"
SCRATCH="$EVIDENCE_DIR/scratch"
mkdir -p "$SCRATCH"
LAT="$EVIDENCE_DIR/latency.txt"
EV="$EVIDENCE_DIR/stress.evidence"

# --- trap cleanup (§11.4.14): reap OUR stray workers + drop scratch ---------
# Kills ONLY the specific burst PIDs this script spawned (never `kill 0`, which
# would signal the whole process group incl. the conductor). Burst workers are
# normally reaped by `wait`; this covers an INT/TERM mid-burst. Evidence files
# under EVIDENCE_DIR are preserved; only the scratch dir is removed.
BURST_PIDS=""
_stress_cleanup() {
    if [ -n "${BURST_PIDS:-}" ]; then
        for _p in $BURST_PIDS; do kill "$_p" 2>/dev/null || true; done
    fi
    rm -rf "$SCRATCH" 2>/dev/null || true
}
trap _stress_cleanup EXIT INT TERM

echo "=== $SUITE — run $RUN_TS ==="
echo "proxy=$PROXY_URL  target=$TARGET  seq=$SEQ conc=$CONC  evidence=$EVIDENCE_DIR"

{
    printf '=== %s stress — run %s ===\n' "$SUITE" "$RUN_TS"
    printf 'proxy_url=%s proxy_port=%s max_time=%ss\n' "$PROXY_URL" "$PROXY_PORT" "$MAX_TIME"
    printf 'target=%s expected_codes=%s\n' "$TARGET" "$EXPECT"
    printf 'seq=%d concurrent=%d\n' "$SEQ" "$CONC"
} > "$EV"

# --- Step 0: Via corroboration probe (plain-HTTP; carries Squid `Via:`) ------
# HTTPS-CONNECT tunnels are opaque to Squid (no Via inside the tunnel), so a
# plain-HTTP probe provides the hard "these bytes transited proxy-squid" proof.
VIA_HDR="$EVIDENCE_DIR/via_probe_headers.txt"
: > "$VIA_HDR"
via_code=$(curl -sS -D "$VIA_HDR" -o /dev/null -w '%{http_code}' \
    --max-time "$MAX_TIME" -x "$PROXY_URL" "$VIA_TARGET" 2>/dev/null || printf '000')
via_present=no
if grep -qiE '^Via:' "$VIA_HDR" 2>/dev/null; then via_present=yes; fi
{
    printf '\n--- Via corroboration probe (plain HTTP) ---\n'
    printf 'via_target=%s via_http_code=%s via_header_present=%s\n' "$VIA_TARGET" "$via_code" "$via_present"
    grep -iE '^HTTP/|^Via:|^Server:' "$VIA_HDR" 2>/dev/null | sed 's/^/  /' || true
} >> "$EV"

# --- Step 1: sustained sequential HTTPS-CONNECT load ------------------------
# Per request: capture %{http_code} to its own file and append %{time_total}
# to the latency sample set. A hung request cannot exceed --max-time (deadlock
# guard) and reports 000.
SAMPLES="$SCRATCH/latency_samples.txt"
: > "$SAMPLES"
seq_ok=0
i=1
while [ "$i" -le "$SEQ" ]; do
    out=$(curl -sS --max-time "$MAX_TIME" -o /dev/null \
        -w '%{http_code} %{time_total}' -x "$PROXY_URL" "$TARGET" 2>/dev/null || printf '000 %s' "$MAX_TIME")
    code=${out%% *}
    ttime=${out##* }
    printf '%s\n' "$code" > "$SCRATCH/seq.$i.code"
    printf '%s\n' "$ttime" >> "$SAMPLES"
    if _code_in "$code" "$EXPECT"; then seq_ok=$((seq_ok + 1)); fi
    i=$((i + 1))
done

# --- Step 2: concurrent burst (>=CONC parallel; B3 per-request code files) ---
j=1
while [ "$j" -le "$CONC" ]; do
    (
        cout=$(curl -sS --max-time "$MAX_TIME" -o /dev/null \
            -w '%{http_code} %{time_total}' -x "$PROXY_URL" "$TARGET" 2>/dev/null || printf '000 %s' "$MAX_TIME")
        printf '%s\n' "${cout%% *}" > "$SCRATCH/conc.$j.code"
        printf '%s\n' "${cout##* }" > "$SCRATCH/conc.$j.time"
    ) &
    BURST_PIDS="$BURST_PIDS $!"
    j=$((j + 1))
done
wait
conc_ok=0
j=1
while [ "$j" -le "$CONC" ]; do
    cc=$(cat "$SCRATCH/conc.$j.code" 2>/dev/null)
    ct=$(cat "$SCRATCH/conc.$j.time" 2>/dev/null)
    [ -n "$ct" ] && printf '%s\n' "$ct" >> "$SAMPLES"
    if _code_in "${cc:-000}" "$EXPECT"; then conc_ok=$((conc_ok + 1)); fi
    j=$((j + 1))
done

# --- Latency distribution (nearest-rank p50/p95/p99) ------------------------
sort -n "$SAMPLES" > "$SCRATCH/latency_sorted.txt" 2>/dev/null || cp "$SAMPLES" "$SCRATCH/latency_sorted.txt"
{
    printf '# %s latency distribution — run %s\n' "$SUITE" "$RUN_TS"
    printf '# unit: seconds (curl %%{time_total}); nearest-rank percentiles\n'
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
    printf '\n--- load result ---\n'
    printf 'sequential_ok=%d/%d\n' "$seq_ok" "$SEQ"
    printf 'concurrent_ok=%d/%d\n' "$conc_ok" "$CONC"
    printf 'direct_probe_code=%s port_%s_listening=%s\n' "$direct_code" "$PROXY_PORT" "$listen"
    printf 'latency_file=%s\n' "$LAT"
    printf 'via_header_present=%s (plain-HTTP corroboration bytes transited proxy-squid)\n' "$via_present"
} >> "$EV"

echo
echo "sequential_ok=$seq_ok/$SEQ concurrent_ok=$conc_ok/$CONC direct=$direct_code"
echo "latency: $(awk '/^p50=|^p95=|^p99=/{printf "%s ", $0}' "$LAT" 2>/dev/null)"

# --- Verdict ----------------------------------------------------------------
# GREEN requires EVERY proxied request to succeed. A shortfall is classified:
#   proxy dropped requests BUT the SAME target is reachable DIRECTLY -> real
#     proxy defect / possible deadlock -> FAIL (§11.4.68 no fail-open).
#   proxy dropped requests AND direct also fails -> external outage -> SKIP
#     (§11.4.1 no false-FAIL of a healthy proxy on a third-party outage).
#   proxy port not listening + no direct signal -> topology SKIP.
total_ok=$((seq_ok + conc_ok))
total_req=$((SEQ + CONC))
if [ "$seq_ok" -eq "$SEQ" ] && [ "$conc_ok" -eq "$CONC" ]; then
    printf 'OVERALL=PASS\n' >> "$EV"
    echo "OVERALL=PASS ($total_ok/$total_req proxied requests succeeded)"
    ab_pass_with_evidence "$SUITE: $total_ok/$total_req HTTPS-CONNECT requests through $PROXY_URL all succeeded (latency captured)" "$LAT"
    exit 0
fi
if _code_in "$direct_code" "$EXPECT"; then
    printf 'OVERALL=FAIL\n' >> "$EV"
    echo "OVERALL=FAIL (proxy dropped requests but target reachable directly=$direct_code — real proxy defect)"
    _evidence_emit FAIL "$SUITE" "[reason: only $total_ok/$total_req proxied requests succeeded while target reachable directly ($direct_code) — proxy dropped/deadlocked requests; see $EV]"
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
