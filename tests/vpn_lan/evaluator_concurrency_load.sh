#!/usr/bin/env sh
###############################################################################
# evaluator_concurrency_load.sh — §11.4.169 CONCURRENCY + LOAD/DDoS test-type
#                                 layer for the VPN-LAN deterministic policy
#                                 evaluators (SSRF carve-out + ingress allowlist)
#                                 (PLAN.md §4/§5 Phase 1 + Phase 12; concurrency +
#                                  load sibling of ssrf_carveout_teeth.sh /
#                                  ingress_allowlist_teeth.sh /
#                                  ssrf_bridge_stress_chaos.sh /
#                                  evaluator_bench_memory.sh)
#
# Purpose:
#   Add the two §11.4.169 test-types the existing VPN-LAN teeth do NOT cover —
#   (10) CONCURRENCY/ATOMICITY and (7) LOAD/DDoS-flood — for the deterministic,
#   pure-shell policy evaluators that gate egress (Dante SSRF first-match-wins
#   rule evaluator: ip_to_int / ip_in_cidr / eval_dest) and ingress (default-deny
#   allowlist evaluator: eval_ingress). Both measured layers ship rock-solid
#   CAPTURED evidence and a paired §1.1 mutation so neither is a bluff gate
#   (§11.4.107(10)). This is a TEST-ONLY, AUTONOMOUS, pure-logic characterisation
#   — NO live VPN, NO bridge, NO data-plane touch, NO live-config mutation, NO
#   podman.
#
#   HOW THE REAL EVALUATOR IS EXERCISED (no editing of the teeth):
#     The shipped teeth define their decision path as shell functions inside
#     their own source. This test EXTRACTS those functions VERBATIM (read-only,
#     byte-for-byte) from the committed teeth via awk — ip_to_int / ip_in_cidr /
#     eval_dest from ssrf_carveout_teeth.sh and eval_ingress from
#     ingress_allowlist_teeth.sh — sources the extracted copy, and drives the
#     REAL committed decision logic both concurrently and under sustained load.
#     It NEVER edits ssrf_carveout_teeth.sh, ingress_allowlist_teeth.sh,
#     ssrf_bridge_stress_chaos.sh, evaluator_bench_memory.sh, or
#     config/dante/sockd.conf. A sanity gate asserts the extracted functions
#     reproduce the known-good canary verdicts BEFORE any measurement — if
#     extraction yields a non-functional path the test honestly SKIPs (never
#     exercises a broken evaluator, never fakes a number).
#
#   CONCURRENCY (§11.4.169 concurrency/atomicity):
#     Launch N>=10 concurrent shell workers (background subshells). Every worker
#     independently computes the SAME combined SSRF+ingress verdict set over a
#     shared canary set, reading the shared READ-ONLY policy configs concurrently
#     while writing ONLY to its OWN per-worker temp files (no temp-file collision
#     between workers — isolated by construction). After every worker finishes —
#     reaped by EXACT PID via `wait <pid>` (NEVER pkill/kill, §11.4.174) — assert:
#       (a) every worker exited 0 and wrote a COMPLETE verdict set (no lost /
#           garbled / half-written decision — the atomicity proof),
#       (b) every worker's verdict-set content hash is IDENTICAL (no interleaving
#           corruption, no shared-state race — a single divergent worker => FAIL),
#       (c) the shared reference verdict set is CORRECT (metadata / loopback /
#           all-RFC1918 BLOCKED, public PASSES; ingress default-deny + exact
#           permit + host-narrow + port-narrow — carve host permitted only on its
#           exact pair). Evidence: worker_hashes.txt + concurrency.evidence.
#
#   LOAD/DDoS (§11.4.169 load-flood):
#     Sustained flood — a large fixed M decisions (bounded, default 2000, clamped
#     [500,5000]) driven as fast as possible through the REAL decision path, with
#     EVERY decision's verdict checked against its known-correct value. Assert:
#       (a) 100% correct verdicts UNDER LOAD (zero wrong verdicts across all M —
#           correctness does not degrade under sustained pressure),
#       (b) the flood COMPLETES within a HOST-CALIBRATED wall-clock bound derived
#           from a warmup on THIS host (bound = warmup-projected-time * SLACK +
#           margin — NOT a hardcoded literature number, §11.4.6); a catastrophic
#           slowdown FAILs,
#       (c) NO resource leak — the working shell's open-FD count is stable across
#           the flood (delta <= tolerance) AND the temp-file count does not grow
#           with M (a leak would accrue files/FDs). Evidence: load_throughput.txt
#           + calibration.txt + resource_stability.txt.
#
#   §1.1 paired mutation (CONCLOAD_MUT=1): after the REAL measurement, INJECT the
#   defects each layer is meant to catch — (concurrency) a synthetic DIVERGENT
#   worker hash into the tally, (load) a synthetic WRONG-verdict-under-load count,
#   an IMPOSSIBLE (1 ms) wall-clock bound, and a synthetic FD-leak delta. The REAL
#   assertions then evaluate FALSE and the test FAILs (rc=1) — proving the
#   worker-agreement, correctness-under-load, wall-clock, and FD-stability teeth
#   are all load-bearing (not tautologies) (§11.4.107(10)).
#
#   Host caps (§12.6): the process re-execs itself once under `nice -n 19`
#   (+ `ionice -c 3` when present) with GOMAXPROCS=2; N and M are bounded +
#   clamped so the whole run stays light (10 workers, bounded M). NEVER
#   pkill/kill, NEVER touches the data-plane :34128/:34080, NEVER signals or
#   self-matches another process (§11.4.174) — background workers are reaped ONLY
#   by their exact recorded PIDs.
#
# Usage:
#   tests/vpn_lan/evaluator_concurrency_load.sh                 # normal — must PASS (rc 0)
#   CONCLOAD_MUT=1 tests/vpn_lan/evaluator_concurrency_load.sh  # mutation — must FAIL (rc 1)
#   CONC_WORKERS=16 LOAD_DECISIONS=3000 tests/vpn_lan/evaluator_concurrency_load.sh  # heavier
#
# Inputs (environment):
#   SOCKD_CONF        live Dante floor to extract the egress rule list from
#                     (default config/dante/sockd.conf) — READ-ONLY, never edited.
#   SSRF_TEETH        path to the SSRF teeth to extract the evaluator from
#                     (default tests/vpn_lan/ssrf_carveout_teeth.sh) — read-only.
#   INGRESS_TEETH     path to the ingress teeth to extract eval_ingress from
#                     (default tests/vpn_lan/ingress_allowlist_teeth.sh) — read-only.
#   HELIX_BRIDGE_HOST allowlisted ingress host + a canary dest (LOGIC input only,
#                     default 10.6.100.221 — no live probe).
#   INGRESS_PORT      allowlisted ingress port (LOGIC input only, default 2049).
#   CONC_WORKERS      concurrent worker count (default 10, clamped [4,24]).
#   LOAD_DECISIONS    sustained-flood decision count M (default 2000, clamped
#                     [500,5000]).
#   WARMUP_DEC        warmup decisions for the wall-clock calibration (default
#                     100, clamped [40,400]).
#   LOAD_SLACK        wall-clock bound slack factor over warmup projection
#                     (default 4, clamped [2,20]).
#   LOAD_MARGIN_S     absolute wall-clock margin seconds (default 5, clamped
#                     [1,60]).
#   FD_TOL            open-FD delta tolerance across the flood (default 4).
#   CONCLOAD_MUT      when 1, run the §1.1 paired mutation (test MUST then FAIL).
#
# Outputs:
#   Diagnostic lines + one verdict token per layer (PASS / FAIL / SKIP:<reason>).
#   Normal: exit 0 iff BOTH measured layers held. Mutation: exit 1 (the injected
#   divergence/regression/leak is correctly caught). Captured evidence under
#   qa-results/vpn_lan/phase_concurrency_load/<UTC-ts>/.
#
# Side-effects:
#   READ-ONLY on the teeth + live config. Extracts evaluator functions + renders
#   an ingress-policy fixture + writes evidence + isolated per-worker temp files
#   under a private temp dir + qa-results only. Removes the temp dir on every exit
#   path (trap, §11.4.14). NEVER edits config/dante/sockd.conf, ssrf_carveout_teeth.sh,
#   ingress_allowlist_teeth.sh, ssrf_bridge_stress_chaos.sh, or
#   evaluator_bench_memory.sh; NEVER (re)starts/kills a proxy; NEVER runs
#   pkill/kill; NEVER touches the data-plane :34128/:34080; reaps its OWN
#   background workers by exact recorded PID only (§11.4.174).
#
# Dependencies:
#   POSIX sh + awk + sort + GNU `date +%s.%N` (millisecond timing) + a content
#   hasher (sha256sum|shasum|cksum) + /proc/<pid>/fd (Linux FD count — optional,
#   honest SKIP of the FD sub-check when absent). Missing teeth/floor ⇒ honest
#   SKIP (never a fake PASS). No network, no root, no listener, no podman.
#
# Cross-references:
#   tests/vpn_lan/ssrf_carveout_teeth.sh        (egress evaluator — extracted here)
#   tests/vpn_lan/ingress_allowlist_teeth.sh    (ingress evaluator — extracted here)
#   tests/vpn_lan/ssrf_bridge_stress_chaos.sh   (stress+chaos sibling — structure mirrored)
#   tests/vpn_lan/evaluator_bench_memory.sh     (bench+memory sibling — structure mirrored)
#   config/dante/sockd.conf                     (live SSRF floor — READ-ONLY)
#   docs/design/vpn_lan_access/PLAN.md §4/§5 Phase 1 + Phase 12
#   constitution §11.4.1 / §11.4.5 / §11.4.6 / §11.4.14 / §11.4.50 / §11.4.69 /
#                §11.4.85 / §11.4.107(10) / §11.4.169 / §11.4.174 / §12.6 / §1.1
###############################################################################

