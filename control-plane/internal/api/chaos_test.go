// Type-2 CHAOS fault-injection tests for the Go control-plane API (Task #67 SLICE
// 3, §11.4.169 test-type coverage + §11.4.85 stress+chaos mandate). The §11.4.169
// matrix's CHAOS row previously cited the DATA-PLANE Squid fault-injection, NOT
// this Go control-plane HTTP server — this file closes that gap by injecting three
// real fault classes into the REAL mTLS server (newHarness → production
// buildTLSConfig) and asserting CATEGORISED recovery, no partial state, and no
// goroutine leak:
//
//  1. Store-drop mid-WithTx  — the audit-append store call fails mid-transaction
//     (via the existing fakeQueries.setAuditErr hook, harness_test.go:241): the
//     mutation returns 500 AND rolls back (no un-audited mutation — the same
//     atomicity invariant as atomicity_test.go), then the fault clears and the
//     next PUT succeeds + audit lands (categorised recovery).
//  2. SSE client disconnect  — M SSE streams are opened then their request
//     contexts cancelled at random mid-stream; every server-side forwarder
//     goroutine (fakeBus.SubscribeEvents) MUST return (NumGoroutine back to
//     baseline — no leak) and the server MUST keep serving new requests.
//  3. Context-cancel mid-mutation — a PUT's request context is cancelled: clean
//     error (no panic), no partial write. HONEST LIMIT (§11.4.3): the fake WithTx
//     ignores ctx (harness_test.go:529), so true in-flight BeginTx-abort needs
//     real Postgres → a DATABASE_URL-guarded variant SKIPs-with-reason when unset
//     (never a fake PASS); the fake exercises only cancel-before-dispatch.
//
// Anti-bluff (§11.4.85 / §11.4.5 / §11.4.69): each PASS writes CAPTURED evidence
// (categorised_errors / recovery_trace / state_delta) under a gitignored
// qa-results/chaos/control-plane_<run-id>/ dir. Every injected fault flag is
// restored in t.Cleanup (§11.4.14). Determinism (§11.4.50): the churn ORDER is
// randomised but every VERDICT (rollback / no-leak / no-partial-write) is
// order-invariant, so the pass is stable across -count>1.
//
// §11.4.1 discipline: request drivers use putProfileConc (no t.Fatalf off the test
// goroutine); every failure is a genuine product finding on the test goroutine.
//
// Reuses harness_test.go / loadflood_test.go helpers (same package, UNTOUCHED):
// newHarness, clientWithCert, putProfileConc, settledGoroutines,
// repoRootForEvidence, and the fakeQueries.setAuditErr fault hook.
package api

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math/rand"
	"net/http"
	"os"
	"path/filepath"
	"runtime"
	"sync"
	"testing"
	"time"

	"digital.vasic.helixproxy/controlplane/internal/redis"
	"digital.vasic.helixproxy/controlplane/internal/vpn"
)

// chaosEvidenceDir creates (and returns) qa-results/chaos/control-plane_<run-id>/.
func chaosEvidenceDir(t *testing.T) string {
	t.Helper()
	runID := time.Now().UTC().Format("20060102-150405") + fmt.Sprintf("-%d", os.Getpid())
	d := filepath.Join(repoRootForEvidence(t), "qa-results", "chaos", "control-plane_"+runID)
	if err := os.MkdirAll(d, 0o755); err != nil {
		t.Fatalf("create chaos evidence dir %s: %v", d, err)
	}
	return d
}

// writeChaosEvidence persists one captured-evidence artefact (§11.4.5 / §11.4.69).
func writeChaosEvidence(t *testing.T, dir, name, content string) {
	t.Helper()
	p := filepath.Join(dir, name)
	if err := os.WriteFile(p, []byte(content), 0o644); err != nil {
		t.Fatalf("write evidence %s: %v", p, err)
	}
	t.Logf("chaos evidence: %s", p)
}

