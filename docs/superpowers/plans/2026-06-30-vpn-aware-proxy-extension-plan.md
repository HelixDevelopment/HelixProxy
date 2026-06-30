# Implementation Plan — Helix Proxy: VPN-Aware Dynamic Routing Extension

**Revision:** 1
**Last modified:** 2026-06-30T00:00:00Z
**Status:** Active
**Spec:** `docs/superpowers/specs/2026-06-30-vpn-aware-proxy-extension-design.md`
**Discipline:** Every task is TDD reproduce-first (§11.4.43/§11.4.115), covers all
warranted test types (§11.4.169), carries a paired §1.1 mutation, produces
captured **data-plane** evidence (§11.4.69/§11.4.107 — no bluff), is independently
code-reviewed before commit (§11.4.142/§11.4.125 → iterate-to-GO §11.4.134),
keeps docs in sync (§11.4.106/§11.4.60/§11.4.65), commits via the project wrapper,
pushes with **no force** (§11.4.113), builds via the **containers submodule** on
the remote host (§11.4.173).

**Legend:** ⟂ = parallelizable (file-disjoint) · ⛓ = sequential dependency ·
🔬 = spike (resolve an `UNCONFIRMED:` gap with captured evidence) ·
🧪 = test types · 📸 = captured evidence required.

---

## Phase 0 — Foundations  (IN FLIGHT)
**Goal:** governance carriers, required submodules, scaffolds, evidence harness.

- **T0.1 ⟂ Governance carriers** (subagent live): create `QWEN.md`+`GEMINI.md`;
  ensure §11.4 anti-bluff covenant + verbatim forensic anchor + docs-sync
  directive in all 5 carriers (§11.4.35/§11.4.157). 📸 grep proof. → task #14.
- **T0.2 ⟂ Postgres data model** (subagent live): `sql/` DDL+migrations+seed, ER
  mermaid, `docs/DATABASE.md`. 📸 schema parse/`\d+`. → task #16.
- **T0.3 ⟂ Evidence harness** (subagent live): `tests/lib/evidence.sh` +
  fixtures + self-tests (parsers provably fail on negative fixtures). → task #17.
- **T0.4 ⛓ Incorporate required submodules** (conductor — touches `.gitmodules`,
  SSH-only, `install_upstreams` §11.4.36, no-force): add
  `vasic-digital/containers` (§11.4.76), `HelixDevelopment/HelixQA`,
  `vasic-digital/challenges`, `vasic-digital/docs_chain` (§11.4.106). Subtasks:
  catalogue-check each (§11.4.74); `git submodule add` via SSH; run
  `install_upstreams`; record `helix-deps.yaml` (§11.4.31); bump pointers.
  📸 `git submodule status` + remote verification.
- **T0.5 ⟂ Go control-plane scaffold:** `control-plane/go.mod`, dir layout
  (`cmd/{healthd,acl-helper,compiler,api}`, `internal/{vpn,routing,store,redis,
  breaker,api,pac,otel}`), CI-free build target. 📸 `go build ./...` (via
  containers submodule build, §11.4.173).
- **T0.6 ⟂ Extend `.env.example`:** Postgres/Redis/dynamic-routing/gluetun/auth
  vars; **fix the `HT PASSWD_FILE` typo (line 115)**; secret-ref conventions
  (§11.4.10). 📸 diff + `load_environment` smoke.
- **T0.7 ⛓ P0 review + checkpoint commit** (§11.4.142): conductor reviews all
  T0 subagent output, runs quiescence check (§11.4.84), commits via wrapper,
  pushes no-force.

## Phase 1 — Spikes (resolve UNCONFIRMED gaps)  ⛓ after T0.4
- **T1.1 🔬 G2 Squid version** on `ubuntu/squid:latest` (`squid -v`); confirm
  whether `tcp_outgoing_address` dstdomain / `cache_peer` syntax apply. 📸.
- **T1.2 🔬 G1 rootless kernel-WireGuard** feasibility via gluetun; else confirm
  userspace `wireguard-go` path. 📸 `wg show` inside a rootless gluetun.
- **T1.3 🔬 G4 gluetun control-API** on a pinned tag (`/v1/vpn/status`,
  `/v1/publicip/ip`) reachable. 📸 curl output.
