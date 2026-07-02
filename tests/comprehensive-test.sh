#!/usr/bin/env bash
#######################################
# Comprehensive Proxy Service Tests
# Tests all functionality including VPN routing
#######################################

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# §11.4.69 data-plane anti-bluff evidence helpers (read-only dependency).
# Provides assert_egress_ip / assert_cache_hit / ab_pass_with_evidence /
# ab_skip_with_reason used by the corrected (de-bluffed) assertions below.
. "$SCRIPT_DIR/lib/evidence.sh"

# Captured-evidence output dir (§11.4.5 / §11.4.69; gitignored under qa-results/).
EVIDENCE_DIR="${EVIDENCE_DIR:-$PROJECT_ROOT/qa-results/comprehensive}"
mkdir -p "$EVIDENCE_DIR" 2>/dev/null || true

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
    
    # §11.4.1: use the assignment form, NOT (( VAR++ )). Under `set -e` a
    # post-increment whose prior value is 0 returns exit status 1 and aborts the
    # whole suite (the run-tests.sh:32-37 / BUGFIX-0001 lesson). [audit B4]
    TESTS_RUN=$((TESTS_RUN + 1))

    case "$result" in
        PASS)
            TESTS_PASSED=$((TESTS_PASSED + 1))
            echo -e "${GREEN}✓ PASS${NC}: $name"
            ;;
        FAIL)
            TESTS_FAILED=$((TESTS_FAILED + 1))
            FAILED_TESTS+=("$name: $message")
            echo -e "${RED}✗ FAIL${NC}: $name"
            [[ -n "$message" ]] && echo -e "  ${YELLOW}→ $message${NC}"
            ;;
        SKIP)
            TESTS_SKIPPED=$((TESTS_SKIPPED + 1))
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
    local proxy_port="${2:-34128}"
    
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
    local proxy_port="${2:-34080}"
    
    curl -s --max-time 15 \
        --proxy "socks5://${proxy_host}:${proxy_port}" \
        https://ifconfig.me 2>/dev/null || \
    echo "unknown"
}

#######################################
# §11.4.3 / §11.4.124: is the REAL cache-management CLI present?
# Returns 0 only when $PROJECT_ROOT/cachectl is a regular EXECUTABLE FILE. The
# documented CLI (commit 84e1754, docs/CACHE.md: stats|clear|invalidate|trim)
# was accidentally deleted in 6ec58ef because the tracked `cache` FILE collided
# with the gitignored `cache/` runtime DATA directory at the same path
# (regression #50); it is restored under the non-colliding name `cachectl`.
# When present this returns 0 and the cache-command checks run+assert (PASS);
# if somehow absent they SKIP-with-reason (§11.4.3), never a hard FAIL.
#######################################
cache_cli_available() {
    [[ -f "$PROJECT_ROOT/cachectl" && -x "$PROJECT_ROOT/cachectl" ]]
}

