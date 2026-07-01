# helix_proxy — Feature Status

**Revision:** 1
**Last modified:** 2026-07-01T12:30:00Z
**Status:** Data plane (Squid HTTP/HTTPS forward + Dante SOCKS5 + Squid caching) is deployed, end-user-reachable, and PASS with captured evidence. The VPN-aware control-plane (dynamic routing / control API / health publisher / breaker / ACL-helper / PAC / metrics) is a separate Go module — component-tested (unit/integration GREEN + §1.1 mutations) but NOT yet wired into the running data plane, therefore PENDING at the end-user layer. Let's Encrypt HTTPS is Phase-1 (cert-analyzer) PASS; issuance/renewal PENDING; staging/production cutover OPERATOR-BLOCKED.
**Authority:** Inherits `constitution/Constitution.md` per §11.4.35. This is the §11.4.153 per-feature Status set (companion §11.4.56 two-audience [`Status_Summary.md`](Status_Summary.md)). Every row is reconciled against real code + committed tests/challenges/evidence; no metadata-only PASS (§11.4 / §11.4.1 / §11.4.6).
**Repo anchor:** branch `feature/vpn-aware-dynamic-routing`, HEAD `bf38c35` at authoring time.

---

## Operator-blocked / operator-gated items (read first — §11.4.45 O(1) surface)

| Item | Why blocked | Unblock condition |
|---|---|---|
| Real VPN egress proof (egress-IP ≠ host-IP through the proxy) | No live tunnel bound at test time; `proxy-vpn` container observed **Stopped**; `VPN_EXIT_IP` unset. The verify scripts SKIP honestly (`operator_attended`) rather than fabricate a VPN PASS (`tests/verify-proxy.sh:87-98`). | Operator brings up a real tunnel and exports `VPN_EXIT_IP=<tunnel exit>`; then `tests/egress_proof/real_vpn_egress_proof.sh` produces the live RED→GREEN proof. |
| Let's Encrypt Phase 4 — LE **staging** end-to-end (real DNS-01) | Needs a real DNS provider + a scoped API token stored as a Podman secret (§11.4.10 — value never in git/`.env`). Operator chose *defer real domain* (design §9 Phase 0). | Operator provides the DNS provider name + a scoped API token + a test hostname. |
| Let's Encrypt Phase 6 — **production** cutover | Real public domain + real DNS-01 for that domain + a single operator-gated go-live (design §9). | Operator authorises go-live with the real domain + token + host firewall opening. |

---

## Feature status table (§11.4.153)

**Legend.** Wiring = *is the feature genuinely reachable by an end user of the DEPLOYED stack (`docker-compose.yml`)?* Validation ∈ {PASS, FAIL, SKIP, PENDING, OPERATOR-BLOCKED}. PASS requires a committed captured-evidence path (§11.4.69). PENDING = code/tests exist but the feature is not yet end-user-reachable in the deployed stack (no metadata-only PASS). Video-confirmation is **N/A** for every row: helix_proxy is a headless network service with no rendered UI — its §11.4.107/§11.4.69 proof is captured curl status codes + Squid `Via:` headers + `access.log` `TCP_*HIT` facts, not a video (§11.4.153(3) autonomous-infeasible ⇒ honest non-video evidence).

### A. Data-plane proxy features — DEPLOYED & end-user-reachable

