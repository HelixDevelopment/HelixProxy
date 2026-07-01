#!/usr/bin/env bash
# =============================================================================
# proxy_flood_test.sh — §11.4.169 DDoS / load-flood test for the LIVE proxy
# -----------------------------------------------------------------------------
# Purpose:      Prove the LIVE proxy (HTTP forward on localhost:53128, SOCKS5 on
#               localhost:51080) DEGRADES GRACEFULLY under a bounded high-rate
#               request flood — it may shed load (503/429/timeout/reset) but it
#               MUST stay UP and keep serving: under overload the process MUST
#               NOT crash, MUST keep both listeners bound, and MUST recover to
#               normal 204/200 service the moment the flood ends (§11.4.85
#               resource-exhaustion: refuse cleanly OR degrade, NEVER crash).
#               Every flood outcome is categorised into a captured census
#               (success | clean-refuse/shed | timeout | connection-error), and
#               the decisive proof is the POST-FLOOD recovery request succeeding
#               plus both listeners surviving (§11.4.108 runtime-signature,
#               §11.4.69 captured evidence). A metadata-only / "no error" PASS is
#               forbidden; a crash / hung recovery / dropped listener is a FAIL;
#               an absent proxy is an honest §11.4.3 SKIP — never a fake PASS.
#
#               DISTINCT from the sibling flood artifacts (no duplication):
#                 - tests/stress/proxy_forward_stress.sh — sustained/concurrent
#                   STRESS (every request MUST succeed); this is the OVERLOAD /
#                   degrade-not-collapse case (shedding is ACCEPTABLE, survival
#                   is mandatory).
#                 - tests/dynamic/suites/ddos_flood_suite.sh — floods the
#                   `dynamic` VPN-aware ROUTING stack via target-a.internal (a
#                   test topology); THIS test floods the REAL proxy ports.
#                 - tests/regression/ddos_flood_evidence_test.sh — a PURE-FUNCTION
#                   anti-bluff HARNESS guard (no network); THIS is a LIVE flood.
#
# Usage:        bash tests/ddos/proxy_flood_test.sh
#               # Conductor MUST wrap with the host-safety caps (§12.6/§11.4.89):
#               GOMAXPROCS=2 nice -n 19 ionice -c 3 \
#                   bash tests/ddos/proxy_flood_test.sh
#               FLOOD_TOTAL=400 FLOOD_CONC=30 bash tests/ddos/proxy_flood_test.sh
#
# Inputs:       Live curl through http://localhost:53128 (READ-ONLY client use)
#               + a SOCKS5 survival probe through localhost:51080. Env:
#                 HTTP_PROXY_URL   (default http://localhost:53128)
#                 HTTP_PROXY_PORT  (default 53128)
#                 SOCKS_PROXY_HOST (default localhost)
#                 SOCKS_PROXY_PORT (default 51080)
#                 FLOOD_TARGET     (default https://www.gstatic.com/generate_204)
#                 FLOOD_EXPECT     (default "204 200")
#                 FLOOD_TOTAL      (default 300; bounded burst, hard-capped 500)
#                 FLOOD_CONC       (default 20; parallel workers, hard-capped 30)
#                 FLOOD_MAX_TIME   (default 5; per-request curl --max-time secs)
#                 FLOOD_EVIDENCE_DIR (default qa-results/ddos/proxy_flood_<ts>)
#
# Outputs:      A captured outcome census (census.txt), a flood.evidence summary
#               (config + census + survival/recovery signals), and one structured
#               verdict line on stdout:
#                 PASS: <desc> [evidence: <path>]   proxy survived + recovered
#                 FAIL: <desc> [reason: <why>]      crash / no-recovery / dropped listener
#                 SKIP: <desc> [reason: <closed-set>] proxy absent / external outage
#               Exit: 0 = PASS, 1 = FAIL (real proxy collapse under flood),
#                     3 = SKIP (honest non-applicable per §11.4.3).
#
# Side-effects: Live curl only. NEVER stops/starts/restarts/reconfigures any
#               container, process, or proxy, and NEVER touches operator
#               resources. Creates the evidence dir under qa-results/ (gitignored)
#               at RUN time. `trap` reaps ONLY the specific worker PIDs this
#               script spawned (never `kill 0`) and drops the scratch dir on every
#               exit path (§11.4.14).
#
# Resources:    HOST-SAFE (§12.6 — the hard constraint). Shell + curl only, no
#               compiled load tool required. Parallelism is HARD-capped at 30
#               workers and the burst at 500 requests regardless of env, so the
#               flood can never endanger the host; per-request --max-time bounds
#               each curl so nothing hangs unboundedly. Conductor additionally
#               wraps with GOMAXPROCS=2 nice -n 19 ionice -c 3. The flood pressures
#               the PROXY, not host memory; well under the §12.6 60% ceiling.
#               Memory-leak-over-soak is out of scope here (honest boundary,
#               §11.4.6) — that is tests/dynamic/suites/memory_soak_suite.sh.
#
# Dependencies: bash, curl, awk, sort, grep; tests/lib/evidence.sh (sourced).
# Cross-refs:   §11.4.169 (test-type coverage) / §11.4.85 (resource-exhaustion:
#               degrade-not-crash) / §11.4.108 (runtime-signature survival) /
#               §11.4.69 (captured sink evidence) / §11.4.1 (no false-FAIL on a
#               third-party outage) / §11.4.68 (no fail-open SKIP-as-PASS) /
#               §11.4.3 (honest topology SKIP); evidence.sh
#               ab_pass_with_evidence / ab_skip_with_reason / port_is_listening /
#               _code_in / _evidence_emit.
# Shell:        POSIX-clean body — parses under `sh -n` AND `bash -n` (§11.4.67).
#               No bash-only constructs ([[ ]], <<<, arrays, >( ), ${v^^}).
# =============================================================================

