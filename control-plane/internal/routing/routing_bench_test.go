package routing

// Micro-benchmarks for the config-compiler render path (§11.4.169 Go-bench
// coverage). CompileAll runs one read pass over the data model and renders the
// Squid include + Dante routes + PAC + resolved routes; it fires on every
// structural change (spec §8/§9). These exercise the REAL exported CompileAll +
// ResolveTunnels against the committed unit fixtures via the in-memory
// fakeQueries (mocks permitted at the unit layer only, §11.4.27).

import (
	"context"
	"testing"
)

// benchTunnelSink defeats dead-code elimination of the pure-render measured call.
var benchTunnelSink []Tunnel

// BenchmarkCompileAll measures one full compile pass over the committed fixtures.
func BenchmarkCompileAll(b *testing.B) {
	e := New("/usr/lib/helix-proxy/acl-helper", "")
	q := &fakeQueries{profiles: fixtureProfiles(), targets: fixtureTargets(), tiers: fixtureTiers()}
	ctx := context.Background()
	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		if _, _, err := e.CompileAll(ctx, q); err != nil {
			b.Fatal(err)
		}
	}
}

// BenchmarkResolveTunnels measures the pure enabled-profile → cache_peer resolution
// + deterministic name sort (no I/O), the per-compile core.
func BenchmarkResolveTunnels(b *testing.B) {
	profiles := fixtureProfiles()
	b.ReportAllocs()
	b.ResetTimer()
	var out []Tunnel
	for i := 0; i < b.N; i++ {
		out = ResolveTunnels(profiles)
	}
	benchTunnelSink = out
}
