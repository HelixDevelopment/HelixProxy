#!/bin/sh
#######################################################################
# §11.4.135 regression guard — BUGFIX #38
# rootless-Podman squid log-dir writability (proxy crash-loop)
#
# Purpose:
#   Prove the orchestrator creates the squid LOG_DIR world-writable, so the
#   squid container's non-root `proxy` user (remapped to a high subuid under
#   rootless Podman) can write /var/log/squid/access.log. Without it squid
#   FATALs ("Cannot open '/var/log/squid/access.log' for writing") and
#   crash-loops, so the proxy never serves a single request.
#
# What it actually does (NOT a grep — exercises real orchestrator code):
#   Sources lib/container-runtime.sh with env pointed at a throwaway temp root,
#   calls the REAL create_directories(), then stats the resulting LOG_DIR and
#   asserts the world-write bit is set.
#
# §11.4.115 polarity switch (RED_MODE):
#   RED_MODE=0 (default, the standing GREEN guard) — run the REAL fixed code;
#              PASS iff LOG_DIR is world-writable (defect ABSENT).
#   RED_MODE=1 (reproduce-on-broken) — replicate the PRE-FIX behaviour (mkdir
#              the log dir WITHOUT the chmod the fix adds); PASS iff the dir is
#              NOT world-writable (defect REPRODUCED). A RED that cannot
#              reproduce is itself a finding (§11.4.7).
#
# Usage:
#   tests/regression/log_dir_writable_test.sh            # GREEN guard
#   RED_MODE=1 tests/regression/log_dir_writable_test.sh # reproduce the defect
#
# Inputs:   RED_MODE (env, default 0). No CLI args.
# Outputs:  PASS/FAIL verdict on stdout + a captured-evidence file under
#           qa-results/regression/bugfix38/. Exit 0 = PASS, 1 = FAIL.
# Side-effects: creates+removes a mktemp dir; writes one evidence file.
# Dependencies: bash (to source the bash-only lib), GNU stat, mktemp.
#               Linux-only — the rootless-Podman bind-mount UID-shift this
#               guards is a Linux/subuid mechanism (§11.4.81 honest scope).
# Cross-references:
#   - Fix: lib/container-runtime.sh create_directories(); start init_cache().
#   - BUGFIX log: docs/issues/fixed/BUGFIXES.md (#38).
#######################################################################
set -eu

RED_MODE="${RED_MODE:-0}"

REPO_ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
EVID_DIR="$REPO_ROOT/qa-results/regression/bugfix38"
mkdir -p "$EVID_DIR"
EVID_FILE="$EVID_DIR/log_dir_writable.$$.txt"

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT INT TERM
LOG_DIR="$TMP_ROOT/logs"

if [ "$RED_MODE" = "1" ]; then
    # Reproduce the PRE-FIX behaviour: create the log dir WITHOUT the chmod the
    # fix adds (this is exactly what create_directories did before BUGFIX #38).
    mkdir -p "$LOG_DIR"
else
    # Exercise the REAL orchestrator dir-init (the fix). The lib is bash-only
    # (set -euo pipefail, readonly, BASH_SOURCE), so source it inside an explicit
    # bash subshell — the outer /bin/sh parser sees only a string (§11.4.67).
    bash -c '
        set -euo pipefail
        export SCRIPT_DIR="'"$TMP_ROOT"'"
        export PROJECT_ROOT="'"$TMP_ROOT"'"
        export CACHE_DIR="'"$TMP_ROOT"'/cache"
        export LOG_DIR="'"$TMP_ROOT"'/logs"
        export USE_VPN=false
        # shellcheck disable=SC1090
        source "'"$REPO_ROOT"'/lib/container-runtime.sh"
        log() { :; }   # neutralise the lib logger (defined after source so it wins)
        create_directories
    '
fi

mode="$(stat -c '%a' "$LOG_DIR" 2>/dev/null || echo '000')"
# World-write bit = the last octal digit has the 2-bit set (2,3,6,7).
last="$(printf '%s' "$mode" | tail -c 1)"
world_writable=no
case "$last" in
    2 | 3 | 6 | 7) world_writable=yes ;;
esac

verdict=FAIL
exit_code=1
if [ "$RED_MODE" = "1" ]; then
    # RED: PASS iff defect reproduced (dir NOT world-writable).
    if [ "$world_writable" = "no" ]; then
        verdict=PASS
        exit_code=0
        msg="RED reproduced: pre-fix LOG_DIR mode=$mode is NOT world-writable (squid proxy user cannot write access.log -> crash-loop)"
    else
        msg="RED could-not-reproduce: LOG_DIR mode=$mode already world-writable without the fix (finding per 11.4.7)"
    fi
else
    # GREEN guard: PASS iff the real orchestrator made the dir world-writable.
    if [ "$world_writable" = "yes" ]; then
        verdict=PASS
        exit_code=0
        msg="GREEN: create_directories() made LOG_DIR mode=$mode world-writable (squid proxy user can write access.log)"
    else
        msg="REGRESSION: create_directories() left LOG_DIR mode=$mode NOT world-writable (BUGFIX #38 reverted/missing -> proxy will crash-loop)"
    fi
fi

{
    echo "BUGFIX #38 regression guard — rootless-Podman squid log-dir writability"
    echo "timestamp_utc: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "RED_MODE: $RED_MODE"
    echo "LOG_DIR_mode: $mode"
    echo "world_writable: $world_writable"
    echo "verdict: $verdict"
    echo "detail: $msg"
} >"$EVID_FILE"

echo "[$verdict] BUGFIX#38 log-dir-writable (RED_MODE=$RED_MODE): $msg"
echo "evidence: $EVID_FILE"
exit "$exit_code"
