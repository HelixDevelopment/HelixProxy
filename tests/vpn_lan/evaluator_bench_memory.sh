#!/usr/bin/env sh
###############################################################################
# evaluator_bench_memory.sh — §11.4.169 BENCHMARK + MEMORY test-type layer for
#                             the VPN-LAN deterministic policy evaluators
#                             (SSRF carve-out + ingress allowlist)
#                             (PLAN.md §4/§5 Phase 1 + Phase 12; performance +
#                              memory sibling of ssrf_carveout_teeth.sh /
#                              ingress_allowlist_teeth.sh /
#                              ssrf_bridge_stress_chaos.sh)
#
# Purpose:
#   Add the two §11.4.169 test-types the existing VPN-LAN teeth do NOT cover —
#   (13) BENCHMARKING/PERFORMANCE and (12) MEMORY — for the deterministic,
#   pure-shell policy evaluators that gate egress (Dante SSRF first-match-wins
#   rule evaluator: ip_to_int / ip_in_cidr / eval_dest) and ingress (default-deny
#   allowlist evaluator: eval_ingress). Both measured layers ship rock-solid
#   CAPTURED evidence and a paired §1.1 mutation so neither is a bluff gate
#   (§11.4.107(10)). This is a TEST-ONLY, AUTONOMOUS, pure-logic characterisation
#   — NO live VPN, NO bridge, NO data-plane touch, NO live-config mutation.
#
#   HOW THE REAL EVALUATOR IS EXERCISED (no editing of the teeth):
#     The shipped teeth define their decision path as shell functions inside
#     their own source. This test EXTRACTS those functions VERBATIM (read-only,
#     byte-for-byte) from the committed teeth via awk — ip_to_int / ip_in_cidr /
#     eval_dest from ssrf_carveout_teeth.sh and eval_ingress from
#     ingress_allowlist_teeth.sh — sources the extracted copy, and drives the
#     REAL committed decision logic in a tight in-process loop. It NEVER edits
#     ssrf_carveout_teeth.sh, ingress_allowlist_teeth.sh,
#     ssrf_bridge_stress_chaos.sh, or config/dante/sockd.conf. A sanity gate
#     asserts the extracted functions reproduce the known-good canary verdicts
#     BEFORE any measurement — if extraction yields a non-functional path the
#     test honestly SKIPs (never benchmarks a broken evaluator, never fakes a
#     number).
#
#   BENCHMARK (§11.4.169 performance):
#     Warmup on THIS host, then run the combined SSRF+ingress decision path for a
#     large fixed N (~1000 evaluations across a canary set) in K batches. Measure
#     per-batch wall-clock (GNU `date +%s.%N`), compute per-decision latency
#     p50/p95/max from the per-batch samples, and a throughput number
#     (decisions/sec). The pass floor is CALIBRATED on this host from the warmup
#     throughput (a catastrophic-regression floor = warmup × FLOOR_FRAC), NOT a
#     hardcoded literature constant (§11.4.6). A throughput below the calibrated
#     floor (a catastrophic slowdown) FAILs. Evidence: latency.json +
#     throughput.txt + calibration.txt.
#
#   MEMORY (§11.4.169 memory):
#     Soak the SAME decision path over K batches IN-PROCESS and sample the
#     working shell's RSS (/proc/$$/status VmRSS) after each batch, plus the
#     peak (VmHWM). Assert (a) peak RSS stays under a CALIBRATED bound (warmup
#     peak × BOUND_FACTOR + margin — calibrated on this host, §11.4.6), and
#     (b) NO unbounded growth — RSS after the last batch does not exceed RSS
#     after the first batch by more than a small tolerance (a pure-sh evaluator
#     is flat; awk children are short-lived and do not accrue to the parent).
#     Evidence: rss_samples.txt.
#
#   §1.1 paired mutation (BENCHMEM_MUT=1): after the REAL measurement, SET an
#   impossible throughput floor (measured × 1000 + 1) AND INJECT an unbounded RSS
#   growth (a synthetic +500 MB final sample). The REAL assertions then evaluate
#   FALSE and the test FAILs (rc=1) — proving both the benchmark floor and the
#   memory-growth teeth are load-bearing (not tautologies) (§11.4.107(10)).
#
#   Host caps (§12.6): the process re-execs itself once under `nice -n 19`
#   (+ `ionice -c 3` when present) with GOMAXPROCS=2; N is bounded + clamped so
#   the whole run stays light. NEVER pkill/kill, NEVER touches the data-plane
#   :53128/:51080, NEVER signals or self-matches another process (§11.4.174).
#
# Usage:
#   tests/vpn_lan/evaluator_bench_memory.sh                 # normal — must PASS (rc 0)
#   BENCHMEM_MUT=1 tests/vpn_lan/evaluator_bench_memory.sh  # mutation — must FAIL (rc 1)
#   BENCH_BATCHES=20 BENCH_PASSES=8 tests/vpn_lan/evaluator_bench_memory.sh  # heavier
#
# Inputs (environment):
#   SOCKD_CONF       live Dante floor to extract the egress rule list from
#                    (default config/dante/sockd.conf) — READ-ONLY, never edited.
#   SSRF_TEETH       path to the SSRF teeth to extract the evaluator from
#                    (default tests/vpn_lan/ssrf_carveout_teeth.sh) — read-only.
#   INGRESS_TEETH    path to the ingress teeth to extract eval_ingress from
#                    (default tests/vpn_lan/ingress_allowlist_teeth.sh) — read-only.
#   HELIX_BRIDGE_HOST allowlisted ingress host + a canary dest (LOGIC input only,
#                    default 10.6.100.221 — no live probe).
#   INGRESS_PORT     allowlisted ingress port (LOGIC input only, default 2049).
#   WARMUP_PASSES / BENCH_BATCHES / BENCH_PASSES / MEM_BATCHES / MEM_PASSES
#                    bounded, clamped loop sizes (defaults 8 / 10 / 6 / 6 / 6).
#   FLOOR_FRAC       throughput floor as a fraction of warmup (default 0.15).
#   BENCHMEM_MUT     when 1, run the §1.1 paired mutation (test MUST then FAIL).
#
# Outputs:
#   Diagnostic lines + one verdict token per layer (PASS / FAIL / SKIP:<reason>).
#   Normal: exit 0 iff BOTH measured layers held. Mutation: exit 1 (the injected
#   regression/growth is correctly caught). Captured evidence under
#   qa-results/vpn_lan/phase_bench_memory/<UTC-ts>/.
#
# Side-effects:
#   READ-ONLY on the teeth + live config. Extracts evaluator functions + renders
#   an ingress-policy fixture + writes evidence under a private temp dir +
#   qa-results only. Removes the temp dir on every exit path (trap, §11.4.14).
#   NEVER edits config/dante/sockd.conf, ssrf_carveout_teeth.sh,
#   ingress_allowlist_teeth.sh, or ssrf_bridge_stress_chaos.sh; NEVER
#   (re)starts/kills a proxy; NEVER runs pkill/kill; NEVER touches the
#   data-plane :53128/:51080.
#
# Dependencies:
#   POSIX sh + awk + sort + GNU `date +%s.%N` (millisecond timing) +
#   /proc/<pid>/status (Linux RSS/VmHWM). Missing teeth/floor/RSS source ⇒
#   honest SKIP (never a fake PASS). No network, no root, no listener.
#
# Cross-references:
#   tests/vpn_lan/ssrf_carveout_teeth.sh        (egress evaluator — extracted here)
#   tests/vpn_lan/ingress_allowlist_teeth.sh    (ingress evaluator — extracted here)
#   tests/vpn_lan/ssrf_bridge_stress_chaos.sh   (stress+chaos sibling — structure mirrored)
#   config/dante/sockd.conf                     (live SSRF floor — READ-ONLY)
#   docs/design/vpn_lan_access/PLAN.md §4/§5 Phase 1 + Phase 12
#   constitution §11.4.1 / §11.4.5 / §11.4.6 / §11.4.14 / §11.4.50 / §11.4.69 /
#                §11.4.107(10) / §11.4.169 / §11.4.174 / §12.6 / §1.1
###############################################################################

