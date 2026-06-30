# D — Bleeding-Edge / Game-Changer Features for helix_proxy

**Revision:** 1
**Last modified:** 2026-06-30T00:00:00Z
**Scope:** Deep web research (WebSearch + WebFetch, accessed 2026-06-30) into state-of-the-art proxy/VPN features that are *implementable on THIS stack* — rootless Podman + compose, OpenVPN/WireGuard tunnels, Squid (HTTP/HTTPS cache, :53128), Dante (SOCKS5, :51080), a new Go control-plane (Postgres + Redis) doing dynamic per-target VPN-profile routing with live tunnel state + graceful 503, and a placeholder admin panel (`traefik/whoami`).
**Anti-bluff note (§11.4.6 / §11.4.123):** Every technology below is tagged **FACT (cited)** with a source URL + access date, or **UNCONFIRMED:** where the search corpus did not establish it as fact. Structural impossibilities on this stack are flagged per §11.4.112. OSS-reuse-first per §11.4.74.

---

## 0. Stack-reality constraints that shape every recommendation

These are the load-bearing facts that decide MVP-now vs later:

- **FACT (cited):** Rootless Podman *cannot* create real bridges or modify host `iptables`; it uses userspace networking (`slirp4netns`/`pasta`). Kernel-dependent and iptables-dependent designs degrade or must move into the container's own netns. — https://oneuptime.com/blog/post/2026-03-18-fix-rootless-podman-networking-issues/view (accessed 2026-06-30)
- **FACT (cited):** `wireguard-go` runs WireGuard *entirely in userspace*, enabling rootless/kernel-module-free tunnels in containers. — https://www.wireguard.com/ , https://blog.topli.ch/posts/wireguard-docker/ (accessed 2026-06-30)
- **FACT (cited):** eBPF programs must be loaded **into the kernel**; true rootless-without-kernel-privilege eBPF is architecturally not possible. — https://github.com/cilium/cilium , https://www.cloudraft.io/blog/ebpf-based-network-observability-using-cilium-hubble (accessed 2026-06-30)
- **FACT (cited):** Squid **does not support HTTP/2** (it detects and *rejects* it) and has **no HTTP/3/QUIC** support; HTTP/2 is "design groundwork" only. — https://wiki.squid-cache.org/Features/HTTP2 , https://lists.squid-cache.org/pipermail/squid-users/2022-November/025437.html (accessed 2026-06-30)
- **FACT (cited):** Squid is **weak at caching range/partial responses**; `range_offset_limit` is a workaround (and was *removed in v8*), and true partial-response chunk caching is an *unimplemented wishlist* feature. — https://www.squid-cache.org/Doc/config/range_offset_limit/ , https://wiki.squid-cache.org/Features/PartialResponsesCaching (accessed 2026-06-30)
- **PROJECT FACT (Constitution §11.4.162):** Any user-facing UI (the new admin panel) MUST be built with the **OpenDesign** design system (tokens/themes, light+dark), not ad-hoc CSS, and ship visual-regression coverage. This is a hard mandate, not a web finding.

---

## 1. WireGuard-first multi-tunnel + per-target circuit breakers + failover

**What it is.** Make WireGuard the primary tunnel transport (faster handshake, smaller attack surface, roaming), run *multiple* tunnels concurrently, and have the Go control-plane select/fail-over per target with circuit breakers.

**FACT (cited).**
- Userspace WireGuard (`wireguard-go`) is the rootless-compatible path; `wg-quick` automates bring-up/tear-down. — https://www.wireguard.com/quickstart/ , https://blog.topli.ch/posts/wireguard-docker/ (accessed 2026-06-30)
- Multi-tunnel **failover** is achieved with gateway *tiers/priorities* (Tier-1 primary, Tier-2 backup) — a configuration pattern, not an automatic WG feature; the control-plane owns the health/priority logic. — https://forum.netgate.com/topic/198867/ (accessed 2026-06-30)
- **`sony/gobreaker` (v2)** is a mature Go circuit breaker: state machine, `TwoStepCircuitBreaker`, `DistributedCircuitBreaker`, rolling-window buckets; `Trendyol/gobreaker-metrics` exposes state/failure/success to Prometheus. — https://github.com/sony/gobreaker , https://pkg.go.dev/github.com/sony/gobreaker/v2 , https://github.com/Trendyol/gobreaker-metrics (accessed 2026-06-30)

