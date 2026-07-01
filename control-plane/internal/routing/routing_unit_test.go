// Unit tests for the config-compiler renderers + route resolution. PURE (no I/O):
// golden-file render comparison + a route-resolution table. Mocks are permitted at
// the unit layer ONLY (§11.4.27) — CompileAll is exercised against an in-memory
// fakeQueries. The data-plane structural proof (rendered Squid `squid -k parse`
// exit 0) lives in routing_integration_test.go against a REAL Squid (§11.4.69).
//
// Regenerate golden files: go test ./internal/routing -run Golden -update
package routing

import (
	"context"
	"flag"
	"os"
	"path/filepath"
	"testing"

	"digital.vasic.helixproxy/controlplane/internal/redis"
	"digital.vasic.helixproxy/controlplane/internal/store"
)

var update = flag.Bool("update", false, "regenerate golden files")

// --- fixture -----------------------------------------------------------------

func fixtureProfiles() []store.VPNProfile {
	return []store.VPNProfile{
		{ID: "p-apac", Name: "apac-ovpn", Type: store.VPNTypeOpenVPN,
			Config: []byte(`{"peer_host":"gluetun-apac","peer_port":3129}`), Enabled: true},
		{ID: "p-eu", Name: "eu-wg-primary", Type: store.VPNTypeWireGuard,
			Config: []byte(`{"endpoint":"vpn-eu.example:51820"}`), Enabled: true},
		{ID: "p-legacy", Name: "legacy-openvpn", Type: store.VPNTypeLegacy, Enabled: false},
		{ID: "p-us", Name: "us-wg-failover", Type: store.VPNTypeWireGuard, Enabled: true},
	}
}

func fixtureTargets() []store.TargetHost {
	return []store.TargetHost{
		{ID: "t-wiki", PublicAlias: "internal-wiki.helix", PrivateIP: "10.10.5.20", Port: 443, Protocol: "https", VPNProfileID: "p-eu", Enabled: true},
		{ID: "t-metrics", PublicAlias: "metrics.helix", PrivateIP: "10.10.5.30", Port: 9090, Protocol: "http", VPNProfileID: "p-eu", Enabled: true},
		{ID: "t-db", PublicAlias: "db-bastion.helix", PrivateIP: "10.20.7.10", Port: 5432, Protocol: "tcp", VPNProfileID: "p-us", Enabled: true},
		{ID: "t-disabled", PublicAlias: "disabled.helix", PrivateIP: "10.10.5.99", Port: 80, Protocol: "http", VPNProfileID: "p-eu", Enabled: false},
	}
}

func fixtureTiers() map[string][]store.TargetTunnelTier {
	return map[string][]store.TargetTunnelTier{
		"t-wiki":    {{TargetID: "t-wiki", VPNProfileID: "p-eu", Tier: 0}, {TargetID: "t-wiki", VPNProfileID: "p-us", Tier: 1}},
		"t-metrics": {{TargetID: "t-metrics", VPNProfileID: "p-eu", Tier: 0}, {TargetID: "t-metrics", VPNProfileID: "p-apac", Tier: 1}},
		// t-db has NO tier rows → falls back to target.VPNProfileID (p-us).
	}
}

// fakeQueries is an in-memory store.Queries (unit-test mock, §11.4.27).
type fakeQueries struct {
	profiles []store.VPNProfile
	targets  []store.TargetHost
	tiers    map[string][]store.TargetTunnelTier
}

func (f *fakeQueries) ListProfiles(context.Context) ([]store.VPNProfile, error) {
	return f.profiles, nil
}
func (f *fakeQueries) ListTargets(context.Context) ([]store.TargetHost, error) { return f.targets, nil }
func (f *fakeQueries) ListTiers(_ context.Context, id string) ([]store.TargetTunnelTier, error) {
	return f.tiers[id], nil
}

