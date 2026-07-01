# `tests/lib/evidence_selftest.sh` — operator guide

**Revision:** 1
**Last modified:** 2026-07-01T00:00:00Z
**Status:** Active §1.1 paired-mutation TAP self-test for `tests/lib/evidence.sh`.
Hermetic — runs anywhere a shell exists (bats NOT required).

> Companion (§11.4.18) to the in-source documentation block at the top of the
> script.

## Overview / Purpose

Proves every `evidence.sh` parser is CORRECT against captured fixtures AND
provably FAILS on its negative fixture — the §1.1 paired-mutation discipline
applied to the evidence harness itself: a helper that cannot catch its own
negation is a bluff gate. Both polarities of every helper are asserted,
including the §11.4.68 fail-open guards on `assert_egress_ip` (host IP
unknown / empty / garbage / sentinel → `OPERATOR-BLOCKED` rc 2, never a
fake-PASS) and the `proxy_conn_verdict` crashed-proxy case (a positive DIRECT
signal out-ranks the port probe → FAIL, never a SKIP fail-open).

## Usage

```sh
bash tests/lib/evidence_selftest.sh
```

No arguments.

## Inputs

- None on the command line.
- Sources the library under test (`tests/lib/evidence.sh`) and consumes the
  captured fixtures under `tests/lib/fixtures/` (wg snapshots, Squid
  access/503 logs, tcpdump / `/proc/net/dev` captures, egress IP files). Drives
  the library via its `EVIDENCE_*` unit-test seams — no network.

## Outputs

- TAP on stdout — one `ok`/`not ok` line per case, a `1..N` plan, a
  `# tests=… passed=… failed=…` line, and a `# RESULT:` line.
- A copy of the TAP stream written to
  `qa-results/evidence-harness/<run-id>/selftest.tap` (run-id = UTC
  `YYYYMMDDTHHMMSSZ`); the artefact path is echoed to stderr.
- Exit code: `0` iff ALL assertions pass (zero `not ok`); `1` if any fail.

## Side-effects

- Creates `qa-results/evidence-harness/<run-id>/` and writes `selftest.tap`
  there (gitignored evidence dir).
- Exports and unsets `EVIDENCE_*` seam variables during the run.
- No network, no live proxy, no containers — every probe is fed a fixture via
  a seam.

## Dependencies

`bash` (body is POSIX-clean, parses under `sh -n`), `awk`, `grep`, `tr`,
`mkdir`, `tee`. `bats` is NOT required.

## Edge cases

- **`tee` subshell** → the failure count is re-derived from the artefact
  (`grep -q '^not ok '`) so the exit code is authoritative even though `$FAILS`
  is not visible outside the tee'd pipeline.
- Asserts the hidden §15 bluff: `egress==host` while the host reports `unknown`
  / `0.0.0.0` must be `OPERATOR-BLOCKED`, never a fake-PASS.
- `procdev_field` value-equality assertions pin exact tx/rx packet counters
  from the fixture snapshot.
- `proxy_conn_verdict` asserts both false-FAIL (§11.4.1) and fail-open
  (§11.4.68) are impossible, plus `_code_in` whole-token matching (`20` ≠
  `200`).

## Related scripts

- `tests/lib/evidence.sh` — the library under test.
- `tests/dynamic/lib/analyzer_common.sh` — the dynamic-mode base that sources
  `evidence.sh` read-only.
- `tests/regression/assert_egress_ip_host_unknown_test.sh` — the F7 fail-open
  regression guard exercised in isolation.
- Constitution §11.4 / §11.4.68 / §11.4.69 / §11.4.107 / §1.1; design §13/§14.

## Last verified

2026-07-01 — documented against the script source; body parses under `sh -n`.
Runs hermetically (fixtures + `EVIDENCE_*` seams, no network) and emits its TAP
artefact under `qa-results/evidence-harness/`.
