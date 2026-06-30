package breaker

import "testing"

// st models the per-tunnel (breakerClosed, healthUp) state the SelectTunnel
// closure reads. Absent tunnels default to closed=false, up=false — the
// fail-closed default (an unknown tunnel is never routed onto).
type st struct {
	closed bool
	up     bool
}

// stateFn builds the `state func(tunnel) (closed, up bool)` SelectTunnel takes,
// from a fixed map. A tunnel missing from the map is reported (false, false).
func stateFn(m map[string]st) func(string) (bool, bool) {
	return func(tunnel string) (bool, bool) {
		s, ok := m[tunnel]
		if !ok {
			return false, false
		}
		return s.closed, s.up
	}
}

// TestSelectTunnel_TableDriven exercises the fail-closed tier-failover contract
// (§11.4 anti-bluff fail-closed primitive): pick the LOWEST-tier tunnel whose
// breaker is CLOSED *and* health is UP; otherwise "" (no route).
func TestSelectTunnel_TableDriven(t *testing.T) {
	t.Parallel()

	threeTiers := []Tier{
		{Tunnel: "a", Tier: 1},
		{Tunnel: "b", Tier: 2},
		{Tunnel: "c", Tier: 3},
	}

	tests := []struct {
		name  string
		tiers []Tier
		state map[string]st
		want  string
	}{
		{
			name:  "lowest-tier up is chosen",
			tiers: threeTiers,
			state: map[string]st{
				"a": {closed: true, up: true},
				"b": {closed: true, up: true},
				"c": {closed: true, up: true},
			},
			want: "a",
		},
		{
			name:  "primary breaker-open fails over to tier 2",
			tiers: threeTiers,
			state: map[string]st{
				"a": {closed: false, up: true}, // breaker OPEN ⇒ ineligible
				"b": {closed: true, up: true},
				"c": {closed: true, up: true},
			},
			want: "b",
		},
		{
			name:  "tier-2 also down fails over to tier 3",
			tiers: threeTiers,
			state: map[string]st{
				"a": {closed: false, up: true}, // breaker OPEN
				"b": {closed: true, up: false}, // health DOWN
				"c": {closed: true, up: true},
			},
			want: "c",
		},
		{
			name:  "all down or open is fail-closed empty",
			tiers: threeTiers,
			state: map[string]st{
				"a": {closed: false, up: true},  // breaker OPEN
				"b": {closed: true, up: false},  // health DOWN
				"c": {closed: false, up: false}, // both
			},
			want: "",
		},
		{
			name:  "empty tiers is fail-closed empty",
			tiers: nil,
			state: map[string]st{},
			want:  "",
		},
		{
			name:  "breaker closed but health down is ineligible",
			tiers: []Tier{{Tunnel: "a", Tier: 1}},
			state: map[string]st{"a": {closed: true, up: false}},
			want:  "",
		},
		{
			name:  "breaker open but health up is ineligible (never route open breaker)",
			tiers: []Tier{{Tunnel: "a", Tier: 1}},
			state: map[string]st{"a": {closed: false, up: true}},
			want:  "",
		},
		{
			name:  "unknown tunnel defaults fail-closed",
			tiers: []Tier{{Tunnel: "ghost", Tier: 1}},
			state: map[string]st{}, // ghost absent ⇒ (false,false)
			want:  "",
		},
		{
			name: "lowest tier wins regardless of slice order",
			tiers: []Tier{
				{Tunnel: "c", Tier: 3},
				{Tunnel: "a", Tier: 1},
				{Tunnel: "b", Tier: 2},
			},
			state: map[string]st{
				"a": {closed: true, up: true},
				"b": {closed: true, up: true},
				"c": {closed: true, up: true},
			},
			want: "a",
		},
		{
			name: "tie on tier resolves to first in slice order",
			tiers: []Tier{
				{Tunnel: "first", Tier: 1},
				{Tunnel: "second", Tier: 1},
			},
			state: map[string]st{
				"first":  {closed: true, up: true},
				"second": {closed: true, up: true},
			},
			want: "first",
		},
	}

	for _, tc := range tests {
		tc := tc
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			got := SelectTunnel(tc.tiers, stateFn(tc.state))
			if got != tc.want {
				t.Fatalf("SelectTunnel() = %q, want %q", got, tc.want)
			}
		})
	}
}

// TestSelectTunnel_NilStateIsFailClosed proves a nil state closure cannot leak a
// route: with no way to confirm a tunnel is closed+up, the answer is "".
func TestSelectTunnel_NilStateIsFailClosed(t *testing.T) {
	t.Parallel()
	got := SelectTunnel([]Tier{{Tunnel: "a", Tier: 1}}, nil)
	if got != "" {
		t.Fatalf("SelectTunnel(nil state) = %q, want \"\" (fail-closed)", got)
	}
}
