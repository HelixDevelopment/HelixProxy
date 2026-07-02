// Type-2 CHAOS fault-injection test for the aclhelper fail-closed decision (Task
// #67 SLICE 3, §11.4.169 test-type coverage + §11.4.85 chaos mandate). The existing
// decide_test.go fail-closed TABLE proves each SINGLE branch once; this file injects
// a SUSTAINED "redis-unavailable" outage across a whole DECISION STREAM (concurrent,
// N per phase) at BOTH decision branches (GetRoute and GetStatus) and asserts ZERO
// affirmative `(true,*)` leaks across the entire outage window — then restores the
// bus and proves the affirmative path returns (categorised recovery). The novelty
// vs decide_test.go is the outage WINDOW + concurrency + no-leak-across-N invariant,
// not a single-branch assertion.
//
// Decide (decide.go:47) is pure fail-closed, so a Bus that errors MUST yield ERR on
// every call. A leak here (any `(true,*)` while redis is down) would be a §11.4 /
// §11.4.1 fail-open defect — the exact class Squid-facing routing must never do.
//
// Anti-bluff (§11.4.85 / §11.4.69): the PASS writes captured evidence
// (categorised_errors / recovery_trace) under gitignored
// qa-results/chaos/aclhelper_<run-id>/. The fault Bus is mutex-guarded so the
// concurrent stream is -race clean; the fault is held STABLE for each phase so the
// zero-leak verdict is deterministic (§11.4.50), not timing-dependent.
package aclhelper

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"digital.vasic.helixproxy/controlplane/internal/redis"
	"digital.vasic.helixproxy/controlplane/internal/vpn"
)

// faultBus is a mutex-guarded Bus whose GetRoute/GetStatus flip to returning
// transport errors when the corresponding outage flag is armed. When healthy it
// returns a route to routeTunnel and an UP snapshot (the single affirmative path).
type faultBus struct {
	mu          sync.Mutex
	routeTunnel string
	routeErr    bool // GetRoute returns a transport error (redis route-layer outage)
	statusErr   bool // GetStatus returns a transport error (redis status-layer outage)
}

func (b *faultBus) arm(route, status bool) {
	b.mu.Lock()
	b.routeErr, b.statusErr = route, status
	b.mu.Unlock()
}

func (b *faultBus) GetRoute(_ context.Context, target string) (redis.Route, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.routeErr {
		return redis.Route{}, errors.New("redis: get route: dial tcp 127.0.0.1:6379: connect: connection refused")
	}
	return redis.Route{Target: target, Tunnel: b.routeTunnel}, nil
}

func (b *faultBus) GetStatus(_ context.Context, profile string) (vpn.HealthSnapshot, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.statusErr {
		// Mirror the real client: a DOWN-safe snapshot AND the transport error.
		return vpn.HealthSnapshot{Profile: profile, State: vpn.StateDown}, errors.New("redis: get status: i/o timeout")
	}
	return vpn.HealthSnapshot{Profile: profile, State: vpn.StateUp, CheckedAt: time.Now().UTC()}, nil
}

func aclRepoRoot(t *testing.T) string {
	t.Helper()
	dir, err := os.Getwd()
	if err != nil {
		return t.TempDir()
	}
	for {
		if _, err := os.Stat(filepath.Join(dir, ".git")); err == nil {
			return dir
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			return t.TempDir()
		}
		dir = parent
	}
}

func aclChaosEvidenceDir(t *testing.T) string {
	t.Helper()
	runID := time.Now().UTC().Format("20060102-150405") + fmt.Sprintf("-%d", os.Getpid())
	d := filepath.Join(aclRepoRoot(t), "qa-results", "chaos", "aclhelper_"+runID)
	if err := os.MkdirAll(d, 0o755); err != nil {
		t.Fatalf("create chaos evidence dir %s: %v", d, err)
	}
	return d
}

