# `tests/dynamic/suites/stress_suite.sh` — operator guide

**Revision:** 1
**Last modified:** 2026-07-01T00:00:00Z
**Status:** Authored for P10. Honest-SKIPs (`topology_unsupported`, §11.4.69)
until the live `dynamic` stack lands; parse-clean + authored today.

> Companion (§11.4.18) to the in-source documentation block at the top of the
> script.

## Overview

§11.4.85 / §11.4.169 **stress** suite for the dynamic data plane: sustained-load
+ concurrent-contention against the live `dynamic` stack (Squid + external_acl
helper + gluetun + Redis). It runs N≥100 sequential requests + N≥10 concurrent
requests, captures each request's `%{http_code}` to its **own file** (so a verdict
never rests on a job exit status), and records the latency/200-ratio. Every PASS
cites a captured-evidence artefact — no metadata-only PASS (§11.4.69).

## Prerequisites

- Source library `tests/dynamic/lib/analyzer_common.sh` + committed
  `tests/lib/evidence.sh`.
- `curl`, POSIX `sh`, `date`.
- For a real (non-SKIP) run: `HELIX_DYNAMIC_STACK=1` + `HELIX_PROXY_URL`.
- Write access to `qa-results/` (gitignored).

## Usage examples

```bash
# Today (no live stack): honest SKIP, exit 0:
bash tests/dynamic/suites/stress_suite.sh

# P10 live run with overrides:
HELIX_DYNAMIC_STACK=1 HELIX_PROXY_URL=http://127.0.0.1:53128 \
    STRESS_SEQ=100 STRESS_CONC=10 bash tests/dynamic/suites/stress_suite.sh
```

Env knobs: `STRESS_SEQ` (default 100), `STRESS_CONC` (default 10),
`STRESS_TARGET` (default `http://target-a.internal/`), `STRESS_OK_RATIO_PCT`
(min % of 200s for GREEN, default 95).

## Edge cases

- **Live stack absent** → `dyn_skip_if_no_stack` emits `topology_unsupported`
  SKIP, prints the P10 note, exits `0`.
- **200-ratio below `STRESS_OK_RATIO_PCT`** under sustained/concurrent load →
  `FAIL` citing `stress.evidence`.
- **Concurrent burst** uses one code-file per worker (the B3 bluff fix); a
  worker that errors writes `000`, never relies on `$?`.

## §11.4.115 RED_MODE polarity

| `RED_MODE` | What it asserts | PASS means |
|---|---|---|
| `0` (default) | GREEN guard | stack **sustains** the load (ratio ≥ `STRESS_OK_RATIO_PCT`) |
| `1` | RED baseline | the pre-fix/throttled stack **collapses** (ratio < threshold) → defect reproduced |

A `RED_MODE=1` run where the stack does NOT collapse is a finding (`defect not
reproduced`), not a pass.

## Internal behaviour

- `#!/usr/bin/env bash`, POSIX-clean (`sh -n` + `bash -n`, §11.4.67).
- Sequential loop → `seq.N.code`; concurrent burst → `conc.N.code` (bounded by
  `STRESS_CONC`, `nice`); ratio + counts written to `stress.evidence`.
- GREEN requires both the sequential ratio and the concurrent-OK count to meet
  the threshold; otherwise FAIL. Evidence dir:
  `qa-results/p9-harness/stress_<run-id>/`.
- Resources: shell+curl only, capped concurrency, well under the §12.6 60%
  host-memory ceiling.

## Related

- `tests/dynamic/lib/analyzer_common.sh` — sourced base (`ab_pass_with_evidence`,
  `dyn_skip_if_no_stack`, `dyn_red_mode`).
- `tests/dynamic/suites/run_all_suites.sh` — orchestrates this suite.
- Constitution §11.4.85 / §11.4.69 / §11.4.107 / §11.4.115 / §11.4.50 / §12.6;
  design spec §13.

## Last verified

2026-07-01 — run with no live stack: honest SKIP (`topology_unsupported`), exit
`0`; `sh -n` + `bash -n` parse-clean. Live sustained/concurrent load is exercised
in **P10**.