#######################################
# Test: Environment configuration
#######################################
test_environment() {
    test_header "ENVIRONMENT TESTS"
    
    cd "$PROJECT_ROOT"
    
    # §11.4.3: .env is gitignored (§11.4.10/§11.4.30); its ABSENCE is the
    # expected fresh-checkout topology, NOT a defect. When present → validate +
    # source it; when absent → SKIP-with-reason and validate the tracked
    # .env.example template instead, so the suite runs to a summary on a fresh
    # clone with NO transient .env (mirrors run-tests.sh).
    local env_sourced=0
    if [[ -f ".env" ]]; then
        test_result ".env file exists" "PASS"
        # shellcheck disable=SC1091
        source .env 2>/dev/null || true
        env_sourced=1
    else
        ab_skip_with_reason ".env present (config topology)" "feature_disabled_by_config" || true
        test_result ".env present (config topology)" "SKIP" ".env gitignored — absent on fresh checkout; validating .env.example template instead"
        # shellcheck disable=SC1091
        source .env.example 2>/dev/null || true
    fi

    # Test .env.example template exists (the §11.4.77 source that regenerates .env)
    if [[ -f ".env.example" ]]; then
        test_result ".env.example template exists" "PASS"
    else
        test_result ".env.example template exists" "FAIL"
    fi

    # Required variables — assert only when a real .env was sourced; otherwise
    # the values default at runtime (§11.4.3), so SKIP rather than FAIL.
    if [[ "$env_sourced" == "1" ]]; then
        [[ -n "${HTTP_PROXY_PORT:-}" ]] && test_result "HTTP_PROXY_PORT set ($HTTP_PROXY_PORT)" "PASS" || test_result "HTTP_PROXY_PORT set" "FAIL"
        [[ -n "${SOCKS_PROXY_PORT:-}" ]] && test_result "SOCKS_PROXY_PORT set ($SOCKS_PROXY_PORT)" "PASS" || test_result "SOCKS_PROXY_PORT set" "FAIL"
        [[ -n "${CACHE_DIR:-}" ]] && test_result "CACHE_DIR set ($CACHE_DIR)" "PASS" || test_result "CACHE_DIR set" "FAIL"
    else
        test_result "HTTP_PROXY_PORT set" "SKIP" "no .env sourced — value defaults at runtime (§11.4.3)"
        test_result "SOCKS_PROXY_PORT set" "SKIP" "no .env sourced — value defaults at runtime (§11.4.3)"
        test_result "CACHE_DIR set" "SKIP" "no .env sourced — value defaults at runtime (§11.4.3)"
    fi

    # Cache directory exists. CACHE_DIR may be unset or the .env.example
    # placeholder path; fall back to the repo runtime cache dir, and SKIP (not
    # FAIL) when neither is present on a fresh pre-init checkout (§11.4.3).
    local _cache_dir="${CACHE_DIR:-$PROJECT_ROOT/cache}"
    [[ -d "$_cache_dir" ]] || _cache_dir="$PROJECT_ROOT/cache"
    if [[ -d "$_cache_dir" ]]; then
        test_result "Cache directory exists" "PASS"
    else
        test_result "Cache directory exists" "SKIP" "cache dir not present — run './init' (§11.4.3)"
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
# §11.4.68/§11.4.69 topology-aware port check (mirrors run-tests.sh
# _ports_check_one). A listening host port proves the SERVICE works ONLY if the
# PROJECT container that owns it is running AND publishes it — a NON-project
# process listening on the port is NOT the project's service (a fail-open bluff;
# observed: a foreign `whoami` on :34088 answers 200 to any path and even echoes
# `Hostname: proxy-admin`). Truth table:
#   owner publishes + listening      -> PASS  (project service up and serving)
#   owner publishes + NOT listening  -> FAIL  (owner up but nothing bound)
#   owner NOT publishing + listening -> SKIP  (a non-project process holds it)
#   owner NOT publishing + no listen -> SKIP  (service not deployed in this topology)
_port_topology_check() {
    local port="$1" owner="$2" label="$3"
    local runtime published="no" listening="no"
    runtime=$(get_runtime)
    if container_running "$owner"; then
        case "$runtime" in
            podman) podman port "$owner" 2>/dev/null | grep -q ":${port}$" && published="yes" ;;
            docker) docker port "$owner" 2>/dev/null | grep -q ":${port}$" && published="yes" ;;
        esac
    fi
    ss -tuln 2>/dev/null | grep -q ":${port} " && listening="yes"
    if [[ "$published" == "yes" && "$listening" == "yes" ]]; then
        test_result "$label $port listening ($owner)" "PASS"
    elif [[ "$published" == "yes" && "$listening" == "no" ]]; then
        test_result "$label $port listening ($owner)" "FAIL" "$owner publishes :$port but nothing is bound"
    elif [[ "$published" == "no" && "$listening" == "yes" ]]; then
        test_result "$label $port" "SKIP" "a NON-project process holds :$port ($owner not publishing it) — not the project's service (§11.4.68); readiness not assertable (§11.4.3)"
    else
        test_result "$label $port" "SKIP" "$owner not running/publishing :$port in this topology (§11.4.3)"
    fi
}

test_ports() {
    test_header "PORT BINDING TESTS"

    source "$PROJECT_ROOT/.env" 2>/dev/null || true

    local http_port="${HTTP_PROXY_PORT:-34128}"
    local socks_port="${SOCKS_PROXY_PORT:-34080}"
    local admin_port="${PROXY_ADMIN_PORT:-34088}"

    _port_topology_check "$http_port"  "proxy-squid" "HTTP proxy port"
    _port_topology_check "$socks_port" "proxy-dante" "SOCKS proxy port"
    _port_topology_check "$admin_port" "proxy-admin" "Admin port"
}

# _external_egress_verdict <proxy_http_code> <direct_http_code> -> PASS | FAIL | SKIP
#
# §11.4.3 / §11.4.68 / §11.4.1: classify an external-site fetch through the proxy so
# a THIRD-PARTY OUTAGE never masquerades as a proxy defect (a false-FAIL), and a REAL
# proxy defect is never masked as an outage (a false-PASS/SKIP):
#   - proxy got 200                          -> PASS (proxy fetched it)
#   - proxy failed BUT the host reaches it
#     DIRECTLY (direct==200)                 -> FAIL (real proxy defect — the anti-bluff catch)
#   - proxy failed AND direct also failed    -> SKIP (external endpoint down — not ours; §11.4.3)
# Same discipline as test_large_file's faithful-relay / network_unreachable_external gate.
_external_egress_verdict() {
    if [ "$1" = "200" ]; then echo PASS
    elif [ "$2" = "200" ]; then echo FAIL
    else echo SKIP; fi
}

