# `tests/comprehensive-test.sh` — operator guide

**Revision:** 1
**Last modified:** 2026-07-01T00:00:00Z
**Authority:** Helix Constitution §11.4.69 (sink-side positive evidence), §11.4.68 (no fail-open), §11.4.3 (topology-aware SKIP), §11.4.1 (no false-FAIL), §11.4.6 (no guessing), §11.4.124 (restored cache CLI)

> Companion (§11.4.18) to the in-source comment blocks in the script.

## Overview / Purpose

The **live data-plane functional suite** — end-to-end tests that exercise the
running proxy stack: environment, scripts, container runtime, container status,
port bindings, HTTP proxy, SOCKS5 proxy, VPN routing, caching, admin interface,
`./status`/`./cachectl` command output, DNS-over-HTTPS through the proxy, large-
file faithful relay, concurrent connections, and network-client simulation. It
is the anti-bluff (de-bluffed) counterpart to `tests/run-tests.sh`: connectivity
checks classify a proxy miss as `PASS` / `FAIL` / `SKIP` via
`proxy_conn_verdict`, and evidence (cache HIT, egress IP, byte counts) is
captured to files, never asserted on a forgeable header or wall-clock timing.

## Usage

```bash
bash tests/comprehensive-test.sh
# override the evidence directory:
EVIDENCE_DIR=/path/to/evidence bash tests/comprehensive-test.sh
```

No CLI flags. The suite auto-detects the container runtime (`podman` preferred,
then `docker`).

## Inputs

- **`.env`** (optional, gitignored) — sourced if present for `HTTP_PROXY_PORT`,
  `SOCKS_PROXY_PORT`, `PROXY_ADMIN_PORT`, `CACHE_DIR`, `VPN_EXIT_IP`. Absent =
  fresh-checkout topology → `.env.example` is validated and per-var checks SKIP.
- **`EVIDENCE_DIR`** (default `$PROJECT_ROOT/qa-results/comprehensive`) — where
  captured evidence files are written.
- **`VPN_EXIT_IP`** (optional) — the expected VPN tunnel exit IP. When unset the
  VPN-routing test SKIPs (`operator_attended`); it never fakes a VPN PASS from an
  `egress == host` equality (that would prove NO VPN diversion).
- Port defaults when `.env` is absent: HTTP `34128`, SOCKS `34080`, admin `34088`.
- Live external endpoints reached during the run (through the proxy and, for the
  anti-bluff cross-check, directly): `connectivitycheck.gstatic.com`,
  `www.google.com`, `httpbin.org`, `api.ipify.org`, `ifconfig.me`, `dns.google`,
  `www.gnu.org` (cacheable HTTP object).

## Outputs

- Coloured per-test `PASS`/`FAIL`/`SKIP` lines + a summary (Run/Passed/Failed/
  Skipped) and a list of failed tests.
- Exit `0` — no `FAIL`; exit `1` — one or more `FAIL`.
- Captured evidence under `EVIDENCE_DIR`: `squid_access_snapshot.log`,
  `cache_hit.evidence`, `cache_stats.out`, `cache_cmd_{stats,size,list}.out`,
  `status.out`, `status_verbose.out`, `status_json.out`, `large_file.evidence`,
  `concurrent.evidence`.

## Side-effects

- Creates `EVIDENCE_DIR` and writes the evidence files above.
- Issues real network requests through the proxy and (for cross-checks) directly.
- Reads the Squid access log via `<runtime> exec proxy-squid cat …` (read-only).
- Runs `./status`, `./status -v`, `./status --json`, and `./cachectl <cmd>`
  (read-only reporting commands). It does **not** start/stop/reconfigure any
  container.

## Dependencies

- `bash` (`set -euo pipefail`), `curl`, `grep`, `awk`, `ss`, `mktemp`, `seq`,
  `hostname`/`ip` (host-IP probe).
- `podman` or `docker` (runtime detection + `<runtime> exec proxy-squid`).
- `tests/lib/evidence.sh` (sourced) — provides `assert_egress_ip`,
  `assert_cache_hit`, `proxy_conn_verdict`, `_code_in`, `port_is_listening`,
  `ab_pass_with_evidence`, `ab_skip_with_reason`.
- The restored `./cachectl` CLI for the cache-command tests (SKIP-with-reason if
  absent, per §11.4.124 — never a hard FAIL).

## Internal behaviour notes

- `test_result` uses assignment-form counters (§11.4.1 — `((VAR++))` from 0
  aborts under `set -e`).
- `_port_topology_check` refuses to fail-open on a foreign responder holding a
  port (§11.4.68): owner-publishes+listening → PASS, owner-not-publishing +
  something-listening → SKIP.
- `_external_egress_verdict` / `conn_check`: proxy 200 → PASS; proxy miss but
  site reachable directly → FAIL (real defect); proxy miss AND direct miss →
  SKIP (external outage, not a proxy defect).
- Cache HIT proof is a Squid `TCP_*HIT` in the real access.log for the specific
  URL, not a timing comparison.

## Related scripts

- `tests/run-tests.sh` — structural + regression + security suite.
- `tests/verify-proxy.sh`, `tests/final-verify.sh` — lighter live connectivity
  checks sharing the same `conn_check`/`evidence.sh` discipline.
- `docs/scripts/proxy_cache_challenge.md`, `docs/scripts/cachectl.md`.

## Last verified

2026-07-01 — documented from source (`set -euo pipefail`, `evidence.sh` sourced
at line 15). Behaviour read from the script body; not executed here (the
conductor runs the live suite against the running stack).
