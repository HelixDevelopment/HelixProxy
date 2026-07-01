# helix_proxy — Feature Status Summary

**Revision:** 3
**Last modified:** 2026-07-01T15:30:00Z
**Authority:** §11.4.56 two-audience companion to [`Status.md`](Status.md). Inherits `constitution/Constitution.md` per §11.4.35.

---

## Page 1 — For the product / operations team (plain language)

**What is this?** helix_proxy is a self-hosted proxy server. Apps and users point their web traffic at it; it forwards that traffic to the internet, can route it through a VPN, and remembers ("caches") repeated downloads so they come back faster.

**What works today, proven with real evidence:**

- **Web proxying works.** Plain web (HTTP) and secure (HTTPS) requests both go through the proxy and reach the internet. We proved it with real requests that came back stamped by our proxy (a `Via: proxy-squid` marker only our proxy adds).
- **SOCKS5 proxying works.** The second proxy type (SOCKS5, used by many apps) forwards both plain and secure traffic. Proven with real requests.
- **Caching works.** Ask for the same file twice and the second copy is served from the proxy's own memory — confirmed in the proxy's own access log as a real cache "HIT", not a guess.
- **Status/health command works.** The `./status` tool truthfully reports which parts are running, which ports are open, and whether connections succeed.
- **The certificate checker works.** The piece that will validate our future auto-HTTPS certificates already passes its full self-test (37/37) and is deliberately built so it cannot rubber-stamp a bad certificate.
- **Automatic-HTTPS certificate issuance works (in a self-contained test).** The system can now obtain a real HTTPS certificate automatically, end-to-end, using our own custom-built certificate server standing in for Let's Encrypt. We proved the issued certificate is genuine and correctly chained — and there is a live check plus a permanent guard test that re-runs to make sure it keeps working. (Issuing against a *real public* domain still needs your go-ahead — see below.)

**What's built but not switched on yet (in progress):**

- The **smart VPN-aware routing brain** (the "control-plane") — the part that decides which VPN tunnel each request should use, plus the admin dashboard, live health publisher, and metrics. The code exists and passes its component tests, but it is not yet plugged into the live proxy, so end users cannot use it yet. The admin page you see today is still a temporary placeholder.
- **Username/password protection** on the proxy and **live dashboards/metrics** — designed and partially tested, not switched on.
- **Automatic-HTTPS certificate *renewal*** — issuing a fresh certificate is proven; automatically *renewing* one before it expires is the next step. We already diagnosed exactly why our test certificate server won't renew yet (it needs a newer version) and know the fix.

**What needs a decision or action from you (operator):**

- To prove **VPN routing** end-to-end we need a real VPN tunnel up and the expected exit IP provided. Until then the test honestly skips rather than pretend.
- To turn on **Let's Encrypt for a real domain** we need you to choose a DNS provider, supply a scoped API token, and authorise go-live for the real domain.

**Bottom line:** the core proxy (forward HTTP, HTTPS, SOCKS5, caching) is working and evidence-backed, and automatic HTTPS certificate *issuance* is now proven in a self-contained test. The advanced VPN-routing/admin/metrics layer, HTTPS certificate *renewal*, and real-domain go-live are still being wired in. Nothing is claimed "done" without a real captured proof behind it.

---

## Page 2 — For software engineers

**Scope.** Reconciled against branch `feature/vpn-aware-dynamic-routing` @ `2f1e49d` (LE issuance `b2afa7d`, Challenge `022b78d`, guard `d2042ac`, renewal research `6349c0e`+`7c6b69f`+`2f1e49d`). Deployed stack = `docker-compose.yml` (Squid `:53128`, Dante `:51080`, `proxy-admin` = `traefik/whoami` placeholder `:58080`, `proxy-vpn` observed Stopped). Control-plane = separate Go module `digital.vasic.helixproxy/controlplane`, not yet in the byte path. LE hermetic issuance stack = `deploy/letsencrypt/` (custom `caddy-challtestsrv:2.8.4` image + Pebble), separate from the production data-plane compose.

**Tally:** 10 PASS-with-evidence · 9 PENDING · 3 OPERATOR-BLOCKED. No FAIL; no metadata-only PASS. Change since Rev 1: LE hermetic DNS-01 issuance (Phase 2/3) flipped PENDING→PASS; LE renewal (Phase 5) remains PENDING.

**PASS-with-evidence (deployed data plane + LE Phase 1):**