#######################################
# conn_check <label> <scheme> <port> <url> <expected-codes> [proxy_host]
#
# §11.4.1 / discovery-sweep F1 (BUGFIX-0017): anti-bluff through-proxy
# connectivity CANARY. Replaces the old `code != expected -> FAIL` canaries that
# BUGFIX-0014 already de-bluffed in verify-proxy.sh / final-verify.sh. Verdict:
#   - proxy returns an EXPECTED code                       -> PASS
#   - proxy miss BUT the SAME url answers DIRECTLY          -> FAIL (real proxy
#     defect — a listening-but-broken proxy can never fail-open to SKIP; §11.4.68)
#   - proxy miss AND direct also fails, port listening      -> SKIP
#     (network_unreachable_external — a third-party/local outage is NOT a proxy
#     defect, so NEVER a §11.4.1 false-FAIL)
#   - proxy miss AND direct fails, port NOT listening       -> SKIP
#     (topology_unsupported)
# Mirrors the conn_check in verify-proxy.sh (same classifier: _code_in ->
# proxy_conn_verdict from tests/lib/evidence.sh, already sourced line 15), but
# routes the verdict through this suite's test_result so the PASS/FAIL/SKIP
# accounting + SKIP-counts-as-neither semantics (§11.4.3) are preserved.
# [proxy_host] defaults to localhost (the network_client canaries pass $host_ip).
#######################################
conn_check() {
    local label="$1" scheme="$2" port="$3" url="$4" expected="$5" phost="${6:-localhost}"
    local pc dc listen verdict
    pc=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 \
        --proxy "${scheme}://${phost}:${port}" "$url" 2>/dev/null || echo "000")
    if _code_in "$pc" "$expected"; then
        test_result "$label" "PASS" "code: $pc"
        return 0
    fi
    dc=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "$url" 2>/dev/null || echo "000")
    listen=no
    if port_is_listening "$port"; then listen=yes; fi
    verdict=$(proxy_conn_verdict "$pc" "$dc" "$expected" "$listen")
    case "$verdict" in
        PASS)
            test_result "$label" "PASS" "code: $pc" ;;
        FAIL)
            test_result "$label" "FAIL" "proxy code: $pc but url reachable directly ($dc) — real proxy defect (§11.4.68)" ;;
        SKIP:*)
            ab_skip_with_reason "$label (proxy code: $pc, direct: $dc)" "${verdict#SKIP:}" || true
            test_result "$label" "SKIP" "proxy=$pc direct=$dc — external outage, not a proxy defect (§11.4.3)" ;;
    esac
}

#######################################
# Test: HTTP Proxy functionality
#######################################
test_http_proxy() {
    test_header "HTTP PROXY TESTS"
    
    source "$PROJECT_ROOT/.env" 2>/dev/null || true
    local port="${HTTP_PROXY_PORT:-34128}"

    # §11.4.1 / F1 (BUGFIX-0017): basic connectivity + HTTPS-through-proxy canaries
    # now classify a proxy miss (outage -> SKIP; directly-reachable-but-proxy-fails
    # -> FAIL) instead of the old blind `code != expected -> FAIL`.
    # Test basic connectivity (204 no-content endpoint; some caches answer 200)
    conn_check "HTTP proxy connectivity" http "$port" \
        "http://connectivitycheck.gstatic.com/generate_204" "204 200"

    # Test HTTPS through proxy
    conn_check "HTTPS through HTTP proxy" http "$port" \
        "https://www.google.com" "200 301 302"

    local response
    # Test various sites. §11.4.3/§11.4.68: a proxy 200 is PASS; a proxy failure on a
    # site the host reaches DIRECTLY is a real proxy defect (FAIL); a site unreachable
    # BOTH via proxy AND directly is an external outage (SKIP — not a proxy defect).
    local sites=("https://httpbin.org/ip" "https://api.ipify.org")
    for site in "${sites[@]}"; do
        response=$(curl -s -o /dev/null -w "%{http_code}" \
            --max-time 10 \
            --proxy "http://localhost:$port" \
            "$site" 2>/dev/null || echo "000")

        if [[ "$response" == "200" ]]; then
            test_result "Access $site" "PASS"
            continue
        fi
        # proxy did not get 200 — is the site reachable DIRECTLY (host, no proxy)?
        local direct
        direct=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "$site" 2>/dev/null || echo "000")
        case "$(_external_egress_verdict "$response" "$direct")" in
            FAIL)
                test_result "Access $site" "FAIL" \
                    "proxy=$response but direct=$direct — proxy cannot fetch a directly-reachable site (real defect)" ;;
            *)
                ab_skip_with_reason "access $site (proxy egress)" "network_unreachable_external" || true
                test_result "Access $site" "SKIP" \
                    "external site unreachable directly too (proxy=$response direct=$direct) — outage, not a proxy defect (§11.4.3)" ;;
        esac
    done
}