// TestChaos_StoreDropMidWithTxRollsBack injects a mid-transaction store drop on the
// audit-append leg of mutateWithAudit → WithTx (handlers.go:142). The mutation MUST
// return 500 and leave NO partial state (the entity mutation rolled back with its
// failed audit — the atomicity_test.go:96 invariant, re-asserted under a chaos
// framing), then the fault clears and the next PUT recovers cleanly (categorised
// recovery: fault-window FAIL → post-fault SUCCESS + audit lands).
func TestChaos_StoreDropMidWithTxRollsBack(t *testing.T) {
	h := newHarness(t)
	c := h.clientWithCert(t)
	evd := chaosEvidenceDir(t)

	// Cleanup restores the fault flag regardless of exit path (§11.4.14).
	t.Cleanup(func() { h.q.setAuditErr(nil) })

	baseProfiles := h.q.profileCount()
	baseAudits := h.q.auditCount()

	// --- inject the store drop mid-WithTx ---
	injected := errors.New("chaos: audit store dropped mid-transaction")
	h.q.setAuditErr(injected)

	code, err := putProfileConc(c, h.url, "chaos-drop-wg")
	if err != nil {
		t.Fatalf("PUT under injected store-drop: transport error %v (want a clean 500)", err)
	}
	if code != http.StatusInternalServerError {
		t.Fatalf("store-drop mid-WithTx must surface as HTTP 500, got %d", code)
	}
	// No partial state: the mutation rolled back with its failed audit.
	if got := h.q.profileCount(); got != baseProfiles {
		t.Fatalf("un-audited mutation PERSISTED across the fault: want %d profiles (rolled back), got %d", baseProfiles, got)
	}
	if got := h.q.auditCount(); got != baseAudits {
		t.Fatalf("partial audit row landed on injected failure: want %d, got %d", baseAudits, got)
	}

	// --- clear the fault: categorised recovery ---
	h.q.setAuditErr(nil)
	code2, err := putProfileConc(c, h.url, "chaos-recover-wg")
	if err != nil {
		t.Fatalf("post-fault PUT: transport error %v", err)
	}
	if code2 != http.StatusOK {
		t.Fatalf("post-fault PUT must succeed (200), got %d", code2)
	}
	if got := h.q.profileCount(); got != baseProfiles+1 {
		t.Fatalf("recovery mutation did not persist: want %d profiles, got %d", baseProfiles+1, got)
	}
	if got := h.q.auditCount(); got != baseAudits+1 {
		t.Fatalf("recovery audit row did not land: want %d, got %d", baseAudits+1, got)
	}

	writeChaosEvidence(t, evd, "categorised_errors.txt",
		fmt.Sprintf("fault=store-drop-mid-withtx category=store_transaction\n"+
			"fault_window: PUT chaos-drop-wg -> HTTP %d (rolled back)\n"+
			"post_fault:   PUT chaos-recover-wg -> HTTP %d (committed)\n", code, code2))
	writeChaosEvidence(t, evd, "state_delta.txt",
		fmt.Sprintf("profiles: base=%d after_fault=%d after_recovery=%d\n"+
			"audits:   base=%d after_fault=%d after_recovery=%d\n"+
			"invariant: an un-audited mutation is impossible (mutation+audit atomic in WithTx)\n",
			baseProfiles, baseProfiles, h.q.profileCount(),
			baseAudits, baseAudits, h.q.auditCount()))
	writeChaosEvidence(t, evd, "recovery_trace.txt",
		"1. inject setAuditErr -> PUT returns 500, no partial state (categorised: store_transaction fault)\n"+
			"2. clear setAuditErr  -> next PUT returns 200, entity+audit both persist (recovered)\n")
}

