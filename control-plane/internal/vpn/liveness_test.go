// Hermetic unit tests for TunnelProxyProber (the D3 fresh-liveness signal). No real
// gluetun and no external network: an httptest.Server ACTS AS the HTTP forward
// proxy — for a proxied plain-HTTP request the transport sends the absolute-URI GET
// to the proxy, so the test server receives it directly and can answer, or fail, or
// vanish (the kill-switch/timeout analogue). Every fail mode MUST surface as an
// error so the caller fails closed. Run under -short.
package vpn

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

// proxyStub returns an httptest server standing in for gluetun's :8888 forward
// proxy: it answers the absolute-URI GET the transport forwards. handler decides
// the response (status/body) so each test drives a distinct outcome.
func proxyStub(t *testing.T, handler http.HandlerFunc) *TunnelProxyProber {
	t.Helper()
	srv := httptest.NewServer(handler)
	t.Cleanup(srv.Close)
	// Target is plain-HTTP so the transport uses absolute-URI proxying (the stub
	// receives the request directly). A real deployment targets an https IP-echo.
	p, err := NewTunnelProxyProber(srv.URL, "http://ip-echo.test/ip", 2*time.Second)
	if err != nil {
		t.Fatalf("NewTunnelProxyProber: %v", err)
	}
	return p
}

// TestTunnelProxyProber_Success — a 2xx with a non-empty body through the proxy is
// the ONLY passing case: fresh through-tunnel liveness confirmed.
func TestTunnelProxyProber_Success(t *testing.T) {
	p := proxyStub(t, func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet || !strings.Contains(r.URL.String(), "ip-echo.test") {
			t.Errorf("proxy did not receive the absolute-URI GET: %s %s", r.Method, r.URL)
		}
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("185.65.135.250\n"))
	})
	if err := p.Probe(context.Background()); err != nil {
		t.Fatalf("Probe on a 2xx+body proxy response must be nil, got %v", err)
	}
}

// TestTunnelProxyProber_Non2xxIsError — a non-2xx status through the proxy is NOT a
// liveness proof (fail-closed). Covers a proxy that returns 502 (upstream blocked).
func TestTunnelProxyProber_Non2xxIsError(t *testing.T) {
	p := proxyStub(t, func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusBadGateway)
		_, _ = w.Write([]byte("blocked"))
	})
	if err := p.Probe(context.Background()); err == nil {
		t.Fatal("non-2xx proxy response must be an error (fail-closed), got nil")
	}
}

// TestTunnelProxyProber_EmptyBodyIsError — a 2xx with an EMPTY body is not proof a
// real response returned; it MUST fail closed (guards a proxy that 200s a stub).
func TestTunnelProxyProber_EmptyBodyIsError(t *testing.T) {
	p := proxyStub(t, func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("   \n")) // whitespace-only ⇒ empty after trim
	})
	if err := p.Probe(context.Background()); err == nil {
		t.Fatal("empty-body proxy response must be an error (fail-closed), got nil")
	}
}

// TestTunnelProxyProber_UnreachableProxyIsError — the kill-switch/tunnel-down
// analogue: the proxy is gone, so Do errors. MUST fail closed.
func TestTunnelProxyProber_UnreachableProxyIsError(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(http.ResponseWriter, *http.Request) {}))
	p, err := NewTunnelProxyProber(srv.URL, "http://ip-echo.test/ip", 1*time.Second)
	if err != nil {
		t.Fatalf("NewTunnelProxyProber: %v", err)
	}
	srv.Close() // proxy vanishes — like a kill-switch-blocked / down tunnel
	if err := p.Probe(context.Background()); err == nil {
		t.Fatal("unreachable proxy (tunnel down) must be an error (fail-closed), got nil")
	}
}

// TestTunnelProxyProber_ContextCancelIsError — a cancelled context aborts the probe
// with an error (no hang, no fabricated success). Bounds the poll (§11.4.6).
func TestTunnelProxyProber_ContextCancelIsError(t *testing.T) {
	p := proxyStub(t, func(w http.ResponseWriter, _ *http.Request) {
		time.Sleep(500 * time.Millisecond) // slow upstream
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("late"))
	})
	ctx, cancel := context.WithCancel(context.Background())
	cancel() // already cancelled
	if err := p.Probe(ctx); err == nil {
		t.Fatal("cancelled context must abort the probe with an error, got nil")
	}
}

// TestNewTunnelProxyProber_Validation covers the constructor guards + defaults.
func TestNewTunnelProxyProber_Validation(t *testing.T) {
	if _, err := NewTunnelProxyProber("://bad url", "", 0); err == nil {
		t.Error("unparseable proxy URL must be an error, got nil")
	}
	if _, err := NewTunnelProxyProber("http://", "", 0); err == nil {
		t.Error("proxy URL with no host must be an error, got nil")
	}
	p, err := NewTunnelProxyProber("http://proxy-gluetun:8888", "", 0)
	if err != nil {
		t.Fatalf("valid proxy URL: %v", err)
	}
	if p.Target != DefaultLivenessTarget {
		t.Errorf("blank target must default to %q, got %q", DefaultLivenessTarget, p.Target)
	}
	if p.HTTP.Timeout != 4*time.Second {
		t.Errorf("non-positive timeout must default to 4s, got %s", p.HTTP.Timeout)
	}
}
