# `challenges/scripts/meta_test_constitution_inheritance.sh` — operator guide

**Revision:** 1
**Last modified:** 2026-07-01T00:00:00Z
**Status:** Active paired §1.1 anti-bluff meta-test. Proves the constitution
inheritance gate genuinely catches the regressions it claims to catch.

> Companion (§11.4.18) to the in-source documentation block at the top of the
> script.

## Overview / Purpose

Helix Constitution §1.1 requires every gate to have a paired mutation showing
it is NOT a bluff gate. This meta-test proves
`tests/constitution_inheritance_gate.sh` is genuine by **mutation testing**:
for each invariant the gate asserts, it snapshots the target file, strips the
anchor the gate looks for, runs the gate, and REQUIRES the gate to FAIL — then
restores the file. A gate that still PASSes with its anchor removed would be a
bluff (and itself a Constitution violation).

It also drives the constitution-shipped generic mutator
`constitution/meta_test_inheritance.sh` against this project's gate, and
finishes with a §11.4.84 working-tree quiescence check (the constitution
submodule must be exactly as found — no mutation residue).

The six mutations exercised:

- strip the `§11.4` section heading from `constitution/Constitution.md`;
- strip the anti-bluff covenant heading from `constitution/CLAUDE.md`;
- strip the anti-bluff covenant heading from `constitution/AGENTS.md`;
- strip the `INHERITED FROM constitution/CLAUDE.md` pointer from `CLAUDE.md`;
- strip the `constitution/AGENTS.md` reference from `AGENTS.md`;
- strip the `constitution/Constitution.md` reference from `CONSTITUTION.md`.

Plus a baseline check (gate PASSes on the un-mutated tree) and the shipped
generic mutator run.

## Usage

```sh
bash challenges/scripts/meta_test_constitution_inheritance.sh
```

No arguments.

## Inputs

- None on the command line.
- Resolves the project root and constitution submodule from its own location;
  reads (and TEMPORARILY mutates + restores) `constitution/Constitution.md`,
  `constitution/CLAUDE.md`, `constitution/AGENTS.md`, and the project-root
  `CLAUDE.md` / `AGENTS.md` / `CONSTITUTION.md`.

## Outputs

- Colorized (TTY) `✓ PASS` / `✗ FAIL` lines per mutation, a baseline line, the
  shipped-mutator result, a quiescence line, and a
  `=== summary: N pass, M fail ===`; failures are also echoed to stderr.
- Exit code: `0` = the gate caught every mutation (gate is genuine); `1` = a
  mutation slipped past (bluff gate) OR a precondition/quiescence check failed.

## Side-effects

- **TEMPORARILY mutates tracked governance files** — each mutation is restored
  immediately after the gate runs, and again via an `EXIT`/`INT`/`TERM` trap
  (crash-safe `restore_pending`), so an interrupted run never leaves residue.
- Creates and removes per-mutation `mktemp` backups.
- Ends by asserting the constitution submodule working tree is clean
  (§11.4.84); a dirty tree FAILs the meta-test rather than being papered over.

## Dependencies

`bash`, `grep`, `git`, `mktemp`, `cp`, `rm`. Requires
`tests/constitution_inheritance_gate.sh` (the gate under test) and
`constitution/meta_test_inheritance.sh` (the generic mutator); a missing
shipped mutator FAILs the meta-test.

## Edge cases

- **Anchor absent BEFORE mutation** → the mutation is a precondition FAIL
  (`anchor not present BEFORE mutation`), never a silent skip.
- **Target file missing** → FAIL for that mutation.
- **Baseline gate FAILs on the clean tree** → reported first, so a broken gate
  is not mistaken for genuine mutation-catching.
- **Interrupt mid-mutation** → the trap restores the in-flight file from its
  backup before exit.

## Related scripts

- `tests/constitution_inheritance_gate.sh` — the gate under test.
- `constitution/meta_test_inheritance.sh` — the constitution-shipped generic
  §11.4 mutator this test also drives.
- `tests/test_constitution_inheritance.sh` — the sibling inheritance test.
- Constitution §1.1 (paired-mutation discipline), §11.4.84 (working-tree
  quiescence), §11.4.35 (canonical-root inheritance).

## Last verified

2026-07-01 — documented against the script source; `sh -n` / `bash -n`
parse-clean. Executed as part of the §1.1 anti-bluff gate suite; the tree is
left quiescent on exit.
