#!/usr/bin/env bash
#######################################
# Proxy Service Test Suite
# Comprehensive tests for all components
#######################################

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Test counters
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

#######################################
# Print test result
#######################################
test_result() {
    local name="$1"
    local result="$2"
    local message="${3:-}"
    
    # NOTE: use assignment form, NOT (( VAR++ )). Under `set -e` a
    # post-increment whose prior value is 0 returns exit status 1 and
    # aborts the whole suite at the very first test (Helix Constitution
    # §11.4.1 — script-internal failures fixed at source). See
    # docs/issues/fixed/BUGFIXES.md.
    TESTS_RUN=$((TESTS_RUN + 1))

    if [[ "$result" == "PASS" ]]; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        echo -e "${GREEN}✓ PASS${NC}: $name"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        echo -e "${RED}✗ FAIL${NC}: $name"
        [[ -n "$message" ]] && echo -e "  ${YELLOW}→ $message${NC}"
    fi
}

#######################################
# Test: Environment configuration
#######################################
test_environment() {
    echo -e "\n${BLUE}=== Environment Tests ===${NC}"
    
    # Test .env exists
    if [[ -f "$PROJECT_ROOT/.env" ]]; then
        test_result ".env file exists" "PASS"
    else
        test_result ".env file exists" "FAIL" "Run 'cp .env.example .env'"
    fi
    
    # Test .env.example exists
    if [[ -f "$PROJECT_ROOT/.env.example" ]]; then
        test_result ".env.example exists" "PASS"
    else
        test_result ".env.example exists" "FAIL"
    fi
    
    # Test required variables
    source "$PROJECT_ROOT/.env" 2>/dev/null || true
    
    if [[ -n "${HTTP_PROXY_PORT:-}" ]]; then
        test_result "HTTP_PROXY_PORT set" "PASS"
    else
        test_result "HTTP_PROXY_PORT set" "FAIL" "Using default"
    fi
}

#######################################
# Test: Directory structure
#######################################
test_directories() {
    echo -e "\n${BLUE}=== Directory Tests ===${NC}"
    
    local dirs=(
        "config"
        "config/squid"
        "config/dante"
        "config/caddy"
        "scripts"
        "services"
        "services/admin"
        "lib"
        "tests"
        "docs"
        "Upstreams"
    )
    
    for dir in "${dirs[@]}"; do
        if [[ -d "$PROJECT_ROOT/$dir" ]]; then
            test_result "Directory $dir" "PASS"
        else
            test_result "Directory $dir" "FAIL"
        fi
    done
}

#######################################
# Test: Scripts executable
#######################################
test_scripts() {
    echo -e "\n${BLUE}=== Script Tests ===${NC}"
    
    local scripts=(
        "init"
        "start"
        "stop"
        "status"
        "cache"
        "restart"
        "lib/container-runtime.sh"
    )
    
    for script in "${scripts[@]}"; do
        if [[ -x "$PROJECT_ROOT/$script" ]]; then
            test_result "Script $script executable" "PASS"
        else
            test_result "Script $script executable" "FAIL" "Run 'chmod +x $script'"
        fi
    done
}

#######################################
# Test: Configuration files
#######################################
test_config_files() {
    echo -e "\n${BLUE}=== Configuration File Tests ===${NC}"
    
    local configs=(
        "config/squid/squid.conf"
        "config/dante/sockd.conf"
        "config/caddy/Caddyfile"
        "docker-compose.yml"
    )
    
    for config in "${configs[@]}"; do
        if [[ -f "$PROJECT_ROOT/$config" ]]; then
            test_result "Config $config exists" "PASS"
        else
            test_result "Config $config exists" "FAIL" "Run './init'"
        fi
    done
}

#######################################
# Test: Docker compose syntax
#######################################
test_docker_compose() {
    echo -e "\n${BLUE}=== Docker Compose Tests ===${NC}"
    
    cd "$PROJECT_ROOT"
    
    # Load environment
    source .env 2>/dev/null || true
    
    # Check compose file syntax
    if command -v docker &>/dev/null; then
        if docker compose config --quiet 2>/dev/null; then
            test_result "Docker compose syntax" "PASS"
        else
            test_result "Docker compose syntax" "FAIL"
        fi
    elif command -v podman-compose &>/dev/null; then
        if podman-compose config --quiet 2>/dev/null; then
            test_result "Podman compose syntax" "PASS"
        else
            test_result "Podman compose syntax" "FAIL"
        fi
    else
        test_result "Compose syntax check" "FAIL" "No compose command found"
    fi
}