- **T1.4 🔬 G3 Dante `SIGHUP`** live-session preservation. 📸 active-conn survives.
- Each spike → records FACT/`UNCONFIRMED` resolution in `docs/research/mvp/findings/`
  and updates the spec if a decision changes.

## Phase 2 — Data model + live stores  ⛓ T0.4, T0.2
- **T2.1** Wire Postgres + Redis as compose services (rootless) under the new
  `dynamic` profile, booted on-demand via the containers submodule.
- **T2.2** Apply schema/migrations against the real Postgres. 🧪 integration. 📸 `\d+`.
- **T2.3** `internal/store` (Postgres) + `internal/redis` clients with the §7
  contract. 🧪 unit (mocks) + integration (real PG/Redis) + paired mutation. 📸.

## Phase 3 — vpn-health-publisher (real data-plane health)  ⛓ T1.2/T1.3, T2.3
- **T3.1** `cmd/healthd`: per-profile poll gluetun API + `wg show transfer` Δ +
  egress probe → write `vpn:status:<profile>` + publish `vpn:events`.
- **T3.2** Health = data-plane fact (tx-Δ>0 + fresh handshake + egress≠host).
- 🧪 unit(parsers, mocks) + integration(real gluetun) + chaos(drop tunnel →
  status flips down) + paired mutation (publisher must report down on tx-Δ==0).
  📸 status JSON + `vpn:events` capture + `wg` snapshots.

## Phase 4 — config-compiler + Squid/Dante integration  ⛓ T1.1, T3.x
- **T4.1** `cmd/compiler`: PG → Squid generated include (`cache_peer` per tunnel,
  `cache_peer_access`, `never_direct`, `deny_info 503`) + Dante routes + PAC.
- **T4.2** `squid.conf.base` + include wiring; structural reload only.
- **T4.3** Dante route generation + `SIGHUP` (per T1.4 result).
- 🧪 unit(render golden files) + integration(real Squid/Dante load the config) +
  paired mutation (corrupt a peer → gate fails). 📸 `squid -k parse`, `sockd` start.

## Phase 5 — external-acl-helper + graceful 503 + breaker/failover  ⛓ T4, T3
- **T5.1** `cmd/acl-helper`: Squid `external_acl_type`; per-request Redis lookup
  `{target→tunnel, up?}` → `OK tag=<tunnel>` / `ERR`.
- **T5.2** `internal/breaker` (gobreaker) + tunnel tier-failover (target's ordered
  tiers; open breaker → next up tier → else 503).
- 🧪 unit + integration (real Squid + helper + Redis) + the **graceful_503**
  evidence test (tunnel down → 503 + branded body + **Squid PID unchanged** → up
  → 200) + failover test + paired mutation. 📸 per §13 matrix.

## Phase 6 — control-API + admin UI  ⛓ T2.3, T5
- **T6.1** `cmd/api`: REST CRUD (profiles/targets/rules/users), live status SSE,
  Prometheus `/metrics`, `FindProxyForURL` PAC, mTLS.
- **T6.2** admin UI (`templ`+`htmx`+SSE), **OpenDesign tokens §11.4.162**,
  light+dark, replaces `traefik/whoami`.
- 🧪 unit + integration(real API+PG) + e2e(CRUD round-trip) + security(authz/mTLS)
  + **host-rendered pixel proof §11.4.170** (no value-equality-only UI tests) +
  paired mutation. 📸 REST transcripts + rendered PNGs (light+dark).

## Phase 7 — DNS privacy + observability + security/secrets  ⟂ within, ⛓ T5/T6
- **T7.1** `AdguardTeam/dnsproxy` sidecar per tunnel (DoH/DoT) + DNS-leak proof.
- **T7.2** `squid-exporter` + Prometheus + Grafana dashboards + OTel spans.
- **T7.3** Podman secrets for VPN creds/auth/mTLS (no plaintext, §11.4.10);
  per-user Squid auth + audit log; in-netns kill-switch.
- 🧪 security(leak/auth) + integration(metrics scrape) + paired mutation. 📸 zero
  plaintext-:53 packets; metrics present; secret never in git (history scan).

