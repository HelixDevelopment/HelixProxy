#!/bin/sh
#######################################################################
# §11.4.135 regression guard — evidence.sh assert_egress_ip host-unknown
# fail-open (discovery finding F7 / §11.4.68).
#
# Purpose:
#   Prove `tests/lib/evidence.sh`'s `assert_egress_ip()` never fake-PASSes the
#   VPN-routing proof when the host's REAL IP is UNKNOWN or empty. The proof has
#   TWO halves: egress==expected_exit AND egress!=host_real (design §15 — an
#   egress that equals the host IP means traffic was NOT routed via any VPN).
#   Pre-fix, when the caller's `curl ifconfig.me || echo "unknown"` (verify-proxy.sh,
#   final-verify.sh, comprehensive-test.sh) or `|| true` (real_vpn_egress_proof.sh)
#   fallback fired, `host_real` was the literal "unknown" / "". Comparing the
#   observed egress against "unknown"/"" trivially satisfies "different", silently
#   COLLAPSING the egress!=host half — so an egress==host (NO-VPN §15 bluff) case
#   could still PASS. That is the §11.4.68 fail-open (the anti-VPN-bluff check
#   losing half its assertion when the host IP is unknown).
#   The fix: host UNKNOWN/empty => the !=host half is UNVERIFIABLE, so the call
#   returns exit-2 OPERATOR-BLOCKED (§11.4.68 cross-ref; §11.4.69 reason
#   network_unreachable_external) — NEVER a fail-open PASS/SKIP-as-PASS. A
#   definitively-wrong exit is still a provable defect and FAILs(1).
#
# What it actually does (drives the REAL sourced function — NOT a grep, no network,
# uses the committed EVIDENCE_OBSERVED_IP_FILE fixtures):
#   GREEN — sources tests/lib/evidence.sh and asserts, on the SHIPPED
#           assert_egress_ip:
#             host UNKNOWN + egress==host (hidden §15 bluff)  -> rc 2 (refused)
#             host UNKNOWN + egress==expected                 -> rc 2
#             host EMPTY   + egress==expected                 -> rc 2
#             host UNKNOWN + WRONG exit                       -> rc 1 (defect FAILs)
#             host KNOWN   + egress==exit && !=host           -> rc 0 (genuine PASS)
#             host 0.0.0.0 sentinel + egress==expected        -> rc 2 (F-1)
#             host GARBAGE HTML + egress==host (hidden bluff)  -> rc 2 (F-1)
#   RED   — runs a faithful PRE-FIX replica (the 3-check logic with NO unknown-host
#           guard) against the hidden-bluff case (egress==host==expected, host
#           "unknown") and asserts it returns rc 0 PASS — the fail-open reproduced.
#           A RED that cannot reproduce is a §11.4.7 finding.
#
# §11.4.115 polarity switch (RED_MODE):
#   RED_MODE=0 (default GREEN guard) — PASS iff the real function gives the five
#              GREEN verdicts above (fail-open closed, genuine PASS preserved).
#   RED_MODE=1 (reproduce) — PASS iff the pre-fix replica fake-PASSes (rc 0) the
#              hidden §15 bluff with host "unknown".
#
# Usage:
#   tests/regression/assert_egress_ip_host_unknown_test.sh            # GREEN guard
#   RED_MODE=1 tests/regression/assert_egress_ip_host_unknown_test.sh # reproduce
#
# Inputs:   RED_MODE (env, default 0). No CLI args.
# Outputs:  PASS/FAIL verdict on stdout + evidence under
#           qa-results/regression/assert_egress_ip_host_unknown/. Exit 0=PASS,1=FAIL.
# Dependencies: sh, awk, tr (via sourced evidence.sh). No network.
# Cross-references:
#   - Fix: tests/lib/evidence.sh assert_egress_ip() host-unknown guard.
#   - Callers protected: tests/verify-proxy.sh, tests/final-verify.sh,
#     tests/comprehensive-test.sh, tests/egress_proof/real_vpn_egress_proof.sh,
#     tests/dynamic/analyzers/egress_neq_host_analyzer.sh.
#   - Self-test cases: tests/lib/evidence_selftest.sh (F7 block).
#   - docs/issues/fixed/BUGFIXES.md — F7.
#   - docs/scripts/assert_egress_ip_host_unknown_test.md (§11.4.18 companion).
#######################################################################
set -eu

RED_MODE="${RED_MODE:-0}"
REPO_ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
LIB="$REPO_ROOT/tests/lib/evidence.sh"
FIX="$REPO_ROOT/tests/lib/fixtures"
VPN_IP="$FIX/egress_observed_vpn.ip"    # 185.65.135.70
HOST_IP="$FIX/egress_observed_host.ip"  # 203.0.113.45
EVID_DIR="$REPO_ROOT/qa-results/regression/assert_egress_ip_host_unknown"
mkdir -p "$EVID_DIR"
EVID_FILE="$EVID_DIR/assert_egress_ip_host_unknown.$$.txt"

fails=0
detail=""

# record <label> <want-rc> <got-rc>
record() {
    if [ "$2" = "$3" ]; then
        detail="$detail
  ok   [$1] rc=$3"
    else
        detail="$detail
  FAIL [$1] got rc=$3 want $2"
        fails=$((fails + 1))
    fi
}