| Component | Feature | Category | Implementation (file:line) | Wiring (end-user-reachable?) | Real-use | Tests-coverage | Validation | Evidence-path |
|---|---|---|---|---|---|---|---|---|
| Squid `:53128` | HTTP forward proxy (plain-HTTP GET relayed to upstream) | functional / data-plane | `config/squid/squid.conf:53` (`http_access allow localnet`); `docker-compose.yml:56` (`proxy-squid`) | YES — `curl -x http://localhost:53128` forwards live | Real `curl` 204 relayed with `Via: 1.1 proxy-squid (squid/6.13)` header | Challenge + verify + comprehensive + HelixQA bank case PRX-HTTP-001 | **PASS** | `qa-results/challenges/20260701T085518Z/evidence/http/forward_http_evidence.txt` (proxy=204, `Via: proxy-squid`) |
| Squid `:53128` | HTTPS CONNECT tunneling (`CONNECT` to TLS upstream) | functional / data-plane | `config/squid/squid.conf:46,50` (`acl CONNECT` / `deny CONNECT !SSL_ports`); `docker-compose.yml:56` | YES — `curl -x http://localhost:53128 https://…` | Real TLS GET → `HTTP/1.1 200 Connection established` then upstream 200 | forward challenge sub-probe `https_200`; HelixQA PRX-HTTPS-001 | **PASS** | `qa-results/challenges/20260701T085518Z/evidence/http/forward_http_evidence.txt` (https_200 CONNECT established) |
| Dante `:51080` | SOCKS5 proxy (HTTP over SOCKS5) | functional / data-plane | `config/dante/sockd.conf`; `docker-compose.yml:127` (`proxy-dante`) | YES — `curl --proxy socks5://localhost:51080` | Real `curl` 204 relayed via Dante SOCKS5 | socks5 challenge sub-probe `socks_204`; HelixQA PRX-SOCKS5-001 | **PASS** | `qa-results/challenges/20260701T085518Z/evidence/socks5/socks5_evidence.txt` (socks=204) |
| Dante `:51080` | SOCKS5-over-HTTPS (TLS carried over SOCKS5) | functional / data-plane | `config/dante/sockd.conf`; `docker-compose.yml:127` | YES — `curl --proxy socks5://… https://…` | Real HTTPS GET → HTTP/2 200 through Dante | socks5 challenge sub-probe `socks_https`; HelixQA PRX-SOCKS5-002 | **PASS** | `qa-results/challenges/20260701T085518Z/evidence/socks5/socks5_evidence.txt` (socks_https=200) |
| Squid `:53128` | Response caching (cache-HIT of cacheable object) | performance / data-plane | `config/squid/squid.conf:9` (`cache_dir aufs … 51200`), `:10` (`cache_mem 512 MB`), `:70-73` (`refresh_pattern`) | YES — repeat GET served from cache | Two GETs of the same object → Squid `TCP_MEM_HIT/200` in `access.log` (decisive sink-side proof) | comprehensive `assert_cache_hit`; HelixQA PRX-CACHE-001/002; challenge (client-side supplementary) | **PASS** | `qa-results/comprehensive/cache_hit.evidence` (`TCP_MEM_HIT/200`) + `qa-results/comprehensive/squid_access_snapshot.log` |
| Squid `:53128` | Cache admin/inspection (`cachectl stats/list/size`) | operational | `cachectl` (repo root) | YES — operator CLI against live cache | Real `cachectl stats` prints substantive cache figures | comprehensive cache-command probes; regression `cache_cli_present_test.sh` | **PASS** | `qa-results/comprehensive/cache_cmd_stats.out`, `cache_cmd_list.out`, `cache_cmd_size.out` |
| Squid `:53128` | ACL access control (allow `localnet`, deny-all default, `Safe_ports`, `CONNECT`→SSL-ports-only, `manager` deny) — **allow-path** | security / data-plane | `config/squid/squid.conf:49-55` | YES — enforced by running Squid on every request | Allow-path proven: localnet requests forward; deny-all is the default tail | Enforced by the live proxy (allow-path is exercised by every forward challenge); `auth_407` analyzer self-validated at fixture level | **PASS** (allow-path only; see A-note) | Allow-path: `qa-results/challenges/20260701T085518Z/evidence/http/forward_http_evidence.txt`; deny-path proof PENDING (§B) |

**A-note (anti-bluff, §11.4.6):** the ACL *allow* path is proven — every forward/SOCKS5 challenge succeeds only because `http_access allow localnet` admits it. The ACL *deny* paths (`deny all`, `deny !Safe_ports`, `deny CONNECT !SSL_ports`, `deny manager`) are present + enforced by the running Squid but have **no dedicated committed deny-assertion capture** yet, so a full deny-path PASS is deferred to §B (PENDING). Proxy *authentication* (username/password `407`) is NOT in the deployed `squid.conf` — see §B.

### B. Control-plane & auth features — code/tests exist, NOT yet wired into the deployed data plane (PENDING)

The control-plane is a separate Go module (`control-plane/`, `module digital.vasic.helixproxy/controlplane`) that sits *beside* the byte path. Its packages are phased (P3–P6 landed with unit/integration GREEN + §1.1 mutations), but the deployed admin surface is still the `traefik/whoami` placeholder (`docker-compose.yml:199-201`), so none of these are end-user-reachable in the running stack yet. Per §11.4 / §11.4.1 they are **PENDING**, never PASS.

