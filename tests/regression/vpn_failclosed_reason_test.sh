#!/bin/sh
#######################################################################
# §11.4.135 regression guard — vpn_failclosed all-timeout SKIP-reason honesty
# (task #74; dynamic-audit ac3f1c89; §11.4.6 / §11.4.3 / §11.4.107(10)).
#
# Purpose:
#   Prove the no-leak-but-not-branded SKIP reason can NEVER assert
#   "fail-closed held — no leak" as FACT when EVERY proxied iteration timed
#   out (000). A 000 is absence-of-response, NOT positive evidence the
#   fail-closed 503 served; the start-of-test reachability probe confirmed the
#   proxy answered at test START, not during the timed-out window.
#
#   F-C (over-claim): the pre-fix code emitted, for the all-timeout run, the
#       reason text "fail-closed held — no leak — but branded ERR_TUNNEL_DOWN
#       path inactive ..." — asserting no-leak as fact on an inconclusive run.
#       Fix: fc_no_leak_skip_reason() distinguishes ALL-timeout (000) →
#       an honest INCONCLUSIVE reason (network_unreachable_external), from a
#       run that received real (non-000) fail-closed responses → the branded-
#       path-inactive reason (fail-closed held).
#
# What it actually does (drives the REAL fc_no_leak_skip_reason function — no
# divergent copy, §11.4.107(10)); hermetic, no live stack, no network:
#   - REAL fix logic: fc_no_leak_skip_reason, obtained by sourcing
#     tests/dynamic/vpn_failclosed_test.sh with FAILCLOSED_SOURCE_ONLY=1
#     (functions only, no body, no nice re-exec, no evidence.sh path work).
#
# §11.4.115 polarity switch (RED_MODE):
#   RED_MODE=1 (reproduce) — PASS iff the DEFECT reproduces: the faithful
#       pre-fix reason (which ALWAYS said "fail-closed held — no leak"
#       regardless of all-timeout) contains "fail-closed held" for the
#       all-timeout inputs (the over-claim).
#   RED_MODE=0 (default GREEN guard) — PASS iff the FIX holds:
#       * all-timeout (timeout==iter) -> reason code network_unreachable_external
#         AND text says "timed out"/"inconclusive" AND does NOT say
#         "fail-closed held";
#       * real non-000 fail-closed (timeout<iter) -> reason code
#         feature_disabled_by_config AND text DOES say "fail-closed held"
#         (that legitimate branch is preserved, §11.4.120 — the real gate is
#         reconciled, not weakened).
#
# Usage:
#   tests/regression/vpn_failclosed_reason_test.sh            # GREEN guard
#   RED_MODE=1 tests/regression/vpn_failclosed_reason_test.sh # reproduce defect
#
# Inputs:   RED_MODE (env, default 0). No CLI args.
# Outputs:  [PASS]/[FAIL] line on stdout + evidence under
#           qa-results/regression/vpn_failclosed_reason/. Exit 0=PASS, 1=FAIL.
# Dependencies: sh (POSIX), grep.
# Cross-references:
#   - Fix: tests/dynamic/vpn_failclosed_test.sh fc_no_leak_skip_reason() +
#     the STEP-5 verdict body (all-timeout inconclusive branch).
# Shell: POSIX-clean (sh -n + bash -n, §11.4.67).
#######################################################################
set -eu

RED_MODE="${RED_MODE:-0}"
REPO_ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
TARGET_SCRIPT="$REPO_ROOT/tests/dynamic/vpn_failclosed_test.sh"
EVID_DIR="$REPO_ROOT/qa-results/regression/vpn_failclosed_reason"
mkdir -p "$EVID_DIR"
EVID_FILE="$EVID_DIR/vpn_failclosed_reason.$$.txt"

# Load the REAL fix function (fc_no_leak_skip_reason) exactly as the target
# defines it — no divergent copy (§11.4.107(10)).
FAILCLOSED_SOURCE_ONLY=1 . "$TARGET_SCRIPT"

ITER=3

verdict=FAIL
exit_code=1
{
    echo "vpn_failclosed all-timeout SKIP-reason honesty guard — §11.4.6/§11.4.3/§11.4.107(10)"
    echo "timestamp_utc: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "RED_MODE: $RED_MODE   iter: $ITER"
} >"$EVID_FILE"

if [ "$RED_MODE" = "1" ]; then
    # --- Reproduce the DEFECT: the pre-fix reason ALWAYS claimed no-leak. ---
    # Faithful 1-line replica of the historical over-claim (the pre-fix body had
    # ONE reason string for both cases): assert it asserts "fail-closed held"
    # even for the all-timeout (inconclusive) inputs.
    prefix_reason="vpn_failclosed (fail-closed held — no leak — but branded ERR_TUNNEL_DOWN path inactive: nonbrand=000 graceful_503_rc=1; dynamic-routing.squid/external_acl likely not rendered — compiler lane pending)"
    {
        echo "pre-fix all-timeout reason (replica): $prefix_reason"
    } >>"$EVID_FILE"
    if printf '%s' "$prefix_reason" | grep -q 'fail-closed held'; then
        verdict=PASS; exit_code=0
        msg="RED reproduced: pre-fix all-timeout reason asserts 'fail-closed held — no leak' on an inconclusive (000) run"
    else
        msg="RED could-not-reproduce: pre-fix replica did not assert 'fail-closed held' — §11.4.7 finding"
    fi
else
    # --- Assert the FIX holds through the REAL fc_no_leak_skip_reason. ---
    # (a) ALL-timeout: iter proxied iterations all 000.
    at_cls="$(fc_no_leak_skip_reason "$ITER" "$ITER" "000" "1")"
    at_reason="${at_cls%%|*}"
    at_text="${at_cls#*|}"
    # (b) real non-000 fail-closed responses (timeout < iter): branded path inactive.
    bi_cls="$(fc_no_leak_skip_reason "$ITER" "0" "503-no-brand" "1")"
    bi_reason="${bi_cls%%|*}"
    bi_text="${bi_cls#*|}"
    {
        echo "all-timeout reason_code: $at_reason"
        echo "all-timeout reason_text: $at_text"
        echo "branded-inactive reason_code: $bi_reason"
        echo "branded-inactive reason_text: $bi_text"
    } >>"$EVID_FILE"

    at_honest=0
    if [ "$at_reason" = "network_unreachable_external" ] \
        && printf '%s' "$at_text" | grep -q 'timed out' \
        && printf '%s' "$at_text" | grep -q 'inconclusive' \
        && ! printf '%s' "$at_text" | grep -q 'fail-closed held'; then
        at_honest=1
    fi
    bi_ok=0
    if [ "$bi_reason" = "feature_disabled_by_config" ] \
        && printf '%s' "$bi_text" | grep -q 'fail-closed held'; then
        bi_ok=1
    fi
    if [ "$at_honest" -eq 1 ] && [ "$bi_ok" -eq 1 ]; then
        verdict=PASS; exit_code=0
        msg="GREEN: all-timeout -> honest inconclusive ($at_reason, no 'fail-closed held'); real fail-closed -> branded-inactive ($bi_reason, 'fail-closed held' preserved)"
    else
        msg="REGRESSION: at_honest=$at_honest bi_ok=$bi_ok — all-timeout reason may still over-claim no-leak, or the legitimate branded-inactive branch was lost"
    fi
fi

echo "verdict: $verdict" >>"$EVID_FILE"
echo "detail: $msg" >>"$EVID_FILE"
echo "[$verdict] vpn-failclosed-reason (RED_MODE=$RED_MODE): $msg"
echo "evidence: $EVID_FILE"
exit "$exit_code"
