#!/usr/bin/env bash
# =============================================================================
# egress_neq_host_analyzer.sh — signal 3: egress IP via proxy != host public IP
# -----------------------------------------------------------------------------
# Signal:       real VPN egress (§11.4.69 network_connectivity; design §13
#               vpn_real_egress; research §15 — THE hardest-to-fake routing proof).
# Oracle:       The egress IP observed THROUGH the proxy must equal the EXPECTED
#               tunnel exit AND differ from the host's real public IP. A 200 OK is
#               NOT proof of routing; egress == host is the §15 bluff (the named
#               `host_ip == proxy_ip` PASS-with-no-VPN). Delegates to the
#               COMMITTED, self-tested evidence.sh:assert_egress_ip via its
#               EVIDENCE_OBSERVED_IP_FILE seam, feeding a captured egress IP.
# golden-good:  observed == expected_exit AND observed != host_real -> PASS.
# golden-BAD:   observed == host_real (no VPN diversion) -> MUST FAIL.
# Manifest:     key=val text file:
#                 observed_ip_file=egress_vpn.ip   (resolved relative to manifest)
#                 expected_exit=185.65.135.70
#                 host_real=203.0.113.45
# Usage:        egress_neq_host_analyzer.sh analyze <manifest-file>
#               egress_neq_host_analyzer.sh --selftest        (default action)
# Output:       PASS:/FAIL: verdict; rc 0 = PASS, 1 = FAIL.
# Anti-bluff:   pairs with wg_transfer_delta in P10 (egress-IP echo can be cached;
#               the WireGuard byte-delta is the orthogonal data-plane corroboration).
# Shell:        POSIX-clean (sh -n + bash -n, §11.4.67).
# Cross-refs:   §11.4.69 / §11.4.107 / §11.4.115; tests/lib/evidence.sh:213.
# =============================================================================
_ANZ_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=/dev/null
. "$_ANZ_DIR/../lib/analyzer_common.sh"
_FIX="$_ANZ_DIR/fixtures/egress_neq_host"

_egress_manifest_get() {
    awk -F= -v k="$2" '$1 == k { sub(/^[^=]*=/, ""); print; exit }' "$1" 2>/dev/null
}

# analyze_egress_neq_host <manifest-file>
analyze_egress_neq_host() {
    manifest=$1
    if [ -z "$manifest" ] || [ ! -f "$manifest" ]; then
        ac_fail "egress_neq_host" "[reason: manifest missing: ${manifest:-<none>}]"
        return 1
    fi
    if [ "$AC_EVIDENCE_AVAILABLE" != "1" ]; then
        ac_fail "egress_neq_host" "[reason: committed tests/lib/evidence.sh not found — cannot delegate]"
        return 1
    fi
    mdir=$(cd "$(dirname "$manifest")" && pwd)
    obs=$(_egress_manifest_get "$manifest" observed_ip_file)
    exit_ip=$(_egress_manifest_get "$manifest" expected_exit)
    host_ip=$(_egress_manifest_get "$manifest" host_real)
    case "$obs" in
        /*) : ;;
        *)  obs="$mdir/$obs" ;;
    esac
    if [ ! -f "$obs" ]; then
        ac_fail "egress_neq_host" "[reason: observed-egress capture missing: $obs]"
        return 1
    fi
    EVIDENCE_OBSERVED_IP_FILE=$obs \
        assert_egress_ip "$(dyn_stack_proxy_url)" "$exit_ip" "$host_ip"
}

_selftest_egress_neq_host() {
    ac_selftest_reset
    printf '# egress_neq_host_analyzer self-test\n'
    ac_expect 0 "golden-good: egress==exit && !=host -> PASS" \
        -- analyze_egress_neq_host "$_FIX/golden_good.manifest"
    ac_expect 1 "golden-BAD: egress==host (the §15 no-VPN bluff) -> FAIL" \
        -- analyze_egress_neq_host "$_FIX/golden_bad_egress_eq_host.manifest"
    ac_expect 1 "golden-BAD: egress is a wrong (unexpected) exit -> FAIL" \
        -- analyze_egress_neq_host "$_FIX/golden_bad_wrong_exit.manifest"
    ac_expect 1 "golden-BAD: empty egress capture (nothing observed) -> FAIL" \
        -- analyze_egress_neq_host "$_FIX/golden_bad_empty.manifest"
    ac_expect 1 "negative: missing manifest -> FAIL" \
        -- analyze_egress_neq_host "$_FIX/does_not_exist.manifest"
    ac_selftest_summary "egress_neq_host_analyzer"
}

case "${1:-}" in
    analyze) shift; analyze_egress_neq_host "$@" ;;
    --selftest|selftest|"") _selftest_egress_neq_host ;;
    *) analyze_egress_neq_host "$@" ;;
esac
