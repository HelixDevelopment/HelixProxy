// Unit tests for the control-API error / list / delete / validation branches that
// the happy-path CRUD round-trips do not reach: the store-error 500 paths
// (List* returning an injected error), the list + delete handlers for targets and
// rules (0% before), the ErrNotFound 404 fail-closed branches, and the tier/user
// input-validation 400s. Driven over the REAL mTLS httptest server + fakeQueries
// (fakes permitted in unit tests only, §11.4.27). listErr is set under f.mu so the
// toggle is -race clean against the handler goroutines that read it.
package api

import (
	"encoding/json"
	"errors"
	"net/http"
	"testing"
)

// setListErr arms (nil to disarm) the fake's List* failure injection under the
// lock the List methods read it beneath, so it is -race clean.
func setListErr(f *fakeQueries, err error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.listErr = err
}

// TestList_StoreErrorReturns500 proves every list endpoint fails LOUD (500) when the
// store errors — never a silent empty-200 (a §11.4.1 FAIL-bluff would hide the fault).
func TestList_StoreErrorReturns500(t *testing.T) {
	h := newHarness(t)
	c := h.clientWithCert(t)
	setListErr(h.q, errors.New("db down"))

	for _, path := range []string{"/api/profiles", "/api/targets", "/api/rules", "/api/users"} {
		if code, _ := doJSON(t, c, http.MethodGet, h.url+path, nil); code != http.StatusInternalServerError {
			t.Fatalf("GET %s with store error: want 500, got %d", path, code)
		}
	}
}

// TestListTargetsRules_EmptyOK covers the previously-0% listTargets/listRules happy
// path: an empty store returns 200 with a JSON array (never null).
func TestListTargetsRules_EmptyOK(t *testing.T) {
	h := newHarness(t)
	c := h.clientWithCert(t)

	for _, path := range []string{"/api/targets", "/api/rules"} {
		code, body := doJSON(t, c, http.MethodGet, h.url+path, nil)
		if code != http.StatusOK {
			t.Fatalf("GET %s: want 200, got %d (%s)", path, code, body)
		}
		if string(body) != "[]" && string(body) != "[]\n" {
			t.Fatalf("GET %s: want empty JSON array, got %s", path, body)
		}
	}
}

// TestDeleteTargetAndRule covers the previously-0% deleteTarget/deleteRule handlers
// end-to-end (seed → DELETE → 204 → gone), and asserts each delete wrote an audit row.
func TestDeleteTargetAndRule(t *testing.T) {
	h := newHarness(t)
	c := h.clientWithCert(t)

	// seed a target, then delete it by id.
	code, body := doJSON(t, c, http.MethodPut, h.url+"/api/targets", targetDTO{
		PublicAlias: "gone.internal", PrivateIP: "10.8.0.9", Port: 443, Protocol: "https", Enabled: true,
	})
	if code != http.StatusOK {
		t.Fatalf("seed target: %d %s", code, body)
	}
	var tgt struct{ ID string }
	if err := json.Unmarshal(body, &tgt); err != nil || tgt.ID == "" {
		t.Fatalf("seed target id: %s (%v)", body, err)
	}
	if code, _ := doJSON(t, c, http.MethodDelete, h.url+"/api/targets/"+tgt.ID, nil); code != http.StatusNoContent {
		t.Fatalf("DELETE target: want 204, got %d", code)
	}
	if _, ok := h.q.byAlias["gone.internal"]; ok {
		t.Fatal("target still present after delete")
	}

	// seed a rule, then delete it by id.
	code, body = doJSON(t, c, http.MethodPut, h.url+"/api/rules", ruleDTO{
		Priority: 5, MatchHost: "gone.internal", Enabled: true,
	})
	if code != http.StatusOK {
		t.Fatalf("seed rule: %d %s", code, body)
	}
	var rl struct{ ID string }
	if err := json.Unmarshal(body, &rl); err != nil || rl.ID == "" {
		t.Fatalf("seed rule id: %s (%v)", body, err)
	}
	if code, _ := doJSON(t, c, http.MethodDelete, h.url+"/api/rules/"+rl.ID, nil); code != http.StatusNoContent {
		t.Fatalf("DELETE rule: want 204, got %d", code)
	}

	// 2 upserts + 2 deletes = 4 audit rows (every mutation audited).
	if n := h.q.auditCount(); n != 4 {
		t.Fatalf("audit rows: want 4, got %d", n)
	}
}

// TestGetNotFound covers the ErrNotFound → 404 fail-closed branch of getTarget and
// getRuleByHost (an unknown alias/host is a 404, not a 500 or a bluffed 200).
func TestGetNotFound(t *testing.T) {
	h := newHarness(t)
	c := h.clientWithCert(t)

	if code, _ := doJSON(t, c, http.MethodGet, h.url+"/api/targets/nope.internal", nil); code != http.StatusNotFound {
		t.Fatalf("GET missing target: want 404, got %d", code)
	}
	if code, _ := doJSON(t, c, http.MethodGet, h.url+"/api/rules/nohost.internal", nil); code != http.StatusNotFound {
		t.Fatalf("GET missing rule: want 404, got %d", code)
	}
}

// TestTierUserValidation covers the input-validation 400 branches of putTier and the
// non-integer tier 400 of deleteTier, and the empty-username 400 of putUser — each
// rejected BEFORE any store write (no audit row for a rejected request).
func TestTierUserValidation(t *testing.T) {
	h := newHarness(t)
	c := h.clientWithCert(t)

	// putTier: missing vpn_profile_id.
	if code, _ := doJSON(t, c, http.MethodPut, h.url+"/api/tiers", tierDTO{TargetID: "t1", Tier: 0}); code != http.StatusBadRequest {
		t.Fatalf("tier missing vpn_profile_id: want 400, got %d", code)
	}
	// putTier: negative tier.
	if code, _ := doJSON(t, c, http.MethodPut, h.url+"/api/tiers", tierDTO{TargetID: "t1", VPNProfileID: "p1", Tier: -1}); code != http.StatusBadRequest {
		t.Fatalf("tier negative: want 400, got %d", code)
	}
	// deleteTier: non-integer tier path segment.
	if code, _ := doJSON(t, c, http.MethodDelete, h.url+"/api/tiers/t1/notanint", nil); code != http.StatusBadRequest {
		t.Fatalf("deleteTier non-int: want 400, got %d", code)
	}
	// putUser: empty username.
	if code, _ := doJSON(t, c, http.MethodPut, h.url+"/api/users", userDTO{Role: "admin"}); code != http.StatusBadRequest {
		t.Fatalf("user empty username: want 400, got %d", code)
	}
	if n := h.q.auditCount(); n != 0 {
		t.Fatalf("rejected requests must not audit: got %d", n)
	}
}
