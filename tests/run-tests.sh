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

    # BUGFIX-0014 (discovery-sweep F2/F3) — GREEN guard: evidence.sh
    # proxy_conn_verdict (the client-side connectivity classifier now used by
    # verify-proxy.sh + final-verify.sh) must SKIP a site OUTAGE (proxy+direct
    # both fail) instead of a §11.4.1 false-FAIL, while still FAILing a real
    # proxy defect (proxy miss but the site is reachable directly — §11.4.68
    # not fail-open) and SKIPping an absent port (topology).
    if bash "$SCRIPT_DIR/regression/proxy_conn_verdict_test.sh" >/dev/null 2>&1; then
        test_result "BUGFIX-0014 proxy-conn-verdict outage SKIP not FAIL (GREEN)" "PASS"
    else
        test_result "BUGFIX-0014 proxy-conn-verdict outage SKIP not FAIL (GREEN)" "FAIL" \
            "run: bash tests/regression/proxy_conn_verdict_test.sh"
    fi

    # BUGFIX-0014 — RED self-check: the pre-fix (code != expected => FAIL) replica
    # must FAIL a proxy miss on an external outage. RED that cannot reproduce is a
    # §11.4.7 finding.
    if RED_MODE=1 bash "$SCRIPT_DIR/regression/proxy_conn_verdict_test.sh" >/dev/null 2>&1; then
        test_result "BUGFIX-0014 proxy-conn-verdict false-FAIL RED reproduces" "PASS"
    else
        test_result "BUGFIX-0014 proxy-conn-verdict false-FAIL RED reproduces" "FAIL" \
            "RED could not reproduce the defect — §11.4.7"
    fi

    # BUGFIX-0015 (discovery-sweep F5) — GREEN guard: ddos_flood_suite must only
    # score "survived the flood" when a flood ACTUALLY occurred (flood_total>0 AND
    # flood_responses>0), never a §11.4.1 no-proof PASS. Pure classifier, no network.
    if bash "$SCRIPT_DIR/regression/ddos_flood_evidence_test.sh" >/dev/null 2>&1; then
        test_result "BUGFIX-0015 ddos-flood survival requires real flood evidence (GREEN)" "PASS"
    else
        test_result "BUGFIX-0015 ddos-flood survival requires real flood evidence (GREEN)" "FAIL" \
            "run: bash tests/regression/ddos_flood_evidence_test.sh"
    fi
    if RED_MODE=1 bash "$SCRIPT_DIR/regression/ddos_flood_evidence_test.sh" >/dev/null 2>&1; then
        test_result "BUGFIX-0015 ddos-flood no-proof PASS RED reproduces" "PASS"
    else
        test_result "BUGFIX-0015 ddos-flood no-proof PASS RED reproduces" "FAIL" \
            "RED could not reproduce the defect — §11.4.7"
    fi

    # BUGFIX-0016 (discovery-sweep F6) — GREEN guard: benchmark ratchet must compare
    # against a persistent COMMITTED baseline (seed+SKIP on absent, FAIL on regression
    # beyond tolerance), never a §11.4.169(13)/§11.4.1 budget-only always-PASS. No network.
    if bash "$SCRIPT_DIR/regression/benchmark_baseline_ratchet_test.sh" >/dev/null 2>&1; then
        test_result "BUGFIX-0016 benchmark ratchet compares vs persistent baseline (GREEN)" "PASS"
    else
        test_result "BUGFIX-0016 benchmark ratchet compares vs persistent baseline (GREEN)" "FAIL" \
            "run: bash tests/regression/benchmark_baseline_ratchet_test.sh"
    fi
    if RED_MODE=1 bash "$SCRIPT_DIR/regression/benchmark_baseline_ratchet_test.sh" >/dev/null 2>&1; then
        test_result "BUGFIX-0016 benchmark budget-only bluff RED reproduces" "PASS"
    else
        test_result "BUGFIX-0016 benchmark budget-only bluff RED reproduces" "FAIL" \
            "RED could not reproduce the defect — §11.4.7"
    fi

    # BUGFIX-0018 (discovery-sweep F7 + F-1) — GREEN guard: evidence.sh
    # assert_egress_ip must NOT fake-PASS the VPN-routing §15 proof when the host's
    # real IP is unknown/empty/garbage/sentinel (the egress!=host half is then
    # UNVERIFIABLE) — it returns exit-2 OPERATOR-BLOCKED, never a §11.4.68 fail-open;
    # a definitively-wrong exit still FAILs, a genuine egress==exit&&!=host still PASSes.
    if bash "$SCRIPT_DIR/regression/assert_egress_ip_host_unknown_test.sh" >/dev/null 2>&1; then
        test_result "BUGFIX-0018 assert-egress host-unknown fail-open closed (GREEN)" "PASS"
    else
        test_result "BUGFIX-0018 assert-egress host-unknown fail-open closed (GREEN)" "FAIL" \
            "run: bash tests/regression/assert_egress_ip_host_unknown_test.sh"
    fi
    if RED_MODE=1 bash "$SCRIPT_DIR/regression/assert_egress_ip_host_unknown_test.sh" >/dev/null 2>&1; then
        test_result "BUGFIX-0018 assert-egress fail-open RED reproduces" "PASS"
    else
        test_result "BUGFIX-0018 assert-egress fail-open RED reproduces" "FAIL" \
            "RED could not reproduce the defect — §11.4.7"
    fi

    # Let's Encrypt Phase 1 (task #59) — GREEN guard: the offline cert-analyzer
    # (tests/letsencrypt/cert_analyzer.sh) must be self-validating (§11.4.107(10)) —
    # it ACCEPTS every golden-GOOD property and REJECTS every golden-BAD (expired /
    # wrong-CA / wrong-host / SAN-substring / not-due). No network. RED reproduces the
    # naive presence-only + SAN-substring bluffs the real analyzer closes.
    if bash "$SCRIPT_DIR/regression/cert_analyzer_selfvalidation_test.sh" >/dev/null 2>&1; then
        test_result "LE cert-analyzer self-validation (golden-good/bad, GREEN)" "PASS"
    else
        test_result "LE cert-analyzer self-validation (golden-good/bad, GREEN)" "FAIL" \
            "run: bash tests/regression/cert_analyzer_selfvalidation_test.sh"
    fi
    if RED_MODE=1 bash "$SCRIPT_DIR/regression/cert_analyzer_selfvalidation_test.sh" >/dev/null 2>&1; then
        test_result "LE cert-analyzer bluff-analyzer RED reproduces" "PASS"
    else
        test_result "LE cert-analyzer bluff-analyzer RED reproduces" "FAIL" \
            "RED could not reproduce the defect — §11.4.7"
    fi

    # BUGFIX-F1 (task #72) — GREEN guard: the security-suite group verdict
    # (single-source acl_group_verdict(), tests/lib/acl_group_verdict.sh —
    # §11.4.107(10)) must NEVER report PASS when a security-CRITICAL check
    # (S1 ACL-deny / S4 SOCKS-SSRF) merely SKIPPED — a non-critical S2/S3 PASS
    # can no longer over-claim group coverage (§11.4.120/§11.4.1). Pure logic,
    # no network/containers.
    if bash "$SCRIPT_DIR/regression/security_group_critical_gate_test.sh" >/dev/null 2>&1; then
        test_result "BUGFIX-F1 security group verdict no over-claim (GREEN)" "PASS"
    else
        test_result "BUGFIX-F1 security group verdict no over-claim (GREEN)" "FAIL" \
            "run: bash tests/regression/security_group_critical_gate_test.sh"
    fi

    # BUGFIX-F1 — RED self-check: the pre-fix over-claim rule (n_pass>0 && n_fail==0
    # => PASS) must reproduce a group PASS for the S3-only shape. A RED that cannot
    # reproduce is a §11.4.7 finding.
    if RED_MODE=1 bash "$SCRIPT_DIR/regression/security_group_critical_gate_test.sh" >/dev/null 2>&1; then
        test_result "BUGFIX-F1 security group over-claim RED reproduces" "PASS"
    else
        test_result "BUGFIX-F1 security group over-claim RED reproduces" "FAIL" \
            "RED could not reproduce the defect — §11.4.7"
    fi

    # LE Phase-3 hermetic DNS-01 issuance guard (§11.4.135). Unlike the pure-logic
    # guards above, this BOOTS the hermetic Pebble+CoreDNS+Caddy stack, so it uses
    # a 3-way exit (0=PASS, 2=topology SKIP when the built image is absent §11.4.3,
    # else FAIL) — collapsing SKIP into FAIL would be a §11.4.1 false-FAIL. GREEN =
    # a real cert is issued + analyzer-verified; RED (broken resolver) reproduces
    # the zone-determination regression the CoreDNS SOA-front fixes. Expensive
    # (~2 min with the image present); set SKIP_LE_ISSUANCE_GUARD=1 to skip it.
    if [ "${SKIP_LE_ISSUANCE_GUARD:-0}" = "1" ]; then
        test_result "LE Phase-3 hermetic issuance guard" "SKIP" "SKIP_LE_ISSUANCE_GUARD=1"
    else
        # `|| _p3_rc=$?` (not `; _p3_rc=$?`) — under `set -euo pipefail` a bare
        # `cmd; rc=$?` aborts the whole suite the instant the guard exits non-zero
        # (e.g. a §11.4.3 topology SKIP=2), before rc is ever captured. The guard's
        # 3-way exit MUST be recorded as PASS/SKIP/FAIL, never abort the suite.
        _p3_rc=0; sh "$SCRIPT_DIR/letsencrypt/phase3_issuance_guard.sh" >/dev/null 2>&1 || _p3_rc=$?
        case "$_p3_rc" in
            0) test_result "LE Phase-3 hermetic issuance (GREEN: real cert issued + verified)" "PASS" ;;
            2) test_result "LE Phase-3 hermetic issuance (GREEN)" "SKIP" "built image/podman-compose absent — §11.4.3" ;;
            *) test_result "LE Phase-3 hermetic issuance (GREEN)" "FAIL" \
                   "run: sh tests/letsencrypt/phase3_issuance_guard.sh" ;;
        esac
        _p3_rc=0; RED_MODE=1 sh "$SCRIPT_DIR/letsencrypt/phase3_issuance_guard.sh" >/dev/null 2>&1 || _p3_rc=$?
        case "$_p3_rc" in
            0) test_result "LE Phase-3 issuance guard RED reproduces (broken resolver)" "PASS" ;;
            2) test_result "LE Phase-3 issuance guard RED" "SKIP" "built image/podman-compose absent — §11.4.3" ;;
            *) test_result "LE Phase-3 issuance guard RED" "FAIL" "RED could not reproduce — §11.4.7" ;;
        esac
    fi

    # LE Phase-5 renewal/rotation guard (§11.4.135) — boots the hermetic stack, so the
    # same 3-way exit (0=PASS / 2=topology SKIP §11.4.3 / else FAIL) + SKIP_LE_ISSUANCE_GUARD.
    # GREEN = real renewal S1->S2 with a 0-downtime swap + analyzer-verified S2; RED (no
    # ARI surgery) MUST NOT renew — proves the surgery is the trigger.
    if [ "${SKIP_LE_ISSUANCE_GUARD:-0}" = "1" ]; then
        test_result "LE Phase-5 renewal/rotation guard" "SKIP" "SKIP_LE_ISSUANCE_GUARD=1"
    else
        _p5_rc=0; sh "$SCRIPT_DIR/letsencrypt/phase5_rotation_guard.sh" >/dev/null 2>&1 || _p5_rc=$?
        case "$_p5_rc" in
            0) test_result "LE Phase-5 renewal rotation (GREEN: real S1->S2, 0-downtime swap, analyzer verifies S2)" "PASS" ;;
            2) test_result "LE Phase-5 renewal rotation (GREEN)" "SKIP" "built image/podman-compose absent — §11.4.3" ;;
            *) test_result "LE Phase-5 renewal rotation (GREEN)" "FAIL" \
                   "run: sh tests/letsencrypt/phase5_rotation_guard.sh" ;;
        esac
        _p5_rc=0; RED_MODE=1 sh "$SCRIPT_DIR/letsencrypt/phase5_rotation_guard.sh" >/dev/null 2>&1 || _p5_rc=$?
        case "$_p5_rc" in
            0) test_result "LE Phase-5 rotation guard RED reproduces (no surgery => no renewal)" "PASS" ;;
            2) test_result "LE Phase-5 rotation guard RED" "SKIP" "built image/podman-compose absent — §11.4.3" ;;
            *) test_result "LE Phase-5 rotation guard RED" "FAIL" "RED could not reproduce — §11.4.7" ;;
        esac
    fi

    # task #73 (dynamic-audit ac3f1c89) — GREEN guard: chaos_suite C1 no-leak
    # sub-signal can NEVER vacuously PASS. Drives the REAL no_leak analyzer + the
    # REAL chaos_target_leak_key/chaos_leak_signal fix functions (§11.4.107(10),
    # no divergent copy). Proves a URL target is stripped to its host/IP so a real
    # leak is CAUGHT, and an empty/absent uplink capture is UNEVALUATED (honest
    # SKIP) not a silent no-leak PASS (§11.4.6/§11.4.120). Pure logic, no live stack.
    if bash "$SCRIPT_DIR/regression/chaos_no_leak_argshape_test.sh" >/dev/null 2>&1; then
        test_result "task#73 chaos no-leak arg-shape + empty-capture (GREEN)" "PASS"
    else
        test_result "task#73 chaos no-leak arg-shape + empty-capture (GREEN)" "FAIL" \
            "run: bash tests/regression/chaos_no_leak_argshape_test.sh"
    fi
    # task #73 — RED self-check: the URL-as-key vacuous PASS on a REAL leak AND the
    # pre-fix empty-capture-assumed-no-leak must reproduce. A RED that cannot
    # reproduce is a §11.4.7 finding.
    if RED_MODE=1 bash "$SCRIPT_DIR/regression/chaos_no_leak_argshape_test.sh" >/dev/null 2>&1; then
        test_result "task#73 chaos no-leak vacuous-PASS RED reproduces" "PASS"
    else
        test_result "task#73 chaos no-leak vacuous-PASS RED reproduces" "FAIL" \
            "RED could not reproduce the defect — §11.4.7"
    fi

    # task #74 (dynamic-audit ac3f1c89) — GREEN guard: vpn_failclosed's
    # no-leak-but-not-branded SKIP reason NEVER asserts "fail-closed held — no
    # leak" as fact for an all-timeout (000) run (absence-of-response is
    # inconclusive, §11.4.6/§11.4.3). Drives the REAL fc_no_leak_skip_reason
    # (§11.4.107(10), no divergent copy) — the legitimate branded-path-inactive
    # branch is preserved (§11.4.120). Pure logic, no live stack.
    if bash "$SCRIPT_DIR/regression/vpn_failclosed_reason_test.sh" >/dev/null 2>&1; then
        test_result "task#74 vpn_failclosed all-timeout inconclusive reason (GREEN)" "PASS"
    else
        test_result "task#74 vpn_failclosed all-timeout inconclusive reason (GREEN)" "FAIL" \
            "run: bash tests/regression/vpn_failclosed_reason_test.sh"
    fi
    if RED_MODE=1 bash "$SCRIPT_DIR/regression/vpn_failclosed_reason_test.sh" >/dev/null 2>&1; then
        test_result "task#74 vpn_failclosed 'fail-closed held' over-claim RED reproduces" "PASS"
    else
        test_result "task#74 vpn_failclosed 'fail-closed held' over-claim RED reproduces" "FAIL" \
            "RED could not reproduce the defect — §11.4.7"
    fi

    # task #75 (dynamic-audit ac3f1c89) — GREEN guard: memory_soak's bounded
    # verdict NEVER scores a sampler that DIED mid-soak (degenerate final
    # sample -> growth=-100%) as a "bounded" PASS. Drives the REAL
    # mem_soak_classify (§11.4.107(10), no divergent copy): degenerate -> SKIP,
    # valid -> PASS, unbounded -> FAIL (§11.4.6/§11.4.69/§11.4.120). Pure logic.
    if bash "$SCRIPT_DIR/regression/memory_soak_degenerate_sample_test.sh" >/dev/null 2>&1; then
        test_result "task#75 memory_soak degenerate-final-sample SKIP (GREEN)" "PASS"
    else
        test_result "task#75 memory_soak degenerate-final-sample SKIP (GREEN)" "FAIL" \
            "run: bash tests/regression/memory_soak_degenerate_sample_test.sh"
    fi
    if RED_MODE=1 bash "$SCRIPT_DIR/regression/memory_soak_degenerate_sample_test.sh" >/dev/null 2>&1; then
        test_result "task#75 memory_soak degenerate-scored-bounded RED reproduces" "PASS"
    else
        test_result "task#75 memory_soak degenerate-scored-bounded RED reproduces" "FAIL" \
            "RED could not reproduce the defect — §11.4.7"
    fi
    if bash "$SCRIPT_DIR/regression/assert_no_leak_empty_capture_test.sh" >/dev/null 2>&1; then
        test_result "task#76 assert_no_leak empty/structureless-capture fail-closed (GREEN)" "PASS"
    else
        test_result "task#76 assert_no_leak empty/structureless-capture fail-closed (GREEN)" "FAIL" \
            "run: bash tests/regression/assert_no_leak_empty_capture_test.sh"
    fi
    if RED_MODE=1 bash "$SCRIPT_DIR/regression/assert_no_leak_empty_capture_test.sh" >/dev/null 2>&1; then
        test_result "task#76 assert_no_leak absence-as-evidence RED reproduces" "PASS"
    else
        test_result "task#76 assert_no_leak absence-as-evidence RED reproduces" "FAIL" \
            "RED could not reproduce the defect — §11.4.7"
    fi
}