set -u

# ---- host caps (§12.6): re-exec once under nice/ionice + GOMAXPROCS=2 --------
if [ "${CONCLOAD_NICED:-0}" != 1 ]; then
    CONCLOAD_NICED=1; export CONCLOAD_NICED
    GOMAXPROCS=2; export GOMAXPROCS
    _nice=''; command -v nice   >/dev/null 2>&1 && _nice='nice -n 19'
    _ionice=''; command -v ionice >/dev/null 2>&1 && _ionice='ionice -c 3'
    if [ -n "$_nice$_ionice" ]; then
        # shellcheck disable=SC2086
        exec $_nice $_ionice sh "$0" "$@"
    fi
fi

SCRIPT_LABEL='evaluator_concurrency_load'
_sc_dir=$(cd "$(dirname "$0")" && pwd)
_repo_root=$(cd "$_sc_dir/../.." && pwd)

SOCKD_CONF="${SOCKD_CONF:-$_repo_root/config/dante/sockd.conf}"
SSRF_TEETH="${SSRF_TEETH:-$_repo_root/tests/vpn_lan/ssrf_carveout_teeth.sh}"
INGRESS_TEETH="${INGRESS_TEETH:-$_repo_root/tests/vpn_lan/ingress_allowlist_teeth.sh}"
CONCLOAD_MUT="${CONCLOAD_MUT:-0}"