#######################################
# Test: SOCKS Proxy functionality
#######################################
test_socks_proxy() {
    test_header "SOCKS5 PROXY TESTS"
    
    source "$PROJECT_ROOT/.env" 2>/dev/null || true
    local port="${SOCKS_PROXY_PORT:-34080}"

    # §11.4.1 / F1 (BUGFIX-0017): SOCKS connectivity + HTTPS-through-SOCKS canaries
    # classify a proxy miss (outage -> SKIP; directly-reachable-but-proxy-fails ->
    # FAIL) instead of the old blind `code != expected -> FAIL`.
    # Test basic connectivity
    conn_check "SOCKS proxy connectivity" socks5 "$port" \
        "http://connectivitycheck.gstatic.com/generate_204" "204 200"

    # Test HTTPS through SOCKS
    conn_check "HTTPS through SOCKS proxy" socks5 "$port" \
        "https://www.google.com" "200 301 302"
}

#######################################
# Test: VPN routing
#######################################
test_vpn_routing() {
    test_header "VPN ROUTING TESTS"
    
    source "$PROJECT_ROOT/.env" 2>/dev/null || true
    local http_port="${HTTP_PROXY_PORT:-34128}"
    local socks_port="${SOCKS_PROXY_PORT:-34080}"
    
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
    
    # §11.4.69 / evidence.sh assert_egress_ip: real VPN routing PROOF is
    # egress-through-proxy == EXPECTED VPN exit IP AND != host real IP. The old
    # check PASSed when egress == host — the INVERSE of routing (the §15 bluff:
    # both paths exit the same address ⇒ NO VPN diversion) — and is removed.
    # The decisive proof needs an operator/P10-provided expected exit IP
    # (VPN_EXIT_IP) + an up tunnel; absent it, the proof cannot be captured
    # autonomously, so emit an honest SKIP (full RED/GREEN deferred to P10).
    # NEVER restore the egress==host PASS. [audit B1]
    local expected_exit_ip="${VPN_EXIT_IP:-}"
    if [[ -z "$expected_exit_ip" ]]; then
        ab_skip_with_reason "VPN routing (egress==expected exit, !=host)" "operator_attended" || true
        test_result "VPN routing (egress==expected exit, !=host)" "SKIP" "VPN_EXIT_IP unset — operator_attended, full RED/GREEN deferred to P10"
    elif assert_egress_ip "http://localhost:$http_port" "$expected_exit_ip" "$host_ip"; then
        test_result "VPN routing (egress==expected exit, !=host)" "PASS" "egress matches VPN exit $expected_exit_ip, != host $host_ip"
    else
        test_result "VPN routing (egress==expected exit, !=host)" "FAIL" "egress not routed via expected VPN exit $expected_exit_ip (host $host_ip)"
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
    local port="${HTTP_PROXY_PORT:-34128}"
    local cache_dir="${CACHE_DIR:-$PROJECT_ROOT/cache}"
    # CACHE_DIR may be unset or the .env.example placeholder path; fall back to
    # the repo runtime cache dir (§11.4.3).
    [[ -d "$cache_dir/squid" ]] || cache_dir="$PROJECT_ROOT/cache"

    # Squid cache dir is absent on a fresh pre-init checkout — SKIP the
    # data-plane cache checks rather than hard-FAIL/abort the suite (§11.4.3).
    if [[ -d "$cache_dir/squid" ]]; then
        test_result "Squid cache directory exists" "PASS"
    else
        test_result "Squid cache directory exists" "SKIP" "cache not initialised — run './init' (§11.4.3)"
        return 0
    fi
    
    # §11.4.69 / evidence.sh assert_cache_hit: a real cache fact is a Squid
    # TCP_*HIT result code in the access.log for THIS url — NOT a wall-clock
    # timing comparison (timing is non-deterministic §11.4.50 and proves no
    # data-plane HIT: faster can come from TCP/DNS warmup or CDN jitter with the
    # object NEVER cached). HTTPS bodies are CONNECT-tunnelled and never
    # cacheable by Squid, so use a cacheable HTTP url. [audit B2]
    local test_url="http://www.gnu.org/graphics/heckert_gnu.transp.small.png"
    curl -s --max-time 30 --proxy "http://localhost:$port" "$test_url" -o /dev/null 2>/dev/null || true  # warm (MISS)
    sleep 1
    curl -s --max-time 30 --proxy "http://localhost:$port" "$test_url" -o /dev/null 2>/dev/null || true  # should HIT

    # The squid container writes /var/log/squid/access.log; the host-mounted
    # copy is owned by the container uid and is not host-readable, so snapshot
    # it via the runtime, then assert a URL-specific TCP_*HIT in the real log.
    local access_snapshot="$EVIDENCE_DIR/squid_access_snapshot.log"
    local runtime
    runtime=$(get_runtime)
    if [[ "$runtime" != "none" ]] && "$runtime" exec proxy-squid cat /var/log/squid/access.log > "$access_snapshot" 2>/dev/null && [[ -s "$access_snapshot" ]]; then
        if assert_cache_hit "$access_snapshot" "$test_url" > "$EVIDENCE_DIR/cache_hit.evidence" 2>&1; then
            cat "$EVIDENCE_DIR/cache_hit.evidence"
            test_result "Cache HIT (Squid TCP_*HIT in access.log)" "PASS" "evidence: $EVIDENCE_DIR/cache_hit.evidence"
        else
            cat "$EVIDENCE_DIR/cache_hit.evidence"
            test_result "Cache HIT (Squid TCP_*HIT in access.log)" "FAIL" "no TCP_*HIT for $test_url in access.log"
        fi
    else
        test_result "Cache HIT (Squid TCP_*HIT in access.log)" "SKIP" "access.log not readable via runtime"
    fi

    # §11.4.69 + §11.4.3 + §11.4.124: capture the real `./cachectl stats` output
    # and assert a SUBSTANTIVE cache figure (exit-status-only &>/dev/null was
    # presence-only). Topology-aware: the documented cache CLI (restored as
    # ./cachectl after the 6ec58ef accidental deletion, #50) is run+asserted when
    # present (PASS); if somehow absent → honest SKIP (NOT a hard FAIL).
    if cache_cli_available; then
        local cache_stats_out="$EVIDENCE_DIR/cache_stats.out"
        "$PROJECT_ROOT/cachectl" stats > "$cache_stats_out" 2>&1 || true
        if grep -Eq 'Cache (Hits|Size|Misses)|TCP_[A-Z_]*HIT|Hit ratio|[0-9]+ ?(KB|MB|GB|bytes)|[0-9]+ objects?' "$cache_stats_out"; then
            ab_pass_with_evidence "cache stats reports real figures" "$cache_stats_out" || true
            test_result "Cache stats command reports real figures" "PASS" "evidence: $cache_stats_out"
        else
            test_result "Cache stats command reports real figures" "FAIL" "cachectl present but no substantive figures ($cache_stats_out)"
        fi
    else
        test_result "Cache stats command (real CLI)" "SKIP" "cachectl absent — restore the cache CLI, tracked #50 (§11.4.124)"
    fi
}

