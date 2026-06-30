// Prometheus metrics for the control-API (design spec §11 ③, §4 component 4). The
// metric NAMES are pinned to config/prometheus/prometheus.yml job
// `helix-control-plane` (and config/grafana/dashboards/helix-proxy.json), so the
// already-committed scrape + dashboards bind to the live /metrics without re-design:
//
//   - helix_proxy_vpn_up{profile}                  gauge  1=up / 0=down, per known
//     profile, read from Redis
//     vpn:status:<profile> at SCRAPE
//     time (fail-closed: stale/missing
//     ⇒ 0).
//   - helix_proxy_acl_decisions_total{decision}    counter  decision="OK"|"ERR".
//   - helix_proxy_tunnel_down_responses_total      counter  ERR_TUNNEL_DOWN→503.
//
// The two counters are registered + exposed here even though they are incremented
// by the acl-helper / byte-path later (plan P5/P10): registering them now means the
// dashboards render `0` instead of `No data`, and the increment seam (Metrics.Inc*)
// is ready (§11.4.108 wiring before behaviour).
package api

import (
	"context"
	"net/http"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promhttp"

	"digital.vasic.helixproxy/controlplane/internal/redis"
	"digital.vasic.helixproxy/controlplane/internal/store"
	"digital.vasic.helixproxy/controlplane/internal/vpn"
)

// Metric names — single source of truth, asserted by tests against prometheus.yml.
const (
	MetricVPNUp               = "helix_proxy_vpn_up"
	MetricACLDecisionsTotal   = "helix_proxy_acl_decisions_total"
	MetricTunnelDownResponses = "helix_proxy_tunnel_down_responses_total"
)

// Metrics holds the control-API's registered Prometheus collectors. The two
// counters are exported via Inc* methods so the acl-helper / byte-path can drive
// them later without reaching into prometheus directly.
type Metrics struct {
	reg                 *prometheus.Registry
	aclDecisions        *prometheus.CounterVec
	tunnelDownResponses prometheus.Counter
}

// newMetrics builds the registry, registers the counters + the vpn_up collector,
// and returns the Metrics handle. q + bus back the per-scrape vpn_up gauge:
// profiles are enumerated from the store, status read fail-closed from Redis.
func newMetrics(q store.Queries, bus redis.StatusBus) *Metrics {
	reg := prometheus.NewRegistry()
	m := &Metrics{
		reg: reg,
		aclDecisions: prometheus.NewCounterVec(prometheus.CounterOpts{
			Name: MetricACLDecisionsTotal,
			Help: "Total external-acl decisions by outcome (decision=OK|ERR).",
		}, []string{"decision"}),
		tunnelDownResponses: prometheus.NewCounter(prometheus.CounterOpts{
			Name: MetricTunnelDownResponses,
			Help: "Total ERR_TUNNEL_DOWN responses served (fail-closed 503).",
		}),
	}
	reg.MustRegister(m.aclDecisions, m.tunnelDownResponses)
	// Pre-touch the decision label set so both series exist at 0 from first scrape.
	m.aclDecisions.WithLabelValues("OK")
	m.aclDecisions.WithLabelValues("ERR")
	reg.MustRegister(&vpnUpCollector{q: q, bus: bus})
	return m
}

// IncACLDecision records one external-acl decision (decision must be "OK"|"ERR").
func (m *Metrics) IncACLDecision(decision string) {
	if decision != "OK" && decision != "ERR" {
		decision = "ERR"
	}
	m.aclDecisions.WithLabelValues(decision).Inc()
}

// IncTunnelDownResponse records one fail-closed ERR_TUNNEL_DOWN (503) response.
func (m *Metrics) IncTunnelDownResponse() { m.tunnelDownResponses.Inc() }

// handler returns the promhttp scrape handler over this registry.
func (m *Metrics) handler() http.Handler {
	return promhttp.HandlerFor(m.reg, promhttp.HandlerOpts{})
}

// vpnUpCollector emits helix_proxy_vpn_up{profile} at scrape time. It lists known
// profiles from the store and reads each profile's status from the fail-closed
// status bus: 1 only when the bus reports StateUp, else 0 (missing/stale/error ⇒
// 0, never silently up — spec §10). A store error yields no series for that scrape
// (the gauge is simply absent), never a fabricated value (§11.4.6).
type vpnUpCollector struct {
	q   store.Queries
	bus redis.StatusBus
}

var vpnUpDesc = prometheus.NewDesc(
	MetricVPNUp,
	"VPN tunnel data-plane health (1=up, 0=down) per profile, fail-closed from Redis vpn:status:<profile>.",
	[]string{"profile"}, nil,
)

func (c *vpnUpCollector) Describe(ch chan<- *prometheus.Desc) { ch <- vpnUpDesc }

func (c *vpnUpCollector) Collect(ch chan<- prometheus.Metric) {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	profiles, err := c.q.ListProfiles(ctx)
	if err != nil {
		return // no fabricated gauge on a store error (§11.4.6)
	}
	for _, p := range profiles {
		val := 0.0
		// GetStatus is fail-closed: a transport error still yields a DOWN snapshot,
		// so even on a Redis error the gauge reports 0, never up.
		if snap, _ := c.bus.GetStatus(ctx, p.Name); snap.State == vpn.StateUp {
			val = 1.0
		}
		ch <- prometheus.MustNewConstMetric(vpnUpDesc, prometheus.GaugeValue, val, p.Name)
	}
}
