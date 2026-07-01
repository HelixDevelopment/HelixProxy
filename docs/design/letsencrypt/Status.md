# Let's Encrypt HTTPS — Integration Status

**Revision:** 3
**Last modified:** 2026-07-01T11:42:00Z
**Status:** In progress — Phases 0–3 + 5 PASS: a REAL hermetic DNS-01 certificate is issued by local Pebble AND auto-renewed/rotated (S1→S2, new serial, zero-downtime swap), both cert-analyzer-verified + re-runnable + guarded. All autonomous LE phases are DONE. Phase 4 (LE staging) + Phase 6 (production cutover) remain OPERATOR-BLOCKED (design §9 real-domain gate).
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
| 5 — Renewal + rotation simulation (zero-downtime) | Force the ARI renewal window → Caddy renews via the ACME renewal path → analyzer confirms the new cert; 0 dropped across the swap | PASS | re-runnable `phase5_rotation.sh`: S1→S2 (new serial, later notBefore), caddy log `certificate needs renewal based on ARI window`→`renewed successfully`, swap `ok=6 fails=0`, cert-analyzer PASS (S2→per-run Pebble CA); guard `phase5_rotation_guard.sh` RED+GREEN proven (wired in run-tests.sh); `qa-results/letsencrypt/phase5_rotation/`. Trigger mechanism (storage-surgery on the cached ARI + restart) is source-justified in `docs/research/caddy_2110_ari_refetch_20260701/` — in production Caddy renews on its own schedule, no trigger needed |
| 6 — Production cutover + rollback runbook | Real domain go-live | OPERATOR-BLOCKED | operator go-live gate (design §9) |

## Honest boundary (§11.4.6)

Phases 0–3 + 5 are DONE with captured evidence. Issuance (Phase 3): the custom Caddy image
is built with the DNS-01 module linked (anti-bluff-verified), the hermetic stack is wired
(CoreDNS SOA front fixes certmagic's zone-determination), and `phase3_hermetic_issue.sh`
issues a REAL cert via DNS-01 against local Pebble (`PEBBLE_VA_ALWAYS_VALID=0`) that the
cert-analyzer verifies over the served leaf (incl. chain to THIS RUN's Pebble CA). Renewal
(Phase 5): `phase5_rotation.sh` forces the ARI renewal window and Caddy renews via the ACME
renewal path (`certificate needs renewal based on ARI window`→`renewed successfully`) to a
NEW serial with a later notBefore, the renewal SWAP measured zero-downtime (0 dropped), and
the cert-analyzer verifies the new leaf. Both are re-runnable (§11.4.98/§11.4.107) + guarded
(§11.4.135, RED+GREEN). Honest trigger boundary (§11.4.6): the hermetic renewal is forced via
storage-surgery on the cached ARI window + a Caddy restart because certmagic v0.21.3 (and even
Caddy ≥2.11.0 — source-proven `docs/research/caddy_2110_ari_refetch_20260701/`) offers no
on-demand ARI re-fetch; in PRODUCTION Caddy renews on its own maintenance schedule with no
trigger + no restart. NOT exercised (honestly): the real-domain paths — Phase 4 (LE staging)
+ Phase 6 (production cutover) — wait on the operator gate; never a metadata-only PASS
(§11.4 / §11.4.1).
