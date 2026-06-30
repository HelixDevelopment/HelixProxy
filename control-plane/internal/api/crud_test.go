package api

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"testing"
)

// doJSON issues a mTLS request with an optional JSON body and returns status+body.
func doJSON(t *testing.T, c *http.Client, method, url string, body any) (int, []byte) {
	t.Helper()
	var rdr io.Reader
	if body != nil {
		b, err := json.Marshal(body)
		if err != nil {
			t.Fatalf("marshal body: %v", err)
		}
		rdr = bytes.NewReader(b)
	}
	req, err := http.NewRequest(method, url, rdr)
	if err != nil {
		t.Fatalf("new request: %v", err)
	}
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	resp, err := c.Do(req)
	if err != nil {
		t.Fatalf("%s %s: %v", method, url, err)
	}
	defer resp.Body.Close()
	out, _ := io.ReadAll(resp.Body)
	return resp.StatusCode, out
}

// TestCRUD_Profiles_RoundTrip drives a full profile lifecycle over REAL mTLS HTTP
// with REAL JSON round-trips, and asserts every mutation wrote an audit row.
func TestCRUD_Profiles_RoundTrip(t *testing.T) {
	h := newHarness(t)
	c := h.clientWithCert(t)

	// PUT (create) — upsert returns an id; audit row #1.
	code, body := doJSON(t, c, http.MethodPut, h.url+"/api/profiles", profileDTO{
		Name: "eu-wg", Type: "wireguard", Config: json.RawMessage(`{"endpoint":"eu1:51820"}`),
		SecretRef: "wg-eu", Enabled: true,
	})
	if code != http.StatusOK {
		t.Fatalf("PUT profile: want 200, got %d (%s)", code, body)
	}
	var created struct{ ID string }
	if err := json.Unmarshal(body, &created); err != nil || created.ID == "" {
		t.Fatalf("PUT profile: bad id payload %s (err %v)", body, err)
	}

	// GET one — round-trip fields survive (config exposed as raw JSON, not base64).
	code, body = doJSON(t, c, http.MethodGet, h.url+"/api/profiles/"+created.ID, nil)
	if code != http.StatusOK {
		t.Fatalf("GET profile: want 200, got %d (%s)", code, body)
	}
	var got profileDTO
	if err := json.Unmarshal(body, &got); err != nil {
		t.Fatalf("GET profile decode: %v", err)
	}
	if got.Name != "eu-wg" || got.Type != "wireguard" || got.SecretRef != "wg-eu" || !got.Enabled {
		t.Fatalf("profile round-trip mismatch: %+v", got)
	}
	if string(got.Config) == "" || !json.Valid(got.Config) {
		t.Fatalf("config not round-tripped as JSON: %q", got.Config)
	}

	// GET list — exactly one.
	code, body = doJSON(t, c, http.MethodGet, h.url+"/api/profiles", nil)
	var list []profileDTO
	if code != http.StatusOK || json.Unmarshal(body, &list) != nil || len(list) != 1 {
		t.Fatalf("GET list: code=%d body=%s", code, body)
	}

	// DELETE — 204; audit row.
	code, _ = doJSON(t, c, http.MethodDelete, h.url+"/api/profiles/"+created.ID, nil)
	if code != http.StatusNoContent {
		t.Fatalf("DELETE profile: want 204, got %d", code)
	}
	code, _ = doJSON(t, c, http.MethodGet, h.url+"/api/profiles/"+created.ID, nil)
	if code != http.StatusNotFound {
		t.Fatalf("GET after delete: want 404, got %d", code)
	}

	// Every mutation (create + delete) recorded an audit row with the cert CN actor.
	if n := h.q.auditCount(); n != 2 {
		t.Fatalf("audit rows: want 2 (upsert+delete), got %d", n)
	}
	if got := h.q.audits[0].Actor; got != "admin@helix" {
		t.Fatalf("audit actor: want cert CN admin@helix, got %q", got)
	}
}

