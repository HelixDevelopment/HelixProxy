# `tests/regression/external_egress_verdict_test.sh` — operator guide

**Revision:** 1
**Last modified:** 2026-07-01T07:15:00Z
**Status:** Active standing regression guard (§11.4.135) for BUGFIX-0012.

> Companion (§11.4.18) to the in-source documentation block at the top of the
> script. Sibling of `docs/scripts/comprehensive_admin_topology_test.md`.

## Overview

A standing regression guard that proves `tests/comprehensive-test.sh` never
reports a proxy **FAIL** for a **third-party outage**, and never masks a **real
proxy defect** as an outage **SKIP**.

Pre-fix, the "various sites" loop in `test_http_proxy()` and the concurrency test
in `test_concurrent()` decided purely on `proxy_http_code == 200 ? PASS : FAIL`.
When an external endpoint (`httpbin.org`) was **down**, the direct host fetch
failed too — yet the suite hard-**FAILed** on an outage the proxy did not cause: a
§11.4.1 false-FAIL that made the suite non-deterministic (§11.4.50) and not
re-runnable (§11.4.98). The working sibling `api.ipify.org` PASSed at the same
moment, proving the proxy's egress was fine.

The fix routes both call sites through a shared pure classifier
`_external_egress_verdict(proxy_code, direct_code)`:

| `proxy_code` | `direct_code` | verdict | meaning |
|---|---|---|---|
| `200` | (any) | `PASS` | the proxy fetched it |
| ≠ `200` | `200` | `FAIL` | the proxy cannot fetch a site the host reaches **directly** — a real proxy defect (the anti-bluff catch) |
| ≠ `200` | ≠ `200` | `SKIP` | the endpoint is down for everyone — external outage, not ours (§11.4.3, `network_unreachable_external`) |

Same discipline the sibling `test_large_file()` already uses for its
faithful-relay / `network_unreachable_external` gate.

It does **not** grep the source. It extracts the **real** `_external_egress_verdict`
function and drives it with the three canonical code pairs — deterministic, no
network.

## Prerequisites

- POSIX `sh`, `awk`, `mktemp`. No network, no privileges.

## Usage examples

```bash
# GREEN guard (default) — assert PASS(200,·) + FAIL(≠200,200) + SKIP(≠200,≠200):
tests/regression/external_egress_verdict_test.sh            # exit 0 = PASS

# RED reproduce — the pre-fix (proxy!=200 => FAIL) replica FAILs an outage pair:
RED_MODE=1 tests/regression/external_egress_verdict_test.sh # exit 0 = defect reproduced

# Runs automatically inside the suite:
bash tests/run-tests.sh                                     # test_regression_guards()
```

## §11.4.115 RED_MODE polarity

| `RED_MODE` | What it runs | PASS means |
|---|---|---|
| `0` (default) | the REAL `_external_egress_verdict` from `comprehensive-test.sh` | `(200,000)→PASS` **and** `(503,200)→FAIL` **and** `(503,000)→SKIP` → the outage is SKIPped (bluff refused) and a real defect still FAILs (GREEN guard) |
| `1` | the PRE-FIX replica (`proxy!=200 ⇒ FAIL`) | `(503,000)→FAIL` → the false-FAIL on an external outage reproduces |

A `RED_MODE=1` run that cannot reproduce is a finding per §11.4.7, not a pass.

## Edge cases

- **Fix reverted** (`_external_egress_verdict` flipped back to `proxy!=200 ⇒ FAIL`)
  → the GREEN guard reports `REGRESSION: verdict wrong …` and exits 1 (the §1.1
  paired-mutation behaviour, verified against the real function).
- **Fail-open regression** (outage → PASS instead of SKIP, or real defect →
  SKIP) → the GREEN guard's `OK200=PASS*DEFECT=FAIL*OUTAGE=SKIP` pattern no longer
  matches → FAIL.

## Internal behaviour

- `#!/bin/sh`, `set -eu`; POSIX-only, `sh -n` parse-clean (§11.4.67).
- Extraction: `awk '/^_external_egress_verdict\(\) \{/{f=1} f{print} /^\}/{if(f){exit}}'`.
- Writes one evidence file per run under
  `qa-results/regression/external_egress_verdict/` (gitignored).

## Related

- Fix site: `tests/comprehensive-test.sh` — `_external_egress_verdict()`, the sites
  loop in `test_http_proxy()`, the direct pre-probe in `test_concurrent()`.
- Sibling gate: `test_large_file()` `network_unreachable_external` SKIP.
- `tests/run-tests.sh` — registers this guard via `test_regression_guards()`.
- `docs/issues/fixed/BUGFIXES.md` — BUGFIX-0012.

## Last verified

2026-07-01 — `sh -n` parse-clean; GREEN asserts PASS/FAIL/SKIP for the three
canonical pairs (exit 0); `RED_MODE=1` reproduces the false-FAIL (exit 0); paired
mutation (revert the helper) makes GREEN FAIL (exit 1) then restores byte-identical;
live `comprehensive-test.sh` = 33 pass / 0 fail / 10 skip with httpbin.org down.
