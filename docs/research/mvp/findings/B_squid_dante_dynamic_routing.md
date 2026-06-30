# B — Dynamic Control-Plane Integration with Squid + Dante for Per-Target VPN-Profile Routing

**Revision:** 1
**Last modified:** 2026-06-30T00:00:00Z
**Authority:** Research finding for `helix_proxy` MVP. Subordinate to `constitution/Constitution.md` §11.4 (anti-bluff), §11.4.6 (no-guessing), §11.4.99 (latest-source cross-reference), §11.4.150 (deep multi-angle research).
**Scope:** How a dynamic control-plane (Go + Postgres + Redis) routes specific targets through specific VPN tunnels via the EXISTING forward proxies — Squid (HTTP/HTTPS, port 53128) and Dante/sockd (SOCKS5, port 51080) — with graceful 503-on-tunnel-down and hot-reload without dropping connections.

> **Evidence discipline.** Every non-trivial claim is tagged `FACT (cited)` with a source URL, or `UNCONFIRMED:` where the authoritative source did not state it. The canonical `squid-cache.org` HTTPS endpoint and `web.archive.org` were unreachable from the research host (TLS issuer / fetch blocks); where verbatim directive text could not be retrieved, the claim is tagged `FACT (cited, paraphrased from official doc via search index)` and the verbatim-gap is stated explicitly per §11.4.6.

---

## 0. Executive summary

The shipped research doc models a **reverse proxy** (`httputil.ReverseProxy`, Host→target lookup). The deployed system is a **forward proxy** (clients set `HTTP_PROXY` / SOCKS). These are reconciled below: **the control-plane is NOT in the data path** for the proxy hop. Instead the Go control-plane is a **config compiler + health monitor** that (a) renders Squid/Dante config from Postgres routing rules, (b) reloads the proxies in-place, and (c) drives a tunnel-health signal that turns into a fast 503 when a target's tunnel is down. A thin Go reverse-proxy is added ONLY as an optional internal "alias" front-end for named targets and for clean 503 bodies — it does not replace Squid/Dante.

**Recommended architecture (detail in §7):** *Squid `cache_peer` → per-tunnel egress gateways, selected by `cache_peer_access` ACLs that are driven by an `external_acl_type` helper backed by Redis; each VPN tunnel runs in its own network namespace exposing a distinct egress; `never_direct` + dead-peer detection yields 503; `deny_info 503:ERR_TUNNEL_DOWN` gives a clean body; `squid -k reconfigure` (or external-ACL/Redis flips for the no-restart path) provides hot-reload.* Dante reaches the same egress fabric via `external.rotation route` + per-destination `route … via` upstream chaining, reloaded with `SIGHUP`.

---

## 1. Squid dynamic routing mechanisms

### 1.1 `cache_peer` + `cache_peer_access` (parent-per-egress selection)

`FACT (cited)` — Squid can choose among configured parents (`cache_peer`) based on ACL results using `cache_peer_access`; this is the documented way to send requests for specific destinations to specific upstreams. `cache_peer_access` is available in Squid v7, v6, v5, v4, 3.x and 2.6+. Per-destination routing is done with `dstdomain` (or `dst`) ACLs gating each peer. Source: <https://www.squid-cache.org/Doc/config/cache_peer_access/> and <https://www.squid-cache.org/Doc/config/cache_peer/> (accessed 2026-06-30, via search index — HTTPS fetch blocked by TLS issuer on host); corroborated <https://docs.huihoo.com/gnu_linux/squid/html/x2163.html> and <https://www.sbarjatiya.com/notes_wiki/index.php/Cache_peer_configuration_for_squid> (accessed 2026-06-30).

Pattern:
```squid
cache_peer 10.40.0.1 parent 3128 0 no-query name=vpn_us
cache_peer 10.41.0.1 parent 3128 0 no-query name=vpn_de
acl to_us dstdomain .us-target.example
acl to_de dstdomain .de-target.example
cache_peer_access vpn_us allow to_us
cache_peer_access vpn_us deny all
cache_peer_access vpn_de allow to_de
cache_peer_access vpn_de deny all
never_direct allow all          # force everything through a peer (see §4)
```
Here each `cache_peer` is a small egress gateway sitting on a per-tunnel network namespace (§7). Squid picks the peer; the peer's netns determines which VPN the packet exits.

