# `tests/lib/evidence.sh` — operator guide

**Revision:** 1
**Last modified:** 2026-07-01T00:00:00Z
**Status:** Active sourceable data-plane anti-bluff evidence library for the
VPN-aware proxy extension. The committed canonical oracle (§11.4.69 / §11.4.107).

> Companion (§11.4.18) to the in-source documentation block at the top of the
> script. This is a **sourced library**, not a runnable script — source it and
> call its functions.

## Overview / Purpose

A sourceable library of DATA-PLANE evidence helpers. Every helper returns `0`
(PASS) only when it can cite CAPTURED data-plane evidence that the user-visible
behaviour really works. Control-plane / config / "absence-of-error" signals are
NEVER accepted as proof (§11.4 / §11.4.69 / §11.4.107). It is the committed
canonical oracle that the dynamic-mode analyzers under `tests/dynamic/` source
read-only and delegate to (reuse, never reimplement — §11.4.74).

### Public function contract

| Function | PASS (rc 0) when… |
|---|---|
| `ab_pass_with_evidence <desc> <evidence_path>` | the cited evidence artefact EXISTS and is NON-EMPTY (else `FAIL`, rc 1). The canonical §11.4.69 PASS helper. |
| `ab_skip_with_reason <desc> <reason>` | `<reason>` is in the §11.4.69 closed set (`geo_restricted`, `operator_attended`, `hardware_not_present`, `topology_unsupported`, `network_unreachable_external`, `feature_disabled_by_config`) → honest `SKIP` (rc 0); any other reason → `FAIL` (rc 2). |
| `wg_transfer_delta <iface> <before> <after>` | the WireGuard tx delta > 0 AND rx delta > 0 across two `wg show <if> transfer` snapshots; flat/decreasing counters `FAIL`. |
| `assert_egress_ip <proxy_url> <expected_exit> <host_real>` | egress observed THROUGH the proxy == `<expected_exit>` AND != `<host_real>`; egress==host is the §15 bluff → `FAIL`; host IP unknown/empty/non-IP-shaped → `OPERATOR-BLOCKED` (rc 2), never fail-open (§11.4.68). |
| `assert_cache_hit <access_log> <url>` | the Squid access.log carries a `TCP_*HIT` result code for `<url>` (whole-field, not substring). |
| `assert_graceful_503 <proxy_url> <target> <pid_before> <pid_after>` | HTTP 503 + non-blank branded body (marker, default `tunnel`) + PID unchanged (proxy did not crash/restart). |
| `assert_no_leak <capture_file>` | zero target packets escaped the real uplink during the tunnel-down window (tcpdump `0 packets`, or `/proc/net/dev` tx-packet delta == 0, or zero IP lines). |

Supporting public helpers: `procdev_field <file> <iface> <idx>` (pure
`/proc/net/dev` field accessor), `proxy_conn_verdict <proxy> <direct>
<expected> <listening>` (PURE connectivity classifier → `PASS`/`FAIL`/`SKIP:…`),
`port_is_listening <port>` (live listen probe). Helpers prefixed `_evidence_` /
`_code_in` / `_evidence_ip_shaped` are internal.

## Usage

```sh
. tests/lib/evidence.sh                    # source it; do NOT execute

assert_egress_ip "$PROXY_URL" "$EXPECTED_EXIT" "$HOST_REAL_IP"
ab_pass_with_evidence "cache hit" "$access_log"
ab_skip_with_reason  "stress" "topology_unsupported"
```

### Unit-test seams (§11.4.27 — stubs only in the unit layer)