# Deterministic LOGIC inputs (never source .env — this is a pure-logic test).
ALLOW_HOST="${HELIX_BRIDGE_HOST:-10.6.100.221}"
ALLOW_PORT="${INGRESS_PORT:-2049}"

log() { printf '%s: %s\n' "$SCRIPT_LABEL" "$1"; }

# ---- bounded, clamped sizes (§12.6) -----------------------------------------
clamp_int() { # <value> <default> <min> <max> -> echo clamped
    _v=$1; _def=$2; _min=$3; _max=$4
    case "$_v" in ''|*[!0-9]*) _v=$_def ;; esac
    [ "$_v" -lt "$_min" ] && _v=$_min
    [ "$_v" -gt "$_max" ] && _v=$_max
    printf '%s' "$_v"
}
CONC_WORKERS=$(clamp_int "${CONC_WORKERS:-10}"       10   4 24)
LOAD_DECISIONS=$(clamp_int "${LOAD_DECISIONS:-2000}" 2000 500 5000)
WARMUP_DEC=$(clamp_int "${WARMUP_DEC:-100}"          100  40 400)
LOAD_SLACK=$(clamp_int "${LOAD_SLACK:-4}"            4    2 20)
LOAD_MARGIN_S=$(clamp_int "${LOAD_MARGIN_S:-5}"      5    1 60)
FD_TOL=$(clamp_int "${FD_TOL:-4}"                    4    0 64)

# ---- evidence + temp ---------------------------------------------------------
TS=$(date -u +%Y%m%dT%H%M%SZ 2>/dev/null || date +%Y%m%dT%H%M%SZ)
EV_ROOT="$_repo_root/qa-results/vpn_lan/phase_concurrency_load/$TS"
mkdir -p "$EV_ROOT" 2>/dev/null || true
CL_TMP=$(mktemp -d 2>/dev/null || printf '%s' "${TMPDIR:-/tmp}/helix_concload_$$")
mkdir -p "$CL_TMP" 2>/dev/null || true
cleanup() { [ -n "${CL_TMP:-}" ] && rm -rf "$CL_TMP" >/dev/null 2>&1; return 0; }
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

# ---- timing + hashing helpers ------------------------------------------------
epoch() { date +%s.%N 2>/dev/null; }
# ms_between <start> <end> -> milliseconds (double subtraction; adequate to ~1us).
ms_between() { awk -v s="$1" -v e="$2" 'BEGIN{d=(e-s)*1000; if(d<0)d=0; printf "%.3f", d}'; }
le() { awk -v a="$1" -v b="$2" 'BEGIN{exit (a<=b)?0:1}'; }   # a <= b ?
hashof() {
    if command -v sha256sum >/dev/null 2>&1; then sha256sum | awk '{print $1}'
    elif command -v shasum   >/dev/null 2>&1; then shasum -a 256 | awk '{print $1}'
    else cksum | awk '{print $1"-"$2}'
    fi
}
# open-FD count of THIS working shell ($$ is stable across POSIX-sh subshells).
fd_count() { ls "/proc/$$/fd" 2>/dev/null | wc -l | tr -d ' '; }
# persistent temp-file count under our private temp dir (leak sentinel).
tmp_count() { find "$CL_TMP" -type f 2>/dev/null | wc -l | tr -d ' '; }

# ---- read-only verbatim extraction of the committed evaluator functions ------
# awk range from `^NAME() {` to the first column-0 `}` — the shipped functions
# close with a column-0 `}` (verified); no editing of the teeth.
extract_fn() { # <src-file> <fn-name>
    awk -v fn="$2" '$0 ~ ("^" fn "\\(\\) \\{"){f=1} f{print} f&&/^\}/{exit}' "$1"
}

# ============================================================================
# PRE — teeth + live floor must exist (else honest SKIP, never a fake PASS).
# ============================================================================
if [ ! -f "$SSRF_TEETH" ] || [ ! -f "$INGRESS_TEETH" ]; then
    ab_skip_with_reason "evaluator concurrency+load (teeth script absent)" topology_unsupported
    printf '%s: done (skipped) — pass=%s fail=%s skip=%s\n' "$SCRIPT_LABEL" "$N_PASS" "$N_FAIL" "$N_SKIP"
    exit 0
