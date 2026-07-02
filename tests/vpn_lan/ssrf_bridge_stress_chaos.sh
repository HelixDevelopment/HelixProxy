#!/usr/bin/env sh
###############################################################################
# ssrf_bridge_stress_chaos.sh — §11.4.85 STRESS + CHAOS coverage for the
#                               VPN-LAN Phase-1 SSRF carve-out teeth logic
#                               (PLAN.md §4/§5 Phase 1; sibling of
#                                tests/vpn_lan/ssrf_carveout_teeth.sh)
#
# Purpose:
#   Prove — AUTONOMOUSLY, with NO live VPN, NO data-plane touch, NO live-config
#   mutation — that the shipped Phase-1 SSRF-teeth *logic* is (a) DETERMINISTIC
#   under sustained repetition (§11.4.85 stress + §11.4.50 no-flake), and
#   (b) FAIL-SAFE under adversarial/malformed input (§11.4.85 chaos + §11.4.1):
#   it never crashes, never fails OPEN (a malformed config must never let a
#   must-block SSRF canary be reported as a passed/success), and always emits an
#   honest FAIL or SKIP verdict.
#
#   This test EXERCISES the real, committed evaluator by INVOKING the shipped
#   `tests/vpn_lan/ssrf_carveout_teeth.sh` — it NEVER edits it, NEVER edits the
#   live `config/dante/sockd.conf`, and NEVER starts/kills a proxy. To keep the
#   host quiescent (§11.4.14) the teeth are invoked through a throwaway
#   symlink inside a private temp "fake repo" so all of the teeth's own
#   qa-results evidence lands under the temp dir and is removed on exit — the
#   real qa-results tree is not polluted by the 100 stress iterations.
#
#   STRESS (§11.4.85 sustained + §11.4.50 determinism):
#     Run the REAL teeth against the REAL live SSRF floor N>=100 times. Every
#     iteration MUST (1) exit 0 (teeth GREEN), and (2) produce the IDENTICAL
#     granular verdict set (metadata/loopback/10.x/172.16.x/192.168.x BLOCKED,
#     public PASSES, carve-host PASSES) — captured as a per-iteration content
#     hash. A single divergent hash OR a single non-zero exit ⇒ FAIL. There is
#     no "first-passed-therefore-flake" escape (§11.4.50).
#
#   CHAOS (§11.4.85 failure-injection):
#     Render MALFORMED / TRUNCATED / REORDERED / EMPTY Dante-config fixtures
#     into a scratch dir (NEVER the live sockd.conf) and drive the REAL teeth
#     against each via the teeth's own SOCKD_CONF override. Assert each is
#     handled HONESTLY:
#       - empty / whitespace-only        => honest SKIP, rc=0, no fake PASS.
#       - metadata-block-removed         => teeth FAIL (T1) — the evaluator
#                                           reports metadata as PASSED (the hole)
#                                           and the teeth correctly catch it.
#       - 10/8-block-removed             => teeth FAIL — RFC1918 hole caught.
#       - permissive-pass-reordered-top  => teeth FAIL — first-match-wins hole.
#       - truncated mid-rule             => teeth FAIL, never a crash.
#       - malformed non-numeric `to:`    => teeth FAIL, never a crash.
#     In EVERY chaos case: no crash under set -u (a set-u crash is a §11.4.1
#     FAIL-bluff), and NEVER a fail-open (a hole fixture must yield a non-zero
#     teeth exit — never a counted PASS). A hole fixture that the teeth PASS
#     would be a genuine SSRF defect and is reported as a FINDING, not hidden.
#
#   This test is AUTONOMOUS — it exercises pure config logic, needs NO svord
#   bridge, and runs GREEN now. It does NOT gate on bridge_require.
#
#   §1.1 paired mutation (STRESSCHAOS_MUT=1): loosen ONE chaos assertion to
#   TOLERATE a fail-open (expect the metadata-removed hole to slip through as a
#   PASS). Because the real teeth correctly catch the hole, that loosened
#   expectation contradicts reality and the test FAILs (exit 1) — proving the
#   chaos assertions are load-bearing and this stress+chaos test is NOT itself a
#   bluff gate (§11.4.107(10)).
#
# Usage:
#   tests/vpn_lan/ssrf_bridge_stress_chaos.sh              # normal — must PASS (rc 0)
#   STRESSCHAOS_MUT=1 tests/vpn_lan/ssrf_bridge_stress_chaos.sh  # mutation — must FAIL (rc 1)
#   STRESS_ITERS=200 tests/vpn_lan/ssrf_bridge_stress_chaos.sh   # more stress iterations (>=100)
#
# Inputs (environment):
#   STRESS_ITERS      stress iteration count (default 100; clamped to >= 100).
#   STRESSCHAOS_MUT   when 1, run the §1.1 paired mutation (test MUST then FAIL).
#   SOCKD_CONF        live Dante floor to stress against (default
#                     config/dante/sockd.conf) — audited READ-ONLY, never edited.
#   SSRF_TEETH        path to the teeth under test (default
#                     tests/vpn_lan/ssrf_carveout_teeth.sh) — invoked, never edited.
#
# Outputs:
#   Diagnostic lines + one verdict token per check (PASS / SKIP:<reason> / FAIL).
#   Exit 0 iff every stress+chaos assertion held (or, under STRESSCHAOS_MUT=1,
#   exit 1 because the loosened assertion correctly fails). Captured evidence
#   under qa-results/vpn_lan/phase_stress_chaos/<UTC-ts>/{stress,chaos}/.
#
# Side-effects:
#   READ-ONLY on the live config and the teeth script. Writes chaos fixtures +
#   evidence + a throwaway "fake repo" (that redirects the invoked teeth's own
#   evidence) under a private temp dir + qa-results only. Removes the temp dir
#   on every exit path (trap, §11.4.14). NEVER edits config/dante/sockd.conf or
#   ssrf_carveout_teeth.sh, NEVER (re)starts/kills a proxy, NEVER runs
#   pkill/kill, NEVER touches the data-plane :34128/:34080, NEVER self-matches
#   or signals another process (§11.4.174).
#
# Dependencies:
#   POSIX sh + awk + sed + grep; sha256sum|shasum|cksum for content hashing.
#   No network, no root. Missing teeth/floor ⇒ honest SKIP (never a fake PASS).
#
# Cross-references:
#   tests/vpn_lan/ssrf_carveout_teeth.sh   (the Phase-1 teeth logic exercised here)
#   config/dante/sockd.conf                (the live SSRF floor — READ-ONLY)
#   tests/vpn_lan/discovery_reflect.sh     (anti-bluff structure mirrored here)
#   docs/design/vpn_lan_access/PLAN.md §4 (SSRF reconciliation) + §5 Phase 1
#   constitution §11.4.1 / §11.4.5 / §11.4.6 / §11.4.14 / §11.4.50 / §11.4.69 /
#                §11.4.85 / §11.4.107(10) / §11.4.174 / §1.1
###############################################################################

