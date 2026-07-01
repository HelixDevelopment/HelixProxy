package breaker

// Micro-benchmarks for the pure tier-failover route decision (§11.4.169 Go-bench
// coverage). SelectTunnel is walked per routing decision to pick the lowest-tier
// tunnel that is breaker-CLOSED AND health-UP (spec §11 ①). These exercise the
// REAL exported SelectTunnel against a realistic 4-tier failover chain: the
// common primary-up path and the failover (primary-open, scan-to-tier-1) path.

import "testing"

// benchTiers is a realistic 4-entry failover chain (primary + 3 failovers), the
// shape SelectTunnel walks; deliberately out-of-order to also exercise the
// min-Tier selection (not slice-order reliance).
var benchTiers = []Tier{
	{Tunnel: "us-wg-failover", Tier: 1},
	{Tunnel: "eu-wg-primary", Tier: 0},
	{Tunnel: "apac-ovpn", Tier: 2},
	{Tunnel: "legacy-openvpn", Tier: 3},
}

// benchSelectSink defeats dead-code elimination of the measured call.
var benchSelectSink string

// BenchmarkSelectTunnel_PrimaryUp: every tunnel CLOSED+UP — the full slice is
// scanned and tier 0 wins (the common healthy case).
func BenchmarkSelectTunnel_PrimaryUp(b *testing.B) {
	state := func(string) (bool, bool) { return true, true }
	b.ReportAllocs()
	b.ResetTimer()
	var chosen string
	for i := 0; i < b.N; i++ {
		chosen = SelectTunnel(benchTiers, state)
	}
	benchSelectSink = chosen
}

// BenchmarkSelectTunnel_Failover: primary breaker OPEN — SelectTunnel must skip it
// (fail-closed continue) and select the next-lowest eligible tier. The state
// closure captures a real per-tunnel lookup map (the shape the live caller uses).
func BenchmarkSelectTunnel_Failover(b *testing.B) {
	open := map[string]bool{"eu-wg-primary": true} // primary breaker open
	state := func(t string) (bool, bool) {
		if open[t] {
			return false, true // breaker OPEN → ineligible
		}
		return true, true
	}
	b.ReportAllocs()
	b.ResetTimer()
	var chosen string
	for i := 0; i < b.N; i++ {
		chosen = SelectTunnel(benchTiers, state)
	}
	benchSelectSink = chosen
}
