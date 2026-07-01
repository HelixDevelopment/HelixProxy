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
# §11.4.3 — a third state: SKIP (topology-appropriate "not applicable here").
# A skipped path is NEITHER a pass NOR a fail; counting it as PASS is a §11.4.3
# PASS-by-default bluff (see docs/research/existing_test_bluffs_audit B7).
TESTS_SKIPPED=0

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
    elif [[ "$result" == "SKIP" ]]; then
        # §11.4.3 SKIP-with-reason — topology-appropriate "not applicable here".
        # Does NOT count as pass or fail; never gates the suite exit status.
        TESTS_SKIPPED=$((TESTS_SKIPPED + 1))
        echo -e "${YELLOW}⊘ SKIP${NC}: $name"
        [[ -n "$message" ]] && echo -e "  ${YELLOW}→ $message${NC}"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        echo -e "${RED}✗ FAIL${NC}: $name"
        [[ -n "$message" ]] && echo -e "  ${YELLOW}→ $message${NC}"
    fi

    # BUGFIX-0003 (§11.4.1, sibling of BUGFIX-0001): test_result is a REPORTING
    # helper — its exit status must never gate control flow. Without this, a
    # FAIL with no message ends on the `[[ -n "$message" ]] &&` short-circuit,
    # which returns 1; when that test_result is the LAST command of a test
    # function (e.g. the final dir in test_directories' loop), the function
    # returns 1 and `set -e` aborts the whole suite mid-run — most tests never
    # execute and no summary prints. Always return 0. Guard:
    # tests/regression/test_result_returns_zero_test.sh.
    return 0
}

#######################################
# Test: Environment configuration
#######################################
test_environment() {
    echo -e "\n${BLUE}=== Environment Tests ===${NC}"
    
    # .env is gitignored (§11.4.10 / §11.4.30); its ABSENCE is the expected
    # fresh-checkout topology, not a defect. When absent → §11.4.3 SKIP and
    # validate the tracked .env.example template instead. When present →
    # validate it as before.
    if [[ -f "$PROJECT_ROOT/.env" ]]; then
        test_result ".env file exists" "PASS"
    else
        test_result ".env present (config topology)" "SKIP" \
            ".env is gitignored (§11.4.10/§11.4.30) — absent in a fresh checkout; validating .env.example template instead"
    fi

    # Test .env.example exists (the tracked template that regenerates .env)
    if [[ -f "$PROJECT_ROOT/.env.example" ]]; then
        test_result ".env.example template exists" "PASS"
    else
        test_result ".env.example template exists" "FAIL"
    fi

    # Test required variables — only assertable when a .env was actually sourced.
    source "$PROJECT_ROOT/.env" 2>/dev/null || true

    if [[ -f "$PROJECT_ROOT/.env" ]]; then
        if [[ -n "${HTTP_PROXY_PORT:-}" ]]; then
            test_result "HTTP_PROXY_PORT set" "PASS"
        else
            test_result "HTTP_PROXY_PORT set" "FAIL" ".env present but HTTP_PROXY_PORT unset"
        fi
    else
        test_result "HTTP_PROXY_PORT set" "SKIP" \
            "no .env sourced in this topology (§11.4.3) — value defaults at runtime"
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
    )

    for dir in "${dirs[@]}"; do
        if [[ -d "$PROJECT_ROOT/$dir" ]]; then
            test_result "Directory $dir" "PASS"
        else
            test_result "Directory $dir" "FAIL"
        fi
    done

    # install_upstreams topology (§11.4.36). §11.4.29 mandates lowercase
    # snake_case and "lowercase wins" during the Upstreams/->upstreams/
    # migration, so accept EITHER form. Present → PASS (topology available);
    # absent → §11.4.3 SKIP (install_upstreams recipes not present in this
    # checkout), never a hard FAIL.
    if [[ -d "$PROJECT_ROOT/upstreams" || -d "$PROJECT_ROOT/Upstreams" ]]; then
        test_result "Directory upstreams (install_upstreams topology)" "PASS"
    else
        test_result "Directory upstreams (install_upstreams topology)" "SKIP" \
            "no upstreams/ — install_upstreams topology not present (§11.4.36)"
    fi
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
        "cachectl"
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

    # §11.4.161 — rootless Podman is the MANDATED runtime; Docker (rootful)
    # is a FORBIDDEN workflow. The pre-fix check asserted "Docker installed"
    # and FAILed on its absence — exactly backwards. Assert the mandated
    # runtime; note Docker only as an optional, non-mandated presence and
    # NEVER FAIL when it is absent (absence is the expected, compliant state).
    if command -v podman &>/dev/null; then
        test_result "Podman installed (mandated runtime §11.4.161)" "PASS"

        if podman info &>/dev/null; then
            test_result "Podman working" "PASS"
        else
            test_result "Podman working" "FAIL"
        fi
    else
        test_result "Podman installed (mandated runtime §11.4.161)" "FAIL" \
            "rootless Podman is required (§11.4.161)"
    fi

    # Docker: optional, and a forbidden workflow — informational only.
    if command -v docker &>/dev/null; then
        test_result "Docker present (optional, not the mandated runtime)" "PASS" \
            "note: Docker (rootful) workflows are forbidden (§11.4.161)"
    else
        test_result "Docker absent (expected — §11.4.161 mandates Podman)" "SKIP" \
            "Docker is not the mandated runtime; its absence is the compliant state"
    fi
}

