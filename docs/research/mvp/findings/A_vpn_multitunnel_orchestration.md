# A — Multi-Tunnel VPN Orchestration: Deep Research Findings

**Revision:** 1
**Last modified:** 2026-06-30T00:00:00Z
**Scope:** Grounds the `helix_proxy` dynamic control-plane (route specific upstream
targets through specific VPN profiles, live per-tunnel state, graceful 503 on
tunnel-down, multiple concurrent tunnels).
**Authority discipline:** Every non-trivial claim is tagged `FACT (cited)` with a
source URL, or `UNCONFIRMED:` / `UNKNOWN:` where it could not be verified
(Constitution §11.4.6 — no guessing). Access date for all URLs: **2026-06-30**.

> Honest boundary (§11.4.6): web-secondary sources establish protocol behaviour,
> tool capabilities, and documented APIs. They do NOT substitute for a runtime
> spike against our own stack — every adoption claim below must still be proven
> by captured evidence in implementation (§11.4.69 / §11.4.108) before it is
> called "working".

---

## 1. WireGuard vs OpenVPN for multi-tunnel

### 1.1 Implementation model
- `FACT (cited)` WireGuard runs as an **in-kernel** module on Linux; packet
  processing happens in kernel space, avoiding kernel↔userspace boundary
  crossings. OpenVPN runs as a **userspace daemon**, so each packet crosses the
  kernel/userspace boundary (at least twice per round trip).
  — https://contabo.com/blog/wireguard-vs-openvpn-a-deep-dive-protocol-comparison/ ;
  https://cyberinsider.com/vpn/wireguard/wireguard-vs-openvpn/
- `FACT (cited)` WireGuard's codebase is ~4,000 lines vs OpenVPN's hundreds of
  thousands — far smaller audit surface.
  — https://cyberinsider.com/vpn/wireguard/wireguard-vs-openvpn/

### 1.2 Throughput
- `FACT (cited)` Multiple independent comparisons (2026) report WireGuard at
  **2–4× the throughput** of OpenVPN on the same hardware, with lower CPU per
  packet and lower latency — the gap widens on resource-constrained hosts.
  — https://routerhax.com/wireguard-vs-openvpn/ ;
  https://myipaddress.app/blog/wireguard-vs-openvpn-throughput-benchmark
- Relevance to us: with **many concurrent tunnels** on one host, per-packet CPU
  cost is the limiting factor. Kernel WireGuard's lower per-packet overhead is
  the dominant reason to prefer it for N-tunnel fan-out.

### 1.3 Userspace WireGuard (`wireguard-go`, `boringtun`)
- `FACT (cited)` `wireguard-go` — the **only compliant** userspace reference
  implementation — is **MIT licensed**, but "falls very short of the performance
  offered by the kernel module."
  — https://sourceforge.net/projects/wireguard-go.mirror/ ;
  https://news.ycombinator.com/item?id=19500725
- `FACT (cited)` `boringtun` (Cloudflare, Rust) is **BSD-3-Clause licensed**,
  deployed on millions of iOS/Android devices + thousands of Cloudflare Linux
  servers; original form is slow but a lightly-modified fork approaches kernel
  single-core performance.
  — https://github.com/cloudflare/boringtun ;
  https://blog.cloudflare.com/boringtun-userspace-wireguard-rust/
- `UNCONFIRMED:` exact ceiling for "N userspace tunnels on one host." Userspace
  is the fallback only when the kernel module is unavailable (e.g. a restrictive
  rootless container without `/dev/net/tun`+kernel wg, or non-Linux).

### 1.4 Verdict for §1
- **Prefer kernel WireGuard** for the multi-tunnel data plane: smaller attack
  surface, 2–4× throughput, lower per-tunnel CPU (critical at N tunnels), and a
  clean `wg show` health signal (§4). Keep **OpenVPN as a compatibility tunnel
  type** because many providers/configs are OpenVPN-only and our current image
  (`dperson/openvpn-client`) already speaks it. Userspace WireGuard
  (`wireguard-go`/`boringtun`) is the **fallback** when kernel wg is
  unavailable under rootless Podman.

> Caveat (§11.4.133 / rootless §11.4.161): kernel WireGuard inside a **rootless**
> Podman container needs the `wireguard` kernel module loaded on the host and
> appropriate `NET_ADMIN`/`/dev/net/tun` access. `UNCONFIRMED:` whether our
> rootless target grants kernel-wg netns creation without elevation — MUST be
> spiked. If it doesn't, gluetun's userspace WireGuard path (§3) is the escape.