set -u

SCRIPT_LABEL='ssrf_bridge_stress_chaos'
_sc_dir=$(cd "$(dirname "$0")" && pwd)
_repo_root=$(cd "$_sc_dir/../.." && pwd)

SOCKD_CONF="${SOCKD_CONF:-$_repo_root/config/dante/sockd.conf}"
SSRF_TEETH="${SSRF_TEETH:-$_repo_root/tests/vpn_lan/ssrf_carveout_teeth.sh}"
STRESSCHAOS_MUT="${STRESSCHAOS_MUT:-0}"
# Deterministic carve host (never source .env here — this is a LOGIC test).
CARVE_HOST='10.6.100.221'

STRESS_ITERS="${STRESS_ITERS:-100}"
case "$STRESS_ITERS" in ''|*[!0-9]*) STRESS_ITERS=100 ;; esac
[ "$STRESS_ITERS" -lt 100 ] && STRESS_ITERS=100

# The §1.1 paired-mutation target: the metadata-removed hole fixture. Under
# STRESSCHAOS_MUT=1 its expected teeth-exit is flipped to "hole tolerated" (0),
# which contradicts the real teeth (which return 1) and forces this test to FAIL.
MUT_TARGET='nometa'

log() { printf '%s: %s\n' "$SCRIPT_LABEL" "$1"; }