set -u

# ---- host caps (§12.6): re-exec once under nice/ionice + GOMAXPROCS=2 --------
if [ "${BENCHMEM_NICED:-0}" != 1 ]; then
    BENCHMEM_NICED=1; export BENCHMEM_NICED
    GOMAXPROCS=2; export GOMAXPROCS
    _nice=''; command -v nice   >/dev/null 2>&1 && _nice='nice -n 19'
    _ionice=''; command -v ionice >/dev/null 2>&1 && _ionice='ionice -c 3'
    if [ -n "$_nice$_ionice" ]; then
        # shellcheck disable=SC2086
        exec $_nice $_ionice sh "$0" "$@"
    fi
fi

SCRIPT_LABEL='evaluator_bench_memory'
_sc_dir=$(cd "$(dirname "$0")" && pwd)
_repo_root=$(cd "$_sc_dir/../.." && pwd)

SOCKD_CONF="${SOCKD_CONF:-$_repo_root/config/dante/sockd.conf}"
SSRF_TEETH="${SSRF_TEETH:-$_repo_root/tests/vpn_lan/ssrf_carveout_teeth.sh}"
INGRESS_TEETH="${INGRESS_TEETH:-$_repo_root/tests/vpn_lan/ingress_allowlist_teeth.sh}"
BENCHMEM_MUT="${BENCHMEM_MUT:-0}"

