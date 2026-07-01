# `tests/constitution_inheritance_gate.sh` — operator guide

**Revision:** 1
**Last modified:** 2026-07-01T00:00:00Z
**Authority:** Helix Constitution §11.4.35 (canonical-root inheritance clarity), §11.4.6 (no guessing — anchors derived from real submodule content), §1.1 (paired mutation), CLAUDE.md Hard Stop #1 (no CI/CD, no git hooks)

> Companion (§11.4.18) to the in-source documentation block at the top of the
> script.

## Overview / Purpose

The **pre-build / pre-merge inheritance gate**: it mechanically proves the Helix
Constitution submodule is present and that this project genuinely inherits from
it (§11.4.35), so a missing / broken / un-wired constitution submodule is caught
BEFORE any build, merge, or release tag. It is read-only and self-contained,
asserting five inheritance invariants via fixed-string (`grep -F`) checks
against real submodule + parent files (the anchors are the SAME literals the
shipped `constitution/meta_test_inheritance.sh` mutates, never guessed).

## Usage

```bash
bash tests/constitution_inheritance_gate.sh
```

No CLI flags or arguments. Paths are derived from the script's own location.

## Inputs

None (no env vars, no arguments). Files it reads:

- `constitution/` directory (I1).
- `constitution/Constitution.md` — must carry
  `### §11.4 End-user quality guarantee — forensic anchor` (I2).
- `constitution/CLAUDE.md` — must carry `## MANDATORY ANTI-BLUFF COVENANT` (I3).
- `constitution/AGENTS.md` — must carry `### Anti-bluff covenant` (I4).
- `CLAUDE.md` — must carry `INHERITED FROM constitution/CLAUDE.md` (I5a).
- `AGENTS.md` — must reference `constitution/AGENTS.md` (I5b).
- `CONSTITUTION.md` — must reference `constitution/Constitution.md` (I5c).

## Outputs

- A header, one `✓ PASS`/`✗ FAIL` line per invariant, and a
  `=== summary: N pass, M fail ===` line (fail details echoed to stderr).
- Exit `0` — all invariants hold; exit `1` — one or more FAILed.
- Colour is emitted only when stdout is a TTY.

## Side-effects

None. Read-only; never mutates the tree.

## Dependencies

- `bash` (`set -uo pipefail`), `grep`.

## Related scripts

- `tests/pre_build_verification.sh` — the pre-build runner that invokes this gate.
- `tests/test_constitution_inheritance.sh` — the comprehensive host test that
  delegates to this gate (Part A) and adds recursive nested-submodule pointer
  checks (Part B).
- `constitution/meta_test_inheritance.sh` — the generic §11.4-anchor mutation.
- `challenges/scripts/meta_test_constitution_inheritance.sh` — the paired §1.1
  mutation proving THIS gate catches regressions.
- `tests/run-tests.sh` — runs this gate first via `test_constitution_inheritance()`.

## Last verified

2026-07-01 — documented from source; the five invariants + their exact literal
anchors read directly from the script body. Not executed here.
