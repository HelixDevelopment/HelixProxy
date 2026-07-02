#!/usr/bin/env bash
#######################################
# Final Proxy Service Verification
#######################################

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Load environment
source "$PROJECT_ROOT/.env" 2>/dev/null || true

HTTP_PROXY_PORT="${HTTP_PROXY_PORT:-34128}"
SOCKS_PROXY_PORT="${SOCKS_PROXY_PORT:-34080}"

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

PASS=0
FAIL=0
SKIP=0

# §11.4.1 enabler: assignment form, NOT (( PASS++ )) / (( FAIL++ )). Under
# `set -e` a post-increment whose prior value is 0 evaluates the (( )) to 0,
# which returns exit status 1 and aborts the whole script before the VPN check
# is ever reached. (Same fix the sibling run-tests.sh already adopted.)
test_pass() { echo -e "${GREEN}✓${NC} $1"; PASS=$((PASS + 1)); }
test_fail() { echo -e "${RED}✗${NC} $1"; FAIL=$((FAIL + 1)); }

# Data-plane anti-bluff evidence helpers (proxy_conn_verdict / port_is_listening /
# ab_skip_with_reason / assert_egress_ip). Sourced up-front so the connectivity
# checks below can CLASSIFY a proxy miss instead of blindly FAILing on a
# third-party/local-internet outage (§11.4.1 / discovery-sweep F3).
. "$SCRIPT_DIR/lib/evidence.sh"

# conn_check <label> <scheme> <port> <url> <expected-codes>
# Anti-bluff through-proxy connectivity check: proxy returns expected -> PASS; a
# site outage (proxy AND direct both fail) -> SKIP (no §11.4.1 false-FAIL); the
# proxy is up but cannot fetch a site reachable DIRECTLY -> FAIL (no §11.4.68
# fail-open of a real defect); the proxy port is not listening -> SKIP (absent).
conn_check() {
    _cc_label=$1; _cc_scheme=$2; _cc_port=$3; _cc_url=$4; _cc_expected=$5
    _cc_pc=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 \
        --proxy "${_cc_scheme}://localhost:${_cc_port}" "$_cc_url" 2>/dev/null || echo "000")
    if _code_in "$_cc_pc" "$_cc_expected"; then
        test_pass "$_cc_label (code: $_cc_pc)"
        return 0
    fi
    _cc_dc=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "$_cc_url" 2>/dev/null || echo "000")
    _cc_listen=no
    if port_is_listening "$_cc_port"; then _cc_listen=yes; fi
    _cc_v=$(proxy_conn_verdict "$_cc_pc" "$_cc_dc" "$_cc_expected" "$_cc_listen")
    case "$_cc_v" in
        PASS)   test_pass "$_cc_label (code: $_cc_pc)" ;;
        FAIL)   test_fail "$_cc_label (proxy code: $_cc_pc, site reachable directly: $_cc_dc)" ;;
        SKIP:*) ab_skip_with_reason "$_cc_label (proxy code: $_cc_pc, direct: $_cc_dc)" "${_cc_v#SKIP:}"
                SKIP=$((SKIP + 1)) ;;
    esac
}

echo -e "${CYAN}"
echo "╔════════════════════════════════════════════════════════════╗"
echo "║           PROXY SERVICE FINAL VERIFICATION                   ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo -e "${NC}\n"

# 1. HTTP Proxy
conn_check "HTTP Proxy" http "$HTTP_PROXY_PORT" 'http://connectivitycheck.gstatic.com/generate_204' '204'

# 2. HTTPS through HTTP Proxy
conn_check "HTTPS through HTTP Proxy" http "$HTTP_PROXY_PORT" 'https://www.google.com' '200 301 302'

# 3. SOCKS5 Proxy
conn_check "SOCKS5 Proxy" socks5 "$SOCKS_PROXY_PORT" 'http://connectivitycheck.gstatic.com/generate_204' '204'

# 4. HTTPS through SOCKS5
conn_check "HTTPS through SOCKS5" socks5 "$SOCKS_PROXY_PORT" 'https://www.google.com' '200 301 302'

# 5. VPN Routing — §11.4.69 data-plane egress proof (anti-bluff audit B5).
#    OLD BLUFF (removed): host_ip == proxy_ip => test_pass "VPN routing verified".
#    That equality PROVES traffic was NOT routed via any VPN — the host's direct
#    egress and the proxy's egress exit the SAME uplink address. The decisive
#    proof (evidence.sh assert_egress_ip / design §15) requires the egress IP
#    seen THROUGH the proxy to EQUAL the expected tunnel exit AND DIFFER from the
#    host's real IP. Absent a live tunnel (VPN_EXIT_IP unset) we SKIP honestly
#    (§11.4.3) — we do NOT fabricate a VPN PASS; the live RED/GREEN proof is
#    deferred to P10 (needs a real tunnel + VPN_EXIT_IP).
echo "Verifying VPN routing..."
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
    SKIP=$((SKIP + 1))
fi

# Summary
echo ""
echo -e "${CYAN}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║  SUMMARY: ${GREEN}Passed: $PASS${NC} ${RED}Failed: $FAIL${NC} Skipped: $SKIP                  ${NC}"
echo -e "${CYAN}╚════════════════════════════════════════════════════════════╝${NC}"
echo ""

if [[ $FAIL -eq 0 ]]; then
    echo -e "${GREEN}All tests passed! Proxy service is working correctly.${NC}"
    exit 0
else
    echo -e "${RED}Some tests failed. Check the proxy configuration.${NC}"
    exit 1
fi