// unused-by-compiler methods (contract completeness).
func (f *fakeQueries) GetProfile(context.Context, string) (store.VPNProfile, error) {
	return store.VPNProfile{}, nil
}
func (f *fakeQueries) UpsertProfile(context.Context, store.VPNProfile) (string, error) {
	return "", nil
}
func (f *fakeQueries) DeleteProfile(context.Context, string) error { return nil }
func (f *fakeQueries) GetTargetHost(context.Context, string) (store.TargetHost, error) {
	return store.TargetHost{}, nil
}
func (f *fakeQueries) UpsertTarget(context.Context, store.TargetHost) (string, error) { return "", nil }
func (f *fakeQueries) DeleteTarget(context.Context, string) error                     { return nil }
func (f *fakeQueries) ListRules(context.Context) ([]store.ProxyRule, error)           { return nil, nil }
func (f *fakeQueries) GetRuleByHost(context.Context, string) (store.ProxyRule, error) {
	return store.ProxyRule{}, nil
}
func (f *fakeQueries) UpsertRule(context.Context, store.ProxyRule) (string, error) { return "", nil }
func (f *fakeQueries) DeleteRule(context.Context, string) error                    { return nil }
func (f *fakeQueries) UpsertTier(context.Context, store.TargetTunnelTier) error    { return nil }
func (f *fakeQueries) DeleteTier(context.Context, string, int) error               { return nil }
func (f *fakeQueries) ListUsers(context.Context) ([]store.ProxyUser, error)        { return nil, nil }
func (f *fakeQueries) UpsertUser(context.Context, store.ProxyUser) (string, error) { return "", nil }
func (f *fakeQueries) AppendAudit(context.Context, store.AuditLogEntry) error      { return nil }

// WithTx satisfies the contract; the compiler/routing path is read-only, so it just
// runs fn against this fake (no mutation to roll back).
func (f *fakeQueries) WithTx(ctx context.Context, fn func(store.Queries) error) error {
	return fn(f)
}

var _ store.Queries = (*fakeQueries)(nil)

// --- golden render tests -----------------------------------------------------

func goldenCompare(t *testing.T, name string, got []byte) {
	t.Helper()
	path := filepath.Join("testdata", name)
	if *update {
		if err := os.WriteFile(path, got, 0o644); err != nil {
			t.Fatalf("write golden %s: %v", name, err)
		}
		t.Logf("updated golden %s (%d bytes)", name, len(got))
		return
	}
	want, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read golden %s: %v (run with -update to create)", name, err)
	}
	if string(got) != string(want) {
		t.Errorf("render mismatch for %s:\n--- got ---\n%s\n--- want ---\n%s", name, got, want)
	}
}

func TestGoldenSquidInclude(t *testing.T) {
	tunnels := ResolveTunnels(fixtureProfiles())
	goldenCompare(t, "squid_dynamic.golden", RenderSquidInclude("/bin/true", tunnels))
}

func TestGoldenDanteRoutes(t *testing.T) {
	routes := []DanteRoute{
		{Name: "tun_eu-wg-primary", TargetCIDR: "10.10.5.20", PeerHost: "gluetun-eu-wg-primary", PeerPort: 8888},
		{Name: "tun_eu-wg-primary", TargetCIDR: "10.10.5.30", PeerHost: "gluetun-eu-wg-primary", PeerPort: 8888},
		{Name: "tun_us-wg-failover", TargetCIDR: "10.20.7.10", PeerHost: "gluetun-us-wg-failover", PeerPort: 8888},
	}
	goldenCompare(t, "dante_routes.golden", RenderDanteRoutes(routes))
}

func TestGoldenPAC(t *testing.T) {
	aliases := []string{"internal-wiki.helix", "metrics.helix", "db-bastion.helix"}
	goldenCompare(t, "pac.golden", RenderPAC(DefaultPACProxy, aliases))
}

// --- resolution behaviour ----------------------------------------------------

func TestResolveTunnels_ExcludesDisabled_AppliesOverrides(t *testing.T) {
	tunnels := ResolveTunnels(fixtureProfiles())
	if len(tunnels) != 3 {
		t.Fatalf("want 3 enabled tunnels (legacy excluded), got %d: %+v", len(tunnels), tunnels)
	}
	// Sorted by profile name: apac-ovpn, eu-wg-primary, us-wg-failover.
	if tunnels[0].Profile != "apac-ovpn" || tunnels[1].Profile != "eu-wg-primary" || tunnels[2].Profile != "us-wg-failover" {
		t.Errorf("tunnels not name-sorted: %+v", tunnels)
	}
	// apac override host/port from config jsonb.
	if tunnels[0].PeerHost != "gluetun-apac" || tunnels[0].PeerPort != 3129 {
		t.Errorf("config peer_host/peer_port override not applied: %+v", tunnels[0])
	}
	// eu uses deterministic defaults.
	if tunnels[1].PeerHost != "gluetun-eu-wg-primary" || tunnels[1].PeerPort != DefaultPeerPort {
		t.Errorf("default peer endpoint wrong: %+v", tunnels[1])
	}
	if tunnels[1].Name != "tun_eu-wg-primary" {
		t.Errorf("tunnel name token wrong: %q", tunnels[1].Name)
	}
}