#######################################
# Test: Container runtime
#######################################
test_container_runtime() {
    echo -e "\n${BLUE}=== Container Runtime Tests ===${NC}"
    
    # Check for Docker
    if command -v docker &>/dev/null; then
        test_result "Docker installed" "PASS"
        
        if docker info &>/dev/null; then
            test_result "Docker daemon running" "PASS"
        else
            test_result "Docker daemon running" "FAIL"
        fi
    else
        test_result "Docker installed" "FAIL"
    fi
    
    # Check for Podman
    if command -v podman &>/dev/null; then
        test_result "Podman installed" "PASS"
        
        if podman info &>/dev/null; then
            test_result "Podman working" "PASS"
        else
            test_result "Podman working" "FAIL"
        fi
    else
        test_result "Podman installed" "FAIL" "Optional"
    fi
}

#######################################
# Test: Network ports
#######################################
test_ports() {
    echo -e "\n${BLUE}=== Port Tests ===${NC}"
    
    source "$PROJECT_ROOT/.env" 2>/dev/null || true
    
    local http_port="${HTTP_PROXY_PORT:-53128}"
    local socks_port="${SOCKS_PROXY_PORT:-51080}"
    local admin_port="${PROXY_ADMIN_PORT:-58080}"
    
    # Check if ports are available
    for port in "$http_port" "$socks_port" "$admin_port"; do
        if ss -tuln | grep -q ":${port} "; then
            test_result "Port $port available" "FAIL" "Port in use"
        else
            test_result "Port $port available" "PASS"
        fi
    done
}

#######################################
# Test: Cache directory
#######################################
test_cache() {
    echo -e "\n${BLUE}=== Cache Tests ===${NC}"
    
    source "$PROJECT_ROOT/.env" 2>/dev/null || true
    
    local cache_dir="${CACHE_DIR:-$PROJECT_ROOT/cache}"
    
    # Check cache directory
    if [[ -d "$cache_dir" ]]; then
        test_result "Cache directory exists" "PASS"
        
        # Check writable
        if [[ -w "$cache_dir" ]]; then
            test_result "Cache directory writable" "PASS"
        else
            test_result "Cache directory writable" "FAIL"
        fi
    else
        test_result "Cache directory exists" "FAIL" "Run './init'"
    fi
}

#######################################
# Test: VPN configuration (if enabled)
#######################################
test_vpn() {
    echo -e "\n${BLUE}=== VPN Tests ===${NC}"
    
    source "$PROJECT_ROOT/.env" 2>/dev/null || true
    
    if [[ "${USE_VPN:-false}" != "true" ]]; then
        test_result "VPN disabled" "PASS" "Skipped"
        return 0
    fi
    
    test_result "VPN enabled" "PASS"
    
    # Check VPN config file
    if [[ -n "${VPN_OVPN_PATH:-}" ]]; then
        if [[ -f "$VPN_OVPN_PATH" ]]; then
            test_result "VPN config file exists" "PASS"
        else
            test_result "VPN config file exists" "FAIL" "File not found: $VPN_OVPN_PATH"
        fi
    else
        test_result "VPN config path set" "FAIL" "VPN_OVPN_PATH not set"
    fi
    
    # Check VPN credentials
    if [[ -n "${VPN_USERNAME:-}" ]]; then
        test_result "VPN username set" "PASS"
    else
        test_result "VPN username set" "FAIL"
    fi
    
    if [[ -n "${VPN_PASSWORD:-}" ]]; then
        test_result "VPN password set" "PASS"
    else
        test_result "VPN password set" "FAIL"
    fi
}