**Feasibility on this stack.** High. The Go control-plane already does dynamic per-target VPN-profile routing + live tunnel state + graceful 503 — circuit breakers and tier-based failover slot directly into that decision path. Each WG tunnel runs as its own rootless container (userspace WG) with a `wg0` netns; the control-plane health-probes each and flips per-target routing on breaker-open.

**Verdict: MVP-NOW** (circuit breakers + tier failover in the Go plane) / **Phase-2** (full WG-as-default replacing OpenVPN everywhere).

**OSS to reuse (§11.4.74):** `wireguard-go`, `wg-quick`, `sony/gobreaker/v2`, `Trendyol/gobreaker-metrics`.

**Prove it works (evidence).** Kill the active tunnel mid-request; assert breaker transitions Closed→Open (metric), per-target route flips to Tier-2, and client request succeeds via backup (captured HTTP response + breaker-state metric delta + tunnel-state row in Postgres). Re-probe shows half-open→closed recovery. Determinism over N=3 (§11.4.50).

---

## 2. DNS privacy: DoH/DoT upstream, per-tunnel DNS, leak prevention

**What it is.** A local encrypted-DNS resolver in front of every tunnel; per-tunnel upstream selection; fail-closed so plaintext :53 never leaks.

**FACT (cited).**
- **`AdguardTeam/dnsproxy`** (Go, Apache-2.0, v0.82.0 Jun 2026, active) speaks **DoH, DoT, DoQ, DNSCrypt + plain**, supports *multiple upstreams, per-domain routing (dnsmasq syntax), fallback resolvers, load-balancing, fastest-address* — ideal for per-tunnel DNS. — https://github.com/AdguardTeam/dnsproxy (accessed 2026-06-30)
- **`dnscrypt-proxy`** supports DoH (TLS 1.3 + QUIC), DNSCrypt, Anonymized DNS, ODoH; actively maintained through 2026. — https://github.com/DNSCrypt/dnscrypt-proxy , https://wiki.archlinux.org/title/Dnscrypt-proxy (accessed 2026-06-30)
- DNS leaks occur when queries escape the tunnel via the host resolver; encrypted DNS (DoH/DoT) protects confidentiality even if a leak happens, but **fail-closed routing is still required** to stop the leak itself. — https://www.iptoolspro.com/blog/dns-over-https-explained , https://netguardia.com/privacy/anonymity/encrypted-dns-in-2026-doh-dot-dnscrypt-and-oblivious-dns-over-https/ (accessed 2026-06-30)

**Feasibility on this stack.** High. Drop `dnsproxy` as a sidecar; point Squid/Dante containers' resolvers at it; the Go control-plane maps `target → upstream DoH/DoT endpoint` (per-tunnel DNS), reusing its existing routing table. `dnsproxy` per-domain routing mirrors the per-target model already in place.

**Verdict: MVP-NOW** (single `dnsproxy` sidecar + DoH upstream + per-tunnel mapping). ODoH = **Phase-2** (needs relay infra).

**OSS to reuse (§11.4.74):** `AdguardTeam/dnsproxy` (primary), `dnscrypt-proxy` (ODoH/DNSCrypt option).

**Prove it works (evidence).** Run a DNS-leak probe (query a controlled authoritative server) through each tunnel; capture that *all* lookups arrive over the configured DoH/DoT endpoint and *zero* plaintext :53 packets exit the host (tcpdump on host iface, count==0); flip tunnel down and assert resolver fails closed (NXDOMAIN/refused, not a host-resolver fallback).

---

