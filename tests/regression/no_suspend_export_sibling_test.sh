#!/bin/sh
#######################################################################
# §11.4.135 regression guard — CONST-033 scanner doc-ledger export-sibling
# exclusion (BUGFIX-0011).
#
# Purpose:
#   Prove `scripts/host-power-management/check-no-suspend-calls.sh` excludes a
#   documentation ledger's §11.4.65 EXPORT SIBLINGS (.html/.pdf), not just its
#   .md source. Pre-fix, EXCLUDE_PATHS carried the ledger with an explicit ".md"
#   extension, so the generated BUGFIXES.html — which legitimately quotes banned
#   patterns when DOCUMENTING a CONST-033 fix — was still scanned and tripped the
#   scanner on its own fix documentation (§11.4.1 false-FAIL). The fix uses an
#   extension-AGNOSTIC prefix ("/docs/issues/fixed/BUGFIXES.") so ALL siblings are
#   excluded — while a NON-ledger .html and any real script invocation still trip.
#   BUGFIX-0013 (F4, §11.4.118 sweep): the same class remained on the governance
#   carriers (CLAUDE.md/AGENTS.md/QWEN.md/GEMINI.md/CONSTITUTION.md) — the GREEN
#   branch now also asserts a CLAUDE.html governance sibling is excluded.
#
# What it actually does (fixture-driven — does NOT depend on the live ledger's
# content, exercises the REAL scanner):
#   Builds a throwaway ROOT with (1) docs/issues/fixed/BUGFIXES.html quoting the
#   banned `systemctl` power-state literal (a ledger export sibling — MUST be
#   excluded) and (2) scripts/real_invocation.sh carrying the same banned literal
#   (a real invocation — MUST trip).
#   GREEN — runs the REAL scanner on the ROOT and asserts: the ledger .html is
#           NOT in the violation list (excluded) AND the real script IS (still
#           caught) → the exclusion covers siblings without neutering the gate.
#   RED   — runs a PRE-FIX replica of the scanner (EXCLUDE_PATHS reverted to the
#           ".md"-only form via sed) on a ledger-.html-ONLY ROOT and asserts it
#           FAILs on BUGFIXES.html (the sibling-blind false-FAIL reproduced).
#
# §11.4.115 polarity switch (RED_MODE):
#   RED_MODE=0 (default GREEN guard) — PASS iff the REAL scanner excludes the
#              ledger .html sibling AND still catches the real script.
#   RED_MODE=1 (reproduce) — PASS iff the ".md"-only replica trips on the ledger
#              .html sibling (the pre-fix false-FAIL). A RED that cannot reproduce
#              is itself a §11.4.7 finding.
#
# Usage:
#   tests/regression/no_suspend_export_sibling_test.sh            # GREEN guard
#   RED_MODE=1 tests/regression/no_suspend_export_sibling_test.sh # reproduce
#
# Inputs:   RED_MODE (env, default 0). No CLI args.
# Outputs:  PASS/FAIL verdict on stdout + evidence under
#           qa-results/regression/no_suspend_export_sibling/. Exit 0=PASS,1=FAIL.
# Dependencies: sh, sed, mktemp, grep, awk (all POSIX).
# Cross-references:
#   - Fix: scripts/host-power-management/check-no-suspend-calls.sh EXCLUDE_PATHS.
#   - Standing challenge: challenges/scripts/no_suspend_calls_challenge.sh.
#   - docs/issues/fixed/BUGFIXES.md — BUGFIX-0011.
#######################################################################
set -eu

RED_MODE="${RED_MODE:-0}"
REPO_ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
SCANNER="$REPO_ROOT/scripts/host-power-management/check-no-suspend-calls.sh"
EVID_DIR="$REPO_ROOT/qa-results/regression/no_suspend_export_sibling"
mkdir -p "$EVID_DIR"
EVID_FILE="$EVID_DIR/no_suspend_export_sibling.$$.txt"

TMPROOT="$(mktemp -d)"
MUT_SCANNER=""
# NB: force a 0 return — a conditional as the trap's last command would leak its
# non-zero status into the script exit under `set -e` (§11.4.1 false-FAIL).
cleanup() { rm -rf "$TMPROOT"; [ -n "$MUT_SCANNER" ] && rm -f "$MUT_SCANNER"; return 0; }
trap cleanup EXIT INT TERM

