# proxy_cache_challenge.sh

**Revision:** 1
**Last modified:** 2026-07-01T00:00:00Z
**Authority:** Helix Constitution §11.4.27 (Challenges), §11.4.69 (sink-side positive evidence), §11.4.107 (forgeable-header discipline), §11.4.3 (honest SKIP), §11.4.68 (no fail-open)

## Overview

Anti-bluff Challenge that proves the **live HTTP proxy** (default
`http://localhost:53128`) caches. A cacheable plain-HTTP URL is fetched **twice**
through the proxy; the **authoritative** proof is a Squid `TCP_*HIT` result code
for that URL in the Squid `access.log`, asserted via `assert_cache_hit` from
`tests/lib/evidence.sh`. An `X-Cache` header or an `Age` field alone is
**forgeable** and is never accepted as the verdict — it is captured only as
supplementary evidence. If the `access.log` is not reachable/readable, the
challenge SKIPs with the closed-set reason `topology_unsupported` (§11.4.3); it
never fakes a PASS.

## Prerequisites

- The base proxy stack UP with the HTTP proxy on `53128`.
- `curl`, `bash`, `awk`, `grep`; `tests/lib/evidence.sh` present (sourced).
- The authoritative branch additionally requires the Squid `access.log` to be
  **readable** by the running user. In the reference rootless-container topology
  the log is owned by a container subuid (mode `0640`) and is **not** readable by
  the host user — the challenge then honestly SKIPs.
- READ-ONLY: plain proxy client + a read of the access.log — never touches any
  container.

## Usage

```sh
bash challenges/scripts/proxy_cache_challenge.sh
# override the cache url / log path / evidence dir:
CACHE_URL=http://example.com/ \
SQUID_ACCESS_LOG=/path/to/access.log \
CHALLENGE_EVIDENCE_DIR=/path/to/evidence \
  bash challenges/scripts/proxy_cache_challenge.sh
```

Environment: `HTTP_PROXY_URL` (default `http://localhost:53128`), `CACHE_URL`
(default `http://example.com/`), `SQUID_ACCESS_LOG` (override the resolved path),
`LOG_DIR` (default `./logs`; the compose file maps container `/var/log/squid`
here), `CHALLENGE_EVIDENCE_DIR` (default `qa-results/challenges/<run-ts>`),
`CURL_MAX_TIME` (default `20`).

## Access-log resolution

`SQUID_ACCESS_LOG` → `$LOG_DIR/access.log` (from env) → `.env` `LOG_DIR` →
`./logs/access.log` (the `docker-compose.yml` default mount).

## Exit codes

| Code | Meaning |
|------|---------|
| `0`  | PASS — a Squid `TCP_*HIT` for the URL was found in a **readable** access.log. |
| `1`  | FAIL — proxy could not fetch the reachable URL, **or** a readable log showed no `TCP_*HIT` for a URL fetched twice. |
| `3`  | SKIP — outage (URL unreachable) **or** the access.log is not readable (`topology_unsupported`, §11.4.3). |

## Anti-bluff notes

- The connectivity precondition uses `proxy_conn_verdict` so a site outage SKIPs
  while a proxy-broken-but-site-reachable-directly case FAILs.
- `Via:` / `Age:` headers are logged as **supplementary** only; the verdict rests
  on the data-plane `TCP_*HIT` result code, per §11.4.107.
- Unreadable log ⇒ honest `topology_unsupported` SKIP with the `ls -ln`
  ownership captured as the reason — never a fabricated cache PASS.

## Outputs

`<evidence-dir>/cache/cache_evidence.txt` (double-fetch codes, `Via`/`Age`
headers, connectivity verdict, and either the `assert_cache_hit` verdict or the
`ls -ln` unreadable-log evidence) plus the two raw header dumps.

## Related scripts

- `proxy_forward_http_challenge.sh`, `proxy_socks5_challenge.sh` — forwarding proofs.
- `run_proxy_challenges.sh` — the bank runner.
- `tests/lib/evidence.sh` — `assert_cache_hit` and the sourced helpers.

**Last verified:** 2026-07-01 (live run: precondition PASS, authoritative SKIP `topology_unsupported` — access.log owned by container subuid 100012, mode 0640, not readable by uid 1000).