#######################################
# Test: Admin interface
#######################################
test_admin() {
    test_header "ADMIN INTERFACE TESTS"

    source "$PROJECT_ROOT/.env" 2>/dev/null || true
    local port="${PROXY_ADMIN_PORT:-34088}"

    # §11.4.68/§11.4.69 ownership gate: a 200 from :$port is proof ONLY if the
    # PROJECT's proxy-admin container is running AND publishes that host port.
    # Otherwise a non-project responder (observed: a foreign `whoami` on :34088
    # answers 200 to ANY path and even echoes `Hostname: proxy-admin`) would be a
    # fail-open bluff. When not project-owned, SKIP-with-reason (§11.4.3) — we
    # refuse to assert whatever happens to answer on the port.
    local runtime published="no"
    runtime=$(get_runtime)
    if container_running "proxy-admin"; then
        case "$runtime" in
            podman) podman port "proxy-admin" 2>/dev/null | grep -q ":${port}$" && published="yes" ;;
            docker) docker port "proxy-admin" 2>/dev/null | grep -q ":${port}$" && published="yes" ;;
        esac
    fi
    if [[ "$published" != "yes" ]]; then
        test_result "Admin interface (:$port)" "SKIP" \
            "proxy-admin not running or not publishing :$port — refusing to assert a non-project responder (§11.4.68); readiness not assertable (§11.4.3)"
        return 0
    fi

    # Owned: a 200 here is genuinely the project's admin.
    local response
    response=$(curl -s -o /dev/null -w "%{http_code}" \
        --max-time 10 \
        "http://localhost:$port/health" 2>/dev/null || echo "000")
    if [[ "$response" == "200" ]]; then
        test_result "Admin health endpoint" "PASS"
    else
        test_result "Admin health endpoint" "FAIL" "HTTP code: $response"
    fi

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
    
    # §11.4.69: capture the real `./status` output and assert SUBSTANTIVE status
    # fields (Container/Port/Connection state) instead of exit-status-only
    # (&>/dev/null was presence-only — and ./status exits non-zero merely
    # because the OPTIONAL VPN service is stopped, so the old exit-code gate was
    # also the wrong signal). [audit B8]
    local status_out="$EVIDENCE_DIR/status.out"
    ./status > "$status_out" 2>&1 || true
    if grep -Eq 'Container Status|Port Status|Running|LISTENING|WORKING' "$status_out"; then
        ab_pass_with_evidence "status reports real service/port fields" "$status_out" || true
        test_result "Status command reports real fields" "PASS" "evidence: $status_out"
    else
        test_result "Status command reports real fields" "FAIL" "no substantive status fields ($status_out)"
    fi

    local status_v_out="$EVIDENCE_DIR/status_verbose.out"
    ./status -v > "$status_v_out" 2>&1 || true
    if grep -Eq 'Container Status|Port Status|Running|LISTENING|WORKING' "$status_v_out"; then
        ab_pass_with_evidence "status -v reports real fields" "$status_v_out" || true
        test_result "Status verbose reports real fields" "PASS" "evidence: $status_v_out"
    else
        test_result "Status verbose reports real fields" "FAIL" "no substantive fields ($status_v_out)"
    fi

    local status_json_out="$EVIDENCE_DIR/status_json.out"
    ./status --json > "$status_json_out" 2>&1 || true
    if grep -Eq '"running"|"port_status"|"status"|LISTENING|WORKING' "$status_json_out"; then
        ab_pass_with_evidence "status --json emits structured output" "$status_json_out" || true
        test_result "Status JSON emits structured output" "PASS" "evidence: $status_json_out"
    else
        test_result "Status JSON emits structured output" "FAIL" "no JSON status fields ($status_json_out)"
    fi
}

