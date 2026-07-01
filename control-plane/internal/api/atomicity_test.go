package api

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"os"
	"testing"
)

// redMode reports the §11.4.115 polarity switch for the WARNING-4 atomicity guard:
//
//	RED_MODE=1        → reproduce-the-defect mode: assert the un-audited mutation
//	                    PERSISTS (the pre-fix two-separate-store-calls behaviour —
//	                    the historical RED reproduction on the broken artifact).
//	RED_MODE=0/unset  → GREEN-guard mode: assert the mutation was ROLLED BACK, i.e.
//	                    an un-audited mutation is impossible (the standing regression
//	                    guard that runs in CI).
func redMode() bool { return os.Getenv("RED_MODE") == "1" }

// deleteProfileReq issues DELETE /api/profiles/{id} and returns its status code.
func deleteProfileReq(t *testing.T, c *http.Client, base, id string) int {
	t.Helper()
	req, err := http.NewRequest(http.MethodDelete, base+"/api/profiles/"+id, nil)
	if err != nil {
		t.Fatalf("build delete request: %v", err)
	}
	resp, err := c.Do(req)
	if err != nil {
		t.Fatalf("delete request: %v", err)
	}
	defer resp.Body.Close()
	_, _ = io.Copy(io.Discard, resp.Body)
	return resp.StatusCode
}

// putTargetReq issues a mutating PUT /api/targets and returns its status code.
func putTargetReq(t *testing.T, c *http.Client, base, alias string) int {
	t.Helper()
	b, _ := json.Marshal(targetDTO{PublicAlias: alias, PrivateIP: "10.9.0.7", Port: 443, Protocol: "https", Enabled: true})
	req, err := http.NewRequest(http.MethodPut, base+"/api/targets", bytes.NewReader(b))
	if err != nil {
		t.Fatalf("build put-target request: %v", err)
	}
	req.Header.Set("Content-Type", "application/json")
	resp, err := c.Do(req)
	if err != nil {
		t.Fatalf("put-target request: %v", err)
	}
	defer resp.Body.Close()
	_, _ = io.Copy(io.Discard, resp.Body)
	return resp.StatusCode
}

// TestAtomicity_MutationAndAuditCommitTogether is the §11.4.115 reproduce-first +
// polarity-switch guard for WARNING-4 (commit 8d95f8a): a control-API mutation and
// its audit row MUST commit-or-rollback TOGETHER. The fake's AppendAudit is forced
// to fail; the handler returns 500 in BOTH the broken and fixed builds — the
// difference is whether the ENTITY mutation survives:
//
//   - pre-fix (two separate store calls): Upsert*/Delete* already committed, so the
//     entity change PERSISTS though it has NO audit row → an un-audited mutation
//     (the durable-data defect; the handler's 500 hides it).
//   - post-fix (mutation+audit in one store.WithTx): the failed audit rolls the
//     whole transaction back → entity unchanged, NO audit row → atomic.
//
// Captured RED (pre-fix, RED_MODE=1) proves the defect is real on the broken
// artifact; the standing guard (RED_MODE=0) proves it cannot recur.
func TestAtomicity_MutationAndAuditCommitTogether(t *testing.T) {
	injected := errors.New("injected: audit store unavailable")

	// upsert path: a brand-new profile must not survive an audit failure.
	t.Run("upsert_profile", func(t *testing.T) {
		h := newHarness(t)
		c := h.clientWithCert(t)
		h.q.setAuditErr(injected)

		code, err := putProfileConc(c, h.url, "atomicity-wg")
		if err != nil {
			t.Fatalf("request error: %v", err)
		}
		if code != http.StatusInternalServerError {
			t.Fatalf("an audit-write failure must surface as HTTP 500, got %d", code)
		}
		if got := h.q.auditCount(); got != 0 {
			t.Fatalf("no audit row may exist after an injected audit failure: want 0, got %d", got)
		}
		got := h.q.profileCount()
		if redMode() {
			if got != 1 {
				t.Fatalf("RED reproduction expected the un-audited mutation to PERSIST (defect), got %d profiles", got)
			}
		} else if got != 0 {
			t.Fatalf("un-audited mutation PERSISTED: want 0 profiles (rolled back with its failed audit), got %d", got)
		}
	})

	// delete path: a delete must not survive an audit failure (the deletion itself
	// is the un-audited mutation if it persists).
	t.Run("delete_profile", func(t *testing.T) {
		h := newHarness(t)
		c := h.clientWithCert(t)

		if code, err := putProfileConc(c, h.url, "to-delete"); err != nil || code != http.StatusOK {
			t.Fatalf("seed upsert failed: code=%d err=%v", code, err)
		}
		id := h.q.firstProfileID()
		if id == "" {
			t.Fatal("seed produced no profile id")
		}
		if got := h.q.auditCount(); got != 1 {
			t.Fatalf("seed must have written exactly 1 audit row, got %d", got)
		}

		h.q.setAuditErr(injected)
		code := deleteProfileReq(t, c, h.url, id)
		if code != http.StatusInternalServerError {
			t.Fatalf("an audit-write failure on delete must surface as HTTP 500, got %d", code)
		}
		// The seed's audit row remains; the delete's audit must never have landed.
		if got := h.q.auditCount(); got != 1 {
			t.Fatalf("delete audit must not land on injected failure: want 1 (seed only), got %d", got)
		}
		got := h.q.profileCount()
		if redMode() {
			if got != 0 {
				t.Fatalf("RED reproduction expected the un-audited DELETE to PERSIST (defect), got %d profiles", got)
			}
		} else if got != 1 {
			t.Fatalf("un-audited delete PERSISTED: want the row restored (1 profile, rolled back), got %d", got)
		}
	})

	// a second entity type proves the seam is applied uniformly, not just to profiles.
	t.Run("upsert_target", func(t *testing.T) {
		h := newHarness(t)
		c := h.clientWithCert(t)
		h.q.setAuditErr(injected)

		code := putTargetReq(t, c, h.url, "atomicity.internal")
		if code != http.StatusInternalServerError {
			t.Fatalf("target audit-write failure must surface as HTTP 500, got %d", code)
		}
		if got := h.q.auditCount(); got != 0 {
			t.Fatalf("no target audit row may exist after an injected audit failure: want 0, got %d", got)
		}
		ts, err := h.q.ListTargets(context.Background())
		if err != nil {
			t.Fatalf("list targets: %v", err)
		}
		if redMode() {
			if len(ts) != 1 {
				t.Fatalf("RED reproduction expected the un-audited target to PERSIST (defect), got %d targets", len(ts))
			}
		} else if len(ts) != 0 {
			t.Fatalf("un-audited target PERSISTED: want 0 targets (rolled back), got %d", len(ts))
		}
	})
}
