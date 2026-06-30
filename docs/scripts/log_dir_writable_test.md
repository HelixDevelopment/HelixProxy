# `tests/regression/log_dir_writable_test.sh` — operator guide

**Revision:** 1
**Last modified:** 2026-07-01T00:00:00Z
**Status:** Active standing regression guard (§11.4.135) for BUGFIX-0002.

> Companion (§11.4.18) to the in-source documentation block at the top of the
> script. Pairs with `docs/issues/fixed/BUGFIXES.md` (BUGFIX-0002).

## Overview

A standing regression guard that proves the proxy orchestrator creates the
squid **log** bind-mount directory **world-writable**, so the squid container's
non-root `proxy` user (remapped to a high subuid under rootless Podman) can open
`/var/log/squid/access.log`. Without it squid `FATAL`s and crash-loops and the
proxy serves nothing — the BUGFIX-0002 defect.

It does **not** grep the source. It exercises the **real** orchestrator code:
it sources `lib/container-runtime.sh` with the environment pointed at a throwaway
temp root, calls `create_directories()`, then `stat`s the resulting log dir and
asserts the world-write bit is set.

## Prerequisites

- `bash` (the guard sources the bash-only runtime lib inside an explicit
  `bash -c` so the outer `/bin/sh` parser sees only a string — §11.4.67).
- GNU `stat`, `mktemp`. **Linux-only** — the rootless-Podman bind-mount
  UID-shift this guards is a Linux `/etc/subuid` mechanism (§11.4.81 honest
  scope; on a platform without subuid remapping the guard is N/A).

## Usage examples

```bash
# GREEN guard (default) — assert the real orchestrator makes LOG_DIR writable:
tests/regression/log_dir_writable_test.sh            # exit 0 = PASS

# RED reproduce — replicate the pre-fix behaviour and assert the defect:
RED_MODE=1 tests/regression/log_dir_writable_test.sh # exit 0 = defect reproduced

# Runs automatically inside the suite:
bash tests/run-tests.sh                              # test_regression_guards()
```

## §11.4.115 RED_MODE polarity

| `RED_MODE` | What it runs | PASS means |
|---|---|---|
| `0` (default) | the REAL `create_directories()` from the lib | LOG_DIR is world-writable → the fix is present (GREEN guard) |
| `1` | the PRE-FIX replica (`mkdir` only, no `chmod`) | LOG_DIR is NOT world-writable → the defect reproduces |

A `RED_MODE=1` run that *cannot* reproduce (dir already writable without the fix)
is a finding per §11.4.7, not a pass.

## Edge cases

- **Fix reverted / removed** → the GREEN guard reports
  `REGRESSION: … mode=755 NOT world-writable` and exits 1. This is the §1.1
  paired-mutation behaviour: stripping `chmod 777 "$LOG_DIR"` from
  `create_directories()` makes the guard FAIL (proven byte-identical-restore
  in BUGFIX-0002).
- **Non-Linux host** → `stat -c` / subuid semantics differ; treat as N/A.
- **Temp dir** is created with `mktemp -d` and removed on every exit path
  (`trap … EXIT INT TERM`, §11.4.14).

## Internal behaviour

- `#!/bin/sh`, `set -eu`; POSIX-only constructs in the outer script (bash-only
  lib sourcing is wrapped in `bash -c`).
- World-write detection: last octal digit of `stat -c '%a'` has the 2-bit set
  (`2|3|6|7`).
- Writes one evidence file per run under
  `qa-results/regression/bugfix38/` (gitignored).

## Related

- Fix sites: `lib/container-runtime.sh` (`create_directories()`),
  `start` (`init_cache()`).
- `docs/issues/fixed/BUGFIXES.md` — BUGFIX-0002 root-cause + verification.
- `tests/run-tests.sh` — registers this guard via `test_regression_guards()`.

## Last verified

2026-07-01 — `sh -n` + `bash -n` parse-clean; RED reproduces (mode 755),
GREEN proves the fix (mode 777); §1.1 mutation makes the GREEN guard FAIL and
the lib restores byte-identical (md5 `0128a96b6d467c2da5b7cef8a808e563`).
