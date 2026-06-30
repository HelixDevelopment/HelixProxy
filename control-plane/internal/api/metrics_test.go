package api

import (
	"context"
	"net/http"
	"regexp"
	"strings"
	"testing"

	"digital.vasic.helixproxy/controlplane/internal/store"
	"digital.vasic.helixproxy/controlplane/internal/vpn"
)

// TestMetrics_Scrape scrapes the REAL /metrics endpoint over mTLS and asserts the
// exposition body contains the metric NAMES pinned to config/prometheus/
// prometheus.yml (job helix-control-plane) + the live vpn_up gauge per profile.
func TestMetrics_Scrape(t *testing.T) {
	h := newHarness(t)
	c := h.clientWithCert(t)

	// Seed two profiles + their live status: eu-wg UP, us-ovpn DOWN (fail-closed).
	ctx := context.Background()
	_, _ = h.q.UpsertProfile(ctx, store.VPNProfile{Name: "eu-wg", Type: store.VPNTypeWireGuard, Enabled: true})
	_, _ = h.q.UpsertProfile(ctx, store.VPNProfile{Name: "us-ovpn", Type: store.VPNTypeOpenVPN, Enabled: true})
	h.bus.setStatus("eu-wg", vpn.StateUp)
	h.bus.setStatus("us-ovpn", vpn.StateDown)

	// Drive the counters so they expose non-zero too (exercises the Inc seam).
	h.srv.Metrics().IncACLDecision("OK")
	h.srv.Metrics().IncTunnelDownResponse()

	resp, err := c.Get(h.url + "/metrics")
	if err != nil {
		t.Fatalf("scrape /metrics: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("/metrics: want 200, got %d", resp.StatusCode)
	}
	body := readAll(t, resp.Body)

	// The three pinned metric names MUST appear (HELP/TYPE lines exist even at 0).
	for _, name := range []string{MetricVPNUp, MetricACLDecisionsTotal, MetricTunnelDownResponses} {
		if !strings.Contains(body, name) {
			t.Fatalf("/metrics missing metric %q\n---\n%s", name, body)
		}
	}
	// The live gauge reflects fail-closed status: eu-wg=1, us-ovpn=0.
	if !regexp.MustCompile(`helix_proxy_vpn_up\{profile="eu-wg"\}\s+1`).MatchString(body) {
		t.Fatalf("vpn_up{eu-wg} should be 1\n%s", body)
	}
	if !regexp.MustCompile(`helix_proxy_vpn_up\{profile="us-ovpn"\}\s+0`).MatchString(body) {
		t.Fatalf("vpn_up{us-ovpn} should be 0 (fail-closed)\n%s", body)
	}
	// The counters carry the driven increments.
	if !regexp.MustCompile(`helix_proxy_acl_decisions_total\{decision="OK"\}\s+1`).MatchString(body) {
		t.Fatalf("acl_decisions_total{OK} should be 1\n%s", body)
	}
	if !regexp.MustCompile(`helix_proxy_tunnel_down_responses_total\s+1`).MatchString(body) {
		t.Fatalf("tunnel_down_responses_total should be 1\n%s", body)
	}
}

// TestMetrics_NameMatchPrometheusJob is a belt-and-suspenders guard that the
// metric-name constants equal the literals the committed prometheus.yml +
// grafana dashboard expect (so a rename here can't silently break the scrape).
func TestMetrics_NameMatchPrometheusJob(t *testing.T) {
	want := map[string]string{
		MetricVPNUp:               "helix_proxy_vpn_up",
		MetricACLDecisionsTotal:   "helix_proxy_acl_decisions_total",
		MetricTunnelDownResponses: "helix_proxy_tunnel_down_responses_total",
	}
	for got, expect := range want {
		if got != expect {
			t.Fatalf("metric name drift: %q != %q (must match prometheus.yml)", got, expect)
		}
	}
}
