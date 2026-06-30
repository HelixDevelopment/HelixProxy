# Grafana configuration — Helix Proxy (P7 observability)

**Revision:** 1
**Last modified:** 2026-07-01T00:00:00Z
**Status:** **config PLAN — NOT YET LIVE.** Dashboard + provisioning definitions
for the VPN-aware dynamic-routing extension. No Grafana container, no live data
source, and no rendered data exist yet. Per Constitution §11.4.6 nothing here
claims a dashboard renders real metrics.
**Authority:** Inherits the Helix Constitution submodule per §11.4.35.
**Design source:** `docs/superpowers/specs/2026-06-30-vpn-aware-proxy-extension-design.md`
(§11③ observability), `docs/DYNAMIC_ROUTING.md`.

---

## What this is

| Path | Purpose |
|---|---|
| `dashboards/helix-proxy.json` | Provisioning-format dashboard model. Panels: **cache hit ratio**, **request rate**, **503 / ERR_TUNNEL_DOWN rate**, **per-tunnel VPN up/down**, plus a top text panel documenting metric provenance. |
| `provisioning/dashboards/helix-proxy.yml` | File provider telling Grafana where to load the dashboard JSON. |
| `provisioning/datasources/prometheus.yml` | Prometheus data source (forward reference to the P10 Prometheus service). |

## Panels & their metrics (provenance — §11.4.6)

| Panel | Metric (PromQL) | Provenance / confidence |
|---|---|---|
| Cache hit ratio | `squid_client_http_hits_total / squid_client_http_requests_total` | `boynux/squid-exporter` (spec §11③). Exact `squid_*` names confirmed live against Squid 6.13 `mgr:counters` in **P10**. |
| Request rate | `rate(squid_client_http_requests_total[5m])` | same exporter; confirmed live **P10**. |
| 503 / ERR_TUNNEL_DOWN rate | `rate(helix_proxy_tunnel_down_responses_total[5m])` | **PLANNED custom** control-plane counter (acl-helper → `deny_info 503`), built P5/P6. Speculative name — confirmed/renamed **P10**. |
| Per-tunnel VPN up/down | `helix_proxy_vpn_up{profile}` | **PLANNED custom** control-plane gauge from Redis `vpn:status:<profile>` (health-publisher, P3/P6), or a future vpn-status exporter. Speculative name — confirmed/renamed **P10**. |

> JSON has no comment syntax, so each panel's `description` field carries the
> speculative-metric flag, and the dashboard's first **text panel** restates the
> provenance table. This is the in-JSON "comment" required by the §11.4.6
> no-guessing framing.

## What IS provable now vs. what is owed to P10

- **Provable now:** every JSON file is well-formed — validated with `jq`.
  Evidence: `qa-results/p7-observability/jq_validate.txt`.
- **NOT proven now (owed to P10):** that Grafana loads the dashboard, that the
  data source resolves, that any panel renders real metrics. "Dashboard renders
  real data" requires a live Prometheus scraping live targets — a **P10**
  deliverable (§11.4.6 / §11.4.123). The host-rendered pixel proof of any UI
  surface (§11.4.170) is likewise owed to P10, not claimed here.

## Re-validate locally (structural only)

```sh
jq . config/grafana/dashboards/helix-proxy.json >/dev/null && echo "dashboard JSON OK"
```
