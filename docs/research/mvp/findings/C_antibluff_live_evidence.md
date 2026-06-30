# C — Anti-Bluff Live Evidence: Proving a VPN + Proxy + Cache System Actually Works

**Revision:** 1
**Last modified:** 2026-06-30T00:00:00Z
**Scope:** `helix_proxy` MVP — anti-bluff test-method research (§11.4.69 sink-side positive-evidence taxonomy + §11.4.107 liveness mandate).
**System under proof:** OpenVPN/WireGuard tunnels + Squid (HTTP/HTTPS cache, `:53128`) + Dante (SOCKS5, `:51080`), rootless Podman containers, dynamic control-plane returning `503` when a target tunnel is down.

> Hard rule (project §11.4 / §11.4.69 / §11.4.107): a test that PASSes **without capturing evidence the user-visible behaviour really works** is a critical defect. Every PASS below cites a captured artefact (a byte-counter delta, a log line, an observed egress IP, a status code + unchanged PID). Config-only / "absence-of-error" / grep-without-runtime PASSes are forbidden.

---

## 0. The core anti-bluff principle for this stack

There are two classes of signal, and only one is trustworthy as **proof of user-visible behaviour**:

1. **Control-plane / configuration signals** — "the interface exists", "the config parsed", "the process is listening", "`wg show` prints a peer", "`squid -k parse` is clean". These prove *intent*, not *function*. **They are NOT evidence** under §11.4.69.
2. **Data-plane / sink-side signals** — bytes actually moved, an echo service reported the **VPN exit IP** (not the host's real IP), Squid logged a `TCP_HIT`, the proxy returned a real `503` body while keeping the same PID. **These ARE evidence.**

Every capability below is proven with a data-plane signal. The decisive, hardest-to-fake proof for the tunnel/proxy chain is the **egress public-IP assertion**: drive a request *through* the chain to an IP-echo service and assert `observed_ip == expected_vpn_exit AND observed_ip != host_real_ip`. A handshake, a byte counter, or a "200 OK" can all be green while traffic still egresses the wrong interface — only the echoed source IP closes that gap. `FACT (cited)`.

---

## 1. PROVE a VPN tunnel actually carries traffic (not just "configured")

### 1a. WireGuard
`FACT (cited)`: `wg show <iface>` (or `wg show <iface> transfer` / `dump`) reports per-peer **latest handshake** and **transfer (bytes received / bytes sent)**. Trust rules:
- `latest handshake` shows `(none)` ⇒ tunnel **never** established. A *recent* handshake (WireGuard renegotiates every ~2 min while traffic flows; "within ~3 min" is the active-window heuristic) is necessary but **not sufficient** — a handshake can complete with zero application traffic. [oneuptime monitor], [oneuptime troubleshoot], [cr0x].
- `transfer` showing `0 B received, 0 B sent` ⇒ no data exchanged. **The decisive WireGuard signal is the byte-counter DELTA**: snapshot `rx/tx` before, drive traffic, snapshot after, assert `Δrx > 0 AND Δtx > 0`. [oneuptime monitor], [DoHost].
- `wg show ... dump` is the machine-parseable form (tab-separated) for scripting; `latest handshake` is a Unix epoch you compare to `date +%s`. [DoHost], [xitoring].

> **Don't-be-fooled gotcha:** a recent handshake with flat byte counters = control-plane green, data-plane dead. Assert the **delta**, never the presence of a handshake alone.

### 1b. OpenVPN
`FACT (cited)`: the **management interface** (telnet to its port, or via the GUI) gives live state without parsing logs. [OpenVPN management-docs], [management-notes.txt].
- `state` → tunnel state machine (`CONNECTED`, `RECONNECTING`, …).
- `bytecount n` → real-time bytes in/out every *n* seconds when running as client (`>BYTECOUNT:` async messages). [OpenVPN management-docs].
- `status /var/log/openvpn/status.log` config directive → periodic snapshot of `CLIENT_LIST`, `ROUTING_TABLE`, `GLOBAL_STATS` (default 60 s). [OpenVPN status-docs], [management-notes.txt].
- PASS = `state == CONNECTED` AND a positive `bytecount`/`GLOBAL_STATS` byte delta across the test window.

### 1c. Kernel-level corroboration (transport-agnostic, captured on host)
- `/proc/net/dev` per-interface RX/TX byte deltas (snapshot-diff the tunnel iface row). `FACT`: standard Linux counter, no extra tooling.
- `tcpdump -ni <tun-or-wg-iface> -c N` — capture N packets actually traversing the tunnel iface; non-empty capture = live traffic. (Use bounded `-c`/`-w` + `timeout` for §12 host-safety.)
- `conntrack -L` / `ss -tnp` — show live flows pinned to the tunnel.

### 1d. The decisive proof — egress public-IP assertion
`FACT (cited)`: request an IP-echo service **through** the tunnel/proxy and compare to the host's real IP.
```bash
HOST_IP=$(curl -s https://icanhazip.com)                       # baseline, no proxy
VIA_IP=$(curl -s -x http://127.0.0.1:53128 https://icanhazip.com)  # through Squid->tunnel
[ -n "$VIA_IP" ] && [ "$VIA_IP" != "$HOST_IP" ] && [ "$VIA_IP" = "$EXPECTED_EXIT" ]  # PASS
```
Echo services: `icanhazip.com`, `ifconfig.me`, `api.ipify.org`. [everything.curl SOCKS], [floxy], [zaltsman]. PASS = observed IP equals the expected VPN exit AND differs from host real IP. This is the single hardest-to-bluff capability proof.

---

## 2. PROVE cache behaviour (real HIT, not a config claim)

`FACT (cited)` — three independent, corroborating signals; require ≥2 to call a real HIT:

1. **Response header** — `curl -x http://127.0.0.1:53128 -I http://<cacheable-url>` and inspect the Squid `X-Cache` / `X-Cache-Lookup` header. [proxyserverpro], [linuxquestions].
2. **`access.log` result code** — `TCP_MISS/200` on first request, `TCP_HIT/200` (or `TCP_MEM_HIT`, `TCP_REFRESH_HIT`, `TCP_IMS_HIT`) on the second. The result-code tags are `TCP` (HTTP port) + `HIT`/`MEM`/`MISS`; `HIT` = "the response object delivered was the local cache object", `MISS` = "the network response object", `MEM` = served from memory cache. [Squid SquidLogs wiki], [Ivanti], [proxyserverpro].
3. **`store.log`** — transaction journal of disk objects: `SWAPOUT` = object written to cache, `RELEASE` = uncached/evicted, file-number `FFFFFFFF` = memory-only/uncachable. Confirms the object was actually stored. [Squid SquidLogs wiki].

**Behavioural corroboration (metamorphic, §11.4.107(8)):** issue the same request twice; assert request-2 latency ≪ request-1 latency (cached objects serve in ~ms vs an origin round-trip) AND request-2 emits no origin-bound traffic on the tunnel iface (byte-delta ~0 upstream). [arxiv delayed-hits], [Squid PerformanceAnalysis].

> **Don't-be-fooled gotcha:** any URL containing `?` is treated as dynamic and is **not cached** by default — your "MISS forever" is a fixture bug, not a cache bug. Use a known-static cacheable object as the fixture, and never accept a config line (`cache_dir …`) as proof of a HIT. [proxyserverpro], [netgate]. Also: an `X-Cache: HIT` header alone can be forged upstream — cross-check it against `access.log` + latency drop.

---

## 3. PROVE SOCKS5 works (Dante `:51080`)

`FACT (cited)`: drive an echo service through the SOCKS5 proxy and assert the egress IP.
```bash
curl -s --socks5-hostname 127.0.0.1:51080 https://icanhazip.com   # proxy-side DNS
curl -s -x socks5h://127.0.0.1:51080 https://ifconfig.me          # equivalent
```
- `--socks5` / `-x socks5://` = curl resolves DNS **locally** (leak risk).
- `--socks5-hostname` / `-x socks5h://` = hostname sent to the proxy, DNS resolved **proxy-side** (no local DNS leak). Prefer `socks5h` for leak-correct tests. [everything.curl SOCKS], [floxy], [zaltsman], [oxylabs].
- PASS = non-empty body AND observed IP == expected SOCKS exit AND != host real IP.

> **Don't-be-fooled gotcha:** `socks5://` (no `h`) resolves DNS on the test host — a "working" SOCKS test with plain `socks5` can still leak DNS. Always test with `socks5h`/`--socks5-hostname`.

---

## 4. PROVE graceful 503-on-tunnel-down + no crash

The control-plane returns `503` when a target's tunnel is down. Anti-bluff sequence:
```bash
PID_BEFORE=$(pidof squid)                      # or container PID / start-epoch
# 1. tunnel UP  -> assert 200 through proxy
curl -s -o /dev/null -w '%{http_code}' -x http://127.0.0.1:53128 http://<target>   # expect 200
# 2. take tunnel DOWN (wg-quick down / ip link set down / toxiproxy 'down' / pumba stop)
# 3. assert graceful 503 WITH a clear body, NOT a hang/connection-refused
CODE=$(curl -s -o body.txt -w '%{http_code}' -x http://127.0.0.1:53128 http://<target>)  # expect 503
grep -q '<expected-reason-text>' body.txt        # body is intentional, not blank
PID_AFTER=$(pidof squid)
[ "$PID_BEFORE" = "$PID_AFTER" ]                 # PASS: proxy did NOT restart/crash
# 4. bring tunnel UP -> assert 200 again (recovery)
```
PASS evidence: captured `503` + matching body text + **unchanged PID/uptime** (proves graceful degradation, not a crash-loop) + a `200` on recovery. This is the §11.4.108 runtime-signature for this feature. A blank-body 503, a `502`, a hang, or a changed PID = FAIL.

> **Don't-be-fooled gotcha:** distinguish a *deliberate* `503` (proxy alive, returns intentional body) from `connection refused` / timeout / a restarted process. Assert the **body content AND the PID equality** — a 503 from a crashed-and-restarted proxy is not "graceful".

---

## 5. Leak tests (kill-switch effectiveness, DNS, IPv6, WebRTC)

A kill switch must block ALL traffic when the VPN drops; a disabled kill switch is the #1 cause of IP leaks. [myipscan], [nordvpn], [vpn.how]. Automatable methods:

- **Kill-switch / no-leak-while-down:** take the tunnel down, then attempt egress and assert it **fails closed** — `curl` through the path returns error AND `tcpdump -ni <real-uplink-iface>` captures **zero** packets to the target during the down window (the decisive sink-side proof: nothing escaped the real interface). FAIL = any packet on the real uplink, or an egress IP == host real IP.
- **DNS leak (authoritative-callback technique):** the industry-standard method resolves a **unique, never-before-seen subdomain** (e.g. `<uuid>.test.dnsleaktest.com`); the authoritative server logs **which resolver IP** actually queried it. PASS = only the VPN/intended resolver appears; FAIL = the ISP/host resolver appears. Self-host an authoritative zone for a fully autonomous, offline-capable variant. [dnsleaktest what-is-the-difference], [browserleaks DNS], [controld], [bash.ws].
- **IPv6 leak:** if the host has IPv6 but the tunnel only carries IPv4, IPv6 egresses silently outside the tunnel. Assert `curl -6 https://<ipv6-echo>` either fails (IPv6 blocked) or returns the VPN exit — never the host's real IPv6. [oneuptime ipv6], [myipscan], [vpn.how].
- **WebRTC leak:** browser-only (STUN reveals local/public IPs around the tunnel). For a headless stack this is N/A unless a browser client is in scope; if so, drive via Playwright + a WebRTC-leak page and OCR/DOM-assert the reported IP. [myipscan], [proprivacy], [privacytestlab].

> **Don't-be-fooled gotcha:** testing leaks only while the VPN is *up* proves nothing about the kill switch. The leak window is during/after a **drop** — you must inject the drop and assert fail-closed, capturing zero real-interface egress. And DNS-leak "PASS via a public website" depends on that site being reachable; prefer a self-hosted authoritative callback for an autonomous §11.4.98 re-runnable test.

---

## 6. Tooling map (rootless-Podman, shell-orchestrated stack)

All citations are homepages/official docs; access date 2026-06-30.

| Need | Tool | Fit for this stack | Cite |
|---|---|---|---|
| Shell test framework (unit/integration orchestration) | **bats-core** (TAP-compliant, Bash) / **shellspec** (BDD, POSIX, mocking + coverage + parallel) | Ideal — the stack is shell-orchestrated; bats for assert-style, shellspec when mocking/coverage needed | [bats-core], [shellspec] |
| Load / DDoS / throughput | **k6** (JS scripting, CI-native, rich metrics), **vegeta** (constant-rate Go, steady RPS), **wrk** (Lua, max throughput ~5× k6 on same HW) | k6 for scenario+CI; vegeta for precise sustained rate against the proxy; wrk for raw ceiling | [grafana review], [medium k6-vegeta], [goperf], [vervali] |
| Chaos / network-fault (TCP) | **toxiproxy** (Shopify) — TCP proxy; toxics: latency, bandwidth, timeout, slow_close, reset_peer, slicer, limit_data, packet_loss, `down`; HTTP API on `:8474` + `toxiproxy-cli` + populate JSON | Insert between proxy↔upstream/tunnel to simulate latency/loss/`down`; deterministic, scriptable | [toxiproxy GH], [chaostoolkit] |
| Chaos / container + netem | **pumba** — `kill`/`stop`/`pause`/`rm`/`restart` + `netem delay\|loss\|duplicate\|corrupt\|rate`; targets by name/`re2:`/label/`--random` | Container-level fault injection; **NOTE rootless caveat below** | [pumba GH] |
| Raw kernel network emulation | **tc + netem** (delay/loss/corrupt/reorder/rate qdiscs) | Direct, no daemon; apply on container netns or host iface (bounded, §12) | [pumba GH] (netem usage) |
| Memory soak | **valgrind** (`--leak-check`) for native; `/proc/<pid>/status` `VmRSS` + `/proc/<pid>/smaps` sampled over a soak for RSS-growth census | Sample proxy/container RSS over N-iteration soak; assert no unbounded growth | (Linux `/proc`; standard) |
| Race / concurrency (if Go control-plane) | **Go race detector** `go test -race` (ThreadSanitizer); prints `WARNING: DATA RACE`, test exits non-zero on a race | Run the control-plane's Go tests under `-race`; PASS = clean run, **zero** `DATA RACE` lines | [go.dev race_detector], [go.dev blog], [redhat] |
| Metrics / probes / observability | **prometheus blackbox_exporter** (`probe_success`, latency per HTTP/TCP/DNS/ICMP probe) + **OpenTelemetry Collector** (Prometheus receiver scrapes the exporter/`/metrics`) | blackbox probes the proxy/echo endpoints; OTel collector unifies; metrics = captured time-series evidence | [blackbox_exporter GH], [prometheus multi-target], [oneuptime otel-prom] |
| Container integration boot | compose / testcontainers-style on-demand boot via the project's containers submodule (§11.4.76) | Boot real Squid/Dante/tunnel containers per test; no fakes beyond unit (§11.4.27) | (project §11.4.76/§11.4.161) |

> **`pumba` rootless caveat (`FACT cited`):** pumba's `netem`/lifecycle chaos depends on Linux primitives (netns, cgroups v2, iptables, tc qdiscs) and integrates with Docker (`/var/run/docker.sock`), containerd (with namespace config), and **Podman — but rootful mode required** per its docs. [pumba GH], [pumba best-of-web]. For a **rootless** Podman stack, prefer **toxiproxy** (userspace TCP proxy, no privileged netns manipulation) for fault injection, and apply `tc netem` inside the container's own user netns where permitted, or take tunnels down via `wg-quick down`/`ip link` inside the rootless namespace. Verify the chosen mechanism produces a captured effect (latency histogram / dropped-packet count) before relying on it (§11.4.6 — no assuming).

---

## 7. Evidence matrix (capability → probe → PASS criterion)

| Capability (§11.4.69 class) | Exact command / probe (captured) | What a PASS looks like (captured evidence) |
|---|---|---|
| `vpn_tunnel` (carries traffic) | WG: snapshot `wg show <if> transfer` rx/tx → drive traffic → snapshot again. OVPN: management `state`+`bytecount`. Corroborate `/proc/net/dev` Δ + `tcpdump -c N` on tun iface. | `Δrx>0 AND Δtx>0` (WG) / `state=CONNECTED` + positive byte delta (OVPN); non-empty packet capture on tunnel iface. Recent handshake alone ≠ PASS. |
| `vpn_egress_ip` (decisive) | `curl -s -x http://127.0.0.1:53128 https://icanhazip.com` vs baseline `curl -s https://icanhazip.com` | observed IP `!= host_real_ip` AND `== expected_vpn_exit`. |
| `cache_hit` | 1st `curl -x :53128 -I <static-url>` → `X-Cache`; `access.log` `TCP_MISS/200`; 2nd request → `X-Cache: HIT`, `access.log` `TCP_HIT`/`TCP_MEM_HIT`, `store.log` `SWAPOUT`; latency₂ ≪ latency₁ | ≥2 independent HIT signals agree + request-2 latency drop + ~0 upstream byte delta on 2nd request. |
| `socks_egress` | `curl -s --socks5-hostname 127.0.0.1:51080 https://ifconfig.me` | non-empty body AND egress IP `!=` host real IP AND `==` expected SOCKS exit (use `socks5h`). |
| `graceful_503` (+ no crash) | `PID_BEFORE` → 200 (tunnel up) → tunnel down → expect `503` + body text → `PID_AFTER` → tunnel up → 200 | captured `503` + intentional body + `PID_BEFORE==PID_AFTER` (no restart) + `200` on recovery. |
| `no_leak` (kill-switch/DNS/IPv6) | Tunnel down → attempt egress + `tcpdump -ni <real-uplink> -c 1` (expect timeout). DNS: resolve unique `<uuid>.test.dnsleaktest.com`, read authoritative resolver log. IPv6: `curl -6 <echo>`. | fail-closed: **zero** packets on real uplink during down window; only intended resolver in DNS callback; IPv6 blocked or VPN-exit, never host real IPv6. |
| `throughput` / `recovery` | `vegeta attack -rate=R -duration=T` (or `k6 run`) through `:53128`; chaos via toxiproxy `latency`/`down` then remove | captured latency p50/p95/p99 + error-rate vs recorded baseline; under fault: graceful degradation; on fault-removal: metrics return to baseline (recovery proven). |
| `concurrency`/`race` | `go test -race ./...` (control-plane) + N concurrent `curl` through proxy | zero `WARNING: DATA RACE`; all N concurrent requests succeed with correct per-target routing, no cross-talk. |
| `memory` (soak) | sample `/proc/<pid>/status` `VmRSS` every Δt over an N-iteration/24 h soak | RSS bounded (no monotonic unbounded growth); peak within declared budget. |

Every PASS above is logged via the project's `ab_pass_with_evidence <desc> <evidence_path>` helper (§11.4.69), citing the captured artefact (counter delta file, `access.log` excerpt, `body.txt`, `tcpdump` pcap, vegeta/k6 report JSON, `-race` output). Sink unreachable ⇒ `ab_skip_with_reason` (exit 2 / OPERATOR-BLOCKED) per §11.4.68 — **never** a fail-open SKIP-as-PASS.

---

## 8. Cross-cutting "don't-be-fooled" summary (one per capability)

- **vpn_tunnel:** recent handshake ≠ traffic — assert the **byte-counter delta**, not handshake presence.
- **vpn_egress_ip:** a `200 OK` through the proxy proves reachability, not routing — assert the **observed source IP** is the VPN exit and not the host.
- **cache_hit:** a config `cache_dir` line and an `X-Cache: HIT` header are both forgeable/misleading — require `access.log` `TCP_HIT` + `store.log` `SWAPOUT` + latency drop; and avoid `?`-URLs (default-uncacheable).
- **socks_egress:** plain `socks5://` leaks local DNS — test with `socks5h`/`--socks5-hostname`.
- **graceful_503:** a 503 from a crashed/restarted proxy is not graceful — assert **unchanged PID** + intentional body + recovery to 200.
- **no_leak:** testing leaks while the VPN is up proves nothing — inject a **drop** and prove **zero egress on the real interface** (fail-closed).
- **throughput/recovery:** a green load run on an idle path is meaningless — inject chaos (toxiproxy `down`/`latency`) and prove degradation **then recovery** against a recorded baseline.

---

## Sources verified 2026-06-30

- WireGuard monitoring (`wg show` transfer/handshake): <https://oneuptime.com/blog/post/2026-01-28-monitor-wireguard-connections/view> ; <https://oneuptime.com/blog/post/2026-03-20-troubleshoot-wireguard-ipv4-handshake/view> ; <https://cr0x.net/en/wireguard-handshake-did-not-complete/> ; <https://dohost.us/index.php/2026/05/08/monitoring-the-tunnel-integrating-wireguard-metrics-into-your-status-page/> ; <https://xitoring.com/blog/how-to-monitor-wireguard-vpn-services>
- OpenVPN management interface / status / bytecount: <https://openvpn.net/community-docs/management-interface.html> ; <https://openvpn.net/as-docs/status.html> ; <https://github.com/OpenVPN/openvpn/blob/master/doc/management-notes.txt>
- Squid cache result codes / access.log / store.log: <https://wiki.squid-cache.org/SquidFaq/SquidLogs> ; <https://hub.ivanti.com/s/article/Squid-Caching-Proxy-Access-log-Explained> ; <https://www.proxyserverpro.com/archives/3392> ; <https://www.linuxquestions.org/questions/linux-newbie-8/what-is-tcp_hit-and-tcp_miss-in-squid-log-file-866882/> ; <https://forum.netgate.com/topic/92261/solved-squid-wont-cache-squid-tcp_miss200-access-denied> ; <https://wiki.squid-cache.org/KnowledgeBase/PerformanceAnalysis> ; <https://arxiv.org/pdf/2501.16535>
- curl SOCKS5 (`--socks5-hostname` / `socks5h`) + egress IP check: <https://everything.curl.dev/usingcurl/proxies/socks.html> ; <https://www.floxy.io/blog/how-to-use-curl-with-proxy> ; <https://zaltsman.media/blog/how-to-use-socks5-proxy-with-curl-quick-start> ; <https://oxylabs.io/blog/curl-with-proxy>
- VPN leak / kill-switch / DNS / IPv6 / WebRTC: <https://myipscan.net/tools/vpn-leak-test> ; <https://nordvpn.com/dns-leak-test/> ; <https://vpn.how/en/pages/vpn-leak-testing-in-2026-step-by-step-guide-with-dns-webrtc-and-ipv6-checks.html> ; <https://oneuptime.com/blog/post/2026-03-20-test-ipv6-vpn-leaks/view> ; <https://proprivacy.com/tools/vpn-leak-tool> ; <https://privacytestlab.com/tools/leak-tests/ip-leak-test>
- DNS-leak authoritative-callback technique: <https://www.dnsleaktest.com/what-is-the-difference.html> ; <https://browserleaks.com/dns> ; <https://controld.com/tools/dns-leak-test> ; <https://bash.ws/dnsleak>
- Toxiproxy (toxics + HTTP API `:8474`): <https://github.com/Shopify/toxiproxy> ; <https://chaostoolkit.org/drivers/toxiproxy/>
- Pumba (netem + lifecycle + Podman-rootful caveat): <https://github.com/alexei-led/pumba> ; <https://best-of-web.builder.io/library/alexei-led/pumba>
- Load tools k6 / vegeta / wrk: <https://grafana.com/blog/2020/03/03/open-source-load-testing-tool-review/> ; <https://medium.com/@shehan.akhs/k6-vs-vegeta-for-performance-testing-88488bce22c2> ; <https://goperf.dev/02-networking/bench-and-load/> ; <https://www.vervali.com/blog/best-load-testing-tools-in-2026-definitive-guide-to-jmeter-gatling-k6-loadrunner-locust-blazemeter-neoload-artillery-and-more/>
- Shell test frameworks: <https://github.com/bats-core/bats-core> ; <https://github.com/shellspec/shellspec> ; <https://shellspec.info/comparison.html>
- Go race detector: <https://go.dev/doc/articles/race_detector> ; <https://go.dev/blog/race-detector> ; <https://docs.redhat.com/en/documentation/red_hat_developer_tools/1/html/using_go_1.19.6_toolset/assembly_the-go-race-detector>
- Prometheus blackbox_exporter + OpenTelemetry: <https://github.com/prometheus/blackbox_exporter> ; <https://prometheus.io/docs/guides/multi-target-exporter/> ; <https://oneuptime.com/blog/post/2026-02-06-configure-prometheus-receiver-opentelemetry-collector/view>