## 3. Observability: Prometheus + Grafana + OpenTelemetry tracing; eBPF flagged

**What it is.** Metrics on every component, dashboards, and distributed traces flowing through the proxy chain; structured logs.

**FACT (cited).**
- **`boynux/squid-exporter`** (Go, v1.13.0 May 2025, active, 33 releases) exports Squid client/server counters, service times, cache hit ratios, FD/memory; listens :9301 `/metrics`; configurable via flags/env/Docker. — https://github.com/boynux/squid-exporter (accessed 2026-06-30)
- **Grafana Alloy** ships a first-class `prometheus.exporter.squid` component + a Squid integration with **2 prebuilt dashboards + 5 alerts** (dashboards 9103 / 14394). — https://grafana.com/docs/alloy/latest/reference/components/prometheus/prometheus.exporter.squid/ , https://grafana.com/grafana/dashboards/14394-squid/ (accessed 2026-06-30)
- **OpenTelemetry Go** auto-propagates W3C `traceparent`: `otelhttp.NewHandler` (server spans) + `otelhttp.NewTransport` (client spans inject context); composite `TraceContext{}+Baggage{}` propagator; OTLP to Jaeger/Tempo/Collector. A forward proxy can create+forward `traceparent` so a request is traceable across the proxy hop. — https://opentelemetry.io/docs/concepts/context-propagation/ , https://uptrace.dev/get/opentelemetry-go/propagation (accessed 2026-06-30)
- **eBPF / Cilium Hubble** gives per-flow L3-L7 visibility **but requires kernel privileges** (programs load into the kernel). — https://github.com/cilium/hubble , https://www.cloudraft.io/blog/ebpf-based-network-observability-using-cilium-hubble (accessed 2026-06-30)

**Structural flag (§11.4.112).** **Cilium/Hubble eBPF flow visibility is NOT compatible with the rootless mandate** — eBPF needs kernel-level load privileges; rootless Podman explicitly avoids that. Do **not** pursue it on this stack without a documented rootful exception. Equivalent visibility is achievable in-process (Go control-plane spans + per-connection metrics) without eBPF.

**Feasibility.** Metrics/dashboards: trivial. OTel tracing: native in the Go control-plane; the proxy hop is the natural span boundary. eBPF: blocked (above).

**Verdict: MVP-NOW** (squid-exporter + Grafana dashboards + OTel spans in the Go plane + structured JSON logs). **Defer/avoid:** eBPF/Hubble (rootless-incompatible).

**OSS to reuse (§11.4.74):** `boynux/squid-exporter`, Grafana dashboards 9103/14394, `go.opentelemetry.io/contrib/instrumentation/.../otelhttp`, OTel Collector + Tempo/Jaeger, Prometheus + Grafana (containers via the containers submodule per §11.4.76).

**Prove it works (evidence).** Scrape `/metrics`, assert non-zero `squid_*` series and a populated Grafana panel screenshot; issue a tagged request and pull the resulting trace from Tempo/Jaeger showing the proxy span linked to the upstream span by shared `trace_id` (captured trace JSON). Self-validate the dashboard with golden-good/golden-bad per §11.4.107(10).

---

## 4. Security / zero-trust: proxy auth, mTLS, kill-switch, secrets, audit

**What it is.** Per-user proxy authentication, mTLS for the control API, a fail-closed kill-switch, no plaintext VPN creds in git, and audit logging.