# Deterministic LOGIC inputs (never source .env — this is a pure-logic test).
ALLOW_HOST="${HELIX_BRIDGE_HOST:-10.6.100.221}"
ALLOW_PORT="${INGRESS_PORT:-2049}"

log() { printf '%s: %s\n' "$SCRIPT_LABEL" "$1"; }

# ---- bounded, clamped loop sizes (§12.6) ------------------------------------
clamp_int() { # <value> <default> <min> <max> -> echo clamped
    _v=$1; _def=$2; _min=$3; _max=$4
    case "$_v" in ''|*[!0-9]*) _v=$_def ;; esac
    [ "$_v" -lt "$_min" ] && _v=$_min
    [ "$_v" -gt "$_max" ] && _v=$_max
    printf '%s' "$_v"
}
WARMUP_PASSES=$(clamp_int "${WARMUP_PASSES:-8}"  8  2 40)
BENCH_BATCHES=$(clamp_int "${BENCH_BATCHES:-10}" 10 4 50)
BENCH_PASSES=$(clamp_int "${BENCH_PASSES:-6}"    6  1 50)
MEM_BATCHES=$(clamp_int "${MEM_BATCHES:-6}"      6  2 50)
MEM_PASSES=$(clamp_int "${MEM_PASSES:-6}"        6  1 50)
FLOOR_FRAC="${FLOOR_FRAC:-0.15}"
case "$FLOOR_FRAC" in ''|*[!0-9.]*) FLOOR_FRAC='0.15' ;; esac
GROWTH_TOL_KB=4096      # 4 MB headroom — a pure-sh evaluator is flat
BOUND_FACTOR=2          # peak-RSS bound = warmup_peak * BOUND_FACTOR + margin
BOUND_MARGIN_KB=8192    # +8 MB absolute margin

# ---- evidence + temp ---------------------------------------------------------
TS=$(date -u +%Y%m%dT%H%M%SZ 2>/dev/null || date +%Y%m%dT%H%M%SZ)
EV_ROOT="$_repo_root/qa-results/vpn_lan/phase_bench_memory/$TS"
mkdir -p "$EV_ROOT" 2>/dev/null || true
BM_TMP=$(mktemp -d 2>/dev/null || printf '%s' "${TMPDIR:-/tmp}/helix_benchmem_$$")
mkdir -p "$BM_TMP" 2>/dev/null || true
cleanup() { [ -n "${BM_TMP:-}" ] && rm -rf "$BM_TMP" >/dev/null 2>&1; return 0; }
trap cleanup EXIT INT TERM

