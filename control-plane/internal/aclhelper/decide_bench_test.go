package aclhelper

// Micro-benchmarks for the per-request fail-closed routing verdict (§11.4.169
// Go-bench coverage). Decider.Decide runs once per proxied request via the Squid
// external-acl helper, so its cost is on the request hot path. These exercise the
// REAL exported Decider.Decide against the in-memory fakeBus already used by the
// fail-closed table (mocks permitted at the unit layer only, §11.4.27) — the
// affirmative (route+up) path and the fail-closed (no-route) refusal path.

import (
	"context"
	"testing"

	"digital.vasic.helixproxy/controlplane/internal/redis"
)

// package-level sinks defeat dead-code elimination of the measured call.
var (
	benchDecideOK  bool
	benchDecideTag string
)

// BenchmarkDecide_Affirmative measures the single OK path (route exists + tunnel
// UP) — the verdict every allowed request gets.
func BenchmarkDecide_Affirmative(b *testing.B) {
	d := Decider{Bus: fakeBus{route: redis.Route{Tunnel: "eu-wg-primary"}, snap: up("eu-wg-primary")}}
	ctx := context.Background()
	var ok bool
	var tag string
	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		ok, tag = d.Decide(ctx, "internal-wiki.helix")
	}
	benchDecideOK, benchDecideTag = ok, tag
}

// BenchmarkDecide_FailClosed measures the fail-closed refusal path (no route →
// ERR), the negation the §1.1 mutation guards.
func BenchmarkDecide_FailClosed(b *testing.B) {
	d := Decider{Bus: fakeBus{routeErr: redis.ErrRouteNotFound}}
	ctx := context.Background()
	var ok bool
	var tag string
	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		ok, tag = d.Decide(ctx, "internal-wiki.helix")
	}
	benchDecideOK, benchDecideTag = ok, tag
}
