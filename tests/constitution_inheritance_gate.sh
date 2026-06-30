#!/usr/bin/env bash
#######################################
# constitution_inheritance_gate.sh — Pre-build / pre-merge gate that
# verifies the Helix Constitution submodule is present and that this
# project genuinely inherits from it (Helix Constitution §11.4.35).
#
# Purpose:  Mechanically prove the five inheritance invariants below so
#           a missing/broken/un-wired constitution submodule is caught
#           BEFORE any build, merge, or release tag.
# Usage:    bash tests/constitution_inheritance_gate.sh
# Inputs:   none (paths derived from this script's location)
# Outputs:  PASS/FAIL lines + summary; exit 0 = all invariants hold,
#           exit 1 = one or more FAILed.
# Side-effects: none (read-only; never mutates the tree).
# Dependencies: bash, grep.
# Cross-references: constitution/meta_test_inheritance.sh (the generic
#           §11.4-anchor mutation), challenges/scripts/
#           meta_test_constitution_inheritance.sh (the paired §1.1
#           mutation proving THIS gate catches regressions),
#           tests/test_constitution_inheritance.sh (comprehensive host
#           test). Anchors are derived from the real submodule content,
#           never guessed (Helix Constitution §11.4.6).
#######################################

set -uo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
readonly CONST_DIR="$PROJECT_ROOT/constitution"

# Colors (match tests/run-tests.sh house style; degrade gracefully if
# stdout is not a TTY).
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

# A file-contains-literal assertion. grep -F = fixed string (the anchors
# contain '§' and em-dashes — never treat them as regex).
check_contains() {
    local label="$1" file="$2" literal="$3"
    if [[ ! -f "$file" ]]; then
        assert_fail "$label — file missing: ${file#"$PROJECT_ROOT"/}"
        return
    fi
    if grep -qF -- "$literal" "$file"; then
        assert_pass "$label"
    else
        assert_fail "$label — literal not found in ${file#"$PROJECT_ROOT"/}: \"$literal\""
    fi
}

echo "=== Constitution inheritance gate (Helix Constitution §11.4.35) ==="
echo "project root: $PROJECT_ROOT"
echo

# --- Invariant 1: constitution/ directory exists -----------------------
if [[ -d "$CONST_DIR" ]]; then
    assert_pass "I1: constitution/ submodule directory exists"
else
    assert_fail "I1: constitution/ submodule directory missing"
fi

# --- Invariant 2: Constitution.md present + carries the §11.4 anchor ----
# Real anchor verified at constitution/Constitution.md (the §11.4
# End-user quality guarantee heading). This is the SAME literal the
# shipped constitution/meta_test_inheritance.sh mutates.
check_contains \
    "I2: constitution/Constitution.md carries the §11.4 forensic anchor (as a section heading, not just a ToC entry)" \
    "$CONST_DIR/Constitution.md" \
    '### §11.4 End-user quality guarantee — forensic anchor'

# --- Invariant 3: CLAUDE.md present + carries the anti-bluff covenant --
check_contains \
    "I3: constitution/CLAUDE.md carries the MANDATORY ANTI-BLUFF COVENANT anchor (as a section heading)" \
    "$CONST_DIR/CLAUDE.md" \
    '## MANDATORY ANTI-BLUFF COVENANT'

# --- Invariant 4: AGENTS.md present + carries the anti-bluff covenant --
check_contains \
    "I4: constitution/AGENTS.md carries the Anti-bluff covenant anchor (as a section heading)" \
    "$CONST_DIR/AGENTS.md" \
    '### Anti-bluff covenant'

# --- Invariant 5: parent files reference the submodule (inheritance) ---
check_contains \
    "I5a: CLAUDE.md inherits from constitution/CLAUDE.md" \
    "$PROJECT_ROOT/CLAUDE.md" \
    'INHERITED FROM constitution/CLAUDE.md'
check_contains \
    "I5b: AGENTS.md references constitution/AGENTS.md" \
    "$PROJECT_ROOT/AGENTS.md" \
    'constitution/AGENTS.md'
check_contains \
    "I5c: CONSTITUTION.md references constitution/Constitution.md" \
    "$PROJECT_ROOT/CONSTITUTION.md" \
    'constitution/Constitution.md'

echo
echo "=== summary: $PASS_COUNT pass, $FAIL_COUNT fail ==="
if [[ $FAIL_COUNT -ne 0 ]]; then
    printf '  - %s\n' "${FAIL_DETAILS[@]}" >&2
    exit 1
fi
exit 0
