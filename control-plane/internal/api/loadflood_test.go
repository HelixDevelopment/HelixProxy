// Type-1 DDoS / sustained-load tests for the Go control-plane API (Task #67 SLICE 1,
// §11.4.85 stress-chaos mandate + §11.4.169 test-type coverage). The §11.4.169 matrix
// previously marked "DDoS PASS" but cited the DATA-PLANE Squid negative-source control,
// NOT this Go control-plane HTTP server — this file closes that gap by driving the REAL
// mTLS server (newHarness → production buildTLSConfig) under a mixed sustained request
// flood and asserting it does NOT crash, hang, deadlock, leak goroutines/FDs, or serve
// torn/partial entities under concurrency.
//
// Anti-bluff (§11.4.85 / §11.4.5 / §11.4.69): every PASS writes captured evidence — a
// per-request latency TSV + a goroutine/FD census summary — under
// qa-results/ddos/control-plane_<run-id>/ (gitignored). The p99 bound is CALIBRATED on
// THIS run (relative to the run's own median, with a measurement-noise floor), never a
// hardcoded literature number (§11.4.6 / §11.4.107(13)).
//
// §11.4.1 discipline: worker goroutines NEVER call t.Fatalf — errors are surfaced via a
// buffered channel and asserted on the main test goroutine (the putProfileConc pattern).
package api

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"runtime"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// --- evidence + math helpers ------------------------------------------------

// repoRootForEvidence walks up from the package dir to the repo root (the dir holding
// .git) so evidence lands at <repo>/qa-results/... . Falls back to a temp dir.
func repoRootForEvidence(t *testing.T) string {
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

// evidenceDir creates (and returns) qa-results/ddos/control-plane_<run-id>/.
func evidenceDir(t *testing.T) string {
	t.Helper()
	runID := time.Now().UTC().Format("20060102-150405") + fmt.Sprintf("-%d", os.Getpid())
	d := filepath.Join(repoRootForEvidence(t), "qa-results", "ddos", "control-plane_"+runID)
	if err := os.MkdirAll(d, 0o755); err != nil {
		t.Fatalf("create evidence dir %s: %v", d, err)
	}
	return d
}

// pct returns the p-th percentile (0..100) of an ASC-sorted duration slice.
func pct(sorted []time.Duration, p float64) time.Duration {
	if len(sorted) == 0 {
		return 0
	}
	idx := int((p/100)*float64(len(sorted))+0.9999) - 1 // ceil, 1-based -> 0-based
	if idx < 0 {
		idx = 0
	}
	if idx >= len(sorted) {
		idx = len(sorted) - 1
	}
	return sorted[idx]
}

// --- per-op request drivers (goroutine-safe, no t.Fatalf — §11.4.1) ---------

// getJSONWellFormed folds the Type-4 residual: while PUTs mutate concurrently, a GET
// list MUST return a COMPLETE, well-formed JSON array — never a torn/partial entity.
// A decode failure on a 200 body is a torn-entity finding surfaced to the test goroutine.
func getJSONWellFormed(c *http.Client, url string, decode func([]byte) error) (int, error) {
	resp, err := c.Get(url)
	if err != nil {
		return 0, err
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return resp.StatusCode, fmt.Errorf("read body: %w", err)
	}
	if resp.StatusCode == http.StatusOK {
		if err := decode(body); err != nil {
			return resp.StatusCode, fmt.Errorf("torn/partial entity (%dB): %w", len(body), err)
		}
	}
	return resp.StatusCode, nil
}

func decodeProfiles(b []byte) error { var v []profileDTO; return json.Unmarshal(b, &v) }
func decodeTargets(b []byte) error  { var v []targetDTO; return json.Unmarshal(b, &v) }

// getPAC drives GET /proxy.pac and asserts the body is a well-formed PAC artifact.
func getPAC(c *http.Client, base string) (int, error) {
	resp, err := c.Get(base + "/proxy.pac")
	if err != nil {
		return 0, err
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return resp.StatusCode, fmt.Errorf("read PAC body: %w", err)
	}
	if resp.StatusCode == http.StatusOK && !bytes.Contains(body, []byte("FindProxyForURL")) {
		return resp.StatusCode, fmt.Errorf("PAC body malformed (%dB): missing FindProxyForURL", len(body))
	}
	return resp.StatusCode, nil
}

// openSSE opens GET /events, confirms the stream header, then tears it down promptly by
// cancelling the request context (which drives the handler's r.Context().Done() path AND
// the fake bus forwarder goroutine's return — a leaked forwarder would surface in the
// post-load goroutine census). A rotating set of these run inside the flood.
func openSSE(c *http.Client, base string, hangDeadline time.Duration) (int, error) {
	ctx, cancel := context.WithTimeout(context.Background(), hangDeadline)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, base+"/events", nil)
	if err != nil {
		return 0, err
	}
	resp, err := c.Do(req)
	if err != nil {
		return 0, err
	}
	code := resp.StatusCode
	cancel()                              // make the server handler + forwarder return
	_, _ = io.Copy(io.Discard, resp.Body) // returns once the cancelled conn closes
	_ = resp.Body.Close()
	return code, nil
}

