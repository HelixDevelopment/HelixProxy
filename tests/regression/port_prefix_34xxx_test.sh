#!/bin/sh
#######################################################################
# §11.4.135 regression guard — BUGFIX-PORTS-34XXX
# Host-exposed proxy ports re-prefixed to the operator-mandated 34XXX scheme.
#
# Purpose:
#   Prove the canonical BEHAVIOR files carry the 34XXX ports and that NO old
#   5XXXX proxy port ever leaks back into the behavior scope. The operator
#   mandated the collision-free re-prefix:
#       HTTP proxy (Squid)   53128 -> 34128
#       SOCKS5   (Dante)     51080 -> 34080
#       Admin / Control-API  58080 -> 34088
#       Metrics  (Prometheus)59090 -> 34090
#   A stray 5XXXX in a config/compose/source/test file would silently bind or
#   probe the OLD port — the service would come up on a port nothing routes to
#   (a §11.4.108 SOURCE/ARTIFACT mismatch that a grep-of-one-file misses).
#
# What it actually does (NOT a single-file grep — scans the whole behavior
# scope AND asserts the positive presence of each new port on its owning
# canonical file, i.e. proves the re-prefix is BOTH complete AND landed):
#   GREEN — (a) ZERO occurrence of any old 5XXXX proxy port across the tracked
#           behavior scope (config non-doc, compose, runtime scripts, admin UI,
#           control-plane, tests, helixqa banks); AND (b) each new port is
#           present on its canonical anchor (squid.conf:34128, sockd.conf:34080,
#           .env.example:{34128,34080,34088,34090}, docker-compose admin :34088,
#           prometheus.yml:34090, control-plane DefaultProxy:34128).
#   RED   — synthesizes a faithful PRE-FIX fixture (a squid http_port line on
#           :53128) and runs the SAME old-port scanner over it, asserting the
#           scanner DETECTS the 5XXXX leak (defect reproduced). A RED that
#           cannot reproduce is itself a §11.4.7 finding — it would prove the
#           GREEN zero-leak assertion is a tautology.
#
#   Self-contained + deterministic: uses `git grep` over the tracked tree +
#   a throwaway temp fixture; never touches the data plane or any container.
#
# §11.4.115 polarity switch (RED_MODE):
#   RED_MODE=0 (default GREEN guard) — PASS iff zero old-port leaks AND every
#              new-port anchor present.
#   RED_MODE=1 (reproduce) — PASS iff the old-port scanner flags a re-introduced
#              5XXXX port (regression genuinely caught).
#
# Usage:
#   tests/regression/port_prefix_34xxx_test.sh            # GREEN guard
#   RED_MODE=1 tests/regression/port_prefix_34xxx_test.sh # reproduce
#
# Inputs:   RED_MODE (env, default 0). No CLI args.
# Outputs:  PASS/FAIL verdict on stdout + an evidence file under
#           qa-results/regression/port_prefix_34xxx/. Exit 0 = PASS, 1 = FAIL.
# Side-effects: writes one temp fixture (removed on exit) + one evidence file.
#               No container/network access.
# Dependencies: git, grep, mktemp.
# Cross-references:
#   - Fix: .env.example / config/squid|dante|prometheus / docker-compose*.yml /
#     control-plane PAC + control-API defaults / runtime scripts / helixqa banks.
#   - Sibling guards: tests/regression/port_topology_aware_test.sh,
#     tests/regression/comprehensive_admin_topology_test.sh.
#######################################################################
set -eu

RED_MODE="${RED_MODE:-0}"
REPO_ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
EVID_DIR="$REPO_ROOT/qa-results/regression/port_prefix_34xxx"
mkdir -p "$EVID_DIR"
EVID_FILE="$EVID_DIR/port_prefix_34xxx.$$.txt"

# Old 5XXXX proxy ports that MUST NOT reappear in the behavior scope.
OLD_PORTS_RE='\b(53128|51080|58080|59090)\b'

# The tracked behavior scope (docs .md/.html/.pdf excluded — another agent owns
# docs; services/admin/index.html IS behavior UI and stays in scope).
scan_old_ports() {
    # Args: $1 = root to scan (git-tracked). Prints matching lines; exits 0
    # regardless (caller inspects the captured output, not the rc).
    git -C "$1" grep -nE "$OLD_PORTS_RE" -- \
        '.env.example' 'config' \
        'docker-compose.yml' 'docker-compose.dynamic.yml' \
        'docker-compose.observability.yml' \
        'deploy/observability/compose.metrics.yml' \
        'start' 'stop' 'init' 'status' 'restart' 'lib/container-runtime.sh' \
        'services/admin/index.html' 'control-plane' 'tests' 'tools/helixqa/banks' \
        2>/dev/null \
        | grep -vE '\.(md|pdf):' \
        | grep -vE '/README\.md:|/README\.html:|DNS_LEAK_TEST\.md:|squid-exporter\.md:|config/security/README\.html:' \
        | grep -v 'tests/regression/port_prefix_34xxx_test\.sh:' \
        || true
}