#######################################
# Security guards (§11.4.135 standing regression suite; §11.4.69 sink-side)
#######################################
test_security_guards() {
    echo -e "\n${BLUE}=== Security Guards (§11.4.135 / §11.4.69) ===${NC}"
    # proxy_acl_security.sh asserts S1 ACL-deny (authoritative access.log
    # TCP_DENIED/HIER_NONE) + S3 Via/version-hygiene + S4 SOCKS5-SSRF-block
    # against the LIVE proxy: exit 0=PASS / 3=topology SKIP (proxy not serving,
    # §11.4.3) / 1=FAIL. GREEN proves the shipped Squid/Dante hardening is really
    # deployed (§11.4.108 runtime-signature). The RED polarity — SEC_SSRF_TARGET
    # set to a target dante does NOT block (240.0.0.1, class-E) — MUST FAIL,
    # proving S4's dante-block-log discriminator has teeth (§11.4.115) and is not
    # the timing-only bluff the §11.4.142 independent review flagged.
    # Exit-code capture uses the `|| rc=$?` idiom (NOT `cmd; rc=$?`) so a non-zero
    # guard exit does NOT abort the `set -euo pipefail` suite before the code is
    # captured — the BUGFIX-0003 lesson, mirroring the if-condition guards above.
    _sec_out=""; _sec_rc=0
    _sec_out=$(bash "$SCRIPT_DIR/security/proxy_acl_security.sh" 2>&1) || _sec_rc=$?
    # §11.4.120/§11.4.1 honest headline: the aggregate exit 0 now REQUIRES both
    # security-critical checks (S1 ACL-deny + S4 SOCKS-SSRF) to have PASSED, so we
    # never claim a specific check "GREEN live" on a topology SKIP. On SKIP, name
    # which critical check(s) were absent (parsed from the [S1]/[S4] PASS lines).
    _s1_ok=no; printf '%s\n' "$_sec_out" | grep -q '\[S1\] PASS' && _s1_ok=yes
    _s4_ok=no; printf '%s\n' "$_sec_out" | grep -q '\[S4\] PASS' && _s4_ok=yes
    _sec_absent=""
    [ "$_s1_ok" = yes ] || _sec_absent="S1 ACL-deny"
    [ "$_s4_ok" = yes ] || _sec_absent="${_sec_absent:+$_sec_absent, }S4 SOCKS-SSRF"
    case "$_sec_rc" in
        0) test_result "Security guards (S1 ACL-deny + S4 SOCKS-SSRF critical, GREEN live)" "PASS" ;;
        3) test_result "Security guards (critical checks)" "SKIP" \
               "critical security check(s) absent: ${_sec_absent:-topology absent} — §11.4.3" ;;
        *) test_result "Security guards (S1 ACL-deny + S4 SOCKS-SSRF critical, live)" "FAIL" \
               "run: bash tests/security/proxy_acl_security.sh" ;;
    esac
    # RED negation is assertable ONLY when S4 itself ran GREEN (dante reachable);
    # a topology gap (S4 SKIP → aggregate may still exit 0 via S3) must NOT
    # manufacture a false FAIL (§11.4.1/§11.4.3) — so gate on the [S4] PASS line.
    if printf '%s\n' "$_sec_out" | grep -q '\[S4\] PASS'; then
        _sec_red=0
        SEC_SSRF_TARGET=240.0.0.1 bash "$SCRIPT_DIR/security/proxy_acl_security.sh" >/dev/null 2>&1 || _sec_red=$?
        if [ "$_sec_red" = "1" ]; then
            test_result "Security guard S4 RED reproduces (unblocked target => FAIL, block-log has teeth)" "PASS"
        else
            test_result "Security guard S4 RED reproduces" "FAIL" \
                "RED (SEC_SSRF_TARGET=240.0.0.1) did not FAIL (rc=$_sec_red) — S4 discriminator weak §11.4.7/§11.4.115"
        fi
    else
        test_result "Security guard S4 RED reproduces" "SKIP" "S4 not GREEN (dante not serving) — RED not assertable §11.4.3"
    fi
    # S1 ACL-deny GREEN — the first run's [S1] line reports whether the authoritative
    # Squid access.log discriminator (TCP_DENIED/403 + HIER_NONE) proved a must-deny
    # CONNECT was denied WITHOUT any upstream contact (deny enforced + no leak,
    # §11.4.69/§11.4.68). GREEN proves the shipped `http_access deny CONNECT
    # !SSL_ports` rule is really enforced on the live Squid (§11.4.108).
    if printf '%s\n' "$_sec_out" | grep -q '\[S1\] PASS'; then
        test_result "Security guard S1 ACL deny enforced + no leak (TCP_DENIED/HIER_NONE, live)" "PASS"
        # S1 RED — point at an ALLOWED target (:443). Squid legitimately tunnels it
        # (TCP_TUNNEL/HIER_DIRECT), so the deny discriminator MUST NOT emit a false
        # [S1] PASS. This proves S1 has teeth — it refuses an unconditional GREEN
        # (§11.4.115 polarity teeth).
        _s1_red_out=$(SEC_DENY_TARGET=https://example.com:443/ SEC_DENY_HOSTPORT=example.com:443 \
            bash "$SCRIPT_DIR/security/proxy_acl_security.sh" 2>&1 || true)
        if printf '%s\n' "$_s1_red_out" | grep -q '\[S1\] PASS'; then
            test_result "Security guard S1 RED reproduces (allowed :443 => no false deny-PASS)" "FAIL" \
                "allowed target still produced [S1] PASS — S1 discriminator weak §11.4.7/§11.4.115"
        else
            test_result "Security guard S1 RED reproduces (allowed :443 => no false deny-PASS)" "PASS"
        fi
    else
        test_result "Security guard S1 ACL deny (live)" "SKIP" "S1 not GREEN (proxy/access.log absent) — deny not assertable §11.4.3"
    fi
}

