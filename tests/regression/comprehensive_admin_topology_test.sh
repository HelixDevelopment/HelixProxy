#!/bin/sh
#######################################################################
# §11.4.135 regression guard — comprehensive-test.sh admin/port fail-open bluff
# (P12 full-retest finding 2)
#
# Purpose:
#   Prove tests/comprehensive-test.sh NEVER reports a PASS for a host port that
#   is held by a NON-project process. Pre-fix, test_ports/test_admin did
#   `ss -tuln | grep :PORT -> PASS` (and curled :PORT asserting HTTP 200), so a
#   foreign `whoami` listening on :34088 (which answers 200 to ANY path and even
#   echoes `Hostname: proxy-admin`) produced 3 FALSE PASSes — a §11.4.68/§11.4.69
#   fail-open-to-whatever-answers bluff. The fix gates on PROJECT-container
#   ownership (`podman port <owner> | grep :PORT`): a port that is listening but
#   NOT published by the owning project container is a SKIP, never a PASS.
#
# What it actually does (NOT a grep — exercises the REAL decision code):
#   GREEN — extracts the REAL `_port_topology_check()` from comprehensive-test.sh
#           and drives the fail-open scenario (owner NOT publishing the port, a
#           foreign process listening on it) with stubbed container/runtime/ss,
#           asserting the verdict is SKIP (the bluff is REFUSED), plus the healthy
#           owner-publishes+listening case -> PASS.
#   RED   — runs a faithful PRE-FIX replica (`listening => PASS`) against the SAME
#           foreign-listener scenario and asserts it returns PASS (bluff
#           REPRODUCED). A RED that cannot reproduce is itself a §11.4.7 finding.
#
#   Self-contained + deterministic: tests the decision function with stubs, so it
#   does NOT depend on live podman/ss state and never touches the data plane.
#
# §11.4.115 polarity switch (RED_MODE):
#   RED_MODE=0 (default GREEN guard) — PASS iff the REAL _port_topology_check
#              SKIPs the foreign-listener scenario AND PASSes the owned scenario.
#   RED_MODE=1 (reproduce) — PASS iff the pre-fix replica PASSes the foreign
#              scenario (fail-open bluff REPRODUCED).
#
# Usage:
#   tests/regression/comprehensive_admin_topology_test.sh            # GREEN guard
#   RED_MODE=1 tests/regression/comprehensive_admin_topology_test.sh # reproduce
#
# Inputs:   RED_MODE (env, default 0). No CLI args.
# Outputs:  PASS/FAIL verdict on stdout + evidence under
#           qa-results/regression/comprehensive_admin_topology/. Exit 0=PASS,1=FAIL.
# Dependencies: bash (extracted fn uses [[ ]]), awk, mktemp.
# Cross-references:
#   - Fix: tests/comprehensive-test.sh _port_topology_check()/test_ports()/test_admin().
#   - Sibling guard: tests/regression/port_topology_aware_test.sh (run-tests.sh).
#######################################################################
set -eu

RED_MODE="${RED_MODE:-0}"
REPO_ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
EVID_DIR="$REPO_ROOT/qa-results/regression/comprehensive_admin_topology"
mkdir -p "$EVID_DIR"
EVID_FILE="$EVID_DIR/comprehensive_admin_topology.$$.txt"

PROBE="$(mktemp)"
trap 'rm -f "$PROBE"' EXIT INT TERM

{
    echo 'set -u'
    # Verdict sink + stubs. Scenario = a foreign process is LISTENING on :34088
    # while the project's proxy-admin container is running but publishes NO port
    # (podman port prints nothing) — the exact live situation the retest hit.
    echo 'VERDICT=""; DETAIL=""'
    echo 'test_result() { VERDICT="$2"; DETAIL="${3:-}"; }'
    echo 'get_runtime() { echo podman; }'
    echo 'container_running() { return 0; }'          # owner container running
    echo 'podman() { :; }'                            # `podman port <owner>` -> empty (publishes nothing)
    echo 'ss() { printf "%s\n" "tcp LISTEN 0 4096 *:34088 *:* users:((\"whoami\",pid=1,fd=3))"; }'

    if [ "$RED_MODE" = "1" ]; then
        # Faithful PRE-FIX replica: PASS iff ANYTHING is listening (fail-open).
        printf '%s\n' \
            '_port_topology_check() {' \
            '    port="$1"' \
            '    if ss -tuln | grep -q ":${port} "; then test_result "x" "PASS"; else test_result "x" "SKIP" "Optional"; fi' \
            '}' \
            '_port_topology_check 34088 proxy-admin "Admin port"' \
            'echo "FOREIGN_VERDICT=$VERDICT"'
    else
        # Extract the REAL, current _port_topology_check from the tracked suite.
        awk '/^_port_topology_check\(\) \{/{f=1} f{print} /^\}/{if(f){exit}}' \
            "$REPO_ROOT/tests/comprehensive-test.sh"
        # (a) foreign-listener scenario -> expect SKIP (bluff refused)
        printf '%s\n' '_port_topology_check 34088 proxy-admin "Admin port"' \
            'echo "FOREIGN_VERDICT=$VERDICT"'
        # (b) healthy owned scenario -> expect PASS. Re-stub podman to publish :34128.
        printf '%s\n' \
            'podman() { echo "34128/tcp -> 0.0.0.0:34128"; }' \
            'ss() { printf "%s\n" "tcp LISTEN 0 4096 *:34128 *:* users:((\"rootlessport\",pid=2,fd=10))"; }' \
            '_port_topology_check 34128 proxy-squid "HTTP proxy port"' \
            'echo "OWNED_VERDICT=$VERDICT"'
    fi
} >"$PROBE"

probe_out="$(bash "$PROBE" 2>&1)" && probe_rc=0 || probe_rc=$?

verdict=FAIL
exit_code=1
if [ "$RED_MODE" = "1" ]; then
    case "$probe_out" in
        *FOREIGN_VERDICT=PASS*)
            verdict=PASS; exit_code=0
            msg="RED reproduced: pre-fix logic PASSes a port held by a NON-project process (fail-open bluff), rc=$probe_rc"
            ;;
        *)
            msg="RED could-not-reproduce: pre-fix replica did not PASS the foreign-listener scenario (out=$probe_out, rc=$probe_rc) — finding per 11.4.7"
            ;;
    esac
else
    case "$probe_out" in
        *FOREIGN_VERDICT=SKIP*OWNED_VERDICT=PASS*)
            verdict=PASS; exit_code=0
            msg="GREEN: real _port_topology_check SKIPs a non-project-held port (bluff refused) AND PASSes an owner-published+listening port"
            ;;
        *)
            msg="REGRESSION: _port_topology_check verdicts wrong (out=$probe_out, rc=$probe_rc) — admin/port fail-open bluff reintroduced OR owned-port no longer PASSes"
            ;;
    esac
fi

{
    echo "comprehensive-test admin/port topology regression guard — §11.4.68/§11.4.69"
    echo "timestamp_utc: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "RED_MODE: $RED_MODE"
    echo "probe_rc: $probe_rc"
    echo "probe_out: $probe_out"
    echo "verdict: $verdict"
    echo "detail: $msg"
} >"$EVID_FILE"

echo "[$verdict] comprehensive-admin-topology (RED_MODE=$RED_MODE): $msg"
echo "evidence: $EVID_FILE"
exit "$exit_code"
