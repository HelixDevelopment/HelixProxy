# `tests/dynamic/analyzers/dns_no_plaintext_53_analyzer.sh` — operator guide

**Revision:** 1
**Last modified:** 2026-07-01T00:00:00Z
**Status:** Active self-validated analyzer (§11.4.107(10)). Signal 5 of 6 for the
dynamic data plane — DNS privacy / no plaintext :53 leak. **Fresh oracle** — no
`evidence.sh` helper exists for this signal, so the parse is local (awk).

> Companion (§11.4.18) to the in-source documentation block at the top of the
> script.

## Overview

Signal 5: **no plaintext :53 DNS leak** (§11.4.69 `network_connectivity`; design
§11 ② DoH/DoT + leak prevention; §13). Given a `tcpdump` capture taken **on the
real uplink**, it PASSes iff **zero** plaintext UDP/TCP :53 DNS packets reach a
NON-allowed resolver. Legitimate DNS under dynamic mode is DoH/DoT (443/853,
encrypted); a plaintext :53 packet on the real uplink to an external resolver is
a DNS leak. An optional allow-list (the in-tunnel resolver IP[s]) excludes the
sanctioned in-namespace resolver.

## Prerequisites

- Source library `tests/dynamic/lib/analyzer_common.sh`. (This analyzer parses
  locally with `awk`; it uses `ab_pass_with_evidence` from `evidence.sh` when
  available, else falls back to `ac_pass`.)
- `awk`, `grep`, POSIX `sh`.
- A real-uplink `tcpdump` capture (live P10 input); the self-test feeds bundled
  fixtures with no network.

## Usage examples

```sh
# Analyze a capture; allow-list (CSV) of sanctioned in-tunnel resolvers optional:
tests/dynamic/analyzers/dns_no_plaintext_53_analyzer.sh analyze <capture> [allow-csv]

# Self-validate (golden-good PASS + golden-bad FAIL) — the default action:
tests/dynamic/analyzers/dns_no_plaintext_53_analyzer.sh --selftest
```

The allow-list may also be supplied via `HELIX_DNS_ALLOW_RESOLVERS` (CSV).

## Edge cases

- **Capture file missing** → `FAIL`.
- **Default allow-list is EMPTY (fail-closed)** — any plaintext :53 is a leak
  unless an explicit sanctioned resolver is allow-listed (§11.4.6 no-guessing: a
  leak is never assumed benign). A :53 packet to an in-tunnel resolver that is
  **not** allow-listed still FAILs.
- **:53 only to an allow-listed in-tunnel resolver** → PASS.
- **DoH-only capture (zero :53 on the uplink)** → PASS.

## §11.4.115 RED_MODE polarity

Consuming suites run the §11.4.115 polarity citing this analyzer; RED reproduces
a plaintext :53 leak, GREEN guards zero-leak (DoH/DoT or allow-listed resolver
only).

## Internal behaviour

- `#!/usr/bin/env bash`, POSIX-clean (`sh -n` + `bash -n`, §11.4.67); the parse
  is done by `awk`.
- `_dns_leaked_resolvers` walks each capture line, converts `ip.port:` tokens,
  keeps only `port == 53`, and prints each non-allowed resolver IP (destination
  for queries, source for responses).
- A non-empty leak list → `FAIL` with the first offender + count; otherwise
  `ab_pass_with_evidence` (or `ac_pass` when `evidence.sh` is absent).
- Self-test asserts: DoH-only PASS, allow-listed resolver PASS; plaintext to
  1.1.1.1 FAIL, in-tunnel-but-not-allow-listed FAIL; missing-capture negative →
  FAIL.

## Related

- `tests/dynamic/lib/analyzer_common.sh` — sourced base.
- Fixtures: `tests/dynamic/analyzers/fixtures/dns_no_plaintext_53/`.
- Constitution §11.4.69 / §11.4.107 / §11.4.115 / §11.4.6; design §11 ② / §13.

## Last verified

2026-07-01 — self-test PASS (DoH-only + allow-listed PASS; plaintext-to-1.1.1.1 +
not-allow-listed FAIL); `sh -n` + `bash -n` parse-clean. Live real-uplink capture
is exercised in **P10**.
