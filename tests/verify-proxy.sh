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

test_pass() { echo -e "${GREEN}✓${NC} $1"; ((PASS++)); }
test_fail() { echo -e "${RED}✗${NC} $1"; ((FAIL++)); }

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

# 5. VPN Routing - check that proxy uses same IP as host
host_ip=$(curl -s -4 --max-time 15 https://ifconfig.me 2>/dev/null || echo "unknown")
proxy_ip=$(curl -s -4 --max-time 15 --proxy http://localhost:${HTTP_PROXY_PORT} https://ifconfig.me 2>/dev/null || echo "unknown")
[[ "$host_ip" == "$proxy_ip" && "$host_ip" != "unknown" ]] && test_pass "VPN routing verified (IP: $host_ip)" || test_fail "VPN routing (host: $host_ip, proxy: $proxy_ip)"

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