## Phase 8 — Fix existing-test bluffs (Stream E)  ⟂ (tests/ only), ⛓ T5
- **T8.1** §11.4.115 reproduce each bluff on the pre-fix artifact (RED), then fix:
  ① false VPN-routing PASS → egress≠host && ==exit + `wg`Δ; ② cache-timing →
  `TCP_HIT`; ③ concurrent → `%{http_code}`; ④ `run-tests.sh` presence-only →
  real probes or honest SKIP. §11.4.138 bluff-audit + §11.4.135 permanent guard.
  📸 RED-then-GREEN per fix.

## Phase 9 — Full test matrix + Challenges + HelixQA  ⛓ T5–T8
- **T9.1 ⟂** per-capability **Challenges** (`challenges/scripts/<cap>_challenge.sh`)
  — real evidence, no return-code bluff (§13 matrix).
- **T9.2 ⟂** missing **test types** (§11.4.169): DDoS/load (k6/vegeta), stress,
  chaos (toxiproxy), concurrency, race (`-race`), memory soak, benchmark, e2e,
  full-automation (re-runnable, no manual step §11.4.98).
- **T9.3 ⟂** **HelixQA** test banks/suites + autonomous QA session wiring (§11.4.27).
- **T9.4** paired §1.1 mutation per test; coverage ledger (§11.4.25/§11.4.52).

## Phase 10 — Live validation + captured evidence  ⛓ T9
- **T10.1** Boot the full `dynamic` profile (containers submodule); run the whole
  matrix; capture evidence under `qa-results/<run-id>/` + curated `docs/qa/<run-id>/`
  (§11.4.83). 📸 window-scoped, project-prefixed recordings (§11.4.154/.155) +
  vision-verified (§11.4.158/.159).
- **T10.2** Risk-ordered run (§11.4.132): newest/most-fragile capabilities first.
- **T10.3** Determinism: each PASS reproduced N× identical (§11.4.50).

## Phase 11 — Docs sync + exports  ⛓ continuous, finalize here
- **T11.1** Update ARCHITECTURE/CACHE/VPN + new DYNAMIC_ROUTING + DATABASE +
  README + USER_GUIDE; diagrams/graphs/SQL all current.
- **T11.2** Bind everything via **docs_chain** contexts (§11.4.106); HTML+PDF
  (+DOCX where mandated) exports (§11.4.65); §11.4.168 exported-doc visual
  validation (no raw mermaid source leaking into PDFs). 📸 `verify` clean.

## Phase 12 — Review + release  ⛓ last
- **T12.1** Independent code-review gate over the whole branch (§11.4.142/.125),
  iterate to zero-finding GO (§11.4.134).
- **T12.2** Full-suite retest from clean baseline (§11.4.40); coverage ledger green.
- **T12.3** Commit via wrapper; **merge onto latest main, no force** (§11.4.113);
  **project-prefixed release tag** (§11.4.151) across repo + any touched submodule;
  push all upstreams (§2.1). Update `docs/CONTINUATION.md` + the standing
  session-resumption file (§12.10/§11.4.131).

---

## Parallelization map (which streams run together)
- **Now (P0):** T0.1 ‖ T0.2 ‖ T0.3 (live) + conductor T0.4/T0.5/T0.6.
- **After P0:** P1 spikes (T1.1–T1.4 all ⟂) ‖ P2 store clients.
- **Mid:** P3 ‖ P4 (compiler) once health contract fixed; P7 sub-tasks ⟂.
- **Late:** P8 ‖ P9.1 ‖ P9.2 ‖ P9.3 all ⟂ (disjoint dirs).
- Cap: ≤6 concurrent agents (§11.4.58), ≤60% host memory (§12.6), single build
  queue (§11.4.173), one owner per device/sink (§11.4.119).

## Definition of Done (per §11.4.40 / §11.4.108 / §11.4.169)
A capability is DONE only when: real artifact built via containers submodule →
deployed on a clean `dynamic` profile → its **runtime signature** verified →
all warranted test types green with captured data-plane evidence → Challenge +
HelixQA green → paired mutation proves the test catches its negation →
independent review GO → docs in sync + exported. No self-certification; pasted
real output required.
