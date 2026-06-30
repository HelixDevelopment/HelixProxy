# E — Existing Test + Challenge Suite Anti-Bluff Audit

**Revision:** 1
**Last modified:** 2026-06-30T00:00:00Z
**Scope:** read-only audit of `tests/` (7 files) + `challenges/scripts/` (3 files)
**Authority:** Helix Constitution §11.4 (anti-bluff covenant), §11.4.6 (no-guessing), §11.4.68/§11.4.69 (sink-side positive evidence)
**Method:** every verdict below quotes the real assertion line(s) from the source. No claim is made about behaviour that the scripts do not assert.

---

## 1. Summary counts

| Class | Files |
|---|---|
| **FUNCTIONAL** (exercise real proxy/VPN/cache behaviour) | 3 — `tests/comprehensive-test.sh`, `tests/final-verify.sh`, `tests/verify-proxy.sh` |
| **STRUCTURAL / pre-build** (config/file/port presence; runs the governance gate; NO functional proxy request) | 1 — `tests/run-tests.sh` |
| **GOVERNANCE** (constitution inheritance / host-power CONST-033) | 6 — `tests/constitution_inheritance_gate.sh`, `tests/pre_build_verification.sh`, `tests/test_constitution_inheritance.sh`, `challenges/scripts/host_no_auto_suspend_challenge.sh`, `challenges/scripts/meta_test_constitution_inheritance.sh`, `challenges/scripts/no_suspend_calls_challenge.sh` |

Headline: **only 3 of 10 files touch real proxy behaviour**, and they overlap heavily (final-verify.sh and verify-proxy.sh are near-duplicates of the same 5 checks). The governance/host-power side is well-built and even has a genuine paired mutation; the **functional side has no paired mutation, no sink-side evidence (X-Cache / egress-IP-differs / 503-on-down), and one inverted VPN assertion that passes with no VPN at all.**

---

## 2. File-by-file

### 2.1 `tests/comprehensive-test.sh` — FUNCTIONAL (+ structural infra checks)
16 test groups. Per-assertion verdicts:

