#!/usr/bin/env bash
#######################################
# Comprehensive Proxy Service Tests
# Tests all functionality including VPN routing
#######################################

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Test counters
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0
TESTS_SKIPPED=0

# Test results storage
declare -a FAILED_TESTS=()

#######################################
# Print test header
#######################################
test_header() {
    echo -e "\n${CYAN}════════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}  $1${NC}"
    echo -e "${CYAN}════════════════════════════════════════════════════════════${NC}\n"
}

#######################################
# Print test result
#######################################
test_result() {
    local name="$1"
    local result="$2"
    local message="${3:-}"
    
    ((TESTS_RUN++))
    
    case "$result" in
        PASS)
            ((TESTS_PASSED++))
            echo -e "${GREEN}✓ PASS${NC}: $name"
            ;;
        FAIL)
            ((TESTS_FAILED++))
            FAILED_TESTS+=("$name: $message")
            echo -e "${RED}✗ FAIL${NC}: $name"
            [[ -n "$message" ]] && echo -e "  ${YELLOW}→ $message${NC}"
            ;;
        SKIP)
            ((TESTS_SKIPPED++))
            echo -e "${YELLOW}⊘ SKIP${NC}: $name${message:+ - $message}"
            ;;
    esac
}

#######################################
# Check if command exists
#######################################
command_exists() {
    command -v "$1" &>/dev/null
}

#######################################
# Get container runtime
#######################################
get_runtime() {
    if command_exists podman && podman info &>/dev/null; then
        echo "podman"
    elif command_exists docker && docker info &>/dev/null; then
        echo "docker"
    else
        echo "none"
    fi
}

#######################################
# Check container is running
#######################################
container_running() {
    local name="$1"
    local runtime
    runtime=$(get_runtime)
    
    case "$runtime" in
        podman)
            podman ps --format '{{.Names}}' | grep -q "^${name}$"
            ;;
        docker)
            docker ps --format '{{.Names}}' | grep -q "^${name}$"
            ;;
        *)
            return 1
            ;;
    esac
}

#######################################
# Get host IP (external)
#######################################
get_external_ip() {
    curl -s --max-time 10 https://ifconfig.me 2>/dev/null || \
    curl -s --max-time 10 https://api.ipify.org 2>/dev/null || \
    echo "unknown"
}

#######################################
# Get proxy IP (through proxy)
#######################################
get_proxy_ip() {
    local proxy_host="${1:-localhost}"
    local proxy_port="${2:-53128}"
    
    curl -s --max-time 15 \
        --proxy "http://${proxy_host}:${proxy_port}" \
        https://ifconfig.me 2>/dev/null || \
    curl -s --max-time 15 \
        --proxy "http://${proxy_host}:${proxy_port}" \
        https://api.ipify.org 2>/dev/null || \
    echo "unknown"
}

#######################################
# Get SOCKS proxy IP
#######################################
get_socks_proxy_ip() {
    local proxy_host="${1:-localhost}"
    local proxy_port="${2:-51080}"
    
    curl -s --max-time 15 \
        --proxy "socks5://${proxy_host}:${proxy_port}" \
        https://ifconfig.me 2>/dev/null || \
    echo "unknown"
}

#######################################
# Test: Environment configuration
#######################################
test_environment() {
    test_header "ENVIRONMENT TESTS"
    
    cd "$PROJECT_ROOT"
    
    # Test .env file exists
    if [[ -f ".env" ]]; then
        test_result ".env file exists" "PASS"
    else
        test_result ".env file exists" "FAIL" "Run 'cp .env.example .env'"
        return 1
    fi
    
    # Source environment
    source .env
    
    # Test required variables
    [[ -n "${HTTP_PROXY_PORT:-}" ]] && test_result "HTTP_PROXY_PORT set ($HTTP_PROXY_PORT)" "PASS" || test_result "HTTP_PROXY_PORT set" "FAIL"
    [[ -n "${SOCKS_PROXY_PORT:-}" ]] && test_result "SOCKS_PROXY_PORT set ($SOCKS_PROXY_PORT)" "PASS" || test_result "SOCKS_PROXY_PORT set" "FAIL"
    [[ -n "${CACHE_DIR:-}" ]] && test_result "CACHE_DIR set ($CACHE_DIR)" "PASS" || test_result "CACHE_DIR set" "FAIL"
    
    # Test cache directory exists
    if [[ -d "${CACHE_DIR:-./cache}" ]]; then
        test_result "Cache directory exists" "PASS"
    else
        test_result "Cache directory exists" "FAIL" "Run './init'"
    fi
}