#######################################
# VPN-LAN svord bridge preflight (Phase 0 — §11.4.3 honest-SKIP + §11.4.115 teeth)
#   Runs scripts/svord_doctor.sh and interprets its single BRIDGE: verdict. When
#   the svord bridge is DOWN or the .env contract is not configured (the default
#   autonomous state — no live svord connection), the VPN-LAN feature correctly
#   SKIPs (topology absent) — NEVER a fake PASS. When UP, the preflight PASSes and
#   the operator-gated protocol round-trips become runnable. A teeth check proves
#   the SKIP is CONDITIONAL (a healthy local stub flips the verdict to UP), so the
#   honest-SKIP can never degrade into an always-SKIP rubber-stamp.
#######################################
test_vpn_lan_bridge() {
    local doctor="$SCRIPT_DIR/../scripts/svord_doctor.sh"
    if [[ ! -f "$doctor" ]]; then
        test_result "VPN-LAN svord bridge preflight" "SKIP" "svord_doctor.sh absent (Phase 0 not present) §11.4.3"
        return
    fi
    local _vd_out _vd_rc=0
    _vd_out=$(sh "$doctor" 2>&1) || _vd_rc=$?
    local _verdict
    _verdict=$(printf '%s\n' "$_vd_out" | grep -E '^BRIDGE: ' | tail -1)
    case "$_verdict" in
        "BRIDGE: UP")
            test_result "VPN-LAN svord bridge preflight (bridge UP — protocol round-trips runnable)" "PASS"
            ;;
        "BRIDGE: SKIP:"*)
            test_result "VPN-LAN svord bridge preflight (bridge down — honest SKIP §11.4.3)" "SKIP" \
                "${_verdict#BRIDGE: } — VPN-LAN tests correctly SKIP when the svord bridge is down (not a fake PASS)"
            ;;
        "BRIDGE: MISCONFIGURED:"*)
            test_result "VPN-LAN svord bridge preflight (bridge not configured — honest SKIP §11.4.3)" "SKIP" \
                "${_verdict#BRIDGE: } — copy .env.example→.env + point at svord_toolkit to enable the VPN-LAN feature"
            ;;
        *)
            test_result "VPN-LAN svord bridge preflight" "FAIL" \
                "svord_doctor emitted no recognized BRIDGE verdict (rc=$_vd_rc): ${_vd_out}"
            ;;
    esac

    # §11.4.115 teeth — prove the SKIP is CONDITIONAL, not an always-SKIP: point
    # svord_doctor at a local UP-stub bridge (health exit 0, loopback host) and
    # assert the verdict flips to UP. If the preflight SKIPped even with a healthy
    # stub, the honest-SKIP would be a rubber-stamp (a §11.4 bluff).
    local _stub
    _stub=$(mktemp -d 2>/dev/null || echo "/tmp/svord_stub_$$")
    mkdir -p "$_stub"
    printf '#!/bin/sh\nexit 0\n' > "$_stub/health"
    printf '#!/bin/sh\nexit 0\n' > "$_stub/conn"
    printf '#!/bin/sh\nexit 0\n' > "$_stub/disc"
    chmod +x "$_stub/health" "$_stub/conn" "$_stub/disc" 2>/dev/null
    local _teeth _teeth_rc=0
    _teeth=$(HELIX_SVORD_DIR="$_stub" HELIX_BRIDGE_CONNECT="$_stub/conn" \
        HELIX_BRIDGE_DISCONNECT="$_stub/disc" HELIX_BRIDGE_HEALTH="$_stub/health" \
        HELIX_BRIDGE_SUBNET="10.0.0.0/8" HELIX_BRIDGE_HOST="127.0.0.1" \
        sh "$doctor" 2>&1) || _teeth_rc=$?
    rm -rf "$_stub" 2>/dev/null
    if printf '%s\n' "$_teeth" | grep -q '^BRIDGE: UP'; then
        test_result "VPN-LAN bridge preflight teeth (UP-stub ⇒ UP — SKIP is conditional §11.4.115)" "PASS"
    else
        test_result "VPN-LAN bridge preflight teeth (UP-stub ⇒ UP — SKIP is conditional §11.4.115)" "FAIL" \
            "healthy local stub did not yield BRIDGE: UP — preflight may be an always-SKIP rubber-stamp: ${_teeth}"
    fi
}