### 1.2 `tcp_outgoing_address` (source-IP-per-destination → policy-routed egress)

`FACT (cited)` — `tcp_outgoing_address <ip> [acl]` binds the **source address** of the upstream connection per matching ACL (destination domain, client subnet, or incoming port). Verbatim config from a reachable source:
```squid
acl blocked_for_ip1 dstdomain .restricted-site.com
tcp_outgoing_address 203.0.113.20 blocked_for_ip1
tcp_outgoing_address 203.0.113.10
```
Source: <https://oneuptime.com/blog/post/2026-03-20-squid-tcp-outgoing-address-ipv4/view> (accessed 2026-06-30), backed by <https://www.squid-cache.org/Doc/config/tcp_outgoing_address/>.
- `FACT (cited)` — **Not available in Squid v8**; works v7 and earlier. Same sources. **This is a load-bearing version constraint** — verify the deployed Squid major version before relying on it.
- Caveat: `server_persistent_connections off` is recommended when the ACL is client/destination-dependent, to avoid a pooled connection reusing the wrong source. Source: same oneuptime article.

This is the **simplest** per-destination egress mechanism on a single host: pair each VPN tunnel with a source IP, then use Linux policy routing (`ip rule from <src> table <tun>`, §7.2) so the bound source IP forces the packet down the right tunnel. No separate egress-gateway process needed.

### 1.3 Helper interfaces for *dynamic* (backend-driven) selection

The above are **static** config. To pick egress from a dynamic backend (Postgres/Redis) without regenerating the whole config:

- `FACT (cited)` — **`external_acl_type`**: an external helper process Squid queries per request; helper replies `OK`/`ERR` and may return `key=value` annotations. Helpers can use pluggable lookup backends including **Memcached, LDAP, and flat text files**; helpers are long-lived and handle concurrent lookups (channel-ID). Squid 3.2+ supports lazy/dynamic helper start. Source: <https://wiki.squid-cache.org/SquidFaq/SquidAcl>, <https://www.squid-cache.org/Doc/config/external_acl_type/> (search index), reference helper scaffold <https://github.com/jnschulze/squidHelper>, Go example <https://github.com/nf/webfilter> (all accessed 2026-06-30). → **A Go helper backed by Redis can answer "is target T's tunnel up, and which peer should it use?" per request**, and its `OK/ERR` gates `cache_peer_access` / `http_access`. This is the no-restart dynamic path (§5).
- `FACT (cited)` — **`url_rewrite_program`**: per-request helper that rewrites or redirects URLs; returns blank line (no change), a rewritten URL, or `key=value` pairs; can be combined with `cache_peer` to steer requests to backends (accel/originserver mode). Source: <https://www.squid-cache.org/Doc/config/url_rewrite_program/>, <https://wiki.squid-cache.org/Features/Redirectors> (accessed 2026-06-30). Less suited to forward-proxy egress selection than `external_acl_type` (rewriting the URL changes what the client sees); prefer external ACL for routing.
- `store_id_program`: `UNCONFIRMED:` relevant to **cache key de-duplication**, not egress routing — not useful for this mandate. Noted for completeness; not researched in depth (out of scope).
- `FACT (cited)` — **PAC file** (`proxy.pac`, `FindProxyForURL(url, host)`): JS that returns a per-host proxy string with built-in fallback if the first proxy is unresponsive. Source: <https://developer.mozilla.org/en-US/docs/Web/HTTP/Guides/Proxy_servers_and_tunneling/Proxy_Auto-Configuration_PAC_file> (accessed 2026-06-30). The control-plane can **generate a PAC** so clients pick a *different Squid/Dante port* per target — a client-side complement, not a Squid-internal mechanism. Useful when each VPN profile is a distinct proxy listener.

### 1.4 How Squid picks a different upstream/egress per destination from a dynamic backend

