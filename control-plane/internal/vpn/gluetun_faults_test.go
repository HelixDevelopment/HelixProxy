// Additional gluetun ControlClient fault-path coverage the happy-path tests miss:
// the httpClient() nil-fallback branch (a client built without NewControlClient),
// EgressIP's error return on a non-200, and getJSON's build-request-error branch
// (an unparseable BaseURL). httptest only — no real network, no mocks of our code.
package vpn

import (
	"context"
	"net/http"
	"net/http/httptest"
	"testing"
)

// TestHTTPClient_NilFallback exercises the httpClient() branch where c.HTTP is nil
// (a ControlClient built by literal, not NewControlClient): getJSON must still work
// via the default 3s client.
func TestHTTPClient_NilFallback(t *testing.T) {
	t.Parallel()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(`{"status":"running"}`))
	}))
	t.Cleanup(srv.Close)
	c := &ControlClient{BaseURL: srv.URL} // HTTP left nil on purpose
	got, err := c.Status(context.Background())
	if err != nil {
		t.Fatalf("Status with nil HTTP: %v", err)
	}
	if got != "running" {
		t.Errorf("Status = %q, want running", got)
	}
}

// TestEgressIP_Non200IsError covers EgressIP's error return (the getJSON non-200
// path routed through EgressIP specifically — the fail-closed egress source).
func TestEgressIP_Non200IsError(t *testing.T) {
	t.Parallel()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusBadGateway)
		_, _ = w.Write([]byte(`{"error":"upstream"}`))
	}))
	t.Cleanup(srv.Close)
	c := NewControlClient(srv.URL)
	if _, err := c.EgressIP(context.Background(), "demo"); err == nil {
		t.Error("EgressIP on non-200 must be an error (fail-closed), got nil")
	}
}

// TestGetJSON_BuildRequestError covers the http.NewRequestWithContext error branch:
// a BaseURL containing a control character makes request construction fail before
// any network I/O.
func TestGetJSON_BuildRequestError(t *testing.T) {
	t.Parallel()
	c := &ControlClient{BaseURL: "http://127.0.0.1\n:8000", HTTP: http.DefaultClient}
	if _, err := c.Status(context.Background()); err == nil {
		t.Error("unparseable BaseURL must fail request construction, got nil error")
	}
}