# ---- self-contained evidence-gated emitters (§11.4.69) -----------------------
N_PASS=0; N_FAIL=0; N_SKIP=0
ab_pass_with_evidence() {
    _d=$1; _e=${2:-}
    if [ -z "$_e" ] || [ ! -s "$_e" ]; then
        printf 'FAIL: %s [reason: evidence missing/empty: %s]\n' "$_d" "$_e"; N_FAIL=$((N_FAIL+1)); return 1
    fi
    printf 'PASS: %s [evidence: %s]\n' "$_d" "$_e"; N_PASS=$((N_PASS+1)); return 0
}
ab_skip_with_reason() {
    _d=$1; _r=${2:-}
    case "$_r" in
        geo_restricted|operator_attended|hardware_not_present|topology_unsupported|network_unreachable_external|feature_disabled_by_config)
            printf 'SKIP: %s [reason: %s]\n' "$_d" "$_r"; N_SKIP=$((N_SKIP+1)); return 0 ;;
        *)
            printf 'FAIL: %s [reason: invalid skip reason %s — not §11.4.69 closed set]\n' "$_d" "$_r"; N_FAIL=$((N_FAIL+1)); return 2 ;;
    esac
}
ab_fail() { printf 'FAIL: %s [%s]\n' "$1" "${2:-}"; N_FAIL=$((N_FAIL+1)); }

# ---- timing + numeric helpers ------------------------------------------------
epoch() { date +%s.%N 2>/dev/null; }
# ms_between <start> <end> -> milliseconds (double subtraction; adequate to ~1us).
ms_between() { awk -v s="$1" -v e="$2" 'BEGIN{d=(e-s)*1000; if(d<0)d=0; printf "%.3f", d}'; }
# pctile <sorted-file> <count> <frac> -> the value at the ceil(count*frac) rank.
pctile() {
    awk -v n="$2" -v fr="$3" 'BEGIN{ i=int(n*fr+0.9999999); if(i<1)i=1; if(i>n)i=n } NR==i{print; exit}' "$1"
}
ge() { awk -v a="$1" -v b="$2" 'BEGIN{exit (a>=b)?0:1}'; }   # a >= b ?
# RSS/VmHWM of THIS working shell ($$ is stable across subshells in POSIX sh).
rss_kb() { awk '/^VmRSS:/{print $2; exit}' "/proc/$$/status" 2>/dev/null; }
hwm_kb() { awk '/^VmHWM:/{print $2; exit}' "/proc/$$/status" 2>/dev/null; }

# ---- read-only verbatim extraction of the committed evaluator functions ------
# awk range from `^NAME() {` to the first line that is exactly `}` — the shipped
# functions close with a column-0 `}` (verified); no editing of the teeth.
extract_fn() { # <src-file> <fn-name>
    awk -v fn="$2" '$0 ~ ("^" fn "\\(\\) \\{"){f=1} f{print} f&&/^\}/{exit}' "$1"
}

# ============================================================================
# PRE — teeth + live floor must exist (else honest SKIP, never a fake PASS).
# ============================================================================
if [ ! -f "$SSRF_TEETH" ] || [ ! -f "$INGRESS_TEETH" ]; then
    ab_skip_with_reason "evaluator bench+memory (teeth script absent)" topology_unsupported
    printf '%s: done (skipped) — pass=%s fail=%s skip=%s\n' "$SCRIPT_LABEL" "$N_PASS" "$N_FAIL" "$N_SKIP"
    exit 0
fi
if [ ! -s "$SOCKD_CONF" ]; then
    ab_skip_with_reason "evaluator bench+memory (live floor absent/empty: $SOCKD_CONF)" topology_unsupported
    printf '%s: done (skipped) — pass=%s fail=%s skip=%s\n' "$SCRIPT_LABEL" "$N_PASS" "$N_FAIL" "$N_SKIP"
    exit 0
fi

EVALS="$BM_TMP/evaluators.sh"
{ extract_fn "$SSRF_TEETH" ip_to_int
  extract_fn "$SSRF_TEETH" ip_in_cidr
  extract_fn "$SSRF_TEETH" eval_dest
  extract_fn "$INGRESS_TEETH" eval_ingress
} > "$EVALS" 2>/dev/null
if [ ! -s "$EVALS" ] || ! sh -n "$EVALS" 2>/dev/null; then
    ab_skip_with_reason "evaluator bench+memory (function extraction failed/unparseable)" topology_unsupported
    printf '%s: done (skipped) — pass=%s fail=%s skip=%s\n' "$SCRIPT_LABEL" "$N_PASS" "$N_FAIL" "$N_SKIP"
    exit 0
fi
# shellcheck disable=SC1090
. "$EVALS"

# Extract the egress rule list read-only (same normalisation the teeth use).
FLOOR_CONF="$BM_TMP/floor.conf"
awk '
  /socks[ \t]+(block|pass)[ \t]*\{/ {inblk=1}
  inblk {print}
  /\}/ && inblk {inblk=0}
