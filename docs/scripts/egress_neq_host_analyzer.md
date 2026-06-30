# `tests/dynamic/analyzers/egress_neq_host_analyzer.sh` — operator guide

**Revision:** 1
**Last modified:** 2026-07-01T00:00:00Z
**Status:** Active self-validated analyzer (§11.4.107(10)). Signal 3 of 6 for the
dynamic data plane — real VPN egress (the hardest-to-fake routing proof).

> Companion (§11.4.18) to the in-source documentation block at the top of the
> script.

## Overview

Signal 3: **egress IP via the proxy ≠ the host's real public IP** (§11.4.69
`network_connectivity`; design §13 `vpn_real_egress`; research §15). The egress
IP observed **through the proxy** must equal the EXPECTED tunnel exit AND differ
from the host's real public IP. A `200 OK` is **not** proof of routing; `egress
== host` is the §15 bluff (a PASS with no VPN actually engaged). It delegates to
the committed, self-tested `evidence.sh:assert_egress_ip` via its
`EVIDENCE_OBSERVED_IP_FILE` seam, feeding a captured egress IP.

## Prerequisites

- Source library `tests/dynamic/lib/analyzer_common.sh` + the committed
  `tests/lib/evidence.sh`.
- `awk`, POSIX `sh`.
- A manifest (`key=val`):
  - `observed_ip_file=egress_vpn.ip` (resolved relative to the manifest dir)
  - `expected_exit=185.65.135.70`
  - `host_real=203.0.113.45`

## Usage examples

```sh
# Analyze a captured egress manifest:
tests/dynamic/analyzers/egress_neq_host_analyzer.sh analyze <manifest-file>

# Self-validate (golden-good PASS + golden-bad FAIL) — the default action:
tests/dynamic/analyzers/egress_neq_host_analyzer.sh --selftest
```

## Edge cases

- **Manifest / observed-egress capture missing** → `FAIL`.
- **`evidence.sh` not found** → `FAIL` (`cannot delegate`), never a bluff.
- **`egress == host_real`** (no VPN diversion — the §15 bluff) → `FAIL`.
- **Egress is a wrong/unexpected exit** → `FAIL`.
- **Empty egress capture** (nothing observed) → `FAIL`.

## §11.4.115 RED_MODE polarity

In P10 this analyzer is paired with `wg_transfer_delta`: the egress-IP echo can be
cached, so the WireGuard byte-delta is the orthogonal data-plane corroboration.
Consuming suites run the §11.4.115 polarity citing this analyzer as the egress
oracle.

## Internal behaviour

- `#!/usr/bin/env bash`, POSIX-clean (`sh -n` + `bash -n`, §11.4.67).
- `_egress_manifest_get` parses `key=val` with `awk`; the observed-IP file is
  resolved relative to the manifest dir when not absolute.
- Drives `assert_egress_ip "$proxy" "$expected_exit" "$host_real"` through the
  `EVIDENCE_OBSERVED_IP_FILE` seam (no network); forwards its rc.
- Self-test asserts: golden-good PASS; egress==host, wrong-exit, empty-capture →
  FAIL; missing-manifest negative → FAIL.

## Related

- `tests/lib/evidence.sh` (`assert_egress_ip`) — the delegated oracle.
- `tests/dynamic/lib/analyzer_common.sh` — sourced base.
- Fixtures: `tests/dynamic/analyzers/fixtures/egress_neq_host/`.
- Constitution §11.4.69 / §11.4.107 / §11.4.115; design §13; research §15.

## Last verified

2026-07-01 — self-test PASS (golden-good PASS + egress==host/wrong-exit/empty
FAIL); `sh -n` + `bash -n` parse-clean. Live egress capture + WireGuard
byte-delta corroboration are exercised in **P10**.