#######################################
# Test: Cache commands
#######################################
test_cache_commands() {
    test_header "CACHE COMMAND TESTS"
    
    cd "$PROJECT_ROOT"
    
    # §11.4.69 + §11.4.3 + §11.4.124: capture the real output of each cache
    # command and assert a SUBSTANTIVE figure instead of exit-status-only
    # (&>/dev/null was presence-only). [audit B8]  Topology-aware: the documented
    # cache CLI (stats|size|list), restored as ./cachectl after the 6ec58ef
    # accidental deletion (#50), is run+asserted when present (PASS); if somehow
    # absent these SKIP-with-reason (honest §11.4.3) rather than hard-FAIL.
    local cc out
    if cache_cli_available; then
        for cc in stats size list; do
            out="$EVIDENCE_DIR/cache_cmd_${cc}.out"
            "$PROJECT_ROOT/cachectl" "$cc" > "$out" 2>&1 || true
            if grep -Eq 'Cache|TCP_[A-Z_]*HIT|Hit ratio|[0-9]+ ?(KB|MB|GB|bytes)|[0-9]+ objects?' "$out"; then
                ab_pass_with_evidence "cache $cc reports real figures" "$out" || true
                test_result "Cache $cc command reports real figures" "PASS" "evidence: $out"
            else
                test_result "Cache $cc command reports real figures" "FAIL" "cachectl present but no substantive output ($out)"
            fi
        done
    else
        for cc in stats size list; do
            test_result "Cache $cc command (real CLI)" "SKIP" "cachectl absent — restore the cache CLI, tracked #50 (§11.4.124)"
        done
    fi
}