| Assertion (line) | What it asserts | Verdict |
|---|---|---|
| `test_environment` (154-174) | `.env` exists, `HTTP_PROXY_PORT`/`SOCKS_PROXY_PORT`/`CACHE_DIR` set, cache dir exists | **BLUFF-RISK** — file/var presence only, no runtime |
| `test_scripts` (185-191) | `[[ -x "$PROJECT_ROOT/$script" ]]` | **BLUFF-RISK** — executable bit, not behaviour |
| `test_container_runtime` (200-223) | runtime + compose available | infra check |
| `test_containers` (233-251) | `podman ps --format '{{.Names}}' | grep -q "^proxy-squid$"` | **BLUFF-RISK** — process presence ≠ proxy works. VPN container → `SKIP` if absent (acceptable) |
| `test_ports` (267-285) | `ss -tuln | grep -q ":${http_port} "` | **BLUFF-RISK** — port open ≠ proxy serves |
| `test_http_proxy` (299-335) | real `curl --proxy http://localhost:$port` to `generate_204` (→204/200), `https://www.google.com` (→200/301/302), `httpbin.org/ip`, `api.ipify.org` (→200) | **REAL-EVIDENCE** (status-code level) — genuinely forwards a request through Squid and asserts the origin response code; falls back to `"000"`→FAIL, no PASS-by-default. Limitation: `-o /dev/null -w "%{http_code}"` discards the body — no egress-IP / `X-Cache` capture |
| `test_socks_proxy` (349-369) | real `curl --proxy socks5://localhost:$port` (→204/200, →200/301/302) | **REAL-EVIDENCE** (status-code level) — genuine SOCKS egress |
| `test_vpn_routing` (399-416) | `host_ip` (direct ifconfig.me) vs `http_proxy_ip` (via proxy); PASS when `"$http_proxy_ip" == "$host_ip"` | **BLUFF-RISK** — egress IP *is* captured, but the PASS condition is "proxy egress == host's direct egress", which is **TRUE when there is no VPN at all** (both = bare ISP IP). Never asserts the egress differs from the known clear-net IP nor matches a VPN endpoint. SKIP if IPs `unknown` (acceptable) |
| `test_caching` (430-467) | request same URL twice; PASS if `second_time < first_time`, else `SKIP`; + `./cache stats &>/dev/null` | **BLUFF-RISK** — pure timing heuristic on `httpbin.org/bytes/65536` (uncacheable random bytes); never reads Squid `X-Cache`/`TCP_HIT`/`TCP_MEM_HIT`. cache_hit is NOT validated |
| `test_admin` (481-499) | `curl .../health` →200, `curl .../` →200 | **BLUFF-RISK** (weak) — real HTTP but status-code-only, no body/content assertion |
| `test_status_command` (512-529), `test_cache_commands` (542-559) | `./status &>/dev/null`, `./cache stats|size|list &>/dev/null` | **BLUFF-RISK** — return-code-only |
| `test_dns` (574-581) | `curl --proxy ... dns.google/resolve?...` then `grep -q "Answer"` on the body | **REAL-EVIDENCE** — inspects response body content |
| `test_large_file` (596-605) | 1 MB download via proxy; `size_download > 1000000` | **REAL-EVIDENCE** — real byte transfer through proxy |
| `test_concurrent` (622-646) | 10 background curls; collects `code=$(wait "$job")` | **BLUFF-RISK / FAIL-bluff (§11.4.1)** — `wait "$job"` yields the job *exit status* (`0`), NOT the captured `%{http_code}` stdout (which is never captured). Compared against `"200"`, so `success` never increments → spurious FAIL. Script does not measure what it claims |
| `test_network_client` (672-692) | curl via `${host_ip}:${port}` HTTP + SOCKS (→204/200) | **REAL-EVIDENCE** (status-code) — exercises the LAN-facing bind |

Skip discipline: VPN container / caching / vpn-routing degrade to `SKIP` correctly. The proxy functional tests do **not** skip-when-absent — a dead service yields `"000"`→FAIL (loud, acceptable; no PASS-by-default).

### 2.2 `tests/final-verify.sh` — FUNCTIONAL
5 checks (lines 36-78):
- HTTP proxy `generate_204`→204 (37): **REAL-EVIDENCE** (status-code).
- HTTPS via HTTP proxy →200/301/302 (46): **REAL-EVIDENCE** (status-code; a real CONNECT through Squid).
- SOCKS5 `generate_204`→204 (55): **REAL-EVIDENCE**.
- HTTPS via SOCKS5 (64): **REAL-EVIDENCE**.
- VPN routing (72-78): `[[ "$host_ip" == "$proxy_ip" && "$host_ip" != "unknown" ]]` → **BLUFF-RISK**, identical inverted logic to comprehensive — green with NO VPN.
No SKIP path; dead service → `"000"`→FAIL (loud).

### 2.3 `tests/verify-proxy.sh` — FUNCTIONAL
Functionally identical to final-verify.sh, one-liner form (lines 31-49). Same verdicts: HTTP/HTTPS/SOCKS = **REAL-EVIDENCE** (status-code); VPN routing (49) = **BLUFF-RISK** (same `host_ip == proxy_ip` inversion).

