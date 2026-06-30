// Unit tests for the gluetun control-API client. Uses httptest (no real network,
// no mocks of our own code — the server speaks the REAL JSON gluetun returns,
// captured from spike G4). Covers running / stopped / empty-public_ip and the
// fail-closed paths (non-200, undecodable body).
package vpn

import (
	"context"
	"net/http"
	"net/http/httptest"
	"testing"
)

func newGluetunStub(t *testing.T, status, publicIP string, code int) *ControlClient {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if code != 0 && code != http.StatusOK {
			w.WriteHeader(code)
			_, _ = w.Write([]byte(`{"error":"forced"}`))
			return
		}
		switch r.URL.Path {
		case "/v1/vpn/status":
			_, _ = w.Write([]byte(`{"status":"` + status + `"}`))
		case "/v1/publicip/ip":
			_, _ = w.Write([]byte(`{"public_ip":"` + publicIP + `"}`))
		default:
			http.NotFound(w, r)
		}
	}))
	t.Cleanup(srv.Close)
	return NewControlClient(srv.URL)
}

func TestControlClient_Status(t *testing.T) {
	cases := []struct{ name, want string }{
		{"running", "running"},
		{"stopped", "stopped"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			c := newGluetunStub(t, tc.want, "203.0.113.9", 200)
			got, err := c.Status(context.Background())
			if err != nil {
				t.Fatalf("Status: %v", err)
			}
			if got != tc.want {
				t.Errorf("Status = %q, want %q", got, tc.want)
			}
		})
	}
}

func TestControlClient_EgressIP(t *testing.T) {
	t.Run("real egress", func(t *testing.T) {
		c := newGluetunStub(t, "running", "203.0.113.9", 200)
		ip, err := c.EgressIP(context.Background(), "demo")
		if err != nil {
			t.Fatalf("EgressIP: %v", err)
		}
		if ip != "203.0.113.9" {
			t.Errorf("EgressIP = %q, want 203.0.113.9", ip)
		}
	})

	// The decisive anti-bluff case (G4): status running BUT empty public_ip.
	// The client returns "" so DecideHealth fails closed (DOWN).
	t.Run("running but empty public_ip → empty string (fail-closed source)", func(t *testing.T) {
		c := newGluetunStub(t, "running", "", 200)
		ip, err := c.EgressIP(context.Background(), "demo")
		if err != nil {
			t.Fatalf("EgressIP: %v", err)
		}
		if ip != "" {
			t.Errorf("EgressIP = %q, want empty", ip)
		}
	})
}

func TestControlClient_Non200IsError(t *testing.T) {
	c := newGluetunStub(t, "", "", http.StatusServiceUnavailable)
	if _, err := c.Status(context.Background()); err == nil {
		t.Error("non-200 must be an error (fail-closed), got nil")
	}
}

func TestControlClient_UndecodableBodyIsError(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(`not-json`))
	}))
	t.Cleanup(srv.Close)
	c := NewControlClient(srv.URL)
	if _, err := c.Status(context.Background()); err == nil {
		t.Error("undecodable body must be an error, got nil")
	}
}