| Component | Feature | Category | Implementation (file:line) | Wiring (end-user-reachable?) | Real-use | Tests-coverage | Validation | Evidence-path |
|---|---|---|---|---|---|---|---|---|
| control-plane `internal/routing` | VPN-aware dynamic routing (render Squid include + Dante routes + PAC) | data-plane routing | `control-plane/internal/routing/routing.go` (+ `testdata/*.golden`) | NO — dynamic stack (`docker-compose.dynamic.yml`) not deployed | — (golden-config render only; no live route yet) | unit + integration GREEN vs golden configs | **PENDING** | `control-plane/qa-results/p4-compiler/*` (unit_routing / integration_routing) |
| control-plane `cmd/api` + `internal/api` | Control API (REST CRUD / SSE status / PAC endpoint / `/metrics` / mTLS) | control API | `control-plane/internal/api/server.go`, `handlers.go`, `metrics.go`, `tls.go`; `cmd/api/main.go` | NO — admin `:58080` is `traefik/whoami` placeholder | — | unit (`-race`) + real-Postgres integration + §1.1 mutation (mTLS) | **PENDING** | `control-plane/qa-results/p6-api/*` (01_unit_short_race, 04_mutation_RED, 08_integration_realpg) |
| control-plane `cmd/healthd` + `internal/vpn` | VPN health publisher / health endpoints (tunnel-up = tx-Δ>0 ∧ fresh handshake ∧ egress≠host) | health / observability | `control-plane/internal/vpn/health.go`, `gluetun.go`, `wg.go`; `cmd/healthd/main.go` | NO — not wired into deployed stack | — (proven against a real gluetun in integration, not in prod) | unit GREEN + real-gluetun integration + chaos + §1.1 mutation | **PENDING** | `control-plane/qa-results/p3-healthd/EVIDENCE.md` + `20260630_211405/*` |
| control-plane `internal/breaker` | Per-target circuit breaker + tunnel tier-failover | resilience | `control-plane/internal/breaker/breaker.go`, `selection.go`, `tunnelbreaker.go` | NO | — | unit GREEN | **PENDING** | `control-plane/qa-results/p5b-breaker/*` |
| control-plane `cmd/acl-helper` + `internal/aclhelper` | External ACL helper (`OK tag=<tunnel>` / `ERR` graceful-503, fail-closed) | data-plane ACL | `control-plane/internal/aclhelper/decide.go`, `protocol.go`; `cmd/acl-helper/main.go` | NO — Squid `external_acl_type` not wired in deployed `squid.conf` | — | unit + integration GREEN | **PENDING** | `control-plane/qa-results/p5-aclhelper/*` |
| control-plane `internal/pac` | PAC generation (`FindProxyForURL`) | data-plane routing | `control-plane/internal/pac/generate.go`, `pac.go` (+ `testdata/pac.golden`) | NO | — | unit GREEN vs golden | **PENDING** | `control-plane/qa-results/p4-compiler/*` |
| Squid `:53128` | Proxy authentication (username/password `407`) + ACL deny-path assertion | security | (design) `tests/dynamic/analyzers/auth_407_analyzer.sh`; not in deployed `config/squid/squid.conf` | NO — no `auth_param` in deployed config | — | `auth_407` analyzer self-validated (golden-good PASS / golden-bad FAIL) at fixture level only | **PENDING** | `qa-results/p9-harness/CONSOLIDATED_20260630T221343Z/CONSOLIDATED_EVIDENCE.txt` (analyzer self-validation) |
| Prometheus / Grafana / OTel | Observability & metrics (scrape topology, dashboards, in-process OTel) | observability | `config/prometheus/prometheus.yml`, `config/grafana/`, `control-plane/internal/otel/otel.go`, `internal/api/metrics.go` | NO — `prometheus.yml` is explicitly a *NOT-YET-LIVE PLAN*; scrape targets do not exist | — | config authored; control `/metrics` unit-tested (not deployed) | **PENDING** | `config/prometheus/prometheus.yml:2-10` (NOT-YET-LIVE PLAN banner); `control-plane/qa-results/p6-api/*` (metrics unit) |

### C. Operational / health surface — DEPLOYED

