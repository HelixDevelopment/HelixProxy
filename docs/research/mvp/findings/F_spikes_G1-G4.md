# F — Spikes G1–G4 (design §20 open-gap resolution, captured evidence)

**Revision:** 1
**Last modified:** 2026-06-30T21:02:00Z
**Authority:** resolves design spec `docs/superpowers/specs/2026-06-30-vpn-aware-proxy-extension-design.md` §20 (G1–G4)
**Scope:** diagnostic spikes only (transient `podman run --rm`); production orchestration is the containers submodule (§11.4.76). Evidence is FACT-with-captured-output (§11.4.123) or honest `UNCONFIRMED:` (§11.4.6) — no guessing.

## Spike environment (captured FACT)

| Item | Value | Evidence |
|---|---|---|
| Host kernel | `Linux 6.12.61-6.12-alt1 x86_64` | `G1_rootless_wireguard.txt` |
| Podman | `5.7.1`, **rootless = true** (uid 1000) | (run setup) |
| Docker | absent (rootless podman only) | (run setup) |
| Free disk at start/end | 2.6 TB free / 31% used (never < 10 GB) | `CLEANUP.txt` |
| Run-id (evidence root) | `qa-results/spikes/20260630_205029_g1g4/` | — |

Host-safety (§12.9): `df -h` first, images pulled **sequentially**, all `--rm`, all 4 diagnostic images removed at end, no host power ops, modest load. The operator's pre-existing `wg0-mullvad` (UP kernel-WG) interface and `lava-postgres-thinker` container were **NOT touched** (§11.4.174 process/resource ownership).

---

## G2 — Squid major version  → **FACT (resolved)**

**Question:** Is `docker.io/ubuntu/squid:latest` v8+ (which removed the `tcp_outgoing_address` dstdomain form)? Do §8 `cache_peer`/`external_acl_type`/`deny_info` directives apply?

**FACT:** `ubuntu/squid:latest` (digest `sha256:8fafd41d…`, pulled 2026-06-30) reports **`Squid Cache: Version 6.13`** (Ubuntu 24.04 package `squid-6.13-0ubuntu0.24.04.3`). **NOT v8.** Built with `--enable-external-acl-helpers` (external ACL infra present).

The full §8 directive set parses clean — **`squid -k parse` exit code 0**:
`http_port` · `cache_peer … parent … no-query name=tun_demo` · `external_acl_type … %>{Host} <helper>` · `acl … external` · `cache_peer_access … allow` · `never_direct allow all` · `deny_info 503:ERR_TUNNEL_DOWN tunnel_down`.

**Evidence:** `G2_squid_version.txt` (`squid -v`), `G2_squid_v6_syntax_parse.txt` (parse exit 0).

**Design impact:**
- The §8 "verify v8 removed dstdomain `tcp_outgoing_address`" concern is **moot for this image** — it pins to v6.13, and the design's routing uses `cache_peer` + `external_acl_type` + `cache_peer_access` (NOT `tcp_outgoing_address` dstdomain) anyway. No §8 routing redesign needed.
- **Refinement (act on this):** Squid 6.13 emits `WARNING: external_acl_type format %>{...} is deprecated. Use %>ha{Host}`. The compiler should emit **`%>ha{Host}`** (not `%>{Host}`) to be future-proof.
- **Recommend:** pin the base explicitly to **`ubuntu/squid:6.13`** (or digest) rather than `:latest`, so an upstream bump to a v8 image is a deliberate, gated change (v8 removed `range_offset_limit`, already a deferred §11 item).

---

## G4 — gluetun control-API  → **FACT (resolved)**

**Question:** pin a tag; confirm the control server on :8000 (`/v1/vpn/status`, `/v1/publicip/ip`) + healthcheck :9999; note issue #3060.