#######################################
# §11.4.3 topology-aware port classification (PURE — no I/O).
#
# Pre-fix BLUFF: test_ports reported any port that was IN USE as FAIL —
# so the running, healthy proxy's own listening ports (squid 53128,
# dante 51080) were reported as FAILURES. A port in use BY ITS OWN
# RUNNING SERVICE is the HEALTHY state, not a failure (§11.4.1 false-FAIL).
#
# port_verdict resolves the truth-table from two topology booleans:
#   owner_serving — the project proxy container that owns this port is
#                   running AND publishing this host port.
#   listening     — something is listening on the port (real ss probe).
#
#   owner_serving=yes, listening=yes -> PASS  (service up and serving)
#   owner_serving=yes, listening=no  -> FAIL  (owner up but not serving!)
#   owner_serving=no,  listening=no  -> PASS  (pre-start: free, ready to start)
#   owner_serving=no,  listening=yes -> SKIP  (pre-start, but a NON-project
#                                              process holds the port —
#                                              readiness not assertable; not
#                                              attributable to the proxy)
#
# Guarded by tests/regression/port_topology_aware_test.sh (§11.4.135 +
# §11.4.115 RED_MODE polarity).
#######################################
port_verdict() {
    local owner_serving="$1" listening="$2"
    if [ "$owner_serving" = "yes" ]; then
        if [ "$listening" = "yes" ]; then echo "PASS"; else echo "FAIL"; fi
    else
        if [ "$listening" = "yes" ]; then echo "SKIP"; else echo "PASS"; fi
    fi
}

#######################################
# Test: Network ports (§11.4.3 topology-aware)
#######################################
test_ports() {
    echo -e "\n${BLUE}=== Port Tests ===${NC}"

    source "$PROJECT_ROOT/.env" 2>/dev/null || true

    local http_port="${HTTP_PROXY_PORT:-53128}"
    local socks_port="${SOCKS_PROXY_PORT:-51080}"
    local admin_port="${PROXY_ADMIN_PORT:-58080}"

    _ports_check_one "$http_port"  "proxy-squid" "HTTP proxy (squid)"
    _ports_check_one "$socks_port" "proxy-dante" "SOCKS proxy (dante)"
    _ports_check_one "$admin_port" "proxy-admin" "control API (admin)"
}

