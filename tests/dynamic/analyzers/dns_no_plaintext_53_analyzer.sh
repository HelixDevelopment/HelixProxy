#!/usr/bin/env bash
# =============================================================================
# dns_no_plaintext_53_analyzer.sh — signal 5: no plaintext :53 DNS leak
# -----------------------------------------------------------------------------
# Signal:       DNS privacy / leak-prevention (§11.4.69 network_connectivity;
#               design §11 ② DoH/DoT + leak prevention; §13 "DNS only via the
#               intended resolver"). FRESH oracle — no evidence.sh helper exists
#               for this signal yet.
# Oracle:       Given a tcpdump capture taken ON THE REAL UPLINK, PASS iff ZERO
#               plaintext UDP/TCP :53 DNS packets reach a NON-allowed resolver.
#               Legitimate DNS under dynamic mode is DoH/DoT (443/853, encrypted)
#               — a plaintext :53 packet on the real uplink to an external
#               resolver is a DNS LEAK. An optional allow-list (the in-tunnel
#               resolver IP[s]) excludes the sanctioned in-namespace resolver.
# golden-good:  capture with zero plaintext :53 lines (DNS went DoH) -> PASS;
#               or :53 only to an allow-listed in-tunnel resolver -> PASS.
# golden-BAD:   a plaintext :53 query to a non-tunnel resolver (1.1.1.1) -> FAIL.
# Usage:        dns_no_plaintext_53_analyzer.sh analyze <capture> [allow-csv]
#               dns_no_plaintext_53_analyzer.sh --selftest        (default action)
# Output:       PASS:/FAIL: verdict; rc 0 = PASS, 1 = FAIL.
# Anti-bluff:   default allow-list is EMPTY (fail-closed) — any plaintext :53 is
#               a leak unless an explicit sanctioned resolver is allow-listed
#               (§11.4.6 no-guessing: a leak is never assumed benign).
# Shell:        POSIX-clean (sh -n + bash -n, §11.4.67). awk does the parse.
# Cross-refs:   §11.4.69 / §11.4.107 / §11.4.115; design §11 ② / §13.
# =============================================================================
_ANZ_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=/dev/null
. "$_ANZ_DIR/../lib/analyzer_common.sh"
_FIX="$_ANZ_DIR/fixtures/dns_no_plaintext_53"

# _dns_leaked_resolvers <capture> <allow-csv>
# Prints one leaked (non-allowed) resolver IP per plaintext :53 packet found.
_dns_leaked_resolvers() {
    awk -v allow="$2" '
        function ipport_to_ip(tok,   a, n, i, s, port) {
            sub(/:$/, "", tok)
            n = split(tok, a, ".")
            if (n < 2) return ""
            port = a[n]
            if (port != "53") return ""
            s = a[1]
            for (i = 2; i < n; i++) s = s "." a[i]
            return s
        }
        function allowed(ip,   i) {
            for (i = 1; i <= na; i++) if (al[i] != "" && al[i] == ip) return 1
            return 0
        }
        BEGIN { na = split(allow, al, ",") }
        {
            for (i = 1; i <= NF; i++) {
                if ($i == ">") {
                    ipd = ipport_to_ip($(i + 1))   # destination .53: (query)
                    ips = ipport_to_ip($(i - 1))   # source .53 (response)
                    if (ipd != "" && !allowed(ipd)) print ipd
                    else if (ips != "" && !allowed(ips)) print ips
                }
            }
        }
    ' "$1" 2>/dev/null
}

# analyze_dns_no_plaintext_53 <capture-file> [allow-csv]
analyze_dns_no_plaintext_53() {
    capture=$1
    allow=${2:-${HELIX_DNS_ALLOW_RESOLVERS:-}}
    if [ -z "$capture" ] || [ ! -f "$capture" ]; then
        ac_fail "dns_no_plaintext_53" "[reason: capture file missing: ${capture:-<none>}]"
        return 1
    fi
    leaked=$(_dns_leaked_resolvers "$capture" "$allow")
    if [ -n "$leaked" ]; then
        first=$(printf '%s\n' "$leaked" | awk 'NF { print $1; exit }')
        count=$(printf '%s\n' "$leaked" | grep -c .)
        ac_fail "dns_no_plaintext_53" "[reason: $count plaintext :53 packet(s) to non-tunnel resolver(s) — DNS LEAK (e.g. $first) ($capture)]"
        return 1
    fi
    if [ "$AC_EVIDENCE_AVAILABLE" = "1" ]; then
        ab_pass_with_evidence "dns_no_plaintext_53 (zero plaintext :53 on real uplink)" "$capture"
        return $?
    fi
    ac_pass "dns_no_plaintext_53" "[evidence: zero plaintext :53 on real uplink ($capture)]"
}

_selftest_dns_no_plaintext_53() {
    ac_selftest_reset
    printf '# dns_no_plaintext_53_analyzer self-test\n'
    ac_expect 0 "golden-good: DoH only, zero :53 on uplink -> PASS" \
        -- analyze_dns_no_plaintext_53 "$_FIX/golden_good.doh.txt"
    ac_expect 0 "golden-good: :53 only to allow-listed in-tunnel resolver -> PASS" \
        -- analyze_dns_no_plaintext_53 "$_FIX/golden_good.allowed_resolver.txt" "10.64.0.1"
    ac_expect 1 "golden-BAD: plaintext :53 query to 1.1.1.1 (non-tunnel) -> FAIL" \
        -- analyze_dns_no_plaintext_53 "$_FIX/golden_bad.plaintext53.txt"
    ac_expect 1 "golden-BAD: :53 to in-tunnel resolver but NOT allow-listed -> FAIL (fail-closed default)" \
        -- analyze_dns_no_plaintext_53 "$_FIX/golden_good.allowed_resolver.txt"
    ac_expect 1 "negative: missing capture -> FAIL" \
        -- analyze_dns_no_plaintext_53 "$_FIX/does_not_exist.txt"
    ac_selftest_summary "dns_no_plaintext_53_analyzer"
}

case "${1:-}" in
    analyze) shift; analyze_dns_no_plaintext_53 "$@" ;;
    --selftest|selftest|"") _selftest_dns_no_plaintext_53 ;;
    *) analyze_dns_no_plaintext_53 "$@" ;;
esac
