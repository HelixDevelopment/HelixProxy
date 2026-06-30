# Prometheus configuration — Helix Proxy (P7 observability)

**Revision:** 1
**Last modified:** 2026-07-01T00:00:00Z
**Status:** **config PLAN — NOT YET LIVE.** This directory defines the *intended*
Prometheus scrape topology for the VPN-aware dynamic-routing extension. The
scrape targets do **not** exist yet; they are built in later phases. Per
Constitution §11.4.6 (no-guessing) nothing here claims metrics are flowing.
**Authority:** Inherits the Helix Constitution submodule per §11.4.35.
**Design source:** `docs/superpowers/specs/2026-06-30-vpn-aware-proxy-extension-design.md`
(§11③ observability), `docs/DYNAMIC_ROUTING.md`, `.env.example`.

---

## What this is

| File | Purpose |
|---|---|
| `prometheus.yml` | Scrape config: `prometheus` self-scrape, `helix-control-plane` (`/metrics` on `METRICS_PORT` 59090), `squid-exporter` (`boynux/squid-exporter` on :9301). |
| `squid-exporter.md` | Which exporter image, what it scrapes (Squid `mgr:` cache-manager), and its port. |

## What is built when (honest phasing — §11.4.6)

- **Control-plane `/metrics`** (job `helix-control-plane`) → built in **P6**
  (control-API + admin UI). The planned custom metrics (`helix_proxy_vpn_up`,
  `helix_proxy_tunnel_down_responses_total`, …) are emitted there.
- **squid-exporter** (job `squid-exporter`) → container wired in **P7/P10**.
- **Compose/integration wiring** (service names, network, Prometheus container
  itself) → owned by **P10**. The `proxy-*` target hostnames in `prometheus.yml`
  are forward references finalized there.

## What IS provable now vs. what is owed to P10

- **Provable now (this phase):** the scrape config is **structurally valid** —
  `promtool check config` exits 0. Evidence:
  `qa-results/p7-observability/promtool_check.txt`.
- **NOT proven now (owed to P10):** that any target is reachable or scrapable,
  that any metric actually flows, or that the Grafana dashboard renders real
  data. `promtool` validates STRUCTURE ONLY — it never contacts a target. The
  live scrape + "dashboard renders real metrics" proof is a P10 deliverable
  (§11.4.6 / §11.4.123 — no metadata-only PASS substituted for runtime proof).

## Re-validate locally (structural only, rootless §11.4.161)

```sh
podman run --rm -v "$PWD/config/prometheus:/c:ro,Z" \
  --entrypoint promtool prom/prometheus:latest \
  check config /c/prometheus.yml
# exit 0 == structurally valid (does NOT prove any target is up)
```