Two viable wirings:
1. **Config-compiled** (static, reload-driven): control-plane renders `cache_peer` + `cache_peer_access` (or `tcp_outgoing_address`) from Postgres; `squid -k reconfigure` applies it (§5). Simple, auditable, but reload semantics are imperfect (§5.1).
2. **Helper-driven** (dynamic, no reload): a fixed config references a Go `external_acl_type` helper; the helper consults Redis per request to decide allow/deny per peer and to fail-fast when down. No reconfigure needed for routing or health changes — only for adding a brand-new tunnel/listener.

---

## 2. Dante (sockd) dynamic upstream/egress selection

### 2.1 Per-destination egress via `external` + `external.rotation`

`FACT (cited)` — `external` may be given **multiple times** (IP or interface name) to bind multiple egress addresses. `external.rotation` selects among them:
- `none` (default): "the first address on the list of external addresses should be used."
- `route`: "the kernels routing table should be consulted to find out what the source address for a given destination will be" — **per-destination egress via the kernel routing table**.
- `same-same`: source address = the address the client connection was accepted on.

Source: <https://www.inet.no/dante/doc/1.4.x/sockd.conf.5.html> (accessed 2026-06-30), corroborated <https://linux.die.net/man/5/sockd.conf> (accessed 2026-06-30).
→ With `external.rotation route` and policy routing (§7.2), Dante egress per destination follows the same `ip rule`/table fabric as Squid's `tcp_outgoing_address`.

### 2.2 Per-destination upstream SOCKS chaining via `route … via`

`FACT (cited)` — Dante `route` blocks take **`from` / `to` / `via`**: `to` = the destination the route applies to; `via` = the upstream proxy gateway (or `direct`). `proxyprotocol` supports `socks_v4`, `socks_v5`, `http`, `upnp`. Different routes select different upstreams per destination; the library matches direct → socks_v4 → socks_v5 → http → upnp in order. **Server-chaining is supported only for the `connect` command.** Source: <https://www.inet.no/dante/doc/1.4.x/socks.conf.5.html> and <https://www.inet.no/dante/doc/1.4.x/sockd.conf.5.html> (accessed 2026-06-30).
→ Dante CAN select egress per destination, by either (a) `route` source-address selection, or (b) chaining to a per-tunnel upstream SOCKS server `via` that destination's route.

### 2.3 Limits

- `FACT (cited)` — Per-destination *upstream chaining* is constrained to TCP `connect` (no UDP-associate / bind chaining). Source: §2.2 sources.
- `UNCONFIRMED:` Whether `route … via` can be flipped by an *external backend* per request — Dante routes are **static config**; there is no documented external-helper hook equivalent to Squid `external_acl_type`. Dynamic Dante routing therefore requires a config rewrite + `SIGHUP` (§5.2), OR steering at the egress-gateway layer (§7) rather than inside sockd. (Searched inet.no sockd.conf/socks.conf — no external-helper directive documented.)

---

## 3. Reverse vs forward reconciliation — architecture options

The shipped doc's `httputil.ReverseProxy` model assumed the proxy owns the data path and looks up target by `Host`. In a **forward** proxy the client already names the absolute target; Squid/Dante own the hop. Reconciliation options:

| Option | Mechanism | Pros | Cons |
|---|---|---|---|
| **(a) Go reverse-proxy front for named aliases** | Clients hit `alias.helix/…`; Go dials through the correct tunnel netns; control-plane is in the data path | Trivial clean 503 body; full hot-reload in Go (atomic `sync.Map`/`atomic.Pointer` swap, no dropped conns); per-target logic arbitrary | Only covers **named-alias** traffic, not arbitrary `HTTP_PROXY` clients; re-implements proxying; TLS to arbitrary targets needs CONNECT/MITM; duplicates Squid caching — **additive only, NOT a Squid/Dante replacement** (mandate is additive per §11.4.74) |
| **(b) Squid `cache_peer` → per-tunnel egress + ACL selection from generated config** | §1.1; control-plane compiles config from Postgres | Uses existing Squid; native caching/ACL/CONNECT; `never_direct`+dead-peer = native 503; mature | Reconfigure semantics imperfect (§5.1); adding a tunnel needs reconfigure |
| **(b′) Squid `external_acl_type` (Redis-backed Go helper) selection** | §1.3; fixed config, dynamic decision | **No reconfigure** for routing/health flips; control-plane stays out of the byte path; per-request decision | Helper is on the hot path (must be fast + concurrent + never block); helper crash = fail-closed risk (must default-deny→503, not allow) |
| **(c) Dante `route`/`external.rotation route` selection** | §2 | Native SOCKS5 egress per destination; chaining to per-tunnel upstreams | No external-helper hook → dynamic change needs `SIGHUP`; chaining is connect-only |
| **(d) Hybrid (RECOMMENDED)** | Squid (b′) for HTTP/HTTPS + Dante (c) for SOCKS, both targeting one **per-tunnel egress fabric** (netns + policy routing); Go control-plane = config compiler + Redis health publisher + optional alias front (a) | Each protocol uses its native strength; single egress fabric; dynamic where it counts (Squid via Redis), reload-driven where it must (Dante) ; control-plane out of the main byte path | Two reload paths to operate; egress fabric (netns/policy-routing) is the real complexity |

