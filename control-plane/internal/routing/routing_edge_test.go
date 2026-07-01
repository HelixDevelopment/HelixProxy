// Edge / error / fallback coverage for the config-compiler (§11.4.6 no-guessing:
// every skip + error path is asserted, not assumed). PURE + in-memory fakes only
// (unit layer, §11.4.27). These complement routing_unit_test.go's golden + happy
// path by exercising the fail-closed skips (orphan target, disabled primary
// tunnel), the store error propagation, and the renderer/token fallbacks.
package routing

import (
	"context"
	"errors"
	"testing"

	"digital.vasic.helixproxy/controlplane/internal/store"
)

// errQueries wraps fakeQueries to inject store errors on the three read calls the
// compiler makes, so CompileAll's error-propagation branches are exercised against
// a real (wrapped-error) failure rather than a happy fake.
type errQueries struct {
	*fakeQueries
	profilesErr error
	targetsErr  error
	tiersErr    error
}

func (e *errQueries) ListProfiles(ctx context.Context) ([]store.VPNProfile, error) {
	if e.profilesErr != nil {
		return nil, e.profilesErr
	}
	return e.fakeQueries.ListProfiles(ctx)
}
func (e *errQueries) ListTargets(ctx context.Context) ([]store.TargetHost, error) {
	if e.targetsErr != nil {
		return nil, e.targetsErr
	}
	return e.fakeQueries.ListTargets(ctx)
}
func (e *errQueries) ListTiers(ctx context.Context, id string) ([]store.TargetTunnelTier, error) {
	if e.tiersErr != nil {
		return nil, e.tiersErr
	}
	return e.fakeQueries.ListTiers(ctx, id)
}

var _ store.Queries = (*errQueries)(nil)

// TestCompile_DelegatesToCompileAll proves the Compiler-interface method returns the
// SAME artifacts CompileAll produces (it drops only the []redis.Route). Guards
// against Compile diverging from CompileAll's render.
func TestCompile_DelegatesToCompileAll(t *testing.T) {
	q := &fakeQueries{profiles: fixtureProfiles(), targets: fixtureTargets(), tiers: fixtureTiers()}
	eng := New("/bin/true", "")

	arts, err := eng.Compile(context.Background(), q)
	if err != nil {
		t.Fatalf("Compile: %v", err)
	}
	wantArts, _, err := eng.CompileAll(context.Background(), q)
	if err != nil {
		t.Fatalf("CompileAll: %v", err)
	}
	if string(arts.SquidInclude) != string(wantArts.SquidInclude) {
		t.Errorf("Compile SquidInclude diverges from CompileAll")
	}
	if string(arts.DanteRoutes) != string(wantArts.DanteRoutes) {
		t.Errorf("Compile DanteRoutes diverges from CompileAll")
	}
	if string(arts.PAC) != string(wantArts.PAC) {
		t.Errorf("Compile PAC diverges from CompileAll")
	}
	// Sanity: delegation actually produced content (not two empty structs matching).
	if len(arts.SquidInclude) == 0 {
		t.Fatal("Compile returned empty SquidInclude — delegation produced nothing")
	}
}

// TestCompileAll_StoreErrorsPropagate proves each store read failure aborts the
// compile with a wrapped error (the sentinel is recoverable via errors.Is) — a
// compiler that swallowed a store error would silently emit a fail-open artifact.
func TestCompileAll_StoreErrorsPropagate(t *testing.T) {
	sentinel := errors.New("boom")
	base := func() *fakeQueries {
		return &fakeQueries{profiles: fixtureProfiles(), targets: fixtureTargets(), tiers: fixtureTiers()}
	}
	cases := []struct {
		name    string
		q       *errQueries
		wantSub string
	}{
		{"list-profiles", &errQueries{fakeQueries: base(), profilesErr: sentinel}, "list profiles"},
		{"list-targets", &errQueries{fakeQueries: base(), targetsErr: sentinel}, "list targets"},
		{"list-tiers", &errQueries{fakeQueries: base(), tiersErr: sentinel}, "list tiers"},
	}
	eng := New("/bin/true", "")
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			arts, routes, err := eng.CompileAll(context.Background(), c.q)
			if err == nil {
				t.Fatalf("want error, got nil (routes=%d)", len(routes))
			}
			if !errors.Is(err, sentinel) {
				t.Errorf("error does not wrap sentinel: %v", err)
			}
			if !contains([]byte(err.Error()), c.wantSub) {
				t.Errorf("error %q missing context %q", err.Error(), c.wantSub)
			}
			// On error the artifacts + routes MUST be the zero set (no partial render).
			if len(arts.SquidInclude) != 0 || len(arts.DanteRoutes) != 0 || len(arts.PAC) != 0 || routes != nil {
				t.Errorf("error path leaked partial output: arts=%+v routes=%+v", arts, routes)
			}
		})
	}
}