| Feature | Decisive evidence |
|---|---|
| HTTP forward proxy | `qa-results/challenges/20260701T085518Z/evidence/http/forward_http_evidence.txt` — proxy=204, `Via: 1.1 proxy-squid (squid/6.13)` |
| HTTPS CONNECT tunnel | same file, `https_200` sub-probe (`Connection established` → upstream 200) |
| SOCKS5 + SOCKS5-over-HTTPS | `qa-results/challenges/20260701T085518Z/evidence/socks5/socks5_evidence.txt` (204 + 200) |
| Response caching | `qa-results/comprehensive/cache_hit.evidence` (`TCP_MEM_HIT/200`) + `squid_access_snapshot.log` |
| Cache admin (`cachectl`) | `qa-results/comprehensive/cache_cmd_stats.out` |
| ACL allow-path | forward challenge (localnet admit) — deny-path PENDING |
| `./status` health | `qa-results/comprehensive/status.out` + `status_json.out` |
| Admin `/health` reachability | `qa-results/comprehensive/after_run.log:92` (placeholder-qualified) |
| LE cert-analyzer (Phase 1) | `qa-results/regression/cert_analyzer_selfvalidation/*` (37/37 + §1.1 RED→GREEN) |
| LE hermetic DNS-01 issuance (Phase 2/3) | `qa-results/letsencrypt/phase3_issuance/20260701T103719Z/cert_analyzer_verdicts.txt` (5/5 PASS, leaf→per-run Pebble CA) + `caddy_issuance.log` (`certificate obtained successfully`); guard `qa-results/regression/phase3_issuance_guard/*` (`verdict: PASS`) + RED `qa-results/regression/phase3_guard_red/*`; image `qa-results/letsencrypt/build/caddy_image_build_20260701T091028Z.log` (`dns.providers.challtestsrv present`) |

**PENDING (code/tests exist, not end-user-reachable):** VPN-aware dynamic routing (`internal/routing`, golden-config unit/integration GREEN, `p4-compiler`); Control API REST/SSE/PAC/mTLS/metrics (`internal/api` + `cmd/api`, unit `-race` + real-PG integration + §1.1 mTLS mutation, `p6-api`); VPN health publisher (`internal/vpn` + `cmd/healthd`, real-gluetun integration + chaos + §1.1, `p3-healthd`); circuit breaker/tier-failover (`internal/breaker`, `p5b-breaker`); ACL helper graceful-503 (`internal/aclhelper`, `p5-aclhelper`); PAC generation (`internal/pac` golden); proxy auth `407` / ACL deny-path (`auth_407` analyzer self-validated at fixture level only); observability/metrics (`config/prometheus/prometheus.yml` is an explicit NOT-YET-LIVE PLAN, targets absent); LE **renewal/rotation Phase 5** — diagnosed only, not yet produced (`docs/research/letsencrypt_renewal_20260701/ANALYSIS.md` Rev 3 §11.4.138: ARI on Pebble 2.6.0 dominates `renewal_window_ratio`, `/set-renewal-info/` absent until v2.8.0 PR #501 → needs a Pebble ≥2.8.0 bump). As of run `20260630T221343Z` the live stress/chaos/ddos/benchmark/memory/concurrency suites SKIP (`suite_results.txt`: `PASS=0 SKIP=6 FAIL=0`) against the then-undeployed dynamic stack (P10); analyzers self-validated + RED regression guards (`ddos_flood_evidence`, `benchmark_baseline_ratchet`) PASS. **2026-07-01:** the `dynamic` stack was brought up — **P10 VPN fail-closed** now **PASS** (`qa-results/dynamic/vpn_failclosed/20260701T130115Z/verdict.txt`: 3/3 branded 503, 0 leak, `graceful_503_rc=0`), the **forward-proxy benchmark** now **PASS** (`qa-results/benchmark/proxy_forward_20260701T130414Z/latency.txt`: p50=0.086s, 200/200 204), and the control-plane is race-clean (`qa-results/race/control-plane_race_20260701T125739Z.log`: 0 DATA RACE). Remaining stress/chaos/ddos/memory suites still SKIP.

**OPERATOR-BLOCKED:** LE Phase 4 (staging real DNS-01 — needs DNS provider + scoped token as Podman secret); LE Phase 6 (production cutover — operator go-live gate); real VPN egress proof (needs live tunnel + `VPN_EXIT_IP`; `proxy-vpn` Stopped; the old `host_ip==proxy_ip` "VPN verified" bluff was removed — `tests/verify-proxy.sh:87-98`).

**Key anti-bluff notes.** (1) HelixQA live exec SKIPs honestly — `helixqa` binary unbuildable (6 own-org sibling modules absent), proxy re-proven via a stdlib HTTPExecutor replica (`qa-results/helixqa/*/mech_*.txt`). (2) Cache challenge client-side SKIP is `topology_unsupported` (rootless subuid owns `access.log`); the `TCP_MEM_HIT` PASS comes from comprehensive-test's container-side snapshot. (3) Every analyzer (`no_leak`, `graceful_503`, `egress_neq_host`, `xcache_hit`, `auth_407`, cert-analyzer) is golden-good/golden-bad self-validated (§11.4.107(10)). (4) Video-confirmation is N/A — helix_proxy is headless; proof is captured status codes + `Via:` headers + `access.log` `TCP_*HIT`.

**Cross-refs:** control-plane `control-plane/README.md`; LE design `docs/design/letsencrypt/Status.md`; LE hermetic issuance `deploy/letsencrypt/phase3_hermetic_issue.sh` + `deploy/letsencrypt/README.md`; LE renewal diagnosis `docs/research/letsencrypt_renewal_20260701/ANALYSIS.md`; HelixQA bank `tools/helixqa/banks/proxy.yaml`; challenge bank `challenges/scripts/run_proxy_challenges.sh` (+ `challenges/scripts/le_phase3_issuance_challenge.sh`).