---

## 4. Live-status → graceful 503 (no restart)

### 4.1 Squid

- `FACT (cited)` — With `never_direct allow all`, Squid MUST use a peer; if all eligible peers are DEAD it cannot forward and returns a 5xx (observed 503/504 / `NONE/503` / `TCP_MISS/504`) to the client. Sources: <https://squid-users.squid-cache.narkive.com/IKjvbLqy/tcp-miss-504-in-cache-peer>, <https://ramesh-sahoo.medium.com/squid-proxy-server-has-stopped-handling-connection-resulting-in-none-503-0-connect-errors-55477316850a>, <https://lists.squid-cache.org/pipermail/squid-users/2021-November/024218.html> (accessed 2026-06-30).
- `FACT (cited)` — **Clean, deterministic body**: `deny_info` returns a chosen status + template per ACL, e.g. `deny_info 503:ERR_TUNNEL_DOWN tunnel_down_acl` (status prefix `503:` before the template name). Source: <https://blog.squidblacklist.org/?p=707>, <https://www.squid-cache.org/Doc/config/deny_info/> (accessed 2026-06-30). → **Cleanest fast-503 path:** a Redis-backed `external_acl_type` helper returns `ERR` when target T's tunnel is down; `http_access deny tunnel_down` + `deny_info 503:ERR_TUNNEL_DOWN tunnel_down` emits an immediate, branded 503 **without touching a dead peer and without restart**. Recovery to 200 is automatic the moment the helper returns `OK` again (Redis flag flipped by the health monitor). No reconfigure for up/down transitions.
- `FACT (cited)` — Dead-peer detection: a peer is marked DEAD after enough connection failures (`connect-fail-limit`, default-ish small N); `standby=N` keeps idle warm connections; `connect-timeout` bounds the probe. Source: <https://www.squid-cache.org/Doc/config/cache_peer/> (search index). `FACT (cited, paraphrased from official doc via search index)` — exact verbatim option text could not be retrieved (TLS issuer block on host); semantics confirmed via search extract + <https://www.spinics.net/lists/squid/msg65394.html>.
- `FACT (cited)` — **`monitorurl`/`monitorinterval` active health-check on `cache_peer` was a Squid-2.6 feature and was NOT ported to Squid 3.4+/4/5/6.** Source: <https://wiki.squid-cache.org/Features/MonitorUrl> + Squid 3.5.9 release-notes search (accessed 2026-06-30). **Implication:** do NOT design around Squid-native active peer health checks on modern Squid — drive health from the **control-plane** (external probe → Redis → external_acl_type), which is the robust, version-independent path anyway.

### 4.2 Dante

- `UNCONFIRMED:` Dante has **no documented `deny_info`-equivalent custom-5xx mechanism** — SOCKS5 returns a numeric reply code (e.g. `0x03` network-unreachable, `0x04` host-unreachable, `0x05` connection-refused), not an HTTP 503. The graceful-failure unit for SOCKS is the SOCKS reply code. (inet.no sockd.conf/socks.conf searched; no error-template directive found.) → For SOCKS clients, "503-equivalent" = a fast SOCKS failure reply when the egress/upstream is down; a clean HTTP-503 body is only achievable for HTTP via Squid, or via the optional Go alias front (option a).
- Fast-fail when down: either (i) the per-tunnel upstream `via` SOCKS server refuses → sockd returns failure, or (ii) policy-route blackhole for a down tunnel → connect fails fast. Tune with sockd connect timeouts.

