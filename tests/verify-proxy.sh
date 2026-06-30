#!/usr/bin/env bash
#######################################
# Proxy Service Verification Script
#######################################

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Load environment
source "$PROJECT_ROOT/.env" 2>/dev/null || true

HTTP_PROXY_PORT="${HTTP_PROXY_PORT:-53128}"
SOCKS_PROXY_PORT="${SOCKS_PROXY_PORT:-51080}"

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

PASS=0
FAIL=0

# §11.4.1 enabler: assignment form, NOT (( PASS++ )) / (( FAIL++ )). Under
# `set -e` a post-increment whose prior value is 0 evaluates the (( )) to 0,
# which returns exit status 1 and aborts the whole script before the VPN check
# is ever reached. (Same fix the sibling run-tests.sh already adopted.)
test_pass() { echo -e "${GREEN}✓${NC} $1"; PASS=$((PASS + 1)); }
test_fail() { echo -e "${RED}✗${NC} $1"; FAIL=$((FAIL + 1)); }

echo -e "${CYAN}=== Proxy Service Verification ===${NC}\n"

# 1. HTTP Proxy
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 --proxy http://localhost:${HTTP_PROXY_PORT} 'http://connectivitycheck.gstatic.com/generate_204' 2>/dev/null || echo "000")
[[ "$code" == "204" ]] && test_pass "HTTP Proxy working (code: $code)" || test_fail "HTTP Proxy (code: $code)"

# 2. HTTPS through HTTP Proxy  
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 --proxy http://localhost:${HTTP_PROXY_PORT} 'https://www.google.com' 2>/dev/null || echo "000")
[[ "$code" =~ ^(200|301|302)$ ]] && test_pass "HTTPS through HTTP Proxy (code: $code)" || test_fail "HTTPS through HTTP Proxy (code: $code)"

# 3. SOCKS5 Proxy
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 --proxy socks5://localhost:${SOCKS_PROXY_PORT} 'http://connectivitycheck.gstatic.com/generate_204' 2>/dev/null || echo "000")
[[ "$code" == "204" ]] && test_pass "SOCKS5 Proxy working (code: $code)" || test_fail "SOCKS5 Proxy (code: $code)"

# 4. HTTPS through SOCKS5
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 --proxy socks5://localhost:${SOCKS_PROXY_PORT} 'https://www.google.com' 2>/dev/null || echo "000")
[[ "$code" =~ ^(200|301|302)$ ]] && test_pass "HTTPS through SOCKS5 (code: $code)" || test_fail "HTTPS through SOCKS5 (code: $code)"

# 5. VPN Routing — §11.4.69 data-plane egress proof (anti-bluff audit B6).
#    OLD BLUFF (removed): the old line-46 comment "check that proxy uses same IP
#    as host" literally encoded the WRONG invariant, and host_ip == proxy_ip =>
#    test_pass "VPN routing verified" PROVES traffic was NOT routed via any VPN
#    (host and proxy egress exit the SAME uplink). The decisive proof
#    (evidence.sh assert_egress_ip / design §15) requires the egress IP seen
#    THROUGH the proxy to EQUAL the expected tunnel exit AND DIFFER from the
#    host's real IP. Absent a live tunnel (VPN_EXIT_IP unset) we SKIP honestly
#    (§11.4.3) — we do NOT fabricate a VPN PASS; live RED/GREEN proof deferred to P10.
. "$SCRIPT_DIR/lib/evidence.sh"
EXPECTED_EXIT_IP="${VPN_EXIT_IP:-}"
if [[ -n "$EXPECTED_EXIT_IP" ]]; then
    host_ip=$(curl -s -4 --max-time 15 https://ifconfig.me 2>/dev/null || echo "unknown")
    if assert_egress_ip "http://localhost:${HTTP_PROXY_PORT}" "$EXPECTED_EXIT_IP" "$host_ip"; then
        test_pass "VPN routing (egress=$EXPECTED_EXIT_IP, != host $host_ip)"
    else
        test_fail "VPN routing (egress not expected exit $EXPECTED_EXIT_IP, or == host)"
    fi
else
    ab_skip_with_reason "VPN routing (egress == expected tunnel exit, != host)" "operator_attended"
fi

# Summary
echo ""
echo -e "${CYAN}Summary:${NC} ${GREEN}Passed: $PASS${NC}, ${RED}Failed: $FAIL${NC}"

if [[ $FAIL -eq 0 ]]; then
    echo -e "${GREEN}All tests passed! Proxy service is working correctly.${NC}"
    exit 0
else
    echo -e "${RED}Some tests failed.${NC}"
    exit 1
fi
