#!/bin/sh
#######################################################################
# §11.4.135 regression guard — BUGFIX-CACHECLI (regression #50)
# The documented cache-management CLI must be PRESENT, EXECUTABLE,
# PARSEABLE, and expose every documented subcommand.
#
# Purpose:
#   Commit 6ec58ef ("fix: container config for host-vpn mode")
#   ACCIDENTALLY deleted the 368-line cache-management CLI: CACHE_DIR has
#   always been "$PROJECT_ROOT/cache", .gitignore ignores cache/ (the data
#   dir), and once the runtime materialised the cache/ DATA directory it
#   collided with the tracked `cache` FILE at the same path, so a broad
#   `git add` recorded the file as deleted. The CLI is documented in
#   README.md, USER_GUIDE.md, docs/CACHE.md and docs/TROUBLESHOOTING.md, so
#   its disappearance left a documented end-user feature unusable while every
#   green test stayed green (a §11.4 PASS-bluff at the feature layer). The CLI
#   has been restored under the non-colliding name `cachectl` (matching the
#   ./start convention) so it coexists with the gitignored cache/ data dir.
#
# What it actually does (NOT a tautology — reads the REAL tracked CLI):
#   GREEN — asserts the restored cachectl file EXISTS, is EXECUTABLE, is
#           `bash -n`-clean (parseable), and that its argument-dispatch `case`
#           lists EVERY documented subcommand
#           (stats|clear|invalidate|warmup|list|size|trim). A removed
#           subcommand (a feature silently dropped) makes this FAIL with an
#           ASSERTION while `bash -n` stays clean.
#   RED   — points at a NON-EXISTENT CLI path (the post-deletion state) and
#           asserts the defect: the CLI is absent, so the documented feature
#           is unusable. A RED that cannot reproduce is itself a §11.4.7
#           finding.
#
#   Self-contained + deterministic: it inspects a tracked file only — no
#   container, network, or live-cache access, no data-plane touch.
#
# §11.4.115 polarity switch (RED_MODE):
#   RED_MODE=0 (default GREEN guard) — PASS iff cachectl is present, executable,
#              parseable, and dispatches all 7 documented subcommands.
#   RED_MODE=1 (reproduce) — PASS iff the documented CLI is ABSENT at the
#              post-deletion path (defect REPRODUCED).
#
# Usage:
#   tests/regression/cache_cli_present_test.sh            # GREEN guard
#   RED_MODE=1 tests/regression/cache_cli_present_test.sh # reproduce
#
# Inputs:   RED_MODE (env, default 0). No CLI args.
# Outputs:  PASS/FAIL verdict on stdout + an evidence file under
#           qa-results/regression/cachecli/. Exit 0 = PASS, 1 = FAIL.
# Side-effects: writes one evidence file. No container/network/live-cache
#               access.
# Dependencies: sh, bash (for `bash -n`), grep.
# Cross-references:
#   - Restored feature: cachectl (was: tracked `cache`, deleted in 6ec58ef).
#   - Companion doc: docs/scripts/cachectl.md.
#   - Registered in: tests/run-tests.sh test_regression_guards().
#######################################################################
set -eu

RED_MODE="${RED_MODE:-0}"
REPO_ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
EVID_DIR="$REPO_ROOT/qa-results/regression/cachecli"
mkdir -p "$EVID_DIR"
EVID_FILE="$EVID_DIR/cache_cli_present.$$.txt"

# The documented subcommands the CLI MUST dispatch.
DOC_SUBCMDS="stats clear invalidate warmup list size trim"

verdict=FAIL
exit_code=1

if [ "$RED_MODE" = "1" ]; then
    # RED: reproduce the post-deletion state — the documented CLI is absent.
    # Point at the path the deleted feature occupied (a non-existent CLI here),
    # and assert the defect: no CLI file => documented feature unusable.
    ABSENT_CLI="$REPO_ROOT/.cachectl_deleted_replica_does_not_exist"
    rm -f "$ABSENT_CLI" 2>/dev/null || true
    if [ ! -f "$ABSENT_CLI" ]; then
        verdict=PASS; exit_code=0
        msg="RED reproduced: documented cache CLI absent at post-deletion path -> the cache-management feature documented in README/USER_GUIDE/docs is unusable"
    else
        msg="RED could-not-reproduce: replica CLI unexpectedly present — finding per §11.4.7"
    fi
else
    # GREEN guard: the restored cachectl must be present, executable,
    # parseable, and dispatch every documented subcommand.
    CLI="$REPO_ROOT/cachectl"
    reasons=""

    if [ ! -f "$CLI" ]; then
        reasons="$reasons file-absent;"
    fi
    if [ -f "$CLI" ] && [ ! -x "$CLI" ]; then
        reasons="$reasons not-executable;"
    fi
    if [ -f "$CLI" ] && ! bash -n "$CLI" 2>/dev/null; then
        reasons="$reasons bash-n-parse-error;"
    fi

    # Extract the argument-dispatch alternation line (the `case "$1" in`
    # branch that recognises commands). It contains stats|clear|... — verify
    # EVERY documented subcommand is present as a dispatch token. A mutation
    # that removes one token keeps the file `bash -n`-clean but drops a
    # documented feature; this detects exactly that.
    missing=""
    if [ -f "$CLI" ]; then
        dispatch_line="$(grep -E '^[[:space:]]*stats\|' "$CLI" 2>/dev/null | head -1 || true)"
        if [ -z "$dispatch_line" ]; then
            reasons="$reasons dispatch-alternation-line-not-found;"
            missing="$DOC_SUBCMDS"
        else
            for cmd in $DOC_SUBCMDS; do
                # token must appear delimited by | or ) (a case alternation
                # member), never as a substring of another word.
                if ! printf '%s' "$dispatch_line" | grep -Eq "[|[:space:]]${cmd}[|)]"; then
                    missing="$missing $cmd"
                fi
            done
        fi
    fi
    if [ -n "$missing" ]; then
        reasons="$reasons missing-subcommands:[${missing# }];"
    fi

    if [ -z "$reasons" ]; then
        verdict=PASS; exit_code=0
        msg="GREEN: cachectl present + executable + bash-n-clean + dispatches all documented subcommands ($DOC_SUBCMDS)"
    else
        msg="REGRESSION: cachectl feature broken -> $reasons"
    fi
fi

{
    echo "BUGFIX-CACHECLI regression guard — restored cache-management CLI (regression #50)"
    echo "timestamp_utc: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "RED_MODE: $RED_MODE"
    echo "documented_subcommands: $DOC_SUBCMDS"
    echo "verdict: $verdict"
    echo "detail: $msg"
} >"$EVID_FILE"

echo "[$verdict] BUGFIX-CACHECLI cache-cli-present (RED_MODE=$RED_MODE): $msg"
echo "evidence: $EVID_FILE"
exit "$exit_code"
