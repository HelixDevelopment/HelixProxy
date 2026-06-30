# CONTINUATION — Helix Proxy: VPN-Aware Dynamic Routing Extension

**Revision:** 3
**Last modified:** 2026-07-01T02:43:32Z
**Status:** Active — control-plane + config-plane + control-API (P6) landed and unit/integration/parse-proven; the existing forward-proxy/SOCKS5/cache features are now PROVEN-WORKING-LIVE after BUGFIX-0002 (squid no longer crash-loops under rootless Podman); the LIVE *dynamic-VPN* data-plane proof is still owed to P10.
**Branch:** `feature/vpn-aware-dynamic-routing`
**Spec:** `docs/superpowers/specs/2026-06-30-vpn-aware-proxy-extension-design.md` (Rev 4)
**Plan:** `docs/superpowers/plans/2026-06-30-vpn-aware-proxy-extension-plan.md` (Rev 1)
**Authority:** Inherits the Helix Constitution submodule (`constitution/Constitution.md`) per §11.4.35.

> §12.10 live-state resume file. Read this first, then `git fetch --all --prune`
> and re-read `git log --oneline main..HEAD`. Any agent must be able to resume
> exactly where the last session left off from this single file.

---

## 1. Current PHASE

**Construction phase — landed: P0–P7 (control-plane + config-plane + control-API).**
28 commits on `feature/vpn-aware-dynamic-routing` ahead of `main`. The Go
control-plane (stores, health-publisher, acl-helper, config-compiler, P5b
breaker/failover, P6 control-API/SSE/metrics/PAC/mTLS) builds clean (4 binaries:
`acl-helper`, `api`, `compiler`, `healthd`; `go build`/`go vet`/`gofmt -l` all
clean) and is proven at the unit / integration / config-parse layer. The
`dynamic` compose profile + Containerfiles + orchestrator wiring are authored
(P10-prep) but **never booted** — the live dynamic-VPN data-plane proof is the
entire job of **P10**.

**MAJOR live finding this session (BUGFIX-0002):** the existing proxy genuinely
did NOT serve under rootless Podman — squid crash-looped because the host-created
`./logs` bind-mount was mode 0755 and the container's remapped non-root `proxy`
user could not write `access.log` (FATAL). Fixed (`chmod 777` the log dir,
mirroring the existing cache-dir remedy). After the fix the **3 existing
features are PROVEN-WORKING-LIVE**: HTTP forward proxy (200 + `Via: proxy-squid`),
Dante SOCKS5 (200), squid caching (`TCP_MEM_HIT`, no origin contact). This
directly answers the operator's "most features don't work / can't be used"
concern at the existing-proxy layer.

**BUGFIX-0003:** `run-tests.sh`'s `test_result` leaked a non-zero status on a
no-message FAIL, aborting the suite after ~10 of 41 tests under `set -e`. Fixed
(`return 0`); the suite now runs to completion and honestly reports 7
pre-existing FAILs (the §11.4.1 false-FAILs P8 is fixing now).

**P8 anti-bluff existing-test sweep — COMMITTED** as four bugfix lanes:
BUGFIX-0004 (`cd11494`, `run-tests.sh` §11.4.3 topology-aware ports + 3-state
SKIP + §11.4.161 podman), BUGFIX-0005 (`4394643`, `final-verify.sh` +
`verify-proxy.sh` false-VPN-routing §15 + `set -e` abort), BUGFIX-0006
(`2bc03de`, `comprehensive-test.sh` revived from a 100%-dead `(( ))` abort + real
data-plane evidence for B2/B3/B8 + B1 honest VPN SKIP). **P6 follow-ups —
COMMITTED** (`8d95f8a`, WARNING-3 real bidirectional metric-name drift guard,
independently §1.1-mutation-proven; WARNING-4 concurrency consistency test +
documented cross-step audit gap → #52; WARNING-5 plaintext-metrics-listener
design note → #53).

**MAJOR finding from the BUGFIX-0006 revival (#50, in flight):** reviving the
dead `comprehensive-test.sh` immediately surfaced a **real regressed feature** —
the documented 368-line `cache` management CLI (`./cache stats|clear|invalidate|
trim`, README/USER_GUIDE/CACHE/TROUBLESHOOTING) is **gone from HEAD**. §11.4.124
git-history investigation (FACT): commit `6ec58ef` accidentally deleted it — the
tracked `cache` FILE collided with the runtime `cache/` DATA dir at the same path
(`CACHE_DIR=$PROJECT_ROOT/cache`, `.gitignore:16` `cache/`). A background subagent
is restoring it as non-colliding `./cachectl` (§11.4.101 safe/reversible),
live-testing it on the running proxy, adding a §11.4.135 guard + §11.4.18
companion, doc-syncing the 4 docs, and flipping the 4 `comprehensive-test.sh`
cache-CLI SKIPs → real PASS — conductor reviews + commits on return (§11.4.142).

**Remaining:** **#50** (cachectl restore, in flight) → **P10** (live dynamic
boot — the usability proof; fail-closed half is data-plane-only + autonomous via
a self-generated throwaway `helixproxy_pg_password` secret, real-VPN-egress half
operator-gated on gluetun WireGuard creds) → **P12** (whole-branch review + full
retest + merge no-force + prefixed tag). Follow-ups: #52 (store-tx audit
atomicity), #53 (plaintext metrics listener, operator-gated).

