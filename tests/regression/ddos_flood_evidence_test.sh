#!/bin/sh
#######################################################################
# §11.4.135 regression guard — ddos_flood_suite.sh flood-evidence verdict (F5).
#
# Purpose:
#   Prove tests/dynamic/suites/ddos_flood_suite.sh's flood-survival GREEN gate
#   never scores a "survived the flood / degraded-not-collapsed" PASS WITHOUT
#   positive captured evidence that a flood was ACTUALLY generated — i.e. it
#   requires flood_total>0 AND flood_responses>0 (§11.4.69 evidence; §11.4.1
#   no PASS-bluff). Pre-fix, the GREEN gate was `pid_stable=1 AND rec=200` ONLY,
#   so a run where the flood issued ZERO requests still PASSed as "survived a
#   flood" — a vacuous claim (the proxy survived nothing).
#
# What it actually does (extracts the REAL pure fn — NOT a grep, no network,
# no live containers):
#   GREEN — drives the REAL flood_survival_verdict with four canonical fixtures:
#           ZERO(no flood, proxy up)      -> FAIL:no-flood-evidence  (bluff refused)
#           SURVIVED(real flood + 200)    -> PASS
#           CRASHED(real flood, no recov) -> FAIL:crashed-or-no-recovery (catch kept)
#           ABSENT(no flood, proxy down)  -> SKIP:topology_unsupported (honest skip)
#   RED   — runs the PRE-FIX replica (`pid_stable=1 && rec=200 => PASS`, ignoring
#           the flood counter) against the ZERO-flood fixture and asserts PASS
#           (the bluff reproduced). A RED that cannot reproduce is a §11.4.7
#           finding.
#
# §11.4.115 polarity switch (RED_MODE):
#   RED_MODE=0 (default GREEN guard) — PASS iff the real verdict gives
#              FAIL:no-flood-evidence(zero) + PASS(survived) +
#              FAIL:crashed-or-no-recovery(crashed) + SKIP:topology_unsupported(absent).
#   RED_MODE=1 (reproduce) — PASS iff the pre-fix replica returns PASS for the
#              zero-flood survival fixture (the §11.4.1 bluff).
#
# Usage:
#   tests/regression/ddos_flood_evidence_test.sh            # GREEN guard
#   RED_MODE=1 tests/regression/ddos_flood_evidence_test.sh # reproduce
#
# Inputs:   RED_MODE (env, default 0). No CLI args.
# Outputs:  PASS/FAIL verdict on stdout + evidence under
#           qa-results/regression/ddos_flood_evidence/. Exit 0=PASS,1=FAIL.
# Side-effects: writes an evidence file; NO network, NO containers.
# Dependencies: sh, awk, mktemp, bash (probe runner).
# Cross-references:
#   - Fix: tests/dynamic/suites/ddos_flood_suite.sh flood_survival_verdict()
#     + the flood_total/flood_responses counters + the GREEN/RED gates.
#   - Companion doc: docs/scripts/ddos_flood_evidence_test.md.
#   - Pattern sibling: tests/regression/external_egress_verdict_test.sh.
#   - docs/issues/fixed/BUGFIXES.md — F5.
# Shell: POSIX-clean — parses under `sh -n` AND `bash -n` (§11.4.67).
#######################################################################
set -eu

RED_MODE="${RED_MODE:-0}"
REPO_ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
EVID_DIR="$REPO_ROOT/qa-results/regression/ddos_flood_evidence"
mkdir -p "$EVID_DIR"
EVID_FILE="$EVID_DIR/ddos_flood_evidence.$$.txt"

SUITE="$REPO_ROOT/tests/dynamic/suites/ddos_flood_suite.sh"

PROBE="$(mktemp)"
trap 'rm -f "$PROBE"' EXIT INT TERM

{
    echo 'set -u'
    if [ "$RED_MODE" = "1" ]; then
        # Faithful PRE-FIX replica: the survival gate ignored the flood counter,
        # PASSing on pid_stable=1 && rec=200 ALONE — so a zero-flood run PASSed.
        printf '%s\n' \
            '_prefix_flood_verdict() { if [ "$1" = "1" ] && [ "$2" = "200" ]; then echo PASS; else echo FAIL; fi; }' \
            'echo "ZERO=$(_prefix_flood_verdict 1 200 0 0 yes)"'
    else
        # Extract the REAL current classifier from the tracked suite and drive it.
        awk '/^flood_survival_verdict\(\) \{/{f=1} f{print} /^\}/{if(f){exit}}' "$SUITE"
        printf '%s\n' \
            'echo "ZERO=$(flood_survival_verdict 1 200 0 0 yes)"' \
            'echo "SURVIVED=$(flood_survival_verdict 1 200 3000 2950 yes)"' \
            'echo "CRASHED=$(flood_survival_verdict 0 000 3000 100 yes)"' \
            'echo "ABSENT=$(flood_survival_verdict 1 200 0 0 no)"'
    fi
} >"$PROBE"

probe_out="$(bash "$PROBE" 2>&1)" && probe_rc=0 || probe_rc=$?

verdict=FAIL
exit_code=1
if [ "$RED_MODE" = "1" ]; then
    case "$probe_out" in
        *ZERO=PASS*)
            verdict=PASS; exit_code=0
            msg="RED reproduced: pre-fix survival gate PASSes a ZERO-flood run (flood_total=0) as 'survived the flood' — the §11.4.1 bluff, rc=$probe_rc"
            ;;
        *)
            msg="RED could-not-reproduce: pre-fix replica did not PASS the zero-flood fixture (out=$probe_out, rc=$probe_rc) — finding per §11.4.7"
            ;;
    esac
else
    case "$probe_out" in
        *ZERO=FAIL:no-flood-evidence*SURVIVED=PASS*CRASHED=FAIL:crashed-or-no-recovery*ABSENT=SKIP:topology_unsupported*)
            verdict=PASS; exit_code=0
            msg="GREEN: real verdict = FAIL:no-flood-evidence(zero) + PASS(survived) + FAIL:crashed-or-no-recovery(crashed) + SKIP:topology_unsupported(absent)"
            ;;
        *)
            msg="REGRESSION: verdict wrong (out=$probe_out, rc=$probe_rc) — a zero-flood run must NOT PASS (bluff) and a real crash must still FAIL"
            ;;
    esac
fi

{
    echo "ddos flood-evidence verdict regression guard — §11.4.69/§11.4.1/§11.4.115"
    echo "timestamp_utc: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "RED_MODE: $RED_MODE"
    echo "probe_rc: $probe_rc"
    echo "probe_out: $probe_out"
    echo "verdict: $verdict"
    echo "detail: $msg"
} >"$EVID_FILE"

echo "[$verdict] ddos-flood-evidence (RED_MODE=$RED_MODE): $msg"
echo "evidence: $EVID_FILE"
exit "$exit_code"
