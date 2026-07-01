# Proxy Hardening — Test-Type Coverage Status

**Revision:** 2
**Last modified:** 2026-07-01T13:12:00Z
**Status:** In progress — 8 hardening test types PASS with captured live evidence (stress+chaos, DDoS, concurrency/atomicity, memory-soak, **P10 VPN fail-closed full-automation GREEN**, **race/deadlock**, **benchmarking/performance**), 1 honest SKIP (security ACL — no autonomous real-ACL-deny topology). P10 GREEN was proven live this round after recreating the 4 dynamic-stack Podman secrets + booting the dynamic stack (tunnel-DOWN ⇒ branded 503 ×3 + NO leak, ×3 deterministic + RED polarity guard). No PASS is claimed without a real `qa-results/` evidence path (§11.4.6).
**Authority:** Inherits `constitution/Constitution.md` per §11.4.35. §11.4.45 integration-status doc reconciling the §11.4.169 test-type-coverage matrix for the proxy hardening workstream.
**Companion:** summary [`Status_Summary.md`](Status_Summary.md)

## Operator-blocked / pending items (read first — §11.4.45 O(1) surface)

| Item | Why blocked / pending | Unblock condition |
|---|---|---|
| P10 real-VPN egress-half (SKIP) | The egress half — proving traffic actually EXITS via the tunnel — needs operator gluetun WireGuard credentials (§11.4.21). The fail-closed half is now GREEN. | Operator provides gluetun WireGuard creds; then the real-egress positive path can be captured. |
| security ACL deny-does-not-leak (SKIP) | No autonomous topology on the base stack produces a real Squid ACL deny (observed deny code `000000` — cannot prove deny nor leak). | A dynamic/ACL-configured topology where a CONNECT to a denied target returns 403/407, so deny-without-leak is provable. |

## §11.4.169 test-type-coverage matrix (captured-evidence-driven — §11.4.5/§11.4.69)

Base proxy stack UP on `:53128` at capture time. Every PASS below cites a real, non-empty `qa-results/` artefact captured live this session.

| Test type | Status | Evidence path | Notes |
|---|---|---|---|
| Unit | PENDING | — | Not re-proven in this hardening round; no captured hardening-round evidence this session (§11.4.6). Tracked in the broader test suite. |
| Integration | PENDING | — | Not re-proven in this hardening round; no captured hardening-round evidence this session (§11.4.6). |
| E2E | PENDING | — | Not re-proven in this hardening round; no captured hardening-round evidence this session (§11.4.6). |
| Full-automation (P10 VPN fail-closed) | PASS | `qa-results/dynamic/vpn_failclosed/20260701T130115Z/verdict.txt` (+ `req_1..3.body` branded pages) | `tests/dynamic/vpn_failclosed_test.sh` GREEN live on the booted dynamic stack: tunnel DOWN ⇒ branded 503 `ERR_TUNNEL_DOWN` ×3 (3132-byte real page, 7 brand markers), `leak_seen=0`, `upstream_forward_lines=0`, Squid PID unchanged (36). Deterministic ×3 (§11.4.50), RED polarity guard FAILs a fabricated 200 leak (§11.4.115). Egress-half operator-gated SKIP (§11.4.21). |
| Challenges | PENDING | — | Not re-proven in this hardening round; no captured hardening-round evidence this session (§11.4.6). |
| HelixQA | PENDING | — | Not re-proven in this hardening round; no captured hardening-round evidence this session (§11.4.6). |
| DDoS / load-flood | PASS | `qa-results/ddos/proxy_flood_20260701T122320Z/flood.evidence` (+ `census.txt`) | 300/300 requests landed (`success=300 refuse_shed=0 timeout=0 error=0`); HTTP `:53128` + SOCKS5 `:51080` still listening after flood; recovery code 204. `OVERALL=PASS`. |
| Security | SKIP | `qa-results/security/proxy_acl_20260701T120913Z/s1_acl_deny.evidence` | Honest SKIP:topology_unsupported — no autonomous real-ACL-deny topology on the base stack (observed deny code `000000`). Header-hygiene sub-check captured (`s2_header_hygiene.evidence`). Not a PASS-by-default (§11.4.3). |
| Stress + Chaos | PASS | `qa-results/stress/proxy_forward_20260701T120843Z/stress.evidence` · `qa-results/chaos/proxy_restart_20260701T120941Z/recovery_trace.log` | Stress: 110/110 forward probes OK (100 sequential + 10 concurrent), `via` header corroborates bytes transited proxy→squid, `OVERALL=PASS`. Chaos: restart-fault injected, recovered code 204 within timeout, `OVERALL=PASS`. |
| Concurrency / atomicity | PASS | `qa-results/concurrency/proxy_concurrency_20260701T122740Z/concurrency.evidence` (+ `clients.tsv`) | 40 simultaneous mixed clients (http=20 + socks5=20), `crosstalk=0 proxy_drop=0 endpoint_limit=0`, zero cross-talk. `OVERALL=PASS`. |
| Race / deadlock | PASS | `qa-results/race/control-plane_race_20260701T125739Z.log` | `go test -race -count=1 ./...` on `control-plane` (11 pkgs incl. cmd/acl-helper, cmd/healthd, cmd/api, cmd/compiler, internal/{aclhelper,api,breaker,otel,pac,redis,routing,store,vpn}): EXIT=0, **0 `WARNING: DATA RACE`**. Real concurrent tests spawn goroutines against mutex-guarded shared state (`internal/api/server.go:34`, `internal/breaker/tunnelbreaker.go:107`, `cmd/healthd/main.go:263`). Follow-up (documented, not a race): a store-layer TOCTOU un-audited-mutation atomicity gap — §11.4.169 concurrency/atomicity item. |
| Memory | PASS | `qa-results/memory/proxy_soak_20260701T122643Z/soak.evidence` (+ `rss_timeseries.tsv`) | RSS-bounded soak: baseline 35 830 000 B → final 35 890 000 B, `growth_ratio=1.0017` (bound 1.5). `OVERALL=PASS`. |
| Benchmarking / performance | PASS | `qa-results/benchmark/proxy_forward_20260701T130414Z/latency.txt` | `tests/benchmark/proxy_forward_benchmark.sh` live vs base proxy: 200/200 proxied 204s, latency `p50=0.086s p95=0.088s p99=0.091s` (min 0.085 / max 0.102 / mean 0.087), throughput 10.841 req/s, direct-probe 204, `OVERALL=PASS`. Follow-up (documented): `control-plane` ships zero Go micro-benchmarks — §11.4.169 Go-bench gap (submodules helix_qa + containers do carry real Go benchmarks). |

## Honest boundary (§11.4.6)

This matrix reconciles the **hardening** test-type picture proven in this session only. The 8 hardening-focused types (stress+chaos, DDoS, concurrency/atomicity, memory, P10 fail-closed full-automation, race/deadlock, benchmarking) are PASS with captured live `qa-results/` evidence. PENDING rows (unit/integration/e2e/Challenges/HelixQA) are not claims the underlying capability is broken — they mean no hardening-round captured evidence exists this session; they are neither PASS nor FAIL and are covered by the broader `tests/run-tests.sh` suite. The single SKIP (security ACL) is topology-honest (§11.4.3). Two documented follow-ups (store-TOCTOU atomicity gap; `control-plane` zero Go micro-benchmarks) are §11.4.169 items, not regressions. None of this substitutes for the §11.4.40 full-suite retest before a release tag.
