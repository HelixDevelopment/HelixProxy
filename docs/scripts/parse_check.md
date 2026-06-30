# `tests/dynamic/parse_check.sh` — operator guide

**Revision:** 1
**Last modified:** 2026-07-01T00:00:00Z
**Status:** Active §11.4.67 target-shell parseability gate for the dynamic test
tree (P9 harness). Wire into the project `pre_build` sweep in P10.

> Companion (§11.4.18) to the in-source documentation block at the top of the
> script.

## Overview

A re-runnable §11.4.67 pre-build gate that asserts **every** shell script under
`tests/dynamic/` parses cleanly under **both** `sh -n` and `bash -n` — i.e. no
bash-only construct leaks outside an `eval`. Android `mksh` and other POSIX
shells parse a whole script before executing it, so a bash-only construct that a
runtime guard "protects" still aborts at parse time; this gate catches that class
at source time.

## Prerequisites

- `bash` (the runner shebang) plus `sh` and `bash` both on `PATH` (it runs each
  script through both parsers).
- `find`, `sort`, `tee`, `grep`, `date`.
- Write access to `qa-results/` (gitignored) for the run log.

## Usage examples

```bash
# Run the gate over the whole dynamic tree:
bash tests/dynamic/parse_check.sh            # exit 0 = all scripts parse-clean

# Inspect the per-run log it tees:
cat qa-results/p9-harness/<run-id>/parse_check.log
```

## Edge cases

- **A bash-only construct outside `eval`** (e.g. `>( )`, `<<<`, `[[ ]]`, arrays,
  `${v^^}`) → the offending script reports `FAIL` with the captured `sh -n` /
  `bash -n` diagnostic, and the gate exits `1`. Fix at **source** per §11.4.67,
  never patch the call site.
- **Empty tree / no `*.sh` found** → `scripts=0`, RESULT line still printed,
  exit `0` (nothing to fail).
- **New script added under `tests/dynamic/`** → automatically enumerated next run
  (depth-N `find`), no list to maintain.

## Internal behaviour

- `#!/usr/bin/env bash`; resolves its own dir + the repo root, stamps a UTC
  `RUN_ID`, and tees the full report to
  `qa-results/p9-harness/<run-id>/parse_check.log`.
- Enumerates `find "$DIR" -type f -name '*.sh' | sort`, then for each runs
  `sh -n` and `bash -n`, capturing both diagnostics.
- A script is `OK` only when **both** parsers return 0; otherwise `FAIL` with the
  captured errors.
- Final exit: `grep -q '^FAIL ' "$OUT"` → exit `1`, else exit `0`.

## Related

- Every `*.sh` under `tests/dynamic/` (lib, analyzers, suites) — the gate's
  scope.
- `tests/dynamic/analyzers/run_analyzer_selftests.sh` — the sibling
  self-validation gate (analyzer correctness vs. this gate's parseability).
- Constitution §11.4.67 (target-shell parseability); design spec §13.

## Last verified

2026-07-01 — run over the dynamic tree: all scripts parse under `sh -n` AND
`bash -n`; the gate itself is `sh -n` + `bash -n` parse-clean.
