#!/usr/bin/env bash
#######################################
# meta_test_constitution_inheritance.sh — Paired §1.1 anti-bluff
# meta-test PROVING tests/constitution_inheritance_gate.sh is not a
# bluff gate (Helix Constitution §1.1: every gate MUST have a paired
# mutation showing it catches the regression it claims to catch).
#
# Method (mutation testing): for each invariant, snapshot the target
# file, strip the anchor it asserts, run the gate, REQUIRE the gate to
# FAIL (exit != 0), then restore the file and confirm clean. A gate that
# still PASSes with the anchor removed is itself a Constitution
# violation. Also drives the constitution-shipped generic mutator
# constitution/meta_test_inheritance.sh against this project's gate.
#
# Usage:    bash challenges/scripts/meta_test_constitution_inheritance.sh
# Inputs:   none.
# Outputs:  PASS/FAIL lines + summary; exit 0 = gate caught every
#           mutation (gate is genuine), 1 = a mutation slipped past
#           (gate is a bluff) OR a precondition failed.
# Side-effects: TEMPORARILY mutates tracked files, ALWAYS restored
#           (immediately + via EXIT/INT/TERM trap). Verifies the working
#           tree is clean at the end; refuses to leave residue
#           (Helix Constitution §11.4.84 working-tree quiescence).
# Dependencies: bash, grep, git, mktemp.
# Cross-references: tests/constitution_inheritance_gate.sh (gate under
#           test), constitution/meta_test_inheritance.sh (generic §11.4
#           mutator), tests/test_constitution_inheritance.sh.
#######################################

set -uo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
readonly CONST_DIR="$PROJECT_ROOT/constitution"
readonly GATE="$PROJECT_ROOT/tests/constitution_inheritance_gate.sh"
readonly GATE_CMD="bash $GATE"

if [[ -t 1 ]]; then
    RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
else
    RED=''; GREEN=''; NC=''
fi

PASS_COUNT=0
FAIL_COUNT=0
FAIL_DETAILS=()
assert_pass() { echo -e "${GREEN}✓ PASS${NC}: $*"; PASS_COUNT=$((PASS_COUNT + 1)); }
assert_fail() { echo -e "${RED}✗ FAIL${NC}: $*"; FAIL_COUNT=$((FAIL_COUNT + 1)); FAIL_DETAILS+=("$*"); }

# --- crash-safe restore of an in-flight mutation ----------------------
PENDING_FILE=""
PENDING_BAK=""
restore_pending() {
    if [[ -n "$PENDING_BAK" && -f "$PENDING_BAK" ]]; then
        cp -- "$PENDING_BAK" "$PENDING_FILE"
        rm -f -- "$PENDING_BAK"
        PENDING_FILE=""; PENDING_BAK=""
    fi
}
trap restore_pending EXIT INT TERM

# mutate_and_require_fail <mutation-name> <file> <literal-to-strip>
mutate_and_require_fail() {
    local name="$1" file="$2" literal="$3"
    if [[ ! -f "$file" ]]; then
        assert_fail "$name — target file missing: $file"
        return
    fi
    if ! grep -qF -- "$literal" "$file"; then
        assert_fail "$name — anchor not present BEFORE mutation (precondition): \"$literal\""
        return
    fi
    PENDING_BAK="$(mktemp)"; PENDING_FILE="$file"
    cp -- "$file" "$PENDING_BAK"
    # Strip every line carrying the anchor (grep -vF; safe with §/em-dash).
    grep -vF -- "$literal" "$PENDING_BAK" > "$file"
    local rc; eval "$GATE_CMD" >/dev/null 2>&1; rc=$?
    # restore immediately
    cp -- "$PENDING_BAK" "$file"; rm -f -- "$PENDING_BAK"; PENDING_BAK=""; PENDING_FILE=""
    if [[ "$rc" -ne 0 ]]; then
        assert_pass "$name — gate correctly FAILed under mutation (rc=$rc)"
    else
        assert_fail "$name — gate PASSed despite stripped anchor => BLUFF GATE"
    fi
}