# VPN-LAN Phase 1 — SSRF carve-out teeth. Unlike the bridge-gated protocol tests
# (which correctly SKIP when the svord bridge is down), this one is AUTONOMOUS:
# it proves the Dante SOCKS SSRF floor survives the narrow VPN-subnet carve-out
# with NO live VPN and the live sockd.conf READ-ONLY (§11.4.119). So it belongs
# in the standing suite as permanent regression coverage (§11.4.135) and runs
# GREEN now. The SSRF_MUT=1 run is the suite-level teeth: it proves the SSRF
# teeth actually catch a collapsed floor (§11.4.115 / §1.1) rather than rubber-
# stamping — a security-critical guard for the widen-egress SSRF surface (§4).
test_vpn_lan_ssrf() {
    local ssrf="$SCRIPT_DIR/vpn_lan/ssrf_carveout_teeth.sh"
    if [[ ! -f "$ssrf" ]]; then
        test_result "VPN-LAN SSRF carve-out teeth" "SKIP" "ssrf_carveout_teeth.sh absent (Phase 1 not present) §11.4.3"
        return
    fi
    local _out _rc=0 _pass _fail
    _out=$(sh "$ssrf" 2>&1) || _rc=$?
    # `|| true` — grep -c prints 0 but EXITS 1 on zero matches; under
    # `set -euo pipefail` that would abort the whole suite mid-function.
    _pass=$(printf '%s\n' "$_out" | grep -c '^PASS:' || true)
    _fail=$(printf '%s\n' "$_out" | grep -c '^FAIL:' || true)
    if [[ $_rc -eq 0 && $_pass -ge 3 && $_fail -eq 0 ]]; then
        test_result "VPN-LAN SSRF carve-out teeth (floor blocks metadata+loopback+all RFC1918; narrow carve floor-preserving)" "PASS"
    elif printf '%s\n' "$_out" | grep -q '^SKIP:' && [[ $_fail -eq 0 && $_pass -eq 0 ]]; then
        test_result "VPN-LAN SSRF carve-out teeth (SSRF floor config absent — honest SKIP §11.4.3)" "SKIP" \
            "$(printf '%s\n' "$_out" | grep -m1 '^SKIP:')"
    else
        test_result "VPN-LAN SSRF carve-out teeth" "FAIL" \
            "expected rc=0 + >=3 PASS + 0 FAIL (rc=$_rc pass=$_pass fail=$_fail): ${_out}"
    fi
    local _mout _mrc=0
    _mout=$(SSRF_MUT=1 sh "$ssrf" 2>&1) || _mrc=$?
    if [[ $_mrc -eq 0 ]] && printf '%s\n' "$_mout" | grep -q '^PASS:'; then
        test_result "VPN-LAN SSRF teeth catch golden-bad floor-collapse (not a bluff gate §11.4.115/§1.1)" "PASS"
    else
        test_result "VPN-LAN SSRF teeth catch golden-bad floor-collapse (not a bluff gate §11.4.115/§1.1)" "FAIL" \
            "SSRF_MUT=1 did not catch the golden-bad fixtures (rc=$_mrc): ${_mout}"
    fi
}

