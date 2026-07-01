# `tests/regression/no_suspend_export_sibling_test.sh` — operator guide

**Revision:** 1
**Last modified:** 2026-07-01T06:30:00Z
**Status:** Active standing regression guard (§11.4.135) for BUGFIX-0011.

> Companion (§11.4.18) to the in-source documentation block at the top of the
> script. Sibling of `docs/scripts/comprehensive_admin_topology_test.md`.

## Overview

A standing regression guard that proves the CONST-033 static scanner
`scripts/host-power-management/check-no-suspend-calls.sh` excludes a
**documentation ledger's §11.4.65 export siblings** (`.html` / `.pdf`), not only
its `.md` source.

Pre-fix, `EXCLUDE_PATHS` carried the bugfix ledger with an explicit `.md`
extension (`/docs/issues/fixed/BUGFIXES.md`). The ledger legitimately quotes the
banned host-power patterns when **documenting** a CONST-033 fix (e.g. a §1.1
mutation example `systemctl suspend`). When `BUGFIXES.md` was exported to
`BUGFIXES.html` per §11.4.65, that literal landed in a sibling the `.md`-anchored
exclusion did **not** cover — so the scanner tripped on its own fix documentation
(`BUGFIXES.html:1210`): a §11.4.1 **false-FAIL**. The same sibling-blindness class
as the `HOST_POWER_MANAGEMENT.` entry fixed one commit earlier (BUGFIX-0010).

The fix makes the exclusion **extension-agnostic** — the prefix
`/docs/issues/fixed/BUGFIXES.` covers `.md` + `.html` + `.pdf` — while a
**non-ledger** `.html` and any **real script invocation** still trip the scanner
(the gate is not neutered, §11.4.120).

It does **not** grep the source. It builds a throwaway fixture tree and drives the
**real** scanner, so it is deterministic and independent of the live ledger's
current content.

## Prerequisites

- POSIX `sh`, `sed`, `mktemp`, `grep`, `awk`. No network, no privileges.

## Usage examples

```bash
# GREEN guard (default) — assert the real scanner excludes a ledger .html sibling
# AND still catches a real script invocation:
tests/regression/no_suspend_export_sibling_test.sh            # exit 0 = PASS

# RED reproduce — the ".md"-only replica trips on the ledger .html sibling:
RED_MODE=1 tests/regression/no_suspend_export_sibling_test.sh # exit 0 = defect reproduced

# Runs automatically inside the suite:
bash tests/run-tests.sh                                       # test_regression_guards()
```

## §11.4.115 RED_MODE polarity

| `RED_MODE` | What it runs | PASS means |
|---|---|---|
| `0` (default) | the REAL `check-no-suspend-calls.sh` against a fixture ROOT holding a ledger `docs/issues/fixed/BUGFIXES.html` (quotes the banned literal) **and** a real `scripts/real_invocation.sh` | the ledger `.html` is **not** in the violation list (excluded) **and** the real script **is** (still caught) → the sibling exclusion is present and the gate is not neutered (GREEN guard) |
| `1` | a PRE-FIX replica (`EXCLUDE_PATHS` reverted to `.md`-only via `sed`) against a ledger-`.html`-only ROOT | the replica FAILs on `BUGFIXES.html` → the sibling-blind false-FAIL reproduces |

A `RED_MODE=1` run that cannot reproduce is a finding per §11.4.7, not a pass.

## Edge cases

- **Fix reverted** (exclusion flipped back to `/docs/issues/fixed/BUGFIXES.md`) →
  the GREEN guard reports `REGRESSION: ledger_flagged=yes …` and exits 1. This is
  the §1.1 paired-mutation behaviour, verified against the real scanner.
- **Non-ledger `.html`** containing the literal → still trips (the exclusion is
  BUGFIXES-specific, not "all `.html`").
- **`cleanup` trap** forces `return 0` so a conditional last command never leaks a
  non-zero status into the script exit under `set -e` (§11.4.1).

## Internal behaviour

- `#!/bin/sh`, `set -eu`; POSIX-only, `sh -n` parse-clean (§11.4.67).
- Fixture ROOT under `mktemp -d`, removed on every exit path (§11.4.14).
- Writes one evidence file per run under
  `qa-results/regression/no_suspend_export_sibling/` (gitignored).

## Related

- Fix site: `scripts/host-power-management/check-no-suspend-calls.sh`
  (`EXCLUDE_PATHS` — `/docs/issues/fixed/BUGFIXES.`).
- Standing challenge: `challenges/scripts/no_suspend_calls_challenge.sh`.
- Sibling guard: `docs/scripts/comprehensive_admin_topology_test.md`.
- `tests/run-tests.sh` — registers this guard via `test_regression_guards()`.
- `docs/issues/fixed/BUGFIXES.md` — BUGFIX-0011.

## Last verified

2026-07-01 — `sh -n` parse-clean; GREEN excludes the ledger `.html` sibling +
catches the real script (exit 0); `RED_MODE=1` reproduces (exit 0); paired
mutation (revert exclusion) makes GREEN FAIL (exit 1) then restores byte-identical;
registered in `run-tests.sh`.