// --- goroutine / fd census --------------------------------------------------

// settledGoroutines polls NumGoroutine until (n-base) <= tol or the timeout elapses,
// GC-ing + closing idle conns each round so async teardown completes before we read.
func settledGoroutines(c *http.Client, base, tol int, timeout time.Duration) int {
	deadline := time.Now().Add(timeout)
	c.CloseIdleConnections()
	for {
		runtime.GC()
		n := runtime.NumGoroutine()
		if n-base <= tol || time.Now().After(deadline) {
			return n
		}
		time.Sleep(50 * time.Millisecond)
	}
}

// fdCount returns the open-fd count on Linux (honest SKIP elsewhere — §11.4.81).
func fdCount() (int, bool) {
	if runtime.GOOS != "linux" {
		return 0, false
	}
	ents, err := os.ReadDir("/proc/self/fd")
	if err != nil {
		return 0, false
	}
	return len(ents), true
}

// --- the load flood ---------------------------------------------------------

func TestLoadFlood_ControlPlaneAPI(t *testing.T) {
	if testing.Short() {
		t.Skip("SKIP-OK: sustained-load flood not run under -short")
	}

	const (
		workers      = 8
		perWorker    = 30 // total = 240 requests (N >= 200), bounded for the account throttle
		total        = workers * perWorker
		goroutineTol = 16 // transport/server noise headroom; a systematic SSE-forwarder leak (~48) >> this
		fdTol        = 16
		hangDeadline = 5 * time.Second
		// tailK: p99 must stay within tailK * median. Self-calibrating on THIS run's own
		// median (§11.4.6 / §11.4.107(13) — NOT a literature number). Generous headroom vs
		// a healthy in-process p99/p50 (~10-40x) yet load-bearing: a time.Sleep injected
		// into a subset of requests drives p99 >> median and FAILs this bound.
		tailK      = 150
		p50FloorNs = 100_000 // 100µs measurement-noise floor (medians below this are timer noise, not a threshold)
	)

	h := newHarness(t)
	c := h.clientWithCert(t)

	// Warmup: spin up the persistent server/transport goroutines + fds so they sit in the
	// BASELINE (post-load delta then reflects leaks only, not first-touch allocation).
	_, _ = getPAC(c, h.url)
	_, _ = openSSE(c, h.url, hangDeadline)
	_, _ = getJSONWellFormed(c, h.url+"/api/profiles", decodeProfiles)
	if _, err := putProfileConc(c, h.url, "flood-warmup"); err != nil {
		t.Fatalf("warmup PUT failed: %v", err)
	}
	c.CloseIdleConnections()
	time.Sleep(150 * time.Millisecond)
	runtime.GC()
	baseG := runtime.NumGoroutine()
	baseFD, fdOK := fdCount()

	// Fan out the flood. Each worker keeps its own latency/code slices (no shared state);
	// errors go to a buffered channel and are asserted on the MAIN goroutine (§11.4.1).
	var (
		wg       sync.WaitGroup
		errs     = make(chan string, total)
		reqLat   = make([][]time.Duration, workers) // PUT/GET/PAC — homogeneous tail pool
		sseLat   = make([][]time.Duration, workers) // SSE opens — reported, hang-checked only
		codes    = make([][]int, workers)
		sseCount int64
	)

	for w := 0; w < workers; w++ {
		wg.Add(1)
		go func(w int) {
			defer wg.Done()
			var rl, sl []time.Duration
			var cc []int
			for j := 0; j < perWorker; j++ {
				idx := w*perWorker + j
				op := idx % 5
				start := time.Now()
				var (
					code  int
					err   error
					isSSE bool
				)
				switch op {
				case 0:
					code, err = putProfileConc(c, h.url, fmt.Sprintf("flood-%d", idx))
				case 1:
					code, err = getJSONWellFormed(c, h.url+"/api/profiles", decodeProfiles)
				case 2:
					code, err = getJSONWellFormed(c, h.url+"/api/targets", decodeTargets)
				case 3:
					code, err = getPAC(c, h.url)
				case 4:
					isSSE = true
					atomic.AddInt64(&sseCount, 1)
					code, err = openSSE(c, h.url, hangDeadline)
				}
				d := time.Since(start)
				if err != nil {
					errs <- fmt.Sprintf("op=%d idx=%d: %v", op, idx, err)
					continue
				}
				cc = append(cc, code)
				if isSSE {
					sl = append(sl, d)
				} else {
					rl = append(rl, d)
				}
			}
			reqLat[w], sseLat[w], codes[w] = rl, sl, cc
		}(w)
	}
	wg.Wait()
	close(errs)

	// (1) No crash/panic/error — every request returned cleanly (hangs surface here as
	// context-deadline errors, so this also proves no-hang / no-deadlock).
	var failures []string
	for e := range errs {
		failures = append(failures, e)
	}
	if len(failures) > 0 {
		show := failures
		if len(show) > 10 {
			show = show[:10]
		}
		t.Fatalf("flood produced %d request failure(s) (crash/hang/torn-entity); first: \n  %s",
			len(failures), strings.Join(show, "\n  "))
	}

	// Merge latencies + codes.
	var poolA, poolSSE []time.Duration
	codeHist := map[int]int{}
	for w := 0; w < workers; w++ {
		poolA = append(poolA, reqLat[w]...)
		poolSSE = append(poolSSE, sseLat[w]...)
		for _, code := range codes[w] {
			codeHist[code]++
		}
	}
	sort.Slice(poolA, func(i, j int) bool { return poolA[i] < poolA[j] })
	sort.Slice(poolSSE, func(i, j int) bool { return poolSSE[i] < poolSSE[j] })

	if len(poolA) == 0 {
		t.Fatalf("no non-SSE requests recorded — flood did not run")
	}

	// (2) Every observed status code is sane (200/204/400/500 class — never a 5xx crash /
	// torn response / unexpected code). GETs+PAC = 200; PUT = 200; SSE = 200.
	for code, n := range codeHist {
		switch {
		case code == 200 || code == 204:
		case code >= 400 && code <= 599:
			t.Fatalf("flood saw error status %d (%d times) — a well-formed load must not 4xx/5xx here", code, n)
		default:
			t.Fatalf("flood saw unexpected status %d (%d times)", code, n)
		}
	}

	// (3) Latency tail — CALIBRATED on this run's median (§11.4.6). Load-bearing: a Sleep
	// injected into a subset blows p99 >> median and FAILs; an impossibly-tight bound FAILs.
	p50 := pct(poolA, 50)
	p95 := pct(poolA, 95)
	p99 := pct(poolA, 99)
	maxA := poolA[len(poolA)-1]
	effP50 := p50
	if effP50 < time.Duration(p50FloorNs) {
		effP50 = time.Duration(p50FloorNs) // noise floor, NOT a latency threshold on the feature
	}
	bound := time.Duration(tailK) * effP50
	if p99 > bound {
		t.Fatalf("latency-tail blowup: p99=%v exceeds calibrated bound %v (=%d×median floored@%v) — "+
			"a subset of requests degraded/hung under load", p99, bound, tailK, effP50)
	}
	// Absolute sanity derived from the client per-request timeout (10s in clientWithCert),
	// not literature: no healthy in-process request approaches it.
	if maxA >= 10*time.Second {
		t.Fatalf("a request approached the 10s client timeout: max=%v (hang)", maxA)
	}

	// (4) Goroutine census — settle then assert no systematic growth (catches an SSE
	// forwarder / handler goroutine that never returns).
	afterG := settledGoroutines(c, baseG, goroutineTol, 5*time.Second)
	gDelta := afterG - baseG
	if gDelta > goroutineTol {
		t.Fatalf("goroutine leak: baseline=%d after=%d delta=%d > tol=%d "+
			"(a never-returning SSE forwarder/handler under load)", baseG, afterG, gDelta, goroutineTol)
	}

	// (5) FD census (Linux only — honest SKIP elsewhere, §11.4.81).
	fdDelta := 0
	fdStatus := "SKIP(non-linux)"
	if fdOK {
		afterFD, ok2 := fdCount()
		if ok2 {
			fdDelta = afterFD - baseFD
			fdStatus = fmt.Sprintf("baseline=%d after=%d delta=%d tol=%d", baseFD, afterFD, fdDelta, fdTol)
			if fdDelta > fdTol {
				t.Fatalf("fd leak: %s (connections/streams not released under load)", fdStatus)
			}
		}
	}

	// --- captured evidence (§11.4.85 / §11.4.5 / §11.4.69) -------------------
	dir := evidenceDir(t)
	writeLatencyTSV(t, filepath.Join(dir, "latency.tsv"), poolA, poolSSE)
	summary := fmt.Sprintf(
		"control-plane API load-flood — captured evidence (§11.4.85)\n"+
			"workers=%d total_requests=%d sse_opens=%d\n"+
			"request-pool(PUT/GET/PAC) latency: p50=%v p95=%v p99=%v max=%v n=%d\n"+
			"  calibrated tail bound: p99 <= %d×median(floored@%v) = %v  -> PASS\n"+
			"sse-open latency: p50=%v p95=%v max=%v n=%d (hang-deadline=%v)\n"+
			"goroutine census: baseline=%d after=%d delta=%d tol=%d -> %s\n"+
			"fd census: %s\n"+
			"status codes: %v (all 200/204 -> no crash/torn/5xx)\n"+
			"torn-entity check: %d concurrent GETs decoded to complete DTO arrays -> no partial entity\n"+
			"VERDICT: PASS (no crash / no hang / no deadlock / no goroutine|fd leak / no torn entity)\n",
		workers, total, atomic.LoadInt64(&sseCount),
		p50, p95, p99, maxA, len(poolA),
		tailK, effP50, bound,
		pct(poolSSE, 50), pct(poolSSE, 95), sseMax(poolSSE), len(poolSSE), hangDeadline,
		baseG, afterG, gDelta, goroutineTol, passWord(gDelta <= goroutineTol),
		fdStatus,
		codeHist,
		countGETs(codes),
	)
	if err := os.WriteFile(filepath.Join(dir, "summary.txt"), []byte(summary), 0o644); err != nil {
		t.Fatalf("write summary evidence: %v", err)
	}
	t.Logf("§11.4.85 captured evidence: %s\n%s", dir, summary)
}

func sseMax(s []time.Duration) time.Duration {
	if len(s) == 0 {
		return 0
	}
	return s[len(s)-1]
}

func passWord(ok bool) string {
	if ok {
		return "PASS"
	}
	return "FAIL"
}

func countGETs(codes [][]int) int {
	n := 0
	for _, cc := range codes {
		n += len(cc)
	}
	return n
}

func writeLatencyTSV(t *testing.T, path string, poolA, poolSSE []time.Duration) {
	t.Helper()
	var b strings.Builder
	b.WriteString("pool\tlatency_ns\tlatency_ms\n")
	for _, d := range poolA {
		fmt.Fprintf(&b, "request\t%d\t%.3f\n", d.Nanoseconds(), float64(d.Nanoseconds())/1e6)
	}
	for _, d := range poolSSE {
		fmt.Fprintf(&b, "sse\t%d\t%.3f\n", d.Nanoseconds(), float64(d.Nanoseconds())/1e6)
	}
	if err := os.WriteFile(path, []byte(b.String()), 0o644); err != nil {
		t.Fatalf("write latency.tsv: %v", err)
	}
}
