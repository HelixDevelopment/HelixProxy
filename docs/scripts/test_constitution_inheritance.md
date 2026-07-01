# `tests/test_constitution_inheritance.sh` — operator guide

**Revision:** 1
**Last modified:** 2026-07-01T00:00:00Z
**Authority:** Helix Constitution §11.4.35 (inheritance clarity), §3 (submodule inheritance propagation), §11.4 (no silent-skip PASS-bluff), §1.1 (paired mutation)

> Companion (§11.4.18) to the in-source documentation block at the top of the
> script.

## Overview / Purpose

The **comprehensive host-side inheritance test** — a superset of the gate. It
asserts ALL five inheritance invariants (by delegating to
`constitution_inheritance_gate.sh`, Part A) PLUS recursive nested-submodule
inheritance pointers (§3, Part B). It is the file the init task's final
verification points at (`bash tests/test_constitution_inheritance.sh`). Read-only.

## Usage

```bash
bash tests/test_constitution_inheritance.sh
```

No CLI flags or arguments.

## Inputs

None (no env vars, no arguments). It enumerates nested submodules via
`git submodule status --recursive` and reads each owned child's `CLAUDE.md` +
`AGENTS.md`. The `constitution` submodule itself is excluded (it is the
canonical SOURCE, not a consumer — §11.4.35).

## Outputs

- **Part A:** delegates to the gate; one PASS/FAIL for "all gate invariants
  (I1–I5) hold".
- **Part B:** for every owned nested submodule, a PASS/FAIL that its `CLAUDE.md`
  and `AGENTS.md` carry the `Helix Constitution` inheritance pointer. When there
  are **zero** owned children, it says so LOUDLY (a `note` + an explicit PASS
  that propagation is a verified no-op) — never a silent skip (§11.4 PASS-bluff).
- A `=== summary: N pass, M fail ===` line (fail details to stderr).
- Exit `0` — all assertions hold; exit `1` — one or more FAILed.
- Colour is emitted only when stdout is a TTY.

## Side-effects

None. Read-only; runs `git submodule status --recursive` and reads files.

## Dependencies

- `bash` (`set -uo pipefail`), `git`, `grep`, `awk`, `mapfile`.
- `tests/constitution_inheritance_gate.sh` (invoked for Part A).

## Related scripts

- `tests/constitution_inheritance_gate.sh` — invariants I1–I5 (see
  `docs/scripts/constitution_inheritance_gate.md`).
- `challenges/scripts/meta_test_constitution_inheritance.sh` — the paired §1.1
  mutation.
- `tests/pre_build_verification.sh`, `tests/run-tests.sh` — other callers of the
  underlying gate.

## Last verified

2026-07-01 — documented from source; Part A (gate delegation) and Part B
(recursive owned-submodule pointer check with a loud zero-children path) read
directly from the script body. Not executed here.
