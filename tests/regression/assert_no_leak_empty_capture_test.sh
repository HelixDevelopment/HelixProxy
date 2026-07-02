#!/bin/sh
#######################################################################
# §11.4.135 regression guard — assert_no_leak empty / structureless capture
# (task #76, F-E; inline-audit §11.4.118/§11.4.69; §11.4.107(10)/§11.4.6/§11.4.120).
#
# Purpose:
#   Prove tests/lib/evidence.sh:assert_no_leak can NEVER score a broken/absent
#   sniff as a genuine no-leak. The DEMONSTRATED bluff (F-E): the fallback
#   branch counted ' IP ' lines and emitted PASS "zero IP packet lines" for
#   BOTH an EMPTY capture file AND a malformed non-empty capture (no tcpdump
#   'packets captured' footer, no '=== AFTER' proc-delta marker, no ' IP '
#   lines, no timestamp) — absence-as-evidence: a failed capture (sniff broke /
#   wrong iface / tcpdump crashed) reported as fail-closed no-leak.
#
# What it actually does (drives the REAL oracle — no divergent copy,
# §11.4.107(10)); hermetic, no live stack, no netns, no network:
#   - REAL oracle: source tests/lib/evidence.sh, call assert_no_leak directly.
#   - REAL fixtures: the committed tests/lib/fixtures/* capture artefacts + an
#     inline empty capture.
#
# §11.4.115 polarity switch (RED_MODE):
#   RED_MODE=1 (reproduce) — PASS iff the DEFECT reproduces: a faithful replica
#       of the pre-fix fallback (grep -c ' IP '; zero -> PASS, NO empty guard,
#       NO structure check) returns 0/"PASS" for the EMPTY capture AND for the
#       malformed structureless capture.
#   RED_MODE=0 (default GREEN guard) — PASS iff the FIX holds through the REAL
#       assert_no_leak:
#       * EMPTY capture                       -> FAIL (rc 1) broken sniff;
#       * malformed, no capture structure     -> FAIL (rc 1) indistinguishable;
#       * genuine tcpdump footer-0            -> PASS (rc 0) no false-FAIL;
#       * tcpdump leak (>0 target packets)    -> FAIL (rc 1) real leak caught;
#       * /proc/net/dev tx-delta == 0         -> PASS (rc 0);
#       * /proc/net/dev tx-delta  > 0         -> FAIL (rc 1);
#       * ran-but-zero-IPv4 (ARP/IP6 + ts)    -> PASS (rc 0) no false-FAIL.
#
# Usage:
#   tests/regression/assert_no_leak_empty_capture_test.sh            # GREEN guard
#   RED_MODE=1 tests/regression/assert_no_leak_empty_capture_test.sh # reproduce
#
# Inputs:   RED_MODE (env, default 0). No CLI args.
# Outputs:  [PASS]/[FAIL] line on stdout + evidence under
#           qa-results/regression/assert_no_leak_empty_capture/. Exit 0=PASS, 1=FAIL.
# Dependencies: sh (POSIX), grep, mktemp.
# Cross-references:
#   - Fix: tests/lib/evidence.sh assert_no_leak() (empty-capture fail-closed
#     guard + fallback positive-structure requirement).
#   - Self-validation: tests/lib/evidence_selftest.sh (F-E negative cases).
# Shell: POSIX-clean (sh -n + bash -n, §11.4.67).
#######################################################################
set -eu

RED_MODE="${RED_MODE:-0}"
REPO_ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
LIB="$REPO_ROOT/tests/lib/evidence.sh"
FIX="$REPO_ROOT/tests/lib/fixtures"
EVID_DIR="$REPO_ROOT/qa-results/regression/assert_no_leak_empty_capture"
mkdir -p "$EVID_DIR"
EVID_FILE="$EVID_DIR/assert_no_leak_empty_capture.$$.txt"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT INT TERM

EMPTY="$WORK/empty.cap"
: > "$EMPTY"                       # deterministic 0-byte capture (broken sniff)
MALFORMED="$FIX/tcpdump_malformed_nostructure.txt"

# rc-capturing runner (set -e safe): _rc <cmd...> ; sets GOT.
_rc() { GOT=0; "$@" >/dev/null 2>&1 || GOT=$?; }