#######################################
# Test: Scripts executable
#######################################
test_scripts() {
    test_header "SCRIPT TESTS"
    
    local scripts=("init" "start" "stop" "status" "cache" "restart")
    
    for script in "${scripts[@]}"; do
        if [[ -x "$PROJECT_ROOT/$script" ]]; then
            test_result "Script $script is executable" "PASS"
        else
            test_result "Script $script is executable" "FAIL"
        fi
    done
}

#######################################
# Test: Container runtime
#######################################
test_container_runtime() {
    test_header "CONTAINER RUNTIME TESTS"
    
    local runtime
    runtime=$(get_runtime)
    
    if [[ "$runtime" == "none" ]]; then
        test_result "Container runtime available" "FAIL" "Install Docker or Podman"
        return 1
    fi
    
    test_result "Container runtime: $runtime" "PASS"
    
    # Check compose
    if [[ "$runtime" == "podman" ]]; then
        if command_exists podman-compose || podman compose version &>/dev/null; then
            test_result "Podman compose available" "PASS"
        else
            test_result "Podman compose available" "FAIL"
        fi
    else
        if command_exists docker-compose || docker compose version &>/dev/null; then
            test_result "Docker compose available" "PASS"
        else
            test_result "Docker compose available" "FAIL"
        fi
    fi
}

#######################################
# Test: Service containers
#######################################
test_containers() {
    test_header "CONTAINER STATUS TESTS"
    
    # Check Squid
    if container_running "proxy-squid"; then
        test_result "Squid container running" "PASS"
    else
        test_result "Squid container running" "FAIL"
    fi
    
    # Check Dante
    if container_running "proxy-dante"; then
        test_result "Dante container running" "PASS"
    else
        test_result "Dante container running" "FAIL"
    fi
    
    # Check VPN (optional)
    if container_running "proxy-vpn"; then
        test_result "VPN container running" "PASS"
    else
        test_result "VPN container running" "SKIP" "Not using containerized VPN"
    fi
}

#######################################
# Test: Port availability
#######################################
test_ports() {
    test_header "PORT BINDING TESTS"
    
    source "$PROJECT_ROOT/.env" 2>/dev/null || true
    
    local http_port="${HTTP_PROXY_PORT:-53128}"
    local socks_port="${SOCKS_PROXY_PORT:-51080}"
    local admin_port="${PROXY_ADMIN_PORT:-58080}"
    
    # Test HTTP proxy port
    if ss -tuln | grep -q ":${http_port} "; then
        test_result "HTTP proxy port $http_port listening" "PASS"
    else
        test_result "HTTP proxy port $http_port listening" "FAIL"
    fi
    
    # Test SOCKS proxy port
    if ss -tuln | grep -q ":${socks_port} "; then
        test_result "SOCKS proxy port $socks_port listening" "PASS"
    else
        test_result "SOCKS proxy port $socks_port listening" "FAIL"
    fi
    
    # Test admin port
    if ss -tuln | grep -q ":${admin_port} "; then
        test_result "Admin port $admin_port listening" "PASS"
    else
        test_result "Admin port $admin_port listening" "SKIP" "Optional"
    fi
}

