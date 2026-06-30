// Unit tests (no Redis): the fail-closed decision (evaluateStatus), the §1.1
// paired-mutation negative proving the test catches a flipped branch, key naming,
// and event/route JSON (un)marshalling. Runnable under `go test -short`.
package redis

import (
	"encoding/json"
	"testing"
	"time"

	"digital.vasic.helixproxy/controlplane/internal/vpn"
)

const testMaxAge = 30 * time.Second

func upSnap(profile string, checkedAt time.Time) []byte {
	b, _ := json.Marshal(vpn.HealthSnapshot{
		Profile: profile, State: vpn.StateUp, Rx: 100, Tx: 200,
		EgressIP: "203.0.113.7", CheckedAt: checkedAt,
	})
	return b
}

// TestEvaluateStatus_FailClosed is the heart of §10: missing / stale / corrupt
// MUST read DOWN; only a fresh up-snapshot reads UP.
func TestEvaluateStatus_FailClosed(t *testing.T) {
	t.Parallel()
	now := time.Date(2026, 6, 30, 12, 0, 0, 0, time.UTC)
	fresh := now.Add(-5 * time.Second)
	stale := now.Add(-5 * time.Minute)

	cases := []struct {
		name  string
		raw   []byte
		found bool
		want  vpn.State
	}{
		{"missing key is DOWN", nil, false, vpn.StateDown},
		{"empty bytes present-but-corrupt is DOWN", []byte(""), true, vpn.StateDown},
		{"garbage JSON is DOWN", []byte("{not json"), true, vpn.StateDown},
		{"explicit down stays DOWN", mustJSON(vpn.HealthSnapshot{Profile: "p", State: vpn.StateDown, CheckedAt: fresh}), true, vpn.StateDown},
		{"unknown stays UNKNOWN (not up)", mustJSON(vpn.HealthSnapshot{Profile: "p", State: vpn.StateUnknown, CheckedAt: fresh}), true, vpn.StateUnknown},
		{"up + fresh is UP", upSnap("p", fresh), true, vpn.StateUp},
		{"up + stale is DOWN (freshness guard)", upSnap("p", stale), true, vpn.StateDown},
	}
	for _, tc := range cases {
		tc := tc
		t.Run(tc.name, func(t *testing.T) {
			got := evaluateStatus("p", tc.raw, tc.found, now, testMaxAge)
			if got.State != tc.want {
				t.Errorf("evaluateStatus(%q) state = %q, want %q", tc.name, got.State, tc.want)
			}
		})
	}
}

// TestEvaluateStatus_ProfileBackfilled proves a snapshot with an empty profile
// field is backfilled with the requested profile (so callers always get a labelled
// snapshot, never a blank one).
func TestEvaluateStatus_ProfileBackfilled(t *testing.T) {
	t.Parallel()
	now := time.Now().UTC()
	raw := mustJSON(vpn.HealthSnapshot{State: vpn.StateUp, CheckedAt: now})
	got := evaluateStatus("alpha", raw, true, now, testMaxAge)
	if got.Profile != "alpha" {
		t.Errorf("profile = %q, want alpha", got.Profile)
	}
}

// buggyEvaluateStatus is the §1.1 PAIRED MUTATION of evaluateStatus: it flips the
// fail-closed missing-key branch to report UP. It exists ONLY in this test file so
// no mutation residue can reach production (§11.4.84).
func buggyEvaluateStatus(profile string, raw []byte, found bool, now time.Time, maxAge time.Duration) vpn.HealthSnapshot {
	if !found {
		// MUTATION: fail-OPEN — the exact bug §10 forbids.
		return vpn.HealthSnapshot{Profile: profile, State: vpn.StateUp, CheckedAt: now}
	}
	return evaluateStatus(profile, raw, found, now, maxAge)
}

// TestFailClosed_MutationIsCaught proves the assertion used by
// TestEvaluateStatus_FailClosed genuinely catches the negation: the real function
// returns DOWN for a missing key while the mutated (fail-open) function returns
// UP. If the production branch were ever flipped, the missing-key case above
// would FAIL — demonstrated here directly.
func TestFailClosed_MutationIsCaught(t *testing.T) {
	t.Parallel()
	now := time.Now().UTC()

	real := evaluateStatus("p", nil, false, now, testMaxAge)
	mutated := buggyEvaluateStatus("p", nil, false, now, testMaxAge)

	if real.State != vpn.StateDown {
		t.Fatalf("real evaluateStatus must be DOWN on missing key, got %q", real.State)
	}
	if mutated.State != vpn.StateUp {
		t.Fatalf("mutation harness wrong: fail-open must yield UP, got %q", mutated.State)
	}
	if real.State == mutated.State {
		t.Fatal("assertion cannot distinguish fail-closed from fail-open — test is a bluff")
	}
	// The discriminator the suite asserts on (want=DOWN) rejects the mutant (UP):
	if mutated.State == vpn.StateDown {
		t.Fatal("mutant unexpectedly passed the DOWN assertion")
	}
}

// TestKeyNaming pins the Redis key layout the helper and publisher must agree on.
func TestKeyNaming(t *testing.T) {
	t.Parallel()
	if got := StatusKey("nordvpn-uk"); got != "vpn:status:nordvpn-uk" {
		t.Errorf("StatusKey = %q", got)
	}
	if got := RouteKey("api.internal"); got != "route:api.internal" {
		t.Errorf("RouteKey = %q", got)
	}
}

// TestEventMarshalling proves the vpn:events payload uses the spec §7 field names
// and round-trips.
func TestEventMarshalling(t *testing.T) {
	t.Parallel()
	e := Event{ProfileID: "nordvpn-uk", State: vpn.StateDown}
	b, err := json.Marshal(e)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	s := string(b)
	for _, want := range []string{`"profile_id":"nordvpn-uk"`, `"state":"down"`} {
		if !contains(s, want) {
			t.Errorf("event JSON %s missing %s", s, want)
		}
	}
	var got Event
	if err := json.Unmarshal(b, &got); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if got != e {
		t.Errorf("round-trip mismatch: %+v != %+v", got, e)
	}
}

// TestRouteMarshalling proves route:<target> JSON round-trips with spec §7 fields.
func TestRouteMarshalling(t *testing.T) {
	t.Parallel()
	r := Route{Target: "api.internal", Tunnel: "nordvpn-uk", Tier: 1, BreakerState: "closed"}
	b, err := json.Marshal(r)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	var got Route
	if err := json.Unmarshal(b, &got); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if got != r {
		t.Errorf("round-trip mismatch: %+v != %+v", got, r)
	}
}

func mustJSON(v any) []byte {
	b, err := json.Marshal(v)
	if err != nil {
		panic(err)
	}
	return b
}

func contains(haystack, needle string) bool {
	return len(haystack) >= len(needle) && (indexOf(haystack, needle) >= 0)
}

func indexOf(s, sub string) int {
	for i := 0; i+len(sub) <= len(s); i++ {
		if s[i:i+len(sub)] == sub {
			return i
		}
	}
	return -1
}
