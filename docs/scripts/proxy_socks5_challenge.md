# proxy_socks5_challenge.sh

**Revision:** 1
**Last modified:** 2026-07-01T00:00:00Z
**Authority:** Helix Constitution §11.4.27 (Challenges), §11.4.69 (sink-side positive evidence), §11.4.1 (no false-FAIL), §11.4.68 (no fail-open), §11.4.2/§11.4.5 (captured evidence)

## Overview

Anti-bluff Challenge that proves the **live SOCKS5 proxy** (default
`socks5://localhost:51080`) actually forwards a real end-user journey. It drives
two real sub-probes through `curl --proxy socks5://...` — a plain-HTTP `GET` to a
`204` endpoint and an HTTPS `GET` — and asserts the through-proxy `%{http_code}`
matches the expected code, cross-checked against a **direct** fetch of the same
URL. Response headers and per-probe verdicts are captured to an evidence file.

## Prerequisites

- The base proxy stack UP with SOCKS5 listening on `51080`.
- `curl` built with SOCKS5 support, `bash`, `awk`, `grep`;
  `tests/lib/evidence.sh` present (sourced).
- READ-ONLY: plain proxy client only — never touches any container.

## Usage

```sh
bash challenges/scripts/proxy_socks5_challenge.sh
# override target / evidence dir:
SOCKS5_PROXY=socks5://localhost:51080 \
CHALLENGE_EVIDENCE_DIR=/path/to/evidence \
  bash challenges/scripts/proxy_socks5_challenge.sh
```

Environment: `SOCKS5_PROXY` (default `socks5://localhost:51080`), `SOCKS5_PORT`
(default `51080`), `CHALLENGE_EVIDENCE_DIR` (default
`qa-results/challenges/<run-ts>`), `CURL_MAX_TIME` (default `20`).

## Exit codes

| Code | Meaning |
|------|---------|
| `0`  | PASS — ≥1 sub-probe proved forwarding and none FAILed. |
| `1`  | FAIL — a real proxy defect (proxy missed but the same URL was reachable directly). |
| `3`  | SKIP — honest non-applicable: no endpoint reachable (third-party/network outage, §11.4.3). |

## Anti-bluff decision

Identical `proxy_conn_verdict` discipline as the HTTP sibling, applied to the
SOCKS5 port: proxy-hits-expected → PASS; proxy-miss + direct-hit → FAIL;
both-miss → SKIP. Aggregate: FAIL if any FAILs; PASS if ≥1 PASSes and none FAIL;
else SKIP.

## Edge cases

- SOCKS5 to plain HTTP shows no `Via:` header (opaque TCP relay); the HTTP status
  code plus the direct cross-check is the functional evidence.
- A site outage SKIPs the affected sub-probe rather than false-FAILing a healthy
  proxy.

## Outputs

`<evidence-dir>/socks5/socks5_evidence.txt` plus per-probe raw header dumps.

## Related scripts

- `proxy_forward_http_challenge.sh` — the HTTP sibling.
- `proxy_cache_challenge.sh` — Squid cache-HIT proof.
- `run_proxy_challenges.sh` — the bank runner.
- `tests/lib/evidence.sh` — the sourced anti-bluff helper library.

**Last verified:** 2026-07-01 (live run: PASS, `204` + HTTP/2 `200` through SOCKS5 captured).
