// Hermetic unit tests for the D3 fresh-liveness wiring in healthd: the sampler
// stamps HealthSnapshot.LiveProbeAt on a successful through-tunnel probe and leaves
// it zero (fail-closed) on a failed one; loadConfig's probe env parsing; and
// buildLivenessProber's enable/disable/bad-URL branches. Plus an end-to-end
// hermetic proof (in-process httptest proxy → sampler → DecideHealth) that a
// wg-LESS snapshot with a fresh probe is reported UP — the exact D3 deployment
// shape (gluetun userspace-WG: no wg counters, only the fresh proxy probe). No real
// gluetun, no external network. Run under -short.
package main

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"digital.vasic.helixproxy/controlplane/internal/vpn"
)

// fakeProber is a test LivenessProber whose Probe returns err (nil ⇒ success).
type fakeProber struct{ err error }

func (p fakeProber) Probe(context.Context) error { return p.err }

// TestLiveSampler_Sample_LivenessSuccessStampsProbeAt proves a successful probe
// stamps LiveProbeAt == CheckedAt (a fresh per-poll proof), alongside the egress
// read, even when wg is absent (the gluetun deployment shape).
func TestLiveSampler_Sample_LivenessSuccessStampsProbeAt(t *testing.T) {
	srv := egressServer(t, http.StatusOK, `{"public_ip":"185.65.135.250"}`)
	s := liveSampler{
		ctrl:   vpn.NewControlClient(srv.URL),
		wg:     vpn.WGReader{Bin: "/nonexistent-wg"}, // wg absent → no counters (gluetun shape)
		ifName: "tun0",
		live:   fakeProber{err: nil}, // probe succeeds
	}
	snap, err := s.sample(context.Background(), "demo")
	if err != nil {
		t.Fatalf("sample: %v", err)
	}
	if snap.LiveProbeAt.IsZero() {
		t.Fatal("successful liveness probe must stamp LiveProbeAt")
	}
	if !snap.LiveProbeAt.Equal(snap.CheckedAt) {
		t.Errorf("LiveProbeAt %v must equal CheckedAt %v", snap.LiveProbeAt, snap.CheckedAt)
	}
	if snap.EgressIP != "185.65.135.250" {
		t.Errorf("EgressIP = %q, want the egress read alongside the probe", snap.EgressIP)
	}
	// End-to-end: with no wg proof, the fresh probe alone must lift to UP.
	if got := vpn.DecideHealth(vpn.HealthSnapshot{}, snap, "198.51.100.7", 180*time.Second); got != vpn.StateUp {
		t.Fatalf("D3: wg-less snapshot with a fresh liveness probe must be UP, got %q", got)
	}
}

// TestLiveSampler_Sample_LivenessFailureLeavesProbeZero proves a failed probe leaves
// LiveProbeAt zero (fail-closed) WITHOUT masking the egress read or erroring the
// sample. DecideHealth then fails closed (no wg proof + no fresh liveness → DOWN).
func TestLiveSampler_Sample_LivenessFailureLeavesProbeZero(t *testing.T) {
	srv := egressServer(t, http.StatusOK, `{"public_ip":"185.65.135.250"}`)
	s := liveSampler{
		ctrl:   vpn.NewControlClient(srv.URL),
		wg:     vpn.WGReader{Bin: "/nonexistent-wg"},
		ifName: "tun0",
		live:   fakeProber{err: errors.New("kill-switch blocked")}, // probe fails
	}
	snap, err := s.sample(context.Background(), "demo")
	if err != nil {
		t.Fatalf("a failed liveness probe must NOT fail the sample, got err: %v", err)
	}
	if !snap.LiveProbeAt.IsZero() {
		t.Errorf("failed probe must leave LiveProbeAt zero, got %v", snap.LiveProbeAt)
	}
	if snap.EgressIP != "185.65.135.250" {
		t.Errorf("EgressIP = %q, want it to survive a failed probe", snap.EgressIP)
	}
	if got := vpn.DecideHealth(vpn.HealthSnapshot{}, snap, "198.51.100.7", 180*time.Second); got != vpn.StateDown {
		t.Fatalf("failed probe + no wg proof must be DOWN (fail-closed), got %q", got)
	}
}

// TestLiveSampler_Sample_NilProberIsWgOnly proves the DEFAULT (live == nil) leaves
// LiveProbeAt zero and issues no probe — behaviour identical to the pre-D3 wg-only
// path (this is why every existing test that builds liveSampler without `live`
// is unaffected).
func TestLiveSampler_Sample_NilProberIsWgOnly(t *testing.T) {
	srv := egressServer(t, http.StatusOK, `{"public_ip":"185.65.135.250"}`)
	s := liveSampler{ctrl: vpn.NewControlClient(srv.URL), wg: vpn.WGReader{Bin: "/nonexistent-wg"}, ifName: "tun0"}
	snap, err := s.sample(context.Background(), "demo")
	if err != nil {
		t.Fatalf("sample: %v", err)
	}
	if !snap.LiveProbeAt.IsZero() {
		t.Errorf("nil prober must leave LiveProbeAt zero, got %v", snap.LiveProbeAt)
	}
}

