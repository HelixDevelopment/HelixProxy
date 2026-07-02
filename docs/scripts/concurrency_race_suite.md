# `tests/dynamic/suites/concurrency_race_suite.sh` — operator guide

**Revision:** 1
**Last modified:** 2026-07-01T00:00:00Z
**Status:** Authored for P10. Honest-SKIPs (`topology_unsupported`, §11.4.69)
until the live `dynamic` stack lands; parse-clean + authored today.

> Companion (§11.4.18) to the in-source documentation block at the top of the
> script.

## Overview

§11.4.169 **concurrency / race** suite for the `external_acl` helper. Under heavy
concurrent load it asserts: (a) every parallel request gets a **correct,
consistent** routing decision (no torn Redis read, no cross-request bleed),
(b) **no deadlock/hang** (every request returns within the timeout), (c)
**determinism** across the burst (§11.4.50 — identical inputs → identical
outcomes). Per-request `%{http_code}` is captured to its own file (the B3 bluff
fix — never a job exit status).

## Prerequisites

- Source library `tests/dynamic/lib/analyzer_common.sh` + committed
  `tests/lib/evidence.sh`.
- `curl`, `awk`, `sort`, POSIX `sh`, `date`.
- For a real run: `HELIX_DYNAMIC_STACK=1` + `HELIX_PROXY_URL`.
- Optional direct-helper probe: `HELIX_ACL_HELPER_CMD` — a direct invocation of
  the Go `external_acl` binary that reads `"<Host>\n"` on stdin and prints
  `"OK tag=…"` / `"ERR"`.

## Usage examples

```bash
# Today (no live stack): honest SKIP, exit 0:
bash tests/dynamic/suites/concurrency_race_suite.sh

# P10 live run with the direct-helper hammer:
HELIX_DYNAMIC_STACK=1 HELIX_PROXY_URL=http://127.0.0.1:34128 \
  RACE_CONC=20 HELIX_ACL_HELPER_CMD='./bin/external_acl' \
  bash tests/dynamic/suites/concurrency_race_suite.sh
```

Env: `RACE_CONC` (default 20), `RACE_TARGET` (default
`http://target-a.internal/`), `RACE_HOST` (default `target-a.internal`).

## Edge cases

- **Live stack absent** → `topology_unsupported` SKIP, exit `0`.
- **A hang/deadlock** leaves an empty code file → counted as `hung`; any `hung >
  0` fails the GREEN guard.
- **Same Host yields more than one decision** (`distinct_tags > 1`) under the
  direct-helper hammer → a race → FAIL.

## §11.4.115 RED_MODE polarity

| `RED_MODE` | What it asserts | PASS means |
|---|---|---|
| `0` (default) | GREEN guard | all 200, 0 hung, ≤1 decision per Host (consistent + live) |
| `1` | RED baseline | the pre-fix helper **races/hangs/returns inconsistent tags** → defect reproduced |

A `RED_MODE=1` run with no race/hang reproduced is a finding, not a pass.

## Internal behaviour

- `#!/usr/bin/env bash`, POSIX-clean (`sh -n` + `bash -n`, §11.4.67).
- Fires `RACE_CONC` parallel proxied requests → `req.N.code`; tallies 200s and
  `hung` (empty/zero-byte code files).
- When `HELIX_ACL_HELPER_CMD` is set, also hammers the helper directly in
  parallel and reduces `helper.*.out` to `sort -u` distinct `OK tag`/`ERR`
  decisions; `distinct_tags > 1` for one Host = a race.
- Counts + decisions written to `concurrency.evidence`; evidence dir
  `qa-results/p9-harness/concurrency_race_<run-id>/`.

## Related

- `tests/dynamic/lib/analyzer_common.sh` — sourced base.
- `tests/dynamic/suites/run_all_suites.sh` — orchestrates this suite.
- Constitution §11.4.169 / §11.4.85 / §11.4.50 / §11.4.69 / §11.4.115 / §12.6;
  design §4/§13.

## Last verified

2026-07-01 — run with no live stack: honest SKIP, exit `0`; `sh -n` + `bash -n`
parse-clean. Live concurrent acl-helper drive is exercised in **P10**.