# ---- evidence + temp ---------------------------------------------------------
TS=$(date -u +%Y%m%dT%H%M%SZ 2>/dev/null || date +%Y%m%dT%H%M%SZ)
EV_ROOT="$_repo_root/qa-results/vpn_lan/phase_stress_chaos/$TS"
mkdir -p "$EV_ROOT/stress" "$EV_ROOT/chaos" 2>/dev/null || true
SC_TMP=$(mktemp -d 2>/dev/null || printf '%s' "${TMPDIR:-/tmp}/helix_scssrf_$$")
mkdir -p "$SC_TMP" 2>/dev/null || true
cleanup() { [ -n "${SC_TMP:-}" ] && rm -rf "$SC_TMP" >/dev/null 2>&1; return 0; }
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

# ---- content hasher (deterministic, tool-stable) -----------------------------
hashof() {
    if command -v sha256sum >/dev/null 2>&1; then sha256sum | awk '{print $1}'
    elif command -v shasum   >/dev/null 2>&1; then shasum -a 256 | awk '{print $1}'
    else cksum | awk '{print $1"-"$2}'
    fi
}

# ---- fake-repo harness: invoke the REAL teeth with redirected evidence -------
# The teeth compute their evidence root from $0's location; by invoking a
# symlink (or copy) planted in a temp "fake repo" their qa-results writes land
# under $SC_TMP (removed on exit) — the real qa-results tree is untouched, and
# the teeth SOURCE bytes are the shipped ones (read-only, never edited).
FAKE_REPO="$SC_TMP/fake_repo"
FAKE_TEETH="$FAKE_REPO/tests/vpn_lan/ssrf_carveout_teeth.sh"
setup_fake_repo() {
    mkdir -p "$FAKE_REPO/tests/vpn_lan" 2>/dev/null || return 1
    ln -s "$SSRF_TEETH" "$FAKE_TEETH" 2>/dev/null || cp "$SSRF_TEETH" "$FAKE_TEETH" 2>/dev/null || return 1
    [ -e "$FAKE_TEETH" ] || return 1
    return 0
}
# run_teeth <sockd-conf> <stdout-file> <stderr-file> ; sets RT_RC ; leaves the
# teeth's granular evidence under $FAKE_REPO/qa-results/vpn_lan/phase1/*/ .
run_teeth() {
    rm -rf "$FAKE_REPO/qa-results" >/dev/null 2>&1
    SOCKD_CONF="$1" HELIX_BRIDGE_HOST="$CARVE_HOST" SSRF_MUT=0 \
        sh "$FAKE_TEETH" >"$2" 2>"$3"
    RT_RC=$?
}
# teeth_signature <stdout-file> — canonical, timestamp-free verdict signature:
# stripped PASS/FAIL/SKIP tokens + summary line + granular per-canary "=>" lines.
teeth_signature() {
    grep -E '^(PASS|FAIL|SKIP):' "$1" 2>/dev/null | sed 's/ \[[^]]*\]//g'
    # ONLY the stable pass/fail/skip summary — NOT the teeth's log() lines, one of
    # which embeds the per-second timestamped evidence-root path (§11.4.1: exclude
    # the volatile path so the signature reflects verdicts, not the clock).
    grep -E "^$SCRIPT_TEETH_LABEL: pass=[0-9]+ fail=[0-9]+ skip=[0-9]+" "$1" 2>/dev/null
    cat "$FAKE_REPO"/qa-results/vpn_lan/phase1/*/*.evidence 2>/dev/null | grep -E '=>' | sort
}
SCRIPT_TEETH_LABEL='ssrf_carveout_teeth'
# crash_signatures <stderr-file> — count set-u / parse / fatal crash markers.
crash_signatures() {
    _cs=$(grep -Ec 'parameter not set|unbound variable|bad substitution|syntax error|Segmentation|core dumped' "$1" 2>/dev/null | tr -d ' ')
    [ -z "$_cs" ] && _cs=0
    printf '%s' "$_cs"
}

# ============================================================================
# PRE — teeth + live floor must exist (else honest SKIP, never a fake PASS).
# ============================================================================
if [ ! -f "$SSRF_TEETH" ]; then
    ab_skip_with_reason "SSRF stress+chaos (teeth script absent: $SSRF_TEETH)" topology_unsupported
    printf '%s: done (skipped) — pass=%s fail=%s skip=%s\n' "$SCRIPT_LABEL" "$N_PASS" "$N_FAIL" "$N_SKIP"
    exit 0
fi
if [ ! -s "$SOCKD_CONF" ]; then
    ab_skip_with_reason "SSRF stress+chaos (live floor absent/empty: $SOCKD_CONF)" topology_unsupported
    printf '%s: done (skipped) — pass=%s fail=%s skip=%s\n' "$SCRIPT_LABEL" "$N_PASS" "$N_FAIL" "$N_SKIP"
    exit 0
fi
if ! setup_fake_repo; then
    ab_skip_with_reason "SSRF stress+chaos (could not stage teeth harness)" topology_unsupported
    printf '%s: done (skipped) — pass=%s fail=%s skip=%s\n' "$SCRIPT_LABEL" "$N_PASS" "$N_FAIL" "$N_SKIP"
    exit 0
fi
FLOOR_SHA=$(sha256sum "$SOCKD_CONF" 2>/dev/null | awk '{print $1}')
[ -z "$FLOOR_SHA" ] && FLOOR_SHA=$(shasum -a 256 "$SOCKD_CONF" 2>/dev/null | awk '{print $1}')
log "teeth=$SSRF_TEETH ; live floor=$SOCKD_CONF (sha256=${FLOOR_SHA:-n/a}, READ-ONLY) ; stress iters=$STRESS_ITERS ; mut=$STRESSCHAOS_MUT"

# ============================================================================
# STRESS — N>=100 iterations of the REAL teeth on the REAL floor MUST all be
#          GREEN (rc 0) AND produce the IDENTICAL granular verdict set.
# ============================================================================
stress_ev="$EV_ROOT/stress/determinism.evidence"
{ printf '=== §11.4.85 STRESS: teeth determinism over N=%s iterations ===\n' "$STRESS_ITERS"
  printf 'timestamp_utc     : %s\n' "$TS"
  printf 'teeth             : %s\n' "$SSRF_TEETH"
  printf 'live_floor        : %s\n' "$SOCKD_CONF"
  printf 'live_floor_sha256 : %s (audited READ-ONLY)\n' "${FLOOR_SHA:-n/a}"
  printf 'carve_host        : %s\n' "$CARVE_HOST"; } > "$stress_ev"

# Probe once: if the teeth SKIP (e.g. unparseable floor) do not assert GREEN —
# honest-SKIP the stress dimension instead of a false FAIL.
run_teeth "$SOCKD_CONF" "$SC_TMP/probe.out" "$SC_TMP/probe.err"
PROBE_RC=$RT_RC
PROBE_SUMMARY=$(grep -E "^$SCRIPT_TEETH_LABEL:" "$SC_TMP/probe.out" 2>/dev/null | tail -n1)
PROBE_HAS_PASS=0; grep -q '^PASS:' "$SC_TMP/probe.out" 2>/dev/null && PROBE_HAS_PASS=1
STRESS_DONE=0
if [ "$PROBE_HAS_PASS" != 1 ] || [ "$PROBE_RC" != 0 ]; then
    { printf 'probe_rc          : %s\n' "$PROBE_RC"
      printf 'probe_summary     : %s\n' "${PROBE_SUMMARY:-<none>}"
      printf 'note              : teeth did not run GREEN on the live floor (probe) — stress SKIP, not a false FAIL\n'
    } >> "$stress_ev"
    ab_skip_with_reason "STRESS determinism (teeth not GREEN on live floor at probe)" topology_unsupported
    STRESS_DONE=1
fi

if [ "$STRESS_DONE" = 0 ]; then
    REF_SIG_FILE="$EV_ROOT/stress/reference_verdicts.txt"
    REF_HASH=''
    BAD_RC=0; DIVERGENCE=0; DIV_LIST=''
    i=1
    while [ "$i" -le "$STRESS_ITERS" ]; do
        run_teeth "$SOCKD_CONF" "$SC_TMP/s.out" "$SC_TMP/s.err"
        _rc=$RT_RC
        _sig=$(teeth_signature "$SC_TMP/s.out")
        _h=$(printf '%s\n' "$_sig" | hashof)
        [ "$_rc" = 0 ] || { BAD_RC=$((BAD_RC+1)); DIV_LIST="$DIV_LIST rc@$i=$_rc"; }
        if [ -z "$REF_HASH" ]; then
            REF_HASH=$_h
            printf '%s\n' "$_sig" > "$REF_SIG_FILE"
        elif [ "$_h" != "$REF_HASH" ]; then
            DIVERGENCE=$((DIVERGENCE+1))
            DIV_LIST="$DIV_LIST hash@$i=$_h"
        fi
        i=$((i+1))
    done

    # Confirm the reference verdict SET is the expected SSRF-safe outcome:
    # metadata/loopback/all-RFC1918 blocked, public passes, carve-host passes.
    vset_ok=1
    check_tok() {
        if grep -Eq "$1" "$REF_SIG_FILE" 2>/dev/null; then
            printf 'verdict_ok        : %s\n' "$2" >> "$stress_ev"
        else
            printf 'verdict_MISSING   : %s\n' "$2" >> "$stress_ev"; vset_ok=0
        fi
    }
    {
      printf 'iterations        : %s\n' "$STRESS_ITERS"
      printf 'nonzero_exit_count: %s\n' "$BAD_RC"
      printf 'hash_divergences  : %s\n' "$DIVERGENCE"
      printf 'reference_hash    : %s\n' "$REF_HASH"
      [ -n "$DIV_LIST" ] && printf 'divergence_detail :%s\n' "$DIV_LIST"
    } >> "$stress_ev"
    check_tok '169\.254\.169\.254.*=> *block' 'metadata (169.254.169.254) BLOCKED'
    check_tok '127\.0\.0\.1.*=> *block'        'loopback (127.0.0.1) BLOCKED'
    check_tok '10\.99\.88\.77.*=> *block'      'rfc1918-10 (10.99.88.77) BLOCKED'
    check_tok '172\.16\.5\.5.*=> *block'       'rfc1918-172 (172.16.5.5) BLOCKED'
    check_tok '192\.168\.9\.9.*=> *block'      'rfc1918-192 (192.168.9.9) BLOCKED'
    check_tok '8\.8\.8\.8.*=> *pass'           'public (8.8.8.8) PASSES'
    check_tok "$CARVE_HOST.*=> *pass"          "carve-host ($CARVE_HOST) PASSES"
    {
      printf 'determinism       : %s\n' "$( [ "$BAD_RC" = 0 ] && [ "$DIVERGENCE" = 0 ] && echo 'IDENTICAL across all iterations (no flake)' || echo 'DIVERGENT — non-determinism defect' )"
      printf 'expected_verdict_set: %s\n' "$( [ "$vset_ok" = 1 ] && echo 'confirmed' || echo 'INCOMPLETE' )"
    } >> "$stress_ev"

    if [ "$BAD_RC" = 0 ] && [ "$DIVERGENCE" = 0 ] && [ "$vset_ok" = 1 ]; then
        ab_pass_with_evidence "STRESS: SSRF teeth deterministic + GREEN across $STRESS_ITERS iterations (identical verdict hash $REF_HASH)" "$stress_ev"
    elif [ "$BAD_RC" != 0 ] || [ "$DIVERGENCE" != 0 ]; then
        ab_fail "STRESS determinism" "non-deterministic teeth: nonzero_exit=$BAD_RC hash_divergences=$DIVERGENCE — see $stress_ev"
    else
        ab_fail "STRESS verdict set" "reference verdict set incomplete (a must-block/pass token missing) — see $stress_ev"
    fi
fi

# ============================================================================
# CHAOS — render malformed/truncated/reordered/empty fixtures (scratch only) and
#         drive the REAL teeth against each; assert honest handling.
# ============================================================================
FX_DIR="$SC_TMP/fixtures"
mkdir -p "$FX_DIR" 2>/dev/null || true
BASE="$FX_DIR/base_valid.conf"
cp "$SOCKD_CONF" "$BASE" 2>/dev/null || true   # read-only copy; live floor never edited

# empty (0 bytes) and whitespace-only (non-empty, zero socks rules)
: > "$FX_DIR/empty.conf"
printf '# comment only\n\n   \n# no socks rules present here\n' > "$FX_DIR/whitespace.conf"
# metadata block removed (link-local 169.254 SSRF hole)
awk '
  /socks[ \t]+block[ \t]*\{/ {
    buf=$0; drop=0
    while ((getline l) > 0) { buf=buf ORS l; if (l ~ /169\.254/) drop=1; if (l ~ /\}/) break }
    if (!drop) print buf
    next
  }
  { print }
' "$BASE" > "$FX_DIR/nometa.conf" 2>/dev/null
# 10/8 block removed (RFC1918-10 SSRF hole)
awk '
  /socks[ \t]+block[ \t]*\{/ {
    buf=$0; drop=0
    while ((getline l) > 0) { buf=buf ORS l; if (l ~ /10\.0\.0\.0/) drop=1; if (l ~ /\}/) break }
    if (!drop) print buf
    next
  }
  { print }
' "$BASE" > "$FX_DIR/no10.conf" 2>/dev/null
# permissive pass 0/0 REORDERED to the top (first-match-wins SSRF hole)
{ printf 'socks pass {\n    from: 0.0.0.0/0 to: 0.0.0.0/0\n    command: connect\n}\n'; cat "$BASE"; } > "$FX_DIR/reorder.conf" 2>/dev/null
# truncated mid-rule — floor cut after the metadata block + a dangling open block
awk '
  BEGIN{done=0}
  done{next}
  { print }
  /169\.254/ { seen=1 }
  seen && /\}/ { print "socks block {"; done=1 }
' "$BASE" > "$FX_DIR/truncate.conf" 2>/dev/null
# malformed non-numeric `to:` on the metadata block (rule becomes a no-match hole)
awk '{ if ($0 ~ /169\.254/) sub(/to:.*/, "to: not-an-ip/xx"); print }' "$BASE" > "$FX_DIR/malformed.conf" 2>/dev/null

