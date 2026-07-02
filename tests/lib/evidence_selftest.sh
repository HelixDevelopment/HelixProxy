#!/usr/bin/env bash
# =============================================================================
# evidence_selftest.sh — TAP self-test for tests/lib/evidence.sh
# -----------------------------------------------------------------------------
# Purpose:      Prove every evidence.sh parser is CORRECT against captured
#               fixtures AND provably FAILS on its negative fixture — the §1.1
#               paired-mutation discipline applied to the harness itself: a
#               helper that cannot catch its own negation is a bluff gate.
# Usage:        bash tests/lib/evidence_selftest.sh
# Output:       TAP (Test Anything Protocol) on stdout + a copy under
#               qa-results/evidence-harness/<run-id>/selftest.tap.
#               Exit 0 iff ALL assertions pass (zero failures).
# Dependencies: bash (or any POSIX sh — body is POSIX-clean), awk, grep, tr.
#               bats is NOT required; this runs anywhere a shell exists.
# Cross-refs:   Constitution §11.4 / §11.4.69 / §11.4.107 / §1.1; design §13/§14.
# Shell:        POSIX-clean body (no arrays / [[ ]] / <<<) — parses under sh -n.
# =============================================================================

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
LIB="$SCRIPT_DIR/evidence.sh"
FIX="$SCRIPT_DIR/fixtures"
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)

RUN_ID=$(date -u +%Y%m%dT%H%M%SZ)
QA_DIR="$REPO_ROOT/qa-results/evidence-harness/$RUN_ID"
mkdir -p "$QA_DIR"
TAP_OUT="$QA_DIR/selftest.tap"

# Source the library under test.
# shellcheck source=/dev/null
. "$LIB"

TESTS=0
FAILS=0

# run_case <expected-rc> <desc> -- <command...>
# Runs the command (env-seam vars must be exported by the caller beforehand),
# captures its return code, and emits a TAP line. PASS iff rc == expected.
run_case() {
    exp=$1
    desc=$2
    shift 2
    out=$("$@" 2>&1)
    rc=$?
    TESTS=$((TESTS + 1))
    if [ "$rc" = "$exp" ]; then
        printf 'ok %d - %s (rc=%d)\n' "$TESTS" "$desc" "$rc"
    else
        printf 'not ok %d - %s (got rc=%d, want %s)\n' "$TESTS" "$desc" "$rc" "$exp"
        printf '# verdict: %s\n' "$out"
        FAILS=$((FAILS + 1))
    fi
}

# check_value <expected> <desc> <actual> — value-equality assertion (parser).
check_value() {
    exp=$1
    desc=$2
    got=$3
    TESTS=$((TESTS + 1))
    if [ "$got" = "$exp" ]; then
        printf 'ok %d - %s (=%s)\n' "$TESTS" "$desc" "$got"
    else
        printf 'not ok %d - %s (got "%s", want "%s")\n' "$TESTS" "$desc" "$got" "$exp"
        FAILS=$((FAILS + 1))
    fi
}

