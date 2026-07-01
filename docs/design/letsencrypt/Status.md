# Let's Encrypt HTTPS — Integration Status

**Revision:** 1
**Last modified:** 2026-07-01T12:15:00Z
**Status:** In progress — Phase 1 cert-analyzer landed; issuance/renewal phases pending. Production cutover OPERATOR-BLOCKED (design §9 real-domain gate).
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
| 1 — Custom Caddy image w/ DNS-01 provider module | Build a Caddy image bundling the chosen DNS provider plugin (via the `containers` submodule, rootless — §11.4.76/.161) | PENDING | — |
| 2 — Compose service + Podman secret + cert volume | Wire Caddy service + secret NAME/PATH (no value) + persistent cert volume; no real issuance yet | PENDING | — |
| 3 — Hermetic local-ACME with Pebble (anti-bluff core) | Caddy issues a real cert against a local Pebble ACME server, fully offline/hermetic; cert-analyzer asserts the result | PENDING | — |
| 4 — LE **staging** end-to-end (real DNS-01) | Real LE staging endpoint + real DNS-01 | OPERATOR-BLOCKED | needs DNS provider + token (§11.4.10) |
| 5 — Renewal + rotation simulation (zero-downtime) | Force near-expiry → observe Caddy renew → analyzer confirms new cert; no downtime | PENDING | — |
| 6 — Production cutover + rollback runbook | Real domain go-live | OPERATOR-BLOCKED | operator go-live gate (design §9) |

## Honest boundary (§11.4.6)

Only Phase 0 and the Phase-1 **cert-analyzer** are DONE with captured evidence. The
analyzer validates a resulting certificate regardless of how it was obtained, so it is
ready to assert the output of Phases 3–6 the moment those land. No issuance, renewal, or
rotation path has been exercised yet — those rows are honestly PENDING / OPERATOR-BLOCKED,
never a metadata-only PASS (§11.4 / §11.4.1). The hermetic Pebble path (Phase 3) is the
next autonomous target; the real-domain paths (4, 6) wait on the operator gate.
