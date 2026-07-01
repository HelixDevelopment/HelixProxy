# run_proxy_challenges.sh

**Revision:** 1
**Last modified:** 2026-07-01T00:00:00Z
**Authority:** Helix Constitution §11.4.27 (Challenges), §11.4.69 (sink-side positive evidence), §11.4.1 (script-crash = FAIL), §12.6/§12.9 (host resource caps), §11.4.89 (bounded execution)

## Overview

Runner for the helix_proxy forward-proxy anti-bluff Challenge bank. It executes
the three challenges — HTTP forward, SOCKS5 forward, Squid cache — against the
**live running proxy** under host-safety resource caps, tallies PASS/FAIL/SKIP,
and writes a summary plus per-challenge evidence under
`qa-results/challenges/<run-ts>/`. It exits non-zero **only** on a real FAIL; an
honest SKIP is not a failure, and an unexpected exit code (e.g. a `set -u` crash)
is conservatively counted as FAIL per §11.4.1.

## Prerequisites

- The three sibling challenge scripts present and executable.
- `bash`; `nice` / `ionice` optional (caps degrade gracefully if absent).
- The live proxy stack UP (HTTP `53128`, SOCKS5 `51080`).

## Usage

```sh
bash challenges/scripts/run_proxy_challenges.sh
```

Any per-challenge environment (`HTTP_PROXY_URL`, `SOCKS5_PROXY`, `CACHE_URL`,
`SQUID_ACCESS_LOG`, `LOG_DIR`, `CURL_MAX_TIME`, …) is passed straight through.

## Resource caps (host-safety)

Each challenge runs under `GOMAXPROCS=2 nice -n 19 ionice -c 3` (§12.6/§12.9).
`GOMAXPROCS` is exported for any Go tooling a challenge might invoke; the shell
challenges themselves are lightweight `curl` clients.

## Exit codes

| Code | Meaning |
|------|---------|
| `0`  | No FAIL — every challenge was PASS or an honest SKIP. |
| `1`  | ≥1 challenge FAILed (a real proxy defect, a missing script, or an unexpected crash). |

## Outputs

- `qa-results/challenges/<run-ts>/summary.txt` — tally + per-challenge verdict lines.
- `qa-results/challenges/<run-ts>/<name>.log` — captured stdout/stderr per challenge.
- `qa-results/challenges/<run-ts>/evidence/…` — the challenges' captured evidence.

## Verdict mapping

Per-challenge exit code → tally: `0` → PASS, `3` → SKIP, anything else → FAIL.

## Related scripts

- `proxy_forward_http_challenge.sh`, `proxy_socks5_challenge.sh`,
  `proxy_cache_challenge.sh` — the challenges it drives.
- `tests/lib/evidence.sh` — the sourced anti-bluff helper library.

**Last verified:** 2026-07-01 (live run: total=3 PASS=2 SKIP=1 FAIL=0, exit 0).