// TestSample_EndToEnd_ThroughRealProxyProber wires the CONCRETE vpn.TunnelProxyProber
// against an in-process httptest server acting as gluetun's :8888 forward proxy, and
// proves the full path: sample() → real Probe through the "proxy" → LiveProbeAt set →
// DecideHealth UP, with wg absent. This is the D3 fix end-to-end, hermetic.
func TestSample_EndToEnd_ThroughRealProxyProber(t *testing.T) {
	proxy := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("185.65.135.250\n")) // the echoed egress through the tunnel
	}))
	t.Cleanup(proxy.Close)
	prober, err := vpn.NewTunnelProxyProber(proxy.URL, "http://ip-echo.test/ip", 2*time.Second)
	if err != nil {
		t.Fatalf("NewTunnelProxyProber: %v", err)
	}
	egress := egressServer(t, http.StatusOK, `{"public_ip":"185.65.135.250"}`)
	s := liveSampler{ctrl: vpn.NewControlClient(egress.URL), wg: vpn.WGReader{Bin: "/nonexistent-wg"}, ifName: "tun0", live: prober}

	snap, err := s.sample(context.Background(), "demo")
	if err != nil {
		t.Fatalf("sample: %v", err)
	}
	if snap.LiveProbeAt.IsZero() {
		t.Fatal("real prober success must stamp LiveProbeAt")
	}
	if got := vpn.DecideHealth(vpn.HealthSnapshot{}, snap, "198.51.100.7", 180*time.Second); got != vpn.StateUp {
		t.Fatalf("D3 end-to-end: fresh through-proxy probe (no wg) must be UP, got %q", got)
	}
}

// TestLoadConfig_LivenessDefaults proves the probe is DISABLED by default and the
// target/timeout defaults are the documented values.
func TestLoadConfig_LivenessDefaults(t *testing.T) {
	t.Setenv("HEALTHD_TUNNEL_PROXY", "")
	t.Setenv("HEALTHD_LIVENESS_TARGET", "")
	t.Setenv("HEALTHD_LIVENESS_TIMEOUT", "")
	c := loadConfig()
	if got := c.tunnelProxy("demo"); got != "" {
		t.Errorf("tunnelProxy default must be empty (probe disabled), got %q", got)
	}
	if c.probeTarget != vpn.DefaultLivenessTarget {
		t.Errorf("probeTarget default = %q, want %q", c.probeTarget, vpn.DefaultLivenessTarget)
	}
	if c.probeTimeout != 4*time.Second {
		t.Errorf("probeTimeout default = %s, want 4s", c.probeTimeout)
	}
}

// TestLoadConfig_LivenessEnv proves the per-profile override wins over the global,
// and target/timeout are read from env.
func TestLoadConfig_LivenessEnv(t *testing.T) {
	t.Setenv("HEALTHD_TUNNEL_PROXY", "http://proxy-gluetun:8888")
	t.Setenv("HEALTHD_TUNNEL_PROXY_EUWG", "http://proxy-gluetun-eu:8888")
	t.Setenv("HEALTHD_LIVENESS_TARGET", "https://api.ipify.org")
	t.Setenv("HEALTHD_LIVENESS_TIMEOUT", "6s")
	c := loadConfig()
	if got := c.tunnelProxy("demo"); got != "http://proxy-gluetun:8888" {
		t.Errorf("tunnelProxy(demo) = %q, want the global", got)
	}
	if got := c.tunnelProxy("euwg"); got != "http://proxy-gluetun-eu:8888" {
		t.Errorf("tunnelProxy(euwg) = %q, want the per-profile override", got)
	}
	if c.probeTarget != "https://api.ipify.org" {
		t.Errorf("probeTarget = %q, want the env value", c.probeTarget)
	}
	if c.probeTimeout != 6*time.Second {
		t.Errorf("probeTimeout = %s, want 6s", c.probeTimeout)
	}
}

// TestBuildLivenessProber_Branches covers disable (no URL), enable (valid URL), and
// disable-on-bad-URL (fail-closed to wg-only, never fail-open).
func TestBuildLivenessProber_Branches(t *testing.T) {
	// No proxy configured → nil (wg-only default).
	if p := buildLivenessProber(config{tunnelProxy: func(string) string { return "" }}, "demo"); p != nil {
		t.Error("no proxy URL must yield a nil prober (probe disabled)")
	}
	// Valid proxy → non-nil prober.
	c := config{
		tunnelProxy:  func(string) string { return "http://proxy-gluetun:8888" },
		probeTarget:  vpn.DefaultLivenessTarget,
		probeTimeout: 4 * time.Second,
	}
	if p := buildLivenessProber(c, "demo"); p == nil {
		t.Error("valid proxy URL must yield a prober")
	}
	// Bad proxy URL → nil (disabled, fail-closed to wg-only — NOT fail-open).
	bad := config{tunnelProxy: func(string) string { return "http://" }, probeTarget: vpn.DefaultLivenessTarget}
	if p := buildLivenessProber(bad, "demo"); p != nil {
		t.Error("bad proxy URL must disable the probe (nil), not fail open")
	}
}
