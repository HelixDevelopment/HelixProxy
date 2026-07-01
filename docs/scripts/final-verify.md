# `tests/final-verify.sh` — operator guide

**Revision:** 1
**Last modified:** 2026-07-01T00:00:00Z
**Authority:** Helix Constitution §11.4.1 (no false-FAIL), §11.4.68 (no fail-open), §11.4.3 (topology SKIP), §11.4.69 (data-plane egress proof), discovery-sweep F3 / BUGFIX-0014

> Companion (§11.4.18) to the in-source comment blocks in the script.

## Overview / Purpose

A **live final-verification smoke check** of the running proxy service: it
drives four through-proxy connectivity checks plus a VPN-routing proof and
prints a banner-boxed pass/fail/skip summary. It is functionally the same
connectivity check as `tests/verify-proxy.sh` (identical `conn_check` + VPN
logic) with a boxed "FINAL VERIFICATION" presentation. Each connectivity check
is anti-bluff: a proxy miss is classified via `proxy_conn_verdict` into
`PASS`/`FAIL`/`SKIP` rather than blindly failing on a third-party outage.

## Usage

```bash
bash tests/final-verify.sh
```

No CLI flags or arguments.

## Inputs

- **`.env`** (optional, gitignored) — sourced if present for `HTTP_PROXY_PORT`
  (default `53128`), `SOCKS_PROXY_PORT` (default `51080`), and `VPN_EXIT_IP`.
- **`VPN_EXIT_IP`** (optional) — the expected VPN tunnel exit IP. Unset → the
  VPN-routing check SKIPs (`operator_attended`, live RED/GREEN deferred to P10);
  it never fabricates a VPN PASS from an `egress == host` equality.
- Live endpoints reached (through the proxy, and directly for cross-checks):
  `connectivitycheck.gstatic.com/generate_204`, `www.google.com`, and
  `ifconfig.me` (host-IP probe when `VPN_EXIT_IP` is set).

## Outputs

- Boxed banner + one line per check (HTTP proxy, HTTPS via HTTP proxy, SOCKS5
  proxy, HTTPS via SOCKS5, VPN routing) + a `SUMMARY: Passed/Failed/Skipped` box.
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
  a directly-reachable site → FAIL (§11.4.68 no fail-open); proxy+direct both
  fail → SKIP (§11.4.1 no false-FAIL on an outage); port not listening → SKIP.

## Related scripts

- `tests/verify-proxy.sh` — the near-identical lighter-presentation sibling
  (same `conn_check` + VPN logic).
- `tests/comprehensive-test.sh` — the full functional suite this smoke check
  distils.
- `tests/regression/proxy_conn_verdict_test.sh` — the §11.4.135 guard for the
  `proxy_conn_verdict` classifier both scripts use.

## Last verified

2026-07-01 — documented from source. Behaviour read from the script body; not
executed here (the conductor runs the live check against the running stack).
