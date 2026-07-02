# `tests/dynamic/suites/run_all_suites.sh` — operator guide

**Revision:** 1
**Last modified:** 2026-07-01T00:00:00Z
**Status:** Active orchestrator for the six §11.4.169 dynamic data-plane suites.
Honest-SKIPs (`topology_unsupported`) until the live `dynamic` stack lands (P10,
§11.4.69) — never a fake PASS.

> Companion (§11.4.18) to the in-source documentation block at the top of the
> script.

## Overview

Runs every §11.4.169 dynamic data-plane suite (stress, chaos, concurrency/race,
ddos/flood, memory soak, benchmark) and aggregates PASS / FAIL / SKIP. The suites
drive the live `dynamic` stack; when it is absent (today — design-only) every
suite emits an honest §11.4.69 SKIP-with-reason and this orchestrator records it
as SKIP. Exit `0` iff there is **no FAIL** (all PASS or honest SKIP).

## Prerequisites

- `bash`/`sh`, `grep`, `tee`, `date`.
- The six suite scripts present under `tests/dynamic/suites/`.
- For real (non-SKIP) runs in P10: `HELIX_DYNAMIC_STACK=1` + `HELIX_PROXY_URL`
  pointing at the live `dynamic` proxy, plus the per-suite injection/hook env
  vars each suite documents.
- Write access to `qa-results/` (gitignored) for the aggregate log.

## Usage examples

```bash
# Today (no live stack): every suite honest-SKIPs, orchestrator exits 0:
bash tests/dynamic/suites/run_all_suites.sh

# P10 live run (GREEN guards):
HELIX_DYNAMIC_STACK=1 HELIX_PROXY_URL=http://127.0.0.1:34128 \
    bash tests/dynamic/suites/run_all_suites.sh

# P10 RED-baseline polarity (reproduce defects on the pre-fix stack):
HELIX_DYNAMIC_STACK=1 HELIX_PROXY_URL=... RED_MODE=1 \
    bash tests/dynamic/suites/run_all_suites.sh
```

## Edge cases

- **Live stack absent** → all six suites SKIP; aggregate RESULT notes
  `all N suites honest-SKIPped (live dynamic stack absent; run in P10)`; exit `0`.
- **A suite script missing** → counted as `FAIL`.
- **A suite emits no `PASS`/`FAIL`/`SKIP` verdict line** → treated as `FAIL`
  (`no PASS/FAIL/SKIP verdict emitted`) — an unclassifiable suite is never a
  pass.
- **Any FAIL** → aggregate exit `1` (`investigate per §11.4.102`).

## Internal behaviour

- `#!/usr/bin/env bash`, POSIX-clean (`sh -n` + `bash -n`, §11.4.67).
- Iterates the fixed suite list, runs each via `sh "$script"`, and classifies by
  the **last** `PASS:`/`FAIL:`/`SKIP:` verdict line the suite emitted.
- Tees the full report to `qa-results/p9-harness/<run-id>/suite_results.txt`.
- Final exit: `grep -q '^FAIL:'` → exit `1`, else exit `0`.

## Related

- The six suites it orchestrates: `stress_suite.sh`, `chaos_suite.sh`,
  `concurrency_race_suite.sh`, `ddos_flood_suite.sh`, `memory_soak_suite.sh`,
  `benchmark_suite.sh`.
- `tests/dynamic/lib/analyzer_common.sh` — the base each suite sources.
- Constitution §11.4.69 / §11.4.85 / §11.4.169 / §11.4.115; design spec §13.

## Last verified

2026-07-01 — run with no live stack: all six suites honest-SKIP
(`topology_unsupported`), aggregate exit `0`; `sh -n` + `bash -n` parse-clean.
Live PASS/FAIL classification is exercised in **P10**.