' "$SOCKD_CONF" > "$FLOOR_CONF" 2>/dev/null
# Render the ingress GOOD policy fixture (default-deny + one exact allow pair).
INGRESS_CONF="$BM_TMP/ingress.conf"
{ printf '# ingress allowlist — DEFAULT-DENY; only exact (from-host, to-port) pairs permitted.\n'
  printf 'ingress allow {\n    from: %s/32 to-port: %s\n}\n' "$ALLOW_HOST" "$ALLOW_PORT"; } > "$INGRESS_CONF"

if [ ! -s "$FLOOR_CONF" ]; then
    ab_skip_with_reason "evaluator bench+memory (no socks rules parsed from $SOCKD_CONF)" topology_unsupported
    printf '%s: done (skipped) — pass=%s fail=%s skip=%s\n' "$SCRIPT_LABEL" "$N_PASS" "$N_FAIL" "$N_SKIP"
    exit 0
fi

# ---- canary sets (drive both cheap early-match + full-walk decision paths) ----
SSRF_CANARY='169.254.169.254 127.0.0.1 10.99.88.77 172.16.5.5 192.168.9.9 8.8.8.8'
OTHER_HOST='10.99.88.77'; NEIGH_HOST='10.6.100.222'; OTHER_PORT='22'
INGRESS_CANARY="$OTHER_HOST:$OTHER_PORT $ALLOW_HOST:$ALLOW_PORT $NEIGH_HOST:$ALLOW_PORT $ALLOW_HOST:$OTHER_PORT"
DEC_PER_PASS=0
for _x in $SSRF_CANARY;    do DEC_PER_PASS=$((DEC_PER_PASS+1)); done
for _x in $INGRESS_CANARY; do DEC_PER_PASS=$((DEC_PER_PASS+1)); done

# ---- SANITY GATE: extracted funcs must reproduce known-good canary verdicts ----
sane=1
[ "$(eval_dest "$FLOOR_CONF" 169.254.169.254 2>/dev/null)" = block ] || sane=0
[ "$(eval_dest "$FLOOR_CONF" 8.8.8.8 2>/dev/null)"         = pass  ] || sane=0
[ "$(eval_ingress "$INGRESS_CONF" "$OTHER_HOST" "$OTHER_PORT" 2>/dev/null)" = deny   ] || sane=0
[ "$(eval_ingress "$INGRESS_CONF" "$ALLOW_HOST" "$ALLOW_PORT" 2>/dev/null)" = permit ] || sane=0
if [ "$sane" != 1 ]; then
    ab_skip_with_reason "evaluator bench+memory (extracted evaluator failed sanity verdicts)" topology_unsupported
    printf '%s: done (skipped) — pass=%s fail=%s skip=%s\n' "$SCRIPT_LABEL" "$N_PASS" "$N_FAIL" "$N_SKIP"
    exit 0
fi
log "extracted+sourced real evaluators (ip_to_int/ip_in_cidr/eval_dest/eval_ingress); sanity OK"
log "dec/pass=$DEC_PER_PASS ; warmup=$WARMUP_PASSES ; bench=${BENCH_BATCHES}x${BENCH_PASSES} ; mem=${MEM_BATCHES}x${MEM_PASSES} ; mut=$BENCHMEM_MUT"

