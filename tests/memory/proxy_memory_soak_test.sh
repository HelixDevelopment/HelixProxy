#!/usr/bin/env bash
# =============================================================================
# proxy_memory_soak_test.sh — §11.4.169 MEMORY/soak proof for the LIVE proxy
# -----------------------------------------------------------------------------
# Purpose:      Prove the LIVE HTTP forward proxy (Squid, localhost:34128,
#               container `proxy-squid`) does NOT leak memory under sustained
#               load. Reads the proxy container's RSS at BASELINE (before any
#               load) NON-INVASIVELY, drives a sustained soak of N>=200 proxied
#               requests over >=30s (sequential — the concurrent-contention
#               dimension is the stress suite's job; sequential keeps the RSS
#               attribution clean and the observer-effect minimal), samples RSS
#               into a captured time-series along the way, re-reads RSS at the
#               end, and PASSes ONLY when the container survived AND the final
#               RSS did NOT grow past a documented, calibrated bound
#               (final_rss <= baseline_rss * MEM_GROWTH_FACTOR). Unbounded growth
#               (a leak) = FAIL; the container dying under the soak (possible OOM)
#               = FAIL; the proxy absent, or cgroup memory accounting genuinely
#               unavailable = honest SKIP (§11.4.3). Every PASS cites the captured
#               RSS time-series (§11.4.69) — never a metadata-only PASS.
# Usage:        bash tests/memory/proxy_memory_soak_test.sh
#               # host-safety caps applied by the conductor's invocation:
#               GOMAXPROCS=2 nice -n 19 ionice -c 3 \
#                   bash tests/memory/proxy_memory_soak_test.sh
#               MEM_SOAK_REQUESTS=400 MEM_SOAK_MIN_SECONDS=60 \
#                   MEM_GROWTH_FACTOR=1.4 \
#                   bash tests/memory/proxy_memory_soak_test.sh
# Inputs:       Live curl through http://localhost:34128 (READ-ONLY client use)
#               + READ-ONLY container introspection of `proxy-squid` (podman/
#               docker `ps` / `stats` / `inspect` — NEVER exec/stop/restart).
#               Env: HTTP_PROXY_URL (default http://localhost:34128),
#                    HTTP_PROXY_PORT (default 34128),
#                    MEM_SOAK_CONTAINER (default proxy-squid),
#                    MEM_SOAK_TARGET (default https://www.gstatic.com/generate_204),
#                    MEM_SOAK_EXPECT (default "204 200"),
#                    MEM_SOAK_REQUESTS (default 240; the >=200 soak floor),
#                    MEM_SOAK_MIN_SECONDS (default 30; the >=30s duration floor),
#                    MEM_SOAK_SAMPLES (default 8; RSS time-series points),
#                    MEM_SOAK_MAX_ROUNDS (default 60; runaway guard),
#                    MEM_GROWTH_FACTOR (default 1.5; the bounded-growth bound —
#                        CALIBRATE on first run, see docs companion §Calibration),
#                    MEM_MIN_BASELINE_BYTES (default 4194304 = 4 MiB; below this
#                        the ratio test is noise-prone — surfaced, not silently
#                        applied),
#                    CURL_MAX_TIME (default 20),
#                    MEM_SOAK_EVIDENCE_DIR (default
#                        qa-results/memory/proxy_soak_<ts>).
# Outputs:      A captured RSS time-series (rss_timeseries.tsv: sample idx /
#               elapsed_s / cumulative_requests / rss_bytes / rss_human), a
#               soak.evidence summary (baseline / final / threshold / ratio /
#               served), and one structured PASS/FAIL/SKIP verdict.
#               Exit: 0 = PASS (bounded RSS, soak served real load),
#                     1 = FAIL (unbounded growth / leak, OR container died under
#                         soak, OR proxy served nothing while target reachable),
#                     3 = SKIP (honest non-applicable: proxy/topology absent,
#                         cgroup memory accounting unavailable, or external
#                         outage — §11.4.3).
# Side-effects: Live curl + READ-ONLY container introspection ONLY. NEVER stops/
#               starts/restarts/reconfigures/execs-into any container and never
#               touches operator resources. Creates the evidence dir under
#               qa-results/ (gitignored). `trap` cleanup removes the scratch dir
#               on every exit path (§11.4.14); evidence under the evidence dir is
#               preserved.
# Dependencies: bash, curl, awk, tr, head; podman OR docker (READ-ONLY, optional
#               — absence => honest SKIP); tests/lib/evidence.sh (sourced).
# Resources:    shell + curl + one podman-stats read per sample; sequential load,
#               well under the §12.6 60% host-memory ceiling. Conductor wraps
#               with GOMAXPROCS=2 nice -n 19 ionice -c 3 (§12.6/§11.4.169 caps).
# Cross-refs:   §11.4.169 (mandatory memory test-type coverage) / §11.4.85
#               (soak / sustained load) / §11.4.69 (captured evidence per PASS) /
#               §11.4.128 (non-invasive observer-effect budget — the RSS read
#               perturbs nothing) / §11.4.1 (no false-FAIL on external outage) /
#               §11.4.68 (no fail-open SKIP masking a real defect) / §11.4.6
#               (calibrated, not hardcoded-from-literature threshold) / §11.4.161
#               (rootless podman preferred); evidence.sh ab_pass_with_evidence /
#               ab_skip_with_reason / _code_in / port_is_listening.
# Shell:        POSIX-clean body — parses under `sh -n` AND `bash -n` (§11.4.67).
#               No bash-only constructs ([[ ]], <<<, arrays, >( ), ${v^^}).
# =============================================================================

