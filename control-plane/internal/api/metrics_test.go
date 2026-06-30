package api

import (
	"context"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"sort"
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

// helixMetricRe matches a helix_proxy_* metric token (lowercase snake; stops at
// the first non-name char, e.g. `{` in `helix_proxy_vpn_up{profile=...}`).
var helixMetricRe = regexp.MustCompile(`helix_proxy_[a-z0-9_]+`)

// sortedKeys returns a map's keys sorted, for stable log output.
func sortedKeys[V any](m map[string]V) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}

// registeredHelixMetricNames returns the set of helix_proxy_* metric family names
// the control-API ACTUALLY registers + exposes — the live "registered collectors"
// source of truth (NOT a hardcoded mirror). A profile is seeded UP so the
// per-scrape vpn_up gauge emits a family (a const-metric collector with no series
// emits no family, so without a profile vpn_up would be absent from Gather).
func registeredHelixMetricNames(t *testing.T) map[string]bool {
	t.Helper()
	q := newFakeQueries()
	bus := newFakeBus()
	if _, err := q.UpsertProfile(context.Background(), store.VPNProfile{
		Name: "drift-probe", Type: store.VPNTypeWireGuard, Enabled: true,
	}); err != nil {
		t.Fatalf("seed profile: %v", err)
	}
	bus.setStatus("drift-probe", vpn.StateUp)
	m := newMetrics(q, bus)
	fams, err := m.reg.Gather() // white-box: same package, real registered registry
	if err != nil {
		t.Fatalf("gather registry: %v", err)
	}
	got := map[string]bool{}
	for _, f := range fams {
		if name := f.GetName(); strings.HasPrefix(name, "helix_proxy_") {
			got[name] = true
		}
	}
	return got
}

// repoFile walks up from the test's working directory to find a committed repo
// file at the given repo-relative path. The control-API Go module lives at
// control-plane/; the observability config lives at the REPO ROOT (one level up),
// OUTSIDE the module — so when the module is built in isolation the files are
// absent and the caller SKIPs (§11.4.3), never fakes a pass.
func repoFile(rel string) (string, bool) {
	dir, err := os.Getwd()
	if err != nil {
		return "", false
	}
	for {
		cand := filepath.Join(dir, rel)
		if _, err := os.Stat(cand); err == nil {
			return cand, true
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			return "", false
		}
		dir = parent
	}
}

// configReferencedHelixMetrics scans the committed observability configs (the
// prometheus scrape config + the grafana dashboard) for every helix_proxy_* token
// and returns metric→files-referencing-it plus the list of config files found.
func configReferencedHelixMetrics(t *testing.T) (map[string][]string, []string) {
	t.Helper()
	configs := []string{
		"config/prometheus/prometheus.yml",
		"config/grafana/dashboards/helix-proxy.json",
	}
	refs := map[string][]string{}
	var found []string
	for _, rel := range configs {
		path, ok := repoFile(rel)
		if !ok {
			continue
		}
		found = append(found, rel)
		b, err := os.ReadFile(path)
		if err != nil {
			t.Fatalf("read %s: %v", rel, err)
		}
		for _, tok := range helixMetricRe.FindAllString(string(b), -1) {
			already := false
			for _, f := range refs[tok] {
				if f == rel {
					already = true
					break
				}
			}
			if !already {
				refs[tok] = append(refs[tok], rel)
			}
		}
	}
	return refs, found
}

// TestMetrics_NamesMatchCommittedObservabilityConfig binds the metric names the
// control-API ACTUALLY registers (gathered from the live registry — source of
// truth #1) to the names the COMMITTED observability config references (the
// prometheus scrape config + grafana dashboard — source of truth #2), in BOTH
// directions, so a rename in EITHER place without the other FAILs:
//
//   - forward (code → config): every registered helix_proxy_* metric MUST be
//     referenced by ≥1 committed config artifact, else a scrape/dashboard would
//     silently lose the series after a code rename.
//   - reverse (config → code): every helix_proxy_* token a committed config
//     references MUST be a metric the code actually registers, else the dashboard
//     points at a metric that no longer exists.
//
// This REPLACES the prior constant-equals-literal assertion, which compared the
// code against a hardcoded mirror of ITSELF and so could not catch drift against
// the real committed config (P6 review WARNING-3). When the module is built in
// isolation the repo-root config is absent → SKIP-with-reason (§11.4.3), never a
// fake pass. §1.1 paired mutation: rename MetricVPNUp's literal in metrics.go →
// the registered name no longer appears in any config (forward FAIL) AND the
// config's helix_proxy_vpn_up token is no longer registered (reverse FAIL).
func TestMetrics_NamesMatchCommittedObservabilityConfig(t *testing.T) {
	registered := registeredHelixMetricNames(t)
	if len(registered) == 0 {
		t.Fatal("no helix_proxy_* metrics registered — the control-API exposes none")
	}
	// Sanity: the exported name constants the rest of the code uses MUST be among
	// the actually-registered names (guards a constant changed without the
	// registration, or a literal hardcoded into a collector instead of the constant).
	for _, c := range []string{MetricVPNUp, MetricACLDecisionsTotal, MetricTunnelDownResponses} {
		if !registered[c] {
			t.Fatalf("exported metric-name constant %q is not actually registered/exposed (registered: %v)", c, sortedKeys(registered))
		}
	}

	refs, found := configReferencedHelixMetrics(t)
	if len(found) == 0 {
		t.Skip("observability config (config/prometheus + config/grafana) not found from module root — running outside the repo tree; cross-config drift check SKIPPED (§11.4.3)")
	}
	t.Logf("registered metrics:        %v", sortedKeys(registered))
	t.Logf("config files scanned:      %v", found)
	t.Logf("config-referenced metrics: %v", sortedKeys(refs))

	// forward: every registered metric is referenced by a committed config.
	for name := range registered {
		if len(refs[name]) == 0 {
			t.Fatalf("metric drift (code→config): registered metric %q is referenced by NO committed observability config %v — rename it in the config too", name, found)
		}
	}
	// reverse: every config-referenced metric is actually registered by the code.
	for name, files := range refs {
		if !registered[name] {
			t.Fatalf("metric drift (config→code): committed config %v references metric %q which the control-API does NOT register — fix the config or the code", files, name)
		}
	}
}
