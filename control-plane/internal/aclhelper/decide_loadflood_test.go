// Type-1 DDoS / sustained-load test for the aclhelper decision hot path (Task #67
// SLICE 1, §11.4.85 stress-chaos + §11.4.169 test-type coverage). Decider.Decide is the
// per-request fail-closed routing verdict Squid calls on EVERY proxied connection — the
// busiest code path in the system — so it MUST stay correct, deadlock-free, and
// panic-free under a sustained tight-loop flood. Zero infrastructure: driven against the
// same in-memory fakeBus the decide_test.go table uses (fakes permitted in unit tests,
// §11.4.27).
//
// §11.4.1 discipline: worker goroutines surface errors via a buffered channel; the
// verdict is asserted on the MAIN test goroutine.
package aclhelper

import (
	"context"
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

func aclEvidenceDir(t *testing.T) string {
	t.Helper()
	dir, err := os.Getwd()
	if err != nil {
		return t.TempDir()
	}
	root := t.TempDir()
	for {
		if _, err := os.Stat(filepath.Join(dir, ".git")); err == nil {
			root = dir
			break
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			break
		}
		dir = parent
	}
	runID := time.Now().UTC().Format("20060102-150405") + fmt.Sprintf("-%d", os.Getpid())
	d := filepath.Join(root, "qa-results", "ddos", "aclhelper_"+runID)
	if err := os.MkdirAll(d, 0o755); err != nil {
		t.Fatalf("create evidence dir %s: %v", d, err)
	}
	return d
}

// TestLoadFlood_DecideHotPath floods Decide sequentially AND concurrently and asserts it
// never panics/deadlocks and the affirmative path (route+up -> OK tag) stays correct
// under load. Captured evidence: qa-results/ddos/aclhelper_<run-id>/decide_flood.tsv.
func TestLoadFlood_DecideHotPath(t *testing.T) {
	if testing.Short() {
		t.Skip("SKIP-OK: decide sustained-load flood not run under -short")
	}

	const (
		seqN        = 20000 // sequential tight loop (N >= 10000)
		concWorkers = 8
		concPer     = 5000 // 8*5000 = 40000 concurrent calls
		deadlock    = 20 * time.Second
	)

	ctx := context.Background()
	affirmative := fakeBus{route: redis.Route{Tunnel: "tun_a"}, snap: up("tun_a")}
	dOK := Decider{Bus: affirmative}
	// A fail-closed bus interleaved into the flood so we exercise the negation branch under
	// load too (down tunnel -> ERR), proving the fail-closed verdict is stable under stress.
	dDown := Decider{Bus: fakeBus{route: redis.Route{Tunnel: "tun_a"}, snap: vpn.HealthSnapshot{Profile: "tun_a", State: vpn.StateDown}}}

	// --- sequential flood: affirmative correctness must hold every iteration ------
	start := time.Now()
	var okCount int64
	for i := 0; i < seqN; i++ {
		ok, tag := dOK.Decide(ctx, "target-a")
		if !ok || tag != "tun_a" {
			t.Fatalf("affirmative path broke under load at iter %d: ok=%v tag=%q (want ok=true tag=tun_a)", i, ok, tag)
		}
		okCount++
		// interleave the fail-closed branch — must ALWAYS refuse.
		if down, _ := dDown.Decide(ctx, "target-a"); down {
			t.Fatalf("fail-closed path leaked an OK under load at iter %d", i)
		}
	}
	seqElapsed := time.Since(start)
	if okCount != seqN {
		t.Fatalf("affirmative OK count = %d, want %d", okCount, seqN)
	}

	// --- concurrent flood: no deadlock / no panic, verdict still correct ----------
	var (
		wg    sync.WaitGroup
		errs  = make(chan string, concWorkers)
		concN int64
	)
	cStart := time.Now()
	done := make(chan struct{})
	for w := 0; w < concWorkers; w++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for i := 0; i < concPer; i++ {
				ok, tag := dOK.Decide(ctx, "target-a")
				if !ok || tag != "tun_a" {
					errs <- fmt.Sprintf("concurrent affirmative wrong: ok=%v tag=%q", ok, tag)
					return
				}
				atomic.AddInt64(&concN, 1)
			}
		}()
	}
	go func() { wg.Wait(); close(done) }()
	select {
	case <-done:
	case <-time.After(deadlock):
		t.Fatalf("decide flood did not complete within %v — possible deadlock/hang under load", deadlock)
	}
	close(errs)
	for e := range errs {
		t.Fatalf("concurrent decide flood failed: %s", e)
	}
	concElapsed := time.Since(cStart)
	if concN != int64(concWorkers*concPer) {
		t.Fatalf("concurrent decide count = %d, want %d", concN, concWorkers*concPer)
	}

	// --- captured evidence (§11.4.85 / §11.4.5 / §11.4.69) ------------------------
	dir := aclEvidenceDir(t)
	seqNsOp := seqElapsed.Nanoseconds() / int64(seqN)
	concTotal := int64(concWorkers * concPer)
	concNsOp := concElapsed.Nanoseconds() / concTotal
	tsv := fmt.Sprintf(
		"phase\tcalls\telapsed_ns\tns_per_call\tcalls_per_sec\n"+
			"sequential\t%d\t%d\t%d\t%.0f\n"+
			"concurrent\t%d\t%d\t%d\t%.0f\n",
		seqN, seqElapsed.Nanoseconds(), seqNsOp, float64(seqN)/seqElapsed.Seconds(),
		concTotal, concElapsed.Nanoseconds(), concNsOp, float64(concTotal)/concElapsed.Seconds(),
	)
	if err := os.WriteFile(filepath.Join(dir, "decide_flood.tsv"), []byte(tsv), 0o644); err != nil {
		t.Fatalf("write decide_flood.tsv: %v", err)
	}
	summary := fmt.Sprintf(
		"aclhelper Decide hot-path load-flood — captured evidence (§11.4.85)\n"+
			"sequential: %d calls in %v (%d ns/call), affirmative OK every iteration\n"+
			"fail-closed branch interleaved %d times: refused every time\n"+
			"concurrent: %d workers × %d = %d calls in %v (%d ns/call), no deadlock (deadline %v), verdict correct\n"+
			"VERDICT: PASS (no panic / no deadlock / affirmative + fail-closed correct under sustained load)\n",
		seqN, seqElapsed, seqNsOp, seqN, concWorkers, concPer, concTotal, concElapsed, concNsOp, deadlock)
	if err := os.WriteFile(filepath.Join(dir, "summary.txt"), []byte(summary), 0o644); err != nil {
		t.Fatalf("write summary: %v", err)
	}
	t.Logf("§11.4.85 captured evidence: %s\n%s", dir, summary)
}
