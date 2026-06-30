# CONTINUATION — Helix Proxy: VPN-Aware Dynamic Routing Extension

**Revision:** 1
**Last modified:** 2026-07-01T00:00:00Z
**Status:** Active — control-plane + config-plane landed and unit/integration/parse-proven; the LIVE dynamic-stack data-plane proof is owed to P10.
**Branch:** `feature/vpn-aware-dynamic-routing`
**Spec:** `docs/superpowers/specs/2026-06-30-vpn-aware-proxy-extension-design.md` (Rev 4)
**Plan:** `docs/superpowers/plans/2026-06-30-vpn-aware-proxy-extension-plan.md` (Rev 1)
**Authority:** Inherits the Helix Constitution submodule (`constitution/Constitution.md`) per §11.4.35.

> §12.10 live-state resume file. Read this first, then `git fetch --all --prune`
> and re-read `git log --oneline main..HEAD`. Any agent must be able to resume
> exactly where the last session left off from this single file.

---

## 1. Current PHASE

**Control-plane / config-plane construction phase — landed: P0–P5a + P7.1/7.2/7.3.**
14 commits on `feature/vpn-aware-dynamic-routing` ahead of `main`. The Go
control-plane logic (stores, health-publisher, acl-helper, config-compiler) and
the DNS/observability/security config-plans are written and proven at the
unit / integration / config-parse layer. **No `dynamic`-mode container has been
booted and no live data-plane evidence exists yet** — that is the entire job of
P10 (the usability proof). In-flight next: **P5b** (breaker/failover), **P9**
(full test matrix), **P11** (docs export — this file is part of it). **P10 is
the critical unblocker** for any "it works for the end user" claim.

## 2. The 14 landed commits (`git log --oneline main..HEAD`, newest first)

| # | Commit | Phase | Summary |
|---|---|---|---|
| 14 | `1833c8f` | P7.3 | per-user Squid auth + rootless Podman-secret loader + kill-switch design (no secrets) |
| 13 | `603e039` | P5a  | acl-helper — Squid external_acl OK/ERR from Redis, fail-closed (stdlib) |
| 12 | `e6e336f` | P7.1 | per-tunnel DoH/DoT (dnsproxy) config plan + DNS-leak test design |
| 11 | `04526dd` | P4   | config-compiler — render Squid/Dante/PAC from PG + seed route keys (parse-verified) |
| 10 | `833fb9e` | P7.2 | Prometheus scrape + Grafana dashboard config plan (promtool-validated) |
|  9 | `11106a4` | P3   | vpn-health-publisher (cmd/healthd + internal/vpn) — data-plane health, fail-closed, TDD |
|  8 | `b66d172` | P4   | Squid 6.13 + Dante dynamic-mode templates (additive, parse-verified) + spec reconcile |
|  7 | `fbfe9ed` | P1   | docs(spec): mark §20 gaps G1-G4 RESOLVED with spike decisions; bump to Revision 2 |
|  6 | `e19e0ed` | P2   | store (pgx) + redis (go-redis) clients — fail-closed, TDD, real PG/Redis |
|  5 | `6409cb9` | P1   | docs(research): resolve spec §20 gaps G1-G4 with captured-evidence spikes |
|  4 | `6802798` | P1/E | docs(audit): §11.4.138 forensic bluff-audit of 4 existing test scripts (8 bluffs) |
|  3 | `9ac1b4a` | P0   | docs(dynamic-routing): DYNAMIC_ROUTING.md + 2 mermaid diagrams |
|  2 | `6251007` | P0   | chore(submodules): incorporate containers, helix_qa, challenges, docs_chain (SSH, no-force) |
|  1 | `5f917a7` | P0   | P0 scaffold — data model, evidence harness, Go skeleton, governance carriers |

## 3. PROVEN-NOW vs OWED-TO-P10 (honest §11.4.6)

### PROVEN-NOW (control-plane / config-plane / spike facts — captured)
- **Spec §20 gaps G1–G4 resolved** with transient-spike captured evidence
  (`docs/research/mvp/findings/F_spikes_G1-G4.md`, run-id
  `qa-results/spikes/20260630_205029_g1g4/`): G2 `ubuntu/squid:latest` = Squid
  **6.13** (not v8), §8 directive set `squid -k parse` exit 0; G4 gluetun **v3.40
  (=v3.40.4)** control-API `:8000` answers 200, issue #3060 confirmed; G1 kernel-WG
  interface **creatable rootless** with `--cap-add NET_ADMIN`; G3 Dante **SIGHUP
  preserves an active SOCKS session** (20/20 chunks, curl exit 0, `/proc/net/tcp`
  ESTABLISHED proof).
- **P2 stores** (pgx + go-redis) — fail-closed, TDD, exercised against **real PG /
  Redis**.
- **P3 vpn-health-publisher** (`cmd/healthd` + `internal/vpn`) — data-plane health
  poll → Redis state, fail-closed, TDD.