set -u

SUITE="proxy_flood"

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
SOCKS_HOST=${SOCKS_PROXY_HOST:-localhost}
SOCKS_PORT=${SOCKS_PROXY_PORT:-51080}
TARGET=${FLOOD_TARGET:-https://www.gstatic.com/generate_204}
EXPECT=${FLOOD_EXPECT:-204 200}
MAX_TIME=${FLOOD_MAX_TIME:-5}

# --- HOST-SAFETY hard caps (§12.6 — non-negotiable) -------------------------
# The burst is HARD-bounded regardless of env so the flood can NEVER endanger
# the host: total requests <=500, parallel workers <=30. Malformed values fall
# back to the safe defaults (§11.4.6 no-guessing — never trust an unparseable
# knob to widen the blast radius).
TOTAL=${FLOOD_TOTAL:-300}
case "$TOTAL" in ''|*[!0-9]*) TOTAL=300 ;; esac
[ "$TOTAL" -lt 1 ] && TOTAL=1
[ "$TOTAL" -gt 500 ] && TOTAL=500          # bounded burst ceiling
CONC=${FLOOD_CONC:-20}
case "$CONC" in ''|*[!0-9]*) CONC=20 ;; esac
[ "$CONC" -lt 1 ] && CONC=1
[ "$CONC" -gt 30 ] && CONC=30              # concurrency ceiling
case "$MAX_TIME" in ''|*[!0-9]*) MAX_TIME=5 ;; esac
[ "$MAX_TIME" -lt 1 ] && MAX_TIME=5
[ "$MAX_TIME" -gt 30 ] && MAX_TIME=30
# Per-worker share so total issued ~= TOTAL (bounded worst-case wall-clock =
# PER_WORKER * MAX_TIME if every request times out — degenerate but finite).
PER_WORKER=$(( (TOTAL + CONC - 1) / CONC ))
[ "$PER_WORKER" -lt 1 ] && PER_WORKER=1

RUN_TS=$(date -u +%Y%m%dT%H%M%SZ)
EVIDENCE_DIR=${FLOOD_EVIDENCE_DIR:-$REPO_ROOT/qa-results/ddos/proxy_flood_$RUN_TS}
mkdir -p "$EVIDENCE_DIR"
SCRATCH="$EVIDENCE_DIR/scratch"
mkdir -p "$SCRATCH"
EV="$EVIDENCE_DIR/flood.evidence"
CENSUS="$EVIDENCE_DIR/census.txt"

# --- trap cleanup (§11.4.14): reap OUR stray workers + drop scratch ---------
# Kills ONLY the specific flood-worker PIDs this script spawned (never `kill 0`,
# which would signal the whole process group incl. the conductor). Workers are
# normally reaped by `wait`; this covers an INT/TERM mid-flood. Evidence files
# under EVIDENCE_DIR are preserved; only the scratch dir is removed.
WORKER_PIDS=""
_flood_cleanup() {
    if [ -n "${WORKER_PIDS:-}" ]; then
        for _p in $WORKER_PIDS; do kill "$_p" 2>/dev/null || true; done
    fi
    rm -rf "$SCRATCH" 2>/dev/null || true
}
trap _flood_cleanup EXIT INT TERM

