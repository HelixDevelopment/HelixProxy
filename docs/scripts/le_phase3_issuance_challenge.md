# le_phase3_issuance_challenge.sh

**Revision:** 1
**Last modified:** 2026-07-01T00:00:00Z
**Authority:** Helix Constitution §11.4.27 (Challenges), §11.4.69 (sink-side positive evidence), §11.4.116 (verdict corroborated by its captured evidence), §11.4.107 (real captured evidence), §11.4.3 (honest SKIP), §11.4.1 (script-crash = FAIL), §11.4.119 (conductor owns the container resource), §12.6/§12.9 (host resource caps)

## Overview

Anti-bluff Challenge that proves the Let's Encrypt **hermetic DNS-01 issuance**
path really works: the custom Caddy image obtains a REAL TLS certificate via the
ACME DNS-01 challenge against a LOCAL Pebble ACME server, fully offline, and the
project's cert-analyzer verifies it.

The Challenge does not re-implement the issuance flow. It delegates to the
conductor-authored, re-runnable proof
`deploy/letsencrypt/phase3_hermetic_issue.sh`, then — on a phase3 PASS —
independently **re-reads phase3's own captured analyzer verdict file**
(`cert_analyzer_verdicts.txt`) and asserts the two decisive verdicts are `PASS`.
That re-read is the anti-bluff cross-check (§11.4.116): a PASS is only accepted
when the captured evidence corroborates it, never on the runner's word.

## Who runs it (§11.4.119)

The **conductor** runs this Challenge. Invoking it boots the hermetic
Pebble + challtestsrv + CoreDNS + Caddy stack (through phase3), and under the
single-resource-owner rule only the conductor may boot containers. This script
authors the proof and delegates the boot to phase3; it never itself issues a
container command.

## Prerequisites

- `bash`; `tests/lib/evidence.sh` (sourced for `ab_pass_with_evidence` /
  `ab_skip_with_reason`).
- `deploy/letsencrypt/phase3_hermetic_issue.sh` present.
- `podman` + `podman-compose` (rootless) on PATH.
- The built image `localhost/helix_proxy/caddy-challtestsrv:2.8.4`
  (run `deploy/letsencrypt/build.sh` first).

If any of these is absent the Challenge emits an **honest SKIP**
(`topology_unsupported`) — never a fake pass.

## Usage

```sh
bash challenges/scripts/le_phase3_issuance_challenge.sh
```

Environment honoured by phase3 is passed straight through (`KEEP_UP`,
`CADDY_HTTPS_PORT`, `CADDY_HTTP_PORT`, `TEST_HOSTNAME`); `CADDY_IMAGE` and
`CHALLENGE_EVIDENCE_DIR` are honoured here.

## Resource caps (host-safety)

phase3 is invoked under `GOMAXPROCS=2 nice -n 19 ionice -c 3`
(§12.6/§12.9); the caps degrade gracefully when `nice`/`ionice` are absent.

## Exit-code contract

The Challenge maps phase3's exit code (0 = real cert issued + all analyzer
verdicts PASS; 1 = product defect; 2 = OPERATOR-BLOCKED / precondition unmet)
onto the standard Challenge verdict codes:

| Code | Verdict | When |
|------|---------|------|
| `0`  | PASS | phase3 exited 0 **and** its captured `cert_analyzer_verdicts.txt` carries `cert_chain_roots_in: PASS` **and** `cert_san_matches: PASS`. |
| `1`  | FAIL | phase3 exited 1 (or any unexpected non-0/non-2 code, §11.4.1), **or** phase3 exited 0 but the captured verdicts do not corroborate it (§11.4.116). |
| `3`  | SKIP | An honest, non-applicable precondition: the built image / `podman-compose` / phase3 script is absent, or phase3 itself reported OPERATOR-BLOCKED (rc 2). |

## Honest-SKIP conditions (§11.4.3)

A SKIP is emitted (exit 3) — never a fabricated PASS — when:

- `deploy/letsencrypt/phase3_hermetic_issue.sh` is missing;
- `podman-compose` is not on PATH;
- the built image `localhost/helix_proxy/caddy-challtestsrv:2.8.4` does not exist
  (build not run);
- phase3 exits `2` (its own precondition check found the environment unmet).

## Anti-bluff evidence (§11.4.69 / §11.4.116)

The two re-read verdicts are the decisive proofs of a genuine issuance:

- `cert_chain_roots_in: PASS` — the served leaf cryptographically chains to
  **this run's** freshly-regenerated Pebble CA (a real issuance, not a static
  fixture).
- `cert_san_matches: PASS` — the issued cert carries the requested hostname SAN.

The PASS cites phase3's own `cert_analyzer_verdicts.txt` via
`ab_pass_with_evidence`, which refuses to PASS if that artefact is missing or
empty.

## Outputs

- `qa-results/challenges/<run-ts>/le_phase3/phase3_stdout.log` — captured phase3
  output.
- `qa-results/challenges/<run-ts>/le_phase3/verdict_crosscheck.txt` — the
  Challenge's re-read of phase3's analyzer verdicts.
- phase3's own evidence under
  `qa-results/letsencrypt/phase3_issuance/<run-id>/` (the cited
  `cert_analyzer_verdicts.txt`, `served_leaf.pem`, `pebble_ca_bundle.pem`,
  `caddy_issuance.log`).

## Related scripts

- `deploy/letsencrypt/phase3_hermetic_issue.sh` — the re-runnable proof this
  Challenge delegates to.
- `tests/letsencrypt/cert_analyzer.sh` — the analyzer whose verdicts gate the PASS.
- `tests/lib/evidence.sh` — the sourced anti-bluff helper library.
- `challenges/scripts/run_proxy_challenges.sh` — the sibling Challenge-bank runner
  (same exit-code convention: 0 = PASS, 3 = SKIP, else = FAIL).

**Last verified:** 2026-07-01 (authored + `sh -n`/`bash -n` clean; not executed
here — the conductor runs it because it boots containers, §11.4.119).
