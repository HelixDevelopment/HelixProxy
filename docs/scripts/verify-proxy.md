# `tests/verify-proxy.sh` — operator guide

**Revision:** 1
**Last modified:** 2026-07-01T00:00:00Z
**Authority:** Helix Constitution §11.4.1 (no false-FAIL), §11.4.68 (no fail-open), §11.4.3 (topology SKIP), §11.4.69 (data-plane egress proof), discovery-sweep F2 / BUGFIX-0014

> Companion (§11.4.18) to the in-source comment blocks in the script.

## Overview / Purpose

A **live proxy-service verification smoke check**: four through-proxy
connectivity checks (HTTP proxy, HTTPS via HTTP proxy, SOCKS5 proxy, HTTPS via
SOCKS5) plus a VPN-routing proof, with a compact one-line summary. It shares the
identical `conn_check` classifier and VPN logic with `tests/final-verify.sh`
(the boxed "final verification" presentation of the same checks). Every
connectivity check is anti-bluff: a proxy miss is classified via
`proxy_conn_verdict` into `PASS`/`FAIL`/`SKIP`, never a blind fail on a
third-party/local-internet outage.

## Usage

```bash
bash tests/verify-proxy.sh
```

No CLI flags or arguments.

## Inputs

- **`.env`** (optional, gitignored) — sourced if present for `HTTP_PROXY_PORT`
  (default `34128`), `SOCKS_PROXY_PORT` (default `34080`), and `VPN_EXIT_IP`.
- **`VPN_EXIT_IP`** (optional) — the expected VPN tunnel exit IP. Unset → the
  VPN-routing check SKIPs (`operator_attended`); it never fakes a VPN PASS from
  an `egress == host` equality (that equality proves NO VPN diversion).
- Live endpoints reached (through the proxy, and directly for cross-checks):
  `connectivitycheck.gstatic.com/generate_204`, `www.google.com`, and
  `ifconfig.me` (host-IP probe when `VPN_EXIT_IP` is set).

## Outputs

- A header + one line per check + a `Summary: Passed/Failed/Skipped` line.
- Exit `0` — `FAIL == 0` (skips allowed); exit `1` — one or more `FAIL`.

## Side-effects

None to the tree/containers. It issues real `curl` requests through the proxy
and (for the anti-bluff cross-check) directly. It does not start/stop/reconfigure
anything.

## Dependencies

- `bash` (`set -euo pipefail`), `curl`.
- `tests/lib/evidence.sh` (sourced) — `_code_in`, `port_is_listening`,
  `proxy_conn_verdict`, `assert_egress_ip`, `ab_skip_with_reason`.

## Internal behaviour notes

- `test_pass`/`test_fail` use assignment-form counters (§11.4.1 — `((PASS++))`
  from 0 aborts under `set -e` before the VPN check).
- `conn_check`: proxy returns an expected code → PASS; proxy up but cannot fetch
  a directly-reachable site → FAIL (§11.4.68); proxy+direct both fail → SKIP
  (§11.4.1 outage, not a defect); port not listening → SKIP (topology absent).

## Related scripts

- `tests/final-verify.sh` — the near-identical boxed-presentation sibling.
- `tests/comprehensive-test.sh` — the full functional suite.
- `tests/regression/proxy_conn_verdict_test.sh` — the §11.4.135 guard for the
  classifier both scripts share.

## Last verified

2026-07-01 — documented from source. Behaviour read from the script body; not
executed here (the conductor runs the live check against the running stack).
