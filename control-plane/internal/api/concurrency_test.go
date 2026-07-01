package api

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net/http"
	"strconv"
	"sync"
	"sync/atomic"
	"testing"
)

// putProfileConc issues a mutating PUT and returns (status, err) WITHOUT calling
// t.Fatalf — a goroutine-safe request helper (t.Fatalf from a non-test goroutine
// is illegal and would itself be a §11.4.1 script-failure bluff, not a product
// finding). Errors are surfaced to the test goroutine instead.
func putProfileConc(c *http.Client, base, name string) (int, error) {
	b, _ := json.Marshal(profileDTO{Name: name, Type: "wireguard", Enabled: true})
	req, err := http.NewRequest(http.MethodPut, base+"/api/profiles", bytes.NewReader(b))
	if err != nil {
		return 0, err
	}
	req.Header.Set("Content-Type", "application/json")
	resp, err := c.Do(req)
	if err != nil {
		return 0, err
	}
	defer resp.Body.Close()
	_, _ = io.Copy(io.Discard, resp.Body)
	return resp.StatusCode, nil
}

// TestConcurrency_MutationAndAuditConsistent is the P6 review WARNING-4 evidence.
//
// FINDING (investigated, §11.4.6): the control-API handlers do NOT read-then-mutate
// — there is no audit-reads-state→mutation-acts-on-it sequence, hence no TOCTOU.
// Each handler performs (1) one store mutation (UpsertProfile/Delete*, individually
// atomic at the store layer — a single SQL upsert in Postgres, a single
// mutex-guarded map write in the fake) followed by (2) one AppendAudit. Under
// concurrent callers this yields neither a lost update nor partial ENTITY state.
// (The one genuine non-atomicity — a mutation that commits while its subsequent
// AppendAudit fails, leaving an un-audited mutation — is now CLOSED by a store-layer
// transaction: handlers.go `mutateWithAudit` wraps the mutation + AppendAudit in one
// `store.Queries.WithTx` (Postgres BeginTx→Rollback-on-error; the fake snapshots +
// restores on rollback), proven by `TestAtomicity_MutationAndAuditCommitTogether`
// (RED_MODE polarity §11.4.115) + the real-Postgres `TestIntegration_WithTxAtomicAuditAndMutation`.
// It is not a concurrency race.)
//
// This test proves the entity+audit path is race-free + consistent under N parallel
// mutating callers. Run under `-race` for the data-race proof.
func TestConcurrency_MutationAndAuditConsistent(t *testing.T) {
	const n = 50

	// Phase 1 — N concurrent upserts of DISTINCT profiles: no lost update, exactly
	// one audit row per upsert, N distinct rows persisted.
	t.Run("distinct_entities_no_lost_update", func(t *testing.T) {
		h := newHarness(t)
		c := h.clientWithCert(t)
		var wg sync.WaitGroup
		errs := make(chan string, n)
		for i := 0; i < n; i++ {
			wg.Add(1)
			go func(i int) {
				defer wg.Done()
				code, err := putProfileConc(c, h.url, "race-wg-"+strconv.Itoa(i))
				if err != nil {
					errs <- "request error: " + err.Error()
				} else if code != http.StatusOK {
					errs <- "non-200 for race-wg-" + strconv.Itoa(i) + ": " + strconv.Itoa(code)
				}
			}(i)
		}
		wg.Wait()
		close(errs)
		for e := range errs {
			t.Fatalf("concurrent upsert failed: %s", e)
		}
		if got := h.q.auditCount(); got != n {
			t.Fatalf("audit rows: want %d (one per upsert), got %d", n, got)
		}
		ps, err := h.q.ListProfiles(context.Background())
		if err != nil || len(ps) != n {
			t.Fatalf("want %d distinct profiles persisted, got %d (err %v)", n, len(ps), err)
		}
	})

	// Phase 2 — N concurrent upserts of the SAME profile name: idempotent upsert,
	// exactly one row (no duplicate / no partial), one audit row per call.
	t.Run("same_entity_idempotent_upsert", func(t *testing.T) {
		h := newHarness(t)
		c := h.clientWithCert(t)
		var wg sync.WaitGroup
		var okCount int64
		errs := make(chan string, n)
		for i := 0; i < n; i++ {
			wg.Add(1)
			go func() {
				defer wg.Done()
				code, err := putProfileConc(c, h.url, "race-shared")
				switch {
				case err != nil:
					errs <- "request error: " + err.Error()
				case code != http.StatusOK:
					errs <- "non-200: " + strconv.Itoa(code)
				default:
					atomic.AddInt64(&okCount, 1)
				}
			}()
		}
		wg.Wait()
		close(errs)
		for e := range errs {
			t.Fatalf("concurrent shared-name upsert failed: %s", e)
		}
		if okCount != n {
			t.Fatalf("want all %d concurrent upserts to succeed, got %d", n, okCount)
		}
		ps, err := h.q.ListProfiles(context.Background())
		if err != nil || len(ps) != 1 {
			t.Fatalf("same-name upsert must yield exactly 1 row (no partial/dup), got %d (err %v)", len(ps), err)
		}
		if got := h.q.auditCount(); got != n {
			t.Fatalf("audit rows: want %d (one per upsert call), got %d", n, got)
		}
	})
}
