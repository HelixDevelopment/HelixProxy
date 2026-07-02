# `tests/stress/proxy_forward_stress.sh` — operator guide

**Revision:** 1
**Last modified:** 2026-07-01T00:00:00Z
**Status:** Authored + parse-clean. Runs live against the running Squid HTTP
forward proxy (`localhost:34128`); honest `SKIP` (§11.4.3) when the proxy or the
target endpoint is unreachable.

> Companion (§11.4.18) to the in-source documentation block at the top of the
> script.

## Overview

§11.4.85 / §11.4.169 **stress** suite for the LIVE HTTP forward proxy (Squid,
`localhost:34128`). It drives **N ≥ 100 sequential** HTTPS-CONNECT requests
through the proxy **plus a concurrent burst of ≥ 10 parallel** requests, captures
each request's `%{http_code}` and `%{time_total}` to its **own file** (so a
verdict never rests on a background job's exit status — the B3 bluff fix), and
records a `p50/p95/p99` latency distribution to a captured `latency.txt`. It
PASSes only when **every** proxied request succeeded (`204`/`200`) with no
deadlock (every request returned within `--max-time`) and no crash. A
representative plain-HTTP probe captures the Squid `Via:` header — hard
client-side proof the bytes transited `proxy-squid`. Every PASS cites captured
evidence (§11.4.69); a metadata-only PASS is refused.

## Prerequisites

- Committed library `tests/lib/evidence.sh` (sourced — provides `_code_in`,
  `port_is_listening`, `proxy_conn_verdict`, `ab_pass_with_evidence`,
  `ab_skip_with_reason`).
- `curl`, `awk`, `sort`, `grep`, POSIX `sh`, `date`.
- A running Squid forward proxy on `HTTP_PROXY_PORT` for a non-SKIP run.
- Write access to `qa-results/` (gitignored).

## Usage examples

- Default run against `localhost:34128`:
  `bash tests/stress/proxy_forward_stress.sh`
- Conductor invocation under host-safety caps (§12.6):
  `GOMAXPROCS=2 nice -n 19 ionice -c 3 bash tests/stress/proxy_forward_stress.sh`
- Custom load / target:
  `STRESS_SEQ=100 STRESS_CONC=10 STRESS_TARGET=https://www.gstatic.com/generate_204 bash tests/stress/proxy_forward_stress.sh`

Env knobs: `HTTP_PROXY_URL` (default `http://localhost:34128`), `HTTP_PROXY_PORT`
(default `34128`), `STRESS_TARGET` (default `https://www.gstatic.com/generate_204`),
`STRESS_EXPECT` (default `204 200`), `STRESS_VIA_TARGET` (default
`http://www.gstatic.com/generate_204`), `STRESS_SEQ` (default `100`),
`STRESS_CONC` (default `10`), `CURL_MAX_TIME` (default `20`),
`STRESS_EVIDENCE_DIR` (default `qa-results/stress/proxy_forward_<ts>`).

## Edge cases

- **Every proxied request succeeds** → `PASS`, citing `latency.txt`. Exit `0`.
- **Some requests dropped BUT the target is reachable directly** → `FAIL`, a real
  proxy defect / possible deadlock (§11.4.68 — a listening-but-dropping proxy can
  never fail-open to SKIP). Exit `1`.
- **Requests dropped AND the target is unreachable directly too** → `SKIP`
  (`network_unreachable_external`) — a third-party outage is not a proxy defect
  (§11.4.1). Exit `3`.
- **Proxy port not listening + no direct signal** → `SKIP`
  (`topology_unsupported`). Exit `3`.
- **Deadlock guard**: no request can exceed `CURL_MAX_TIME`; a hung request
  reports `000` and counts as a failure — never hangs the suite.

## Internal behaviour

- `#!/usr/bin/env bash`, POSIX-clean body (`sh -n` + `bash -n`, §11.4.67).
- Step 0 Via corroboration probe (plain HTTP) → `via_probe_headers.txt`.
- Sequential loop → `seq.N.code`; concurrent burst → `conc.N.code` /
  `conc.N.time` (bounded by `STRESS_CONC`); latency samples sorted numerically;
  nearest-rank `p50/p95/p99` + `min/max/mean` computed in `awk` →
  `latency.txt`. Summary → `stress.evidence`.
- `trap ... EXIT INT TERM` reaps stray workers and removes the scratch dir
  (§11.4.14).
- Resources: shell + curl only, capped concurrency, well under the §12.6 60%
  host-memory ceiling.

## Related

- `tests/lib/evidence.sh` — sourced anti-bluff evidence library.
- `challenges/scripts/proxy_forward_http_challenge.sh` — the functional forward
  Challenge this stress suite complements.
- `tests/chaos/proxy_restart_recovery.sh`, `tests/security/proxy_acl_security.sh`
  — sibling chaos + security suites.
- Constitution §11.4.85 / §11.4.169 / §11.4.69 / §11.4.1 / §11.4.68 / §11.4.50 /
  §11.4.107 / §12.6.

## Last verified

2026-07-01 — authored; `sh -n` + `bash -n` parse-clean. Live sustained /
concurrent load is exercised by the conductor against the running proxy.
