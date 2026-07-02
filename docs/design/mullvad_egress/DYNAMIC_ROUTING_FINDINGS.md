# Dynamic-routing MVP findings — proxy-through-gluetun (Mullvad) e2e

**Revision:** 3
**Last modified:** 2026-07-02T20:22:00Z

Operator-authorized (2026-07-02): reset podman + prove the full proxy-through-gluetun
Mullvad e2e. This document records the honest results (§11.4.6) — what is proven and the
real MVP dynamic-routing defects that block the full squid-integrated path.

## Proven live (rock-solid captured evidence)

- **podman/aardvark-dns is NOT broken** — throwaway inter-container DNS (`10.89.2.2`) and
  outbound DNS both resolve; the earlier "can't bind :53" fault has cleared. **No destructive
  `podman system reset` was done** — it would have destroyed the operator's 263 volumes
  (catalogizer/deploy/aosp/lava data — §9.2/§11.4.174).
- **squid-dynamic image rebuilt** (control-plane + squid multi-stage, `config/squid` context)
  → bakes `http_port :34128` (E's §11.4.108 staleness RESOLVED; source was already 34128).
- **Dynamic stack boots**; **gluetun WireGuard tunnel to Mullvad is UP** (exits observed
  Osaka / Denver / Malmö — public IP is a Mullvad exit each boot).
- **CORE proxy-through-gluetun egress PROVEN**: `http_proxy=http://proxy-gluetun:8888` →
  `am.i.mullvad.net/json` = `mullvad_exit_ip:true` (194.114.136.116, Osaka).
  Evidence `qa-results/dynamic_e2e_20260702T175536Z/`.
- **Squid dynamic-routing LOGIC proven**: un-routed target → fail-closed `TCP_DENIED/503
  ERR_TUNNEL_DOWN` (§11.4.68); with a `route:<host:port>` + up-status the acl-helper returns
  `OK tag=<tunnel>` and squid flips to `TCP_TUNNEL` (allowed). The decision engine works.

## Open MVP dynamic-routing DEFECTS (the full squid-integrated path does NOT yet pass)

| # | Defect | Status |
|---|---|---|
| D1 | Compiler renders `cache_peer gluetun-<profile>` but the MVP ships one `proxy-gluetun` → peers unresolvable → all routed targets 503. | **FIXED** `068dc78` (network aliases on the gluetun compose service). |
| D2 | Route key is port-qualified: squid `%>ha{Host}` sends `host:443` on CONNECT, so routes must be `route:<host>:<port>`. | Documented (compiler/doc note). |
| D3 | **healthd↔gluetun health signal BROKEN**: gluetun control API (`/v1/publicip/ip`, `/v1/vpn/status`) returns EMPTY; healthd's `wg show <if>` reads a WG interface in gluetun's netns (not healthd's) → every profile held falsely "down" → squid fail-closes even though the tunnel is genuinely UP. | **FIXED** `4a69225` (#79) + activated `2cd7f64`. Took a THIRD path (neither doc option): healthd does a FRESH per-poll through-tunnel liveness PROBE via gluetun's built-in `:8888` HTTP forward proxy — a real request egresses via the tunnel + returns THIS cycle (kill-switch blocks it when down ⇒ fail-closed). Additive to DecideHealth (§11.4.68-preserved, wg path intact), default-OFF until `HEALTHD_TUNNEL_PROXY` set. **LIVE-PROVEN**: the fixed healthd publishes `state=up` for the live Mullvad tunnel (`qa-results/dynamic/d3_healthd_live_20260702T200259Z/` + `d3_liveprobe_…195836Z/`). |
| D4 | gluetun compose **healthcheck probes `/v1/openvpn/status`** for a WireGuard tunnel → gluetun labelled "unhealthy" though the WG tunnel is up. | **FIXED** `57cc857`: healthcheck → VPN-agnostic `/v1/vpn/status` + a read-only gluetun control-auth config (gluetun v3.40 made control routes private/401) so healthd + the healthcheck stop 401ing. Live-validated (gluetun healthy; status 200; mutating routes 401) + §11.4.135 guard. |
| D5 | Squid caches the `gluetun-*` peer **negative DNS** from its pre-alias startup; reconfigure did not clear it (peer stays dead). Needs squid to (re)resolve peers after gluetun is up (startup ordering / DNS lifecycle). | **FIXED** `973ff59` (#81): a `config/squid/wait-for-gluetun.sh` ENTRYPOINT wrapper (baked via Containerfile.dynamic) waits (bounded, fail-open-safe) for a `gluetun-*` peer alias to resolve, so squid's startup peer resolution is POSITIVE-cached, then execs the base entrypoint unchanged. Root cause confirmed by §11.4.150 research (squid resolves cache_peer names only at startup + caches NXDOMAIN with no reliable retry); podman-compose ignores `depends_on: service_healthy` so a container-level wait is the reliable mechanism. Independently reviewed GO (6/6); logic-validated standalone (resolve→exec, nxdomain→fail-open bounded). Engages on the next squid image rebuild. |

## Honest conclusion (§11.4.6)

The proxy-through-gluetun **egress capability** is proven live (gluetun's proxy egresses via
Mullvad). **Rev 3 update (2026-07-02): ALL THREE deep blockers (D3, D4, D5) are now FIXED** (this
session): D3 (the deepest — healthd false-down) by the fresh through-tunnel liveness probe (#79,
LIVE-PROVEN healthd publishes `state=up`), D4 by the gluetun control-auth + VPN-agnostic healthcheck
(live-validated), and D5 (squid peer negative-DNS) by the startup wait-for-gluetun ENTRYPOINT wrapper
(#81, independently reviewed GO + logic-validated). Each fix's mechanism is proven live individually
(D3 healthd=up; D4 gluetun healthy + auth-enforced; D5 the peer alias resolves on a fresh start).
**Remaining to a passing FULL e2e: only the DEPLOY** — a `./start --dynamic` that rebuilds the
control-plane image (so the running proxy-healthd carries the #79 D3 binary — it's currently the old
always-down build) and the squid image (so it carries the D5 entrypoint), then redeploys. With
D3+D4+D5 all deployed + healthd=up: `curl -x http://127.0.0.1:34128 <a routed host:port>` egresses
via the mullvad exit (mullvad_exit_ip=true), NOT the branded 503. Honest boundary (§11.4.6): the full
squid-integrated e2e is **not yet claimed PASS** — the source fixes are complete + individually
proven, but the composed e2e is proven only after the rebuild+redeploy. D1 fixed; D2 documented;
**D3+D4+D5 FIXED**; full-e2e = the deploy step.
