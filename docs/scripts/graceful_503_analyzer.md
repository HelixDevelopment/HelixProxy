# `tests/dynamic/analyzers/graceful_503_analyzer.sh` — operator guide

**Revision:** 1
**Last modified:** 2026-07-01T00:00:00Z
**Status:** Active self-validated analyzer (§11.4.107(10)). Signal 2 of 6 for the
dynamic data plane — graceful degradation.

> Companion (§11.4.18) to the in-source documentation block at the top of the
> script.

## Overview

Signal 2: **branded 503 + Squid PID unchanged** (§11.4.69
`network_connectivity`; design §10/§13 `graceful_503`; §11.4.108
runtime-signature). When the target tunnel is DOWN, Squid must return an
intentional, **branded** 503 (`ERR_TUNNEL_DOWN` body) **and keep the same PID**
across the request (it did not crash/restart). It delegates the decision to the
committed, self-tested `evidence.sh:assert_graceful_503` through that helper's
documented unit-test seams (`EVIDENCE_503_CODE_OVERRIDE`,
`EVIDENCE_503_BODY_FILE`, `EVIDENCE_503_BODY_MARKER`), feeding a captured probe
manifest — so the analyzer needs no live network.

## Prerequisites

- Source library `tests/dynamic/lib/analyzer_common.sh` + the committed
  `tests/lib/evidence.sh`.
- `awk`, POSIX `sh`.
- A probe manifest (`key=val`, one per line):
  - `http_code=503`
  - `body_file=503_body.html` (resolved relative to the manifest dir)
  - `pid_before=12345`
  - `pid_after=12345`
  - `marker=tunnel` (optional branded-text marker)

## Usage examples

```sh
# Analyze a captured probe manifest:
tests/dynamic/analyzers/graceful_503_analyzer.sh analyze <manifest-file>

# Self-validate (golden-good PASS + golden-bad FAIL) — the default action:
tests/dynamic/analyzers/graceful_503_analyzer.sh --selftest
```

## Edge cases

- **Manifest missing** / **`evidence.sh` not found** → `FAIL`, never a bluff.
- **PID changed across the request** (proxy crashed/restarted) → `FAIL`: a 503
  from a crashed proxy is not graceful — the PID-unchanged check is the
  §11.4.108 runtime-signature that distinguishes them.
- **HTTP 200 instead of 503** (target leaked through) → `FAIL`.
- **Blank / unbranded 503 body** → `FAIL` (the branded marker is required).

## §11.4.115 RED_MODE polarity

Consuming suites (`chaos_suite.sh` C1) run the §11.4.115 polarity: RED reproduces
a crash/fail-open on the pre-fix stack; GREEN guards the branded-503 +
PID-unchanged contract. This analyzer is the oracle each polarity cites.

## Internal behaviour

- `#!/usr/bin/env bash`, POSIX-clean (`sh -n` + `bash -n`, §11.4.67).
- `_g503_manifest_get` parses `key=val` lines with `awk`; the body file is
  resolved relative to the manifest dir when not absolute.
- Drives `assert_graceful_503` through its env seams (no network) and forwards
  its rc (0 PASS / 1 FAIL).
- Self-test asserts: golden-good PASS; PID-changed, HTTP-200, blank-body → FAIL;
  missing-manifest negative → FAIL.

## Related

- `tests/lib/evidence.sh` (`assert_graceful_503`) — the delegated oracle.
- `tests/dynamic/lib/analyzer_common.sh` — sourced base.
- `tests/dynamic/suites/chaos_suite.sh` — builds a manifest from the live
  capture and runs this analyzer.
- Fixtures: `tests/dynamic/analyzers/fixtures/graceful_503/`.
- Constitution §11.4.69 / §11.4.107 / §11.4.108 / §11.4.115; design §10/§13;
  research §4.

## Last verified

2026-07-01 — self-test PASS (golden-good PASS + PID-changed/200/blank-body FAIL);
`sh -n` + `bash -n` parse-clean. Live probe is exercised in **P10**.