- **P4 config-compiler + templates** — Squid 6.13 (`%>ha{Host}`) + Dante
  (concatenation, no `include`) render from PG; **`squid -k parse` exit 0**; PAC +
  route-key seeding parse-verified.
- **P5a acl-helper** — Squid `external_acl` OK/ERR from Redis, **fail-closed**,
  stdlib-only.
- **P7.2 observability** config plan — **promtool-validated** Prometheus scrape +
  Grafana dashboard.
- **P7.1 DNS / P7.3 security** — config plans only (DoH/DoT per-tunnel; per-user
  auth + Podman-secret loader + in-netns kill-switch). Design + parse layer.
- **Existing-test bluff audit** (Stream E) — 8 bluffs across 4 scripts catalogued
  (§11.4.138), guards owed to P8.

### OWED-TO-P10 (the LIVE dynamic-stack data-plane proof — NOT yet captured)
The `dynamic` compose profile (postgres + redis + control-plane + gluetun(s) +
squid+helper + dante) has **never been booted**; `docs/DYNAMIC_ROUTING.md` is
explicitly DESIGN-only. The following remain **unproven live** and are the
usability proof:
- `vpn_real_egress` — egress IP via proxy `== tunnel exit && != host IP` **+ `wg
  transfer` Δ** (200 OK is not routing).
- `graceful_503` — tunnel down → branded 503 with **Squid PID unchanged** → up →
  200, live.
- `no_leak / killswitch` — drop tunnel → **zero** target packets on the real
  uplink (`tcpdump`) + DNS only via the intended resolver.
- per-user **407 auth challenge** live; **secret injection leak-free** at runtime.
- **G1 residual** — full rootless kernel-WG *operation* (handshake + routing +
  throughput), only interface *creation* was spiked (§20 G1).
- **G3 residual / P9** — concurrent / repeated SIGHUP + **route-change-mid-session**
  SOCKS path behaviour (§20 G3).
- circuit-breaker open → failover to next up tier (P5b not yet landed).

## 4. Remaining phases

| Phase | Scope | State |
|---|---|---|
| **P5b** | per-target circuit breaker + tunnel tier-failover (`sony/gobreaker/v2`) | next, in flight |
| **P6**  | control-API + admin UI (templ+htmx+SSE, OpenDesign §11.4.162, host-rendered pixel proof §11.4.170) | pending |
| **P8**  | fix the existing-test bluffs (Stream E — the 8 audited bluffs → real probes / honest SKIP + §11.4.135 guards) | pending |
| **P9**  | full test matrix + Challenges + HelixQA (all §11.4.169 types; G3 route-change-mid-session live test) | in flight |
| **P10** | **live `dynamic`-mode boot + captured data-plane evidence = the usability proof** | **critical unblocker** |
| **P11** | docs sync + HTML/PDF (+DOCX where mandated) exports (this CONTINUATION + .remember are part of it) | in flight |
| **P12** | whole-branch review + full retest + merge to `main` + prefixed release tag | last |

## 5. Binding constraints (non-negotiable)

- **Anti-bluff §11.4** — every PASS carries positive captured **data-plane**
  evidence; control-plane/config-parse green is necessary, never sufficient; the
  end-user-usability bar is met only at P10.
- **No force-push §11.4.113** — merge onto latest `main`, fast-forward only;
  force-push is forbidden with no exception.
- **Rootless Podman §11.4.161** — all containers rootless; no Docker-rootful, no
  sudo, no root escalation; orchestrate via the containers submodule (§11.4.76),
  build on the remote host (§11.4.173).
- **Secrets-as-names-only §11.4.10** — VPN creds / proxy-auth / mTLS keys via
  Podman secrets / file refs; **never** plaintext in git; `.env.example` documents
  refs only.
- **Operator-safe §11.4.174** — do **NOT** touch the operator's pre-existing
  resources: the host `wg0-mullvad` (UP kernel-WG) interface and any `lava-*`
  containers (e.g. `lava-postgres-thinker`) are off-limits; verify process/resource
  ownership before acting; block-don't-break on shared-host contention.
- **Host safety §12** — ≤60% memory (§12.6); no host power-state commands
  (CONST-033); pull images sequentially; `--rm` diagnostics; `df` first.

## 6. Resume now (next actionable)

1. `git fetch --all --prune` on `feature/vpn-aware-dynamic-routing`; confirm HEAD
   `1833c8f` (or integrate any newer foreign commit per §11.4.71, no force).
2. In flight in parallel (§11.4.103): **P5b** breaker/failover, **P9** test
   matrix, **P11** docs export. None of these is the usability proof.
3. **Unblock P10** as the priority — it is the only phase that converts the
   landed control-plane into captured end-user-usable evidence; until it lands,
   no "works for users" claim may be made (§11.4 / §11.4.108).
4. Every change: TDD reproduce-first (§11.4.43/§11.4.115), all warranted test
   types (§11.4.169), paired §1.1 mutation, independent review → iterate-to-GO
   (§11.4.142/§11.4.125/§11.4.134), docs in sync (§11.4.60/§11.4.65/§11.4.106).