| Component | Feature | Category | Implementation (file:line) | Wiring | Real-use | Tests-coverage | Validation | Evidence-path |
|---|---|---|---|---|---|---|---|---|
| `./status` | Operational status/health command (Container/Port/Connection state) | health / operational | `status` (repo root) | YES — operator CLI + `--json` | Real `./status` prints Container/Port/Connection fields; `--json` emits structured health | comprehensive status probes | **PASS** | `qa-results/comprehensive/status.out`, `status_json.out`, `probe_status_json.txt` |
| `proxy-admin` `:58080` | Admin container reachability `/health` (200) | health | `docker-compose.yml:199-201` (`traefik/whoami`) | YES (reachable) — but is the `whoami` **placeholder**, not the real admin UI | HTTP 200 from `:58080/health` | comprehensive "Admin health endpoint" | **PASS** (placeholder-qualified — real admin UI is §B PENDING) | `qa-results/comprehensive/after_run.log:92` (`✓ PASS: Admin health endpoint`) |
| Containers | Compose service healthchecks (Squid/Dante/admin liveness) | health | `docker-compose.yml` (`healthcheck:` blocks) | YES — runtime restart/liveness | `./status` reflects Running/Stopped per container | comprehensive container-status tests | **PASS** | `qa-results/comprehensive/status.out` (per-container Running/Stopped) |

### D. Let's Encrypt HTTPS workstream (task #59)

Detailed integration status: [`../design/letsencrypt/Status.md`](../design/letsencrypt/Status.md).

| Component | Feature | Category | Implementation (file:line) | Wiring | Real-use | Tests-coverage | Validation | Evidence-path |
|---|---|---|---|---|---|---|---|---|
| cert-analyzer | Offline PEM analyzer (`cert_not_expired` / `cert_days_remaining` / `cert_san_matches` / `cert_chain_roots_in` / `cert_renewal_due`) + golden-good/golden-bad self-validation (§11.4.107(10)) | security / TLS | `tests/letsencrypt/cert_analyzer.sh` (+ `cert_analyzer_selftest.sh`, `fixtures/`) | YES (offline tool — analyzes a resulting cert regardless of how obtained) | Selftest 37/37; guard GREEN+RED; §1.1 SAN-mutation → FAIL, restore byte-identical | unit selftest + regression self-validation guard + §1.1 mutation | **PASS** | `qa-results/regression/cert_analyzer_selfvalidation/*` (`verdict: PASS`, RED reproduced); `qa-results/letsencrypt/cert-analyzer/*` |
| Caddy (custom image) | Auto-HTTPS terminator + DNS-01 ACME client (chosen client) | TLS | `config/caddy/Caddyfile` | NO — image/service not built/wired yet | — | design decisions captured (Phase 0) | **PENDING** | `docs/design/letsencrypt/Status.md` (Phase 1/2/3 rows) |
| Caddy + Pebble | Hermetic local-ACME issuance (Phase 3) + renewal/rotation (Phase 5) | TLS | (design) `docs/design/LETSENCRYPT_HTTPS.md` §Pebble | NO | — | authored plan; analyzer ready to assert the result | **PENDING** | `docs/design/letsencrypt/Status.md` (Phase 3/5) |
| LE staging / production | Real DNS-01 issuance (Phase 4) + production cutover (Phase 6) | TLS | (design) `docs/design/LETSENCRYPT_HTTPS.md` §9 | NO | — | operator-gated | **OPERATOR-BLOCKED** | `docs/design/letsencrypt/Status.md` (Operator-blocked table) |

### E. VPN routing / egress

| Component | Feature | Category | Implementation (file:line) | Wiring | Real-use | Tests-coverage | Validation | Evidence-path |
|---|---|---|---|---|---|---|---|---|
| egress proof | Real VPN egress proof (egress-IP through proxy = tunnel exit ∧ ≠ host-IP) | data-plane / security | `tests/egress_proof/real_vpn_egress_proof.sh`; `evidence.sh assert_egress_ip`; `egress_neq_host` analyzer | NO — `proxy-vpn` observed Stopped; no live tunnel | — (SKIP `operator_attended` — the old host_ip==proxy_ip "VPN verified" bluff was removed) | `egress_neq_host_analyzer` self-validated (golden-good PASS / golden-bad `egress==host` FAIL) | **OPERATOR-BLOCKED** | analyzer self-validation: `qa-results/p9-harness/CONSOLIDATED_20260630T221343Z/CONSOLIDATED_EVIDENCE.txt`; live SKIP: `tests/verify-proxy.sh:87-98` |