# VPN-LAN Phase 12 — ingress-allowlist teeth. Autonomous (pure policy logic, no
# bridge): proves the VPN→proxy INGRESS surface (the bidirectional mandate) is
# default-deny + narrow-allowlist. Permanent §11.4.135 regression coverage for
# the ingress security surface, the mirror of the egress SSRF floor.
# NOTE the mutation rc convention is INVERTED vs the SSRF teeth: INGRESS_MUT=1
# exits 1 when it CAUGHT the golden-bad allow-all/wide policy (a slip-through
# would exit 2, loud and != 1).
test_vpn_lan_ingress() {
    local ing="$SCRIPT_DIR/vpn_lan/ingress_allowlist_teeth.sh"
    if [[ ! -f "$ing" ]]; then
        test_result "VPN-LAN ingress-allowlist teeth" "SKIP" "ingress_allowlist_teeth.sh absent (Phase 12 not present) §11.4.3"
        return
    fi
    local _out _rc=0 _pass _fail
    _out=$(sh "$ing" 2>&1) || _rc=$?
    # `|| true` — grep -c prints 0 but EXITS 1 on zero matches; under
    # `set -euo pipefail` that would abort the whole suite mid-function.
    _pass=$(printf '%s\n' "$_out" | grep -c '^PASS:' || true)
    _fail=$(printf '%s\n' "$_out" | grep -c '^FAIL:' || true)
    if [[ $_rc -eq 0 && $_pass -ge 4 && $_fail -eq 0 ]]; then
        test_result "VPN-LAN ingress-allowlist teeth (default-deny; only exact (host,port) permitted; host+port narrow)" "PASS"
    else
        test_result "VPN-LAN ingress-allowlist teeth" "FAIL" \
            "expected rc=0 + >=4 PASS + 0 FAIL (rc=$_rc pass=$_pass fail=$_fail): ${_out}"
    fi
    local _mrc=0
    INGRESS_MUT=1 sh "$ing" >/dev/null 2>&1 || _mrc=$?
    if [[ $_mrc -eq 1 ]]; then
        test_result "VPN-LAN ingress teeth catch golden-bad allow-all/wide policy (not a bluff gate §11.4.115/§1.1)" "PASS"
    else
        test_result "VPN-LAN ingress teeth catch golden-bad allow-all/wide policy (not a bluff gate §11.4.115/§1.1)" "FAIL" \
            "INGRESS_MUT=1 expected rc=1 (teeth caught the golden-bad), got rc=$_mrc"
    fi
}