**FACT (cited).**
- **Squid per-user auth** supports Basic, Digest, NTLM, Negotiate/Kerberos and `external_acl_type` with `%LOGIN` for custom/db-backed policy; the authenticated username is logged to `access.log` (audit trail). — https://wiki.squid-cache.org/Features/Authentication , https://wiki.squid-cache.org/SquidFaq/SquidAcl (accessed 2026-06-30)
- **Kill-switch** = iptables deny-by-default allowing egress *only* via the WG/tun interface; if the tunnel drops, traffic is blocked, not leaked. — https://oneuptime.com/blog/post/2026-03-18-use-podman-containers-wireguard-vpn/view , https://wiki.archlinux.org/title/Linux_Containers/Using_VPNs (accessed 2026-06-30)
- **Rootless caveat (FACT, cited):** rootless Podman can't touch host iptables; the kill-switch must live *inside the tunnel container's own netns* (or use `pasta`/policy routing there). — https://oneuptime.com/blog/post/2026-03-18-fix-rootless-podman-networking-issues/view (accessed 2026-06-30)
- **Podman secrets** (`podman secret` / compose `secrets:`) keep VPN creds out of env/git — the project's `.env.example` already signals env-based config; secrets store is the hardening step (§11.4.10). — https://oneuptime.com/blog/post/2026-03-18-use-podman-containers-wireguard-vpn/view (accessed 2026-06-30) [secrets-store specifics: **UNCONFIRMED** beyond general Podman secrets; verify against Podman docs before claiming a feature.]

