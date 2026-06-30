# `tests/regression/port_topology_aware_test.sh` — operator guide

**Revision:** 1
**Last modified:** 2026-07-01T00:00:00Z
**Status:** Active standing regression guard (§11.4.135) for BUGFIX-PORTS.

> Companion (§11.4.18) to the in-source documentation block at the top of the
> script. Pairs with `docs/research/existing_test_bluffs_audit/README.md`.

## Overview

A standing regression guard that proves `tests/run-tests.sh` never reports a
**healthy, serving** proxy port as a **failure**. The pre-fix `test_ports`
treated *any* port that was IN USE as `FAIL`, so the running proxy's own
listening ports (squid `53128`, dante `51080`) were reported as failures and
the whole suite exited `1` against a perfectly healthy serving proxy — a
§11.4.1 false-FAIL (as forbidden as a false-PASS).

It does **not** grep the source. It exercises the **real** decision code: it
extracts the current pure `port_verdict()` from `tests/run-tests.sh` and drives
the full §11.4.3 topology truth-table, asserting the healthy
"owner serving + port listening" case returns `PASS` (defect ABSENT). Because it
tests the **pure** decision function, it is fully deterministic and never
depends on live `podman`/`ss` state nor touches any container or the data plane.

## Prerequisites

- `bash` (the extracted `port_verdict` uses bash `local`; the probe runs under
  `set -euo pipefail`).
- `awk`, `mktemp`. No network, no container access, no privileges.

## Usage examples

```bash
# GREEN guard (default) — assert the real port_verdict truth-table is honest:
tests/regression/port_topology_aware_test.sh            # exit 0 = PASS

# RED reproduce — replicate the pre-fix logic and assert the bluff:
RED_MODE=1 tests/regression/port_topology_aware_test.sh # exit 0 = defect reproduced

# Runs automatically inside the suite:
bash tests/run-tests.sh                                 # test_regression_guards()
```

## §11.4.115 RED_MODE polarity

| `RED_MODE` | What it runs | PASS means |
|---|---|---|
| `0` (default) | the REAL `port_verdict()` from `tests/run-tests.sh` | the healthy serving port (`owner_serving=yes, listening=yes`) → `PASS`, plus `FAIL`/`PASS`/`SKIP` cells correct → the fix is present (GREEN guard) |
| `1` | the PRE-FIX replica (`listening => FAIL`) | the healthy serving port is classified `FAIL` → the bluff reproduces |

A `RED_MODE=1` run that *cannot* reproduce (replica does not FAIL the healthy
port) is a finding per §11.4.7, not a pass.

The honest truth-table the GREEN guard asserts:

| `owner_serving` | `listening` | verdict | meaning |
|---|---|---|---|
| yes | yes | `PASS` | service up and serving (squid/dante healthy) |
| yes | no  | `FAIL` | owner up + publishing but nothing listening |
| no  | no  | `PASS` | pre-start: port free, ready for `./start` |
| no  | yes | `SKIP` | pre-start, but a **non-project** process holds the port — readiness not assertable (§11.4.3) |

## Edge cases

- **Fix reverted** (e.g. `port_verdict` flipped so a serving port returns
  `FAIL`) → the GREEN guard reports
  `REGRESSION: … HEALTHY=FAIL …` and exits 1. This is the §1.1 paired-mutation
  behaviour: flipping the PASS/FAIL branch makes the guard FAIL (proven
  byte-identical-restore in BUGFIX-PORTS).
- **58080 held by a foreign host process** → in the live suite the control-API
  port has no project owner publishing it; if a non-project process occupies it
  the per-port check is a `SKIP` (not a false-FAIL blaming the proxy, not a
  false-PASS). Both occupied→SKIP and free→PASS keep the suite at 0 failures —
  the guard tests the pure decision so it is unaffected by that live variation.
- **`podman`/`ss` absent at suite runtime** → `_ports_check_one` resolves
  `owner_serving=no` and classifies on listener presence; the pure guard does
  not depend on either tool.

## Internal behaviour

- `#!/bin/sh`, `set -eu`; POSIX-only constructs in the outer script (the
  bash-only `port_verdict` runs inside an explicit `bash` probe — §11.4.67).
- Extraction: `awk '/^port_verdict\(\) \{/{f=1} f{print} /^\}/{if(f){exit}}'`
  pulls the live function (closing `}` at column 0).
- Writes one evidence file per run under
  `qa-results/regression/portstopology/` (gitignored).

## Related

- Fix site: `tests/run-tests.sh` — `port_verdict()` + `test_ports()` /
  `_ports_check_one()` (§11.4.3 topology-aware dispatch).
- `docs/research/existing_test_bluffs_audit/README.md` — the bluff audit
  (port false-FAIL + B7 SKIP-as-PASS).
- `tests/run-tests.sh` — registers this guard via `test_regression_guards()`.

## Last verified

2026-07-01 — `sh -n` + `bash -n` parse-clean; RED reproduces
(`VERDICT=FAIL` for a healthy serving port); GREEN proves the fix
(`HEALTHY=PASS NOTSERVING=FAIL PRESTART_FREE=PASS PRESTART_BUSY=SKIP`); §1.1
mutation (flip the PASS/FAIL branch) makes the GREEN guard FAIL with `bash -n`
still clean (assertion, not parse error), and `tests/run-tests.sh` restores
byte-identical (md5 `2f4d3e4bf33cd391036cee595839d439`). Full suite against the
healthy running proxy: 43 run / 37 pass / 6 skip / 0 fail, exit 0.
