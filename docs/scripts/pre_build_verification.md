# `tests/pre_build_verification.sh` — operator guide

**Revision:** 1
**Last modified:** 2026-07-01T00:00:00Z
**Authority:** Helix Constitution §11.4.35 (inheritance gate), §11.4 (pre-build verification — no CI/CD, no git hooks; CLAUDE.md Hard Stop #1), §1.1 (paired-mutation discipline for future gates)

> Companion (§11.4.18) to the in-source documentation block at the top of the
> script.

## Overview / Purpose

The **manual pre-build / pre-merge gate runner** — the single entry point the
build/test pipeline invokes BEFORE a build or merge. The project Constitution
bans CI/CD and git hooks (CLAUDE.md Hard Stop #1), so this enforcement lives as
a script target invoked manually (or by `tests/run-tests.sh`) instead of a
pipeline. Today it runs one gate — the constitution-inheritance gate — and is
the designated place to append further pre-build gates as the project grows
(each new gate must carry a paired §1.1 mutation).

## Usage

```bash
bash tests/pre_build_verification.sh
```

No flags, no arguments.

## Inputs

None. All paths are derived from the script's own location
(`${BASH_SOURCE[0]}`).

## Outputs

- A banner, a `>>> gate: constitution inheritance` line, the delegated gate's
  own PASS/FAIL output, and a final
  `=== pre-build verification summary: PASS|FAIL ===` line.
- Exit `0` — all gates passed; exit `1` — a gate failed (`rc` is set to 1 and
  returned).

## Side-effects

None. It delegates to the read-only inheritance gate and never mutates the tree.

## Dependencies

- `bash` (`set -uo pipefail`).
- `tests/constitution_inheritance_gate.sh` (the only gate it currently invokes).

## Related scripts

- `tests/constitution_inheritance_gate.sh` — the gate this runner invokes
  (see `docs/scripts/constitution_inheritance_gate.md`).
- `tests/test_constitution_inheritance.sh` — the comprehensive host-side
  inheritance test (superset of the gate).
- `tests/run-tests.sh` — the broader structural + regression suite, which also
  runs the inheritance gate as a pre-flight step.

## Last verified

2026-07-01 — documented from source. The script is a thin aggregator: it runs
`constitution_inheritance_gate.sh` and reports PASS/FAIL. Not executed here (the
conductor runs the live gate).