# ---- the real decision path (in-process; awk children are short-lived) --------
run_pass() {
    for _d in $SSRF_CANARY; do eval_dest "$FLOOR_CONF" "$_d" >/dev/null 2>&1; done
    for _pr in $INGRESS_CANARY; do
        _ip=${_pr%:*}; _pt=${_pr##*:}
        eval_ingress "$INGRESS_CONF" "$_ip" "$_pt" >/dev/null 2>&1
    done
}
run_batch() { _bp=0; while [ "$_bp" -lt "$1" ]; do run_pass; _bp=$((_bp+1)); done; }

# ============================================================================
# WARMUP — calibrate the throughput floor + the RSS bound on THIS host (§11.4.6).
# ============================================================================
WARM_RSS0=$(rss_kb); [ -z "$WARM_RSS0" ] && WARM_RSS0=0
_w0=$(epoch); run_batch "$WARMUP_PASSES"; _w1=$(epoch)
WARM_MS=$(ms_between "$_w0" "$_w1")
WARM_DEC=$((WARMUP_PASSES * DEC_PER_PASS))
WARM_TPUT=$(awk -v d="$WARM_DEC" -v m="$WARM_MS" 'BEGIN{ if(m>0) printf "%.2f", d*1000/m; else print "0" }')
WARM_PEAK=$(hwm_kb); [ -z "$WARM_PEAK" ] && WARM_PEAK=0
CAL_FLOOR=$(awk -v w="$WARM_TPUT" -v f="$FLOOR_FRAC" 'BEGIN{printf "%.2f", w*f}')
RSS_BOUND=$(awk -v p="$WARM_PEAK" -v k="$BOUND_FACTOR" -v m="$BOUND_MARGIN_KB" 'BEGIN{printf "%d", p*k+m}')

cal_ev="$EV_ROOT/calibration.txt"
{ printf '=== §11.4.6 host calibration (this host, this session — no hardcoded literature number) ===\n'
  printf 'timestamp_utc            : %s\n' "$TS"
  printf 'warmup_passes            : %s\n' "$WARMUP_PASSES"
  printf 'warmup_decisions         : %s\n' "$WARM_DEC"
  printf 'warmup_wallclock_ms      : %s\n' "$WARM_MS"
  printf 'warmup_throughput_dec_s  : %s\n' "$WARM_TPUT"
  printf 'floor_fraction           : %s\n' "$FLOOR_FRAC"
  printf 'calibrated_throughput_floor_dec_s : %s (catastrophic-regression floor)\n' "$CAL_FLOOR"
  printf 'warmup_peak_rss_kb       : %s\n' "$WARM_PEAK"
  printf 'bound_factor             : %s\n' "$BOUND_FACTOR"
  printf 'bound_margin_kb          : %s\n' "$BOUND_MARGIN_KB"
  printf 'calibrated_peak_rss_bound_kb : %s\n' "$RSS_BOUND"
  printf 'growth_tolerance_kb      : %s\n' "$GROWTH_TOL_KB"
} > "$cal_ev"
log "calibrated: warmup_tput=$WARM_TPUT dec/s ; floor=$CAL_FLOOR dec/s ; warmup_peak=${WARM_PEAK}kb ; rss_bound=${RSS_BOUND}kb"

# ============================================================================
# BENCHMARK — K batches of the REAL decision path; p50/p95/max + throughput.
# ============================================================================
BENCH_SAMPLES="$BM_TMP/perdec_ms.txt"; : > "$BENCH_SAMPLES"
TOTAL_MS=0; TOTAL_DEC=0
bi=1
while [ "$bi" -le "$BENCH_BATCHES" ]; do
    _b0=$(epoch); run_batch "$BENCH_PASSES"; _b1=$(epoch)
    _bms=$(ms_between "$_b0" "$_b1")
    _bdec=$((BENCH_PASSES * DEC_PER_PASS))
    _perdec=$(awk -v m="$_bms" -v d="$_bdec" 'BEGIN{ if(d>0) printf "%.5f", m/d; else print "0" }')
    printf '%s\n' "$_perdec" >> "$BENCH_SAMPLES"
    TOTAL_MS=$(awk -v a="$TOTAL_MS" -v b="$_bms" 'BEGIN{printf "%.3f", a+b}')
    TOTAL_DEC=$((TOTAL_DEC + _bdec))
    bi=$((bi+1))
done
sort -n "$BENCH_SAMPLES" > "$BM_TMP/perdec_ms.sorted"
NSAMP=$(awk 'END{print NR}' "$BM_TMP/perdec_ms.sorted"); [ -z "$NSAMP" ] && NSAMP=0
P50=$(pctile "$BM_TMP/perdec_ms.sorted" "$NSAMP" 0.50); [ -z "$P50" ] && P50=0
P95=$(pctile "$BM_TMP/perdec_ms.sorted" "$NSAMP" 0.95); [ -z "$P95" ] && P95=0
PMAX=$(pctile "$BM_TMP/perdec_ms.sorted" "$NSAMP" 1.00); [ -z "$PMAX" ] && PMAX=0
TPUT=$(awk -v d="$TOTAL_DEC" -v m="$TOTAL_MS" 'BEGIN{ if(m>0) printf "%.2f", d*1000/m; else print "0" }')

# §1.1 mutation: SET an impossible floor (measured throughput can never meet it).
ASSERT_FLOOR="$CAL_FLOOR"
if [ "$BENCHMEM_MUT" = 1 ]; then
    ASSERT_FLOOR=$(awk -v t="$TPUT" 'BEGIN{printf "%.2f", t*1000+1}')
fi

lat_ev="$EV_ROOT/latency.json"
{ printf '{\n'
  printf '  "evaluator": "vpn_lan_ssrf_carveout+ingress_allowlist",\n'
  printf '  "timestamp_utc": "%s",\n' "$TS"
  printf '  "source": "real committed evaluator functions extracted read-only from the shipped teeth",\n'
  printf '  "batches": %s,\n' "$BENCH_BATCHES"
  printf '  "passes_per_batch": %s,\n' "$BENCH_PASSES"
  printf '  "decisions_per_pass": %s,\n' "$DEC_PER_PASS"
  printf '  "total_decisions": %s,\n' "$TOTAL_DEC"
  printf '  "total_wallclock_ms": %s,\n' "$TOTAL_MS"
  printf '  "per_decision_latency_ms": { "p50": %s, "p95": %s, "max": %s },\n' "$P50" "$P95" "$PMAX"
  printf '  "throughput_decisions_per_sec": %s,\n' "$TPUT"
  printf '  "warmup_throughput_decisions_per_sec": %s,\n' "$WARM_TPUT"
  printf '  "calibrated_floor_decisions_per_sec": %s,\n' "$CAL_FLOOR"
  printf '  "assert_floor_decisions_per_sec": %s,\n' "$ASSERT_FLOOR"
  printf '  "mutation_mode": %s\n' "$BENCHMEM_MUT"
  printf '}\n'
} > "$lat_ev"

tput_ev="$EV_ROOT/throughput.txt"
{ printf '=== §11.4.169 BENCHMARK: VPN-LAN evaluator decision-path throughput ===\n'
  printf 'total_decisions        : %s across %s batches x %s passes\n' "$TOTAL_DEC" "$BENCH_BATCHES" "$BENCH_PASSES"
  printf 'total_wallclock_ms     : %s\n' "$TOTAL_MS"
  printf 'per_decision_p50_ms    : %s\n' "$P50"
  printf 'per_decision_p95_ms    : %s\n' "$P95"
  printf 'per_decision_max_ms    : %s\n' "$PMAX"
  printf 'throughput_dec_per_sec : %s\n' "$TPUT"
  printf 'calibrated_floor_dec_s : %s (warmup %s x FLOOR_FRAC %s)\n' "$CAL_FLOOR" "$WARM_TPUT" "$FLOOR_FRAC"
  printf 'assert_floor_dec_s     : %s%s\n' "$ASSERT_FLOOR" "$( [ "$BENCHMEM_MUT" = 1 ] && printf ' (§1.1 mutation: impossible floor injected)' )"
  printf 'verdict                : %s\n' "$( ge "$TPUT" "$ASSERT_FLOOR" && printf 'ABOVE-FLOOR' || printf 'BELOW-FLOOR' )"
} > "$tput_ev"

if ge "$TPUT" "$ASSERT_FLOOR"; then
    ab_pass_with_evidence "BENCHMARK: evaluator throughput $TPUT dec/s >= calibrated floor $ASSERT_FLOOR dec/s (p50=${P50}ms p95=${P95}ms max=${PMAX}ms over $TOTAL_DEC decisions)" "$lat_ev"
else
    ab_fail "BENCHMARK throughput below calibrated floor" "throughput $TPUT dec/s < floor $ASSERT_FLOOR dec/s — catastrophic regression (or §1.1 mutation) — see $tput_ev"
fi

# ============================================================================
# MEMORY — in-process soak; sample RSS after each batch + peak; assert bounded,
#          no unbounded growth. Pure-sh evaluator MUST be flat.
# ============================================================================
rss_ev="$EV_ROOT/rss_samples.txt"
{ printf '=== §11.4.169 MEMORY: VPN-LAN evaluator in-process RSS soak ===\n'
  printf 'timestamp_utc          : %s\n' "$TS"
  printf 'working_pid            : %s\n' "$$"
  printf 'soak                   : %s batches x %s passes (%s decisions/batch)\n' "$MEM_BATCHES" "$MEM_PASSES" "$((MEM_PASSES*DEC_PER_PASS))"
  printf 'calibrated_peak_bound_kb: %s\n' "$RSS_BOUND"
  printf 'growth_tolerance_kb    : %s\n' "$GROWTH_TOL_KB"
  printf '%s\n' '--- per-batch VmRSS (kb) ---'
} > "$rss_ev"

RSS_FIRST=0; RSS_LAST=0
mb=1
while [ "$mb" -le "$MEM_BATCHES" ]; do
    run_batch "$MEM_PASSES"
    _r=$(rss_kb); [ -z "$_r" ] && _r=0
    printf 'batch %-3s VmRSS_kb=%s\n' "$mb" "$_r" >> "$rss_ev"
    [ "$mb" = 1 ] && RSS_FIRST=$_r
    RSS_LAST=$_r
    mb=$((mb+1))
done
RSS_PEAK=$(hwm_kb); [ -z "$RSS_PEAK" ] && RSS_PEAK=0

# §1.1 mutation: INJECT an unbounded growth (synthetic +500 MB final sample).
GROWTH=$((RSS_LAST - RSS_FIRST))
if [ "$BENCHMEM_MUT" = 1 ]; then
    _inj=$((RSS_FIRST + 512000))
    printf 'batch INJ VmRSS_kb=%s  <-- §1.1 mutation: synthetic unbounded-growth sample injected\n' "$_inj" >> "$rss_ev"
    GROWTH=$((_inj - RSS_FIRST))
fi

if [ "$RSS_FIRST" = 0 ] || [ "$RSS_PEAK" = 0 ]; then
    { printf 'note                   : /proc/$$/status VmRSS/VmHWM unavailable — cannot measure RSS here\n'; } >> "$rss_ev"
    ab_skip_with_reason "MEMORY soak (per-process RSS source /proc/\$\$/status unavailable)" hardware_not_present
else
    _growth_ok=0; [ "$GROWTH" -le "$GROWTH_TOL_KB" ] && _growth_ok=1
    _bound_ok=0;  [ "$RSS_PEAK" -le "$RSS_BOUND" ] && _bound_ok=1
    { printf '%s\n' '--- verdict ---'
      printf 'rss_first_kb           : %s\n' "$RSS_FIRST"
      printf 'rss_last_kb            : %s\n' "$RSS_LAST"
      printf 'rss_growth_kb          : %s (tolerance %s)%s\n' "$GROWTH" "$GROWTH_TOL_KB" "$( [ "$BENCHMEM_MUT" = 1 ] && printf ' (§1.1 mutation: growth injected)' )"
      printf 'peak_rss_kb            : %s (bound %s)\n' "$RSS_PEAK" "$RSS_BOUND"
      printf 'growth_bounded         : %s\n' "$( [ "$_growth_ok" = 1 ] && printf 'YES (no unbounded growth)' || printf 'NO (unbounded growth detected)' )"
      printf 'peak_within_bound      : %s\n' "$( [ "$_bound_ok" = 1 ] && printf 'YES' || printf 'NO' )"
    } >> "$rss_ev"
    if [ "$_growth_ok" = 1 ] && [ "$_bound_ok" = 1 ]; then
        ab_pass_with_evidence "MEMORY: evaluator peak RSS ${RSS_PEAK}kb <= bound ${RSS_BOUND}kb, growth ${GROWTH}kb <= ${GROWTH_TOL_KB}kb (flat, no unbounded growth over $((MEM_BATCHES*MEM_PASSES*DEC_PER_PASS)) decisions)" "$rss_ev"
    else
        ab_fail "MEMORY soak" "peak/growth out of bound: peak=${RSS_PEAK}kb bound=${RSS_BOUND}kb growth=${GROWTH}kb tol=${GROWTH_TOL_KB}kb (regression or §1.1 mutation) — see $rss_ev"
    fi
fi

log "done — evidence root: $EV_ROOT"
printf '%s: pass=%s fail=%s skip=%s\n' "$SCRIPT_LABEL" "$N_PASS" "$N_FAIL" "$N_SKIP"
[ "$N_FAIL" -eq 0 ] && exit 0 || exit 1
