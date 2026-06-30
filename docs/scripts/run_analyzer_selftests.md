# `tests/dynamic/analyzers/run_analyzer_selftests.sh` — operator guide

**Revision:** 1
**Last modified:** 2026-07-01T00:00:00Z
**Status:** Active §11.4.107(10) self-validation runner for all six dynamic
data-plane analyzers. **Runnable today** against bundled fixtures — no live
stack, no network.

> Companion (§11.4.18) to the in-source documentation block at the top of the
> script.

## Overview

Runs every dynamic data-plane analyzer's built-in self-test and aggregates the
result. Each analyzer must PASS its **golden-good** fixture AND FAIL its
**golden-bad** fixture (the §11.4.107(10) self-validated-analyzer proof). An
analyzer that passes its own golden-bad is a bluff gate, and this runner exits
non-zero so it cannot ship.

This is the part of the dynamic harness that is **runnable immediately**: it
validates analyzer correctness against the committed fixtures with zero network
and no live `dynamic` stack.

## Prerequisites

- `bash`/`sh`, `awk`, `grep`, `tr` on `PATH`.
- The six analyzers and their fixtures present under
  `tests/dynamic/analyzers/` (each `<signal>/fixtures/…`).
- The committed `tests/lib/evidence.sh` (most analyzers delegate to it; a missing
  lib makes the delegating analyzers FAIL honestly, surfacing here as a
  self-test failure rather than a bluff).
- Write access to `qa-results/` (gitignored) for the TAP artefact.

## Usage examples

```bash
# Self-validate all six analyzers (golden-good PASS + golden-bad FAIL):
bash tests/dynamic/analyzers/run_analyzer_selftests.sh   # exit 0 = all valid

# Inspect the aggregated TAP artefact:
cat qa-results/p9-harness/<run-id>/analyzer_selftests.tap
```

## Edge cases

- **An analyzer passes its golden-bad fixture** → that analyzer's self-test
  exits non-zero, the runner marks it `not ok`, and the aggregate exits `1`
  (`do NOT ship`). This is the §1.1 paired-mutation behaviour for the analyzers.
- **An analyzer script is missing** → reported `MISSING` (`not ok`) and counted
  as a failure.
- **`evidence.sh` absent** → delegating analyzers FAIL their golden-good
  self-test (cannot delegate), surfacing as a self-test failure — never a silent
  pass.

## Internal behaviour

- `#!/usr/bin/env bash`, POSIX-clean (`sh -n` + `bash -n`, §11.4.67).
- Iterates the fixed list of six analyzers
  (`no_leak`, `graceful_503`, `egress_neq_host`, `xcache_hit`,
  `dns_no_plaintext_53`, `auth_407`), runs each with `--selftest`, and reuses the
  `analyzer_common.sh` TAP harness verdicts.
- Emits per-analyzer TAP plus an aggregate `1..N` plan and a RESULT line; tees
  everything to `qa-results/p9-harness/<run-id>/analyzer_selftests.tap`.
- Final exit: `grep -q '^not ok '` → exit `1`, else exit `0`.

## Related

- The six analyzers under `tests/dynamic/analyzers/*.sh` it drives.
- `tests/dynamic/lib/analyzer_common.sh` — supplies the self-test TAP harness.
- `tests/dynamic/parse_check.sh` — the sibling parseability gate.
- Constitution §11.4 / §11.4.69 / §11.4.107 / §1.1; design spec §13/§14.

## Last verified

2026-07-01 — run against the bundled fixtures: all six analyzers self-validate
(golden-good PASS + golden-bad FAIL); `sh -n` + `bash -n` parse-clean.
