# Let's Encrypt HTTPS — Integration Status

**Revision:** 2
**Last modified:** 2026-07-01T10:06:00Z
**Status:** In progress — Phases 0–3 PASS: a REAL hermetic DNS-01 certificate is issued by local Pebble and verified by the cert-analyzer (re-runnable). Phase 5 (renewal/rotation) next; Phase 4 (LE staging) + Phase 6 (production cutover) OPERATOR-BLOCKED (design §9 real-domain gate).
**Authority:** Inherits `constitution/Constitution.md` per §11.4.35. §11.4.45 integration-status doc for the Let's Encrypt HTTPS workstream (task #59).
**Companion:** design [`../LETSENCRYPT_HTTPS.md`](../LETSENCRYPT_HTTPS.md) · plan [`../LETSENCRYPT_HTTPS_PLAN.md`](../LETSENCRYPT_HTTPS_PLAN.md) · summary [`Status_Summary.md`](Status_Summary.md)

## Operator-blocked items (read first — §11.4.45 O(1) surface)

| Item | Why blocked | Unblock condition |
|---|---|---|
| Phase 4 — LE **staging** end-to-end (real DNS-01) | Needs a real DNS provider + an API token stored as a Podman secret (§11.4.10 — value never in git/`.env`). Operator chose *defer real domain* (Phase 0). | Operator provides the DNS provider name + a scoped API token, and names a test hostname. |
| Phase 6 — **production** cutover | Real public domain, real DNS-01 for that domain, single operator-gated go-live (design §9). | Operator authorises the go-live with the real domain + token + host firewall opening. |

## Operator decisions captured (Phase 0 — §11.4.66)

| Decision | Choice | Date |
|---|---|---|
| TLS client / terminator | **Caddy auto-HTTPS** (in-process ACME client + terminator; no cron/CI/hook renewal — §11.4.156) | 2026-07-01 |
| ACME challenge type | **DNS-01** (works without inbound :80/:443 to the host) | 2026-07-01 |
| Rollout order | **Hermetic (Pebble) + LE-staging first; defer real domain** — prod is one later operator-gated cutover | 2026-07-01 |

## Phase status (captured-evidence-driven — §11.4.5/§11.4.69)

| Phase | Scope | Validation | Evidence |
|---|---|---|---|
| 0 — Operator decisions + scaffolding | Capture the 3 design §9 decisions; scaffold the plan | PASS | decisions table above; committed `LETSENCRYPT_HTTPS.md` + `_PLAN.md` @ fddd25c |
| 1 — Cert-analyzer (client/challenge-agnostic) | Pure offline analyzer over a resulting PEM (`cert_not_expired` / `cert_days_remaining` / `cert_san_matches` / `cert_chain_roots_in` / `cert_renewal_due`) + golden-good/golden-bad self-validation (§11.4.107(10)) | PASS | selftest 37/37; guard GREEN+RED PASS; §1.1 mutation (SAN exact→substring) → guard FAIL, restore byte-identical md5 `a06e0f89…`; `qa-results/letsencrypt/cert-analyzer/` + `qa-results/regression/cert_analyzer_selfvalidation/` |
| 1 — Custom Caddy image w/ DNS-01 provider module | Build a rootless Caddy image bundling the local `dns.providers.challtestsrv` module (§11.4.161) | PASS | `build.sh` built `localhost/helix_proxy/caddy-challtestsrv:2.8.4`; post-build anti-bluff check `caddy list-modules \| grep dns.providers.challtestsrv` PASS (a build ≠ module linked, §11.4.6); `qa-results/letsencrypt/build/` |
| 2 — Compose service + Podman secret + cert volume + CoreDNS SOA front | Wire Caddy + CoreDNS (zone-determination fix) + secret NAME/PATH (no value) + persistent cert volume | PASS | `compose.hermetic.yml` (4 services; `PEBBLE_VA_ALWAYS_VALID=0`; secrets commented for hermetic; caddy loopback-bound per security-audit M1); CoreDNS answers `hermetic.test` SOA, forwards `_acme-challenge` TXT to challtestsrv |
| 3 — Hermetic local-ACME with Pebble (anti-bluff core) | Caddy issues a REAL cert against local Pebble via DNS-01, fully offline; cert-analyzer asserts the served leaf | PASS | re-runnable `phase3_hermetic_issue.sh` → 2 clean runs each issued a real cert (Pebble VA_ALWAYS_VALID=0 genuine validation); cert-analyzer PASS: not_expired + SAN `proxy.hermetic.test` + negative-SAN-reject + **chain-to-this-run's-Pebble-CA**; `qa-results/letsencrypt/phase3_issuance/20260701T100119Z/` + `…T100434Z/` |
| 4 — LE **staging** end-to-end (real DNS-01) | Real LE staging endpoint + real DNS-01 | OPERATOR-BLOCKED | needs DNS provider + token (§11.4.10) |
| 5 — Renewal + rotation simulation (zero-downtime) | Force near-expiry → observe Caddy renew → analyzer confirms new cert; no downtime | PENDING | — |
| 6 — Production cutover + rollback runbook | Real domain go-live | OPERATOR-BLOCKED | operator go-live gate (design §9) |

## Honest boundary (§11.4.6)

Phases 0–3 are DONE with captured evidence: the custom Caddy image is built with the
DNS-01 module linked (anti-bluff-verified), the hermetic stack is wired (with the CoreDNS
SOA front that fixes certmagic's zone-determination), and `phase3_hermetic_issue.sh`
issues a REAL cert via DNS-01 against local Pebble (genuine validation —
`PEBBLE_VA_ALWAYS_VALID=0`) that the cert-analyzer verifies over the served leaf,
including that it chains to THIS RUN's Pebble CA — proven on two clean re-runnable runs
(§11.4.98 / §11.4.107). What is NOT yet exercised (honestly): Phase 5 renewal/rotation
(research landed, `docs/research/letsencrypt_renewal_20260701/`; the running stack is left
up via `KEEP_UP=1` for it) and the real-domain paths (Phase 4 LE staging, Phase 6 production
cutover) which wait on the operator gate — never a metadata-only PASS (§11.4 / §11.4.1).
