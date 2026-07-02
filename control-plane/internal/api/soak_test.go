// Type-3 MEMORY-SOAK test for the Go control-plane API (Task #67 SLICE 2,
// §11.4.169 test-type coverage + §11.4.85 stress mandate). The §11.4.169 matrix's
// MEMORY row previously cited the DATA-PLANE Squid soak, NOT this Go control-plane
// HTTP server — this file closes that gap by CHURNING the REAL mTLS server
// (newHarness → production buildTLSConfig) through many PUT/GET/PAC/SSE cycles and
// asserting the heap + goroutine footprint does NOT grow unbounded across the run.
//
// The leak CANDIDATE is the per-SSE-stream server-side forwarder goroutine
// (fakeBus.SubscribeEvents, harness_test.go) + the SSE handler loop (handlers.go):
// a stream that opens then closes MUST reap its forwarder. A never-returning
// forwarder (or a request path that retains state) shows up as (a) NumGoroutine
// climbing across iterations and (b) live-heap HeapObjects/HeapAlloc growing.
//
// Anti-bluff (§11.4.5 / §11.4.69 / §11.4.107(13)): the PASS is gated on CAPTURED
// measurements — a memstats timeseries TSV + a soak.evidence summary under
// qa-results/memory/control-plane_<run-id>/ (gitignored). The growth bound is a
// RATIO (final/baseline ≤ 1.5) computed on THIS run after forced GC at both
// endpoints — never a hardcoded byte count (§11.4.6). Determinism (§11.4.50):
// a warm-up pre-fills the bounded 64-name profile set + persistent server/transport
// goroutines into the BASELINE, and both endpoints are read after a double
// runtime.GC(), so the ratio reflects retained (leaked) memory only, not GC phase
// noise nor first-touch allocation. Two by-design test-fake accumulations are
// neutralised so they cannot masquerade as a leak: PUT names are drawn from a
// bounded 64-name pool (fake profile store stays <=64), and the fake's per-PUT
// in-memory audit slice is drained at every measurement (drainFakeAudit) — the real
// server persists audits to Postgres, retaining nothing on the process heap — which
// also makes the growth ratio N-INVARIANT for the full SOAK_ITERS>=5000 soak.
//
// §11.4.1 discipline: no worker goroutines here (sequential churn) — every failure
// is a genuine product/leak finding surfaced on the test goroutine, never a
// script-internal crash.
//
// Reuses loadflood_test.go / concurrency_test.go helpers (same package, untouched):
// openSSE, getJSONWellFormed, decodeProfiles, decodeTargets, getPAC,
// settledGoroutines, repoRootForEvidence, putProfileConc, and the newHarness /
// clientWithCert mTLS harness.
package api

import (
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"testing"
	"time"
)

// doubleGC forces two GC cycles so finalizers run and the live-heap reading
// settles (the standard "read a stable HeapObjects" idiom).
func doubleGC() { runtime.GC(); runtime.GC() }

// heapSnapshot after a doubleGC — the retained (live) heap.
type heapSnapshot struct {
	heapAlloc   uint64
	heapInuse   uint64
	heapObjects uint64
	goroutines  int
}

// drainFakeAudit clears the in-memory audit slice the unit-test fake accumulates
// (fakeQueries.AppendAudit does `f.audits = append(...)` — one row per PUT). That
// unbounded slice is a TEST-HARNESS artifact, NOT production behaviour: the real
// server persists each audit row to Postgres and retains nothing on the process
// heap. Draining it before every heap measurement makes the growth ratio reflect
// PRODUCTION-relevant retention (server/transport goroutines, connection pool,
// request-path allocations) and keeps the ratio N-INVARIANT — so a full soak
// (SOAK_ITERS>=5000, 1000+ PUTs) is bounded by real footprint, never by the fake's
// bookkeeping. Same mutex the fake's AppendAudit uses, so -race stays clean.
// Reaches only package-visible fields (same package) — harness_test.go is untouched.
func drainFakeAudit(h *harness) {
	if h.q == nil {
		return
	}
	h.q.mu.Lock()
	h.q.audits = nil
	h.q.mu.Unlock()
}

func readHeap() heapSnapshot {
	doubleGC()
	var m runtime.MemStats
	runtime.ReadMemStats(&m)
	return heapSnapshot{
		heapAlloc:   m.HeapAlloc,
		heapInuse:   m.HeapInuse,
		heapObjects: m.HeapObjects,
		goroutines:  runtime.NumGoroutine(),
	}
}

// readVmHWMkB returns the process peak-RSS (VmHWM) in kB on Linux (honest SKIP
// elsewhere — §11.4.81 cross-platform-parity: Darwin/BSD have no /proc VmHWM).
func readVmHWMkB() (int, bool) {
	if runtime.GOOS != "linux" {
		return 0, false
	}
	b, err := os.ReadFile("/proc/self/status")
	if err != nil {
		return 0, false
	}
	for _, line := range strings.Split(string(b), "\n") {
		if strings.HasPrefix(line, "VmHWM:") {
			f := strings.Fields(line) // ["VmHWM:", "12345", "kB"]
			if len(f) >= 2 {
				if v, err := strconv.Atoi(f[1]); err == nil {
					return v, true
				}
			}
		}
	}
	return 0, false
}

