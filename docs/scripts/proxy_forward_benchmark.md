# proxy_forward_benchmark.sh — user guide

**Revision:** 1
**Last modified:** 2026-07-01T13:10:00Z

## Overview

`tests/benchmark/proxy_forward_benchmark.sh` is the §11.4.169
**benchmarking / performance** test-type for the live HTTP forward proxy
(Squid on `127.0.0.1:53128`). It measures forward-proxy request **latency**
(nearest-rank `p50` / `p95` / `p99` + `min` / `max` / `mean`) and sequential
**throughput** (successful requests per wall-second) by driving `N` (default
200) plain-HTTP requests through the proxy to a 204-returning endpoint and
capturing **every** request's `%{http_code}` + `%{time_total}` to an evidence
file. The verdict rests on the captured per-request samples, never a summary
number (§11.4.6 no fake numbers, §11.4.69 captured evidence).

It is the performance sibling of the §11.4.85 stress suite
(`tests/stress/proxy_forward_stress.sh`) and reuses the same anti-bluff
verdict contract from `tests/lib/evidence.sh`.

## Prerequisites

- The base proxy stack UP (`./start`), Squid listening on `:53128`.
- `bash`, `curl`, `awk`, `sort`, `grep` on `PATH`.
- Network reachability to `BENCH_TARGET` (default `www.gstatic.com`) — an
  external outage is classified as an honest SKIP, never a false FAIL.

## Usage examples

```bash
# default: 200 sequential requests, host-safety caps applied
GOMAXPROCS=2 nice -n 19 ionice -c 3 bash tests/benchmark/proxy_forward_benchmark.sh

# smaller/larger sample, custom proxy/target
BENCH_N=50 PROXY_ADDR=127.0.0.1:53128 \
  BENCH_TARGET=http://www.gstatic.com/generate_204 \
  bash tests/benchmark/proxy_forward_benchmark.sh
```

Env overrides: `PROXY_ADDR` (default `127.0.0.1:53128`), `BENCH_TARGET`,
`BENCH_EXPECT` (default `204`), `BENCH_N` (default `200`), `CURL_MAX_TIME`
(default `20`), `BENCH_EVIDENCE_DIR`.

## Edge cases

- **Proxy dropped requests while target reachable directly** → `OVERALL=FAIL`
  (exit 1) — a real proxy defect (§11.4.68 no fail-open, never masked as SKIP).
- **Target unreachable via proxy AND directly, port listening** →
  `SKIP:network_unreachable_external` (exit 3) — third-party outage, not a
  proxy defect (§11.4.1 no false-FAIL of a healthy proxy).
- **Proxy port not listening, no direct signal** →
  `SKIP:topology_unsupported` (exit 3) — the base stack is down (§11.4.3).
- A hung request cannot exceed `CURL_MAX_TIME` (bounds the whole run) and is
  recorded as `000`.

## Internal behaviour

1. Sources `tests/lib/evidence.sh` (walks up to find the repo root).
2. Fires `N` sequential `curl -x http://$PROXY_ADDR $BENCH_TARGET`, appending
   `%{time_total}` to a sample set and counting `EXPECT` responses.
3. Sorts the samples, computes nearest-rank percentiles + throughput, writes
   `latency.txt` (raw samples + distribution) and `benchmark.evidence` under
   `qa-results/benchmark/proxy_forward_<ts>/`.
4. Cross-checks a direct (non-proxied) probe to classify a shortfall as a
   proxy defect vs an external outage.
5. Emits one structured `PASS` (≥ `N` successful 204s) / `FAIL` / `SKIP`
   verdict via `ab_pass_with_evidence` / `ab_skip_with_reason`, citing
   `latency.txt`.
6. `trap` cleanup removes only the scratch dir (§11.4.14); evidence preserved.

## Last verified

2026-07-01 — live run against the base proxy: **200/200** proxied 204s,
`p50=0.086s p95=0.088s p99=0.091s` (min 0.085 / max 0.102 / mean 0.087),
throughput 10.841 req/s, `OVERALL=PASS`. Evidence:
`qa-results/benchmark/proxy_forward_20260701T130414Z/latency.txt`.

## Related scripts

- `tests/stress/proxy_forward_stress.sh` — §11.4.85 stress sibling.
- `tests/lib/evidence.sh` — shared anti-bluff verdict helpers.
- `docs/design/hardening/Status.md` — §11.4.169 test-type coverage matrix.
