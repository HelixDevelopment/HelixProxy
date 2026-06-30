#!/usr/bin/env bash
#######################################
# pre_build_verification.sh — Manual pre-build / pre-merge gate runner.
#
# Purpose:  Single entry point the build/test pipeline invokes BEFORE a
#           build or merge. The project Constitution bans CI/CD and git
#           hooks (CLAUDE.md Hard Stop #1), so enforcement lives here as
#           a script target, invoked manually or by tests/run-tests.sh.
# Usage:    bash tests/pre_build_verification.sh
# Inputs:   none.
# Outputs:  Aggregated gate output; exit 0 = all gates pass, 1 = a gate
#           failed.
# Side-effects: none (delegates to read-only gates).
# Dependencies: bash; tests/constitution_inheritance_gate.sh.
# Cross-references: tests/constitution_inheritance_gate.sh,
#           tests/test_constitution_inheritance.sh.
#######################################

set -uo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

rc=0

echo "############################################################"
echo "# PRE-BUILD VERIFICATION (manual gate — no CI/CD, no hooks) #"
echo "############################################################"
echo

# Gate: Constitution inheritance (Helix Constitution §11.4.35).
echo ">>> gate: constitution inheritance"
if bash "$SCRIPT_DIR/constitution_inheritance_gate.sh"; then
    echo ">>> gate: constitution inheritance OK"
else
    echo ">>> gate: constitution inheritance FAILED" >&2
    rc=1
fi
echo

# Additional pre-build gates may be appended here as the project grows;
# each MUST carry a paired §1.1 mutation proving it catches regressions.

echo "=== pre-build verification summary: $([[ $rc -eq 0 ]] && echo PASS || echo FAIL) ==="
exit "$rc"