#######################################
# Classify one port against its owning project proxy container.
# Real evidence only (§11.4.6 — no guessing): podman ps for run state,
# `podman port` for the published host mapping, `ss -tuln` for the live
# listener. No probe touches the data plane.
#######################################
_ports_check_one() {
    local port="$1" owner="$2" label="$3"
    local owner_serving="no" listening="no" verdict

    # owner_serving := the named project container is running AND publishes
    # this host port (so the port being in use is the HEALTHY serving state).
    if command -v podman >/dev/null 2>&1 \
        && podman ps --format '{{.Names}}' 2>/dev/null | grep -qx "$owner" \
        && podman port "$owner" 2>/dev/null | grep -q ":${port}$"; then
        owner_serving="yes"
    fi

    if ss -tuln 2>/dev/null | grep -q ":${port} "; then
        listening="yes"
    fi

    verdict="$(port_verdict "$owner_serving" "$listening")"

    case "$verdict" in
        PASS)
            if [[ "$owner_serving" == "yes" ]]; then
                test_result "Port $port $label serving" "PASS" \
                    "$owner up and serving on $port"
            else
                test_result "Port $port $label free (pre-start)" "PASS" \
                    "free, ready for ./start to bind"
            fi
            ;;
        FAIL)
            test_result "Port $port $label serving" "FAIL" \
                "$owner up and publishing $port but nothing is listening"
            ;;
        SKIP)
            test_result "Port $port $label (pre-start)" "SKIP" \
                "$port held by a non-project process — readiness not assertable (§11.4.3)"
            ;;
    esac
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
        # B7 (§11.4.3): a skipped path is SKIP, never PASS — recording it as
        # PASS inflates TESTS_PASSED (PASS-by-default bluff).
        test_result "VPN configuration" "SKIP" "VPN not enabled (USE_VPN!=true) — §11.4.3 topology"
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
        # B7 (§11.4.3): SKIP-with-reason, not a PASS-by-default.
        test_result "Startup tests" "SKIP" "RUN_STARTUP_TESTS!=true — §11.4.3 topology (set RUN_STARTUP_TESTS=true to enable)"
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

    # BUGFIX-0003 — GREEN guard: test_result must return 0 (no set -e suite abort).
    if bash "$SCRIPT_DIR/regression/test_result_returns_zero_test.sh" >/dev/null 2>&1; then
        test_result "BUGFIX-0003 test_result returns 0 (GREEN)" "PASS"
    else
        test_result "BUGFIX-0003 test_result returns 0 (GREEN)" "FAIL" \
            "run: bash tests/regression/test_result_returns_zero_test.sh"
    fi

    # BUGFIX-0003 — RED self-check: pre-fix replica must abort under set -e.
    if RED_MODE=1 bash "$SCRIPT_DIR/regression/test_result_returns_zero_test.sh" >/dev/null 2>&1; then
        test_result "BUGFIX-0003 test_result RED reproduces" "PASS"
    else
        test_result "BUGFIX-0003 test_result RED reproduces" "FAIL" \
            "RED could not reproduce the defect — §11.4.7"
    fi

    # BUGFIX-PORTS — GREEN guard: §11.4.3 topology-aware port_verdict must treat
    # a healthy serving port (owner up + listening) as PASS, NOT FAIL.
    if bash "$SCRIPT_DIR/regression/port_topology_aware_test.sh" >/dev/null 2>&1; then
        test_result "BUGFIX-PORTS topology-aware port check (GREEN)" "PASS"
    else
        test_result "BUGFIX-PORTS topology-aware port check (GREEN)" "FAIL" \
            "run: bash tests/regression/port_topology_aware_test.sh"
    fi

    # BUGFIX-PORTS — RED self-check: the pre-fix replica must reproduce the bluff
    # (classify a healthy serving port as FAIL). A RED that cannot reproduce is a
    # §11.4.7 finding.
    if RED_MODE=1 bash "$SCRIPT_DIR/regression/port_topology_aware_test.sh" >/dev/null 2>&1; then
        test_result "BUGFIX-PORTS topology-aware RED reproduces" "PASS"
    else
        test_result "BUGFIX-PORTS topology-aware RED reproduces" "FAIL" \
            "RED could not reproduce the defect — §11.4.7"
    fi

    # BUGFIX-CACHECLI (regression #50) — GREEN guard: the documented cache CLI
    # (restored as ./cachectl after the 6ec58ef accidental deletion) must be
    # present, executable, parseable, and dispatch every documented subcommand.
    if bash "$SCRIPT_DIR/regression/cache_cli_present_test.sh" >/dev/null 2>&1; then
        test_result "BUGFIX-CACHECLI cache CLI present + complete (GREEN)" "PASS"
    else
        test_result "BUGFIX-CACHECLI cache CLI present + complete (GREEN)" "FAIL" \
            "run: bash tests/regression/cache_cli_present_test.sh"
    fi

    # BUGFIX-CACHECLI — RED self-check: the post-deletion state (CLI absent ->
    # documented feature unusable) must reproduce. A RED that cannot reproduce
    # is a §11.4.7 finding.
    if RED_MODE=1 bash "$SCRIPT_DIR/regression/cache_cli_present_test.sh" >/dev/null 2>&1; then
        test_result "BUGFIX-CACHECLI cache CLI absent RED reproduces" "PASS"
    else
        test_result "BUGFIX-CACHECLI cache CLI absent RED reproduces" "FAIL" \
            "RED could not reproduce the defect — §11.4.7"
    fi

    # BUGFIX-ADMIN-TOPOLOGY (P12 retest finding 2) — GREEN guard: comprehensive-
    # test.sh's _port_topology_check must SKIP a port held by a NON-project process
    # (never fail-open PASS on a foreign responder — §11.4.68/§11.4.69) AND PASS an
    # owner-published+listening port.
    if bash "$SCRIPT_DIR/regression/comprehensive_admin_topology_test.sh" >/dev/null 2>&1; then
        test_result "BUGFIX-ADMIN-TOPOLOGY fail-open refused (GREEN)" "PASS"
    else
        test_result "BUGFIX-ADMIN-TOPOLOGY fail-open refused (GREEN)" "FAIL" \
            "run: bash tests/regression/comprehensive_admin_topology_test.sh"
    fi

    # BUGFIX-ADMIN-TOPOLOGY — RED self-check: the pre-fix replica (listening=>PASS)
    # must reproduce the fail-open bluff on a foreign-held port. A RED that cannot
    # reproduce is a §11.4.7 finding.
    if RED_MODE=1 bash "$SCRIPT_DIR/regression/comprehensive_admin_topology_test.sh" >/dev/null 2>&1; then
        test_result "BUGFIX-ADMIN-TOPOLOGY fail-open RED reproduces" "PASS"
    else
        test_result "BUGFIX-ADMIN-TOPOLOGY fail-open RED reproduces" "FAIL" \
            "RED could not reproduce the defect — §11.4.7"
    fi

    # BUGFIX-0011 (P12 final-retest finding) — GREEN guard: the CONST-033 scanner
    # must exclude a documentation ledger's §11.4.65 EXPORT SIBLINGS (.html/.pdf),
    # not just its .md, while STILL catching a real invocation (§11.4.68/§11.4.1).
    if bash "$SCRIPT_DIR/regression/no_suspend_export_sibling_test.sh" >/dev/null 2>&1; then
        test_result "BUGFIX-0011 no-suspend export-sibling excluded (GREEN)" "PASS"
    else
        test_result "BUGFIX-0011 no-suspend export-sibling excluded (GREEN)" "FAIL" \
            "run: bash tests/regression/no_suspend_export_sibling_test.sh"
    fi

    # BUGFIX-0011 — RED self-check: the pre-fix ".md"-only replica must trip on the
    # ledger .html sibling (sibling-blind false-FAIL). RED that cannot reproduce is
    # a §11.4.7 finding.
    if RED_MODE=1 bash "$SCRIPT_DIR/regression/no_suspend_export_sibling_test.sh" >/dev/null 2>&1; then
        test_result "BUGFIX-0011 no-suspend export-sibling RED reproduces" "PASS"
    else
        test_result "BUGFIX-0011 no-suspend export-sibling RED reproduces" "FAIL" \
            "RED could not reproduce the defect — §11.4.7"
    fi

    # BUGFIX-0012 (P12 final-retest finding) — GREEN guard: comprehensive-test.sh's
    # _external_egress_verdict must SKIP a third-party outage (proxy+direct both fail)
    # instead of a §11.4.1 false-FAIL, while still FAILing a real proxy defect
    # (proxy fails but direct 200 — §11.4.68 not fail-open).
    if bash "$SCRIPT_DIR/regression/external_egress_verdict_test.sh" >/dev/null 2>&1; then
        test_result "BUGFIX-0012 external-egress outage SKIP not FAIL (GREEN)" "PASS"
    else
        test_result "BUGFIX-0012 external-egress outage SKIP not FAIL (GREEN)" "FAIL" \
            "run: bash tests/regression/external_egress_verdict_test.sh"
    fi

    # BUGFIX-0012 — RED self-check: the pre-fix (proxy!=200 => FAIL) replica must
    # FAIL an external outage. RED that cannot reproduce is a §11.4.7 finding.
    if RED_MODE=1 bash "$SCRIPT_DIR/regression/external_egress_verdict_test.sh" >/dev/null 2>&1; then
        test_result "BUGFIX-0012 external-egress false-FAIL RED reproduces" "PASS"
    else
        test_result "BUGFIX-0012 external-egress false-FAIL RED reproduces" "FAIL" \
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
    echo -e "Tests Run:     $TESTS_RUN"
    echo -e "Tests Passed:  ${GREEN}$TESTS_PASSED${NC}"
    echo -e "Tests Skipped: ${YELLOW}$TESTS_SKIPPED${NC}"
    echo -e "Tests Failed:  ${RED}$TESTS_FAILED${NC}"
    echo -e "${BLUE}================================${NC}"

    # §11.4.3 — skips count as neither pass nor fail; only real FAILs gate the
    # suite. A healthy running proxy whose ports are correctly LISTENING must
    # NOT make the suite exit non-zero (that was the §11.4.1 false-FAIL).
    if [[ $TESTS_FAILED -eq 0 ]]; then
        echo -e "${GREEN}All tests passed (${TESTS_SKIPPED} skipped — neither pass nor fail).${NC}"
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