// TestCompileAll_ListTiersError_NamesTarget proves the list-tiers error carries the
// offending target's public alias (so an operator can find the bad row).
func TestCompileAll_ListTiersError_NamesTarget(t *testing.T) {
	q := &errQueries{
		fakeQueries: &fakeQueries{
			profiles: fixtureProfiles(),
			targets:  []store.TargetHost{{ID: "t-x", PublicAlias: "boom-target.helix", PrivateIP: "10.0.0.1", VPNProfileID: "p-eu", Enabled: true}},
		},
		tiersErr: errors.New("db down"),
	}
	_, _, err := New("/bin/true", "").CompileAll(context.Background(), q)
	if err == nil {
		t.Fatal("want tiers error, got nil")
	}
	if !contains([]byte(err.Error()), "boom-target.helix") {
		t.Errorf("tiers error %q missing target alias", err.Error())
	}
}

// TestCompileAll_SkipsOrphanTarget proves an enabled target whose primary tunnel is
// UNRESOLVABLE (VPNProfileID points at a profile that does not exist, no tiers) is
// skipped fail-closed — no route, no Dante block — rather than guessed.
func TestCompileAll_SkipsOrphanTarget(t *testing.T) {
	q := &fakeQueries{
		profiles: []store.VPNProfile{{ID: "p-eu", Name: "eu-wg-primary", Enabled: true}},
		targets: []store.TargetHost{
			{ID: "t-ok", PublicAlias: "ok.helix", PrivateIP: "10.0.0.1", VPNProfileID: "p-eu", Enabled: true},
			{ID: "t-orphan", PublicAlias: "orphan.helix", PrivateIP: "10.0.0.2", VPNProfileID: "p-gone", Enabled: true},
		},
	}
	arts, routes, err := New("/bin/true", "").CompileAll(context.Background(), q)
	if err != nil {
		t.Fatalf("CompileAll: %v", err)
	}
	if len(routes) != 1 || routes[0].Target != "ok.helix" {
		t.Fatalf("orphan target not skipped: routes=%+v", routes)
	}
	if contains(arts.DanteRoutes, "10.0.0.2") {
		t.Error("orphan target 10.0.0.2 must not appear in Dante routes")
	}
	// The orphan alias IS still advertised in the PAC (enabled targets are listed),
	// but produces no egress route — proving the skip is at route resolution only.
	if !contains(arts.PAC, "orphan.helix") {
		t.Error("enabled orphan alias should still be in the PAC alias list")
	}
}

// TestCompileAll_SkipsTargetWithDisabledPrimaryTunnel proves a target whose primary
// tunnel RESOLVES BY NAME (the profile exists) but is DISABLED (so it has no
// cache_peer) is skipped — the peerByProfile miss branch, distinct from the orphan
// (unresolvable-name) branch above.
func TestCompileAll_SkipsTargetWithDisabledPrimaryTunnel(t *testing.T) {
	q := &fakeQueries{
		profiles: []store.VPNProfile{
			{ID: "p-eu", Name: "eu-wg-primary", Enabled: true},
			{ID: "p-legacy", Name: "legacy-openvpn", Enabled: false}, // named but no cache_peer
		},
		targets: []store.TargetHost{
			{ID: "t-ok", PublicAlias: "ok.helix", PrivateIP: "10.0.0.1", VPNProfileID: "p-eu", Enabled: true},
			{ID: "t-disabledtun", PublicAlias: "legacy.helix", PrivateIP: "10.0.0.9", VPNProfileID: "p-legacy", Enabled: true},
		},
	}
	arts, routes, err := New("/bin/true", "").CompileAll(context.Background(), q)
	if err != nil {
		t.Fatalf("CompileAll: %v", err)
	}
	if len(routes) != 1 || routes[0].Target != "ok.helix" {
		t.Fatalf("target on disabled tunnel not skipped: routes=%+v", routes)
	}
	if contains(arts.DanteRoutes, "10.0.0.9") {
		t.Error("target routed through disabled tunnel must not appear in Dante routes")
	}
	// Disabled profile must NOT have emitted a cache_peer either.
	if contains(arts.SquidInclude, "legacy-openvpn") {
		t.Error("disabled profile must not produce a cache_peer")
	}
}