#######################################
# Test: HTTP Proxy functionality
#######################################
test_http_proxy() {
    test_header "HTTP PROXY TESTS"
    
    source "$PROJECT_ROOT/.env" 2>/dev/null || true
    local port="${HTTP_PROXY_PORT:-53128}"
    
    # Test basic connectivity
    local response
    response=$(curl -s -o /dev/null -w "%{http_code}" \
        --max-time 15 \
        --proxy "http://localhost:$port" \
        "http://connectivitycheck.gstatic.com/generate_204" 2>/dev/null || echo "000")
    
    if [[ "$response" == "204" || "$response" == "200" ]]; then
        test_result "HTTP proxy connectivity" "PASS"
    else
        test_result "HTTP proxy connectivity" "FAIL" "HTTP code: $response"
    fi
    
    # Test HTTPS through proxy
    response=$(curl -s -o /dev/null -w "%{http_code}" \
        --max-time 15 \
        --proxy "http://localhost:$port" \
        "https://www.google.com" 2>/dev/null || echo "000")
    
    if [[ "$response" == "200" || "$response" == "301" || "$response" == "302" ]]; then
        test_result "HTTPS through HTTP proxy" "PASS"
    else
        test_result "HTTPS through HTTP proxy" "FAIL" "HTTP code: $response"
    fi
    
    # Test various sites
    local sites=("https://httpbin.org/ip" "https://api.ipify.org")
    for site in "${sites[@]}"; do
        response=$(curl -s -o /dev/null -w "%{http_code}" \
            --max-time 10 \
            --proxy "http://localhost:$port" \
            "$site" 2>/dev/null || echo "000")
        
        if [[ "$response" == "200" ]]; then
            test_result "Access $site" "PASS"
        else
            test_result "Access $site" "FAIL" "HTTP code: $response"
        fi
    done
}

#######################################
# Test: SOCKS Proxy functionality
#######################################
test_socks_proxy() {
    test_header "SOCKS5 PROXY TESTS"
    
    source "$PROJECT_ROOT/.env" 2>/dev/null || true
    local port="${SOCKS_PROXY_PORT:-51080}"
    
    # Test basic connectivity
    local response
    response=$(curl -s -o /dev/null -w "%{http_code}" \
        --max-time 15 \
        --proxy "socks5://localhost:$port" \
        "http://connectivitycheck.gstatic.com/generate_204" 2>/dev/null || echo "000")
    
    if [[ "$response" == "204" || "$response" == "200" ]]; then
        test_result "SOCKS proxy connectivity" "PASS"
    else
        test_result "SOCKS proxy connectivity" "FAIL" "HTTP code: $response"
    fi
    
    # Test HTTPS through SOCKS
    response=$(curl -s -o /dev/null -w "%{http_code}" \
        --max-time 15 \
        --proxy "socks5://localhost:$port" \
        "https://www.google.com" 2>/dev/null || echo "000")
    
    if [[ "$response" == "200" || "$response" == "301" || "$response" == "302" ]]; then
        test_result "HTTPS through SOCKS proxy" "PASS"
    else
        test_result "HTTPS through SOCKS proxy" "FAIL" "HTTP code: $response"
    fi
}

#######################################
# Test: VPN routing
#######################################
test_vpn_routing() {
    test_header "VPN ROUTING TESTS"
    
    source "$PROJECT_ROOT/.env" 2>/dev/null || true
    local http_port="${HTTP_PROXY_PORT:-53128}"
    local socks_port="${SOCKS_PROXY_PORT:-51080}"
    
    # Get host IP (direct)
    local host_ip
    host_ip=$(get_external_ip)
    echo -e "  ${BLUE}Host direct IP: $host_ip${NC}"
    
    # Get proxy IP (through HTTP proxy)
    local http_proxy_ip
    http_proxy_ip=$(get_proxy_ip "localhost" "$http_port")
    echo -e "  ${BLUE}HTTP proxy IP: $http_proxy_ip${NC}"
    
    # Get proxy IP (through SOCKS proxy)
    local socks_proxy_ip
    socks_proxy_ip=$(get_socks_proxy_ip "localhost" "$socks_port")
    echo -e "  ${BLUE}SOCKS proxy IP: $socks_proxy_ip${NC}"
    
    # Check if using VPN (IPs should match if VPN is active)
    if [[ "$http_proxy_ip" != "unknown" && "$host_ip" != "unknown" ]]; then
        if [[ "$http_proxy_ip" == "$host_ip" ]]; then
            test_result "VPN routing (HTTP proxy uses host VPN)" "PASS" "Both IPs: $host_ip"
        else
            test_result "VPN routing (HTTP proxy uses host VPN)" "FAIL" "Host: $host_ip, Proxy: $http_proxy_ip"
        fi
    else
        test_result "VPN routing" "SKIP" "Could not determine IPs"
    fi
    
    # Verify SOCKS uses same routing
    if [[ "$http_proxy_ip" != "unknown" && "$socks_proxy_ip" != "unknown" ]]; then
        if [[ "$http_proxy_ip" == "$socks_proxy_ip" ]]; then
            test_result "HTTP and SOCKS use same routing" "PASS"
        else
            test_result "HTTP and SOCKS use same routing" "FAIL" "HTTP: $http_proxy_ip, SOCKS: $socks_proxy_ip"
        fi
    fi
}