// TestChaos_SSEClientDisconnectNoLeak opens M SSE streams over the REAL mTLS server,
// cancels their request contexts at random mid-stream, and asserts every server-side
// forwarder goroutine (fakeBus.SubscribeEvents) + handler loop returns — NumGoroutine
// settles back to baseline (no leak) — and the server keeps serving new requests
// after the churn. A leaked forwarder would leave NumGoroutine ~M above baseline.
func TestChaos_SSEClientDisconnectNoLeak(t *testing.T) {
	h := newHarness(t)
	c := h.clientWithCert(t)
	evd := chaosEvidenceDir(t)

	const (
		M   = 12
		tol = 4 // absorbs transient runtime/transport goroutines; << M so a real leak fails
	)

	runtime.GC()
	baseG := runtime.NumGoroutine()

	var wg sync.WaitGroup
	cancels := make([]context.CancelFunc, 0, M)
	for i := 0; i < M; i++ {
		ctx, cancel := context.WithCancel(context.Background())
		req, _ := http.NewRequestWithContext(ctx, http.MethodGet, h.url+"/events", nil)
		resp, err := c.Do(req)
		if err != nil {
			cancel()
			t.Fatalf("open SSE stream %d: %v", i, err)
		}
		if resp.StatusCode != http.StatusOK {
			cancel()
			resp.Body.Close()
			t.Fatalf("SSE stream %d: want 200, got %d", i, resp.StatusCode)
		}
		cancels = append(cancels, cancel)
		wg.Add(1)
		go func(r *http.Response) { // client-side reader, joined before the census
			defer wg.Done()
			buf := make([]byte, 128)
			for {
				if _, e := r.Body.Read(buf); e != nil {
					break
				}
			}
			_ = r.Body.Close()
		}(resp)
	}

	// Push a few real events so the streams are actively forwarding mid-stream (the
	// shared bus channel distributes them among the M forwarders; <=8 fits the buffer).
	for i := 0; i < 4; i++ {
		_ = h.bus.PublishEvent(context.Background(), redis.Event{ProfileID: "chaos-eu", State: vpn.StateDown})
	}
	time.Sleep(50 * time.Millisecond)

	// Cancel at random mid-stream (order-randomised; the no-leak verdict is order-invariant).
	rand.Shuffle(len(cancels), func(i, j int) { cancels[i], cancels[j] = cancels[j], cancels[i] })
	for _, cx := range cancels {
		cx()
		time.Sleep(time.Duration(rand.Intn(4)) * time.Millisecond)
	}
	wg.Wait() // all client readers returned

	settled := settledGoroutines(c, baseG, tol, 6*time.Second)
	if settled-baseG > tol {
		t.Fatalf("SSE forwarder LEAK after churn: baseline=%d settled=%d (delta=%d > tol=%d, M=%d streams)",
			baseG, settled, settled-baseG, tol, M)
	}

	// Server still serves new requests after the disconnect churn.
	code, err := putProfileConc(c, h.url, "chaos-post-sse-churn")
	if err != nil {
		t.Fatalf("post-churn PUT: transport error %v", err)
	}
	if code != http.StatusOK {
		t.Fatalf("server did not recover after SSE churn: post-churn PUT got %d (want 200)", code)
	}

	writeChaosEvidence(t, evd, "recovery_trace.txt",
		fmt.Sprintf("fault=sse-client-disconnect-mid-stream category=stream_teardown\n"+
			"streams_churned=%d\ngoroutines_baseline=%d goroutines_settled=%d delta=%d tol=%d\n"+
			"post_churn_put=HTTP %d (server still serving)\n"+
			"verdict: every forwarder+handler reaped on client cancel (no leak)\n",
			M, baseG, settled, settled-baseG, tol, code))
}