### 2.4 `tests/run-tests.sh` — STRUCTURAL / pre-build (NO functional proxy request)
Runs the constitution gate first (governance), then: `.env` exists (56), `.env.example` exists (63), `HTTP_PROXY_PORT` set (72), directory list exists (99-105), scripts executable (124-130), config files exist (146-152), `docker compose config --quiet` syntax (168), runtime installed (191-214), **ports** (230-236: here PASS = port *free* — opposite polarity to comprehensive, this is a "ports not in use" pre-flight), cache dir exists/writable (250-258), `test_vpn` (267-301), `test_service_startup` (307-331).
- Every assertion is **BLUFF-RISK** w.r.t. user-visible capability (file existence / executable bit / port free / compose syntax / config presence).
- **PASS-by-default risks:** `test_vpn` → if `USE_VPN != "true"` → `test_result "VPN disabled" "PASS"` (273); `test_service_startup` → if `RUN_STARTUP_TESTS != "true"` → `test_result "Startup tests" "PASS" "Skipped"` (311) — a skip recorded as PASS (labelled, but increments `TESTS_PASSED`). Acceptable only because this is a structural pre-build runner, NOT a functional suite — but its banner "Proxy Service Test Suite" overstates its coverage.

### 2.5 `tests/constitution_inheritance_gate.sh` — GOVERNANCE
`grep -qF` for anchor headings in `constitution/{Constitution,CLAUDE,AGENTS}.md` + parent inheritance pointers (I1-I5, lines 66-105). grep-based, but for a governance/inheritance gate the file content **is** the behaviour, so this is correct, not a bluff. Read-only. Has a paired mutation (§2.9). **Genuine.**

### 2.6 `tests/pre_build_verification.sh` — GOVERNANCE
Thin orchestrator (32) that only runs `constitution_inheritance_gate.sh`. Zero functional coverage. Comment at line 40 admits "Additional pre-build gates may be appended here". **Governance only.**

### 2.7 `tests/test_constitution_inheritance.sh` — GOVERNANCE
Delegates to the gate (46) + recursive owned-submodule inheritance-pointer check (59-86); reports the zero-children case **loudly** as N/A (82-85) rather than silently skipping. Read-only. **Genuine.**

### 2.8 `challenges/scripts/host_no_auto_suspend_challenge.sh` — GOVERNANCE (CONST-033)
4 assertions against **real host state**: `systemctl is-enabled` targets == `masked` (42-52), `AllowSuspend=no` in sleep.conf/drop-ins (56-61), logind `IdleAction` == `ignore`/`<unset>` (65-74), `journalctl --since <fix-marker> | grep -c "The system will suspend now"` == 0 (83-91). Reads genuine system state — **REAL-EVIDENCE** for the host-hardening claim.

### 2.9 `challenges/scripts/meta_test_constitution_inheritance.sh` — GOVERNANCE (paired §1.1 mutation)
For each anchor: snapshot → strip → run gate → **require exit ≠ 0** → restore → assert working tree quiescent (103-150). This is a **genuine anti-bluff meta-test that proves the governance gate catches its regressions** ("gate PASSed despite stripped anchor => BLUFF GATE", 83). Excellent — but note it proves **only the governance gate**; there is **no equivalent paired mutation for any functional proxy/VPN/cache test.**

### 2.10 `challenges/scripts/no_suspend_calls_challenge.sh` — GOVERNANCE (source scan)
Wraps `scripts/host-power-management/check-no-suspend-calls.sh` over the tree (44). Source-tree scan for forbidden power calls — real for its purpose.

---

## 3. Capability-gap matrix