| Env var | Effect |
|---|---|
| `EVIDENCE_OBSERVED_IP_FILE` | `assert_egress_ip` reads the observed egress IP from this file instead of live curl. |
| `EVIDENCE_503_CODE_OVERRIDE` | `assert_graceful_503` uses this HTTP code instead of live curl. |
| `EVIDENCE_503_BODY_FILE` | `assert_graceful_503` reads the response body from this file. |
| `EVIDENCE_503_BODY_MARKER` | branded marker the 503 body must contain (default `tunnel`, case-insensitive). |
| `EVIDENCE_LEAK_IFACE` | real-uplink iface for the `/proc/net/dev` no-leak delta (default `eth0`). |
| `EVIDENCE_IP_ECHO_URL` | IP-echo endpoint for the live egress probe (default `https://icanhazip.com`). |
| `EVIDENCE_CURL_TIMEOUT` | curl `--max-time` for live probes (default `15`). |

## Inputs

Captured artefacts (wg transfer snapshots, Squid `access.log`, 503 body + PID
pair, tcpdump capture / `/proc/net/dev` snapshots) plus, for the live probes,
real curl through the proxy. Unit-test seams (above) feed fixtures with no
network.

## Outputs

One structured verdict line per call on stdout:

```
PASS: <desc> [evidence: <path-or-detail>]
FAIL: <desc> [reason: <why>]
SKIP: <desc> [reason: <closed-set-reason>]
OPERATOR-BLOCKED: <desc> [reason: …]
```

Return code: `0` = PASS / valid-SKIP, `1` = FAIL, `2` = invalid SKIP /
OPERATOR-BLOCKED.

## Side-effects

- The live probes (`assert_egress_ip`, `assert_graceful_503`) run `curl`
  through the proxy in real use; `assert_graceful_503` may create + remove a
  `mktemp` body file. `port_is_listening` inspects the local network stack.
- The pure classifiers/parsers (`ab_*`, `wg_transfer_delta`,
  `assert_cache_hit`, `assert_no_leak`, `procdev_field`, `proxy_conn_verdict`)
  have no side-effects.

## Dependencies

POSIX `sh`, `awk`, `grep`, `tr`; `curl` (live probes only); `ss`/`netstat`
(`port_is_listening` only). POSIX-clean — parses under `sh -n` AND `bash -n`
(§11.4.67); no bash-only constructs (`[[ ]]`, `<<<`, arrays, `>( )`,
`${v^^}`).

## Edge cases

- **`assert_egress_ip` fail-open guard (§11.4.68, findings F7/F-1)** — when
  `host_real` is empty, `unknown`, non-IP-shaped garbage, or a loopback/
  unspecified sentinel, the `egress!=host` half cannot be evaluated: a
  definitively-wrong exit still FAILs, but an otherwise-good result returns
  `OPERATOR-BLOCKED` (rc 2), NEVER a fail-open PASS/SKIP.
- **`wg_transfer_delta`** — a recent handshake with flat counters is
  control-plane-green / data-plane-dead → FAIL.
- **`assert_cache_hit`** — URL-specific: a MISS line for the same URL does NOT
  satisfy it; the HIT token must be the result-code field, not text inside the
  URL.
- **`proxy_conn_verdict`** — a positive DIRECT signal out-ranks the port probe,
  so a crashed proxy on a working host FAILs rather than fail-opening to SKIP
  (§11.4.68); a site outage SKIPs rather than false-FAILing (§11.4.1).
- **`_code_in`** matches whole tokens only (`20` does not match `200`).

## Related scripts

- `tests/lib/evidence_selftest.sh` — TAP self-test proving every parser is
  correct AND fails on its negative fixture (§1.1).
- `tests/dynamic/lib/analyzer_common.sh` — sources this library read-only; the
  six analyzers under `tests/dynamic/analyzers/*.sh` delegate to these helpers.
- `tests/regression/assert_egress_ip_host_unknown_test.sh` — the F7 fail-open
  regression guard.
- Design §13/§14 (`docs/superpowers/specs/2026-06-30-vpn-aware-proxy-extension-design.md`);
  research report C; Constitution §11.4.68 / §11.4.69 / §11.4.107.

## Last verified

2026-07-01 — documented against the library source; `sh -n` / `bash -n`
parse-clean. Every parser is exercised (no network, via fixtures + seams) by
`evidence_selftest.sh`; the live curl probes run against the real dynamic stack
in P10.
