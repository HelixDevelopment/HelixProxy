# `tests/regression/test_result_returns_zero_test.sh` — operator guide

**Revision:** 1
**Last modified:** 2026-07-01T00:00:00Z
**Status:** Active standing regression guard (§11.4.135) for BUGFIX-0003.

> Companion (§11.4.18) to the in-source documentation block at the top of the
> script. Pairs with `docs/issues/fixed/BUGFIXES.md` (BUGFIX-0003).

## Overview

A standing regression guard that proves `tests/run-tests.sh`'s `test_result`
reporting helper **always returns 0**, even on a FAIL with no message. The
pre-fix helper ended on a bare `[[ -n "$message" ]] &&` short-circuit that
returns 1 when the message is empty; when such a `test_result` was the last
command of a test function, the function returned 1 and `set -euo pipefail`
aborted the whole suite mid-run — most tests never executed and no summary
printed (BUGFIX-0003).

It does **not** grep the source. GREEN extracts the **real** current
`test_result` from `tests/run-tests.sh`, runs it under `set -euo pipefail`
with a no-message FAIL, and asserts the process survives (exit 0).

## Prerequisites

- `bash` (the extracted `test_result` uses bash `[[ ]]` / `local`; the guard
  wraps it in a `bash` probe so the outer `/bin/sh` parser stays POSIX-clean,
  §11.4.67).
- `mktemp`.

## Usage examples

```bash
# GREEN guard (default) — assert the real test_result survives a no-message FAIL:
tests/regression/test_result_returns_zero_test.sh            # exit 0 = PASS

# RED reproduce — run the pre-fix replica and assert it aborts:
RED_MODE=1 tests/regression/test_result_returns_zero_test.sh # exit 0 = defect reproduced

# Runs automatically inside the suite:
bash tests/run-tests.sh                                      # test_regression_guards()
```

## §11.4.115 RED_MODE polarity

| `RED_MODE` | What it runs | PASS means |
|---|---|---|
| `0` (default) | the REAL `test_result` extracted from `tests/run-tests.sh` | it survives a no-message FAIL under `set -e` → the fix is present (GREEN guard) |
| `1` | a faithful PRE-FIX replica (last command is the bare `&&`) | it aborts under `set -e` → the defect reproduces |

A `RED_MODE=1` run that *cannot* reproduce (replica survives) is a finding per
§11.4.7, not a pass.

## Edge cases

- **Fix reverted** (the `return 0` removed from `test_result`) → the GREEN guard
  reports `REGRESSION: test_result aborts the suite …` and exits 1. This is the
  §1.1 paired-mutation behaviour (proven byte-identical-restore in BUGFIX-0003).
- **Temp probe** is created with `mktemp` and removed on every exit path
  (`trap … EXIT INT TERM`, §11.4.14).

## Internal behaviour

- `#!/bin/sh`, `set -eu`; POSIX-only outer script (the bash probe is built into
  a temp file and run with `bash`).
- GREEN extracts `test_result` verbatim via `awk` from the tracked suite so it
  always tests the actual current code, never a stale copy.
- Writes one evidence file per run under `qa-results/regression/bugfix0003/`
  (gitignored).

## Related

- Fix site: `tests/run-tests.sh` `test_result()` (`return 0`).
- `docs/issues/fixed/BUGFIXES.md` — BUGFIX-0003 root-cause + verification.
- `tests/run-tests.sh` — registers this guard via `test_regression_guards()`.
- Sibling guard: `tests/regression/log_dir_writable_test.sh` (BUGFIX-0002).

## Last verified

2026-07-01 — `sh -n` + `bash -n` parse-clean; RED reproduces (pre-fix replica
aborts, rc=1), GREEN proves the fix (real test_result survives); §1.1 mutation
makes the GREEN guard FAIL and `tests/run-tests.sh` restores byte-identical
(md5 `7c2bab18c4566d081b1c8aa7a9a412e0`). Full suite runs to completion
(41 tests, summary printed).