// TestChaos_ContextCancelMidMutation cancels a PUT's request context and asserts a
// clean failure (no panic) with NO partial write. HONEST LIMIT (§11.4.3): with the
// fake WithTx ignoring ctx (harness_test.go:529) only cancel-before-dispatch is
// exercised; the real in-flight BeginTx-abort semantics are guarded behind
// DATABASE_URL and SKIP-with-reason when unset (never a fake PASS).
func TestChaos_ContextCancelMidMutation(t *testing.T) {
	evd := chaosEvidenceDir(t)

	t.Run("fake_cancel_before_dispatch", func(t *testing.T) {
		h := newHarness(t)
		c := h.clientWithCert(t)

		baseProfiles := h.q.profileCount()
		baseAudits := h.q.auditCount()

		ctx, cancel := context.WithCancel(context.Background())
		body, _ := json.Marshal(profileDTO{Name: "chaos-cancel-wg", Type: "wireguard", Enabled: true})
		req, err := http.NewRequestWithContext(ctx, http.MethodPut, h.url+"/api/profiles", newReader(body))
		if err != nil {
			t.Fatalf("build request: %v", err)
		}
		req.Header.Set("Content-Type", "application/json")

		cancel() // cancel before dispatch — the only cancel semantics the fake honours
		resp, err := c.Do(req)

		// Clean outcome: either a transport-level context error, or a non-2xx status.
		// A 2xx here would mean a cancelled mutation "succeeded" — a real defect.
		outcome := ""
		if err != nil {
			outcome = "transport error: " + err.Error()
		} else {
			outcome = fmt.Sprintf("HTTP %d", resp.StatusCode)
			if resp.StatusCode >= 200 && resp.StatusCode < 300 {
				resp.Body.Close()
				t.Fatalf("cancelled mutation returned 2xx (%d) — a cancelled PUT must not succeed", resp.StatusCode)
			}
			_, _ = io.Copy(io.Discard, resp.Body)
			resp.Body.Close()
		}

		// No partial write regardless of outcome (reaching here proves no panic/crash).
		if got := h.q.profileCount(); got != baseProfiles {
			t.Fatalf("cancelled mutation left a partial write: want %d profiles, got %d", baseProfiles, got)
		}
		if got := h.q.auditCount(); got != baseAudits {
			t.Fatalf("cancelled mutation left a partial audit: want %d, got %d", baseAudits, got)
		}

		// Server still serves a normal (uncancelled) PUT.
		code, err := putProfileConc(c, h.url, "chaos-post-cancel")
		if err != nil || code != http.StatusOK {
			t.Fatalf("post-cancel PUT: code=%d err=%v (want 200/nil)", code, err)
		}

		writeChaosEvidence(t, evd, "categorised_errors.txt",
			fmt.Sprintf("fault=context-cancel-mid-mutation category=request_cancel (fake: cancel-before-dispatch)\n"+
				"cancelled_put_outcome: %s\n"+
				"no_panic=true no_partial_write=true (profiles/audits unchanged)\n"+
				"post_cancel_put=HTTP %d (server still serving)\n", outcome, code))
	})

	t.Run("real_pg_cancel_aborts_begintx", func(t *testing.T) {
		// HONEST §11.4.3 SKIP (never a fake PASS), for BOTH cases:
		//   - DATABASE_URL unset: the topology (real Postgres) is absent.
		//   - DATABASE_URL set:   the real store.Postgres harness for the in-flight
		//     BeginTx-abort variant is a TRACKED GAP not wired in this SLICE (SLICE
		//     scope: fake-mode chaos only). Either way we refuse to assert the
		//     in-flight-abort against the fake (which ignores ctx, harness_test.go:529)
		//     — that would be a fake PASS.
		// The real variant WOULD assert: cancel the request context AFTER the mutation
		// SQL runs but BEFORE commit → BeginTx/commit aborts, the row does NOT persist,
		// the handler returns a clean 5xx.
		if os.Getenv("DATABASE_URL") == "" {
			t.Skip("SKIP §11.4.3: in-flight BeginTx-abort-on-cancel needs real Postgres (DATABASE_URL unset); " +
				"the fake WithTx ignores ctx (harness_test.go:529) so only cancel-before-dispatch is exercised above")
		}
		t.Skip("SKIP §11.4.3: DATABASE_URL is set but the real-PG in-flight-abort harness is a tracked gap " +
			"not wired in this SLICE (fake-mode chaos only) — refusing a fake PASS against the ctx-ignoring fake")
	})
}

// newReader is a tiny bytes.Reader shim so this file needs no bytes import churn.
func newReader(b []byte) *chaosReader { return &chaosReader{b: b} }

type chaosReader struct {
	b   []byte
	off int
}

func (r *chaosReader) Read(p []byte) (int, error) {
	if r.off >= len(r.b) {
		return 0, io.EOF
	}
	n := copy(p, r.b[r.off:])
	r.off += n
	return n, nil
}
