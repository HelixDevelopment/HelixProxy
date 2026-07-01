#!/bin/sh
#######################################################################
# §11.4.135 regression guard — comprehensive-test.sh external-egress verdict
# (BUGFIX-0012).
#
# Purpose:
#   Prove `tests/comprehensive-test.sh`'s `_external_egress_verdict()` never
#   reports a proxy FAIL for a THIRD-PARTY OUTAGE (§11.4.1 false-FAIL) and never
#   masks a REAL proxy defect as an outage SKIP (§11.4.68 fail-open). Pre-fix, the
#   sites loop + concurrency test did `proxy != 200 -> FAIL`, so when httpbin.org
#   was externally down (direct fetch ALSO failed) the suite hard-FAILed on an
#   outage the proxy did not cause — non-deterministic (§11.4.50), not re-runnable
#   (§11.4.98). The fix classifies:
#     proxy 200                       -> PASS
#     proxy fail, direct 200          -> FAIL  (proxy can't fetch a reachable site)
#     proxy fail, direct fail         -> SKIP  (external endpoint down — not ours)
#
# What it actually does (extracts the REAL pure function — NOT a grep, no network):
#   GREEN — drives the REAL `_external_egress_verdict` with the three canonical
#           (proxy,direct) code pairs and asserts PASS / FAIL / SKIP respectively,
#           INCLUDING the outage pair (503,000)->SKIP (the bluff refused) and the
#           real-defect pair (503,200)->FAIL (the anti-bluff catch preserved).
#   RED   — runs the PRE-FIX replica (`proxy!=200 => FAIL`) against the outage pair
#           and asserts FAIL (the false-FAIL reproduced). A RED that cannot
#           reproduce is a §11.4.7 finding.
#
# §11.4.115 polarity switch (RED_MODE):
#   RED_MODE=0 (default GREEN guard) — PASS iff the real verdict gives
#              PASS(200,000) + FAIL(503,200) + SKIP(503,000).
#   RED_MODE=1 (reproduce) — PASS iff the pre-fix replica returns FAIL for (503,000).
#
# Usage:
#   tests/regression/external_egress_verdict_test.sh            # GREEN guard
#   RED_MODE=1 tests/regression/external_egress_verdict_test.sh # reproduce
#
# Inputs:   RED_MODE (env, default 0). No CLI args.
# Outputs:  PASS/FAIL verdict on stdout + evidence under
#           qa-results/regression/external_egress_verdict/. Exit 0=PASS,1=FAIL.
# Dependencies: sh, awk, mktemp.
# Cross-references:
#   - Fix: tests/comprehensive-test.sh _external_egress_verdict() + the sites loop
#     in test_http_proxy() + the direct pre-probe in test_concurrent().
#   - Sibling gate: test_large_file() network_unreachable_external SKIP.
#   - docs/issues/fixed/BUGFIXES.md — BUGFIX-0012.
#######################################################################
set -eu

RED_MODE="${RED_MODE:-0}"
REPO_ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
EVID_DIR="$REPO_ROOT/qa-results/regression/external_egress_verdict"
mkdir -p "$EVID_DIR"
EVID_FILE="$EVID_DIR/external_egress_verdict.$$.txt"

PROBE="$(mktemp)"
trap 'rm -f "$PROBE"' EXIT INT TERM

{
    echo 'set -u'
    if [ "$RED_MODE" = "1" ]; then
        # Faithful PRE-FIX replica: proxy != 200 => FAIL (no direct-reachability gate).
        printf '%s\n' \
            '_external_egress_verdict() { if [ "$1" = "200" ]; then echo PASS; else echo FAIL; fi; }' \
            'echo "OUTAGE=$(_external_egress_verdict 503 000)"'
    else
        # Extract the REAL current function from the tracked suite.
        awk '/^_external_egress_verdict\(\) \{/{f=1} f{print} /^\}/{if(f){exit}}' \
            "$REPO_ROOT/tests/comprehensive-test.sh"
        printf '%s\n' \
            'echo "OK200=$(_external_egress_verdict 200 000)"' \
            'echo "DEFECT=$(_external_egress_verdict 503 200)"' \
            'echo "OUTAGE=$(_external_egress_verdict 503 000)"'
    fi
} >"$PROBE"

probe_out="$(bash "$PROBE" 2>&1)" && probe_rc=0 || probe_rc=$?

verdict=FAIL
exit_code=1
if [ "$RED_MODE" = "1" ]; then
    case "$probe_out" in
        *OUTAGE=FAIL*)
            verdict=PASS; exit_code=0
            msg="RED reproduced: pre-fix logic returns FAIL for an external outage (proxy 503, direct 000) — the false-FAIL, rc=$probe_rc"
            ;;
        *)
            msg="RED could-not-reproduce: pre-fix replica did not FAIL the outage pair (out=$probe_out, rc=$probe_rc) — finding per 11.4.7"
            ;;
    esac
else
    case "$probe_out" in
        *OK200=PASS*DEFECT=FAIL*OUTAGE=SKIP*)
            verdict=PASS; exit_code=0
            msg="GREEN: real verdict = PASS(proxy200) + FAIL(proxy-fail/direct-200 real defect) + SKIP(proxy-fail/direct-fail outage)"
            ;;
        *)
            msg="REGRESSION: verdict wrong (out=$probe_out, rc=$probe_rc) — outage no longer SKIPs (false-FAIL) OR real defect no longer FAILs (fail-open)"
            ;;
    esac
fi

{
    echo "external-egress verdict regression guard — §11.4.1/§11.4.3/§11.4.68"
    echo "timestamp_utc: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "RED_MODE: $RED_MODE"
    echo "probe_rc: $probe_rc"
    echo "probe_out: $probe_out"
    echo "verdict: $verdict"
    echo "detail: $msg"
} >"$EVID_FILE"

echo "[$verdict] external-egress-verdict (RED_MODE=$RED_MODE): $msg"
echo "evidence: $EVID_FILE"
exit "$exit_code"
