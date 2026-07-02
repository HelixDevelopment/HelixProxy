#!/bin/sh
#######################################################################
# §11.4.135 regression guard — memory_soak degenerate-final-sample honesty
# (task #75; dynamic-audit ac3f1c89; §11.4.6 / §11.4.69 / §11.4.107(10)).
#
# Purpose:
#   Prove the memory-soak bounded-growth verdict can NEVER score a sampler that
#   DIED mid-soak as a "bounded working set" PASS.
#
#   F-D (absence-as-evidence): base>0 blocks an all-empty series, but if
#       HELIX_MEM_RSS_CMD yields a valid first sample then empty/0 later
#       (rss=${rss:-0} -> last=0), growth = (0-base)*100/base = -100%, which
#       satisfies "growth <= GROWTH_PCT" -> PASS "bounded (growth=-100%)".
#       A sampler that dies mid-soak was scored as bounded. Fix:
#       mem_soak_classify() rejects a degenerate final sample (last<=0) with a
#       valid baseline -> honest SKIP (sampler failed mid-soak), NEVER a PASS.
#
# What it actually does (drives the REAL mem_soak_classify function — no
# divergent copy, §11.4.107(10)); hermetic, no live stack, no soak:
#   - REAL fix logic: mem_soak_classify, obtained by sourcing
#     tests/dynamic/suites/memory_soak_suite.sh with MEMSOAK_SOURCE_ONLY=1
#     (functions only, no soak, no side effects).
#
# §11.4.115 polarity switch (RED_MODE):
#   RED_MODE=1 (reproduce) — PASS iff the DEFECT reproduces: the faithful pre-fix
#       one-liner ([ base>0 ] && [ grow<=GROWTH_PCT ]) scores the degenerate
#       series (base=100 last=0 grow=-100) as a bounded PASS.
#   RED_MODE=0 (default GREEN guard) — PASS iff the FIX holds:
#       * degenerate final sample (base=100 last=0 grow=-100)  -> SKIP;
#       * valid bounded series      (base=100 last=110 grow=10) -> PASS;
#       * unbounded growth          (base=100 last=200 grow=100)-> FAIL.
#
# Usage:
#   tests/regression/memory_soak_degenerate_sample_test.sh            # GREEN guard
#   RED_MODE=1 tests/regression/memory_soak_degenerate_sample_test.sh # reproduce
#
# Inputs:   RED_MODE (env, default 0). No CLI args.
# Outputs:  [PASS]/[FAIL] line on stdout + evidence under
#           qa-results/regression/memory_soak_degenerate_sample/. Exit 0=PASS,1=FAIL.
# Dependencies: sh (POSIX).
# Cross-references:
#   - Fix: tests/dynamic/suites/memory_soak_suite.sh mem_soak_classify() +
#     the GREEN verdict body (degenerate-final-sample SKIP branch).
# Shell: POSIX-clean (sh -n + bash -n, §11.4.67).
#######################################################################
set -eu

RED_MODE="${RED_MODE:-0}"
REPO_ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
TARGET_SCRIPT="$REPO_ROOT/tests/dynamic/suites/memory_soak_suite.sh"
EVID_DIR="$REPO_ROOT/qa-results/regression/memory_soak_degenerate_sample"
mkdir -p "$EVID_DIR"
EVID_FILE="$EVID_DIR/memory_soak_degenerate_sample.$$.txt"

# analyzer_common.sh first, then the suite functions-only (its $0-based DIR would
# otherwise misresolve; the suite skips re-sourcing when dyn_red_mode is defined).
. "$REPO_ROOT/tests/dynamic/lib/analyzer_common.sh"
MEMSOAK_SOURCE_ONLY=1 . "$TARGET_SCRIPT"

GROWTH_PCT=20

# Fixture triple: degenerate-final / valid-bounded / unbounded.
DG_BASE=100; DG_LAST=0;   DG_GROW=-100   # sampler died mid-soak
OK_BASE=100; OK_LAST=110; OK_GROW=10     # real bounded working set
UB_BASE=100; UB_LAST=200; UB_GROW=100    # real leak (unbounded)

verdict=FAIL
exit_code=1
{
    echo "memory_soak degenerate-final-sample honesty guard — §11.4.6/§11.4.69/§11.4.107(10)"
    echo "timestamp_utc: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "RED_MODE: $RED_MODE   growth_pct<=$GROWTH_PCT"
} >"$EVID_FILE"

if [ "$RED_MODE" = "1" ]; then
    # --- Reproduce the DEFECT via the faithful pre-fix one-liner. ---
    # Pre-fix: [ base -gt 0 ] && [ grow -le GROWTH_PCT ] -> bounded PASS.
    prefix_pass=0
    if [ "$DG_BASE" -gt 0 ] && [ "$DG_GROW" -le "$GROWTH_PCT" ]; then
        prefix_pass=1
    fi
    {
        echo "pre-fix degenerate verdict (base=$DG_BASE last=$DG_LAST grow=$DG_GROW): bounded_PASS=$prefix_pass"
    } >>"$EVID_FILE"
    if [ "$prefix_pass" -eq 1 ]; then
        verdict=PASS; exit_code=0
        msg="RED reproduced: pre-fix scored a degenerate final sample (last=0, growth=-100%) as a bounded PASS"
    else
        msg="RED could-not-reproduce: pre-fix one-liner did not PASS the degenerate series — §11.4.7 finding"
    fi
else
    # --- Assert the FIX holds through the REAL mem_soak_classify. ---
    dg_cls="$(mem_soak_classify "$DG_BASE" "$DG_LAST" "$DG_GROW" "$GROWTH_PCT")"
    ok_cls="$(mem_soak_classify "$OK_BASE" "$OK_LAST" "$OK_GROW" "$GROWTH_PCT")"
    ub_cls="$(mem_soak_classify "$UB_BASE" "$UB_LAST" "$UB_GROW" "$GROWTH_PCT")"
    dg_kind="${dg_cls%%|*}"; ok_kind="${ok_cls%%|*}"; ub_kind="${ub_cls%%|*}"
    {
        echo "degenerate (base=$DG_BASE last=$DG_LAST grow=$DG_GROW) -> $dg_kind (want SKIP)"
        echo "  detail: ${dg_cls#*|}"
        echo "valid    (base=$OK_BASE last=$OK_LAST grow=$OK_GROW) -> $ok_kind (want PASS)"
        echo "unbounded(base=$UB_BASE last=$UB_LAST grow=$UB_GROW) -> $ub_kind (want FAIL)"
    } >>"$EVID_FILE"
    if [ "$dg_kind" = "SKIP" ] && [ "$ok_kind" = "PASS" ] && [ "$ub_kind" = "FAIL" ]; then
        verdict=PASS; exit_code=0
        msg="GREEN: degenerate final sample -> SKIP (not a bounded PASS); valid series -> PASS; unbounded -> FAIL"
    else
        msg="REGRESSION: degenerate=$dg_kind valid=$ok_kind unbounded=$ub_kind — a sampler death may still score as bounded"
    fi
fi

echo "verdict: $verdict" >>"$EVID_FILE"
echo "detail: $msg" >>"$EVID_FILE"
echo "[$verdict] memory-soak-degenerate-sample (RED_MODE=$RED_MODE): $msg"
echo "evidence: $EVID_FILE"
exit "$exit_code"