#######################################
# Test: DNS resolution
#######################################
test_dns() {
    test_header "DNS RESOLUTION TESTS"
    
    source "$PROJECT_ROOT/.env" 2>/dev/null || true
    local port="${HTTP_PROXY_PORT:-34128}"
    local dns_url="https://dns.google/resolve?name=google.com"

    # §11.4.6 / §11.4.1 / F1 (BUGFIX-0017): this canary asserts BODY content (a
    # DoH JSON "Answer" field) fetched THROUGH the proxy — NOT an HTTP code — so
    # it cannot use the HTTP-code conn_check wrapper. But the SAME false-FAIL
    # applies: a dns.google OUTAGE (external, not ours) must SKIP, never FAIL a
    # healthy proxy (the old `grep Answer || FAIL` was the exact §11.4.1 bug).
    # Encode "answer present/absent" as synthetic tokens and reuse the
    # proxy_conn_verdict classifier so the semantics match every other canary:
    #   proxy relays a DoH Answer                          -> PASS
    #   proxy no-Answer BUT the SAME query answers DIRECTLY -> FAIL (real proxy
    #     defect — proxy cannot relay a directly-working DoH query; §11.4.68)
    #   proxy no-Answer AND direct no-Answer                -> SKIP
    #     (network_unreachable_external / topology_unsupported — dns.google down,
    #      not a proxy defect; §11.4.3). The content assertion is preserved.
    local proxy_body direct_body proxy_tok direct_tok listen verdict
    proxy_body=$(curl -s --max-time 10 --proxy "http://localhost:$port" "$dns_url" 2>/dev/null || true)
    proxy_tok=MISS
    if echo "$proxy_body" | grep -q "Answer"; then proxy_tok=ANSWER; fi
    if [[ "$proxy_tok" == "ANSWER" ]]; then
        test_result "DNS resolution through proxy" "PASS" "DoH Answer relayed via proxy"
    else
        direct_body=$(curl -s --max-time 10 "$dns_url" 2>/dev/null || true)
        direct_tok=MISS
        if echo "$direct_body" | grep -q "Answer"; then direct_tok=ANSWER; fi
        listen=no
        if port_is_listening "$port"; then listen=yes; fi
        verdict=$(proxy_conn_verdict "$proxy_tok" "$direct_tok" "ANSWER" "$listen")
        case "$verdict" in
            PASS)
                test_result "DNS resolution through proxy" "PASS" "DoH Answer relayed via proxy" ;;
            FAIL)
                test_result "DNS resolution through proxy" "FAIL" \
                    "proxy relayed no DoH Answer but dns.google answers directly — real proxy defect (§11.4.68)" ;;
            SKIP:*)
                ab_skip_with_reason "DNS resolution through proxy (proxy=$proxy_tok direct=$direct_tok)" "${verdict#SKIP:}" || true
                test_result "DNS resolution through proxy" "SKIP" \
                    "dns.google unreachable via proxy AND directly — external outage, not a proxy defect (§11.4.3)" ;;
        esac
    fi
}

#######################################
# Test: Large file download
#######################################
test_large_file() {
    test_header "LARGE FILE DOWNLOAD TESTS"
    
    source "$PROJECT_ROOT/.env" 2>/dev/null || true
    local port="${HTTP_PROXY_PORT:-34128}"
    
    # §11.4.6 root-caused (2026-07-01, captured direct-vs-proxy sizes):
    # httpbin.org/bytes/1048576 now CAPS at ~100KB at the SOURCE
    # (direct==proxy==102400, reproduced for /1048576, /512000, /200000), so the
    # old exact ">1MB" assertion failed on external-endpoint variance, NOT a
    # proxy defect. The real proxy property is FAITHFUL RELAY: bytes through the
    # proxy == bytes fetched DIRECTLY (and > 0). A direct/proxy MISMATCH is a real
    # proxy-truncation defect (kept FAIL + evidence); an unreachable external
    # endpoint → §11.4.3 SKIP (network_unreachable_external).
    local url="https://httpbin.org/bytes/1048576"
    local direct_size proxy_size
    direct_size=$(curl -s --max-time 60 "$url" -o /dev/null -w "%{size_download}" 2>/dev/null || echo "0")
    proxy_size=$(curl -s --max-time 60 --proxy "http://localhost:$port" "$url" -o /dev/null -w "%{size_download}" 2>/dev/null || echo "0")
    local large_evidence="$EVIDENCE_DIR/large_file.evidence"
    printf 'url=%s\ndirect_size=%s\nproxy_size=%s\n' "$url" "$direct_size" "$proxy_size" > "$large_evidence"
    if [[ "$direct_size" -le 0 ]]; then
        ab_skip_with_reason "large file download (faithful relay)" "network_unreachable_external" || true
        test_result "Large file download (proxy relays faithfully)" "SKIP" "direct fetch unreachable (external) — direct=$direct_size"
    elif [[ "$proxy_size" -eq "$direct_size" ]]; then
        ab_pass_with_evidence "proxy relays large download faithfully (proxy==direct)" "$large_evidence" || true
        test_result "Large file download (proxy relays faithfully)" "PASS" "proxy=$proxy_size == direct=$direct_size bytes (evidence: $large_evidence)"
    else
        test_result "Large file download (proxy relays faithfully)" "FAIL" "proxy truncation: proxy=$proxy_size != direct=$direct_size (evidence: $large_evidence)"
    fi
}