| Capability | Verdict | Evidence / reason (file:assertion) |
|---|---|---|
| `http_forward_proxy` | **VALIDATED** (status-code level) | Real forwarded request returns origin status: comprehensive `test_http_proxy:304`, final-verify:37, verify-proxy:32. Limitation: body discarded, no `X-Cache`/egress capture |
| `https_connect` | **VALIDATED** (status-code level) | Real CONNECT via `--proxy http://...` to google.com →200/301/302: comprehensive:316, final-verify:46, verify-proxy:36 |
| `socks5_egress` | **VALIDATED** (status-code level) | Real `--proxy socks5://...` →204/200: comprehensive:354, final-verify:55, verify-proxy:40 |
| `cache_hit` | **BLUFF-ONLY** | comprehensive `test_caching:456` — timing-only (`second_time < first_time` else SKIP) on uncacheable random bytes; never reads Squid `X-Cache`/`TCP_HIT`. No header-level cache-hit proof anywhere |
| `vpn_real_egress_ip` | **BLUFF-ONLY** | Egress IP captured (comprehensive:390, final-verify:73, verify-proxy:48) but PASS condition `proxy_ip == host_ip` (comprehensive:400, final-verify:74, verify-proxy:49) **passes with no VPN** (both = bare ISP IP). Never compares against a known clear-net IP or VPN endpoint |
| `graceful_503_on_tunnel_down` | **NO-COVERAGE** | No test takes the tunnel down and asserts a 503 (grep of all 10 files: no down-injection, no 503 assertion) |
| `no_leak_killswitch` | **NO-COVERAGE** | No test verifies that with the tunnel down, egress is blocked / does not fall back to bare ISP IP |
| `vpn_reconnect` | **NO-COVERAGE** | No reconnect / flap-recovery test |
| `cache_invalidation` | **NO-COVERAGE** | `./cache list/size` are return-code-only (comprehensive:549-556); no purge-then-miss validation |
| `admin_panel` | **BLUFF-ONLY** | comprehensive `test_admin:485,496` — `/health` and `/` →200 only; no body/content/functionality assertion |

**Genuinely covered (status-code level):** http_forward_proxy, https_connect, socks5_egress.
**No real coverage at all:** graceful_503_on_tunnel_down, no_leak_killswitch, vpn_reconnect, cache_invalidation — the entire failure-mode / kill-switch / resilience surface (§11.4.85 stress+chaos) is absent.

---

## 4. Worst bluff-risks (ranked)

1. **`final-verify.sh:74` / `verify-proxy.sh:49` / `comprehensive-test.sh:400`** — `[[ "$host_ip" == "$proxy_ip" ... ]] && PASS "VPN routing verified"`. The label claims VPN verification but the condition is satisfied when **no VPN exists** (proxy egress == host's clear-net egress). A green "VPN routing verified" with zero tunnel is the textbook §11.4 PASS-bluff. It even captures the egress IP — the data is there — but the assertion validates the wrong thing.
2. **`comprehensive-test.sh:456` (`test_caching`)** — cache "PASS" on a timing heuristic over uncacheable random bytes, else SKIP; never inspects `X-Cache`/`TCP_HIT`. `cache_hit` is unvalidated despite caching being the project's headline feature.
3. **`run-tests.sh` (whole file)** — banner "Proxy Service Test Suite" but every assertion is structural (file exists / executable / port free / compose syntax / config present). Plus PASS-by-default: `test_vpn:273` (USE_VPN!=true → PASS "VPN disabled"), `test_service_startup:311` (RUN_STARTUP_TESTS!=true → PASS "Skipped").
4. **`comprehensive-test.sh:633-640` (`test_concurrent`)** — `code=$(wait "$job")` captures the job exit status (`0`), not the curl `%{http_code}` (never captured); compared to `"200"` → success counter never increments → spurious FAIL (§11.4.1 FAIL-bluff). The test cannot pass even when concurrency works.
5. **Return-code-only command tests** — `comprehensive-test.sh:463,512,519,526,542,549,556` (`./status`, `./cache ... &>/dev/null`): green merely means exit 0, no output/state assertion.

## 5. Structural anti-bluff gap

The governance side has a real paired §1.1 mutation (`meta_test_constitution_inheritance.sh`) proving its gate is not a bluff. **No functional proxy/VPN/cache test has any paired mutation, any sink-side positive evidence (§11.4.68/§11.4.69 — egress-IP-differs, `X-Cache: HIT`, real 503), or any failure-injection (§11.4.85).** The functional suite proves "a request returns a 2xx through the proxy" and nothing about VPN tunneling, cache hits, kill-switch, or graceful degradation.