// soakEvidenceDir creates qa-results/memory/control-plane_<run-id>/ (gitignored).
func soakEvidenceDir(t *testing.T) string {
	t.Helper()
	runID := time.Now().UTC().Format("20060102-150405") + fmt.Sprintf("-%d", os.Getpid())
	d := filepath.Join(repoRootForEvidence(t), "qa-results", "memory", "control-plane_"+runID)
	if err := os.MkdirAll(d, 0o755); err != nil {
		t.Fatalf("create evidence dir %s: %v", d, err)
	}
	return d
}

// TestMemorySoak_ControlPlaneAPI churns the real control-plane API and asserts a
// bounded heap + goroutine footprint (no leak).
func TestMemorySoak_ControlPlaneAPI(t *testing.T) {
	if testing.Short() {
		t.Skip("SKIP-OK: memory-soak not run under -short")
	}

	// Iteration count: DEFAULT is modest so an un-env'd run finishes in a few
	// seconds (suite-friendly); export SOAK_ITERS>=5000 for a full soak.
	iters := 1500
	if v := os.Getenv("SOAK_ITERS"); v != "" {
		if n, err := strconv.Atoi(v); err == nil && n > 0 {
			iters = n
		}
	}

	const (
		nameSet      = 64               // bounded PUT name pool → fake store holds <=64 profiles
		warmupIters  = 128              // covers all 64 names >=2x so the store is FULL at baseline
		goroutineTol = 16               // transport/server noise headroom; a per-SSE forwarder leak (>=iters/5) >> this
		growthBound  = 1.5              // final/baseline live-heap ratio ceiling (§11.4.6 — ratio, not a byte count)
		hangDeadline = 5 * time.Second  // per-SSE open→close context budget
		wallBudget   = 90 * time.Second // hard wall-clock cap so a throttled verify run cannot hang
	)

	h := newHarness(t)
	c := h.clientWithCert(t)

	// One churn cycle: op selected by i%5 (PUT / GET profiles / GET targets / PAC /
	// SSE open→close). Bounded PUT names keep the fake store from growing by design.
	churn := func(i int) error {
		switch i % 5 {
		case 0:
			_, err := putProfileConc(c, h.url, fmt.Sprintf("soak-%d", i%nameSet))
			return err
		case 1:
			_, err := getJSONWellFormed(c, h.url+"/api/profiles", decodeProfiles)
			return err
		case 2:
			_, err := getJSONWellFormed(c, h.url+"/api/targets", decodeTargets)
			return err
		case 3:
			_, err := getPAC(c, h.url)
			return err
		default:
			_, err := openSSE(c, h.url, hangDeadline)
			return err
		}
	}

	// Warm-up: spin up persistent server/transport goroutines + fill the 64-name
	// store so BASELINE is steady-state (post-warmup delta => leaks only).
	for i := 0; i < warmupIters; i++ {
		if err := churn(i); err != nil {
			t.Fatalf("warmup churn i=%d: %v", i, err)
		}
	}
	c.CloseIdleConnections()
	baseG := settledGoroutines(c, 0, 0, 3*time.Second) // stabilise before reading (returns settled count)
	drainFakeAudit(h)                                  // exclude the fake's per-PUT audit bookkeeping from every measurement
	base := readHeap()
	base.goroutines = baseG
	baseVmHWM, vmOK := readVmHWMkB()

	// Sample the live heap every K iters into the evidence timeseries.
	sampleEvery := iters / 20
	if sampleEvery < 50 {
		sampleEvery = 50
	}
	type sample struct {
		iter                              int
		heapAlloc, heapInuse, heapObjects uint64
		goroutines                        int
	}
	series := []sample{{0, base.heapAlloc, base.heapInuse, base.heapObjects, base.goroutines}}

	// Main soak loop.
	deadline := time.Now().Add(wallBudget)
	sseOpens, ran := 0, 0
	var firstErr string
	for i := 0; i < iters; i++ {
		if i%5 == 4 {
			sseOpens++
		}
		if err := churn(i); err != nil {
			if firstErr == "" {
				firstErr = fmt.Sprintf("op=%d iter=%d: %v", i%5, i, err)
			}
		}
		ran++
		if (i+1)%sampleEvery == 0 {
			drainFakeAudit(h)
			s := readHeap()
			series = append(series, sample{i + 1, s.heapAlloc, s.heapInuse, s.heapObjects, s.goroutines})
		}
		if time.Now().After(deadline) {
			t.Logf("wall-clock budget %v reached at iter %d/%d — stopping early (ratio still valid)", wallBudget, i+1, iters)
			break
		}
	}

	// A churn error is a genuine finding (crash/hang/torn) — soak must be clean.
	if firstErr != "" {
		t.Fatalf("soak churn produced request failure(s); first: %s", firstErr)
	}

	// Settle async SSE-forwarder teardown, then read the final live heap.
	afterG := settledGoroutines(c, base.goroutines, goroutineTol, 10*time.Second)
	drainFakeAudit(h)
	final := readHeap()
	final.goroutines = afterG
	finalVmHWM, _ := readVmHWMkB()
	series = append(series, sample{ran, final.heapAlloc, final.heapInuse, final.heapObjects, final.goroutines})

	// --- assertions (gated on captured measurements) -------------------------

	if base.heapObjects == 0 || base.heapAlloc == 0 {
		t.Fatalf("degenerate baseline (heapObjects=%d heapAlloc=%d) — warm-up did not allocate",
			base.heapObjects, base.heapAlloc)
	}
	objRatio := float64(final.heapObjects) / float64(base.heapObjects)
	allocRatio := float64(final.heapAlloc) / float64(base.heapAlloc)

	// (1) Live-heap growth ratio — the retained-memory guard. Load-bearing: a request
	// path that retains references (or an unbounded fake accumulation) drives the ratio
	// past the bound. Calibrated on THIS run's own baseline (§11.4.6 / §11.4.107(13)).
	if objRatio > growthBound {
		t.Fatalf("HeapObjects leak: baseline=%d final=%d ratio=%.3f > bound %.2f "+
			"(memory retained across %d churn iters)", base.heapObjects, final.heapObjects, objRatio, growthBound, ran)
	}
	if allocRatio > growthBound {
		t.Fatalf("HeapAlloc leak: baseline=%d final=%d ratio=%.3f > bound %.2f "+
			"(memory retained across %d churn iters)", base.heapAlloc, final.heapAlloc, allocRatio, growthBound, ran)
	}

	// (2) Goroutine census — the REAL leak guard: every SSE open→close MUST reap its
	// server-side forwarder + handler goroutine. A never-returning forwarder (one per
	// SSE open, >= ran/5 of them) blows this bound.
	gDelta := final.goroutines - base.goroutines
	if gDelta > goroutineTol {
		t.Fatalf("goroutine leak: baseline=%d final=%d delta=%d > tol=%d over %d SSE open/close cycles "+
			"(a never-returning SSE forwarder/handler goroutine)", base.goroutines, final.goroutines, gDelta, goroutineTol, sseOpens)
	}

	// --- captured evidence (§11.4.5 / §11.4.69) ------------------------------
	dir := soakEvidenceDir(t)

	var tsv strings.Builder
	tsv.WriteString("iter\theap_alloc_bytes\theap_inuse_bytes\theap_objects\tgoroutines\n")
	for _, s := range series {
		fmt.Fprintf(&tsv, "%d\t%d\t%d\t%d\t%d\n", s.iter, s.heapAlloc, s.heapInuse, s.heapObjects, s.goroutines)
	}
	if err := os.WriteFile(filepath.Join(dir, "memstats_timeseries.tsv"), []byte(tsv.String()), 0o644); err != nil {
		t.Fatalf("write memstats_timeseries.tsv: %v", err)
	}

	vmLine := "peak-rss(VmHWM): SKIP(non-linux)"
	if vmOK {
		vmLine = fmt.Sprintf("peak-rss(VmHWM): baseline=%d kB final=%d kB delta=%+d kB", baseVmHWM, finalVmHWM, finalVmHWM-baseVmHWM)
	}
	summary := fmt.Sprintf(
		"control-plane API memory-soak — captured evidence (§11.4.169 / §11.4.85)\n"+
			"iters(requested)=%d iters(ran)=%d sse_open_close=%d name_pool=%d (fake store bounded)\n"+
			"warm-up=%d cycles pre-filled the store + persistent goroutines into the baseline\n"+
			"LIVE-HEAP (post double-GC at each endpoint):\n"+
			"  HeapObjects: baseline=%d final=%d ratio=%.3f  (bound <= %.2f) -> %s\n"+
			"  HeapAlloc  : baseline=%d final=%d ratio=%.3f  (bound <= %.2f) -> %s\n"+
			"  HeapInuse  : baseline=%d final=%d bytes\n"+
			"GOROUTINES : baseline=%d final=%d delta=%+d  (tol=%d) -> %s  [SSE-forwarder reap guard]\n"+
			"%s\n"+
			"timeseries : %d samples in memstats_timeseries.tsv\n"+
			"VERDICT: PASS (bounded heap growth ratio + all SSE forwarders reaped — no memory/goroutine leak)\n",
		iters, ran, sseOpens, nameSet,
		warmupIters,
		base.heapObjects, final.heapObjects, objRatio, growthBound, passWord(objRatio <= growthBound),
		base.heapAlloc, final.heapAlloc, allocRatio, growthBound, passWord(allocRatio <= growthBound),
		base.heapInuse, final.heapInuse,
		base.goroutines, final.goroutines, gDelta, goroutineTol, passWord(gDelta <= goroutineTol),
		vmLine,
		len(series),
	)
	if err := os.WriteFile(filepath.Join(dir, "soak.evidence"), []byte(summary), 0o644); err != nil {
		t.Fatalf("write soak.evidence: %v", err)
	}
	t.Logf("§11.4.169 captured evidence: %s\n%s", dir, summary)
}
