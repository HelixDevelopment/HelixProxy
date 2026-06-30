package breaker

import (
	"sync"
	"testing"
	"time"
)

// TestBreaker_TripsOpenAfterConsecutiveFailures proves the breaker OPENs once the
// configured number of consecutive health failures is reached, and not before.
func TestBreaker_TripsOpenAfterConsecutiveFailures(t *testing.T) {
	t.Parallel()
	b := NewBreaker("tun", Options{FailThreshold: 3, Cooldown: time.Minute})

	if !b.Closed() {
		t.Fatalf("a fresh breaker must start CLOSED, got %q", b.State())
	}
	b.Record(false)
	b.Record(false)
	if !b.Closed() {
		t.Fatalf("after 2/3 failures the breaker must still be CLOSED, got %q", b.State())
	}
	b.Record(false) // third consecutive failure trips it
	if b.Closed() {
		t.Fatalf("after 3/3 consecutive failures the breaker must be OPEN, got %q", b.State())
	}
}

// TestBreaker_SuccessResetsConsecutiveBeforeThreshold proves an intervening
// success resets the consecutive-failure count, so the breaker does NOT trip on
// non-consecutive failures.
func TestBreaker_SuccessResetsConsecutiveBeforeThreshold(t *testing.T) {
	t.Parallel()
	b := NewBreaker("tun", Options{FailThreshold: 3, Cooldown: time.Minute})

	b.Record(false)
	b.Record(false)
	b.Record(true) // resets consecutive failures
	b.Record(false)
	b.Record(false) // only 2 consecutive since the reset
	if !b.Closed() {
		t.Fatalf("non-consecutive failures must not trip the breaker, got %q", b.State())
	}
}

// TestBreaker_HalfOpenClosesOnSuccessfulProbe proves the full recovery arc:
// OPEN → (cooldown elapses) → HALF-OPEN → successful probe → CLOSED.
func TestBreaker_HalfOpenClosesOnSuccessfulProbe(t *testing.T) {
	t.Parallel()
	const cooldown = 40 * time.Millisecond
	b := NewBreaker("tun", Options{FailThreshold: 2, Cooldown: cooldown})

	b.Record(false)
	b.Record(false)
	if b.Closed() {
		t.Fatalf("breaker should be OPEN after 2 failures, got %q", b.State())
	}

	time.Sleep(cooldown + 30*time.Millisecond) // let the cooldown elapse → half-open
	if b.Closed() {
		t.Fatalf("during cooldown→half-open the breaker must NOT report CLOSED, got %q", b.State())
	}

	b.Record(true) // the single half-open recovery probe succeeds → CLOSED
	if !b.Closed() {
		t.Fatalf("a successful half-open probe must CLOSE the breaker, got %q", b.State())
	}
}

// TestBreaker_ZeroOptionsUsesDefaults proves a zero Options is valid and uses the
// Default* consts (trips at DefaultFailThreshold consecutive failures).
func TestBreaker_ZeroOptionsUsesDefaults(t *testing.T) {
	t.Parallel()
	b := NewBreaker("tun", Options{})
	for i := uint32(0); i < DefaultFailThreshold-1; i++ {
		b.Record(false)
	}
	if !b.Closed() {
		t.Fatalf("breaker tripped before DefaultFailThreshold (%d), got %q", DefaultFailThreshold, b.State())
	}
	b.Record(false) // reaches DefaultFailThreshold
	if b.Closed() {
		t.Fatalf("breaker must OPEN at DefaultFailThreshold (%d), got %q", DefaultFailThreshold, b.State())
	}
}

// TestRegistry_UnknownTunnelIsClosed proves an unseen tunnel is CLOSED (eligible)
// — the breaker only removes a tunnel after it observes failures.
func TestRegistry_UnknownTunnelIsClosed(t *testing.T) {
	t.Parallel()
	reg := NewRegistry(Options{FailThreshold: 2, Cooldown: time.Minute})
	if !reg.Closed("never-seen") {
		t.Fatal("an unseen tunnel must report CLOSED (eligible)")
	}
}

// TestRegistry_TripsAndFeedsSelectTunnel is the integration proof: a registry-fed
// breaker tripping OPEN on the primary makes SelectTunnel fail over to tier 2,
// exactly as the per-request path will use it.
func TestRegistry_TripsAndFeedsSelectTunnel(t *testing.T) {
	t.Parallel()
	reg := NewRegistry(Options{FailThreshold: 2, Cooldown: time.Minute})

	tiers := []Tier{{Tunnel: "primary", Tier: 1}, {Tunnel: "secondary", Tier: 2}}
	// Health: both up. Breaker: from the registry.
	state := func(tunnel string) (bool, bool) { return reg.Closed(tunnel), true }

	if got := SelectTunnel(tiers, state); got != "primary" {
		t.Fatalf("with both breakers closed, want primary, got %q", got)
	}

	// Trip the primary's breaker OPEN.
	reg.Record("primary", false)
	reg.Record("primary", false)

	if got := SelectTunnel(tiers, state); got != "secondary" {
		t.Fatalf("with primary breaker OPEN, want failover to secondary, got %q", got)
	}

	// Trip the secondary too → no eligible tunnel → fail-closed "".
	reg.Record("secondary", false)
	reg.Record("secondary", false)
	if got := SelectTunnel(tiers, state); got != "" {
		t.Fatalf("with both breakers OPEN, want fail-closed \"\", got %q", got)
	}
}

// TestRegistry_ConcurrentRecord exercises the registry under concurrent Record +
// Closed calls so the -race detector proves the map guard is correct.
func TestRegistry_ConcurrentRecord(t *testing.T) {
	t.Parallel()
	reg := NewRegistry(Options{FailThreshold: 5, Cooldown: time.Minute})
	tunnels := []string{"t1", "t2", "t3", "t4"}

	var wg sync.WaitGroup
	for _, name := range tunnels {
		for i := 0; i < 50; i++ {
			wg.Add(1)
			go func(n string, ok bool) {
				defer wg.Done()
				reg.Record(n, ok)
				_ = reg.Closed(n)
			}(name, i%2 == 0)
		}
	}
	wg.Wait()
}