**FACT (image):** tag **`qmcgaw/gluetun:v3.40` → image version `v3.40.4`** (created 2025-12-24, MIT, digest `sha256:62dc2761…`, ~42 MB). Exposed ports: **8000/tcp** (control), 8888/tcp (HTTP proxy), 8388/tcp+udp (Shadowsocks). No Docker `HEALTHCHECK` directive (the :9999 healthcheck is gluetun's *internal* loop, confirmed below).

**FACT (live, no real VPN creds — fake custom WireGuard):** the control server came up in **~2 s and answered HTTP 200** even with a bogus endpoint and no tunnel:
- `GET /v1/openvpn/status` → `{"status":"stopped"}` HTTP 200
- `GET /v1/vpn/status` → `{"status":"running"}` HTTP 200
- `GET /v1/publicip/ip` → `{"public_ip":""}` HTTP 200 (empty — no real egress, exactly as expected)
- log: `[http server] http server listening on [::]:8000` · `[healthcheck] listening on 127.0.0.1:9999` (both confirmed).

**Issue #3060 — CONFIRMED live:** `WARN route GET /v1/openvpn/status is unprotected by default … this will become no longer publicly accessible after release v3.40`. On v3.40.x routes are **open by default (warn only)**; from the next release they are auth-gated by default.

**Bonus FACT (cross-feeds G1):** log `[wireguard] Using available kernelspace implementation` — gluetun auto-detected kernel WireGuard is usable under rootless podman + `--cap-add NET_ADMIN` on this host and chose kernelspace.

**Evidence:** `G4_gluetun_control_api.txt` (inspect), `G4_gluetun_control_api_live2.txt` (200 OK from all 3 endpoints + listening logs). (`…live.txt` is a first attempt with a buggy poll — superseded.)

**Design impact:**
- **Pin gluetun to `v3.40` (=v3.40.4).** The health-publisher (§4/§7) integration surface is confirmed: poll `:8000/v1/vpn/status` + `/v1/publicip/ip` (+ `/v1/openvpn/status`) → write `vpn:status:<profile>`. `publicip/ip` is the live source for the `vpn_real_egress` anti-bluff evidence (§13).
- gluetun's own healthcheck is **internal on 127.0.0.1:9999** (not the integration API) — our health-publisher uses the :8000 control API, not :9999.
- **#3060 carried into the plan:** while pinned to v3.40.x the routes are open; **any upgrade past v3.40 MUST add control-server auth** (apikey/role config) — aligns with §11 ④ zero-trust (mTLS/auth on control plane). Record as a pinned-version constraint + an upgrade checklist item.

---

## G1 — Rootless WireGuard  → **FACT (resolved; nuanced)**

**Question:** does kernel WireGuard work under rootless podman here, or is gluetun's userspace `wireguard-go` required?

**FACT (host netns):** kernel module **loaded** (`wireguard 118784 0` in `lsmod`, `/sys/module/wireguard` present). Creating a WG interface in the **host** netns as uid 1000 **FAILS**: `ip link add wg-test type wireguard` → `RTNETLINK answers: Operation not permitted` (exit 2) — expected, uid 1000 lacks CAP_NET_ADMIN in the init netns. No leftover interface.

**FACT (decisive — rootless container netns):** inside a **rootless podman container with `--cap-add NET_ADMIN`**, `ip link add wg0 type wireguard` **SUCCEEDS** — `exit 0`, `wg0: <POINTOPOINT,NOARP> mtu 1420 … link/none`. On kernel 6.12 the wireguard module permits RTNETLINK newlink of type wireguard inside a non-init user-namespace netns when the container holds CAP_NET_ADMIN. Independently corroborated by **gluetun choosing kernelspace** (G4) and by the operator's own **`wg0-mullvad` kernel-WG interface running UP** on this host.

**Evidence:** `G1_rootless_wireguard.txt` (host: denied), `G1_rootless_container_wireguard.txt` (container + NET_ADMIN: created, exit 0), `G4_gluetun_control_api_live2.txt` (`Using available kernelspace implementation`).

**Honest boundary (`UNCONFIRMED:`):** the spike proved interface **creation** rootless; it did NOT bring the link up with a real peer, add routes, or pass traffic (no real VPN endpoint). Full kernel-WG **operation** (handshake + routing + throughput) under rootless is therefore not yet end-to-end proven.

**Design impact:**
- The §5 "rootless-WireGuard risk → fall back to gluetun userspace wireguard-go" risk is **LOWER than feared on this host** — kernel WG is creatable rootless with `--cap-add NET_ADMIN`, and gluetun auto-selects it.
- **Keep the design as written:** gluetun is the right abstraction precisely because it **auto-selects kernel vs userspace** at runtime. Userspace `wireguard-go` (bundled in gluetun) stays the **portability guarantee** for hosts where the kernel module is absent or non-init-userns WG is restricted. No spec change; record that on this host kernel WG is the active path and `--cap-add NET_ADMIN` (+ `--device /dev/net/tun`) is the required container grant.

---

## G3 — Dante SIGHUP live-session preservation  → **FACT (spike scenario PASS; P9 broader test still owed)**

**Question:** does `vimagick/dante` reload config on SIGHUP **without dropping an active SOCKS session**?

**FACT (image):** `vimagick/dante:latest` = Debian 12, `sockd` at `/usr/local/sbin/sockd` (source-built; no `dante-server` dpkg entry), mother + `-N <workers>` process model. No nc/curl/socat preinstalled (apt available).

**FACT (live, captured):** with a 20-chunk/20-second loopback HTTP stream proxied through `sockd` (SOCKS5 :1080 → upstream :9000), SIGHUP fired **mid-stream** (independently proven: at the 6 s mark `/proc/net/tcp` showed **2 ESTABLISHED conns on :1080 and 2 on :9000**, 6 chunks already received):
- `sockd` mother logged `SIGHUP [: reloading config` → `config reloaded. Broadcasting to children` and **stayed alive**; ESTABLISHED counts unchanged after HUP.
- The **same session kept streaming through the reload**: chunk-7 arrived at epoch `…146.772` immediately after SIGHUP at `…146.770`, continuing to chunk-20.
- **Result: 20/20 chunks, curl exit 0, empty stderr, zero close/error/terminate lines in `sockd.log`.**

**FACT:** On this Dante image/version, **SIGHUP reloads config and does NOT drop an active ESTABLISHED SOCKS session.**

**Evidence:** `G3_dante_sighup_live3_FINAL.txt` (the FACT run, with `/proc/net/tcp` proof + per-chunk timestamps). Note for transparency: `…live.txt` was an **invalid** run (socat `SYSTEM:` shell-quoting bug crashed the slow server → curl exit 52 — NOT a dante verdict, per §11.4.6/§11.4.7); `…live2.txt` was clean (20/20) but curl output buffering hid the mid-stream proof — both superseded by `…live3_FINAL.txt`.

**Design impact:**
- §9 Dante "config rewrite + SIGHUP" dynamism is **SAFE for live sessions** — structural reloads (new tunnel/peer) won't kill in-flight SOCKS connections. No §9 redesign needed.
- **P9 owes a broader live captured-evidence test** (the spike validated one short loopback stream during one reload): real per-tunnel upstreams, **concurrent** sessions, **repeated** SIGHUPs, and a reload that actually **changes the route** for an already-established session (does an in-flight session keep its OLD path or get re-evaluated?). That route-change-mid-session behavior remains `UNCONFIRMED:` and is the substantive P9 question.

---

## Summary table

| Gap | Verdict | Key FACT | Evidence | Spec change |
|---|---|---|---|---|
| G2 | FACT resolved | `ubuntu/squid:latest` = **6.13** (not v8); §8 directives parse exit 0 | `G2_*` | Use `%>ha{Host}`; pin `ubuntu/squid:6.13`; v8 concern moot |
| G4 | FACT resolved | gluetun `v3.40`→**v3.40.4**; control :8000 + healthcheck :9999 confirmed sans VPN; **#3060 confirmed** | `G4_*` | Pin v3.40; add control-server auth on any upgrade past v3.40 |
| G1 | FACT resolved (nuanced) | kernel WG iface **creatable rootless + NET_ADMIN** (gluetun auto-picks kernelspace); userspace = portability fallback | `G1_*`, `G4_…live2` | None — gluetun auto-select is correct; full kernel-WG *operation* rootless still `UNCONFIRMED:` |
| G3 | FACT (spike PASS) | SIGHUP reloads + **preserves** active SOCKS session (20/20, exit 0) | `G3_…live3_FINAL` | None for §9; P9 owes concurrent/repeated/route-change live test |