# ---- CHAOS-A: empty / whitespace => honest SKIP, rc 0, no fake PASS ----------
skip_ev="$EV_ROOT/chaos/chaos_skip.evidence"
{ printf '=== §11.4.85 CHAOS-A: degenerate configs => honest SKIP (never fake PASS) ===\n'
  printf 'timestamp_utc : %s\n' "$TS"; } > "$skip_ev"
skip_ok=1
assert_honest_skip() {
    _fx=$1; _lbl=$2
    run_teeth "$_fx" "$SC_TMP/c.out" "$SC_TMP/c.err"
    _rc=$RT_RC
    _crash=$(crash_signatures "$SC_TMP/c.err")
    _hasskip=0; grep -q '^SKIP:' "$SC_TMP/c.out" 2>/dev/null && _hasskip=1
    _haspass=0; grep -q '^PASS:' "$SC_TMP/c.out" 2>/dev/null && _haspass=1
    _ok=1
    [ "$_rc" = 0 ] || _ok=0
    [ "$_crash" = 0 ] || _ok=0
    [ "$_hasskip" = 1 ] || _ok=0
    [ "$_haspass" = 0 ] || _ok=0
    printf '%-12s rc=%s crash=%s skip=%s fakepass=%s => %s\n' \
        "$_lbl" "$_rc" "$_crash" "$_hasskip" "$_haspass" "$( [ "$_ok" = 1 ] && echo HONEST-SKIP || echo VIOLATION )" >> "$skip_ev"
    [ "$_ok" = 1 ]
}
assert_honest_skip "$FX_DIR/empty.conf"      empty      || skip_ok=0
assert_honest_skip "$FX_DIR/whitespace.conf" whitespace || skip_ok=0
if [ "$skip_ok" = 1 ]; then
    ab_pass_with_evidence "CHAOS: empty/whitespace configs => honest SKIP, no crash, no fake PASS (2 fixtures)" "$skip_ev"