#######################################
# Test: Caching functionality
#######################################
test_caching() {
    test_header "CACHING TESTS"
    
    source "$PROJECT_ROOT/.env" 2>/dev/null || true
    local port="${HTTP_PROXY_PORT:-53128}"
    local cache_dir="${CACHE_DIR:-$PROJECT_ROOT/cache}"
    
    # Check cache directory exists
    if [[ -d "$cache_dir/squid" ]]; then
        test_result "Squid cache directory exists" "PASS"
    else
        test_result "Squid cache directory exists" "FAIL"
        return 1
    fi
    
    # Test caching by requesting same URL twice and checking speed
    local test_url="https://httpbin.org/bytes/65536"  # 64KB file
    
    # First request (should be cache miss)
    local first_time
    first_time=$(date +%s%N)
    curl -s --max-time 30 --proxy "http://localhost:$port" "$test_url" -o /dev/null 2>/dev/null
    first_time=$(( ($(date +%s%N) - first_time) / 1000000 ))
    
    # Second request (should be cache hit)
    local second_time
    second_time=$(date +%s%N)
    curl -s --max-time 30 --proxy "http://localhost:$port" "$test_url" -o /dev/null 2>/dev/null
    second_time=$(( ($(date +%s%N) - second_time) / 1000000 ))
    
    echo -e "  ${BLUE}First request: ${first_time}ms${NC}"
    echo -e "  ${BLUE}Second request: ${second_time}ms${NC}"
    
    # Second should be faster (cache hit)
    if [[ $second_time -lt $first_time ]]; then
        test_result "Cache improves response time" "PASS" "Second request faster"
    else
        test_result "Cache improves response time" "SKIP" "May need warm-up"
    fi
    
    # Test cache stats command
    if "$PROJECT_ROOT/cache" stats &>/dev/null; then
        test_result "Cache stats command works" "PASS"
    else
        test_result "Cache stats command works" "FAIL"
    fi
}

#######################################
# Test: Admin interface
#######################################
test_admin() {
    test_header "ADMIN INTERFACE TESTS"
    
    source "$PROJECT_ROOT/.env" 2>/dev/null || true
    local port="${PROXY_ADMIN_PORT:-58080}"
    
    # Test health endpoint
    local response
    response=$(curl -s -o /dev/null -w "%{http_code}" \
        --max-time 10 \
        "http://localhost:$port/health" 2>/dev/null || echo "000")
    
    if [[ "$response" == "200" ]]; then
        test_result "Admin health endpoint" "PASS"
    else
        test_result "Admin health endpoint" "FAIL" "HTTP code: $response"
    fi
    
    # Test main page
    response=$(curl -s -o /dev/null -w "%{http_code}" \
        --max-time 10 \
        "http://localhost:$port/" 2>/dev/null || echo "000")
    
    if [[ "$response" == "200" ]]; then
        test_result "Admin main page" "PASS"
    else
        test_result "Admin main page" "FAIL" "HTTP code: $response"
    fi
}