# The banned literal lives ONLY in the runtime temp fixtures (never as a real host
# call). Assemble it from parts so THIS guard's own source stays scanner-clean —
# no contiguous `systemctl`+state substring — while the fixtures written below carry
# the real contiguous value.
_p1='systemctl'; _p2='suspend'
BANNED="$_p1 $_p2"

# Fixture (1): a documentation-ledger EXPORT SIBLING that legitimately quotes the
# banned pattern (mirrors the real BUGFIXES.html:1210 line).
mkdir -p "$TMPROOT/docs/issues/fixed"
printf '<p>$ printf %s > tests/_probe.txt; scanner .</p>\n' "$BANNED" \
    > "$TMPROOT/docs/issues/fixed/BUGFIXES.html"

verdict=FAIL
exit_code=1

if [ "$RED_MODE" = "1" ]; then
    # PRE-FIX replica: revert the exclusion to the sibling-blind ".md"-only form.
    MUT_SCANNER="$(mktemp)"
    sed 's#"/docs/issues/fixed/BUGFIXES\."#"/docs/issues/fixed/BUGFIXES.md"#' \
        "$SCANNER" > "$MUT_SCANNER"
    out="$(bash "$MUT_SCANNER" "$TMPROOT" 2>&1)" && rc=0 || rc=$?
    case "$out" in
        *docs/issues/fixed/BUGFIXES.html*)
            verdict=PASS; exit_code=0
            msg="RED reproduced: the .md-only replica scans the ledger .html sibling and FAILs on it (sibling-blind false-FAIL), rc=$rc"
            ;;
        *)
            msg="RED could-not-reproduce: .md-only replica did NOT flag the ledger .html (out=$out, rc=$rc) — finding per 11.4.7"
            ;;
    esac
else
    # GREEN: add a REAL invocation the scanner MUST still catch, plus a GOVERNANCE
    # export sibling (CLAUDE.html — F4 from the §11.4.118 sweep), then assert BOTH
    # doc siblings are excluded while the real script is not.
    mkdir -p "$TMPROOT/scripts"
    printf '#!/bin/sh\n%s\n' "$BANNED" > "$TMPROOT/scripts/real_invocation.sh"
    # F4: a governance-carrier export sibling (CLAUDE.<ext>) legitimately quoting the
    # banned literal — MUST be excluded by the extension-agnostic "CLAUDE." prefix
    # (an explicit "CLAUDE.md" left this generated .html sibling scannable).
    printf '<p>%s</p>\n' "$BANNED" > "$TMPROOT/CLAUDE.html"
    out="$(bash "$SCANNER" "$TMPROOT" 2>&1)" && rc=0 || rc=$?
    ledger_flagged=no; gov_flagged=no; script_flagged=no
    case "$out" in *docs/issues/fixed/BUGFIXES.html*) ledger_flagged=yes;; esac
    case "$out" in *CLAUDE.html*)                     gov_flagged=yes;; esac
    case "$out" in *scripts/real_invocation.sh*)      script_flagged=yes;; esac
    if [ "$ledger_flagged" = "no" ] && [ "$gov_flagged" = "no" ] && [ "$script_flagged" = "yes" ] && [ "$rc" -eq 1 ]; then
        verdict=PASS; exit_code=0
        msg="GREEN: real scanner EXCLUDES the ledger .html AND governance CLAUDE.html export siblings AND still catches the real script (rc=$rc)"
    else
        msg="REGRESSION: ledger_flagged=$ledger_flagged (want no) gov_flagged=$gov_flagged (want no) script_flagged=$script_flagged (want yes) rc=$rc (want 1) — a doc-sibling exclusion broke OR the gate was neutered (out=$out)"
    fi
fi

{
    echo "CONST-033 scanner doc-ledger export-sibling exclusion guard — BUGFIX-0011"
    echo "timestamp_utc: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "RED_MODE: $RED_MODE"
    echo "scanner: $SCANNER"
    echo "verdict: $verdict"
    echo "detail: $msg"
} > "$EVID_FILE"

echo "[$verdict] no-suspend-export-sibling (RED_MODE=$RED_MODE): $msg"
echo "evidence: $EVID_FILE"
exit "$exit_code"