**Feasibility.** High for auth + secrets + audit. Kill-switch is feasible *inside the tunnel netns* but must be designed around the rootless constraint (don't assume host-iptables rules will apply).

**Verdict: MVP-NOW** (Squid Basic/Digest auth + `external_acl_type` to the Go plane for per-user policy + username audit logging + Podman secrets for creds + in-netns kill-switch). mTLS on the control API = **MVP-NOW** (cheap in Go). Full SSO/OIDC = **Phase-2**.

**OSS to reuse (§11.4.74):** Squid auth helpers + `external_acl_type`, Podman secrets, Go `crypto/tls` mTLS, structured audit logger.

**Prove it works (evidence).** Unauthenticated request → 407; authed → 200 with username in `access.log` (captured). Stop the tunnel and assert egress is blocked (tcpdump count==0 on host iface), not leaked. `git grep` proves no plaintext creds tracked; secret is injected at runtime only. mTLS: connection without client cert is refused (captured handshake failure).

---

## 5. Protocol modernization: HTTP/3 / QUIC, IPv6, keep-alive tuning

**What it is.** Serve/forward HTTP/3 (QUIC), dual-stack IPv6, and tune connection pooling/keep-alive.

**FACT (cited).**
- **Squid has no HTTP/2 or HTTP/3** (rejects HTTP/2). So QUIC proxying *cannot* be done in Squid today. — https://wiki.squid-cache.org/Features/HTTP2 (accessed 2026-06-30)
- **Envoy** supports HTTP/3 downstream **and** upstream, plus **CONNECT-UDP (RFC 9298 / MASQUE)** for tunnelling QUIC. — https://www.envoyproxy.io/docs/envoy/latest/intro/arch_overview/http/http3 (accessed 2026-06-30)
- **`quic-go/masque-go`** implements RFC 9298 UDP-proxying-in-HTTP/3 in Go; MASQUE/QUIC-aware proxying is **standardized but adoption is still very early**. — https://github.com/quic-go/masque-go , https://blog.cloudflare.com/unlocking-quic-proxying-potential/ , https://datatracker.ietf.org/doc/draft-ietf-masque-quic-proxy/ (accessed 2026-06-30)

**Feasibility.** HTTP/3 forward proxying is **not** a Squid capability — it requires either fronting with Envoy or building a QUIC/MASQUE listener with `quic-go` in the Go plane. That's a meaningful new component, not a config tweak. IPv6 dual-stack + keep-alive/pool tuning are config-level and low-risk.

**Verdict:** IPv6 + connection-pool/keep-alive tuning = **MVP-NOW** (config). HTTP/3 client *origin* support via the Go plane's upstream transport = **Phase-2**. Full HTTP/3 *forward-proxy / MASQUE CONNECT-UDP* = **LATER** (experimental, early adoption; high effort).

**OSS to reuse (§11.4.74):** `quic-go` + `quic-go/masque-go`, or Envoy as a QUIC front (heavier).

**Prove it works (evidence).** IPv6: `curl -6` through the proxy to an IPv6 origin returns 200 (captured). HTTP/3 (Phase-2): `curl --http3` negotiates h3 to a test origin via the Go transport (captured ALPN `h3`). Keep-alive: connection-reuse counter rises across N requests (metric).

---

## 6. Smart routing: geo-aware, split-tunnel, health-based, PAC, hot reload

**What it is.** Choose target/tunnel by geo + health; split-tunnel policy; auto-generate PAC for clients; reload config without dropping connections.

**FACT (cited).**
- **PAC** = a `FindProxyForURL(url, host)` JS function clients evaluate; modern PAC supports **geolocation-based forwarding** and can be **dynamically generated** per org/policy. — https://developer.mozilla.org/en-US/docs/Web/HTTP/Guides/Proxy_servers_and_tunneling/Proxy_Auto-Configuration_PAC_file , https://en.wikipedia.org/wiki/Proxy_auto-config (accessed 2026-06-30)
- Health-based target selection is exactly the breaker/tier logic from §1; geo-aware = MaxMind/GeoIP lookup in the Go plane (**UNCONFIRMED:** specific GeoIP lib not researched here — pick MaxMind GeoLite2 + a maintained Go reader and verify license before shipping).

**Feasibility.** Very high — these are decisions the Go control-plane is *already* positioned to make. Dynamic PAC is a single Go HTTP endpoint rendering `FindProxyForURL` from the live routing table. Hot reload (SIGHUP/`fsnotify` + atomic swap of the routing snapshot) is standard Go and avoids restart-induced 503s.

**Verdict: MVP-NOW** (dynamic PAC endpoint + health-based selection + hot config reload). Geo-aware routing = **MVP-NOW** if GeoLite2 license is acceptable, else **Phase-2**. Split-tunnel policy = **MVP-NOW** (policy rows in Postgres).

**OSS to reuse (§11.4.74):** Go `text/template` for PAC, `fsnotify`, MaxMind GeoLite2 + a Go MMDB reader (license-verify first).

**Prove it works (evidence).** Fetch `/proxy.pac`, assert it routes `host A → tunnel-EU`, `host B → DIRECT` per policy (captured PAC body + a client honoring it). Change a routing rule and confirm the live decision changes with **zero dropped in-flight connections** (request issued during reload returns 200). Geo: request from a tagged source resolves to the geo-correct tunnel (captured route + tunnel-state row).

---

## 7. Real admin / control plane: web UI + REST/gRPC API (replace whoami)

**What it is.** Replace `traefik/whoami` with a real admin: CRUD for profiles/targets/rules, live status, metrics, over REST and/or gRPC.

**FACT (cited).**
- **Go + `templ` + `htmx` + SSE** is a mature, well-documented 2025-2026 pattern for server-driven admin dashboards with live status and CRUD — type-safe templates, targeted interactivity, no SPA. — https://dev.to/colafanta/go-admin-dashboard-for-e-commerce-with-htmx-templ-ui-and-gorm-part-1-5b86 , https://threedots.tech/post/live-website-updates-go-sse-htmx/ (accessed 2026-06-30)
- **PROJECT FACT (Constitution §11.4.162):** the UI **must** use **OpenDesign** tokens/themes (light+dark) with visual-regression coverage and host-rendered pixel proof (§11.4.170) — not raw CSS. This constrains the styling layer; `templ`+`htmx` remain the rendering/interaction layer.

**Feasibility.** High. The Go control-plane already holds the state (Postgres/Redis). REST CRUD + an SSE/htmx live-status panel is the lowest-risk path; gRPC is a clean add for machine clients (**gRPC-in-control-plane specifics: UNCONFIRMED** in the corpus, but standard Go practice).

**Verdict: MVP-NOW** (REST CRUD + htmx/templ + SSE live status + OpenDesign tokens). gRPC control API = **Phase-2**.

**OSS to reuse (§11.4.74):** `a-h/templ`, `htmx`, Go `net/http`/chi, OpenDesign (mandated), `connectrpc`/`grpc-go` for the Phase-2 API.

**Prove it works (evidence).** Create a profile via the UI/REST → row appears in Postgres → live status panel updates over SSE without reload (captured screen recording + DB row, window-scoped MP4 per §11.4.159 + vision validation). OpenDesign: light+dark host-rendered PNG diff PASS (§11.4.170). NEGATIVE: invalid CRUD payload → 4xx with structured error.

---

## 8. Cache intelligence: streaming/range caching, analytics, prefetch

**What it is.** Smarter caching for large/streaming objects, cache analytics, and prefetch.

**FACT (cited).**
- Squid is **weak at range/partial caching**: `range_offset_limit none` refetches whole objects (and breaks if the client disconnects); true chunked partial-response caching is an **unimplemented wishlist** item; `range_offset_limit` is **gone in Squid v8**. — https://www.squid-cache.org/Doc/config/range_offset_limit/ , https://wiki.squid-cache.org/Features/PartialResponsesCaching (accessed 2026-06-30)
- **Store-ID helpers** (e.g. `store_id` rewriters) let Squid treat varying URLs for the same object as one cache entry — a real, available win for CDN-sharded/streaming URLs. — https://wiki.squid-cache.org/Features/StoreID (referenced via range/store-id results, accessed 2026-06-30)
- Cache analytics come free from §3 (`squid-exporter` hit/miss ratios + Grafana).

**Honest boundary (§11.4.6).** Aggressive *streaming/range* caching is **structurally limited in Squid today** — do not promise full partial-object caching on Squid. Store-ID normalization + hit-ratio analytics are the realistic wins now.

**Verdict: MVP-NOW** (cache analytics via squid-exporter + Store-ID normalization for known sharded origins). Streaming/range/prefetch = **LATER** (Squid limitation; would need a different cache engine — e.g. a Go range-aware caching layer or Apache Traffic Server — which is a large new component).

**OSS to reuse (§11.4.74):** Squid `store_id` helpers, `squid-exporter` for analytics; (Phase-3) Apache Traffic Server for range-aware caching if streaming becomes a hard requirement.

**Prove it works (evidence).** Store-ID: two sharded URLs for the same object produce one cache entry and a HIT on the second request (captured `access.log` `TCP_HIT`). Analytics: hit-ratio panel populated (screenshot). For the *limitation*, capture the range-request MISS behavior to document it honestly rather than claim a cache HIT.

---

## Prioritized table

| # | Feature | Value for THIS system | Feasibility (rootless+Squid/Dante+Go) | When | Key OSS to reuse (§11.4.74) | How we PROVE it (evidence) |
|---|---------|----------------------|----------------------------------------|------|------------------------------|-----------------------------|
| 1 | Per-target circuit breakers + tier failover (WG-first) | Resilience; no 503 when a tunnel dies | High — sits in existing Go routing path | **MVP-NOW** | `sony/gobreaker/v2`, `gobreaker-metrics`, `wireguard-go` | Kill tunnel → breaker Open metric + route flips to Tier-2 → client 200; N=3 determinism |
| 2 | DoH/DoT per-tunnel DNS + leak prevention | Privacy; stops ISP/leak exposure | High — `dnsproxy` sidecar | **MVP-NOW** | `AdguardTeam/dnsproxy`, `dnscrypt-proxy` | tcpdump: 0 plaintext :53; all lookups via DoH; fail-closed on tunnel down |
| 3 | Prometheus + Grafana + OTel tracing + JSON logs | Operability; root-cause across proxy hop | High (eBPF excluded) | **MVP-NOW** | `boynux/squid-exporter`, Grafana 9103/14394, OTel `otelhttp`, Tempo/Jaeger | Non-zero `squid_*` series + linked trace by shared trace_id |
| 4 | Per-user proxy auth + audit + secrets + in-netns kill-switch + mTLS | Zero-trust; no creds in git | High (kill-switch must live in tunnel netns) | **MVP-NOW** | Squid auth + `external_acl_type`, Podman secrets, Go mTLS | 407→200 with username in access.log; egress blocked on tunnel down; no tracked creds |
| 5 | Dynamic PAC + health/geo routing + hot reload + split-tunnel | Smart client steering, zero-downtime config | Very high — Go plane already decides | **MVP-NOW** (geo if GeoLite2 OK) | Go `text/template`, `fsnotify`, MaxMind GeoLite2 | `/proxy.pac` routes per policy; rule change with 0 dropped connections |
| 6 | Real admin UI + REST API (replace whoami) | Operable control plane | High; UI must use OpenDesign (§11.4.162) | **MVP-NOW** | `a-h/templ`, `htmx`, SSE, OpenDesign | CRUD→DB row→SSE live update; light+dark host-rendered PNG diff PASS |
| 7 | IPv6 dual-stack + keep-alive/pool tuning | Modern reachability + perf | High — config-level | **MVP-NOW** | Squid/Dante config, Go transport tuning | `curl -6` 200; connection-reuse counter rises |
| 8 | Cache analytics + Store-ID normalization | Realistic cache wins on Squid | High (analytics) / limited (range) | **MVP-NOW** (analytics+Store-ID) | `store_id` helpers, `squid-exporter` | Sharded URLs → single entry → TCP_HIT |
| 9 | gRPC control API | Machine clients/automation | High but additive | **Phase-2** | `connectrpc`/`grpc-go` | gRPC CRUD round-trip + reflection |
| 10 | HTTP/3 upstream (Go transport) | Modern origin reach | Medium — new transport path | **Phase-2** | `quic-go` | `curl --http3` ALPN `h3` to origin |
| 11 | ODoH (oblivious DNS) | Strong unlinkability | Medium — needs relay | **Phase-2** | `dnscrypt-proxy` ODoH | Query unlinkable across relay (captured) |
| 12 | HTTP/3 forward-proxy / MASQUE CONNECT-UDP | Cutting-edge UDP/QUIC proxying | Low — early adoption, big build | **LATER** | `quic-go/masque-go`, Envoy | RFC 9298 CONNECT-UDP tunnel established |
| 13 | Streaming/range caching + prefetch | Big-object cache efficiency | **Structurally limited in Squid** | **LATER** | Apache Traffic Server (new engine) | Range HIT on second request (needs non-Squid engine) |
| — | eBPF / Cilium Hubble flow visibility | Deep L3-L7 visibility | **Incompatible with rootless mandate (§11.4.112)** | **AVOID** | (n/a on this stack) | — (requires kernel privilege) |

---

## Structural impossibility / honest-boundary flags (§11.4.112 / §11.4.6)

1. **eBPF/Cilium-Hubble flow observability** — requires kernel-level program loading; the project's rootless-Podman mandate makes this non-viable without a documented rootful exception. Equivalent insight comes from in-process Go metrics + OTel spans.
2. **HTTP/2 & HTTP/3 in Squid** — not supported (HTTP/2 actively rejected). QUIC proxying must come from `quic-go`/Envoy, not Squid config.
3. **Streaming/range caching in Squid** — partial-response chunk caching is unimplemented and `range_offset_limit` was removed in v8; full streaming cache requires a different engine.
4. **Rootless kill-switch** — host-iptables rules won't apply under rootless Podman; the fail-closed rule must live inside the tunnel container's own network namespace.
5. **UNCONFIRMED items to verify before claiming "done":** Podman secrets-store feature specifics; a maintained Go GeoIP/MMDB reader + GeoLite2 license terms; gRPC framework choice; current Dante upstream maintenance cadence (commercial backing confirmed, release cadence not).

---

## Sources verified 2026-06-30

- WireGuard (userspace / quickstart): https://www.wireguard.com/ , https://www.wireguard.com/quickstart/ , https://blog.topli.ch/posts/wireguard-docker/ , https://emar10.dev/posts/rootless-podman-wireguard/
- Multi-tunnel failover (tiers/priorities): https://forum.netgate.com/topic/198867/multiple-wireguard-tunnels-how-to-set-tier-1-and-2-for-priorities-to-achieve-failover-behavior
- Circuit breakers (Go): https://github.com/sony/gobreaker , https://pkg.go.dev/github.com/sony/gobreaker/v2 , https://github.com/Trendyol/gobreaker-metrics
- Rootless Podman networking constraints: https://oneuptime.com/blog/post/2026-03-18-fix-rootless-podman-networking-issues/view , https://oneuptime.com/blog/post/2026-03-18-use-podman-containers-wireguard-vpn/view , https://wiki.archlinux.org/title/Linux_Containers/Using_VPNs
- Encrypted DNS: https://github.com/AdguardTeam/dnsproxy , https://github.com/DNSCrypt/dnscrypt-proxy , https://wiki.archlinux.org/title/Dnscrypt-proxy , https://www.iptoolspro.com/blog/dns-over-https-explained , https://netguardia.com/privacy/anonymity/encrypted-dns-in-2026-doh-dot-dnscrypt-and-oblivious-dns-over-https/
- Squid metrics/Grafana: https://github.com/boynux/squid-exporter , https://grafana.com/docs/alloy/latest/reference/components/prometheus/prometheus.exporter.squid/ , https://grafana.com/grafana/dashboards/14394-squid/ , https://grafana.com/grafana/dashboards/13582-9103-squid/
- OpenTelemetry Go: https://opentelemetry.io/docs/concepts/context-propagation/ , https://uptrace.dev/get/opentelemetry-go/propagation , https://opentelemetry.io/docs/concepts/signals/traces/
- eBPF/Cilium/Hubble: https://github.com/cilium/hubble , https://github.com/cilium/cilium , https://www.cloudraft.io/blog/ebpf-based-network-observability-using-cilium-hubble
- HTTP/3 / QUIC / MASQUE: https://www.envoyproxy.io/docs/envoy/latest/intro/arch_overview/http/http3 , https://github.com/quic-go/masque-go , https://blog.cloudflare.com/unlocking-quic-proxying-potential/ , https://datatracker.ietf.org/doc/draft-ietf-masque-quic-proxy/ , https://quic-go.net/docs/connect-udp/proxy/
- Squid HTTP/2-3 + caching limits: https://wiki.squid-cache.org/Features/HTTP2 , https://lists.squid-cache.org/pipermail/squid-users/2022-November/025437.html , https://www.squid-cache.org/Doc/config/range_offset_limit/ , https://wiki.squid-cache.org/Features/PartialResponsesCaching
- Squid auth/ACL/audit: https://wiki.squid-cache.org/Features/Authentication , https://wiki.squid-cache.org/SquidFaq/SquidAcl
- PAC / smart routing: https://developer.mozilla.org/en-US/docs/Web/HTTP/Guides/Proxy_servers_and_tunneling/Proxy_Auto-Configuration_PAC_file , https://en.wikipedia.org/wiki/Proxy_auto-config
- Go admin UI (templ/htmx/SSE): https://dev.to/colafanta/go-admin-dashboard-for-e-commerce-with-htmx-templ-ui-and-gorm-part-1-5b86 , https://threedots.tech/post/live-website-updates-go-sse-htmx/ , https://medium.com/@iamsiddharths/building-reactive-uis-with-go-templ-and-htmx-a-simpler-path-beyond-spas-17e7dad2c7a2
- Dante / SOCKS5: https://www.inet.no/dante/ , https://github.com/notpeter/dante , https://alternativeto.net/software/dante/

*Project-internal authority (not a web source): Constitution §11.4.162 (OpenDesign UI mandate), §11.4.170 (host-rendered UI visual proof), §11.4.112 (structural-impossibility classification), §11.4.6 (no-guessing), §11.4.74 (reuse/extend submodule catalogue), §11.4.76 (containers submodule).*