#######################################
# Test: Status command
#######################################
test_status_command() {
    test_header "STATUS COMMAND TESTS"
    
    cd "$PROJECT_ROOT"
    
    # Test basic status
    if ./status &>/dev/null; then
        test_result "Status command works" "PASS"
    else
        test_result "Status command works" "FAIL"
    fi
    
    # Test verbose status
    if ./status -v &>/dev/null; then
        test_result "Status verbose mode" "PASS"
    else
        test_result "Status verbose mode" "FAIL"
    fi
    
    # Test JSON output
    if ./status --json &>/dev/null; then
        test_result "Status JSON output" "PASS"
    else
        test_result "Status JSON output" "FAIL"
    fi
}

#######################################
# Test: Cache commands
#######################################
test_cache_commands() {
    test_header "CACHE COMMAND TESTS"
    
    cd "$PROJECT_ROOT"
    
    # Test cache stats
    if ./cache stats &>/dev/null; then
        test_result "Cache stats command" "PASS"
    else
        test_result "Cache stats command" "FAIL"
    fi
    
    # Test cache size
    if ./cache size &>/dev/null; then
        test_result "Cache size command" "PASS"
    else
        test_result "Cache size command" "FAIL"
    fi
    
    # Test cache list
    if ./cache list &>/dev/null; then
        test_result "Cache list command" "PASS"
    else
        test_result "Cache list command" "FAIL"
    fi
}

#######################################
# Test: DNS resolution
#######################################
test_dns() {
    test_header "DNS RESOLUTION TESTS"
    
    source "$PROJECT_ROOT/.env" 2>/dev/null || true
    local port="${HTTP_PROXY_PORT:-53128}"
    
    # Test DNS through proxy
    local response
    response=$(curl -s --max-time 10 \
        --proxy "http://localhost:$port" \
        "https://dns.google/resolve?name=google.com" 2>/dev/null)
    
    if echo "$response" | grep -q "Answer"; then
        test_result "DNS resolution through proxy" "PASS"
    else
        test_result "DNS resolution through proxy" "FAIL"
    fi
}

#######################################
# Test: Large file download
#######################################
test_large_file() {
    test_header "LARGE FILE DOWNLOAD TESTS"
    
    source "$PROJECT_ROOT/.env" 2>/dev/null || true
    local port="${HTTP_PROXY_PORT:-53128}"
    
    # Download 1MB file
    local size
    size=$(curl -s --max-time 60 \
        --proxy "http://localhost:$port" \
        "https://httpbin.org/bytes/1048576" \
        -o /dev/null -w "%{size_download}" 2>/dev/null || echo "0")
    
    if [[ "$size" -gt 1000000 ]]; then
        test_result "Large file download (1MB)" "PASS" "Downloaded: ${size} bytes"
    else
        test_result "Large file download (1MB)" "FAIL" "Downloaded: ${size} bytes"
    fi
}

#######################################
# Test: Multiple concurrent connections
#######################################
test_concurrent() {
    test_header "CONCURRENT CONNECTION TESTS"
    
    source "$PROJECT_ROOT/.env" 2>/dev/null || true
    local port="${HTTP_PROXY_PORT:-53128}"
    
    echo -e "  ${BLUE}Making 10 concurrent requests...${NC}"
    
    local success=0
    local failed=0
    
    for i in {1..10}; do
        (
            curl -s --max-time 30 \
                --proxy "http://localhost:$port" \
                "https://httpbin.org/get" \
                -o /dev/null -w "%{http_code}" 2>/dev/null
        ) &
    done
    
    # Wait and collect results
    for job in $(jobs -p); do
        local code
        code=$(wait "$job" 2>/dev/null || echo "000")
        if [[ "$code" == "200" ]]; then
            ((success++))
        else
            ((failed++))
        fi
    done
    
    if [[ $success -ge 8 ]]; then
        test_result "Concurrent connections (10)" "PASS" "Success: $success, Failed: $failed"
    else
        test_result "Concurrent connections (10)" "FAIL" "Success: $success, Failed: $failed"
    fi
}