echo "=== Paired anti-bluff meta-test for the constitution inheritance gate (§1.1) ==="
echo

# --- Precondition: baseline gate PASSes on the un-mutated tree --------
if eval "$GATE_CMD" >/dev/null 2>&1; then
    assert_pass "baseline: gate PASSes on the un-mutated tree"
else
    assert_fail "baseline: gate FAILs on the un-mutated tree (fix wiring before trusting mutations)"
fi
echo

# --- Mutations: each must make the gate FAIL --------------------------
# CM-CONSTITUTION-INHERITANCE (the canonical §11.4-anchor mutation).
# NOTE: these strip the SECTION HEADING line (the exact thing the gate
# asserts), matching the constitution-shipped meta_test_inheritance.sh
# contract — NOT a looser substring that would also nuke the ToC entry.
mutate_and_require_fail \
    "CM-CONSTITUTION-INHERITANCE (strip §11.4 section heading from constitution/Constitution.md)" \
    "$CONST_DIR/Constitution.md" \
    '### §11.4 End-user quality guarantee — forensic anchor'
mutate_and_require_fail \
    "CM-CLAUDE-COVENANT (strip ANTI-BLUFF COVENANT heading from constitution/CLAUDE.md)" \
    "$CONST_DIR/CLAUDE.md" \
    '## MANDATORY ANTI-BLUFF COVENANT'
mutate_and_require_fail \
    "CM-AGENTS-COVENANT (strip Anti-bluff covenant heading from constitution/AGENTS.md)" \
    "$CONST_DIR/AGENTS.md" \
    '### Anti-bluff covenant'
mutate_and_require_fail \
    "CM-PARENT-INHERIT-CLAUDE (strip inheritance pointer from CLAUDE.md)" \
    "$PROJECT_ROOT/CLAUDE.md" \
    'INHERITED FROM constitution/CLAUDE.md'
mutate_and_require_fail \
    "CM-PARENT-INHERIT-AGENTS (strip constitution/AGENTS.md reference from AGENTS.md)" \
    "$PROJECT_ROOT/AGENTS.md" \
    'constitution/AGENTS.md'
mutate_and_require_fail \
    "CM-PARENT-INHERIT-CONSTITUTION (strip constitution/Constitution.md reference from CONSTITUTION.md)" \
    "$PROJECT_ROOT/CONSTITUTION.md" \
    'constitution/Constitution.md'
echo

# --- Also drive the constitution-shipped generic mutator --------------
SHIPPED="$CONST_DIR/meta_test_inheritance.sh"
if [[ -f "$SHIPPED" ]]; then
    echo ">>> constitution/meta_test_inheritance.sh \"$GATE_CMD\""
    if bash "$SHIPPED" "$GATE_CMD"; then
        assert_pass "shipped meta_test_inheritance.sh: gate FAILed under its §11.4 mutation"
    else
        assert_fail "shipped meta_test_inheritance.sh: gate did NOT FAIL under its §11.4 mutation"
    fi
else
    assert_fail "shipped constitution/meta_test_inheritance.sh missing"
fi
echo

# --- Quiescence: the working tree MUST be exactly as we found it ------
# (Helix Constitution §11.4.84 — no mutation residue may survive.)
const_dirty="$(git -C "$CONST_DIR" status --porcelain 2>/dev/null)"
if [[ -z "$const_dirty" ]]; then
    assert_pass "quiescence: constitution submodule working tree clean (no mutation residue)"
else
    assert_fail "quiescence: constitution submodule left dirty: $const_dirty"
fi

echo
echo "=== summary: $PASS_COUNT pass, $FAIL_COUNT fail ==="
if [[ $FAIL_COUNT -ne 0 ]]; then
    printf '  - %s\n' "${FAIL_DETAILS[@]}" >&2
    exit 1
fi
exit 0