#######################################
# Test: Multiple concurrent connections
#######################################
test_concurrent() {
    test_header "CONCURRENT CONNECTION TESTS"
    
    source "$PROJECT_ROOT/.env" 2>/dev/null || true
    local port="${HTTP_PROXY_PORT:-34128}"
    
    echo -e "  ${BLUE}Making 10 concurrent requests...${NC}"

    # §11.4.3: if the endpoint is externally unreachable (a DIRECT host fetch fails),
    # SKIP — a concurrency test against a down upstream measures the outage, not the
    # proxy (same network_unreachable_external gate as test_large_file). A real proxy
    # concurrency defect (endpoint up, proxy drops requests) still FAILs below.
    local concurrent_url="https://httpbin.org/get"
    local cc_direct
    cc_direct=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "$concurrent_url" 2>/dev/null || echo "000")
    if [[ "$cc_direct" != "200" ]]; then
        ab_skip_with_reason "concurrent 10x through proxy" "network_unreachable_external" || true
        test_result "Concurrent connections (10)" "SKIP" \
            "endpoint $concurrent_url unreachable directly (direct=$cc_direct) — external outage, not a proxy defect (§11.4.3)"
        return
    fi

    # §11.4.1 / §11.4.69: the old loop captured each background job's EXIT status
    # via `wait` (which emits no stdout), NEVER the HTTP code — the `-w
    # %{http_code}` output went to a discarded subshell stdout — so the
    # 200-count was always meaningless (success stayed 0). Write each request's
    # real %{http_code} to its OWN file, read it back per request, count real
    # 200s, and cite a captured evidence file. (Also drops the `((success++))` /
    # `((failed++))` §11.4.1 set-e abort form — uses assignment counters.) [audit B3/B4]
    local tmpd
    tmpd=$(mktemp -d)
    local i
    for i in $(seq 1 10); do
        ( curl -s --max-time 30 \
            --proxy "http://localhost:$port" \
            "$concurrent_url" \
            -o /dev/null -w '%{http_code}' > "$tmpd/code.$i" 2>/dev/null ) &
    done
    wait

    local success=0
    local failed=0
    for i in $(seq 1 10); do
        if [[ "$(cat "$tmpd/code.$i" 2>/dev/null)" == "200" ]]; then
            success=$((success + 1))
        else
            failed=$((failed + 1))
        fi
    done

    local concurrent_evidence="$EVIDENCE_DIR/concurrent.evidence"
    {
        printf 'concurrent 10x GET %s through http://localhost:%s\n' "$concurrent_url" "$port"
        printf 'per-request http_code:'
        for i in $(seq 1 10); do printf ' %s' "$(cat "$tmpd/code.$i" 2>/dev/null)"; done
        printf '\nsuccess=%d/10 failed=%d\n' "$success" "$failed"
    } > "$concurrent_evidence"
    rm -rf "$tmpd"

    if [[ $success -ge 8 ]]; then
        ab_pass_with_evidence "concurrent 10x HTTP 200 through proxy" "$concurrent_evidence" || true
        test_result "Concurrent connections (10)" "PASS" "Success: $success, Failed: $failed (evidence: $concurrent_evidence)"
    else
        test_result "Concurrent connections (10)" "FAIL" "Success: $success, Failed: $failed (evidence: $concurrent_evidence)"
    fi
}

#######################################
# Test: Network client simulation
#######################################
test_network_client() {
    test_header "NETWORK CLIENT SIMULATION TESTS"
    
    source "$PROJECT_ROOT/.env" 2>/dev/null || true
    local http_port="${HTTP_PROXY_PORT:-34128}"
    local socks_port="${SOCKS_PROXY_PORT:-34080}"
    
    # Get host IP for network testing.
    # §11.4.1 (same script-internal-abort class as audit B4): `hostname -I` is
    # unsupported on some hosts ("invalid option -- 'I'"); under `set -euo
    # pipefail` the failing pipeline aborts the whole suite one line before the
    # summary. Guard so the EXISTING empty-host_ip SKIP path (below) handles it;
    # behaviour-preserving (empty => SKIP, as already designed). Fall back to a
    # source-IP probe when `hostname -I` is unavailable.
    local host_ip
    host_ip=$(hostname -I 2>/dev/null | awk '{print $1}' || true)
    if [[ -z "$host_ip" ]]; then
        host_ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}' || true)
    fi

    if [[ -z "$host_ip" ]]; then
        test_result "Network client test" "SKIP" "Cannot determine host IP"
        return 0
    fi
    
    echo -e "  ${BLUE}Testing from network IP: $host_ip${NC}"

    # §11.4.1 / F1 (BUGFIX-0017): network-client canaries drive the proxy on the
    # host's real interface IP (not localhost) — pass $host_ip as conn_check's
    # proxy_host. A directly-reachable endpoint the proxy cannot fetch -> FAIL;
    # an external outage -> SKIP; never the old blind `code != expected -> FAIL`.
    # Test HTTP proxy from network
    conn_check "Network client HTTP proxy access" http "$http_port" \
        "http://connectivitycheck.gstatic.com/generate_204" "204 200" "$host_ip"

    # Test SOCKS proxy from network
    conn_check "Network client SOCKS proxy access" socks5 "$socks_port" \
        "http://connectivitycheck.gstatic.com/generate_204" "204 200" "$host_ip"
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
