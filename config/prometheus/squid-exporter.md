# squid-exporter wiring note (P7 observability — config PLAN, NOT yet live)

**Revision:** 1
**Last modified:** 2026-07-01T00:00:00Z
**Status:** DESIGN / config-PLAN only. The exporter container is **not** wired
yet — it is brought up by the P10 integration step. Per Constitution §11.4.6
nothing below is claimed to be scraping live data; the "exporter republishes
real Squid metrics" proof is owed to P10.
**Authority:** Inherits the Helix Constitution submodule per §11.4.35.
**Source:** spec §11③ (`boynux/squid-exporter`), `docs/DYNAMIC_ROUTING.md`,
`.env.example` (`HTTP_PROXY_PORT=53128`).

---

## Which image

- **`boynux/squid-exporter`** (the exporter named in the design spec §11③ —
  "③ observability — `boynux/squid-exporter` + Prometheus + Grafana + OTel").
- Consumed as a published container image (extend-don't-reimplement, §11.4.74);
  pin by a specific tag or digest at P10 wiring time (§11.4.6 — no floating
  `:latest` in the eventual compose).
- Runs **rootless** alongside the rest of the stack (§11.4.161); orchestrated
  via the containers submodule at P10, not an ad-hoc `podman run` (§11.4.76).

## What it scrapes (the Squid side)

`boynux/squid-exporter` connects to Squid's **cache-manager** interface — the
`mgr:` / `cache_object://` reports (e.g. `mgr:counters`, `mgr:info`) — over the
Squid HTTP port and translates the counters into Prometheus `squid_*` metrics.

- **Squid endpoint:** `proxy-squid:53128` (`HTTP_PROXY_PORT` from `.env.example`).
- **Requirement (P4/P10):** Squid's `squid.conf` must permit the cache-manager
  query from the exporter's source (an `http_access allow manager <acl>` for the
  exporter container). That ACL change lives in `config/squid/` (P4 scope) —
  **out of scope here**; this note only records the dependency.
- Squid base is **6.13** (spec §20 G2) — the `mgr:` reports are available; exact
  counter→metric naming is confirmed against the live 6.13 report in P10.

## Port

- The exporter listens on its own HTTP port, default **`:9301`**, exposing
  `/metrics`. This is the port Prometheus job `squid-exporter` scrapes
  (`proxy-squid-exporter:9301` in `prometheus.yml`).
- Configurable via the exporter's `-listen` flag / `SQUID_EXPORTER_LISTEN` env
  at P10 if `:9301` collides.

## Metrics it produces (used by the Grafana dashboard)

The boynux exporter maps Squid counters to `squid_*` series. The dashboard uses:

| Metric (planned name)              | Used for                          | Confidence |
|------------------------------------|-----------------------------------|------------|
| `squid_client_http_requests_total` | request rate, hit-ratio denominator | exporter counter mapping — confirm live P10 |
| `squid_client_http_hits_total`     | cache-hit-ratio numerator         | exporter counter mapping — confirm live P10 |
| `squid_client_http_kbytes_out_total` | egress volume (optional panel)   | exporter counter mapping — confirm live P10 |

> §11.4.6: the exact `squid_*` names depend on the exporter version and the
> Squid 6.13 `mgr:counters` report; they are **verified against live exporter
> output in P10**, not asserted here. Anything the dashboard references that is
> NOT a `squid_*` exporter metric (per-tunnel VPN up/down, 503/ERR_TUNNEL_DOWN
> rate) is a **planned custom control-plane metric** (see `prometheus.yml` job
> `helix-control-plane`), not produced by this exporter.

## Not in scope of this note

Compose service definition, the Squid cachemgr ACL, network wiring, and the
live "metrics are flowing" proof are all **P10**. This note is the
forward-reference plan only.