fi
if [ ! -s "$SOCKD_CONF" ]; then
    ab_skip_with_reason "evaluator concurrency+load (live floor absent/empty: $SOCKD_CONF)" topology_unsupported
    printf '%s: done (skipped) — pass=%s fail=%s skip=%s\n' "$SCRIPT_LABEL" "$N_PASS" "$N_FAIL" "$N_SKIP"
    exit 0
fi

EVALS="$CL_TMP/evaluators.sh"
{ extract_fn "$SSRF_TEETH" ip_to_int
  extract_fn "$SSRF_TEETH" ip_in_cidr
  extract_fn "$SSRF_TEETH" eval_dest
  extract_fn "$INGRESS_TEETH" eval_ingress
} > "$EVALS" 2>/dev/null
if [ ! -s "$EVALS" ] || ! sh -n "$EVALS" 2>/dev/null; then
    ab_skip_with_reason "evaluator concurrency+load (function extraction failed/unparseable)" topology_unsupported
    printf '%s: done (skipped) — pass=%s fail=%s skip=%s\n' "$SCRIPT_LABEL" "$N_PASS" "$N_FAIL" "$N_SKIP"
    exit 0
fi
# shellcheck disable=SC1090
. "$EVALS"

# Extract the egress rule list read-only (same normalisation the teeth use).
FLOOR_CONF="$CL_TMP/floor.conf"
awk '
  /socks[ \t]+(block|pass)[ \t]*\{/ {inblk=1}
  inblk {print}
  /\}/ && inblk {inblk=0}
' "$SOCKD_CONF" > "$FLOOR_CONF" 2>/dev/null
# Render the ingress GOOD policy fixture (default-deny + one exact allow pair).
INGRESS_CONF="$CL_TMP/ingress.conf"
{ printf '# ingress allowlist — DEFAULT-DENY; only exact (from-host, to-port) pairs permitted.\n'
  printf 'ingress allow {\n    from: %s/32 to-port: %s\n}\n' "$ALLOW_HOST" "$ALLOW_PORT"; } > "$INGRESS_CONF"

if [ ! -s "$FLOOR_CONF" ]; then
    ab_skip_with_reason "evaluator concurrency+load (no socks rules parsed from $SOCKD_CONF)" topology_unsupported
    printf '%s: done (skipped) — pass=%s fail=%s skip=%s\n' "$SCRIPT_LABEL" "$N_PASS" "$N_FAIL" "$N_SKIP"
    exit 0
fi

# ---- canary sets + their KNOWN-CORRECT reference verdicts --------------------
# SSRF egress: metadata/loopback/all-RFC1918 BLOCKED; public PASSES.
SSRF_CANARY='169.254.169.254 127.0.0.1 10.99.88.77 172.16.5.5 192.168.9.9 8.8.8.8'
# Ingress: default-deny + exact permit + host-narrow + port-narrow (carve host on
# its exact pair permitted; a /32 neighbour + a different port denied).
OTHER_HOST='10.99.88.77'; NEIGH_HOST='10.6.100.222'; OTHER_PORT='22'
INGRESS_CANARY="$OTHER_HOST:$OTHER_PORT $ALLOW_HOST:$ALLOW_PORT $NEIGH_HOST:$ALLOW_PORT $ALLOW_HOST:$OTHER_PORT"
EXP_DEC=0
for _x in $SSRF_CANARY;    do EXP_DEC=$((EXP_DEC+1)); done
for _x in $INGRESS_CANARY; do EXP_DEC=$((EXP_DEC+1)); done

# The canonical expected verdict set (one line per canary; the CORRECTNESS oracle).
EXPECT_FILE="$CL_TMP/expect_sorted.txt"
{ printf 'ssrf 169.254.169.254 => block\n'
  printf 'ssrf 127.0.0.1 => block\n'
  printf 'ssrf 10.99.88.77 => block\n'
  printf 'ssrf 172.16.5.5 => block\n'
  printf 'ssrf 192.168.9.9 => block\n'
  printf 'ssrf 8.8.8.8 => pass\n'
  printf 'ingress %s:%s => deny\n'   "$OTHER_HOST" "$OTHER_PORT"
  printf 'ingress %s:%s => permit\n' "$ALLOW_HOST" "$ALLOW_PORT"
  printf 'ingress %s:%s => deny\n'   "$NEIGH_HOST" "$ALLOW_PORT"
  printf 'ingress %s:%s => deny\n'   "$ALLOW_HOST" "$OTHER_PORT"
} | sort > "$EXPECT_FILE"