---

## §11.4.169 test-type coverage matrix

Per-feature × test-type × evidence-state. Cells: **PASS** = live captured evidence committed; **UNIT** = unit/fixture-level GREEN (incl. golden-good/golden-bad self-validation) but not a live-stack run; **SKIP** = honest topology SKIP (dynamic/live stack absent — §11.4.3); **PENDING** = warranted but not yet produced; **N/A** = not applicable to this feature class. The DEPLOYED data-plane suites for stress/chaos/ddos/benchmark/memory/concurrency currently **SKIP** because they require the un-deployed `dynamic` stack (P10) — their analyzers are self-validated and their scripts are parse-clean, so the SKIP is honest, not a gap-hidden PASS.

| Feature | unit | integration | e2e / live | challenge | HelixQA | security | stress / chaos | benchmark | Overall |
|---|---|---|---|---|---|---|---|---|---|
| HTTP forward proxy | PASS (`proxy_conn_verdict_test.sh`) | PASS (comprehensive) | **PASS** (challenge live curl) | **PASS** (`proxy_forward_http_challenge.sh`) | SKIP (bank authored; `helixqa` binary unbuildable — 6 sibling modules absent) | UNIT (ACL analyzers) | SKIP (dynamic stack absent) | SKIP (dynamic stack absent) | **PASS** |
| HTTPS CONNECT tunneling | PASS | PASS | **PASS** (challenge) | **PASS** (`https_200` sub-probe) | SKIP (harness build) | UNIT | SKIP | SKIP | **PASS** |
| SOCKS5 proxy | PASS | PASS | **PASS** | **PASS** (`proxy_socks5_challenge.sh`) | SKIP (harness build) | UNIT | SKIP | SKIP | **PASS** |
| SOCKS5-over-HTTPS | PASS | PASS | **PASS** | **PASS** (`socks_https` sub-probe) | SKIP (harness build) | UNIT | SKIP | SKIP | **PASS** |
| Response caching (TCP_*HIT) | PASS (`xcache_hit_analyzer` self-val) | **PASS** (comprehensive `TCP_MEM_HIT`) | **PASS** (comprehensive live double-fetch) | SKIP (client-side access.log unreadable → topology SKIP); comprehensive PASS via container | SKIP (harness build) | N/A | SKIP | SKIP | **PASS** |
| Cache admin (`cachectl`) | PASS (`cache_cli_present_test.sh`) | **PASS** (comprehensive) | **PASS** (live `cachectl stats`) | N/A | N/A | N/A | N/A | N/A | **PASS** |
| Squid ACL (allow-path) | PASS (analyzer) | **PASS** (live forward) | **PASS** | via forward challenge | SKIP | UNIT (`auth_407` self-val) | SKIP | N/A | **PASS** (allow); deny-path PENDING |
| Proxy auth (407) / ACL deny-path | UNIT (`auth_407` self-val) | PENDING | PENDING | PENDING | SKIP | UNIT | N/A | N/A | **PENDING** |
| VPN-aware dynamic routing | **UNIT** (routing golden) | **UNIT** (integration golden) | SKIP (dynamic stack absent) | PENDING | SKIP | PENDING | SKIP | SKIP | **PENDING** |
| Control API (REST/SSE/PAC/mTLS) | **UNIT** (`-race`) | **UNIT** (real Postgres) | PENDING (admin=whoami) | PENDING | N/A | UNIT (mTLS §1.1) | PENDING | PENDING | **PENDING** |
| VPN health publisher / health | **UNIT** | **UNIT** (real gluetun + chaos) | PENDING | PENDING | N/A | UNIT | UNIT (chaos) | PENDING | **PENDING** |
| Circuit breaker + tier-failover | **UNIT** | PENDING | PENDING | PENDING | N/A | N/A | PENDING | PENDING | **PENDING** |
| ACL helper (graceful 503) | **UNIT** | **UNIT** | SKIP | PENDING | SKIP | UNIT (`graceful_503` self-val) | SKIP | N/A | **PENDING** |
| PAC generation | **UNIT** (golden) | UNIT | PENDING | N/A | N/A | N/A | N/A | N/A | **PENDING** |
| Observability / metrics | **UNIT** (control `/metrics`) | PENDING | PENDING (targets absent) | N/A | N/A | N/A | N/A | PENDING | **PENDING** |
| `./status` operational health | PASS | **PASS** (comprehensive) | **PASS** (live) | N/A | N/A | N/A | N/A | N/A | **PASS** |
| LE cert-analyzer (Phase 1) | **PASS** (selftest 37/37 + §1.1) | PASS (regression guard) | N/A (offline tool) | N/A | N/A | **PASS** (cert validity/SAN/chain) | N/A | N/A | **PASS** |
| LE issuance/renewal (Phase 2/3/5) | PENDING | PENDING | PENDING | PENDING | N/A | PENDING | N/A | N/A | **PENDING** |
| LE staging/production (Phase 4/6) | N/A | N/A | OPERATOR-BLOCKED | N/A | N/A | OPERATOR-BLOCKED | N/A | N/A | **OPERATOR-BLOCKED** |
| Real VPN egress proof | UNIT (`egress_neq_host` self-val) | SKIP | OPERATOR-BLOCKED (no live tunnel) | PENDING | N/A | UNIT | N/A | N/A | **OPERATOR-BLOCKED** |
| ddos / flood resilience | UNIT (`ddos_flood_evidence` guard) | SKIP (dynamic stack) | SKIP | N/A | N/A | UNIT | SKIP | N/A | **PENDING** (live SKIP; guard PASS) |
| benchmark / latency ratchet | UNIT (`benchmark_baseline_ratchet` guard) | SKIP | SKIP | N/A | N/A | N/A | N/A | SKIP (dynamic stack) | **PENDING** (live SKIP; guard PASS) |