echo "=== $SUITE — run $RUN_TS ==="
echo "http_proxy=$PROXY_URL socks=$SOCKS_HOST:$SOCKS_PORT target=$TARGET"
echo "flood: total=$TOTAL conc=$CONC (per_worker=$PER_WORKER) max_time=${MAX_TIME}s  evidence=$EVIDENCE_DIR"

{
    printf '=== %s DDoS/flood — run %s ===\n' "$SUITE" "$RUN_TS"
    printf 'http_proxy_url=%s http_proxy_port=%s\n' "$PROXY_URL" "$PROXY_PORT"
    printf 'socks_proxy=%s:%s\n' "$SOCKS_HOST" "$SOCKS_PORT"
    printf 'target=%s expected_codes=%s\n' "$TARGET" "$EXPECT"
    printf 'flood_total=%d flood_conc=%d per_worker=%d max_time=%ss (host-safe caps: total<=500 conc<=30)\n' \
        "$TOTAL" "$CONC" "$PER_WORKER" "$MAX_TIME"
} > "$EV"

# --- classify_outcome <code> <time_total> <max_time> <expect_list> ----------
# PURE outcome classifier (no network). Prints exactly one census bucket:
#   success  — HTTP code in the expected set (served through the proxy).
#   refuse   — any OTHER measurable HTTP code (1xx-5xx incl. 503/429/407/502/
#              400/3xx): a CLEAN refuse / load-shed — the proxy answered, it did
#              NOT crash. This is the graceful-degradation signal §11.4.85 wants.
#   timeout  — curl reported 000 AND spent ~>= max_time: the request hung until
#              the deadline (backpressure / saturation).
#   error    — curl reported 000 quickly: connection refused / reset (no HTTP
#              response). En-masse `error` alongside a failed recovery is the
#              crash signature the verdict catches.
# `success` + `refuse` = flood_landed (requests that got a real HTTP response —
# positive proof the flood actually reached and was answered by the proxy,
# §11.4.69). Timeouts/errors do NOT count as landed.
classify_outcome() {
    _co_code=$1
    _co_time=$2
    _co_max=$3
    _co_expect=$4
    if _code_in "$_co_code" "$_co_expect"; then
        printf 'success\n'; return 0
    fi
    if [ "$_co_code" != "000" ]; then
        printf 'refuse\n'; return 0
    fi
    # code == 000: distinguish a timed-out hang from a fast connection error.
    # Nearest-integer compare of time_total vs max_time (awk — time is fractional).
    _co_hung=$(awk -v t="$_co_time" -v m="$_co_max" 'BEGIN { print ((t + 0) >= (m + 0) - 0.5) ? 1 : 0 }')
    if [ "$_co_hung" = "1" ]; then
        printf 'timeout\n'; return 0
    fi
    printf 'error\n'; return 0
}

# --- Precondition: is the HTTP proxy even present? --------------------------
# Proxy absent => honest topology SKIP BEFORE flooding nothing (§11.4.3).
if port_is_listening "$PROXY_PORT"; then http_listen_before=yes; else http_listen_before=no; fi
if port_is_listening "$SOCKS_PORT"; then socks_listen_before=yes; else socks_listen_before=no; fi
{
    printf '\n--- pre-flood listeners ---\n'
    printf 'http_%s_listening_before=%s socks_%s_listening_before=%s\n' \
        "$PROXY_PORT" "$http_listen_before" "$SOCKS_PORT" "$socks_listen_before"
} >> "$EV"

if [ "$http_listen_before" = "no" ]; then
    # No HTTP proxy to flood. Cross-check a direct fetch: if even the target is
    # unreachable we still SKIP (topology absent); we NEVER fabricate a PASS.
    printf 'OVERALL=SKIP:topology_unsupported (http proxy :%s not listening pre-flood)\n' "$PROXY_PORT" >> "$EV"
    echo "OVERALL=SKIP:topology_unsupported (proxy :$PROXY_PORT absent — nothing to flood)"
    ab_skip_with_reason "$SUITE (http proxy :$PROXY_PORT not listening — proxy absent)" "topology_unsupported"
    exit 3
fi

