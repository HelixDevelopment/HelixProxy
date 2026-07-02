// Unit tests for the through-tunnel FRESH-LIVENESS acceptance path of DecideHealth
// (D3 core fix; §11.4.68 fail-closed gate, §11.4.107 liveness, §11.4.115 RED-first).
//
// ROOT CAUSE these tests pin: in the gluetun deployment the WireGuard
// handshake/tx counters are STRUCTURALLY UNOBTAINABLE (userspace-WG tun0, no `wg`
// binary, control API exposes no transfer/handshake — confirmed against the
// gluetun v3.40 control-server route list), so the wg-only DecideHealth returned
// StateDown even for a genuinely-live tunnel → the proxy fail-closed on a FALSE
// down (a real Mullvad tunnel wrongly reported DOWN). The fix adds a SECOND,
// EITHER/OR proof path: a fresh per-poll through-tunnel liveness probe
// (HealthSnapshot.LiveProbeAt) — the wg path is preserved unchanged.
//
// TestDecideHealth_FreshLivenessLiftsToUp is the §11.4.115 polarity test: it is
// RED on the pre-fix DecideHealth (which ignores LiveProbeAt) and GREEN after the
// EITHER/OR change. It reproduces the exact false-down.
package vpn

import (
	"testing"
	"time"
)

// mutantDecideUpOnDeadProbe is the §1.1 paired mutation for the NEW liveness
// guard: it DROPS the "LiveProbeAt is non-zero AND fresh" requirement and treats
// ANY snapshot with egress!=host as UP (the exact "accept a dead/failed probe as
// up" bluff). The real DecideHealth MUST stay DOWN on a failed probe where this
// mutant (wrongly) returns UP — proving the liveness guard is load-bearing.
func mutantDecideUpOnDeadProbe(prev, cur HealthSnapshot, hostIP string, fr time.Duration) State {
	if fr <= 0 {
		return StateDown
	}
	if cur.EgressIP == "" {
		return StateDown
	}
	if hostIP != "" && cur.EgressIP == hostIP {
		return StateDown
	}
	// BLUFF: the fresh-liveness guard (and the wg proof) are removed — egress
	// presence alone is (wrongly) accepted as up.
	return StateUp
}

// TestDecideHealth_FreshLivenessLiftsToUp — §11.4.115 RED-first polarity test.
//
// A genuinely-live tunnel where the ONLY obtainable proof is the fresh per-poll
// through-tunnel liveness probe: LiveProbeAt is fresh, egress is observed and
// differs from the host — but there is NO wg proof (zero handshake, flat tx). On
// the PRE-FIX DecideHealth this returns StateDown (the false-down bug); after the
// EITHER/OR fix it returns StateUp. This test is the reproduction AND the standing
// GREEN regression guard (§11.4.135): if a regression drops the liveness path, it
// goes RED again.
func TestDecideHealth_FreshLivenessLiftsToUp(t *testing.T) {
	now := time.Date(2026, 6, 30, 12, 0, 0, 0, time.UTC)
	cur := HealthSnapshot{
		// No wg proof at all: handshake never happened, tx flat vs prev.
		LastHandshake: time.Time{},
		Tx:            0,
		// The fresh data-plane liveness proof (this poll cycle).
		LiveProbeAt: now,
		CheckedAt:   now,
		EgressIP:    "185.65.135.250", // real Mullvad egress
	}
	prev := HealthSnapshot{Tx: 0}
	if got := DecideHealth(prev, cur, "198.51.100.7", freshness); got != StateUp {
		t.Fatalf("FRESH liveness proof (egress!=host, no wg counters) must be UP — "+
			"the gluetun false-down bug; got %q", got)
	}
}