---

## 2. Network-namespace-per-tunnel + policy routing

### 2.1 The canonical WireGuard netns pattern (authoritative)
- `FACT (cited)` From the official WireGuard docs: a wg interface can be created
  in one namespace and **moved** to another with
  `ip link set wg0 netns <ns>`, and crucially **"the UDP socket always lives in
  namespace A"** (its creation namespace). So the *encrypted* packets egress via
  namespace A's physical NIC while the *cleartext* `wg0` interface lives in the
  container namespace.
  — https://www.wireguard.com/netns/
- `FACT (cited)` Container pattern (verbatim shape): `ip link add wg0 type wireguard`
  → `ip link set wg0 netns container`; the container can then reach the network
  **only** through `wg0`. This is a per-tunnel network-namespace isolation
  primitive — exactly the "one netns per tunnel" model we need.
  — https://www.wireguard.com/netns/

### 2.2 Policy routing / fwmark (avoid loops, pick a tunnel)
- `FACT (cited)` WireGuard sets an `fwmark` on its own encrypted UDP egress so
  those packets are exempt from the tunnel default route; canonical commands:
  `wg set wg0 fwmark 1234`, `ip route add default dev wg0 table 2468`,
  `ip rule add not fwmark 1234 table 2468`. wg-quick full-tunnel uses fwmark
  `51820`. — https://www.wireguard.com/netns/ ;
  https://wiki.archlinux.org/title/WireGuard
- `FACT (cited)` Multiple tunnels are isolated by giving each its own
  `fwmark` + dedicated routing table, so packets destined for different tunnels
  go to different tables; "complex setups can utilize multiple WireGuard
  containers to achieve split tunneling so connections can be sent through
  different VPN tunnels."
  — https://www.linuxserver.io/blog/advanced-wireguard-container-routing ;
  https://docs.opnsense.org/manual/how-tos/wireguard-selective-routing.html

### 2.3 How a forward-proxy selects the egress tunnel
There are two production-proven strategies; both are viable for us:
- **(A) Namespace-per-tunnel + proxy-per-namespace (our current shape).** Run one
  Squid/Dante instance *inside each tunnel's netns* (the existing
  `network_mode: service:<vpn-container>` pattern, one VPN container per tunnel).
  Tunnel selection becomes **"which proxy port the request hits"** — the
  control-plane maps a target host → the proxy bound to that tunnel's namespace.
  This is the lowest-risk extension of today's compose and matches the WireGuard
  netns doc directly (§2.1). `FACT (cited)` netns isolation primitive exists.
- **(B) Single proxy + policy routing by fwmark.** One proxy in the init
  namespace; an `iptables`/`nft` rule (or `SO_MARK` set by the proxy per
  connection) marks the connection, and `ip rule`/`ip route` tables steer it to
  the chosen `wg`/tun interface. More elegant for many tunnels, but requires the
  proxy to set per-connection marks and is more error-prone.
  `UNCONFIRMED:` Squid's native ability to set per-request `SO_MARK` to choose a
  routing table — Squid has `tcp_outgoing_mark`/`mark_client_packet`/
  `tcp_outgoing_address` directives but their exact behaviour for tunnel
  selection must be spiked before relying on it.

### 2.4 Kill-switch / firewall-on-down
- `FACT (cited)` The standard pattern is `iptables`/`nft` default-DROP egress
  except the encrypted VPN endpoint + LAN, so when a tunnel drops, connected
  clients lose all egress instead of leaking to the clear net. gluetun
  implements exactly this with iptables.
  — (gluetun) https://www.simplehomelab.com/gluetun-docker-guide/ ;
  https://corelab.tech/setup-gluetun/
- For our 503-on-down requirement: the kill-switch prevents **leaks**, but the
  *graceful 503* is an **application-layer** behaviour our proxy/control-plane
  must add (the kill-switch just drops packets → clients would hang/time out,
  not get a clean 503). See §4 + §5.

---

## 3. Reusable OSS to adopt (extend-don't-reimplement, §11.4.74)

### 3.1 gluetun (`qmcgaw/gluetun`) — DEEP EVALUATION
- `FACT (cited)` **License: MIT.** Maturity: ~14.7k stars, 594 forks, 77
  releases, active development. — https://github.com/qdm12/gluetun