# All output is tee'd to the TAP artefact.
{
printf '# evidence.sh self-test — run-id %s\n' "$RUN_ID"

# --- Layer 0: parseability gates (§11.4.67) --------------------------------
run_case 0 "evidence.sh parses under sh -n"   sh -n "$LIB"
run_case 0 "evidence.sh parses under bash -n" bash -n "$LIB"

# --- §11.4.69 helper contracts ---------------------------------------------
run_case 0 "ab_pass_with_evidence: non-empty evidence -> PASS" \
    ab_pass_with_evidence "demo" "$FIX/squid_503_body.html"
run_case 1 "ab_pass_with_evidence: empty evidence -> FAIL (negative)" \
    ab_pass_with_evidence "demo" "$FIX/egress_empty.ip"
run_case 1 "ab_pass_with_evidence: missing evidence -> FAIL (negative)" \
    ab_pass_with_evidence "demo" "$FIX/does_not_exist.path"
run_case 0 "ab_skip_with_reason: closed-set reason -> SKIP(0)" \
    ab_skip_with_reason "demo" "network_unreachable_external"
run_case 2 "ab_skip_with_reason: bogus reason -> FAIL(2) (negative)" \
    ab_skip_with_reason "demo" "because_reasons"

# --- wg_transfer_delta ------------------------------------------------------
run_case 0 "wg_transfer_delta: tx/rx delta > 0 -> PASS" \
    wg_transfer_delta wg0 "$FIX/wg_transfer_before.snapshot" "$FIX/wg_transfer_after.snapshot"
run_case 1 "wg_transfer_delta: flat counters (handshake, no flow) -> FAIL (negative)" \
    wg_transfer_delta wg0 "$FIX/wg_transfer_before.snapshot" "$FIX/wg_transfer_after_noflow.snapshot"
run_case 1 "wg_transfer_delta: counter reset/decrease -> FAIL (negative)" \
    wg_transfer_delta wg0 "$FIX/wg_transfer_after.snapshot" "$FIX/wg_transfer_before.snapshot"

# --- assert_egress_ip (seam: EVIDENCE_OBSERVED_IP_FILE) --------------------
export EVIDENCE_OBSERVED_IP_FILE="$FIX/egress_observed_vpn.ip"
run_case 0 "assert_egress_ip: egress==exit && !=host -> PASS" \
    assert_egress_ip "http://127.0.0.1:53128" "185.65.135.70" "203.0.113.45"
run_case 1 "assert_egress_ip: wrong exit -> FAIL (negative)" \
    assert_egress_ip "http://127.0.0.1:53128" "1.2.3.4" "203.0.113.45"
export EVIDENCE_OBSERVED_IP_FILE="$FIX/egress_observed_host.ip"
run_case 1 "assert_egress_ip: egress==host (the §15 bluff) -> FAIL (negative)" \
    assert_egress_ip "http://127.0.0.1:53128" "185.65.135.70" "203.0.113.45"
export EVIDENCE_OBSERVED_IP_FILE="$FIX/egress_empty.ip"
run_case 1 "assert_egress_ip: no egress observed -> FAIL (negative)" \
    assert_egress_ip "http://127.0.0.1:53128" "185.65.135.70" "203.0.113.45"

# --- assert_egress_ip F7 fail-open guard (§11.4.68) -------------------------
# When the host's real IP is UNKNOWN or empty (the caller's `curl ifconfig.me
# || echo "unknown"` / `|| true` fallback fired) the egress!=host HALF of the
# proof cannot be evaluated — comparing egress against "unknown"/"" trivially
# satisfies "different" and could fake-PASS a NO-VPN (egress==host) case. The
# guard returns exit-2 OPERATOR-BLOCKED (never a return-0 SKIP-as-PASS); a
# definitively-wrong exit is still a provable FAIL(1).
export EVIDENCE_OBSERVED_IP_FILE="$FIX/egress_observed_vpn.ip"
run_case 2 "assert_egress_ip: host UNKNOWN + egress==exit -> OPERATOR-BLOCKED(2), NOT fake-PASS (F7)" \
    assert_egress_ip "http://127.0.0.1:53128" "185.65.135.70" "unknown"
run_case 2 "assert_egress_ip: host EMPTY + egress==exit -> OPERATOR-BLOCKED(2), NOT fake-PASS (F7)" \
    assert_egress_ip "http://127.0.0.1:53128" "185.65.135.70" ""
run_case 1 "assert_egress_ip: host UNKNOWN + WRONG exit -> FAIL(1) (provable defect survives the F7 guard)" \
    assert_egress_ip "http://127.0.0.1:53128" "1.2.3.4" "unknown"
export EVIDENCE_OBSERVED_IP_FILE="$FIX/egress_observed_host.ip"
run_case 2 "assert_egress_ip: HIDDEN §15 bluff — egress==host but host reported UNKNOWN -> OPERATOR-BLOCKED(2), NOT fake-PASS (F7)" \
    assert_egress_ip "http://127.0.0.1:53128" "203.0.113.45" "unknown"
# --- F-1 hardening: non-empty, non-"unknown" GARBAGE host_real is exactly as
# unverifiable as empty/unknown (a `curl -s` 200 can echo a captive-portal / rate-limit
# HTML body, or a non-public sentinel like 0.0.0.0) — it MUST take the same exit-2
# OPERATOR-BLOCKED branch, never fall through to a fake-PASS on the collapsed !=host half.
export EVIDENCE_OBSERVED_IP_FILE="$FIX/egress_observed_vpn.ip"
run_case 2 "assert_egress_ip: host GARBAGE (HTML body) + egress==exit -> OPERATOR-BLOCKED(2), NOT fake-PASS (F-1)" \
    assert_egress_ip "http://127.0.0.1:53128" "185.65.135.70" "<html>captive portal login</html>"
run_case 2 "assert_egress_ip: host 0.0.0.0 sentinel + egress==exit -> OPERATOR-BLOCKED(2), NOT fake-PASS (F-1)" \
    assert_egress_ip "http://127.0.0.1:53128" "185.65.135.70" "0.0.0.0"
run_case 1 "assert_egress_ip: host GARBAGE + WRONG exit -> FAIL(1) (provable defect survives the F-1 guard)" \
    assert_egress_ip "http://127.0.0.1:53128" "1.2.3.4" "not-an-ip"
export EVIDENCE_OBSERVED_IP_FILE="$FIX/egress_observed_host.ip"
run_case 2 "assert_egress_ip: HIDDEN §15 bluff — egress==host but host reported as 0.0.0.0 sentinel -> OPERATOR-BLOCKED(2), NOT fake-PASS (F-1)" \
    assert_egress_ip "http://127.0.0.1:53128" "203.0.113.45" "0.0.0.0"
unset EVIDENCE_OBSERVED_IP_FILE

# --- assert_cache_hit -------------------------------------------------------
run_case 0 "assert_cache_hit: TCP_HIT for url -> PASS" \
    assert_cache_hit "$FIX/squid_access_hit.log" "http://cdn.example.com/static/app.css"
run_case 0 "assert_cache_hit: TCP_MEM_HIT for url -> PASS" \
    assert_cache_hit "$FIX/squid_access_hit.log" "http://cdn.example.com/static/logo.png"
run_case 1 "assert_cache_hit: MISS-only log -> FAIL (negative)" \
    assert_cache_hit "$FIX/squid_access_miss.log" "http://cdn.example.com/static/app.css"
run_case 1 "assert_cache_hit: url present but only MISS -> FAIL (url-specific negative)" \
    assert_cache_hit "$FIX/squid_access_hit.log" "http://cdn.example.com/dynamic?x=1"

# --- assert_graceful_503 (seam: EVIDENCE_503_CODE_OVERRIDE + _BODY_FILE) ----
export EVIDENCE_503_CODE_OVERRIDE="503"
export EVIDENCE_503_BODY_FILE="$FIX/squid_503_body.html"
run_case 0 "assert_graceful_503: 503 + branded body + PID unchanged -> PASS" \
    assert_graceful_503 "http://127.0.0.1:53128" "http://blocked.example" "12345" "12345"
run_case 1 "assert_graceful_503: PID changed (crash) -> FAIL (negative)" \
    assert_graceful_503 "http://127.0.0.1:53128" "http://blocked.example" "12345" "12999"
export EVIDENCE_503_CODE_OVERRIDE="200"
run_case 1 "assert_graceful_503: HTTP 200 not 503 -> FAIL (negative)" \
    assert_graceful_503 "http://127.0.0.1:53128" "http://blocked.example" "12345" "12345"
export EVIDENCE_503_CODE_OVERRIDE="503"
export EVIDENCE_503_BODY_FILE="$FIX/squid_503_blank_body.html"
run_case 1 "assert_graceful_503: blank 503 body -> FAIL (negative)" \
    assert_graceful_503 "http://127.0.0.1:53128" "http://blocked.example" "12345" "12345"
unset EVIDENCE_503_CODE_OVERRIDE EVIDENCE_503_BODY_FILE

# --- assert_no_leak ---------------------------------------------------------
run_case 0 "assert_no_leak: tcpdump 0 packets -> PASS" \
    assert_no_leak "$FIX/tcpdump_no_leak.txt"
run_case 1 "assert_no_leak: tcpdump >0 target packets -> FAIL (negative)" \
    assert_no_leak "$FIX/tcpdump_leak.txt"
run_case 0 "assert_no_leak: /proc/net/dev eth0 tx-delta == 0 -> PASS" \
    assert_no_leak "$FIX/proc_net_dev_noleak.delta"
run_case 1 "assert_no_leak: /proc/net/dev eth0 tx-delta > 0 -> FAIL (negative)" \
    assert_no_leak "$FIX/proc_net_dev_leak.delta"
# --- F-E: absence-as-evidence guards (task #76; §11.4.68/§11.4.120) ----------
# A broken/absent sniff MUST NOT score as no-leak. An EMPTY capture and a
# non-empty capture with NO recognizable capture structure (no footer, no
# '=== AFTER', no ' IP ' lines, no tcpdump timestamp) are indistinguishable
# from a failed sniff -> FAIL-closed, never a vacuous zero-IP-lines PASS.
run_case 1 "assert_no_leak: EMPTY capture -> FAIL (broken sniff, not no-leak) (negative)" \
    assert_no_leak "$FIX/egress_empty.ip"
run_case 1 "assert_no_leak: malformed non-empty, no capture structure -> FAIL (negative)" \
    assert_no_leak "$FIX/tcpdump_malformed_nostructure.txt"
# Positive control: a capture that provably RAN (tcpdump timestamps) but recorded
# only non-IPv4 traffic (ARP/IP6) has zero ' IP ' lines yet is genuine no-leak
# -> PASS via the fallback structure check (proves NO false-FAIL on a real 0).
run_case 0 "assert_no_leak: ran-but-zero-IPv4 (timestamps, ARP/IP6 only) -> PASS (no false-FAIL)" \
    assert_no_leak "$FIX/tcpdump_noleak_nonipv4.txt"

# --- procdev_field parser (direct value assertions) ------------------------
check_value 900   "procdev_field: wg0 tx-packets (field 10)" \
    "$(procdev_field "$FIX/proc_net_dev.snapshot" wg0 10)"
check_value 1500  "procdev_field: wg0 rx-packets (field 2)" \
    "$(procdev_field "$FIX/proc_net_dev.snapshot" wg0 2)"
check_value 87654 "procdev_field: eth0 tx-packets (field 10)" \
    "$(procdev_field "$FIX/proc_net_dev.snapshot" eth0 10)"

# --- proxy_conn_verdict (client-side connectivity classifier, BUGFIX-0014) --
# The whole point: never false-FAIL on a site outage (§11.4.1), never fail-OPEN a
# real proxy defect into a SKIP (§11.4.68). Both polarities asserted, including the
# reviewer-caught crashed-proxy case: a positive DIRECT signal out-ranks the port
# probe, so a DEAD proxy (port not listening) on a working host FAILs, never SKIPs.
check_value PASS "proxy_conn_verdict: proxy returns expected -> PASS" \
    "$(proxy_conn_verdict 204 000 '204' yes)"
check_value FAIL "proxy_conn_verdict: proxy miss + site reachable directly (port up) -> FAIL (defect NOT masked)" \
    "$(proxy_conn_verdict 000 204 '204' yes)"
check_value FAIL "proxy_conn_verdict: proxy CRASHED (port down) + site reachable directly -> FAIL (no §11.4.68 fail-open)" \
    "$(proxy_conn_verdict 000 204 '204' no)"
check_value SKIP:network_unreachable_external "proxy_conn_verdict: proxy miss + site also down (port up) -> SKIP outage (no false-FAIL)" \
    "$(proxy_conn_verdict 000 000 '204' yes)"
check_value SKIP:topology_unsupported "proxy_conn_verdict: proxy absent (port down) + no network signal -> SKIP topology (unprovable)" \
    "$(proxy_conn_verdict 000 000 '204' no)"
check_value PASS "proxy_conn_verdict: multi-code expected (301 in '200 301 302') -> PASS" \
    "$(proxy_conn_verdict 301 000 '200 301 302' yes)"
check_value FAIL "proxy_conn_verdict: multi-code expected, proxy miss + direct 200 -> FAIL" \
    "$(proxy_conn_verdict 000 200 '200 301 302' yes)"
check_value SKIP:network_unreachable_external "proxy_conn_verdict: _code_in exact-match (20 does NOT match '200') -> not PASS" \
    "$(proxy_conn_verdict 20 000 '200' yes)"

# --- TAP plan + summary -----------------------------------------------------
printf '1..%d\n' "$TESTS"
printf '# tests=%d passed=%d failed=%d\n' "$TESTS" "$((TESTS - FAILS))" "$FAILS"
if [ "$FAILS" -eq 0 ]; then
    printf '# RESULT: ALL PASS — every parser correct AND fails on its negative fixture\n'
else
    printf '# RESULT: FAILURES PRESENT (%d)\n' "$FAILS"
fi
} | tee "$TAP_OUT"

# Re-derive failure count from the artefact (the tee'd pipeline runs in a
# subshell, so $FAILS is not visible here) and exit accordingly.
if grep -q '^not ok ' "$TAP_OUT"; then
    printf '\nSelf-test artefact: %s\n' "$TAP_OUT" >&2
    exit 1
fi
printf '\nSelf-test artefact: %s\n' "$TAP_OUT" >&2
exit 0