## 2. The 28 landed commits (`git log --oneline main..HEAD`, newest first; this-session wave = newest 11)

| # | Commit | Phase | Summary |
|---|---|---|---|
| 28 | `8d95f8a` | P6   | real bidirectional metric-name drift guard (§1.1-mutation-proven) + concurrency consistency test; WARNING-3/4/5 |
| 27 | `2bc03de` | BUGFIX-0006 | revive + de-bluff `comprehensive-test.sh` (`(( ))` abort = 100% dead) + real B2/B3/B8 evidence; surfaced regression #50 |
| 26 | `4394643` | BUGFIX-0005 | `final-verify.sh` + `verify-proxy.sh` no longer green a NO-VPN config (false-VPN-routing §15) + `set -e` abort |
| 25 | `cd11494` | BUGFIX-0004 | `run-tests.sh` no longer FAILs a healthy proxy — §11.4.3 topology-aware ports + 3-state SKIP |
| 24 | `6a8f886` | P11  | refresh CONTINUATION to live state (Rev 2) — 23 commits, P5b/P6/BUGFIX-0002/0003 landed, P8 in flight |
| 23 | `61b4215` | chore | gofmt-format 6 pre-existing files (formatters-clean mandate; semantics-null verified) |
| 22 | `62b22fe` | P6   | control-API server (REST/SSE/metrics/PAC, fail-closed mTLS) + coherent operator-wiring contract |
| 21 | `1045dfd` | BUGFIX-0003 | `test_result` must `return 0` — suite no longer aborts mid-run under `set -e` |
| 20 | `c6f2935` | P9   | §11.4.18 operator-guide companions for the 16 `tests/dynamic` scripts |
| 19 | `b5573a9` | BUGFIX-0002 | squid log-dir writable under rootless Podman (proxy crash-loop) — existing features now serve live |
| 18 | `0aca034` | P9   | anti-bluff dynamic-routing test/analyzer harness (`tests/dynamic`) |
| 17 | `e6e93ec` | P10-prep | `dynamic` compose profile + control-plane/squid Containerfiles + orchestrator wiring |
| 16 | `6bdeef9` | P5b  | circuit-breaker + tier-failover (`internal/breaker`, gobreaker/v2) |
| 15 | `7d0d128` | P11  | CONTINUATION (§12.10) + spec §9 reconcile + §11.4.65 HTML/PDF export backfill |
| 14 | `1833c8f` | P7.3 | per-user Squid auth + rootless Podman-secret loader + kill-switch design (no secrets) |
| 13 | `603e039` | P5a  | acl-helper — Squid external_acl OK/ERR from Redis, fail-closed (stdlib) |
| 12 | `e6e336f` | P7.1 | per-tunnel DoH/DoT (dnsproxy) config plan + DNS-leak test design |
| 11 | `04526dd` | P4   | config-compiler — render Squid/Dante/PAC from PG + seed route keys (parse-verified) |
| 10 | `833fb9e` | P7.2 | Prometheus scrape + Grafana dashboard config plan (promtool-validated) |
|  9 | `11106a4` | P3   | vpn-health-publisher (cmd/healthd + internal/vpn) — data-plane health, fail-closed, TDD |
|  8 | `b66d172` | P4   | Squid 6.13 + Dante dynamic-mode templates (additive, parse-verified) + spec reconcile |
|  7 | `fbfe9ed` | P1   | docs(spec): mark §20 gaps G1-G4 RESOLVED with spike decisions |
|  6 | `e19e0ed` | P2   | store (pgx) + redis (go-redis) clients — fail-closed, TDD, real PG/Redis |
|  5 | `6409cb9` | P1   | docs(research): resolve spec §20 gaps G1-G4 with captured-evidence spikes |
|  4 | `6802798` | P1/E | docs(audit): §11.4.138 forensic bluff-audit of 4 existing test scripts (8 bluffs) |
|  3 | `9ac1b4a` | P0   | docs(dynamic-routing): DYNAMIC_ROUTING.md + 2 mermaid diagrams |
|  2 | `6251007` | P0   | chore(submodules): incorporate containers, helix_qa, challenges, docs_chain (SSH, no-force) |
|  1 | `5f917a7` | P0   | P0 scaffold — data model, evidence harness, Go skeleton, governance carriers |

## 3. PROVEN-NOW vs OWED-TO-P10 (honest §11.4.6)