#######################################
# Test: Service startup (optional)
#######################################
test_service_startup() {
    echo -e "\n${BLUE}=== Service Startup Tests ===${NC}"
    
    if [[ "${RUN_STARTUP_TESTS:-false}" != "true" ]]; then
        test_result "Startup tests" "PASS" "Skipped (set RUN_STARTUP_TESTS=true)"
        return 0
    fi
    
    cd "$PROJECT_ROOT"
    
    # Test init
    if ./init --check 2>/dev/null; then
        test_result "Init check" "PASS"
    else
        test_result "Init check" "FAIL"
        return 1
    fi
    
    # Test start (dry run)
    if ./start --dry-run 2>/dev/null; then
        test_result "Start dry-run" "PASS"
    else
        test_result "Start dry-run" "FAIL"
    fi
}

#######################################
# Test: Constitution inheritance pre-flight gate (Helix Constitution
# §11.4.35). Runs FIRST. No CI/CD, no git hooks (CLAUDE.md Hard Stop
# #1) — the gate is enforced here as a script target. Its paired §1.1
# mutation lives at challenges/scripts/meta_test_constitution_inheritance.sh.
#######################################
test_constitution_inheritance() {
    echo -e "\n${BLUE}=== Constitution Inheritance (pre-flight gate) ===${NC}"
    if bash "$SCRIPT_DIR/constitution_inheritance_gate.sh" >/dev/null 2>&1; then
        test_result "Constitution inheritance gate (§11.4.35)" "PASS"
    else
        test_result "Constitution inheritance gate (§11.4.35)" "FAIL" \
            "run: bash tests/constitution_inheritance_gate.sh"
    fi
}

#######################################
# Test: standing regression guards (Helix Constitution §11.4.135). Each
# guards a closed defect with a §11.4.115 RED_MODE polarity test. New
# guards register here so they run on every suite execution.
#   - BUGFIX-0002: rootless-Podman squid log-dir writability
#     (docs/issues/fixed/BUGFIXES.md). RED reproduces, GREEN proves the fix.
#######################################
test_regression_guards() {
    echo -e "\n${BLUE}=== Regression guards (§11.4.135) ===${NC}"

    # BUGFIX-0002 — GREEN guard: the real orchestrator must make LOG_DIR writable.
    if bash "$SCRIPT_DIR/regression/log_dir_writable_test.sh" >/dev/null 2>&1; then
        test_result "BUGFIX-0002 squid log-dir writable (GREEN)" "PASS"
    else
        test_result "BUGFIX-0002 squid log-dir writable (GREEN)" "FAIL" \
            "run: bash tests/regression/log_dir_writable_test.sh"
    fi

    # BUGFIX-0002 — RED self-check: the guard must genuinely reproduce the defect
    # on the pre-fix replica (a guard that cannot reproduce is a §11.4.7 finding).
    if RED_MODE=1 bash "$SCRIPT_DIR/regression/log_dir_writable_test.sh" >/dev/null 2>&1; then
        test_result "BUGFIX-0002 squid log-dir RED reproduces" "PASS"
    else
        test_result "BUGFIX-0002 squid log-dir RED reproduces" "FAIL" \
            "RED could not reproduce the defect — §11.4.7"
    fi
}

#######################################
# Print summary
#######################################
print_summary() {
    echo -e "\n${BLUE}================================${NC}"
    echo -e "${BLUE}         TEST SUMMARY           ${NC}"
    echo -e "${BLUE}================================${NC}"
    echo -e "Tests Run:    $TESTS_RUN"
    echo -e "Tests Passed: ${GREEN}$TESTS_PASSED${NC}"
    echo -e "Tests Failed: ${RED}$TESTS_FAILED${NC}"
    echo -e "${BLUE}================================${NC}"
    
    if [[ $TESTS_FAILED -eq 0 ]]; then
        echo -e "${GREEN}All tests passed!${NC}"
        return 0
    else
        echo -e "${RED}Some tests failed.${NC}"
        return 1
    fi
}

#######################################
# Main function
#######################################
main() {
    echo -e "${BLUE}"
    echo "================================"
    echo "   Proxy Service Test Suite     "
    echo "================================"
    echo -e "${NC}"
    
    cd "$PROJECT_ROOT"

    test_constitution_inheritance
    test_regression_guards
    test_environment
    test_directories
    test_scripts
    test_config_files
    test_docker_compose
    test_container_runtime
    test_ports
    test_cache
    test_vpn
    test_service_startup
    
    print_summary
}

main "$@"