# --- FLOOD: bounded parallel curl workers through the HTTP proxy ------------
# Each worker issues PER_WORKER requests, appending "<code> <time_total>" per
# request to its OWN file (never rests a verdict on a background exit status).
# A hung request cannot exceed --max-time (deadlock/backpressure guard) and
# reports 000.
w=1
while [ "$w" -le "$CONC" ]; do
    (
        r=1
        while [ "$r" -le "$PER_WORKER" ]; do
            out=$(curl -s --max-time "$MAX_TIME" -o /dev/null \
                -w '%{http_code} %{time_total}' -x "$PROXY_URL" "$TARGET" 2>/dev/null \
                || printf '000 %s' "$MAX_TIME")
            printf '%s\n' "$out" >> "$SCRATCH/worker.$w.out"
            r=$((r + 1))
        done
    ) &
    WORKER_PIDS="$WORKER_PIDS $!"
    w=$((w + 1))
done
wait
WORKER_PIDS=""

# --- Categorise every outcome into the captured census ----------------------
n_success=0; n_refuse=0; n_timeout=0; n_error=0; n_total=0
: > "$SCRATCH/outcomes.txt"
for f in "$SCRATCH"/worker.*.out; do
    [ -f "$f" ] || continue
    while IFS=' ' read -r code ttime rest; do
        [ -n "${code:-}" ] || continue
        bucket=$(classify_outcome "${code:-000}" "${ttime:-0}" "$MAX_TIME" "$EXPECT")
        printf '%s %s %s\n' "$bucket" "$code" "${ttime:-0}" >> "$SCRATCH/outcomes.txt"
        n_total=$((n_total + 1))
        case "$bucket" in
            success) n_success=$((n_success + 1)) ;;
            refuse)  n_refuse=$((n_refuse + 1)) ;;
            timeout) n_timeout=$((n_timeout + 1)) ;;
            error)   n_error=$((n_error + 1)) ;;
        esac
    done < "$f"
done
flood_landed=$((n_success + n_refuse))

{
    printf '# %s outcome census — run %s\n' "$SUITE" "$RUN_TS"
    printf '# flood_total_issued=%d flood_landed(success+refuse)=%d\n' "$n_total" "$flood_landed"
    printf 'success=%d\n' "$n_success"
    printf 'refuse_shed=%d\n' "$n_refuse"
    printf 'timeout=%d\n' "$n_timeout"
    printf 'error=%d\n' "$n_error"
    printf '\n# distinct HTTP codes seen (code count):\n'
    awk '{print $2}' "$SCRATCH/outcomes.txt" 2>/dev/null | sort | uniq -c | sort -rn
} > "$CENSUS"

# --- POST-FLOOD SURVIVAL + RECOVERY (the decisive proof) -------------------
# The proxy must still be UP and serving after the flood: both listeners bound
# AND a normal request succeeds (§11.4.108 runtime-signature). A direct probe
# discriminates a real proxy crash (§11.4.68) from an external outage (§11.4.1).
if port_is_listening "$PROXY_PORT"; then http_listen_after=yes; else http_listen_after=no; fi
if port_is_listening "$SOCKS_PORT"; then socks_listen_after=yes; else socks_listen_after=no; fi

recover_code=$(curl -s --max-time "$MAX_TIME" -o /dev/null -w '%{http_code}' \
    -x "$PROXY_URL" "$TARGET" 2>/dev/null || printf '000')
direct_code=$(curl -s --max-time "$MAX_TIME" -o /dev/null -w '%{http_code}' \
    "$TARGET" 2>/dev/null || printf '000')
# SOCKS5 survival probe (single bounded request — proves the SOCKS listener
# still serves, not merely that the port is bound). 000 if the SOCKS path is not
# configured/reachable; the listener check remains the primary SOCKS signal.
socks_recover_code=000
if [ "$socks_listen_before" = "yes" ]; then
    socks_recover_code=$(curl -s --max-time "$MAX_TIME" -o /dev/null -w '%{http_code}' \
        --socks5-hostname "$SOCKS_HOST:$SOCKS_PORT" "$TARGET" 2>/dev/null || printf '000')
fi

{
    printf '\n--- post-flood survival / recovery ---\n'
    printf 'http_%s_listening_after=%s socks_%s_listening_after=%s\n' \
        "$PROXY_PORT" "$http_listen_after" "$SOCKS_PORT" "$socks_listen_after"
    printf 'recovery_http_code=%s direct_probe_code=%s socks_recovery_code=%s\n' \
        "$recover_code" "$direct_code" "$socks_recover_code"
    printf 'census: success=%d refuse_shed=%d timeout=%d error=%d landed=%d/%d\n' \
        "$n_success" "$n_refuse" "$n_timeout" "$n_error" "$flood_landed" "$n_total"
} >> "$EV"

