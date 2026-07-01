# phase3_hermetic_issue.sh — Let's Encrypt Phase-3 hermetic issuance proof

**Revision:** 1
**Last modified:** 2026-07-01T10:08:00Z
**Authority:** Inherits `constitution/Constitution.md` per §11.4.35. §11.4.18 companion for `deploy/letsencrypt/phase3_hermetic_issue.sh`.

## Overview

Proves — repeatably, from a clean slate, with captured physical evidence — that the
custom Caddy image obtains a **real** TLS certificate via the ACME **DNS-01** challenge
against a **local Pebble** ACME server, fully offline, and that the project's
cert-analyzer verifies the issued cert. It is the anti-bluff core of the Let's Encrypt
workstream (§11.4.98 re-runnable · §11.4.107 real-evidence · §11.4.108 runtime-signature).

No bluff: Pebble runs with `PEBBLE_VA_ALWAYS_VALID=0` (a **genuine** DNS-01 validation),
and the PASS is gated on the analyzer verdicts over the leaf Caddy **actually served**.

## Prerequisites

- Rootless Podman + `podman-compose` (§11.4.161).
- The built image `localhost/helix_proxy/caddy-challtestsrv:2.8.4` — run
  `deploy/letsencrypt/build.sh` first.
- `openssl`, `curl`. Images `ghcr.io/letsencrypt/pebble:2.6.0`,
  `…/pebble-challtestsrv:2.6.0`, `docker.io/coredns/coredns:1.11.1` (pulled on first run).
- `tests/letsencrypt/cert_analyzer.sh` (sourced for the verdicts).

## Usage

```sh
bash deploy/letsencrypt/phase3_hermetic_issue.sh                 # run + tear down
KEEP_UP=1 bash deploy/letsencrypt/phase3_hermetic_issue.sh       # leave stack up (Phase-5)
CADDY_HTTPS_PORT=9443 CADDY_HTTP_PORT=9080 bash …                # override ports
```

Runs under `nice -n 19 ionice -c 3`. Auto-picks a free host port pair if the defaults
are busy (this host's `:8443` is owned by an operator service — §11.4.174).

## Exit codes

| Code | Meaning |
|---|---|
| 0 | PASS — a real cert was issued via DNS-01 and every cert-analyzer verdict PASSed |
| 1 | FAIL — a product defect (no cert served, or a verdict failed) |
| 2 | OPERATOR-BLOCKED / precondition unmet (image not built, podman-compose absent) |

## What it verifies (the anti-bluff gate)

Over the leaf Caddy served on `:CADDY_HTTPS_PORT` (SNI `proxy.hermetic.test`):

- `cert_not_expired` — the served cert is time-valid.
- `cert_san_matches proxy.hermetic.test` — covers the expected name…
- …and a **negative** check that it does NOT match `evil.example.invalid` (the analyzer
  is discriminating, not a rubber-stamp).
- `cert_chain_roots_in` — the leaf cryptographically chains to **this run's** Pebble CA,
  fetched fresh from Pebble's management API (`/roots/0` + `/intermediates/0`) — the
  strongest proof the cert was genuinely issued by this Pebble instance.

## Internal behaviour

1. `podman-compose down -v` (fresh Caddy `/data` — avoids certmagic bug #354).
2. Materialize `pebble-ca/pebble.minica.pem` (Pebble's public trust anchor) via `podman cp`.
3. Boot pebble + challtestsrv; resolve challtestsrv's live pod IP.
4. Write `coredns/Corefile` (authoritative `hermetic.test` SOA in the ANSWER section +
   fall-through forward of the dynamic `_acme-challenge` TXT to that IP); boot CoreDNS.
5. Wait for the Pebble ACME directory; boot caddy — issuance triggers on start.
6. Poll `:CADDY_HTTPS_PORT` for the served leaf with the expected SAN.
7. Fetch this run's Pebble CA; run the cert-analyzer verdicts; write evidence; PASS/FAIL.

## Edge cases

- **Image not built / podman-compose absent** → exit 2 (OPERATOR-BLOCKED), never a fake pass.
- **Port `:8443` busy** (operator `lava-api` on this host) → auto-picks `9443`/`9080`.
- **Broken resolver** (e.g. `ACME_RESOLVERS=challtestsrv:8053`, bypassing CoreDNS) → the
  SOA walk hits NOTIMP, no cert is served, exit 1 — this is exactly what the
  `tests/letsencrypt/phase3_issuance_guard.sh` RED_MODE reproduces.
- Cleanup (`down -v`) runs on every exit path unless `KEEP_UP=1` (§11.4.14).

## Internal behaviour — why CoreDNS

certmagic's DNS-01 flow does an SOA walk to determine the zone **before** presenting the
TXT; challtestsrv answers `NOTIMP` to SOA. CoreDNS is inserted as an authoritative SOA
front (`template IN SOA` in the ANSWER section) so certmagic accepts `hermetic.test` as
the zone, while the dynamic TXT still lives in challtestsrv (via `forward`). Full
root-cause: `docs/research/letsencrypt_hermetic_20260701/` +
`docs/research/certmagic_chain_panic_20260701/`.

## Related scripts

- `deploy/letsencrypt/build.sh` — builds the DNS-01-capable Caddy image (run first).
- `tests/letsencrypt/cert_analyzer.sh` — the verdict functions this script sources.
- `tests/letsencrypt/phase3_issuance_guard.sh` — the §11.4.135 standing regression guard.
- `challenges/scripts/le_phase3_issuance_challenge.sh` — the HelixQA-style Challenge.

## Last verified

2026-07-01 — two clean runs (`20260701T100119Z`, `20260701T100434Z`) each issued a real
cert (distinct per-run Pebble intermediate CAs `4ce89d` / `351928`) with all four
cert-analyzer verdicts PASS. Evidence: `qa-results/letsencrypt/phase3_issuance/`.