// runOutageWindow drives N concurrent decisions (G goroutines) while the fault is
// held stable, returning the number of affirmative `(true,*)` LEAKS observed.
func runOutageWindow(d Decider, n int) int64 {
	const g = 8
	var leaks int64
	var wg sync.WaitGroup
	per := n / g
	for w := 0; w < g; w++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for i := 0; i < per; i++ {
				ok, tag := d.Decide(context.Background(), "target-a")
				if ok || tag != "" {
					atomic.AddInt64(&leaks, 1)
				}
			}
		}()
	}
	wg.Wait()
	return leaks
}

// TestDecideChaos_RedisUnavailableMidDecideFailsClosed injects a sustained redis
// outage at each decision branch and asserts EVERY decision across the window is
// fail-closed `(false,"")` — zero affirmative leaks — then restores the bus and
// proves the affirmative path recovers.
func TestDecideChaos_RedisUnavailableMidDecideFailsClosed(t *testing.T) {
	bus := &faultBus{routeTunnel: "tun_a"}
	d := Decider{Bus: bus}
	evd := aclChaosEvidenceDir(t)

	// Cleanup clears every fault flag (§11.4.14).
	t.Cleanup(func() { bus.arm(false, false) })

	const N = 800

	// Phase 0 — healthy baseline: the affirmative path works (proves the fault, not a
	// permanently-broken bus, is what drives ERR in the outage phases).
	if ok, tag := d.Decide(context.Background(), "target-a"); !ok || tag != "tun_a" {
		t.Fatalf("healthy baseline: Decide = (%v,%q), want (true,\"tun_a\")", ok, tag)
	}

	// Phase 1 — route-layer outage (GetRoute errors).
	bus.arm(true, false)
	if leaks := runOutageWindow(d, N); leaks != 0 {
		t.Fatalf("route-layer outage: %d/%d decisions leaked (true,*) — fail-OPEN defect", leaks, N)
	}

	// Phase 2 — status-layer outage (route resolves, GetStatus errors).
	bus.arm(false, true)
	if leaks := runOutageWindow(d, N); leaks != 0 {
		t.Fatalf("status-layer outage: %d/%d decisions leaked (true,*) — fail-OPEN defect", leaks, N)
	}

	// Phase 3 — full outage (both branches error).
	bus.arm(true, true)
	if leaks := runOutageWindow(d, N); leaks != 0 {
		t.Fatalf("full outage: %d/%d decisions leaked (true,*) — fail-OPEN defect", leaks, N)
	}

	// Phase 4 — restore: the affirmative path returns (categorised recovery).
	bus.arm(false, false)
	if ok, tag := d.Decide(context.Background(), "target-a"); !ok || tag != "tun_a" {
		t.Fatalf("recovery: affirmative path did not return after outage cleared: (%v,%q), want (true,\"tun_a\")", ok, tag)
	}

	writeAclEvidence(t, evd, "categorised_errors.txt",
		fmt.Sprintf("fault=redis-unavailable-mid-decide category=network_upstream (redis)\n"+
			"decisions_per_phase=%d concurrency=8\n"+
			"phase1 route_outage:  leaks=0 (all ERR)\n"+
			"phase2 status_outage: leaks=0 (all ERR)\n"+
			"phase3 full_outage:   leaks=0 (all ERR)\n"+
			"invariant: zero (true,*) across the entire outage window (fail-closed)\n", N))
	writeAclEvidence(t, evd, "recovery_trace.txt",
		"0. healthy: Decide(target-a) -> (true,tun_a)\n"+
			"1-3. redis outage armed (route / status / both) -> every decision (false,\"\")\n"+
			"4. outage cleared -> Decide(target-a) -> (true,tun_a) (recovered)\n")
}

func writeAclEvidence(t *testing.T, dir, name, content string) {
	t.Helper()
	p := filepath.Join(dir, name)
	if err := os.WriteFile(p, []byte(content), 0o644); err != nil {
		t.Fatalf("write evidence %s: %v", p, err)
	}
	t.Logf("chaos evidence: %s", p)
}