if [ "$RED_MODE" = "1" ]; then
    # ------------------------------------------------------------------
    # RED — faithful PRE-FIX replica: the 3-check logic with NO host-unknown
    # guard. Feed the hidden §15 bluff (egress==host==expected, host "unknown");
    # the pre-fix logic fake-PASSes it (rc 0).
    # ------------------------------------------------------------------
    prefix_assert_egress_ip() {
        _observed=$1; _expected_exit=$2; _host_real=$3
        [ -z "$_observed" ] && return 1
        [ "$_observed" = "$_host_real" ] && return 1
        [ "$_observed" != "$_expected_exit" ] && return 1
        return 0
    }
    # egress 203.0.113.45 IS the host's real IP (NO VPN) but host reported "unknown".
    prefix_assert_egress_ip "203.0.113.45" "203.0.113.45" "unknown" && rc=0 || rc=$?
    record "RED: pre-fix replica fake-PASSes hidden §15 bluff (host unknown)" 0 "$rc"
    if [ "$fails" -eq 0 ]; then
        verdict=PASS; exit_code=0
        msg="RED reproduced: pre-fix logic returns rc 0 PASS for egress==host with host='unknown' — the §11.4.68 fail-open"
    else
        verdict=FAIL; exit_code=1
        msg="RED could-not-reproduce: pre-fix replica did not fake-PASS the hidden bluff — finding per §11.4.7"
    fi
else
    # ------------------------------------------------------------------
    # GREEN — drive the REAL shipped assert_egress_ip via the committed fixtures.
    # ------------------------------------------------------------------
    # shellcheck source=/dev/null
    . "$LIB"

    EVIDENCE_OBSERVED_IP_FILE="$HOST_IP" \
        assert_egress_ip "http://127.0.0.1:53128" "203.0.113.45" "unknown" >/dev/null 2>&1 && rc=0 || rc=$?
    record "host UNKNOWN + egress==host (hidden §15 bluff) -> OPERATOR-BLOCKED(2)" 2 "$rc"

    EVIDENCE_OBSERVED_IP_FILE="$VPN_IP" \
        assert_egress_ip "http://127.0.0.1:53128" "185.65.135.70" "unknown" >/dev/null 2>&1 && rc=0 || rc=$?
    record "host UNKNOWN + egress==expected -> OPERATOR-BLOCKED(2)" 2 "$rc"

    EVIDENCE_OBSERVED_IP_FILE="$VPN_IP" \
        assert_egress_ip "http://127.0.0.1:53128" "185.65.135.70" "" >/dev/null 2>&1 && rc=0 || rc=$?
    record "host EMPTY + egress==expected -> OPERATOR-BLOCKED(2)" 2 "$rc"

    EVIDENCE_OBSERVED_IP_FILE="$VPN_IP" \
        assert_egress_ip "http://127.0.0.1:53128" "1.2.3.4" "unknown" >/dev/null 2>&1 && rc=0 || rc=$?
    record "host UNKNOWN + WRONG exit -> FAIL(1) (provable defect survives)" 1 "$rc"

    EVIDENCE_OBSERVED_IP_FILE="$VPN_IP" \
        assert_egress_ip "http://127.0.0.1:53128" "185.65.135.70" "203.0.113.45" >/dev/null 2>&1 && rc=0 || rc=$?
    record "host KNOWN + egress==exit && !=host -> genuine PASS(0) preserved" 0 "$rc"

    # F-1 hardening: a non-empty, non-"unknown" GARBAGE host_real (captive-portal HTML
    # body a `curl -s` 200 can echo, or a non-public 0.0.0.0 sentinel) is exactly as
    # unverifiable as empty/unknown — same OPERATOR-BLOCKED(2), never a fake-PASS.
    EVIDENCE_OBSERVED_IP_FILE="$VPN_IP" \
        assert_egress_ip "http://127.0.0.1:53128" "185.65.135.70" "0.0.0.0" >/dev/null 2>&1 && rc=0 || rc=$?
    record "host 0.0.0.0 sentinel + egress==expected -> OPERATOR-BLOCKED(2) (F-1)" 2 "$rc"

    EVIDENCE_OBSERVED_IP_FILE="$HOST_IP" \
        assert_egress_ip "http://127.0.0.1:53128" "203.0.113.45" "<html>login</html>" >/dev/null 2>&1 && rc=0 || rc=$?
    record "host GARBAGE HTML + HIDDEN egress==host bluff -> OPERATOR-BLOCKED(2) (F-1)" 2 "$rc"

    if [ "$fails" -eq 0 ]; then
        verdict=PASS; exit_code=0
        msg="GREEN: fail-open closed (unknown/empty/garbage/sentinel host => OPERATOR-BLOCKED-2, never PASS), wrong-exit still FAILs, genuine PASS preserved"
    else
        verdict=FAIL; exit_code=1
        msg="REGRESSION: unknown/empty host no longer refused (§11.4.68 fail-open re-opened) OR a provable/genuine verdict changed"
    fi
fi

{
    echo "assert_egress_ip host-unknown fail-open regression guard — §11.4.68/§11.4.135 (F7)"
    echo "timestamp_utc: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "RED_MODE: $RED_MODE"
    echo "checks:$detail"
    echo "fails: $fails"
    echo "verdict: $verdict"
    echo "detail: $msg"
} >"$EVID_FILE"

echo "[$verdict] assert_egress_ip-host-unknown (RED_MODE=$RED_MODE): $msg"
echo "evidence: $EVID_FILE"
exit "$exit_code"
