#!/bin/sh
#######################################################################
# §11.4.135 regression guard — proxy_acl_security.sh honest group verdict (F1 / #72).
#
# Purpose:
#   Prove the security-suite group verdict NEVER reports PASS when a security-
#   CRITICAL check (S1 ACL-deny, S4 SOCKS-SSRF) merely SKIPPED — i.e. a non-
#   critical PASS (S2/S3) can no longer over-claim group security coverage
#   (§11.4.120/§11.4.1). GREEN drives the REAL single-source function
#   acl_group_verdict() (tests/lib/acl_group_verdict.sh — §11.4.107(10): the
#   guard exercises the SAME function the live suite uses, not a copy). RED
#   reproduces the historical over-claim rule (n_pass>0 && n_fail==0 => PASS)
#   and shows the S3-only case WOULD have wrongly PASSed pre-fix.
#
# What it actually does (drives the REAL sourced fn — no network, no containers):
#   GREEN — sources acl_group_verdict.sh and asserts the four canonical cases:
#           {s1=0,s4=0,nfail=0} (S3-only-ish)   -> SKIP / exit 3   (NOT PASS)
#           {s1=1,s4=1,nfail=0}                 -> PASS / exit 0
#           {s1=1,s4=0,nfail=0}                 -> SKIP / exit 3
#           {s1=0,s4=0,nfail=1}                 -> FAIL / exit 1
#           {s1=1,s4=1,nfail=1}                 -> FAIL / exit 1  (defect trumps)
#   RED   — a LOCAL faithful replica of the pre-F1 over-claiming rule
#           (n_pass>0 && n_fail==0 => PASS) driven with the S3-only shape
#           (n_pass=1 from S3, n_fail=0) and asserts it returns PASS/0 — the
#           §11.4.1 over-claim reproduced. A RED that cannot reproduce is a
#           §11.4.7 finding.
#
# §11.4.115 polarity switch (RED_MODE):
#   RED_MODE=0 (default GREEN guard) — PASS iff all five real-function cases hold.
#   RED_MODE=1 (reproduce)           — PASS iff the pre-fix replica PASSes the
#                                      S3-only (n_pass=1,n_fail=0) shape.
#
# Usage:
#   tests/regression/security_group_critical_gate_test.sh            # GREEN guard
#   RED_MODE=1 tests/regression/security_group_critical_gate_test.sh # reproduce
#
# Inputs:   RED_MODE (env, default 0). No CLI args.
# Outputs:  PASS/FAIL verdict on stdout + evidence under
#           qa-results/regression/security_group_critical_gate/. Exit 0=PASS,1=FAIL.
# Side-effects: writes one evidence file; NO network, NO containers.
# Dependencies: sh (POSIX). Sources tests/lib/acl_group_verdict.sh.
# Cross-references:
#   - Fix / single source: tests/lib/acl_group_verdict.sh (acl_group_verdict),
#     consumed by tests/security/proxy_acl_security.sh aggregate.
#   - Pattern sibling: tests/regression/ddos_flood_evidence_test.sh.
#   - Wired into tests/run-tests.sh test_regression_guards().
# Shell: POSIX-clean — parses under `sh -n` AND `bash -n` (§11.4.67).
#######################################################################
set -eu

RED_MODE="${RED_MODE:-0}"
REPO_ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
EVID_DIR="$REPO_ROOT/qa-results/regression/security_group_critical_gate"
mkdir -p "$EVID_DIR"
EVID_FILE="$EVID_DIR/security_group_critical_gate.$$.txt"

# --- Source the REAL single-source verdict function (§11.4.107(10)). ---------
# shellcheck source=/dev/null
. "$REPO_ROOT/tests/lib/acl_group_verdict.sh"

# Drive a callable without aborting under `set -e` on its non-zero (1/3) return;
# captures stdout in GV_OUT and the exit code in GV_RC.
GV_OUT=""; GV_RC=0
_run() {
    _fn=$1; shift
    if GV_OUT=$("$_fn" "$@"); then GV_RC=0; else GV_RC=$?; fi
}

# Faithful LOCAL replica of the PRE-F1 over-claiming rule: PASS on any non-fail
# check when nothing failed (n_pass>0 && n_fail==0 => PASS) — ignored WHICH
# check passed, so an S3-only run over-claimed a group security PASS.
_prefix_group_verdict() {
    # $1=n_pass  $2=n_fail
    if [ "$2" -gt 0 ]; then echo "FAIL"; return 1; fi
    if [ "$1" -gt 0 ]; then echo "PASS"; return 0; fi
    echo "SKIP"; return 3
}

verdict=FAIL
exit_code=1
details=""

if [ "$RED_MODE" = "1" ]; then
    # S3-only shape: one non-critical check (S3) passed, none failed.
    _run _prefix_group_verdict 1 0
    if [ "$GV_RC" -eq 0 ] && [ "${GV_OUT%% *}" = "PASS" ]; then
        verdict=PASS; exit_code=0
        details="RED reproduced: pre-F1 rule (n_pass>0 && n_fail==0) returns PASS/0 for the S3-only shape (n_pass=1,n_fail=0) — the §11.4.1 over-claim (out=$GV_OUT rc=$GV_RC)"
    else
        details="RED could-not-reproduce: pre-fix replica did not PASS the S3-only shape (out=$GV_OUT rc=$GV_RC) — finding per §11.4.7"
    fi
else
    ok=1; trace=""
    _assert() { # $1=label $2=want_word $3=want_rc  (uses GV_OUT/GV_RC)
        _got_word=${GV_OUT%% *}
        if [ "$_got_word" = "$2" ] && [ "$GV_RC" -eq "$3" ]; then
            trace="$trace $1=$_got_word/$GV_RC(ok)"
        else
            ok=0; trace="$trace $1=$_got_word/$GV_RC(WANT $2/$3)"
        fi
    }
    _run acl_group_verdict 0 0 0; _assert "S3only{0,0,0}" SKIP 3
    _run acl_group_verdict 1 1 0; _assert "both{1,1,0}"   PASS 0
    _run acl_group_verdict 1 0 0; _assert "S1only{1,0,0}" SKIP 3
    _run acl_group_verdict 0 0 1; _assert "fail{0,0,1}"   FAIL 1
    _run acl_group_verdict 1 1 1; _assert "faildom{1,1,1}" FAIL 1
    if [ "$ok" -eq 1 ]; then
        verdict=PASS; exit_code=0
        details="GREEN: real acl_group_verdict() enforces the honest gate —$trace"
    else
        details="REGRESSION: group verdict over-claims or misroutes —$trace"
    fi
fi

{
    echo "security group critical-gate regression guard — §11.4.120/§11.4.1/§11.4.115/§11.4.135"
    echo "timestamp_utc: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "RED_MODE: $RED_MODE"
    echo "single_source_fn: tests/lib/acl_group_verdict.sh :: acl_group_verdict"
    echo "verdict: $verdict"
    echo "detail: $details"
} >"$EVID_FILE"

echo "[$verdict] security-group-critical-gate (RED_MODE=$RED_MODE): $details"
echo "evidence: $EVID_FILE"
exit "$exit_code"
