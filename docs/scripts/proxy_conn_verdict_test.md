# `tests/regression/proxy_conn_verdict_test.sh`

**Revision:** 1
**Last modified:** 2026-07-01T07:20:00Z

## Overview

Standing §11.4.135 regression guard for `proxy_conn_verdict()` — the client-side
through-proxy connectivity classifier added to `tests/lib/evidence.sh` in
**BUGFIX-0014**. It proves the classifier never commits either of the two anti-bluff
sins the connectivity checks used to be capable of:

- a **§11.4.1 false-FAIL** — scoring a healthy proxy as FAIL because the *site* the
  probe targeted was unreachable (a third-party / local-internet outage the proxy
  cannot be blamed for); and
- a **§11.4.68 fail-open** — masking a *real* proxy defect as a benign SKIP.

## Why this guard exists

Before BUGFIX-0014, `tests/verify-proxy.sh` and `tests/final-verify.sh` classified
each through-proxy check as `code == expected -> PASS else FAIL`. That single-axis
logic could not tell "the proxy is broken" apart from "the site is momentarily down",
so a blip on `connectivitycheck.gstatic.com` / `www.google.com` — or a host with no
egress — hard-FAILed a perfectly healthy proxy. Non-deterministic (§11.4.50), not
re-runnable (§11.4.98).

The fix classifies with a second axis (does the site respond **directly**?) plus a
port-liveness gate:

| proxy in expected | direct in expected | port listening | verdict |
|---|---|---|---|
| yes | — | — | `PASS` |
| no  | yes | — | `FAIL` (site reachable directly, proxy can't serve it — a real defect whether the port is up-but-broken OR the proxy crashed; a positive direct signal out-ranks the port probe, §11.4.68 not fail-open) |
| no  | no  | yes | `SKIP:network_unreachable_external` (site outage — no false-FAIL) |
| no  | no  | no  | `SKIP:topology_unsupported` (proxy absent AND no network signal to substantiate a FAIL) |

## Prerequisites

- POSIX `sh`; `tests/lib/evidence.sh` present (the guard **sources** it — it drives
  the real function, never a re-implementation).
- No network: every case is a pure-function truth-table assertion.

## Usage

```sh
# GREEN standing guard (default): PASS iff the classifier's full truth table is correct.
tests/regression/proxy_conn_verdict_test.sh

# RED reproduction: PASS iff the PRE-FIX replica (code != expected => FAIL) FAILs an
# outage tuple — the false-FAIL demonstrated on the pre-fix logic (§11.4.115).
RED_MODE=1 tests/regression/proxy_conn_verdict_test.sh
```

Exit `0` = PASS, `1` = FAIL. Evidence is written under
`qa-results/regression/proxy_conn_verdict/`.

## §11.4.115 polarity switch (`RED_MODE`)

- `RED_MODE=0` (default) — GREEN guard: sources `evidence.sh` and asserts
  `proxy_conn_verdict` returns `PASS` / `FAIL` / `SKIP:network_unreachable_external` /
  `SKIP:topology_unsupported` across the canonical truth table (single- and
  multi-code `expected`).
- `RED_MODE=1` — reproduces the defect: runs the pre-fix `code != expected => FAIL`
  replica against the outage tuple `(proxy=000, expected=204)` and asserts it FAILs.
  A RED that cannot reproduce is a §11.4.7 finding.

## §1.1 paired mutation

Mutating `proxy_conn_verdict`'s outage branch in `evidence.sh`
(`SKIP:network_unreachable_external` → `FAIL`, reintroducing the false-FAIL) makes the
GREEN guard FAIL with a **real value-assertion mismatch**
(`proxy_conn_verdict 000 000 204 yes -> FAIL (want SKIP:network_unreachable_external)`),
not a parse error or panic. Restoring the file byte-identically (md5-verified) returns
the guard to PASS. This proves the guard tracks behaviour, not syntax.

## Edge cases

- **Site outage vs proxy defect** — the decisive discriminator is whether the site
  answers *directly*. If neither the proxy nor a direct fetch reaches it, the site is
  the problem → SKIP, not FAIL.
- **Crashed / absent proxy port** — a not-listening port does NOT auto-SKIP. If the
  site is reachable **directly** (proof the network works), a dead proxy is a real
  defect → `FAIL` (§11.4.68 not fail-open). Only when the site is *also* unreachable
  and nothing proves the proxy should be serving does it become
  `SKIP:topology_unsupported` (an unprovable-FAIL, honestly skipped).
- **Multi-code expectations** — `expected` is a space-separated allow-list
  (e.g. `'200 301 302'`); `_code_in` matches membership.

## Related scripts

- Fix under guard: `tests/lib/evidence.sh` (`proxy_conn_verdict` / `_code_in` /
  `port_is_listening`).
- Consumers: `tests/verify-proxy.sh`, `tests/final-verify.sh` (`conn_check`).
- Unit truth table: `tests/lib/evidence_selftest.sh`.
- Sibling sink-side guard: `tests/regression/external_egress_verdict_test.sh`
  (BUGFIX-0012).
- Ledger: `docs/issues/fixed/BUGFIXES.md` — BUGFIX-0014.

## Last verified

2026-07-01 — GREEN PASS, RED PASS (reproduces), §1.1 mutation FAILs + restores
byte-identical, unit selftest 37/37 (incl. crashed-proxy FAIL + `_code_in`
exact-match cases from the independent-review reconciliation), `verify-proxy.sh` +
`final-verify.sh` each 4 PASS + 1 SKIP (exit 0) live.