# VPN-LAN Phase 12 — autonomous test battery (§11.4.135 standing regression guards).
# The stress+chaos, benchmark+memory, concurrency+load, and DNS-rebinding-gap tests all
# run WITHOUT the svord bridge or podman (pure evaluator/policy logic), so they belong in
# the standing suite as permanent GREEN guards. Each is run in its normal mode and must
# PASS (rc=0, >=1 '^PASS:' line, 0 '^FAIL:'); each ships its own §1.1 mutation self-check
# (proven at commit time), so the suite guard asserts the normal-mode GREEN. Uses the
# set-e-safe capture idiom ('rc=0; cmd || rc=$?', 'grep -c ... || true').
test_vpn_lan_autonomous_battery() {
    local _bat _p _out _rc _pass _fail _name
    for _bat in \
        "bridge-contract library unit tests (17 assertions)|vpn_lan/svord_bridge_unit.sh" \
        "SSRF stress+chaos (100-iter determinism + fail-safe chaos)|vpn_lan/ssrf_bridge_stress_chaos.sh" \
        "evaluator benchmark+memory (throughput floor + no RSS growth)|vpn_lan/evaluator_bench_memory.sh" \
        "evaluator concurrency+load (N-worker hash agreement + load correctness)|vpn_lan/evaluator_concurrency_load.sh" \
        "DNS-rebinding SSRF gap demo + resolved-IP-recheck fix|security/dns_rebinding_ssrf_gap.sh"; do
        _name=${_bat%%|*}; _p="$SCRIPT_DIR/${_bat#*|}"
        if [[ ! -f "$_p" ]]; then
            test_result "VPN-LAN autonomous: $_name" "SKIP" "test absent §11.4.3"
            continue
        fi
        _rc=0; _out=$(GOMAXPROCS=2 nice -n 19 ionice -c 3 sh "$_p" 2>&1) || _rc=$?
        _pass=$(printf '%s\n' "$_out" | grep -c '^PASS:' || true)
        _fail=$(printf '%s\n' "$_out" | grep -c '^FAIL:' || true)
        if [[ $_rc -eq 0 && $_pass -ge 1 && $_fail -eq 0 ]]; then
            test_result "VPN-LAN autonomous: $_name" "PASS"
        else
            test_result "VPN-LAN autonomous: $_name" "FAIL" \
                "expected rc=0 + >=1 PASS + 0 FAIL (rc=$_rc pass=$_pass fail=$_fail): run sh $_p"
        fi
    done
}

