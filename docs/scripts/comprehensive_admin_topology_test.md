# `tests/regression/comprehensive_admin_topology_test.sh` — operator guide

**Revision:** 1
**Last modified:** 2026-07-01T05:00:00Z
**Status:** Active standing regression guard (§11.4.135) for BUGFIX-ADMIN-TOPOLOGY.

> Companion (§11.4.18) to the in-source documentation block at the top of the
> script. Sibling of `docs/scripts/port_topology_aware_test.md`.

## Overview

A standing regression guard that proves `tests/comprehensive-test.sh` never
reports a **PASS** for a host port that is held by a **non-project process**.

Pre-fix, `test_ports()` and `test_admin()` decided admin health purely on
"is *something* listening on / answering 200 at `:58080`?". In the CI/host
topology the project's `proxy-admin` container is **unpublished** (internal port
only) while `:58080` is held by an unrelated `whoami` service that answers HTTP
200 to *any* path — and even echoes `Hostname: proxy-admin`. So three checks
(`Admin port listening`, `Admin health endpoint`, `Admin main page`) were
**false PASSes hitting the foreign service** — a §11.4.68/§11.4.69
fail-open-to-whatever-answers bluff.

The fix gates the verdict on **project-container ownership**: a listening port is
proof only if the named project container is running **and** publishes it
(`podman port <owner> | grep :<port>`). A port that is listening but not
project-published is a `SKIP`, never a `PASS`.

It does **not** grep the source. It extracts the **real** `_port_topology_check()`
from `tests/comprehensive-test.sh` and drives it with stubbed
container/runtime/`ss`, so it is deterministic and never touches the data plane.

## Prerequisites

- `bash` (the extracted `_port_topology_check` uses `[[ ]]`/`local`; the probe
  runs under `bash`).
- `awk`, `mktemp`. No network, no container access, no privileges.

## Usage examples

```bash
# GREEN guard (default) — assert the real check refuses the fail-open + PASSes owned:
tests/regression/comprehensive_admin_topology_test.sh            # exit 0 = PASS

# RED reproduce — replicate the pre-fix listening=>PASS logic and assert the bluff:
RED_MODE=1 tests/regression/comprehensive_admin_topology_test.sh # exit 0 = defect reproduced

# Runs automatically inside the suite:
bash tests/run-tests.sh                                          # test_regression_guards()
```

## §11.4.115 RED_MODE polarity

| `RED_MODE` | What it runs | PASS means |
|---|---|---|
| `0` (default) | the REAL `_port_topology_check()` from `tests/comprehensive-test.sh` | a foreign-held port (owner **not** publishing, a non-project process listening) → `SKIP`, and an owner-published+listening port → `PASS` → the fix is present (GREEN guard) |
| `1` | the PRE-FIX replica (`listening => PASS`) | the foreign-held port is classified `PASS` → the fail-open bluff reproduces |

A `RED_MODE=1` run that *cannot* reproduce (replica does not PASS the
foreign-held port) is a finding per §11.4.7, not a pass.

The honest truth-table the GREEN guard asserts (`owner` = the named project
container, `published` = `podman port <owner>` shows the port):

| `published` | `listening` | verdict | meaning |
|---|---|---|---|
| yes | yes | `PASS` | project service up and serving on the published port |
| yes | no  | `FAIL` | owner publishes the port but nothing is bound |
| no  | yes | `SKIP` | a **non-project** process holds the port — not the project's service (§11.4.68) |
| no  | no  | `SKIP` | service not deployed in this topology (§11.4.3) |

## Edge cases

- **Fix reverted** (e.g. `_port_topology_check` flipped back to
  `ss | grep => PASS`) → the GREEN guard reports
  `REGRESSION: … fail-open bluff reintroduced …` and exits 1. This is the §1.1
  paired-mutation behaviour.
- **Admin genuinely published** (`proxy-admin` publishes `:58080`) → the guard's
  owned-scenario cell still asserts `PASS`, so the fix does not over-SKIP a real
  admin.
- **Runtime is docker** → the extracted function's `docker port` branch is
  exercised identically (the guard stubs `get_runtime`).

## Internal behaviour

- `#!/bin/sh`, `set -eu`; the bash-only extracted function runs inside an explicit
  `bash` probe (§11.4.67).
- Extraction: `awk '/^_port_topology_check\(\) \{/{f=1} f{print} /^\}/{if(f){exit}}'`
  pulls the live function (closing `}` at column 0).
- Writes one evidence file per run under
  `qa-results/regression/comprehensive_admin_topology/` (gitignored).

## Related

- Fix site: `tests/comprehensive-test.sh` — `_port_topology_check()` +
  `test_ports()` / `test_admin()` (§11.4.68/§11.4.69 ownership gate).
- Sibling guard: `docs/scripts/port_topology_aware_test.md` (same class for
  `tests/run-tests.sh`).
- `tests/run-tests.sh` — registers this guard via `test_regression_guards()`.
- `docs/issues/fixed/BUGFIXES.md` — BUGFIX-0010.

## Last verified

2026-07-01 — `sh -n` parse-clean; GREEN proves the fix
(`FOREIGN_VERDICT=SKIP` + `OWNED_VERDICT=PASS`); `RED_MODE=1` reproduces
(`FOREIGN_VERDICT=PASS`); registered in `run-tests.sh` (41 pass / 0 fail /
6 skip, exit 0); `comprehensive-test.sh` full run 35 pass / 0 fail / 8 skip.
