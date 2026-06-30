#!/usr/bin/env bash
# =============================================================================
# no_leak_analyzer.sh — signal 1: ZERO target packets on the real uplink (down)
# -----------------------------------------------------------------------------
# Signal:       fail-closed kill-switch / no-leak (§11.4.69 network_connectivity;
#               design §10/§13 no_leak; research §5).
# Oracle:       Given a tcpdump capture taken ON THE REAL UPLINK while the target
#               tunnel is DOWN, PASS iff ZERO packets escaped to the target.
#               Delegates the parse to the COMMITTED, self-tested
#               evidence.sh:assert_no_leak (tcpdump "N packets captured", a
#               /proc/net/dev tx-packet delta, or raw " IP " line count) and adds
#               the dynamic-mode optional target-host filter.
# golden-good:  a real-uplink capture during the DOWN window with 0 target pkts.
# golden-BAD:   the SAME capture WITH a leaked target packet -> MUST FAIL (an
#               analyzer that passes this is a bluff gate, §11.4.107(10)).
# Usage:        no_leak_analyzer.sh analyze <capture-file> [target-host-or-ip]
#               no_leak_analyzer.sh --selftest        (default action)
# Output:       PASS:/FAIL: verdict line; rc 0 = PASS, 1 = FAIL.
# Anti-bluff:   testing leaks while the tunnel is UP proves nothing; this asserts
#               fail-closed during the DOWN window only (§11.4.107 honest window).
# Shell:        POSIX-clean (sh -n + bash -n, §11.4.67).
# Cross-refs:   §11.4.69 / §11.4.107 / §11.4.115; tests/lib/evidence.sh.
# =============================================================================
_ANZ_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=/dev/null
. "$_ANZ_DIR/../lib/analyzer_common.sh"
_FIX="$_ANZ_DIR/fixtures/no_leak"

# analyze_no_leak <capture-file> [target]
# Delegates the zero-packet decision to the canonical evidence.sh oracle. When a
# <target> is supplied AND the capture is a raw tcpdump text, an extra guard
# counts ONLY packet lines mentioning the target (so unrelated host chatter on a
# shared uplink does not mask or cause a false leak verdict).
analyze_no_leak() {
    capture=$1
    target=${2:-}
    if [ -z "$capture" ] || [ ! -f "$capture" ]; then
        ac_fail "no_leak" "[reason: capture file missing: ${capture:-<none>}]"
        return 1
    fi
    if [ "$AC_EVIDENCE_AVAILABLE" != "1" ]; then
        ac_fail "no_leak" "[reason: committed tests/lib/evidence.sh not found — cannot delegate]"
        return 1
    fi

    # Target-specific guard for raw text captures (no "packets captured" footer
    # and not a /proc/net/dev delta): count target packet lines explicitly.
    if [ -n "$target" ] \
        && ! grep -qi 'packets captured' "$capture" 2>/dev/null \
        && ! grep -q '=== AFTER' "$capture" 2>/dev/null; then
        n=$(grep -c -- " IP .*$target" "$capture" 2>/dev/null)
        n=${n:-0}
        if [ "$n" -eq 0 ] 2>/dev/null; then
            ab_pass_with_evidence "no_leak (0 target=$target packets on real uplink)" "$capture"
            return $?
        fi
        ac_fail "no_leak" "[reason: $n packet line(s) to target $target on real uplink — LEAK ($capture)]"
        return 1
    fi

    # General case: delegate to the canonical oracle (returns 0 PASS / 1 FAIL).
    assert_no_leak "$capture"
}

_selftest_no_leak() {
    ac_selftest_reset
    printf '# no_leak_analyzer self-test\n'
    ac_expect 0 "golden-good: tcpdump 0 target packets -> PASS" \
        -- analyze_no_leak "$_FIX/golden_good.tcpdump.txt"
    ac_expect 1 "golden-BAD: tcpdump with leaked target packet -> FAIL" \
        -- analyze_no_leak "$_FIX/golden_bad.tcpdump.txt"
    ac_expect 0 "golden-good: /proc/net/dev eth0 tx-delta == 0 -> PASS" \
        -- analyze_no_leak "$_FIX/golden_good.procdev.delta"
    ac_expect 1 "golden-BAD: /proc/net/dev eth0 tx-delta > 0 -> FAIL" \
        -- analyze_no_leak "$_FIX/golden_bad.procdev.delta"
    ac_expect 0 "golden-good: target-filtered raw capture, 0 target lines -> PASS" \
        -- analyze_no_leak "$_FIX/golden_good.targetfilter.txt" "93.184.216.34"
    ac_expect 1 "golden-BAD: target-filtered raw capture, target line present -> FAIL" \
        -- analyze_no_leak "$_FIX/golden_bad.targetfilter.txt" "93.184.216.34"
    ac_expect 1 "negative: missing capture file -> FAIL" \
        -- analyze_no_leak "$_FIX/does_not_exist.path"
    ac_selftest_summary "no_leak_analyzer"
}

case "${1:-}" in
    analyze) shift; analyze_no_leak "$@" ;;
    --selftest|selftest|"") _selftest_no_leak ;;
    *) analyze_no_leak "$@" ;;
esac
