#!/bin/sh
#######################################################################
# §11.4.135 regression guard — evidence.sh proxy_conn_verdict (BUGFIX-0014).
#
# Purpose:
#   Prove `tests/lib/evidence.sh`'s `proxy_conn_verdict()` — the client-side
#   through-proxy connectivity classifier used by verify-proxy.sh + final-verify.sh
#   — never reports a proxy FAIL for a THIRD-PARTY / local-internet OUTAGE
#   (§11.4.1 false-FAIL) and never masks a REAL proxy defect as an outage SKIP
#   (§11.4.68 fail-open). Pre-fix, those scripts did `code != expected -> FAIL`,
#   so a site outage (curl through the proxy fails because the SITE is down) hard-
#   FAILed a healthy proxy — non-deterministic (§11.4.50), not re-runnable
#   (§11.4.98). The classifier decides (a positive DIRECT signal out-ranks the port
#   probe, so a crashed proxy on a working host FAILs rather than fail-opens):
#     proxy in expected                            -> PASS
#     proxy miss, direct in expected               -> FAIL (site reachable directly,
#                                                     proxy can't serve it — real defect
#                                                     whether the port is up-but-broken
#                                                     OR crashed; §11.4.68 no fail-open)
#     proxy miss, direct miss, port listening      -> SKIP:network_unreachable_external (outage)
#     proxy miss, direct miss, port NOT listening  -> SKIP:topology_unsupported (absent, unprovable)
#
# What it actually does (drives the REAL function from evidence.sh — no network):
#   GREEN — sources evidence.sh and asserts the full truth table, INCLUDING the
#           outage tuple (000,000)->SKIP (the bluff refused) and the real-defect
#           tuple (000,204)->FAIL (the anti-bluff catch preserved).
#   RED   — runs the PRE-FIX replica (`code != expected => FAIL`) against the
#           outage tuple and asserts FAIL (the false-FAIL reproduced). A RED that
#           cannot reproduce is a §11.4.7 finding.
#
# §11.4.115 polarity switch (RED_MODE):
#   RED_MODE=0 (default GREEN guard) — PASS iff the real classifier gives the full
#              correct truth table.
#   RED_MODE=1 (reproduce) — PASS iff the pre-fix replica returns FAIL for a proxy
#              miss on an outage (proxy=000, expected 204).
#
# Usage:
#   tests/regression/proxy_conn_verdict_test.sh            # GREEN guard
#   RED_MODE=1 tests/regression/proxy_conn_verdict_test.sh # reproduce
#
# Inputs:   RED_MODE (env, default 0). No CLI args.
# Outputs:  PASS/FAIL verdict on stdout + evidence under
#           qa-results/regression/proxy_conn_verdict/. Exit 0=PASS,1=FAIL.
# Dependencies: sh, mktemp (evidence.sh: awk/grep).
# Cross-references:
#   - Fix: tests/lib/evidence.sh proxy_conn_verdict() + _code_in() + port_is_listening();
#     verify-proxy.sh / final-verify.sh conn_check().
#   - Unit truth-table: tests/lib/evidence_selftest.sh (proxy_conn_verdict cases).
#   - docs/issues/fixed/BUGFIXES.md — BUGFIX-0014.
#######################################################################
set -eu

RED_MODE="${RED_MODE:-0}"
REPO_ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
EVID_DIR="$REPO_ROOT/qa-results/regression/proxy_conn_verdict"
mkdir -p "$EVID_DIR"
EVID_FILE="$EVID_DIR/proxy_conn_verdict.$$.txt"

# Source the REAL library under test (never re-implement the classifier).
# shellcheck source=/dev/null
. "$REPO_ROOT/tests/lib/evidence.sh"

# Faithful PRE-FIX replica: the OLD connectivity logic — code != expected => FAIL,
# with NO direct-reachability / port gate (what verify-proxy/final-verify + the
# comprehensive-test canaries did before BUGFIX-0014).
_prefix_verdict() {
    if _code_in "$1" "$2"; then echo PASS; else echo FAIL; fi
}

verdict=FAIL
exit_code=1

if [ "$RED_MODE" = "1" ]; then
    out="$(_prefix_verdict 000 204)"
    if [ "$out" = "FAIL" ]; then
        verdict=PASS; exit_code=0
        msg="RED reproduced: pre-fix logic returns FAIL for a proxy miss on an external outage (proxy=000, expected 204) — the false-FAIL"
    else
        msg="RED could-not-reproduce: pre-fix replica did not FAIL the outage (out=$out) — finding per 11.4.7"
    fi
else
    ok=yes
    check() {
        _want="$1"; shift
        _got="$(proxy_conn_verdict "$@")"
        if [ "$_got" != "$_want" ]; then
            ok=no
            echo "  MISMATCH: proxy_conn_verdict $* -> $_got (want $_want)"
        fi
    }
    check PASS                              204 000 '204'         yes
    check FAIL                              000 204 '204'         yes
    check FAIL                              000 204 '204'         no
    check SKIP:network_unreachable_external 000 000 '204'         yes
    check SKIP:topology_unsupported         000 000 '204'         no
    check PASS                              301 000 '200 301 302' yes
    check FAIL                              000 200 '200 301 302' yes
    check SKIP:network_unreachable_external 20  000 '200'         yes
    if [ "$ok" = "yes" ]; then
        verdict=PASS; exit_code=0
        msg="GREEN: proxy_conn_verdict = PASS(expected) + FAIL(proxy-miss OR crashed-port, site reachable = real defect, no fail-open) + SKIP(outage, no false-FAIL) + SKIP(absent+no-network) + exact-match(20!=200) across the truth table"
    else
        msg="REGRESSION: a proxy_conn_verdict case is wrong — an outage no longer SKIPs (false-FAIL) OR a real/crashed-proxy defect no longer FAILs (fail-open)"
    fi
fi

{
    echo "proxy_conn_verdict regression guard — §11.4.1/§11.4.3/§11.4.68"
    echo "timestamp_utc: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "RED_MODE: $RED_MODE"
    echo "verdict: $verdict"
    echo "detail: $msg"
} > "$EVID_FILE"

echo "[$verdict] proxy-conn-verdict (RED_MODE=$RED_MODE): $msg"
echo "evidence: $EVID_FILE"
exit "$exit_code"