### PROVEN-NOW (control-plane / config-plane / spike facts — captured)
- **Existing proxy serves LIVE (BUGFIX-0002)** — after the rootless-Podman
  log-dir fix, the booted `--no-vpn` stack proves all 3 existing features:
  HTTP forward proxy `200` + `Via: 1.1 proxy-squid`, Dante SOCKS5 `200`, squid
  cache `TCP_MEM_HIT` (no origin contact). Guard:
  `tests/regression/log_dir_writable_test.sh` (§11.4.115 polarity, §1.1 mutation
  byte-identical md5 `0128a96b6d467c2da5b7cef8a808e563`). Evidence:
  `qa-results/regression/bugfix38/`.
- **P5b breaker/failover** (`internal/breaker`, gobreaker/v2) — per-target
  circuit breaker + tunnel tier-failover, TDD.
- **P6 control-API** (`cmd/api` + `internal/api` + `internal/pac`) — REST CRUD +
  SSE + Prometheus `/metrics` + PAC, **fail-closed mTLS**
  (`RequireAndVerifyClientCert`), coherent operator-wiring contract
  (`CONTROL_API_TLS_CERT/_KEY/_TLS_CLIENT_CA`, `:58080`); builds + vets clean,
  §1.1 mutation md5 `67125c7a1ab9b00c98fb164f765b04af`.
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
| **P5b** | per-target circuit breaker + tunnel tier-failover (`sony/gobreaker/v2`) | ✅ landed `6bdeef9` |
| **P6**  | control-API + SSE + metrics + PAC + fail-closed mTLS | ✅ landed `62b22fe` (admin-UI templ/htmx + §11.4.170 host-rendered pixel proof = P6.2, deferred) |
| **P8**  | fix existing-test bluffs → §11.4.3 topology dispatch / honest SKIP / §11.4.161 + §11.4.135 guards | **in flight** (2 subagents: `run-tests.sh` + `comprehensive-test.sh`) |
| **P9**  | full test matrix + Challenges + HelixQA (all §11.4.169 types; G3 route-change-mid-session live test) | harness landed `0aca034`; live execution coupled to P10 |
| **P10** | **live `dynamic`-mode boot + captured data-plane evidence = the usability proof** | **critical unblocker**; fail-closed half doable now, real-egress half operator-gated (gluetun WG creds) |
| **P11** | docs sync + HTML/PDF (+DOCX where mandated) exports (this CONTINUATION + .remember are part of it) | ongoing |
| **P12** | whole-branch review (iterate-to-GO) + full retest + merge to `main` no-force + prefixed release tag | last |

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
   `8d95f8a` (28 ahead of `main`; or integrate any newer foreign commit per
   §11.4.71, no force).
2. **#50 cachectl restore (in flight, background subagent):** on its return,
   review independently (§11.4.142) — verify the live `./cachectl stats/size/list`
   data-plane evidence, the CONTAINER_RUNTIME wiring fix, the §11.4.135 guard
   RED/GREEN + §1.1 mutation (byte-identical restore md5), the doc-sync
   (`./cache`→`./cachectl` in README/USER_GUIDE/CACHE/TROUBLESHOOTING + exports,
   zero raw-markup leak §11.4.168), and the 4 flipped `comprehensive-test.sh`
   cache-CLI checks now PASS — then commit explicit-path (§11.4.84), no-force.
3. **P10 fail-closed half (doable now, NO operator dependency):** boot the
   `dynamic` stack (data-plane only: redis+postgres+gluetun+compiler+healthd+
   squid-dynamic; a **self-generated throwaway** `helixproxy_pg_password` Podman
   secret — internal test-DB password, not an operator credential) with the
   tunnel forced down (empty `WIREGUARD_*` + `FIREWALL=on`) → assert branded 503
   with squid PID unchanged + zero target packets on the real uplink (`tcpdump`
   no-leak). NB: booting reclaims `:53128` from the running proxy — single-owner
   the data plane (§11.4.119), so run AFTER #50's live cache testing frees it.
   The **real-VPN-egress half** (egress IP == tunnel exit != host + `wg transfer`
   Δ) is **operator-gated on gluetun WireGuard credentials** — surface via
   §11.4.66 ONLY at that boundary (don't block the loop; §11.4.21/§11.4.101). The
   `api-service` control-plane entry is NOT required for the data-plane
   fail-closed proof; only for the full control surface (resolve at execution).
4. **P12 (last):** whole-branch review iterate-to-GO + full retest (§11.4.40) +
   merge onto latest `main` fast-forward-only (§11.4.113) + project-prefixed
   release tag (§11.4.151).
5. Tracked follow-ups: **#52** (store-tx spanning mutation+audit — the WARNING-4
   cross-step un-audited-mutation window), **#53** (separate plaintext `/metrics`
   listener vs the mTLS port — WARNING-5, operator-gated at P10 topology). P6.2
   admin-UI + §11.4.170 host-rendered pixel proof deferred.
6. Every change: TDD reproduce-first (§11.4.43/§11.4.115), all warranted test
   types (§11.4.169), paired §1.1 mutation, independent review → iterate-to-GO
   (§11.4.142/§11.4.125/§11.4.134), docs in sync (§11.4.60/§11.4.65/§11.4.106),
   operator resources untouched (§11.4.174: `wg0-mullvad`, `lava-*`).