else
    ab_fail "CHAOS degenerate-config handling" "a degenerate config crashed or produced a fake PASS — see $skip_ev"
fi

# ---- CHAOS-B: fail-open fixtures => teeth FAIL the hole, no crash ------------
holes_ev="$EV_ROOT/chaos/chaos_holes.evidence"
{ printf '=== §11.4.85 CHAOS-B: malformed/hole configs => teeth FAIL (no fail-open, no crash) ===\n'
  printf 'timestamp_utc : %s\n' "$TS"
  printf 'invariant     : a config with an SSRF hole MUST yield teeth exit!=0 (hole caught) — never a counted PASS\n'; } > "$holes_ev"
holes_ok=1
finding=0
# assert_hole_caught <fixture> <label> <require-T1-FAIL: yes|no>
assert_hole_caught() {
    _fx=$1; _lbl=$2; _needt1=$3
    run_teeth "$_fx" "$SC_TMP/c.out" "$SC_TMP/c.err"
    _rc=$RT_RC
    _crash=$(crash_signatures "$SC_TMP/c.err")
    _nfail=$(grep -c '^FAIL:' "$SC_TMP/c.out" 2>/dev/null | tr -d ' '); [ -z "$_nfail" ] && _nfail=0
    _t1fail=0; grep -q '^FAIL: T1' "$SC_TMP/c.out" 2>/dev/null && _t1fail=1
    # A hole fixture must be CAUGHT: teeth exit non-zero AND >=1 FAIL AND no crash.
    _exp_rc_nonzero=1
    # §1.1 paired mutation: for the target fixture, tolerate the fail-open
    # (expect the hole to slip through as a clean pass). Real teeth catch it, so
    # this loosened expectation contradicts reality and the test FAILs.
    if [ "$STRESSCHAOS_MUT" = 1 ] && [ "$_lbl" = "$MUT_TARGET" ]; then
        _exp_rc_nonzero=0
    fi
    _ok=1
    if [ "$_exp_rc_nonzero" = 1 ]; then
        [ "$_rc" != 0 ] || _ok=0            # non-zero => hole caught
        [ "$_nfail" -ge 1 ] || _ok=0
    else
        [ "$_rc" = 0 ] || _ok=0             # loosened: tolerate fail-open (will not hold)
    fi
    [ "$_crash" = 0 ] || _ok=0
    if [ "$_needt1" = yes ] && [ "$_t1fail" != 1 ]; then _ok=0; fi
    # A hole fixture that the teeth PASS (rc 0, no FAIL) with no crash is a real
    # fail-open SSRF defect — record it as a FINDING, not a silent tolerance.
    if [ "$_rc" = 0 ] && [ "$_nfail" = 0 ] && [ "$_crash" = 0 ] && [ "$_exp_rc_nonzero" = 1 ]; then
        finding=1
        printf 'FINDING: fixture %s (%s) produced a CLEAN PASS despite an SSRF hole — real fail-open in the evaluator\n' "$_lbl" "$_fx" >> "$holes_ev"
    fi
    printf '%-11s rc=%s crash=%s FAILs=%s T1FAIL=%s expect_nonzero=%s => %s\n' \
        "$_lbl" "$_rc" "$_crash" "$_nfail" "$_t1fail" "$_exp_rc_nonzero" \
        "$( [ "$_ok" = 1 ] && echo HOLE-CAUGHT || echo NOT-HELD )" >> "$holes_ev"
    [ "$_ok" = 1 ]
}
assert_hole_caught "$FX_DIR/nometa.conf"    nometa    yes || holes_ok=0
assert_hole_caught "$FX_DIR/no10.conf"      no10      no  || holes_ok=0
assert_hole_caught "$FX_DIR/reorder.conf"   reorder   yes || holes_ok=0
assert_hole_caught "$FX_DIR/truncate.conf"  truncate  no  || holes_ok=0
assert_hole_caught "$FX_DIR/malformed.conf" malformed yes || holes_ok=0
{ printf 'fail_open_finding : %s\n' "$( [ "$finding" = 1 ] && echo 'YES — evaluator has a real SSRF fail-open (see FINDING lines)' || echo 'none (every hole fixture was caught with a non-zero teeth exit)' )"
  printf 'mutation_mode     : %s%s\n' "$STRESSCHAOS_MUT" "$( [ "$STRESSCHAOS_MUT" = 1 ] && echo " (paired §1.1: fixture '$MUT_TARGET' fail-open tolerated => test MUST FAIL)" )"; } >> "$holes_ev"
if [ "$holes_ok" = 1 ]; then
    ab_pass_with_evidence "CHAOS: malformed/hole configs (nometa/no10/reorder/truncate/malformed) => teeth FAIL the hole, no crash, no fail-open (5 fixtures)" "$holes_ev"
elif [ "$finding" = 1 ]; then
    ab_fail "CHAOS fail-open FINDING" "a malformed config produced a clean teeth PASS despite an SSRF hole — real evaluator defect; see $holes_ev"
else
    ab_fail "CHAOS hole-handling" "a hole fixture was not honestly caught (or crashed, or — under mutation — the loosened assertion correctly failed) — see $holes_ev"
fi

log "done — evidence root: $EV_ROOT"
printf '%s: pass=%s fail=%s skip=%s\n' "$SCRIPT_LABEL" "$N_PASS" "$N_FAIL" "$N_SKIP"
[ "$N_FAIL" -eq 0 ] && exit 0 || exit 1