# VPN-LAN hermetic-tunnel autonomous protocol promotions (§11.4.52 / §11.4.135).
# Each harness stands up a REAL rootless kernel-WireGuard tunnel between two
# unprivileged netns and drives an UNMODIFIED protocol test (or the substrate
# round-trip) over it against a pure-stdlib peer — zero installs, no svord bridge,
# no podman, no live VPN. These are the STANDING regression guards for the three
# §11.4.52 protocol promotions (Cast-eureka / FTP / WebDAV) + the H0 tunnel
# substrate; each ships its own §1.1 golden-bad mutation self-check (proven at
# commit time), so the suite guard asserts the normal-mode verdict.
#   Verdict convention: exactly one '^PASS:' / '^SKIP:' / '^FAIL:' line; rc 0 on
#   PASS/SKIP, 1 on FAIL. Each harness does its OWN env-preflight and honestly
#   SKIPs (§11.4.3) when the host lacks the 'wireguard' kernel module or
#   unprivileged user+net namespaces — so the suite stays GREEN everywhere,
#   promotion-proven where supported and honest-SKIP where not.
#   SKIP-AWARE mapping (DISTINCT from the always-PASS battery above, which has no
#   env-skip path): rc0 + PASS>=1 + FAIL0 => PASS; rc0 + SKIP>=1 + PASS0 + FAIL0
#   => honest SKIP; anything else => FAIL. Invoked via 'bash' (harnesses are
#   bash, not POSIX-sh — §11.4.67), sequential (single netns owner §11.4.119),
#   resource-capped + timeout-bounded (§12 / §12.6) above each harness's own
#   inner timeout. set-e-safe capture ('rc=0; cmd || rc=$?', 'grep -c ... || true').
test_vpn_lan_hermetic() {
    local _h _p _out _rc _pass _skip _fail _name
    for _h in \
        "H0 kernel-WireGuard round-trip (tunnel substrate)|vpn_lan/hermetic_wg_roundtrip.sh" \
        "Chromecast eureka_info promoted over the tunnel|vpn_lan/hermetic_bridge_run.sh" \
        "FTP passive promoted over the tunnel|vpn_lan/hermetic_ftp_run.sh" \
        "WebDAV PROPFIND promoted over the tunnel|vpn_lan/hermetic_webdav_run.sh" \
        "Email SMTPS/IMAPS/POP3S promoted over the tunnel|vpn_lan/hermetic_email_run.sh"; do
        _name=${_h%%|*}; _p="$SCRIPT_DIR/${_h#*|}"
        if [[ ! -f "$_p" ]]; then
            test_result "VPN-LAN hermetic: $_name" "SKIP" "harness absent §11.4.3"
            continue
        fi
        _rc=0; _out=$(GOMAXPROCS=2 nice -n 19 ionice -c 3 timeout -k 5 150 bash "$_p" 2>&1) || _rc=$?
        _pass=$(printf '%s\n' "$_out" | grep -c '^PASS:' || true)
        _skip=$(printf '%s\n' "$_out" | grep -c '^SKIP:' || true)
        _fail=$(printf '%s\n' "$_out" | grep -c '^FAIL:' || true)
        if [[ $_rc -eq 0 && $_pass -ge 1 && $_fail -eq 0 ]]; then
            test_result "VPN-LAN hermetic: $_name" "PASS"
        elif [[ $_rc -eq 0 && $_skip -ge 1 && $_pass -eq 0 && $_fail -eq 0 ]]; then
            test_result "VPN-LAN hermetic: $_name" "SKIP" \
                "honest §11.4.3 env-skip (host lacks 'wireguard' module / unprivileged userns): run bash $_p"
        else
            test_result "VPN-LAN hermetic: $_name" "FAIL" \
                "expected rc0+>=1 PASS+0 FAIL, or rc0+SKIP-only (rc=$_rc pass=$_pass skip=$_skip fail=$_fail): run bash $_p"
        fi
    done
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
    test_security_guards
    test_vpn_lan_bridge
    test_vpn_lan_ssrf
    test_vpn_lan_ingress
    test_vpn_lan_autonomous_battery
    test_vpn_lan_hermetic
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
