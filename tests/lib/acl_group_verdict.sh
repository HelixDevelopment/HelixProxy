#!/bin/sh
# =============================================================================
# acl_group_verdict.sh — §11.4.120/§11.4.1 honest group-verdict for the proxy
#                        ACL security suite (single source of truth, §11.4.107(10))
# -----------------------------------------------------------------------------
# Purpose:      The ONE authoritative decision that turns the per-check outcomes
#               of tests/security/proxy_acl_security.sh into a group verdict.
#               Extracted into this sourceable lib so BOTH the live suite AND its
#               §11.4.135 regression guard exercise the IDENTICAL logic — no
#               divergent copy can drift (§11.4.107(10) self-validated: the guard
#               drives the REAL function, not a re-implementation).
#
#               The honest rule (§11.4.120/§11.4.1 — never over-claim security
#               coverage): a group PASS is earned ONLY when BOTH security-CRITICAL
#               checks actually PASSED — S1 (ACL-deny + no-leak) AND S4 (SOCKS5
#               SSRF block). A real defect (any sub-check FAIL) trumps everything.
#               Otherwise the group SKIPs — a non-critical PASS (S2/S3) while a
#               critical check merely SKIPPED must NOT manufacture a group PASS
#               (the exact over-claim BUGFIX F1 / task #72 guards against).
#
# API:          acl_group_verdict <s1_pass> <s4_pass> <n_fail>
#                 <s1_pass>  1 iff S1 (ACL-deny + HIER_NONE no-leak) PASSED, else 0
#                 <s4_pass>  1 iff S4 (SOCKS5 SSRF block, dante block-log) PASSED
#                 <n_fail>   count of sub-checks that FAILED (>0 => a real defect)
#               Echoes ONE verdict token + human reason to stdout:
#                 FAIL (<n> security defect(s))
#                 PASS (both critical checks proven: S1 ACL-deny + S4 SOCKS-SSRF, 0 leaks)
#                 SKIP (critical security check(s) not asserted on this topology: <absent>)
#               RETURNS the matching exit code: 0=PASS, 1=FAIL, 3=SKIP.
#               (Callers prefix the echoed string as they see fit, e.g.
#               `echo "OVERALL=$(acl_group_verdict ...)"`.)
#
# Usage:        . tests/lib/acl_group_verdict.sh   (source it; do not execute)
#               verdict=$(acl_group_verdict "$S1_PASS" "$S4_PASS" "$N_FAIL"); rc=$?
# Inputs:       Three integer positional args (see API). No env, no files.
# Outputs:      One verdict line on stdout + the 0/1/3 exit code.
# Side-effects: NONE — pure function, no network, no containers, no writes.
# Dependencies: POSIX sh test/echo only.
# Cross-refs:   §11.4.120 (honest aggregate) / §11.4.1 (no over-claim) /
#               §11.4.135 (regression guard drives this) / §11.4.107(10)
#               (single-source, no divergent analyzer). Guard:
#               tests/regression/security_group_critical_gate_test.sh.
# Shell:        POSIX-clean — parses under `sh -n` AND `bash -n` (§11.4.67).
#               Pure sourceable lib: sets NO shell options (never mutates the
#               sourcing shell's `set -e`/`set -u` state).
# =============================================================================

# acl_group_verdict <s1_pass> <s4_pass> <n_fail> -> echoes PASS|FAIL|SKIP + reason,
# returns 0|1|3. Mirrors the F1 honest-aggregate exactly (§11.4.120/§11.4.1).
acl_group_verdict() {
    _agv_s1=$1
    _agv_s4=$2
    _agv_nfail=$3

    # A real leak/defect trumps everything.
    if [ "$_agv_nfail" -gt 0 ]; then
        echo "FAIL ($_agv_nfail security defect(s))"
        return 1
    fi

    # Group PASS ONLY when BOTH security-critical checks proved out.
    if [ "$_agv_s1" -eq 1 ] && [ "$_agv_s4" -eq 1 ]; then
        echo "PASS (both critical checks proven: S1 ACL-deny + S4 SOCKS-SSRF, 0 leaks)"
        return 0
    fi

    # Otherwise a critical check could not run — coverage honestly absent (SKIP),
    # naming which critical check(s) were absent. NEVER a group PASS on a
    # non-critical (S2/S3) PASS alone (the §11.4.120/§11.4.1 over-claim guard).
    _agv_absent=""
    [ "$_agv_s1" -eq 1 ] || _agv_absent="S1 ACL-deny"
    [ "$_agv_s4" -eq 1 ] || _agv_absent="${_agv_absent:+$_agv_absent, }S4 SOCKS-SSRF"
    echo "SKIP (critical security check(s) not asserted on this topology: ${_agv_absent:-none})"
    return 3
}
