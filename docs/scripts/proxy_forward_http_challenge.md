# proxy_forward_http_challenge.sh

**Revision:** 1
**Last modified:** 2026-07-01T00:00:00Z
**Authority:** Helix Constitution §11.4.27 (Challenges), §11.4.69 (sink-side positive evidence), §11.4.1 (no false-FAIL), §11.4.68 (no fail-open), §11.4.2/§11.4.5 (captured evidence)

## Overview

Anti-bluff Challenge that proves the **live HTTP forward proxy** (default
`http://localhost:34128`) actually forwards real end-user traffic. It drives two
real sub-probes through the proxy — a plain-HTTP `GET` to a `204` endpoint and a
CONNECT-tunnelled HTTPS `GET` — and asserts the through-proxy `%{http_code}`
matches the expected code, cross-checked against a **direct** fetch of the same
URL. Response headers (including Squid's `Via:` line) are captured to an evidence
file, so every PASS cites a real artefact.

## Prerequisites

- The base proxy stack UP with the HTTP proxy listening on `34128`.
- `curl`, `bash`, `awk`, `grep`; `tests/lib/evidence.sh` present (sourced).
- READ-ONLY: the script is a plain proxy client — it never starts, stops,
  restarts, or reconfigures any container.

## Usage

```sh
bash challenges/scripts/proxy_forward_http_challenge.sh
# override target / evidence dir:
HTTP_PROXY_URL=http://localhost:34128 \
CHALLENGE_EVIDENCE_DIR=/path/to/evidence \
  bash challenges/scripts/proxy_forward_http_challenge.sh
```

Environment: `HTTP_PROXY_URL` (default `http://localhost:34128`),
`HTTP_PROXY_PORT` (default `34128`), `CHALLENGE_EVIDENCE_DIR`
(default `qa-results/challenges/<run-ts>`), `CURL_MAX_TIME` (default `20`).

## Exit codes

| Code | Meaning |
|------|---------|
| `0`  | PASS — ≥1 sub-probe proved forwarding and none FAILed. |
| `1`  | FAIL — a real proxy defect (proxy missed but the same URL was reachable directly). |
| `3`  | SKIP — honest non-applicable: no endpoint reachable (third-party/network outage, §11.4.3). |

## Anti-bluff decision (per sub-probe, via `proxy_conn_verdict`)

- proxy code in expected → **PASS**
- proxy miss + same URL reachable **directly** → **FAIL** (§11.4.68, no fail-open)
- proxy miss + direct miss → **SKIP** (§11.4.1, no false-FAIL on a site outage)

Aggregate: **FAIL** if any sub-probe FAILs; **PASS** if ≥1 PASSes and none FAIL;
otherwise **SKIP**.

## Edge cases

- A `204` endpoint that goes down SKIPs its sub-probe (not a proxy fault); the
  HTTPS sub-probe can still carry the run to PASS.
- The captured `Via: ... proxy-squid` header is hard client-side proof the bytes
  transited the proxy, beyond the HTTP status code alone.

## Outputs

`<evidence-dir>/http/forward_http_evidence.txt` (per-probe codes, verdicts,
captured response headers) plus per-probe raw header dumps.

## Related scripts

- `proxy_socks5_challenge.sh` — the SOCKS5 sibling.
- `proxy_cache_challenge.sh` — Squid cache-HIT proof.
- `run_proxy_challenges.sh` — the bank runner.
- `tests/lib/evidence.sh` — the sourced anti-bluff helper library.

**Last verified:** 2026-07-01 (live run: PASS, `Via: 1.1 proxy-squid (squid/6.13)` captured).