// TestPeerEndpoint_ConfigVariants exercises the peer_host / peer_port override
// resolution: string peer_port (the previously-uncovered branch), non-positive /
// non-numeric strings falling back to the default, and malformed JSON falling back
// to the deterministic gluetun-<name>:DefaultPeerPort endpoint (§11.4.6).
func TestPeerEndpoint_ConfigVariants(t *testing.T) {
	cases := []struct {
		name     string
		cfg      string
		wantHost string
		wantPort int
	}{
		{"string-peer-port", `{"peer_port":"3130"}`, "gluetun-eu", 3130},
		{"string-peer-port-and-host", `{"peer_host":"gw.internal","peer_port":"9"}`, "gw.internal", 9},
		{"string-peer-port-nonnumeric-falls-back", `{"peer_port":"nope"}`, "gluetun-eu", DefaultPeerPort},
		{"string-peer-port-zero-falls-back", `{"peer_port":"0"}`, "gluetun-eu", DefaultPeerPort},
		{"string-peer-port-negative-falls-back", `{"peer_port":"-5"}`, "gluetun-eu", DefaultPeerPort},
		{"float-peer-port-nonpositive-falls-back", `{"peer_port":0}`, "gluetun-eu", DefaultPeerPort},
		{"empty-peer-host-ignored", `{"peer_host":""}`, "gluetun-eu", DefaultPeerPort},
		{"malformed-json-falls-back", `{not-json`, "gluetun-eu", DefaultPeerPort},
		{"no-config-falls-back", ``, "gluetun-eu", DefaultPeerPort},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			p := store.VPNProfile{Name: "eu", Config: []byte(c.cfg)}
			host, port := peerEndpoint(p)
			if host != c.wantHost || port != c.wantPort {
				t.Errorf("peerEndpoint(%q) = (%q,%d), want (%q,%d)", c.cfg, host, port, c.wantHost, c.wantPort)
			}
		})
	}
}

// TestSanitizeToken exercises the invalid-char replacement and the empty→"unnamed"
// fallback (both previously uncovered), plus the pass-through of already-valid
// names — sanitizeToken output must be a single safe Squid config token.
func TestSanitizeToken(t *testing.T) {
	cases := []struct{ in, want string }{
		{"eu-wg-primary", "eu-wg-primary"},   // valid name passes through
		{"host.name_1", "host.name_1"},       // dot + underscore + digit allowed
		{"eu wg/primary!", "eu_wg_primary_"}, // space, slash, bang → underscore
		{"tab\ttab", "tab_tab"},              // control char → underscore
		{"", "unnamed"},                      // empty → sentinel
	}
	for _, c := range cases {
		if got := sanitizeToken(c.in); got != c.want {
			t.Errorf("sanitizeToken(%q) = %q, want %q", c.in, got, c.want)
		}
	}
}

// TestRenderSquidInclude_DefaultHelperPath proves an empty helperPath falls back to
// the baked default so the rendered external_acl_type still wires a real helper
// (a blank helper path would break the tun_up ACL — fail-open risk).
func TestRenderSquidInclude_DefaultHelperPath(t *testing.T) {
	out := RenderSquidInclude("", nil)
	if !contains(out, "/usr/lib/helix-proxy/acl-helper") {
		t.Errorf("empty helperPath did not fall back to default:\n%s", out)
	}
	// The fail-closed block is present even with zero tunnels.
	if !contains(out, "http_access deny !tun_up") {
		t.Error("fail-closed block missing")
	}
}

// TestRenderPAC_DefaultProxy proves an empty proxy argument falls back to
// DefaultPACProxy for routed aliases (an empty PROXY return would be invalid PAC).
func TestRenderPAC_DefaultProxy(t *testing.T) {
	out := RenderPAC("", []string{"a.helix"})
	if !contains(out, DefaultPACProxy) {
		t.Errorf("empty proxy did not fall back to DefaultPACProxy:\n%s", out)
	}
	if !contains(out, `return "DIRECT"`) {
		t.Error("split-tunnel DIRECT fallthrough missing")
	}
}
