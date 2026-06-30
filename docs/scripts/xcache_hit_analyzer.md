# `tests/dynamic/analyzers/xcache_hit_analyzer.sh` — operator guide

**Revision:** 1
**Last modified:** 2026-07-01T00:00:00Z
**Status:** Active self-validated analyzer (§11.4.107(10)). Signal 4 of 6 for the
dynamic data plane — caching preserved under dynamic mode.

> Companion (§11.4.18) to the in-source documentation block at the top of the
> script.

## Overview

Signal 4: **a real Squid cache HIT** (§11.4.69 `storage_read`; design §13
`cache_hit`; research §2). A second request for a cacheable URL must produce a
HIT. The **decisive** data-plane fact is the Squid `access.log` carrying a
URL-specific `TCP_*HIT` result code (a response header alone is forgeable). It
delegates that to the committed, self-tested `evidence.sh:assert_cache_hit`, and
— when a captured response-header dump is supplied — additionally requires it to
corroborate with `X-Cache: HIT` (defense in depth: a header that says MISS while
the log says HIT is contradictory evidence → FAIL).

## Prerequisites

- Source library `tests/dynamic/lib/analyzer_common.sh` + the committed
  `tests/lib/evidence.sh`.
- `awk`, `grep`, POSIX `sh`.
- A manifest (`key=val`):
  - `access_log=access_hit.log` (resolved relative to the manifest dir)
  - `url=http://cdn.example.com/static/app.css`
  - `headers_file=headers_hit.txt` (optional corroboration)

## Usage examples

```sh
# Analyze a captured cache manifest:
tests/dynamic/analyzers/xcache_hit_analyzer.sh analyze <manifest-file>

# Self-validate (golden-good PASS + golden-bad FAIL) — the default action:
tests/dynamic/analyzers/xcache_hit_analyzer.sh --selftest
```

## Edge cases

- **Manifest missing** / **`evidence.sh` not found** → `FAIL`, never a bluff.
- **No `TCP_*HIT` for the URL in the access.log** → `FAIL` (re-runs the canonical
  oracle to surface its FAIL line).
- **Declared `headers_file` missing** → `FAIL`.
- **access.log shows TCP_HIT but the `X-Cache` header is not HIT** →
  `FAIL` (contradictory evidence).
- **Timing-is-faster is NOT a cache fact** — a result code in the access.log is
  the data-plane corroboration; a faster second request alone proves nothing.

## §11.4.115 RED_MODE polarity

Consuming suites run the §11.4.115 polarity citing this analyzer; RED reproduces
an always-MISS regression, GREEN guards the TCP_HIT + `X-Cache: HIT` contract.

## Internal behaviour

- `#!/usr/bin/env bash`, POSIX-clean (`sh -n` + `bash -n`, §11.4.67).
- `_xc_manifest_get` parses `key=val` with `awk`; the log + optional header file
  are resolved relative to the manifest dir when not absolute.
- Decisive check first (`assert_cache_hit`), then optional `X-Cache` header
  corroboration via `grep -Eiq '^[[:space:]]*X-Cache:.*HIT'`, then
  `ab_pass_with_evidence` citing the access.log.
- Self-test asserts: golden-good PASS; always-MISS, header-contradiction,
  url-MISS-only → FAIL; missing-manifest negative → FAIL.

## Related

- `tests/lib/evidence.sh` (`assert_cache_hit`) — the delegated oracle.
- `tests/dynamic/lib/analyzer_common.sh` — sourced base.
- Fixtures: `tests/dynamic/analyzers/fixtures/xcache_hit/`.
- Constitution §11.4.69 / §11.4.107 / §11.4.115; design §13; research §2.

## Last verified

2026-07-01 — self-test PASS (golden-good PASS + all-miss/header-contradiction/
url-miss-only FAIL); `sh -n` + `bash -n` parse-clean. Live cache HIT is exercised
in **P10**.