### Honest gaps (§11.4.3 / §11.4.6)

1. **HelixQA live execution is SKIP, not PASS.** The `helixqa` binary cannot be built in this checkout — its `go.mod` `replace`s six own-org sibling modules (`doc_processor`, `llm_orchestrator`, `llm_provider`, `llms_verifier`, `vision_engine`, `security`) that are not vendored here. The runner emits an honest §11.4.3 SKIP naming the exact blocker (`qa-results/helixqa/20260701T090532Z/SKIP.md`). The proxy data plane was independently re-proven this run via a stdlib replica of the HelixQA HTTPExecutor client (`mech_http_forward.txt` 204, `mech_https_connect.txt` 200, `mech_socks5.txt` 204). Unblock: vendor the six modules under `submodules/`.
2. **Live stress/chaos/ddos/benchmark/memory/concurrency SKIP.** These six dynamic-suite runs require the un-deployed `dynamic` stack (P10); all six honest-SKIP (`qa-results/p9-harness/20260630T221343Z/suite_results.txt`: `suites=6 PASS=0 SKIP=6 FAIL=0`). Their analyzers are self-validated (golden-good PASS / golden-bad FAIL) and their scripts parse-clean; the RED regression guards (`ddos_flood_evidence`, `benchmark_baseline_ratchet`) PASS.
3. **ACL deny-path** has enforcement but no dedicated committed deny-assertion capture — represented PENDING, not folded into the allow-path PASS.
4. **Cache challenge client-side SKIP** (`topology_unsupported`) is honest — the Squid `access.log` is owned by a rootless-container subuid and unreadable client-side; the decisive `TCP_MEM_HIT` PASS comes from comprehensive-test's container-side snapshot instead.
5. **Video-confirmation N/A** for every row (§11.4.153(3)): helix_proxy is headless — proof is captured status codes + `Via:` headers + `access.log` `TCP_*HIT`, not rendered video.

---

## Honest boundary (§11.4.6)

Only the **deployed Squid + Dante data plane** (HTTP forward, HTTPS CONNECT, SOCKS5, SOCKS5-over-HTTPS, caching, cache admin, ACL allow-path, `./status`, admin reachability) and the **LE Phase-1 cert-analyzer** are PASS with committed captured evidence. Everything in §B (control-plane routing / API / health / breaker / ACL-helper / PAC / metrics, and proxy auth) is **component-tested but not wired into the running stack** — honestly PENDING, never a metadata-only PASS. The LE issuance/renewal path is PENDING; LE staging/production and the real VPN egress proof are OPERATOR-BLOCKED. Feature tally: **9 PASS-with-evidence, 10 PENDING, 3 OPERATOR-BLOCKED** (LE Phase 4, LE Phase 6, real VPN egress proof).
