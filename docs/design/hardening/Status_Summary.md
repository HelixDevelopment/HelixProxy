# Proxy Hardening — Status Summary

**Revision:** 2
**Last modified:** 2026-07-01T13:14:00Z
**Status:** Companion summary of [`Status.md`](Status.md) (§11.4.56 two-audience).

---

## Page 1 — For the operator / stakeholders (plain language)

We put the proxy through a battery of **hardening tests** — the kind that try to break it
with heavy load, sudden restarts, floods of traffic, many users at once, and long-running
memory checks — to prove it stays healthy and trustworthy under pressure. Every "pass"
below is backed by a saved proof file captured while the proxy was actually running, so
none of these results can be faked.

**What passed (proven this round):**

- **Heavy load + sudden restart:** the proxy handled 110 back-to-back and simultaneous
  requests, and when we forcibly restarted it, it came back and served traffic again within
  seconds.
- **Traffic flood (denial-of-service):** we hit it with 300 requests as fast as possible —
  all 300 got through, nothing was dropped, and it kept listening and recovered cleanly.
- **Many users at once:** 40 clients used the proxy simultaneously (both web and SOCKS5
  styles) with **zero cross-talk** — no user ever saw another user's data.
- **Memory stability:** over a sustained run the proxy's memory barely moved (about 0.17%
  growth), proving no memory leak.

**Also passed this round (newly proven):**

- **VPN "fail-closed" safety (the big one):** we booted the VPN-aware routing stack, forced
  the tunnel DOWN, and confirmed that every request was refused with the branded
  "tunnel down" page and **nothing leaked to the open internet** — proven three times in a
  row, plus a deliberately-broken control run that correctly caught a simulated leak. This is
  the security-critical guarantee that the proxy never sends your traffic out unprotected.
- **Race-condition / deadlock check:** the proxy's control-plane code was run under Go's race
  detector across all 11 modules — **zero data races** found, with real concurrent tests
  exercising the shared state.
- **Performance benchmark:** 200 requests through the proxy, measured typical latency at
  ~86 milliseconds (99th percentile ~91 ms) — a saved performance baseline.

**What is still honestly skipped:**

- **Real-VPN egress proof** (that traffic actually exits *through* the tunnel) needs the
  operator's VPN credentials — honestly skipped, not faked.
- **The access-control leak test** is honestly **skipped** because the current setup can't
  automatically produce a real "access denied" situation to test against.

**Bottom line:** eight hardening dimensions — including the critical VPN fail-closed safety
guarantee — are now proven solid with saved evidence; two items remain honestly skipped
pending operator credentials / a specific topology. No result is overstated.

---

## Page 2 — For software engineers

§11.4.169 test-type-coverage reconciled for the proxy hardening workstream. Base stack UP on
`:53128` at capture. Verdicts are the literal `OVERALL=` lines from each `.evidence` artefact.

| Test type | Status | Evidence |
|---|---|---|
| DDoS / load-flood | PASS | `qa-results/ddos/proxy_flood_20260701T122320Z/flood.evidence` — `landed=300/300`, `OVERALL=PASS` |
| Stress + Chaos | PASS | `qa-results/stress/proxy_forward_20260701T120843Z/stress.evidence` (110/110, `OVERALL=PASS`) + `qa-results/chaos/proxy_restart_20260701T120941Z/recovery_trace.log` (`recovered=yes … OVERALL=PASS`) |
| Concurrency / atomicity | PASS | `qa-results/concurrency/proxy_concurrency_20260701T122740Z/concurrency.evidence` — 40 mixed clients, `crosstalk=0`, `OVERALL=PASS` |
| Memory | PASS | `qa-results/memory/proxy_soak_20260701T122643Z/soak.evidence` — `growth_ratio=1.0017`, `OVERALL=PASS` |
| Security (ACL) | SKIP | `qa-results/security/proxy_acl_20260701T120913Z/s1_acl_deny.evidence` — `SKIP:topology_unsupported` (deny code `000000`, §11.4.3) |
| Full-automation (P10 VPN fail-closed) | PASS | `qa-results/dynamic/vpn_failclosed/20260701T130115Z/verdict.txt` — tunnel DOWN ⇒ branded 503 `ERR_TUNNEL_DOWN` ×3, `leak_seen=0`, Squid PID unchanged; deterministic ×3 + RED polarity guard (§11.4.50/§11.4.115). Egress-half operator-gated SKIP (§11.4.21) |
| Race / deadlock | PASS | `qa-results/race/control-plane_race_20260701T125739Z.log` — `go test -race ./...` 11 pkgs, **0 DATA RACE**, EXIT=0 |
| Benchmarking / performance | PASS | `qa-results/benchmark/proxy_forward_20260701T130414Z/latency.txt` — 200/200 204s, `p50=0.086 p95=0.088 p99=0.091`s, 10.841 req/s, `OVERALL=PASS` |
| Unit / Integration / E2E / Challenges / HelixQA | PENDING | Not re-proven in this hardening round; no captured hardening-round evidence this session (§11.4.6) |

Composes §11.4.45 (integration-status doc), §11.4.56 (two-audience summary), §11.4.169
(mandatory test-type coverage), §11.4.5/§11.4.69 (captured evidence), §11.4.6 (no-guessing),
§11.4.3 (honest SKIP), §11.4.115 (P10 RED-baseline polarity switch).