// TestCRUD_Validation rejects malformed input with 400 BEFORE any store write
// (no partial writes), and never records an audit row for a rejected request.
func TestCRUD_Validation(t *testing.T) {
	h := newHarness(t)
	c := h.clientWithCert(t)

	// missing name
	if code, _ := doJSON(t, c, http.MethodPut, h.url+"/api/profiles", profileDTO{Type: "wireguard"}); code != http.StatusBadRequest {
		t.Fatalf("empty name: want 400, got %d", code)
	}
	// bad type
	if code, _ := doJSON(t, c, http.MethodPut, h.url+"/api/profiles", profileDTO{Name: "x", Type: "bogus"}); code != http.StatusBadRequest {
		t.Fatalf("bad type: want 400, got %d", code)
	}
	// target missing private_ip
	if code, _ := doJSON(t, c, http.MethodPut, h.url+"/api/targets", targetDTO{PublicAlias: "a"}); code != http.StatusBadRequest {
		t.Fatalf("target no ip: want 400, got %d", code)
	}
	// rule with neither match
	if code, _ := doJSON(t, c, http.MethodPut, h.url+"/api/rules", ruleDTO{Priority: 1}); code != http.StatusBadRequest {
		t.Fatalf("rule no match: want 400, got %d", code)
	}
	if n := h.q.auditCount(); n != 0 {
		t.Fatalf("rejected requests must not audit: got %d rows", n)
	}
}

// TestCRUD_TargetsRulesTiersUsers exercises the remaining entities end-to-end so
// every CRUD route is covered by a real request (not just profiles).
func TestCRUD_TargetsRulesTiersUsers(t *testing.T) {
	h := newHarness(t)
	c := h.clientWithCert(t)

	// target
	code, body := doJSON(t, c, http.MethodPut, h.url+"/api/targets", targetDTO{
		PublicAlias: "api.internal", PrivateIP: "10.8.0.5", Port: 8443, Protocol: "https", Enabled: true,
	})
	if code != http.StatusOK {
		t.Fatalf("PUT target: %d %s", code, body)
	}
	var tgt struct{ ID string }
	_ = json.Unmarshal(body, &tgt)
	code, body = doJSON(t, c, http.MethodGet, h.url+"/api/targets/api.internal", nil)
	var gotT targetDTO
	if code != http.StatusOK || json.Unmarshal(body, &gotT) != nil || gotT.Port != 8443 {
		t.Fatalf("GET target by alias: %d %s", code, body)
	}

	// rule
	code, body = doJSON(t, c, http.MethodPut, h.url+"/api/rules", ruleDTO{
		Priority: 100, MatchHost: "api.internal", TargetHostID: tgt.ID, Enabled: true,
	})
	if code != http.StatusOK {
		t.Fatalf("PUT rule: %d %s", code, body)
	}
	code, body = doJSON(t, c, http.MethodGet, h.url+"/api/rules/api.internal", nil)
	var gotR ruleDTO
	if code != http.StatusOK || json.Unmarshal(body, &gotR) != nil || gotR.Priority != 100 {
		t.Fatalf("GET rule by host: %d %s", code, body)
	}

	// tier
	code, _ = doJSON(t, c, http.MethodPut, h.url+"/api/tiers", tierDTO{TargetID: tgt.ID, VPNProfileID: "prof-1", Tier: 0})
	if code != http.StatusOK {
		t.Fatalf("PUT tier: %d", code)
	}
	code, body = doJSON(t, c, http.MethodGet, h.url+"/api/tiers/"+tgt.ID, nil)
	var tiers []tierDTO
	if code != http.StatusOK || json.Unmarshal(body, &tiers) != nil || len(tiers) != 1 {
		t.Fatalf("GET tiers: %d %s", code, body)
	}
	code, _ = doJSON(t, c, http.MethodDelete, h.url+"/api/tiers/"+tgt.ID+"/0", nil)
	if code != http.StatusNoContent {
		t.Fatalf("DELETE tier: %d", code)
	}

	// user
	code, body = doJSON(t, c, http.MethodPut, h.url+"/api/users", userDTO{Username: "alice", Role: "admin", SecretRef: "htpw", Enabled: true})
	if code != http.StatusOK {
		t.Fatalf("PUT user: %d %s", code, body)
	}
	code, body = doJSON(t, c, http.MethodGet, h.url+"/api/users", nil)
	var users []userDTO
	if code != http.StatusOK || json.Unmarshal(body, &users) != nil || len(users) != 1 || users[0].Username != "alice" {
		t.Fatalf("GET users: %d %s", code, body)
	}
}