verdict=FAIL
exit_code=1

if [ "$RED_MODE" = "1" ]; then
    # Faithful PRE-FIX replica: a throwaway git tree whose squid config still
    # binds :53128. The SAME scanner MUST flag it, proving the detector is not
    # a tautology.
    FIX_DIR="$(mktemp -d)"
    trap 'rm -rf "$FIX_DIR"' EXIT INT TERM
    mkdir -p "$FIX_DIR/config/squid"
    printf 'http_port 0.0.0.0:53128\n' > "$FIX_DIR/config/squid/squid.conf"
    ( cd "$FIX_DIR" && git init -q && git add -A && git -c user.email=g@g -c user.name=g commit -qm x ) >/dev/null 2>&1
    red_hits="$(scan_old_ports "$FIX_DIR")"
    red_n="$(printf '%s' "$red_hits" | grep -c . || true)"
    if [ "$red_n" -gt 0 ]; then
        verdict=PASS; exit_code=0
        msg="RED reproduced: old-port scanner DETECTS a re-introduced 5XXXX (:53128) leak ($red_n hit) — detector is genuine, not a tautology"
    else
        msg="RED could-not-reproduce: scanner missed a planted :53128 leak — finding per §11.4.7 (GREEN zero-leak would be a bluff)"
    fi
    scan_report="$red_hits"
else
    # GREEN: (a) zero old-port leaks across the real tracked behavior scope.
    leaks="$(scan_old_ports "$REPO_ROOT")"
    n_leaks="$(printf '%s' "$leaks" | grep -c . || true)"

    # (b) each new port present on its canonical anchor.
    anchors_ok=yes
    anchor_detail=""
    check_anchor() { # $1 file  $2 fixed-grep-pattern  $3 label
        if git -C "$REPO_ROOT" grep -qF "$2" -- "$1"; then
            anchor_detail="${anchor_detail}OK  $3\n"
        else
            anchors_ok=no
            anchor_detail="${anchor_detail}MISS $3 (expected '$2' in $1)\n"
        fi
    }
    check_anchor 'config/squid/squid.conf'              'http_port 0.0.0.0:34128'          'squid http_port 34128'
    check_anchor 'config/dante/sockd.conf'              'port = 34080'                     'dante internal 34080'
    check_anchor '.env.example'                         'HTTP_PROXY_PORT=34128'            'env HTTP_PROXY_PORT 34128'
    check_anchor '.env.example'                         'SOCKS_PROXY_PORT=34080'           'env SOCKS_PROXY_PORT 34080'
    check_anchor '.env.example'                         'PROXY_ADMIN_PORT=34088'           'env PROXY_ADMIN_PORT 34088'
    check_anchor '.env.example'                         'CONTROL_API_ADDR=:34088'          'env CONTROL_API_ADDR :34088'
    check_anchor '.env.example'                         'METRICS_PORT=34090'               'env METRICS_PORT 34090'
    check_anchor 'docker-compose.yml'                   '"-port", "34088"'                 'compose admin -port 34088'
    check_anchor 'config/prometheus/prometheus.yml'     'proxy-control-plane:34090'        'prometheus scrape 34090'
    check_anchor 'control-plane/internal/pac/generate.go' 'PROXY proxy-squid:34128'        'PAC DefaultProxy 34128'
    check_anchor 'control-plane/cmd/api/main.go'        'CONTROL_API_ADDR", ":34088"'      'control-API default :34088'

    if [ "$n_leaks" -eq 0 ] && [ "$anchors_ok" = yes ]; then
        verdict=PASS; exit_code=0
        msg="GREEN: zero old 5XXXX proxy-port leaks in behavior scope AND every 34XXX anchor present"
    elif [ "$n_leaks" -ne 0 ]; then
        msg="REGRESSION: $n_leaks old 5XXXX proxy-port leak(s) re-appeared in behavior scope — see scan_report"
    else
        msg="REGRESSION: a 34XXX new-port anchor is missing — the re-prefix is incomplete (see anchors)"
    fi
    scan_report="$leaks"
fi

{
    echo "BUGFIX-PORTS-34XXX regression guard — §11.4.135 + §11.4.115 (host-port re-prefix)"
    echo "timestamp_utc: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "RED_MODE: $RED_MODE"
    echo "mapping: 53128->34128  51080->34080  58080->34088  59090->34090"
    echo "verdict: $verdict"
    echo "detail: $msg"
    if [ "$RED_MODE" != "1" ]; then
        echo "--- anchors ---"
        printf '%b' "${anchor_detail:-}"
    fi
    echo "--- old-port scan output (empty on GREEN, one planted hit on RED) ---"
    printf '%s\n' "${scan_report:-}"
} >"$EVID_FILE"

echo "[$verdict] BUGFIX-PORTS-34XXX host-port re-prefix (RED_MODE=$RED_MODE): $msg"
echo "evidence: $EVID_FILE"
exit "$exit_code"