echo
echo "census: success=$n_success refuse=$n_refuse timeout=$n_timeout error=$n_error (landed=$flood_landed/$n_total)"
echo "survival: http_after=$http_listen_after socks_after=$socks_listen_after recovery=$recover_code direct=$direct_code"

# --- Verdict (first match wins) --------------------------------------------
# GREEN (survived + recovered) requires ALL of:
#   (1) a REAL flood landed  — flood_landed > 0 (the proxy actually answered
#       flood requests; a zero-landed flood proves nothing → not a survive-PASS);
#   (2) both listeners survived — the HTTP listener still bound AND, if the SOCKS
#       listener was up before, it is still up after (a dropped listener = crash);
#   (3) recovery succeeded — a normal request returns an expected code.
# Load-shedding (refuse/timeout DURING the flood) is ACCEPTABLE and healthy —
# only a CRASH / no-recovery / dropped listener fails.
socks_dropped=no
[ "$socks_listen_before" = "yes" ] && [ "$socks_listen_after" = "no" ] && socks_dropped=yes

if [ "$socks_dropped" = "yes" ]; then
    printf 'OVERALL=FAIL:socks-listener-dropped\n' >> "$EV"
    echo "OVERALL=FAIL (SOCKS listener :$SOCKS_PORT was up before the flood and is DOWN after — crash)"
    _evidence_emit FAIL "$SUITE" "[reason: SOCKS5 listener :$SOCKS_PORT dropped under flood (before=yes after=no) — proxy collapsed a service; census $CENSUS]"
    exit 1
fi

if _code_in "$recover_code" "$EXPECT" && [ "$http_listen_after" = "yes" ]; then
    if [ "$flood_landed" -gt 0 ]; then
        printf 'OVERALL=PASS\n' >> "$EV"
        echo "OVERALL=PASS (proxy survived a real flood + recovered to $recover_code)"
        ab_pass_with_evidence \
            "$SUITE degraded-not-collapsed: flood landed=$flood_landed/$n_total (success=$n_success shed=$n_refuse timeout=$n_timeout err=$n_error) — listeners survived + recovered $recover_code" \
            "$EV"
        exit 0
    fi
    # Proxy is up and recovers, but the flood produced ZERO measurable responses
    # (all timeout/error). That is not proof the proxy withstood a flood — the
    # target was unreachable THROUGH the proxy, so no real flood pressure was
    # applied. Honest SKIP, never a vacuous "survived" PASS (§11.4.69/§11.4.1).
    printf 'OVERALL=SKIP:network_unreachable_external (recovered but zero flood landed)\n' >> "$EV"
    echo "OVERALL=SKIP:network_unreachable_external (proxy up + recovered but no flood request landed — target unreachable through proxy)"
    ab_skip_with_reason "$SUITE (proxy up + recovered but zero flood landed — target unreachable through proxy, no real flood pressure)" "network_unreachable_external"
    exit 3
fi

# Recovery FAILED (or the HTTP listener dropped). Discriminate a real proxy
# collapse from an external outage.
if _code_in "$direct_code" "$EXPECT" || [ "$http_listen_after" = "no" ]; then
    printf 'OVERALL=FAIL:crash-or-no-recovery\n' >> "$EV"
    echo "OVERALL=FAIL (proxy did NOT recover: recovery=$recover_code http_after=$http_listen_after; target reachable directly=$direct_code)"
    _evidence_emit FAIL "$SUITE" "[reason: proxy did not recover after flood (recovery=$recover_code, http_listening_after=$http_listen_after) while target reachable directly ($direct_code) — crash / collapse / fail-closed-and-stuck; census $CENSUS]"
    exit 1
fi

# Recovery failed AND direct also fails AND the port still listens: the site /
# internet is down, not the proxy's fault (§11.4.1 no false-FAIL of a healthy
# proxy on a third-party outage).
printf 'OVERALL=SKIP:network_unreachable_external (recovery + direct both fail, proxy still listening)\n' >> "$EV"
echo "OVERALL=SKIP:network_unreachable_external (target unreachable via proxy AND directly — external outage)"
ab_skip_with_reason "$SUITE (target unreachable via proxy AND directly after flood — outage, not a proxy defect)" "network_unreachable_external"
exit 3