// TestDecideHealth_LivenessMatrix is the comprehensive matrix for the NEW path.
// Every row calls DecideHealth DIRECTLY (not the swappable `decider`) because the
// existing HELIX_HEALTH_MUTATE meta-test mutates ONLY the wg-path guards. Fail-
// closed rows here MUST stay DOWN; the up rows require a fresh liveness proof.
func TestDecideHealth_LivenessMatrix(t *testing.T) {
	now := time.Date(2026, 6, 30, 12, 0, 0, 0, time.UTC)
	freshProbe := now.Add(-2 * time.Second)  // within window
	staleProbe := now.Add(-10 * time.Minute) // beyond 180s window
	egress := "185.65.135.250"
	host := "198.51.100.7"

	cases := []struct {
		name   string
		cur    HealthSnapshot
		hostIP string
		fr     time.Duration
		want   State
	}{
		{
			name:   "fresh liveness + egress!=host → UP (no wg proof needed)",
			cur:    HealthSnapshot{LiveProbeAt: freshProbe, CheckedAt: now, EgressIP: egress},
			hostIP: host,
			fr:     freshness,
			want:   StateUp,
		},
		{
			name:   "fresh liveness, host unknown → UP",
			cur:    HealthSnapshot{LiveProbeAt: freshProbe, CheckedAt: now, EgressIP: egress},
			hostIP: "",
			fr:     freshness,
			want:   StateUp,
		},
		{
			name:   "liveness probe FAILED (LiveProbeAt zero), no wg proof → DOWN (fail-closed)",
			cur:    HealthSnapshot{LiveProbeAt: time.Time{}, CheckedAt: now, EgressIP: egress},
			hostIP: host,
			fr:     freshness,
			want:   StateDown,
		},
		{
			name:   "stale liveness (probe old, beyond window), no wg proof → DOWN",
			cur:    HealthSnapshot{LiveProbeAt: staleProbe, CheckedAt: now, EgressIP: egress},
			hostIP: host,
			fr:     freshness,
			want:   StateDown,
		},
		{
			name:   "future liveness (clock skew, age<0), no wg proof → DOWN",
			cur:    HealthSnapshot{LiveProbeAt: now.Add(5 * time.Second), CheckedAt: now, EgressIP: egress},
			hostIP: host,
			fr:     freshness,
			want:   StateDown,
		},
		{
			name:   "egress==host even WITH fresh liveness → DOWN (traffic not tunnelled)",
			cur:    HealthSnapshot{LiveProbeAt: freshProbe, CheckedAt: now, EgressIP: host},
			hostIP: host,
			fr:     freshness,
			want:   StateDown,
		},
		{
			name:   "empty egress even WITH fresh liveness → DOWN (no real egress)",
			cur:    HealthSnapshot{LiveProbeAt: freshProbe, CheckedAt: now, EgressIP: ""},
			hostIP: host,
			fr:     freshness,
			want:   StateDown,
		},
		{
			name:   "fresh liveness but freshness<=0 → DOWN (unsatisfiable window)",
			cur:    HealthSnapshot{LiveProbeAt: freshProbe, CheckedAt: now, EgressIP: egress},
			hostIP: host,
			fr:     0,
			want:   StateDown,
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := DecideHealth(HealthSnapshot{}, tc.cur, tc.hostIP, tc.fr); got != tc.want {
				t.Errorf("DecideHealth = %q, want %q", got, tc.want)
			}
		})
	}
}

// TestDecideHealth_LivenessMutation_RealStaysDownMutantGoesUp is the §1.1 paired
// mutation proof for the liveness guard: on a FAILED probe (LiveProbeAt zero, no
// wg proof) the REAL DecideHealth fails closed (DOWN) while the mutant that drops
// the guard (wrongly) returns UP. Both assertions in one deterministic run: the
// guard both holds (real=DOWN) AND is falsifiable (mutant=UP).
func TestDecideHealth_LivenessMutation_RealStaysDownMutantGoesUp(t *testing.T) {
	now := time.Date(2026, 6, 30, 12, 0, 0, 0, time.UTC)
	deadProbe := HealthSnapshot{ // egress present but the through-tunnel probe FAILED
		LiveProbeAt: time.Time{},
		CheckedAt:   now,
		EgressIP:    "185.65.135.250",
	}
	host := "198.51.100.7"

	if got := DecideHealth(HealthSnapshot{}, deadProbe, host, freshness); got != StateDown {
		t.Fatalf("REAL DecideHealth must fail closed (DOWN) on a failed liveness probe, got %q", got)
	}
	if got := mutantDecideUpOnDeadProbe(HealthSnapshot{}, deadProbe, host, freshness); got != StateUp {
		t.Fatalf("mutant (guard removed) must return UP — proving the liveness guard "+
			"catches its negation; got %q", got)
	}
}

// TestDataPlaneEvaluator_AcceptsFreshLiveness proves the wired evaluator (used by
// cmd/healthd) yields the SAME EITHER/OR verdict as the pure rule for the liveness
// path — so the deployed healthd reports UP on a fresh liveness proof.
func TestDataPlaneEvaluator_AcceptsFreshLiveness(t *testing.T) {
	now := time.Now().UTC()
	cur := HealthSnapshot{LiveProbeAt: now, CheckedAt: now, EgressIP: "185.65.135.250"}
	eval := DataPlaneEvaluator{Freshness: freshness}
	if got := eval.Evaluate(HealthSnapshot{}, cur, "198.51.100.7"); got != StateUp {
		t.Errorf("evaluator fresh-liveness = %q, want up", got)
	}
	cur.LiveProbeAt = time.Time{} // probe failed
	if got := eval.Evaluate(HealthSnapshot{}, cur, "198.51.100.7"); got != StateDown {
		t.Errorf("evaluator failed-probe = %q, want down (fail-closed)", got)
	}
}