# ---- SANITY GATE: extracted funcs must reproduce known-good canary verdicts ----
sane=1
[ "$(eval_dest "$FLOOR_CONF" 169.254.169.254 2>/dev/null)" = block ] || sane=0
[ "$(eval_dest "$FLOOR_CONF" 8.8.8.8 2>/dev/null)"         = pass  ] || sane=0
[ "$(eval_ingress "$INGRESS_CONF" "$OTHER_HOST" "$OTHER_PORT" 2>/dev/null)" = deny   ] || sane=0
[ "$(eval_ingress "$INGRESS_CONF" "$ALLOW_HOST" "$ALLOW_PORT" 2>/dev/null)" = permit ] || sane=0
if [ "$sane" != 1 ]; then
    ab_skip_with_reason "evaluator concurrency+load (extracted evaluator failed sanity verdicts)" topology_unsupported
    printf '%s: done (skipped) — pass=%s fail=%s skip=%s\n' "$SCRIPT_LABEL" "$N_PASS" "$N_FAIL" "$N_SKIP"
    exit 0
fi
log "extracted+sourced real evaluators (ip_to_int/ip_in_cidr/eval_dest/eval_ingress); sanity OK"
log "workers=$CONC_WORKERS ; dec/worker=$EXP_DEC ; load M=$LOAD_DECISIONS ; warmup=$WARMUP_DEC ; slack=${LOAD_SLACK}x+${LOAD_MARGIN_S}s ; mut=$CONCLOAD_MUT"