set -u

SUITE="proxy_memory_soak"

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
PROXY_URL=${HTTP_PROXY_URL:-http://localhost:34128}
PROXY_PORT=${HTTP_PROXY_PORT:-34128}
CONTAINER=${MEM_SOAK_CONTAINER:-proxy-squid}
TARGET=${MEM_SOAK_TARGET:-https://www.gstatic.com/generate_204}
EXPECT=${MEM_SOAK_EXPECT:-204 200}
N=${MEM_SOAK_REQUESTS:-240}
MIN_SECS=${MEM_SOAK_MIN_SECONDS:-30}
SAMPLES=${MEM_SOAK_SAMPLES:-8}
MAX_ROUNDS=${MEM_SOAK_MAX_ROUNDS:-60}
MAX_TIME=${CURL_MAX_TIME:-20}
GROWTH_FACTOR=${MEM_GROWTH_FACTOR:-1.5}
MIN_BASELINE=${MEM_MIN_BASELINE_BYTES:-4194304}
RUN_TS=$(date -u +%Y%m%dT%H%M%SZ)
EVIDENCE_DIR=${MEM_SOAK_EVIDENCE_DIR:-$REPO_ROOT/qa-results/memory/proxy_soak_$RUN_TS}
mkdir -p "$EVIDENCE_DIR"
SCRATCH="$EVIDENCE_DIR/scratch"
mkdir -p "$SCRATCH"
TS="$EVIDENCE_DIR/rss_timeseries.tsv"
EV="$EVIDENCE_DIR/soak.evidence"

# per-round request quota (>=1); rounds continue until BOTH the request floor
# AND the duration floor are met (or MAX_ROUNDS trips).
PER_ROUND=$(( N / SAMPLES ))
[ "$PER_ROUND" -lt 1 ] && PER_ROUND=1

# --- trap cleanup (§11.4.14): drop scratch only; preserve evidence ----------
_soak_cleanup() { rm -rf "$SCRATCH" 2>/dev/null || true; }
trap _soak_cleanup EXIT INT TERM

# --- Container engine (rootless podman preferred, docker fallback; READ-ONLY) -
CE=""
if command -v podman >/dev/null 2>&1; then CE=podman
elif command -v docker >/dev/null 2>&1; then CE=docker
fi

# container_running <name> — READ-ONLY detection.
container_running() {
    _c=$1
    [ -n "$CE" ] || return 1
    "$CE" ps --format '{{.Names}}' 2>/dev/null | grep -qx "$_c"
}

# _to_bytes <human-size> — convert a go-units size ("12.5MB", "128MiB", "512kB",
# a bare byte count) to an integer byte count. Prints "" on an unknown unit so
# the caller treats it as an unreadable sample (never a fabricated number,
# §11.4.6). Handles both base-1000 (kB/MB/GB/TB) and base-1024 (KiB/MiB/GiB/TiB).
_to_bytes() {
    awk -v v="$1" 'BEGIN {
        n = v + 0
        u = v; sub(/^[0-9.]+/, "", u); gsub(/ /, "", u); u = tolower(u)
        if (u == "" || u == "b")            m = 1
        else if (u == "kb")                 m = 1000
        else if (u == "kib")                m = 1024
        else if (u == "mb")                 m = 1000000
        else if (u == "mib")                m = 1048576
        else if (u == "gb")                 m = 1000000000
        else if (u == "gib")                m = 1073741824
        else if (u == "tb")                 m = 1000000000000
        else if (u == "tib")                m = 1099511627776
        else                                { print ""; exit }
        printf "%.0f", n * m
    }'
}

# proxy_rss_bytes — NON-INVASIVE RSS of the whole proxy container.
# Primary: `<ce> stats --no-stream` reads the container cgroup memory accounting
#   counter ONCE and exits — it does NOT exec into the container, send a signal,
#   or spawn any process inside it, so it perturbs the squid processes not at all
#   (§11.4.128 observer-effect budget). It aggregates EVERY process in the
#   container cgroup (squid master + worker + helpers) — the correct leak signal.
# Fallback: when cgroup memory accounting is unavailable (some rootless cgroup-v1
#   hosts render MemUsage as "--"), read the host-side /proc VmRSS of the
#   container's init PID via READ-ONLY `<ce> inspect`. This is COARSE (container
#   PID 1 only, not the cgroup aggregate) and is documented as such; the primary
#   path is preferred whenever available.
# Prints an integer byte count (>0) on success; prints nothing + returns 1 when
# RSS is genuinely unreadable (caller => honest SKIP, never a faked 0).
proxy_rss_bytes() {
    [ -n "$CE" ] || { return 1; }
    _mu=$("$CE" stats --no-stream --format '{{.MemUsage}}' "$CONTAINER" 2>/dev/null \
        | head -n1 | awk -F'/' '{print $1}' | tr -d ' ')
    _b=$(_to_bytes "$_mu")
    if [ -n "$_b" ] && [ "$_b" -gt 0 ] 2>/dev/null; then
        printf '%s\n' "$_b"; return 0
    fi
    _pid=$("$CE" inspect --format '{{.State.Pid}}' "$CONTAINER" 2>/dev/null)
    if [ -n "$_pid" ] && [ "$_pid" -gt 0 ] 2>/dev/null && [ -r "/proc/$_pid/status" ]; then
        _kb=$(awk '/^VmRSS:/ { print $2; exit }' "/proc/$_pid/status" 2>/dev/null)
        if [ -n "$_kb" ] && [ "$_kb" -gt 0 ] 2>/dev/null; then
            printf '%s\n' "$(( _kb * 1024 ))"; return 0
        fi
    fi
    return 1
}

# _mib <bytes> — human MiB for logs/time-series (display only).
_mib() { awk -v b="$1" 'BEGIN { printf "%.1fMiB", b / 1048576 }'; }

echo "=== $SUITE — run $RUN_TS ==="
echo "proxy=$PROXY_URL container=$CONTAINER target=$TARGET"
echo "soak: requests>=$N over >=${MIN_SECS}s, samples=$SAMPLES, growth_factor=$GROWTH_FACTOR"
echo "evidence=$EVIDENCE_DIR"

{
    printf '=== %s — run %s ===\n' "$SUITE" "$RUN_TS"
    printf 'proxy_url=%s proxy_port=%s container=%s engine=%s\n' \
        "$PROXY_URL" "$PROXY_PORT" "$CONTAINER" "${CE:-none}"
    printf 'target=%s expected_codes=%s max_time=%ss\n' "$TARGET" "$EXPECT" "$MAX_TIME"
    printf 'soak_requests_floor=%d soak_seconds_floor=%d samples=%d per_round=%d max_rounds=%d\n' \
        "$N" "$MIN_SECS" "$SAMPLES" "$PER_ROUND" "$MAX_ROUNDS"
    printf 'growth_factor=%s min_baseline_bytes=%d\n' "$GROWTH_FACTOR" "$MIN_BASELINE"
} > "$EV"

# --- Guard 1: container engine + proxy container present (READ-ONLY) ---------
if [ -z "$CE" ]; then
    printf 'OVERALL=SKIP:topology_unsupported (no podman/docker to read container RSS)\n' >> "$EV"
    ab_skip_with_reason "$SUITE (no podman/docker available to read container RSS)" "topology_unsupported"
    exit 3
fi
if ! container_running "$CONTAINER"; then
    printf 'OVERALL=SKIP:topology_unsupported (container %s not running)\n' "$CONTAINER" >> "$EV"
    ab_skip_with_reason "$SUITE (proxy container '$CONTAINER' not running)" "topology_unsupported"
    exit 3
fi

# --- Guard 2: baseline RSS readable BEFORE any load -------------------------
baseline_rss=$(proxy_rss_bytes || true)
if [ -z "${baseline_rss:-}" ] || [ "$baseline_rss" -le 0 ] 2>/dev/null; then
    printf 'OVERALL=SKIP:topology_unsupported (cgroup memory accounting unavailable for %s)\n' "$CONTAINER" >> "$EV"
    ab_skip_with_reason "$SUITE (cgroup memory accounting unavailable for '$CONTAINER' — cannot read RSS)" "topology_unsupported"
    exit 3
fi

# time-series header + baseline sample (idx 0, elapsed 0, 0 requests)
{
    printf '# %s RSS time-series — run %s\n' "$SUITE" "$RUN_TS"
    printf '# columns: sample_idx\telapsed_s\tcumulative_requests\trss_bytes\trss_human\n'
    printf '0\t0\t0\t%s\t%s\n' "$baseline_rss" "$(_mib "$baseline_rss")"
} > "$TS"

echo "baseline RSS: $baseline_rss bytes ($(_mib "$baseline_rss"))"

# --- Soak: sustained sequential proxied load, sampling RSS per round --------
start=$(date +%s)
req=0
ok=0
round=0
sample_idx=0
last_rss=$baseline_rss
while : ; do
    r=0
    while [ "$r" -lt "$PER_ROUND" ]; do
        code=$(curl -sS --max-time "$MAX_TIME" -o /dev/null \
            -w '%{http_code}' -x "$PROXY_URL" "$TARGET" 2>/dev/null || printf '000')
        req=$((req + 1))
        if _code_in "$code" "$EXPECT"; then ok=$((ok + 1)); fi
        r=$((r + 1))
    done
    round=$((round + 1))
    sample_idx=$((sample_idx + 1))
    now=$(date +%s)
    elapsed=$((now - start))
    s_rss=$(proxy_rss_bytes || true)
    if [ -n "${s_rss:-}" ] && [ "$s_rss" -gt 0 ] 2>/dev/null; then
        last_rss=$s_rss
        printf '%s\t%s\t%s\t%s\t%s\n' "$sample_idx" "$elapsed" "$req" "$s_rss" "$(_mib "$s_rss")" >> "$TS"
    else
        # unreadable mid-soak sample: record honestly (0), keep last good for verdict.
        printf '%s\t%s\t%s\t0\tUNREADABLE\n' "$sample_idx" "$elapsed" "$req" >> "$TS"
    fi
    if [ "$req" -ge "$N" ] && [ "$elapsed" -ge "$MIN_SECS" ]; then break; fi
    if [ "$round" -ge "$MAX_ROUNDS" ]; then break; fi
done
soak_secs=$(( $(date +%s) - start ))

echo "soak done: served_ok=$ok/$req requests over ${soak_secs}s, rounds=$round"

# --- Post-soak: did the container SURVIVE the soak? (OOM/crash guard) --------
if ! container_running "$CONTAINER"; then
    {
        printf '\n--- post-soak ---\n'
        printf 'container_alive=no served_ok=%d/%d soak_seconds=%d\n' "$ok" "$req" "$soak_secs"
        printf 'OVERALL=FAIL (container %s died during the memory soak — possible OOM/crash)\n' "$CONTAINER"
    } >> "$EV"
    echo "OVERALL=FAIL (container $CONTAINER died during the soak — possible OOM)"
    _evidence_emit FAIL "$SUITE" "[reason: container '$CONTAINER' not running after the soak — died under sustained load (possible OOM); see $TS]"
    exit 1
fi

# final RSS (explicit end-of-soak read)
final_rss=$(proxy_rss_bytes || true)
if [ -z "${final_rss:-}" ] || [ "$final_rss" -le 0 ] 2>/dev/null; then
    final_rss=$last_rss
fi

# --- Soak-served-real-load guard (memory census over an idle proxy is void) --
# The RSS census only means something if the soak actually loaded the proxy.
if [ "$ok" -eq 0 ]; then
    direct_code=$(curl -sS --max-time "$MAX_TIME" -o /dev/null -w '%{http_code}' "$TARGET" 2>/dev/null || printf '000')
    if port_is_listening "$PROXY_PORT"; then listen=yes; else listen=no; fi
    {
        printf '\n--- soak served no proxied requests ---\n'
        printf 'served_ok=0/%d direct_probe_code=%s port_%s_listening=%s\n' "$req" "$direct_code" "$PROXY_PORT" "$listen"
    } >> "$EV"
    if _code_in "$direct_code" "$EXPECT"; then
        printf 'OVERALL=FAIL (proxy served 0 requests while target reachable directly=%s — real proxy defect)\n' "$direct_code" >> "$EV"
        echo "OVERALL=FAIL (proxy served nothing while target reachable directly=$direct_code)"
        _evidence_emit FAIL "$SUITE" "[reason: proxy served 0/$req soak requests while target reachable directly ($direct_code) — proxy defect, memory census void; see $EV]"
        exit 1
    fi
    printf 'OVERALL=SKIP:network_unreachable_external (target unreachable via proxy AND directly)\n' >> "$EV"
    echo "OVERALL=SKIP:network_unreachable_external"
    ab_skip_with_reason "$SUITE (target unreachable via proxy AND directly — outage, not a proxy defect)" "network_unreachable_external"
    exit 3
fi

# --- Bounded-growth verdict -------------------------------------------------
# threshold = baseline * MEM_GROWTH_FACTOR (calibrated bound, §11.4.6 — NOT a
# hardcoded-from-literature absolute; see docs companion §Calibration). Squid
# legitimately warms its in-memory index + worker buffers early in a soak then
# PLATEAUS; a leak shows CONTINUOUS growth across the time-series and blows past
# the bound. delta_bytes + ratio are captured for the operator to tighten the
# factor after the first calibrated run.
threshold=$(awk -v b="$baseline_rss" -v f="$GROWTH_FACTOR" 'BEGIN { printf "%.0f", b * f }')
ratio=$(awk -v a="$final_rss" -v b="$baseline_rss" 'BEGIN { printf "%.4f", (b > 0) ? a / b : 0 }')
delta=$((final_rss - baseline_rss))
small_baseline=no
if [ "$baseline_rss" -lt "$MIN_BASELINE" ]; then small_baseline=yes; fi

{
    printf '\n--- memory census ---\n'
    printf 'served_ok=%d/%d soak_seconds=%d rounds=%d\n' "$ok" "$req" "$soak_secs" "$round"
    printf 'baseline_rss_bytes=%s (%s)\n' "$baseline_rss" "$(_mib "$baseline_rss")"
    printf 'final_rss_bytes=%s (%s)\n' "$final_rss" "$(_mib "$final_rss")"
    printf 'delta_bytes=%s growth_ratio=%s growth_factor_bound=%s threshold_bytes=%s\n' \
        "$delta" "$ratio" "$GROWTH_FACTOR" "$threshold"
    printf 'small_baseline=%s (baseline < %d bytes => ratio noise-prone, surfaced)\n' "$small_baseline" "$MIN_BASELINE"
    printf 'timeseries=%s\n' "$TS"
} >> "$EV"

echo "baseline=$(_mib "$baseline_rss") final=$(_mib "$final_rss") ratio=$ratio bound=$GROWTH_FACTOR"

if [ "$final_rss" -le "$threshold" ]; then
    printf 'OVERALL=PASS (RSS bounded: final %s <= baseline*%s = %s bytes)\n' "$final_rss" "$GROWTH_FACTOR" "$threshold" >> "$EV"
    echo "OVERALL=PASS (RSS bounded under sustained load)"
    ab_pass_with_evidence "$SUITE: RSS bounded under $ok-request/${soak_secs}s soak (baseline $(_mib "$baseline_rss") -> final $(_mib "$final_rss"), ratio $ratio <= bound $GROWTH_FACTOR)" "$TS"
    exit 0
fi

printf 'OVERALL=FAIL (RSS grew unbounded: final %s > baseline*%s = %s bytes — leak)\n' "$final_rss" "$GROWTH_FACTOR" "$threshold" >> "$EV"
echo "OVERALL=FAIL (RSS grew unbounded — memory leak)"
_evidence_emit FAIL "$SUITE" "[reason: RSS grew from $(_mib "$baseline_rss") to $(_mib "$final_rss") (ratio $ratio > bound $GROWTH_FACTOR) under a $ok-request/${soak_secs}s soak — unbounded growth / leak; see $TS]"
exit 1