- `FACT (cited)` **Multiple providers** (AirVPN, Cyberghost, ExpressVPN,
  IPVanish, IVPN, Mullvad [wg-only], NordVPN, PIA, ProtonVPN, Surfshark,
  Windscribe, etc.) **and both protocols** — OpenVPN (all listed providers) +
  WireGuard (**kernelspace and userspace**).
  — https://github.com/qdm12/gluetun
- `FACT (cited)` **Built-in firewall kill-switch** ("allow traffic only with the
  needed VPN servers and LAN devices") + **DNS over TLS** + built-in **HTTP,
  SOCKS5, Shadowsocks** proxy servers.
  — https://github.com/qdm12/gluetun ;
  https://www.simplehomelab.com/gluetun-docker-guide/
- `FACT (cited)` **One tunnel per container** — each gluetun container is a
  single VPN tunnel instance; **run multiple containers for multiple tunnels**
  (the documentation supports this). This maps 1:1 onto our
  "one VPN profile = one container/netns" model.
  — https://github.com/qdm12/gluetun
- `FACT (cited)` **HTTP control server on port 8000** with a real REST API
  (auth: `none`/`apikey` via `X-API-Key`/`basic`, v3.39.1+; configured via
  `/gluetun/auth/config.toml` or `HTTP_CONTROL_SERVER_AUTH_*`):
  - `GET /v1/vpn/status` → `{"status":"running"}`; **`PUT /v1/vpn/status`** with
    `{"status":"running"|"stopped"}` to start/stop the tunnel at runtime.
  - `GET /v1/publicip/ip` → current public egress IP (an egress-IP health signal).
  - `GET/PUT /v1/portforward`, `GET/PUT /v1/dns/status`, `GET/PUT /v1/updater/status`,
    `GET /v1/vpn/settings`.
  — https://github.com/qdm12/gluetun-wiki/blob/main/setup/advanced/control-server.md ;
  https://deepwiki.com/qdm12/gluetun/7.1-api-endpoints-reference
- `FACT (cited)` **Docker-native healthcheck**: separate health server on
  `127.0.0.1:9999` (`HEALTH_SERVER_ADDRESS`) feeding Docker's healthcheck.
  — https://deepwiki.com/qdm12/gluetun-wiki/4.1-http-control-server
- `FACT (cited)` API versioning caveat: v3.41.0+ uses `/v1/vpn/status` +
  `/v1/portforward`; v3.40.0 and older used `/v1/openvpn/status` +
  `/v1/openvpn/portforwarded`. **Pin a version** and target the new API.
  — https://deepwiki.com/qdm12/gluetun-wiki/4.1-http-control-server
- `UNCONFIRMED:` GitHub issue #3060 reports a build where the WireGuard control
  server "exposes no usable API routes" — a version-specific regression signal.
  MUST pin + smoke-test the control API on the chosen tag before relying on it.
  — https://github.com/qdm12/gluetun/issues/3060

**Fit: STRONG.** gluetun is a near-exact prebuilt of the per-tunnel VPN layer we
were about to hand-roll: multi-provider, dual-protocol, kill-switch, DNS-over-TLS,
**and a runtime control/status API** — precisely what our Redis `vpn:status:<profile>`
+ start/stop control-plane wants. One container per profile = one Redis key.

### 3.2 Other building blocks (license / maturity / fit)
| Tool | License | Maturity | Fit for our control-plane |
|---|---|---|---|
| **gluetun** `qmcgaw/gluetun` | MIT `FACT` | 14.7k★, active `FACT` | **Adopt** — per-tunnel container + control API. |
| **wg-quick** (wireguard-tools) | GPL-2.0 `UNCONFIRMED (typical)` | Reference tool `FACT` | Good for raw kernel-wg tunnels if we wrap directly; no API/kill-switch/health — we'd build §2/§4 ourselves. — https://manpages.debian.org/unstable/wireguard-tools/wg.8.en.html |
| **dperson/openvpn-client** (current) | `UNKNOWN:` LICENSE not verified from search — must read repo LICENSE file | `UNCONFIRMED:` low recent activity signal; not confirmed | OpenVPN-only, no status API, no multi-tunnel. Keep only as legacy OpenVPN tunnel type; gluetun supersedes it. — https://github.com/dperson/openvpn-client |
| **Tailscale** | BSD-3 (client) `UNCONFIRMED` | Mature `FACT` | Mesh/exit-node model, NOT commercial-provider egress; Free plan = 1 exit node. Wrong shape for "route target X through commercial VPN profile Y." — https://www.vpnsmith.com/en/blog/tailscale-exit-node-complete-guide-2026 |
| **Cloudflare WARP / WARP Connector** | Proprietary service `FACT` | Mature `FACT` | Cloudflare-network egress only; not arbitrary multi-provider; known conflicts when combined with exit nodes. Not a fit for multi-provider profiles. — https://andrewdoering.org/blog/2025/cloudflare-warp-connector-tailscale-alternative/ ; https://github.com/tailscale/tailscale/issues/15288 |

> `UNKNOWN:` exact license of `dperson/openvpn-client` and `wg-quick` were not
> confirmable from search snippets — read the repo LICENSE files before any
> redistribution claim (§11.4.99).

---

## 4. REAL tunnel-health detection (anti-bluff, §11.4.69)

The core anti-bluff distinction: **"configured" ≠ "carrying traffic."** Trust
signals that prove *bidirectional data movement*, not config presence.

### 4.1 WireGuard (trustworthy)
- `FACT (cited)` `wg show <if>` / `wg show <if> dump` exposes per-peer
  `latest-handshake`, `transfer-rx`, `transfer-tx`. **Trust signal =
  recent handshake (< ~3 min, "(none)" means never established) AND increasing
  rx/tx byte counters across two samples.** A static counter or stale handshake =
  tunnel not actually working even if the interface is "up."
  — https://man7.org/linux/man-pages/man8/wg.8.html ;
  https://oneuptime.com/blog/post/2026-01-28-monitor-wireguard-connections/view ;
  https://github.com/dsh2dsh/check_wg
- This is the **strongest** signal: it is a kernel-reported counter of real
  encrypted bytes, not a config field.

### 4.2 OpenVPN (trustworthy, via management interface)
- `FACT (cited)` Connect to the OpenVPN **management interface** (TCP/Unix
  socket); `state on` → `>STATE:` notifications (the `CONNECTED` state =
  "Initialization Sequence Completed"); `bytecount <n>` → `>BYTECOUNT:` real-time
  rx/tx. **Trust signal = CONNECTED state AND advancing bytecount.**
  — https://openvpn.net/community-docs/management-interface.html ;
  https://github.com/OpenVPN/openvpn/blob/master/doc/management-notes.txt
- Note: `dperson/openvpn-client` does not expose this API by default; gluetun's
  `/v1/vpn/status` is the higher-level equivalent.

### 4.3 Egress public-IP check (medium trust — confirms, doesn't prove liveness)
- `FACT (cited)` `curl ifconfig.me` / `api.ipify.org` / `icanhazip.com` returns
  the egress public IP; gluetun exposes it at `GET /v1/publicip/ip`. Comparing it
  against the host's real IP confirms traffic is *leaving via the tunnel*.
  — https://getpublicip.com/guides/find-your-public-ip-address/find-your-ip-address-on-linux ;
  https://deepwiki.com/qdm12/gluetun/7.1-api-endpoints-reference
- Caveat (§11.4.6): a cached/last-known IP can be a **false positive** — gluetun
  reports its last-resolved public IP. Pair it with a live counter (§4.1/§4.2) or
  an active probe, don't trust the IP field alone.

### 4.4 conntrack / active reachability (supporting)
- `FACT (cited)` `conntrack` confirms bidirectional de-SNAT of return traffic;
  an ICMP/HTTP probe across the tunnel at a polling interval is the standard
  "is the path actually up" check used for automatic failover.
  — https://dev.classmethod.jp/en/articles/multi-az-snat-instance/ ;
  https://docs.paloaltonetworks.com/network-security/ipsec-vpn/administration/set-up-tunnel-monitoring
- `FACT (cited)` Documented false-positive class: config saved ≠ config applied —
  the UI/state shows correct settings while running iptables/peer state is stale
  and traffic is silently dropped. Health logic MUST read **running** state.
  — https://docnotes.net/2026/03/29/vlan-through-speedfusion/

### 4.5 Trust ranking (best → weakest)
1. **WireGuard `transfer` byte-counter delta + fresh `latest-handshake`** (kernel-reported, hardest to fake). `FACT`
2. **OpenVPN management `CONNECTED` + advancing `BYTECOUNT`** (or gluetun `/v1/vpn/status` + a counter). `FACT`
3. **Active egress probe** (HTTP/ICMP through the tunnel to a known target) — proves end-to-end path. `FACT`
   - (Egress public-IP compare is a *confirmation*, not a liveness proof on its own — §4.3.)

> §11.4.69 mapping: tunnel-up evidence = a `network_connectivity` /
> `network_throughput` artefact (sampled counter delta + probe result), NOT a
> config-file read or an "interface exists" check.

---

## 5. Failover / reconnect between tunnels for one target

- `FACT (cited)` Production failover = **continuous health monitoring** (latency,
  loss, jitter, L7 HTTP probe) of primary + secondary tunnels, **automatic
  switch to backup on threshold breach, auto-revert on recovery**. SD-WAN/Meraki
  use L7 health-check data to decide; BGP is the dynamic-routing variant.
  — https://oneuptime.com/blog/post/2026-02-12-configure-vpn-redundancy-dual-tunnels/view ;
  https://documentation.meraki.com/MX/Site-to-site_VPN/Site-to-Site_VPN_Failover_Behavior ;
  https://www.fatpipeinc.com/resources/glossary/what-is-vpn-failover
- **Our application of it:** a `proxy_rule` maps target → ordered list of
  `vpn_profiles` (primary + fallback). The VPN monitor publishes
  `vpn:status:<profile>` to Redis; on a primary going unhealthy (by §4 signals),
  the control-plane (a) re-points the rule to the next healthy profile and
  publishes a `vpn:events` message, and (b) **returns a graceful 503** for
  requests whose entire profile list is down (no crash/restart — the kill-switch
  drops packets, but the proxy must answer 503 at L7 itself; §2.4).
- **Hysteresis/anti-flap (§11.4.6, no guessing):** require N consecutive healthy
  samples before revert; use the *already-defined* poll/grace budgets, never
  invented numbers (mirrors Constitution §11.4.144 reconnection-timing rule).

---

## Structural-impossibility / honest gaps (§11.4.6 / §11.4.112)
- **No structural impossibility found** for the multi-tunnel control-plane — all
  five angles map to documented, OSS-backed primitives.
- `UNKNOWN:` kernel-WireGuard creation inside **rootless Podman** without
  elevation — the one real risk. If blocked, use gluetun userspace WireGuard or
  grant the wg module + netns capability per §11.4.133. MUST be spiked early.
- `UNCONFIRMED:` Squid per-connection `SO_MARK`/`tcp_outgoing_mark` tunnel
  selection (strategy §2.3-B) — needs a runtime spike; strategy §2.3-A
  (proxy-per-netns) is the de-risked default.
- `UNCONFIRMED:` gluetun control-API route availability on a given tag (issue
  #3060) — pin + smoke-test the API on the chosen version.

---

## RECOMMENDATION (concrete)

**Adopt gluetun as the per-tunnel VPN-manager layer; one gluetun container per
`vpn_profile` (= one netns = one Redis `vpn:status:<profile>` key).** Rationale:

1. It is a mature (14.7k★), **MIT-licensed**, actively-developed prebuilt that
   already provides multi-provider + **dual-protocol (OpenVPN + WireGuard,
   kernel & userspace)** + **firewall kill-switch** + **DNS-over-TLS** + a
   **runtime HTTP control/status API** (`/v1/vpn/status` GET/PUT,
   `/v1/publicip/ip`) + a Docker healthcheck server. This is §11.4.74
   extend-don't-reinvent in textbook form: it *is* the control-plane's tunnel
   layer, with status+start/stop endpoints our Redis layer can drive directly.
2. Its **one-tunnel-per-container** model maps 1:1 onto our existing
   `network_mode: service:<vpn>` compose pattern and onto "one profile = one
   tunnel," giving native multi-tunnel via multiple containers.
3. **Prefer kernel WireGuard** as the default tunnel type for throughput/CPU at
   scale; keep **OpenVPN** as the compatibility type (gluetun covers both, so we
   retire `dperson/openvpn-client` to "legacy" rather than maintain it).

**Trade-offs / what we still build ourselves:**
- Graceful **L7 503-on-down** is ours — gluetun's kill-switch drops packets; our
  proxy/control-plane must answer 503 (§2.4/§5). This is the main custom piece.
- **Target→tunnel selection**: default to **proxy-per-netns** (§2.3-A,
  de-risked, matches today's compose) over single-proxy-fwmark (§2.3-B) until a
  spike proves Squid `SO_MARK` steering.
- **Health truth** comes from §4.5 layered signals (wg counter-delta + handshake
  #1; OpenVPN/gluetun status + bytecount #2; active egress probe #3) — never a
  config read (§11.4.69). gluetun's `/v1/vpn/status` + `/v1/publicip/ip` feed it,
  but pair the IP with a live counter to dodge the cached-IP false positive.
- **Risk to spike first:** kernel-wg under rootless Podman (§11.4.161/§11.4.133);
  fall back to gluetun userspace wg if blocked.

If a runtime spike shows gluetun cannot run under our rootless constraints OR its
control API is unavailable on a maintainable tag (#3060), the fallback is
**wrap kernel WireGuard directly via `wg`/`wg-quick` + the netns pattern (§2.1)**,
building kill-switch + status ourselves — more code, same architecture.

---

## Sources verified 2026-06-30
- https://www.wireguard.com/netns/  (WireGuard official — netns isolation, fwmark, socket-stays-in-namespace-A)
- https://wiki.archlinux.org/title/WireGuard
- https://man7.org/linux/man-pages/man8/wg.8.html  (wg(8) — show/dump fields)
- https://manpages.debian.org/unstable/wireguard-tools/wg.8.en.html
- https://github.com/dsh2dsh/check_wg  (handshake-age + transfer health check)
- https://oneuptime.com/blog/post/2026-01-28-monitor-wireguard-connections/view
- https://contabo.com/blog/wireguard-vs-openvpn-a-deep-dive-protocol-comparison/
- https://cyberinsider.com/vpn/wireguard/wireguard-vs-openvpn/
- https://routerhax.com/wireguard-vs-openvpn/
- https://myipaddress.app/blog/wireguard-vs-openvpn-throughput-benchmark
- https://blog.cloudflare.com/boringtun-userspace-wireguard-rust/  (boringtun — Rust userspace wg)
- https://github.com/cloudflare/boringtun  (BSD-3-Clause)
- https://sourceforge.net/projects/wireguard-go.mirror/  (wireguard-go — MIT, perf note)
- https://news.ycombinator.com/item?id=19500725
- https://github.com/qdm12/gluetun  (MIT license, providers, protocols, kill-switch, DoT, multi-instance, maturity)
- https://github.com/qdm12/gluetun-wiki/blob/main/setup/advanced/control-server.md  (control API endpoints, auth, port 8000)
- https://deepwiki.com/qdm12/gluetun/7.1-api-endpoints-reference
- https://deepwiki.com/qdm12/gluetun-wiki/4.1-http-control-server  (health server 9999, API versioning v3.41+)
- https://github.com/qdm12/gluetun/issues/3060  (UNCONFIRMED: control-API regression on a WireGuard build)
- https://www.simplehomelab.com/gluetun-docker-guide/  (iptables kill-switch)
- https://corelab.tech/setup-gluetun/
- https://www.linuxserver.io/blog/advanced-wireguard-container-routing  (multi-tunnel split routing via fwmark/tables)
- https://docs.opnsense.org/manual/how-tos/wireguard-selective-routing.html
- https://openvpn.net/community-docs/management-interface.html  (state/bytecount)
- https://github.com/OpenVPN/openvpn/blob/master/doc/management-notes.txt  (>STATE:/>BYTECOUNT:, CONNECTED)
- https://github.com/dperson/openvpn-client  (UNKNOWN: license/maintenance not confirmed from search)
- https://getpublicip.com/guides/find-your-public-ip-address/find-your-ip-address-on-linux  (egress IP via curl)
- https://dev.classmethod.jp/en/articles/multi-az-snat-instance/  (conntrack de-SNAT)
- https://docs.paloaltonetworks.com/network-security/ipsec-vpn/administration/set-up-tunnel-monitoring  (ICMP tunnel monitor / failover)
- https://docnotes.net/2026/03/29/vlan-through-speedfusion/  (config-saved ≠ config-applied false-positive class)
- https://oneuptime.com/blog/post/2026-02-12-configure-vpn-redundancy-dual-tunnels/view  (dual-tunnel redundancy/failover)
- https://documentation.meraki.com/MX/Site-to-site_VPN/Site-to-Site_VPN_Failover_Behavior  (L7 health-check failover)
- https://www.fatpipeinc.com/resources/glossary/what-is-vpn-failover
- https://www.vpnsmith.com/en/blog/tailscale-exit-node-complete-guide-2026  (Tailscale exit-node model/limits)
- https://andrewdoering.org/blog/2025/cloudflare-warp-connector-tailscale-alternative/  (WARP Connector)
- https://github.com/tailscale/tailscale/issues/15288  (WARP + exit-node conflict)
