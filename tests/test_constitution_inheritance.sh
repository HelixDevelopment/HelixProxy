#!/usr/bin/env bash
#######################################
# test_constitution_inheritance.sh — Comprehensive host-side test that
# the Helix Constitution submodule is present, inherited, and propagated
# to every owned nested submodule (Helix Constitution §11.4.35 / §3).
#
# Purpose:  Assert ALL inheritance invariants (delegated to the gate)
#           PLUS recursive child-submodule inheritance pointers. This is
#           the file referenced in the init task's final verification:
#               bash tests/test_constitution_inheritance.sh
# Usage:    bash tests/test_constitution_inheritance.sh
# Inputs:   none.
# Outputs:  PASS/FAIL lines + summary; exit 0 = all assertions hold.
# Side-effects: none (read-only).
# Dependencies: bash, git, grep; tests/constitution_inheritance_gate.sh.
# Cross-references: tests/constitution_inheritance_gate.sh (invariants
#           1-5), challenges/scripts/meta_test_constitution_inheritance.sh
#           (paired §1.1 mutation). NOTE: nested-submodule propagation is
#           reported LOUDLY even when zero owned children exist — a
#           silent skip would be a §11.4 PASS-bluff.
#######################################

set -uo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

if [[ -t 1 ]]; then
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; NC=''
fi

PASS_COUNT=0
FAIL_COUNT=0
FAIL_DETAILS=()
assert_pass() { echo -e "${GREEN}✓ PASS${NC}: $*"; PASS_COUNT=$((PASS_COUNT + 1)); }
assert_fail() { echo -e "${RED}✗ FAIL${NC}: $*"; FAIL_COUNT=$((FAIL_COUNT + 1)); FAIL_DETAILS+=("$*"); }
note()        { echo -e "${YELLOW}• $*${NC}"; }

echo "=== Comprehensive constitution-inheritance test ==="
echo

# --- Part A: the five invariants (delegate to the gate) ---------------
echo ">>> Part A: inheritance invariants (constitution_inheritance_gate.sh)"
if bash "$SCRIPT_DIR/constitution_inheritance_gate.sh"; then
    assert_pass "A: all gate invariants (I1-I5) hold"
else
    assert_fail "A: gate reported one or more invariant failures"
fi
echo

# --- Part B: recursive owned-submodule inheritance pointers (§3) ------
# Helix Constitution §3: submodule inheritance propagates. Every OWNED
# nested submodule (everything except the constitution itself) must
# carry the inheritance pointer in its CLAUDE.md and AGENTS.md. We
# enumerate recursively and NEVER skip silently.
echo ">>> Part B: recursive nested owned-submodule pointers"
mapfile -t SUBMODULES < <(git -C "$PROJECT_ROOT" submodule status --recursive 2>/dev/null | awk '{print $2}')

owned_count=0
for sm in "${SUBMODULES[@]:-}"; do
    [[ -z "$sm" ]] && continue
    # The constitution submodule is the canonical SOURCE, not a consumer
    # (Helix Constitution §11.4.35) — it must NOT carry an inheritance
    # pointer, so it is correctly excluded from this check.
    if [[ "$sm" == "constitution" || "$sm" == */constitution ]]; then
        note "skipping source-of-truth submodule: $sm (§11.4.35 — canonical root, not a consumer)"
        continue
    fi
    owned_count=$((owned_count + 1))
    sm_dir="$PROJECT_ROOT/$sm"
    for f in CLAUDE.md AGENTS.md; do
        if [[ -f "$sm_dir/$f" ]] && grep -qF 'Helix Constitution' "$sm_dir/$f"; then
            assert_pass "B: $sm/$f carries the Helix Constitution inheritance pointer"
        else
            assert_fail "B: $sm/$f missing the Helix Constitution inheritance pointer"
        fi
    done
done

if [[ "$owned_count" -eq 0 ]]; then
    note "0 owned nested submodules besides constitution — no child pointers to verify."
    note "Step 6 (propagate inheritance to nested submodules) is a verified no-op for this repo."
    assert_pass "B: nested-submodule propagation N/A (zero owned children) — reported, not silently skipped"
fi
echo

echo "=== summary: $PASS_COUNT pass, $FAIL_COUNT fail ==="
if [[ $FAIL_COUNT -ne 0 ]]; then
    printf '  - %s\n' "${FAIL_DETAILS[@]}" >&2
    exit 1
fi
exit 0