func TestPrimaryTunnel_Table(t *testing.T) {
	nameByID := map[string]string{"p-eu": "eu-wg-primary", "p-us": "us-wg-failover", "p-apac": "apac-ovpn"}
	cases := []struct {
		name        string
		tgt         store.TargetHost
		tiers       []store.TargetTunnelTier
		wantProfile string
		wantTier    int
		wantOK      bool
	}{
		{"tier0-wins", store.TargetHost{VPNProfileID: "p-us"},
			[]store.TargetTunnelTier{{VPNProfileID: "p-eu", Tier: 0}, {VPNProfileID: "p-us", Tier: 1}}, "eu-wg-primary", 0, true},
		{"fallback-to-target-profile", store.TargetHost{VPNProfileID: "p-us"}, nil, "us-wg-failover", 0, true},
		{"orphan-unresolvable", store.TargetHost{VPNProfileID: "p-gone"}, nil, "", 0, false},
		{"tier-points-to-missing-profile", store.TargetHost{VPNProfileID: "p-eu"},
			[]store.TargetTunnelTier{{VPNProfileID: "p-gone", Tier: 0}}, "", 0, false},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			gotProfile, gotTier, ok := primaryTunnel(c.tgt, c.tiers, nameByID)
			if ok != c.wantOK || gotProfile != c.wantProfile || gotTier != c.wantTier {
				t.Errorf("primaryTunnel = (%q,%d,%v), want (%q,%d,%v)",
					gotProfile, gotTier, ok, c.wantProfile, c.wantTier, c.wantOK)
			}
		})
	}
}

func TestCompileAll_ArtifactsAndRoutes(t *testing.T) {
	q := &fakeQueries{profiles: fixtureProfiles(), targets: fixtureTargets(), tiers: fixtureTiers()}
	eng := New("/bin/true", "")
	arts, routes, err := eng.CompileAll(context.Background(), q)
	if err != nil {
		t.Fatalf("CompileAll: %v", err)
	}
	// 3 enabled targets resolve to a route (disabled.helix excluded).
	if len(routes) != 3 {
		t.Fatalf("want 3 routes, got %d: %+v", len(routes), routes)
	}
	byTarget := map[string]redis.Route{}
	for _, r := range routes {
		byTarget[r.Target] = r
	}
	if r := byTarget["internal-wiki.helix"]; r.Tunnel != "eu-wg-primary" || r.Tier != 0 || r.BreakerState != "closed" {
		t.Errorf("wiki route wrong: %+v", r)
	}
	if r := byTarget["db-bastion.helix"]; r.Tunnel != "us-wg-failover" || r.Tier != 0 {
		t.Errorf("db route (tier fallback) wrong: %+v", r)
	}
	if _, ok := byTarget["disabled.helix"]; ok {
		t.Error("disabled target must not produce a route")
	}
	// Artifacts non-empty + structurally present.
	for _, kv := range []struct {
		name string
		b    []byte
		want string
	}{
		{"squid", arts.SquidInclude, "external_acl_type vpn_route"},
		{"squid-peer", arts.SquidInclude, "cache_peer gluetun-eu-wg-primary parent 8888 0 no-query name=tun_eu-wg-primary"},
		{"squid-failclosed", arts.SquidInclude, "http_access deny !tun_up"},
		{"dante", arts.DanteRoutes, "to: 10.10.5.20"},
		{"pac", arts.PAC, "function FindProxyForURL"},
		{"pac-target", arts.PAC, "internal-wiki.helix"},
	} {
		if !contains(kv.b, kv.want) {
			t.Errorf("%s artifact missing %q", kv.name, kv.want)
		}
	}
}

func contains(b []byte, s string) bool {
	return string(b) != "" && (len(s) == 0 || indexOf(string(b), s) >= 0)
}
func indexOf(h, n string) int {
	for i := 0; i+len(n) <= len(h); i++ {
		if h[i:i+len(n)] == n {
			return i
		}
	}
	return -1
}