---

## 5. Hot-reload safety (no dropped sessions)

### 5.1 Squid

- `FACT (cited)` — `squid -k reconfigure` is **not guaranteed** zero-impact. Squid developer Alex Rousskov: Squid "does *not* maintain a consistent configuration state during (re)configuration"; "Most existing connections, especially short-lived ones, are usually unaffected when the configuration does not change much"; "new incoming connections may be rejected during reconfiguration (in some cases)"; reconfigure cost "depends on many variables" and can approach a cold start; a **"smooth reconfiguration" project** (per-directive, non-disruptive) is ongoing but incomplete. Source: <https://www.spinics.net/lists/squid/msg95260.html> (accessed 2026-06-30). Corroborated <https://wiki.squid-cache.org/SquidFaq/OperatingSquid> (accessed 2026-06-30).
- **Design consequence:** treat `reconfigure` as "mostly-graceful but may reject some new connections + drop long-lived ones if directives changed." **Therefore route as much dynamism as possible through the `external_acl_type` + Redis path (§1.3/§4.1), which needs NO reconfigure** for routing/health changes. Reserve `reconfigure` for structural changes (new `cache_peer`, new listener) — done rarely, ideally during low traffic, optionally behind a second Squid + connection-draining (the wiki's two-Squid technique).

### 5.2 Dante

- `FACT (cited)` — `sockd` reloads config on **`SIGHUP`** ("Reload the configuration file. Will also reopen logfiles."). Source: <https://man.archlinux.org/man/sockd.8.en>, <https://www.inet.no/dante/doc/1.3.x/sockd.8.html> (accessed 2026-06-30); SIGHUP-reload corroborated <https://linuxvox.com/blog/sighup-for-reloading-configuration/> (accessed 2026-06-30).
- `UNCONFIRMED:` Whether `SIGHUP` **preserves established sockd sessions** — the man pages document reload + log-reopen but make **no statement** that active client sessions survive or are dropped. Do not claim either way without a live test (per §11.4.6 / §11.4.123). **Action item:** before relying on Dante hot-reload, run a captured-evidence test (long-lived SOCKS session active across a `SIGHUP`; observe whether the byte stream survives) and record the result.

---

## 6. Modern alternatives (awareness only — mandate is additive to Squid/Dante)

- **Envoy** — `FACT (cited)` industry-standard for **dynamic** routing via xDS control-plane APIs and **hot config without dropping connections** (its design goal). Could serve as an *internal* egress-selection/data-plane component fed by the Go control-plane if Squid's reconfigure limits become blocking; but it is HTTP/gRPC/TCP-centric, not a SOCKS5 server, and would duplicate Squid. (General knowledge; not a project mandate.) Useful only as an internal component where dynamic, connection-preserving reconfig is essential.
- **HAProxy** — runtime API + seamless reloads (socket hand-off) preserve connections; strong for TCP/HTTP egress steering. Same "internal component" caveat.
- **mitmproxy** — scriptable Python forward proxy; great for per-request logic/aliases but not a high-throughput production egress. Could prototype alias logic only.

None replace the existing Squid/Dante per the additive mandate (§11.4.74); note them only as candidate **internal** building blocks if a limitation below proves blocking.

---

## 7. RECOMMENDED architecture (control-plane ↔ Squid/Dante)

**Hybrid (option d).** The Go control-plane is a **config compiler + health publisher + (optional) alias front**, NOT the proxy data path.

### 7.1 Components
1. **Egress fabric — per-tunnel network namespaces.** Each OpenVPN tunnel runs in its own netns (one `tun` per netns), so tunnels are isolated and a down tunnel cannot leak to another. `FACT (cited)` netns-per-tunnel and concurrent multiple tunnels: <https://github.com/slingamn/namespaced-openvpn>, <https://www.redhat.com/sysadmin/use-net-namespace-vpn> (accessed 2026-06-30). Each netns runs a tiny egress gateway (a minimal Squid/`socat`/`tinyproxy`-class listener) that Squid/Dante reach as a `cache_peer` / SOCKS `via` upstream.
   - *Single-host alternative without netns:* policy routing by source IP. `FACT (cited)` `ip rule from <src> table <tunN>` + per-table default via the tun gateway selects egress per source address; `ip route get <dst> from <src>` verifies. Source: <https://oneuptime.com/blog/post/2026-03-20-ip-rule-policy-based-routing/view>, <https://community.openvpn.net/openvpn/wiki/Concepts-PolicyRouting-Linux> (accessed 2026-06-30). Pair with Squid `tcp_outgoing_address` (§1.2) / Dante `external.rotation route` (§2.1).
2. **Squid (HTTP/HTTPS, 53128).** Fixed config + a Go **`external_acl_type` helper** that, per request, reads Redis for `{target → (tunnel_id, up?)}` and returns `OK <peer-tag>` / `ERR`. Routing: `cache_peer` per tunnel-egress + `cache_peer_access` keyed on the helper's annotation; `never_direct allow all`; `deny_info 503:ERR_TUNNEL_DOWN` for the down case. **No reconfigure** for routing/health; reconfigure only when a NEW tunnel/peer is added.
3. **Dante (SOCKS5, 51080).** Config compiled from Postgres: `external.rotation route` for source-based egress + `route { to: … via: <per-tunnel upstream> }` for chaining; reload via `SIGHUP`. SOCKS fast-fail (reply code) when egress down.
4. **Control-plane (Go + Postgres + Redis).**
   - **Postgres** = source of truth for routing rules (target ↔ VPN profile) and tunnel inventory.
   - **Redis** = hot, low-latency status the Squid helper reads per request (`tunnel:<id>:up = 0|1`, `target:<host> = tunnel:<id>`), and a pub/sub channel for config-change events.
   - **Health monitor** = the control-plane (NOT Squid `monitorurl`, which is unported on modern Squid — §4.1) actively probes each tunnel and flips the Redis flag → instant 503/recovery with no proxy restart.
   - **Config compiler** = renders Squid + Dante config from Postgres; applies `squid -k reconfigure` / `kill -HUP` only for structural changes; verifies with `squid -k parse` before swap.
   - **(Optional) alias front** = a Go `httputil.ReverseProxy` for named-alias targets only, dialing the correct netns, giving a fully-controlled 503 body and atomic in-process hot-swap. Reconciles the shipped reverse-proxy doc as a *supplementary* surface, not the main proxy.

### 7.2 Why this satisfies all three requirements
- **Per-target VPN selection:** Squid `external_acl_type`→Redis (dynamic, no restart) for HTTP; Dante `route … via` / `external.rotation route` for SOCKS; both land on per-netns egress.
- **Graceful 503 when tunnel down:** Squid `external_acl_type` `ERR` + `deny_info 503:ERR_TUNNEL_DOWN` (clean body, fast, recovers automatically); never touches a dead peer; SOCKS returns a fast failure reply. No crash, no restart.
- **Hot-reload without dropping connections:** routing/health changes flow through Redis flags read by the helper — **zero reconfigure**, so no connection impact. Structural changes (rare) use `reconfigure`/`SIGHUP` with the known caveats (§5), optionally drained behind a second instance.

### 7.3 Honest boundaries / structural cautions (§11.4.6 / §11.4.112)
- **No proven structural impossibility found** for the mandate on this stack. It is achievable with Squid + Dante + a netns/policy-routing egress fabric + a Redis-backed external-ACL helper.
- **Squid `reconfigure` is not provably connection-lossless** (§5.1 — developer-confirmed) — hence the design pushes dynamism to the helper/Redis path so reconfigure is rare. Do not claim "Squid hot-reloads without dropping connections" as a blanket fact; it is true only for the external-ACL/Redis path, NOT for `reconfigure`.
- **Dante `SIGHUP` session-preservation is UNCONFIRMED** (§5.2) — must be settled by a captured-evidence live test before being relied on.
- **`tcp_outgoing_address` is gone in Squid v8** (§1.2) — if the deployment is/targets v8, use the `cache_peer`+netns egress path, not source-IP binding. **Verify the Squid major version first.**
- **Dante has no external-helper hook** (§2.3) — fully-dynamic per-request SOCKS routing without a `SIGHUP` is not available inside sockd; do dynamic SOCKS steering at the egress-gateway layer or accept `SIGHUP` for SOCKS routing changes.
- **Verbatim-quote gap:** exact `cache_peer` option text (`connect-fail-limit`, `standby`) and `never_direct` verbatim could not be retrieved (squid-cache.org TLS issuer + web.archive.org both unreachable from host); semantics are confirmed via the search index + mailing lists, tagged accordingly above. Re-verify verbatim against the running Squid's `squid.conf.documented` before final implementation.

---

## Sources verified 2026-06-30

- Squid `cache_peer_access` directive — https://www.squid-cache.org/Doc/config/cache_peer_access/ (via search index; HTTPS fetch TLS-issuer-blocked on host)
- Squid `cache_peer` directive — https://www.squid-cache.org/Doc/config/cache_peer/ (via search index)
- Squid peer selection (Huihoo guide) — https://docs.huihoo.com/gnu_linux/squid/html/x2163.html
- Squid cache_peer notes — https://www.sbarjatiya.com/notes_wiki/index.php/Cache_peer_configuration_for_squid
- Squid `tcp_outgoing_address` how-to (verbatim config) — https://oneuptime.com/blog/post/2026-03-20-squid-tcp-outgoing-address-ipv4/view
- Squid `tcp_outgoing_address` directive — https://www.squid-cache.org/Doc/config/tcp_outgoing_address/ (via search index)
- Squid `external_acl_type` — https://www.squid-cache.org/Doc/config/external_acl_type/ (via search index); https://wiki.squid-cache.org/SquidFaq/SquidAcl
- Squid external-ACL helper scaffold (Go) — https://github.com/jnschulze/squidHelper ; https://github.com/nf/webfilter
- Squid `url_rewrite_program` — https://www.squid-cache.org/Doc/config/url_rewrite_program/ (via search index); https://wiki.squid-cache.org/Features/Redirectors
- Squid `deny_info` custom 503 — https://blog.squidblacklist.org/?p=707 ; https://www.squid-cache.org/Doc/config/deny_info/ (via search index)
- Squid `never_direct` + dead-peer → 503/504 — https://squid-users.squid-cache.narkive.com/IKjvbLqy/tcp-miss-504-in-cache-peer ; https://ramesh-sahoo.medium.com/squid-proxy-server-has-stopped-handling-connection-resulting-in-none-503-0-connect-errors-55477316850a ; https://lists.squid-cache.org/pipermail/squid-users/2021-November/024218.html
- Squid `monitorurl` not ported to 3.4+ — https://wiki.squid-cache.org/Features/MonitorUrl
- Squid `-k reconfigure` connection/downtime semantics (Alex Rousskov) — https://www.spinics.net/lists/squid/msg95260.html ; https://wiki.squid-cache.org/SquidFaq/OperatingSquid
- Squid cache_peer options (mailing list) — https://www.spinics.net/lists/squid/msg65394.html
- Dante `sockd.conf` (external, external.rotation, route) — https://www.inet.no/dante/doc/1.4.x/sockd.conf.5.html ; https://linux.die.net/man/5/sockd.conf
- Dante `socks.conf` (route from/to/via, proxyprotocol, chaining connect-only) — https://www.inet.no/dante/doc/1.4.x/socks.conf.5.html
- Dante `sockd(8)` signals (SIGHUP reload) — https://man.archlinux.org/man/sockd.8.en ; https://www.inet.no/dante/doc/1.3.x/sockd.8.html
- SIGHUP reload convention — https://linuxvox.com/blog/sighup-for-reloading-configuration/
- OpenVPN per-tunnel network namespaces — https://github.com/slingamn/namespaced-openvpn ; https://www.redhat.com/sysadmin/use-net-namespace-vpn
- Linux policy routing (`ip rule from src table`) — https://oneuptime.com/blog/post/2026-03-20-ip-rule-policy-based-routing/view ; https://community.openvpn.net/openvpn/wiki/Concepts-PolicyRouting-Linux
- PAC `FindProxyForURL` per-host + fallback — https://developer.mozilla.org/en-US/docs/Web/HTTP/Guides/Proxy_servers_and_tunneling/Proxy_Auto-Configuration_PAC_file