# Faithful replica of the PRE-FIX fallback (no empty guard, no structure check):
# grep -c ' IP ' ; zero count -> "PASS". Reproduces the bluff without a copy of
# the whole file — this is exactly the removed code path.
_prefix_fallback_verdict() {
    # `|| true`: grep -c exits 1 on zero matches; under `set -e` in a command
    # substitution (dash) that would abort the guard — keep the printed "0".
    _n=$(grep -c ' IP ' "$1" 2>/dev/null || true); _n=${_n:-0}
    if [ "$_n" -eq 0 ] 2>/dev/null; then echo PASS; else echo FAIL; fi
}

verdict=FAIL
exit_code=1
{
    echo "assert_no_leak empty/structureless-capture guard — §11.4.107(10)/§11.4.6/§11.4.120"
    echo "timestamp_utc: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "RED_MODE: $RED_MODE"
} >"$EVID_FILE"

if [ "$RED_MODE" = "1" ]; then
    # --- Reproduce the DEFECT via the faithful pre-fix fallback replica. -------
    empty_v="$(_prefix_fallback_verdict "$EMPTY")"        # defect: PASS
    malformed_v="$(_prefix_fallback_verdict "$MALFORMED")" # defect: PASS
    {
        echo "pre-fix fallback(empty)     = $empty_v      (defect: PASS = absence-as-evidence)"
        echo "pre-fix fallback(malformed) = $malformed_v  (defect: PASS = absence-as-evidence)"
    } >>"$EVID_FILE"
    if [ "$empty_v" = "PASS" ] && [ "$malformed_v" = "PASS" ]; then
        verdict=PASS; exit_code=0
        msg="RED reproduced: pre-fix fallback scores EMPTY and MALFORMED captures as no-leak PASS (absence-as-evidence bluff)"
    else
        msg="RED could-not-reproduce: empty=$empty_v malformed=$malformed_v — §11.4.7 finding"
    fi
else
    # --- Assert the FIX holds through the REAL assert_no_leak. -----------------
    # shellcheck source=/dev/null
    . "$LIB"
    _rc assert_no_leak "$EMPTY";                            empty_got=$GOT   # want 1
    _rc assert_no_leak "$MALFORMED";                        mal_got=$GOT     # want 1
    _rc assert_no_leak "$FIX/tcpdump_no_leak.txt";          footer0_got=$GOT # want 0
    _rc assert_no_leak "$FIX/tcpdump_leak.txt";             leak_got=$GOT    # want 1
    _rc assert_no_leak "$FIX/proc_net_dev_noleak.delta";    proc0_got=$GOT   # want 0
    _rc assert_no_leak "$FIX/proc_net_dev_leak.delta";      procL_got=$GOT   # want 1
    _rc assert_no_leak "$FIX/tcpdump_noleak_nonipv4.txt";   ran0_got=$GOT    # want 0
    {
        echo "assert_no_leak(empty)               rc: $empty_got   (want 1 = broken sniff FAIL)"
        echo "assert_no_leak(malformed)           rc: $mal_got     (want 1 = structureless FAIL)"
        echo "assert_no_leak(tcpdump footer-0)    rc: $footer0_got (want 0 = genuine no-leak)"
        echo "assert_no_leak(tcpdump leak)        rc: $leak_got    (want 1 = leak caught)"
        echo "assert_no_leak(proc-delta 0)        rc: $proc0_got   (want 0)"
        echo "assert_no_leak(proc-delta >0)       rc: $procL_got   (want 1)"
        echo "assert_no_leak(ran-but-zero-IPv4)   rc: $ran0_got    (want 0 = no false-FAIL)"
    } >>"$EVID_FILE"
    if [ "$empty_got" -eq 1 ] && [ "$mal_got" -eq 1 ] \
        && [ "$footer0_got" -eq 0 ] && [ "$leak_got" -eq 1 ] \
        && [ "$proc0_got" -eq 0 ] && [ "$procL_got" -eq 1 ] \
        && [ "$ran0_got" -eq 0 ]; then
        verdict=PASS; exit_code=0
        msg="GREEN: empty/malformed captures fail-closed; genuine no-leak + proc-0 + ran-but-zero-IPv4 PASS; leak + proc>0 FAIL — no absence-as-evidence, no false-FAIL"
    else
        msg="REGRESSION: empty=$empty_got mal=$mal_got footer0=$footer0_got leak=$leak_got proc0=$proc0_got procL=$procL_got ran0=$ran0_got — a broken capture can still vacuously pass, or a genuine 0 false-FAILs"
    fi
fi

echo "verdict: $verdict" >>"$EVID_FILE"
echo "detail: $msg" >>"$EVID_FILE"
echo "[$verdict] assert-no-leak-empty-capture (RED_MODE=$RED_MODE): $msg"
echo "evidence: $EVID_FILE"
exit "$exit_code"