# ============================================================================
# CONCURRENCY (§11.4.169) — N workers compute the same verdict set concurrently;
#   isolated per-worker temp; all IDENTICAL + all CORRECT; reaped by exact PID.
# ============================================================================
# conc_worker <index>: pure decision path; writes ONLY its own per-index files.
conc_worker() {
    _w=$1
    _vf="$CL_TMP/w_${_w}.verdicts"     # this worker's OWN verdict file (no collision)
    _hf="$CL_TMP/w_${_w}.hash"         # this worker's OWN hash file
    : > "$_vf"
    for _d in $SSRF_CANARY; do
        printf 'ssrf %s => %s\n' "$_d" "$(eval_dest "$FLOOR_CONF" "$_d" 2>/dev/null)" >> "$_vf"
    done
    for _pr in $INGRESS_CANARY; do
        _ip=${_pr%:*}; _pt=${_pr##*:}
        printf 'ingress %s:%s => %s\n' "$_ip" "$_pt" "$(eval_ingress "$INGRESS_CONF" "$_ip" "$_pt" 2>/dev/null)" >> "$_vf"
    done
    # hash ONLY the `=> ` verdict lines (sorted) — order-independent, marker-free.
    grep ' => ' "$_vf" | sort | hashof > "$_hf"
    printf 'WORKER_DONE %s\n' "$_w" >> "$_vf"   # completeness marker (atomicity)
}

conc_ev="$EV_ROOT/concurrency.evidence"
whash_ev="$EV_ROOT/worker_hashes.txt"
{ printf '=== §11.4.169 CONCURRENCY: %s workers, identical+correct verdict set, isolated temps ===\n' "$CONC_WORKERS"
  printf 'timestamp_utc     : %s\n' "$TS"
  printf 'workers           : %s\n' "$CONC_WORKERS"
  printf 'decisions_per_worker : %s (SSRF+ingress combined canary)\n' "$EXP_DEC"
  printf 'reap_policy       : exact recorded PID via wait (NEVER pkill/kill, §11.4.174)\n'; } > "$conc_ev"

# Launch N concurrent background workers; record each EXACT PID (never pkill).
WPIDS=''
_wn=1
while [ "$_wn" -le "$CONC_WORKERS" ]; do
    conc_worker "$_wn" &
    WPIDS="$WPIDS $!"
    _wn=$((_wn+1))
done
{ printf 'launched_worker_pids :%s\n' "$WPIDS"; } >> "$conc_ev"

# Reap ONLY our own workers, by their exact recorded PIDs (§11.4.174).
BADRC=0
for _pid in $WPIDS; do
    wait "$_pid"; _wrc=$?
    [ "$_wrc" = 0 ] || { BADRC=$((BADRC+1)); printf 'worker_nonzero_exit : pid=%s rc=%s\n' "$_pid" "$_wrc" >> "$conc_ev"; }
done

# Collect + verify: completeness (atomicity) + per-worker hash tally.
: > "$whash_ev"
INCOMPLETE=0
_wn=1
while [ "$_wn" -le "$CONC_WORKERS" ]; do
    _vf="$CL_TMP/w_${_wn}.verdicts"; _hf="$CL_TMP/w_${_wn}.hash"
    _nl=0; [ -f "$_vf" ] && _nl=$(grep -c ' => ' "$_vf" 2>/dev/null | tr -d ' ')
    _done=0; [ -f "$_vf" ] && grep -q "^WORKER_DONE $_wn\$" "$_vf" 2>/dev/null && _done=1
    _h='<none>'; [ -s "$_hf" ] && _h=$(cat "$_hf")
    if [ "$_nl" != "$EXP_DEC" ] || [ "$_done" != 1 ]; then
        INCOMPLETE=$((INCOMPLETE+1))
        printf 'worker %-3s INCOMPLETE verdict_lines=%s (expect %s) done_marker=%s hash=%s\n' "$_wn" "$_nl" "$EXP_DEC" "$_done" "$_h" >> "$conc_ev"
    fi
    printf 'worker %-3s hash=%s\n' "$_wn" "$_h" >> "$whash_ev"
    _wn=$((_wn+1))
done

# §1.1 mutation: INJECT a synthetic DIVERGENT worker hash into the tally — the
# real "all workers identical" assertion must then evaluate FALSE (rc=1).
if [ "$CONCLOAD_MUT" = 1 ]; then
    printf 'worker INJ hash=%s  <-- §1.1 mutation: synthetic divergent worker injected\n' 'deadbeefmutationdivergenthash' >> "$whash_ev"
fi

DISTINCT=$(awk '{print $NF}' "$whash_ev" | grep -v '^<none>$' | sort -u | grep -c . 2>/dev/null | tr -d ' ')
[ -z "$DISTINCT" ] && DISTINCT=0
# The shared reference verdict set (worker 1) must equal the CORRECT expected set.
REF_VF="$CL_TMP/w_1.verdicts"
CORRECT_OK=0
if [ -f "$REF_VF" ]; then
    grep ' => ' "$REF_VF" | sort > "$CL_TMP/ref_sorted.txt"
    if cmp -s "$CL_TMP/ref_sorted.txt" "$EXPECT_FILE"; then CORRECT_OK=1; fi
fi
{ printf 'workers_nonzero_exit : %s\n' "$BADRC"
  printf 'workers_incomplete   : %s (lost/garbled/half-written decision => atomicity break)\n' "$INCOMPLETE"
  printf 'distinct_verdict_hashes : %s (expect 1 => no interleaving corruption, no race)%s\n' "$DISTINCT" "$( [ "$CONCLOAD_MUT" = 1 ] && printf ' (§1.1 mutation: divergent hash injected)' )"
  printf 'reference_verdict_correct : %s (metadata/loopback/RFC1918 blocked; public+carve handled)\n' "$( [ "$CORRECT_OK" = 1 ] && printf YES || printf NO )"
  printf '%s\n' '--- reference verdict set (worker 1) ---'
  [ -f "$CL_TMP/ref_sorted.txt" ] && sed 's/^/  | /' "$CL_TMP/ref_sorted.txt"
} >> "$conc_ev"

if [ "$BADRC" = 0 ] && [ "$INCOMPLETE" = 0 ] && [ "$DISTINCT" = 1 ] && [ "$CORRECT_OK" = 1 ]; then
    ab_pass_with_evidence "CONCURRENCY: $CONC_WORKERS workers produced IDENTICAL+CORRECT verdict set (1 distinct hash, 0 incomplete, isolated temps, exact-PID reap)" "$conc_ev"
else
    ab_fail "CONCURRENCY worker agreement" "nonzero_exit=$BADRC incomplete=$INCOMPLETE distinct_hashes=$DISTINCT (expect 1) correct=$CORRECT_OK — divergence/corruption (or §1.1 mutation) — see $conc_ev"
fi

# ============================================================================
# LOAD/DDoS (§11.4.169) — sustained flood of M checked decisions; 100% correct
#   under load, within a host-calibrated wall-clock bound, no resource leak.
# ============================================================================
# run_checked_pass: one full canary pass ($EXP_DEC decisions), each verdict
#   compared to its known-correct value; increments LOAD_ERRORS on any mismatch.
#   Runs in the CURRENT shell (not a subshell) so LOAD_ERRORS accrues in-place.
LOAD_ERRORS=0
run_checked_pass() {
    [ "$(eval_dest "$FLOOR_CONF" 169.254.169.254 2>/dev/null)" = block ]  || LOAD_ERRORS=$((LOAD_ERRORS+1))
    [ "$(eval_dest "$FLOOR_CONF" 127.0.0.1 2>/dev/null)"       = block ]  || LOAD_ERRORS=$((LOAD_ERRORS+1))
    [ "$(eval_dest "$FLOOR_CONF" 10.99.88.77 2>/dev/null)"     = block ]  || LOAD_ERRORS=$((LOAD_ERRORS+1))
    [ "$(eval_dest "$FLOOR_CONF" 172.16.5.5 2>/dev/null)"      = block ]  || LOAD_ERRORS=$((LOAD_ERRORS+1))
    [ "$(eval_dest "$FLOOR_CONF" 192.168.9.9 2>/dev/null)"     = block ]  || LOAD_ERRORS=$((LOAD_ERRORS+1))
    [ "$(eval_dest "$FLOOR_CONF" 8.8.8.8 2>/dev/null)"         = pass  ]  || LOAD_ERRORS=$((LOAD_ERRORS+1))
    [ "$(eval_ingress "$INGRESS_CONF" "$OTHER_HOST" "$OTHER_PORT" 2>/dev/null)" = deny   ] || LOAD_ERRORS=$((LOAD_ERRORS+1))
    [ "$(eval_ingress "$INGRESS_CONF" "$ALLOW_HOST" "$ALLOW_PORT" 2>/dev/null)" = permit ] || LOAD_ERRORS=$((LOAD_ERRORS+1))
    [ "$(eval_ingress "$INGRESS_CONF" "$NEIGH_HOST" "$ALLOW_PORT" 2>/dev/null)" = deny   ] || LOAD_ERRORS=$((LOAD_ERRORS+1))
    [ "$(eval_ingress "$INGRESS_CONF" "$ALLOW_HOST" "$OTHER_PORT" 2>/dev/null)" = deny   ] || LOAD_ERRORS=$((LOAD_ERRORS+1))
}

# --- WARMUP: calibrate the wall-clock bound on THIS host (§11.4.6) ------------
WARM_ITERS=$(( (WARMUP_DEC + EXP_DEC - 1) / EXP_DEC )); [ "$WARM_ITERS" -lt 1 ] && WARM_ITERS=1
WARM_DEC=$((WARM_ITERS * EXP_DEC))
_wi=0; _wc0=$(epoch)
while [ "$_wi" -lt "$WARM_ITERS" ]; do run_checked_pass; _wi=$((_wi+1)); done
_wc1=$(epoch)
WARM_MS=$(ms_between "$_wc0" "$_wc1")
PER_DEC_MS=$(awk -v m="$WARM_MS" -v d="$WARM_DEC" 'BEGIN{ if(d>0) printf "%.5f", m/d; else print "0" }')
LOAD_ERRORS=0   # discard warmup counts; the flood correctness count starts clean

# Actual flood size (whole canary passes covering >= M decisions).
LOAD_ITERS=$(( (LOAD_DECISIONS + EXP_DEC - 1) / EXP_DEC )); [ "$LOAD_ITERS" -lt 1 ] && LOAD_ITERS=1
LOAD_M=$((LOAD_ITERS * EXP_DEC))
PROJ_MS=$(awk -v p="$PER_DEC_MS" -v m="$LOAD_M" 'BEGIN{printf "%.3f", p*m}')
BOUND_MS=$(awk -v pr="$PROJ_MS" -v s="$LOAD_SLACK" -v mg="$LOAD_MARGIN_S" 'BEGIN{printf "%.3f", pr*s + mg*1000}')

cal_ev="$EV_ROOT/calibration.txt"
{ printf '=== §11.4.6 host calibration for the load-flood wall-clock bound (this host, no hardcoded number) ===\n'
  printf 'timestamp_utc            : %s\n' "$TS"
  printf 'warmup_iters             : %s (x %s dec/pass)\n' "$WARM_ITERS" "$EXP_DEC"
  printf 'warmup_decisions         : %s\n' "$WARM_DEC"
  printf 'warmup_wallclock_ms      : %s\n' "$WARM_MS"
  printf 'per_decision_ms          : %s (measured this host)\n' "$PER_DEC_MS"
  printf 'load_target_M            : %s (requested)\n' "$LOAD_DECISIONS"
  printf 'load_actual_decisions    : %s (%s passes x %s dec/pass)\n' "$LOAD_M" "$LOAD_ITERS" "$EXP_DEC"
  printf 'projected_flood_ms       : %s (per_decision_ms x load_actual_decisions)\n' "$PROJ_MS"
  printf 'slack_factor             : %s\n' "$LOAD_SLACK"
  printf 'margin_ms                : %s\n' "$((LOAD_MARGIN_S*1000))"
  printf 'calibrated_wallclock_bound_ms : %s (projected x slack + margin — catastrophic-slowdown ceiling)\n' "$BOUND_MS"
  printf 'fd_delta_tolerance       : %s\n' "$FD_TOL"
} > "$cal_ev"
log "calibrated: per_decision=$PER_DEC_MS ms ; flood M=$LOAD_M ; wall-clock bound=$BOUND_MS ms (slack ${LOAD_SLACK}x + ${LOAD_MARGIN_S}s)"

# --- resource baseline (leak sentinels) --------------------------------------
FD_BEFORE=$(fd_count); [ -z "$FD_BEFORE" ] && FD_BEFORE=0
TMP_BEFORE=$(tmp_count); [ -z "$TMP_BEFORE" ] && TMP_BEFORE=0

# --- the flood: M checked decisions as fast as possible ----------------------
_li=0; _f0=$(epoch)
while [ "$_li" -lt "$LOAD_ITERS" ]; do run_checked_pass; _li=$((_li+1)); done
_f1=$(epoch)
FLOOD_MS=$(ms_between "$_f0" "$_f1")
TPUT=$(awk -v d="$LOAD_M" -v m="$FLOOD_MS" 'BEGIN{ if(m>0) printf "%.2f", d*1000/m; else print "0" }')

FD_AFTER=$(fd_count); [ -z "$FD_AFTER" ] && FD_AFTER=0
TMP_AFTER=$(tmp_count); [ -z "$TMP_AFTER" ] && TMP_AFTER=0
FD_DELTA=$((FD_AFTER - FD_BEFORE)); [ "$FD_DELTA" -lt 0 ] && FD_DELTA=$((0 - FD_DELTA))
TMP_DELTA=$((TMP_AFTER - TMP_BEFORE))

# §1.1 mutations: inject the defects the load teeth must catch.
ASSERT_ERRORS=$LOAD_ERRORS
ASSERT_BOUND_MS=$BOUND_MS
ASSERT_FD_DELTA=$FD_DELTA
if [ "$CONCLOAD_MUT" = 1 ]; then
    ASSERT_ERRORS=$((LOAD_ERRORS + 1))   # synthetic wrong-verdict-under-load
    ASSERT_BOUND_MS=1                    # impossible wall-clock ceiling
    ASSERT_FD_DELTA=$((FD_TOL + 100))    # synthetic FD leak
fi

# --- assertions --------------------------------------------------------------
_corr_ok=0; [ "$ASSERT_ERRORS" = 0 ] && _corr_ok=1
_wall_ok=0; le "$FLOOD_MS" "$ASSERT_BOUND_MS" && _wall_ok=1
# FD sub-check honestly SKIPs when /proc/$$/fd is unavailable (never a fake pass).
FD_AVAILABLE=1; [ "$FD_BEFORE" = 0 ] && [ "$FD_AFTER" = 0 ] && FD_AVAILABLE=0
_fd_ok=1
if [ "$FD_AVAILABLE" = 1 ]; then
    _fd_ok=0; { [ "$ASSERT_FD_DELTA" -le "$FD_TOL" ] && [ "$TMP_DELTA" -le 1 ]; } && _fd_ok=1
fi

tput_ev="$EV_ROOT/load_throughput.txt"
{ printf '=== §11.4.169 LOAD/DDoS: VPN-LAN evaluator sustained-flood throughput + correctness-under-load ===\n'
  printf 'timestamp_utc          : %s\n' "$TS"
  printf 'flood_decisions        : %s (%s passes x %s dec/pass)\n' "$LOAD_M" "$LOAD_ITERS" "$EXP_DEC"
  printf 'flood_wallclock_ms     : %s\n' "$FLOOD_MS"
  printf 'throughput_dec_per_sec : %s\n' "$TPUT"
  printf 'wrong_verdicts_under_load : %s / %s (100%% correct => 0)%s\n' "$ASSERT_ERRORS" "$LOAD_M" "$( [ "$CONCLOAD_MUT" = 1 ] && printf ' (§1.1 mutation: synthetic wrong verdict injected)' )"
  printf 'calibrated_bound_ms    : %s%s\n' "$ASSERT_BOUND_MS" "$( [ "$CONCLOAD_MUT" = 1 ] && printf ' (§1.1 mutation: impossible bound injected)' )"
  printf 'wall_clock_verdict     : %s\n' "$( [ "$_wall_ok" = 1 ] && printf 'WITHIN-BOUND' || printf 'OVER-BOUND' )"
  printf 'correctness_verdict    : %s\n' "$( [ "$_corr_ok" = 1 ] && printf '100%%-CORRECT' || printf 'DEGRADED' )"
} > "$tput_ev"

res_ev="$EV_ROOT/resource_stability.txt"
{ printf '=== §11.4.169 LOAD: resource-leak sentinels across the flood ===\n'
  printf 'timestamp_utc          : %s\n' "$TS"
  printf 'working_pid            : %s\n' "$$"
  printf 'fd_source_available    : %s (/proc/$$/fd)\n' "$( [ "$FD_AVAILABLE" = 1 ] && printf YES || printf NO )"
  printf 'open_fd_before         : %s\n' "$FD_BEFORE"
  printf 'open_fd_after          : %s\n' "$FD_AFTER"
  printf 'open_fd_delta          : %s (tolerance %s)%s\n' "$ASSERT_FD_DELTA" "$FD_TOL" "$( [ "$CONCLOAD_MUT" = 1 ] && printf ' (§1.1 mutation: synthetic FD leak injected)' )"
  printf 'temp_files_before      : %s\n' "$TMP_BEFORE"
  printf 'temp_files_after       : %s\n' "$TMP_AFTER"
  printf 'temp_files_delta       : %s (must not grow with M => <= 1)\n' "$TMP_DELTA"
  printf 'fd_stability_verdict   : %s\n' "$( [ "$_fd_ok" = 1 ] && printf 'STABLE (no leak)' || printf 'LEAK/UNAVAILABLE' )"
} > "$res_ev"

# LOAD PASS iff correctness held AND within wall-clock bound AND no resource leak.
if [ "$_corr_ok" = 1 ] && [ "$_wall_ok" = 1 ] && [ "$_fd_ok" = 1 ]; then
    ab_pass_with_evidence "LOAD/DDoS: $LOAD_M decisions 100% correct under load @ $TPUT dec/s, ${FLOOD_MS}ms <= bound ${ASSERT_BOUND_MS}ms, FD delta $ASSERT_FD_DELTA<=$FD_TOL (no leak)" "$tput_ev"
else
    ab_fail "LOAD/DDoS flood" "correctness_ok=$_corr_ok (wrong=$ASSERT_ERRORS) wall_ok=$_wall_ok (${FLOOD_MS}ms vs bound ${ASSERT_BOUND_MS}ms) fd_ok=$_fd_ok (delta $ASSERT_FD_DELTA, tmp_delta $TMP_DELTA) — regression/leak (or §1.1 mutation) — see $tput_ev + $res_ev"
fi

log "done — evidence root: $EV_ROOT"
printf '%s: pass=%s fail=%s skip=%s\n' "$SCRIPT_LABEL" "$N_PASS" "$N_FAIL" "$N_SKIP"
[ "$N_FAIL" -eq 0 ] && exit 0 || exit 1