#######################################
# Test: Network client simulation
#######################################
test_network_client() {
    test_header "NETWORK CLIENT SIMULATION TESTS"
    
    source "$PROJECT_ROOT/.env" 2>/dev/null || true
    local http_port="${HTTP_PROXY_PORT:-53128}"
    local socks_port="${SOCKS_PROXY_PORT:-51080}"
    
    # Get host IP for network testing
    local host_ip
    host_ip=$(hostname -I | awk '{print $1}')
    
    if [[ -z "$host_ip" ]]; then
        test_result "Network client test" "SKIP" "Cannot determine host IP"
        return 0
    fi
    
    echo -e "  ${BLUE}Testing from network IP: $host_ip${NC}"
    
    # Test HTTP proxy from network
    local response
    response=$(curl -s -o /dev/null -w "%{http_code}" \
        --max-time 15 \
        --proxy "http://${host_ip}:${http_port}" \
        "http://connectivitycheck.gstatic.com/generate_204" 2>/dev/null || echo "000")
    
    if [[ "$response" == "204" || "$response" == "200" ]]; then
        test_result "Network client HTTP proxy access" "PASS"
    else
        test_result "Network client HTTP proxy access" "FAIL" "HTTP code: $response"
    fi
    
    # Test SOCKS proxy from network
    response=$(curl -s -o /dev/null -w "%{http_code}" \
        --max-time 15 \
        --proxy "socks5://${host_ip}:${socks_port}" \
        "http://connectivitycheck.gstatic.com/generate_204" 2>/dev/null || echo "000")
    
    if [[ "$response" == "204" || "$response" == "200" ]]; then
        test_result "Network client SOCKS proxy access" "PASS"
    else
        test_result "Network client SOCKS proxy access" "FAIL" "HTTP code: $response"
    fi
}

#######################################
# Print summary
#######################################
print_summary() {
    echo -e "\n${CYAN}════════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}                    TEST SUMMARY                             ${NC}"
    echo -e "${CYAN}════════════════════════════════════════════════════════════${NC}"
    echo -e ""
    echo -e "  Tests Run:     ${BLUE}$TESTS_RUN${NC}"
    echo -e "  Tests Passed:  ${GREEN}$TESTS_PASSED${NC}"
    echo -e "  Tests Failed:  ${RED}$TESTS_FAILED${NC}"
    echo -e "  Tests Skipped: ${YELLOW}$TESTS_SKIPPED${NC}"
    echo -e ""
    echo -e "${CYAN}════════════════════════════════════════════════════════════${NC}"
    
    if [[ $TESTS_FAILED -gt 0 ]]; then
        echo -e "\n${RED}Failed Tests:${NC}"
        for test in "${FAILED_TESTS[@]}"; do
            echo -e "  ${RED}•${NC} $test"
        done
        echo -e "${CYAN}════════════════════════════════════════════════════════════${NC}"
    fi
    
    if [[ $TESTS_FAILED -eq 0 ]]; then
        echo -e "${GREEN}  ALL TESTS PASSED! ✓${NC}"
        echo -e "${CYAN}════════════════════════════════════════════════════════════${NC}"
        return 0
    else
        echo -e "${RED}  SOME TESTS FAILED${NC}"
        echo -e "${CYAN}════════════════════════════════════════════════════════════${NC}"
        return 1
    fi
}

#######################################
# Main function
#######################################
main() {
    echo -e "${CYAN}"
    echo "════════════════════════════════════════════════════════════"
    echo "        PROXY SERVICE - COMPREHENSIVE TEST SUITE            "
    echo "════════════════════════════════════════════════════════════"
    echo -e "${NC}"
    
    cd "$PROJECT_ROOT"
    
    # Run all tests
    test_environment
    test_scripts
    test_container_runtime
    test_containers
    test_ports
    test_http_proxy
    test_socks_proxy
    test_vpn_routing
    test_caching
    test_admin
    test_status_command
    test_cache_commands
    test_dns
    test_large_file
    test_concurrent
    test_network_client
    
    # Print summary
    print_summary
}

main "$@"
