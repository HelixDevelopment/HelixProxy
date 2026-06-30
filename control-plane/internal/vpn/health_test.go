// Unit tests for the pure DecideHealth verdict (§11.4.107 / §11.4.69 anti-bluff).
// The truth table MUST include the data-plane bluff cases: tx-delta==0 → DOWN,
// empty public_ip → DOWN, stale handshake → DOWN, egress==host → DOWN, and the
// single all-good → UP path.
//
// §1.1 PAIRED MUTATION (env-gated, test-only — no production residue, §11.4.84):
// setting HELIX_HEALTH_MUTATE=1 swaps the decider for a BLUFF that returns UP on
// tx-delta==0 / empty egress. The same table is then RED. The mutation lives only
// in this _test.go file and is selected at runtime, never compiled into healthd.
package vpn

import (
	"os"
	"testing"
	"time"
)

const freshness = 180 * time.Second

// mutantDecideUpOnZeroTx is the §1.1 bluff: it drops the tx-delta>0 AND the
// non-empty-egress guards (the exact "report up when it's configured / when the
// API said running" failure mode). Flipping the decider to this MUST turn the
// anti-bluff rows RED.
func mutantDecideUpOnZeroTx(prev, cur HealthSnapshot, hostIP string, fr time.Duration) State {
	if fr <= 0 {
		return StateDown
	}
	if cur.LastHandshake.IsZero() {
		return StateDown
	}
	age := cur.CheckedAt.Sub(cur.LastHandshake)
	if age < 0 || age > fr {
		return StateDown
	}
	// BLUFF: tx-delta and empty-egress guards removed.
	if hostIP != "" && cur.EgressIP == hostIP {
		return StateDown
	}
	return StateUp
}

// decider is the function under test. Default = the real pure rule; the env-gated
// mutation swaps in the bluff so the SAME table is provably RED under it.
var decider = DecideHealth

func init() {
	if os.Getenv("HELIX_HEALTH_MUTATE") == "1" {
		decider = mutantDecideUpOnZeroTx
	}
}

func TestDecideHealth_TruthTable(t *testing.T) {
	now := time.Date(2026, 6, 30, 12, 0, 0, 0, time.UTC)
	fresh := now.Add(-30 * time.Second)  // 30s ago — within window
	stale := now.Add(-10 * time.Minute)  // 10m ago — beyond 180s window
	goodEgress := "203.0.113.9"
	host := "198.51.100.7"

	cases := []struct {
		name   string
		prev   HealthSnapshot
		cur    HealthSnapshot
		hostIP string
		want   State
	}{
		{
			name:   "all-good → UP",
			prev:   HealthSnapshot{Tx: 1000},
			cur:    HealthSnapshot{Tx: 5000, LastHandshake: fresh, CheckedAt: now, EgressIP: goodEgress},
			hostIP: host,
			want:   StateUp,
		},
		{
			name:   "tx-delta==0 → DOWN (flat counter, no traffic)",
			prev:   HealthSnapshot{Tx: 5000},
			cur:    HealthSnapshot{Tx: 5000, LastHandshake: fresh, CheckedAt: now, EgressIP: goodEgress},
			hostIP: host,
			want:   StateDown,
		},
		{
			name:   "tx-delta<0 → DOWN (counter reset)",
			prev:   HealthSnapshot{Tx: 9000},
			cur:    HealthSnapshot{Tx: 100, LastHandshake: fresh, CheckedAt: now, EgressIP: goodEgress},
			hostIP: host,
			want:   StateDown,
		},
		{
			name:   "empty public_ip → DOWN (no real egress, the gluetun fail-closed signal)",
			prev:   HealthSnapshot{Tx: 1000},
			cur:    HealthSnapshot{Tx: 5000, LastHandshake: fresh, CheckedAt: now, EgressIP: ""},
			hostIP: host,
			want:   StateDown,
		},
		{
			name:   "stale handshake → DOWN",
			prev:   HealthSnapshot{Tx: 1000},
			cur:    HealthSnapshot{Tx: 5000, LastHandshake: stale, CheckedAt: now, EgressIP: goodEgress},
			hostIP: host,
			want:   StateDown,
		},
		{
			name:   "zero handshake (never) → DOWN",
			prev:   HealthSnapshot{Tx: 1000},
			cur:    HealthSnapshot{Tx: 5000, LastHandshake: time.Time{}, CheckedAt: now, EgressIP: goodEgress},
			hostIP: host,
			want:   StateDown,
		},
		{
			name:   "egress==host → DOWN (traffic not tunnelled)",
			prev:   HealthSnapshot{Tx: 1000},
			cur:    HealthSnapshot{Tx: 5000, LastHandshake: fresh, CheckedAt: now, EgressIP: host},
			hostIP: host,
			want:   StateDown,
		},
		{
			name:   "all-good, host unknown → UP (egress!=host check skipped when hostIP empty)",
			prev:   HealthSnapshot{Tx: 1000},
			cur:    HealthSnapshot{Tx: 5000, LastHandshake: fresh, CheckedAt: now, EgressIP: goodEgress},
			hostIP: "",
			want:   StateUp,
		},
		{
			name:   "first poll, tx>0 from zero, all good → UP",
			prev:   HealthSnapshot{}, // zero prev (Tx=0)
			cur:    HealthSnapshot{Tx: 4096, LastHandshake: fresh, CheckedAt: now, EgressIP: goodEgress},
			hostIP: host,
			want:   StateUp,
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := decider(tc.prev, tc.cur, tc.hostIP, freshness)
			if got != tc.want {
				t.Errorf("DecideHealth = %q, want %q", got, tc.want)
			}
		})
	}
}

// TestDecideHealth_FreshnessZeroIsFailClosed proves a non-positive window is never UP.
func TestDecideHealth_FreshnessZeroIsFailClosed(t *testing.T) {
	now := time.Now().UTC()
	cur := HealthSnapshot{Tx: 5000, LastHandshake: now, CheckedAt: now, EgressIP: "203.0.113.9"}
	if got := DecideHealth(HealthSnapshot{}, cur, "", 0); got != StateDown {
		t.Errorf("freshness<=0 must be DOWN, got %q", got)
	}
}

// TestDataPlaneEvaluator_DelegatesToDecideHealth proves the HealthEvaluator impl
// matches the pure rule (so cmd/healthd's wiring is the same verdict).
func TestDataPlaneEvaluator_DelegatesToDecideHealth(t *testing.T) {
	now := time.Now().UTC()
	cur := HealthSnapshot{Tx: 5000, LastHandshake: now.Add(-10 * time.Second), CheckedAt: now, EgressIP: "203.0.113.9"}
	eval := DataPlaneEvaluator{Freshness: freshness}
	if got := eval.Evaluate(HealthSnapshot{Tx: 1000}, cur, ""); got != StateUp {
		t.Errorf("evaluator all-good = %q, want up", got)
	}
	cur.EgressIP = "" // empty egress
	if got := eval.Evaluate(HealthSnapshot{Tx: 1000}, cur, ""); got != StateDown {
		t.Errorf("evaluator empty-egress = %q, want down", got)
	}
}
