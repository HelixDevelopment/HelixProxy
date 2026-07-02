#!/bin/sh
#######################################################################
# §11.4.135 regression guard — BUGFIX-PORTS
# tests/run-tests.sh port check must be §11.4.3 topology-aware
#
# Purpose:
#   Prove the suite never reports a HEALTHY, serving proxy port as a
#   FAILURE. The pre-fix test_ports treated ANY port that was IN USE as
#   FAIL — so the running proxy's own listening ports (squid 34128,
#   dante 34080) were reported as failures and the whole suite exited 1
#   against a perfectly healthy serving proxy (a §11.4.1 false-FAIL, as
#   forbidden as a false-PASS).
#
# What it actually does (NOT a grep — exercises the REAL decision code):
#   GREEN — extracts the REAL `port_verdict()` from tests/run-tests.sh and
#           drives the full topology truth-table, asserting the healthy
#           "owner serving + port listening" case returns PASS (defect
#           ABSENT), plus the FAIL / pre-start-free / pre-start-busy cells.
#   RED   — runs a faithful PRE-FIX replica (old logic: listening => FAIL)
#           against the SAME healthy scenario and asserts it returns FAIL
#           (the bluff REPRODUCED). A RED that cannot reproduce is itself a
#           §11.4.7 finding.
#
#   This is self-contained + deterministic: it tests the PURE decision
#   function, so it does NOT depend on live podman/ss state and never
#   touches the data plane or any container.
#
# §11.4.115 polarity switch (RED_MODE):
#   RED_MODE=0 (default GREEN guard) — PASS iff the REAL port_verdict yields
#              the honest truth-table (HEALTHY=PASS, defect ABSENT).
#   RED_MODE=1 (reproduce) — PASS iff the pre-fix replica classifies the
#              healthy serving port as FAIL (defect REPRODUCED).
#
# Usage:
#   tests/regression/port_topology_aware_test.sh            # GREEN guard
#   RED_MODE=1 tests/regression/port_topology_aware_test.sh # reproduce
#
# Inputs:   RED_MODE (env, default 0). No CLI args.
# Outputs:  PASS/FAIL verdict on stdout + an evidence file under
#           qa-results/regression/portstopology/. Exit 0 = PASS, 1 = FAIL.
# Side-effects: writes one temp probe script (removed on exit) + one
#               evidence file. No container/network access.
# Dependencies: bash (port_verdict uses bash `local`), awk, mktemp.
# Cross-references:
#   - Fix: tests/run-tests.sh port_verdict() + test_ports()/_ports_check_one().
#   - Bluff audit: docs/research/existing_test_bluffs_audit/README.md.
#######################################################################
set -eu

RED_MODE="${RED_MODE:-0}"
REPO_ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
EVID_DIR="$REPO_ROOT/qa-results/regression/portstopology"
mkdir -p "$EVID_DIR"
EVID_FILE="$EVID_DIR/port_topology_aware.$$.txt"

PROBE="$(mktemp)"
trap 'rm -f "$PROBE"' EXIT INT TERM

{
    echo 'set -euo pipefail'
    if [ "$RED_MODE" = "1" ]; then
        # Faithful PRE-FIX replica: the old loop reported a port that is IN USE
        # (listening) as FAIL, ignoring whether its owner proxy service is
        # running+serving it. Feed the HEALTHY scenario (owner serving + port
        # listening) and capture the (bluff) verdict.
        printf '%s\n' \
            'old_port_verdict() {' \
            '    # old code: listening => "Port in use" => FAIL; free => PASS' \
            '    local listening="$2"' \
            '    if [[ "$listening" == "yes" ]]; then echo "FAIL"; else echo "PASS"; fi' \
            '}' \
            'v="$(old_port_verdict yes yes)"   # owner serving + listening = healthy serving proxy' \
            'echo "VERDICT=$v"'
    else
        # Extract the REAL, current port_verdict from the tracked suite and
        # exercise the full topology truth-table.
        awk '/^port_verdict\(\) \{/{f=1} f{print} /^\}/{if(f){exit}}' \
            "$REPO_ROOT/tests/run-tests.sh"
        printf '%s\n' \
            'healthy="$(port_verdict yes yes)"        # owner serving + listening    -> PASS' \
            'notserving="$(port_verdict yes no)"      # owner serving + not listening -> FAIL' \
            'prestart_free="$(port_verdict no no)"    # pre-start + free              -> PASS' \
            'prestart_busy="$(port_verdict no yes)"   # pre-start + occupied          -> SKIP' \
            'echo "HEALTHY=$healthy NOTSERVING=$notserving PRESTART_FREE=$prestart_free PRESTART_BUSY=$prestart_busy"'
    fi
} >"$PROBE"

probe_out="$(bash "$PROBE" 2>&1)" && probe_rc=0 || probe_rc=$?

verdict=FAIL
exit_code=1
if [ "$RED_MODE" = "1" ]; then
    # RED: PASS iff defect reproduced — the pre-fix replica classifies a
    # healthy serving port (owner up + listening) as FAIL.
    case "$probe_out" in
        *VERDICT=FAIL*)
            verdict=PASS; exit_code=0
            msg="RED reproduced: pre-fix logic classifies a healthy serving proxy port (owner up + listening) as FAIL (rc=$probe_rc)"
            ;;
        *)
            msg="RED could-not-reproduce: pre-fix replica did not FAIL the healthy port (out=$probe_out, rc=$probe_rc) — finding per 11.4.7"
            ;;
    esac
else
    # GREEN guard: PASS iff the REAL port_verdict yields the honest truth-table,
    # crucially HEALTHY=PASS (a serving port is NOT a failure).
    case "$probe_out" in
        *"HEALTHY=PASS NOTSERVING=FAIL PRESTART_FREE=PASS PRESTART_BUSY=SKIP"*)
            verdict=PASS; exit_code=0
            msg="GREEN: real port_verdict honest — healthy serving port=PASS (not FAIL), owner-up-not-listening=FAIL, pre-start-free=PASS, pre-start-busy=SKIP"
            ;;
        *)
            msg="REGRESSION: real port_verdict truth-table wrong (out=$probe_out, rc=$probe_rc) — topology-aware port check reverted"
            ;;
    esac
fi

{
    echo "BUGFIX-PORTS regression guard — §11.4.3 topology-aware port classification"
    echo "timestamp_utc: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "RED_MODE: $RED_MODE"
    echo "probe_rc: $probe_rc"
    echo "probe_out: $probe_out"
    echo "verdict: $verdict"
    echo "detail: $msg"
} >"$EVID_FILE"

echo "[$verdict] BUGFIX-PORTS topology-aware-port (RED_MODE=$RED_MODE): $msg"
echo "evidence: $EVID_FILE"
exit "$exit_code"
