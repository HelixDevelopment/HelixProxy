// Tests for the OPTIONAL separate plaintext /metrics listener (workable item #53).
//
// Prometheus scrape targets typically do NOT do mTLS, so operators want the
// Prometheus /metrics endpoint scrapable over plain HTTP on a SEPARATE address,
// WITHOUT weakening the fail-closed mTLS control port. The listener is controlled
// by CONTROL_API_METRICS_ADDR -> api.Config.MetricsAddr:
//
//   - UNSET/empty  => feature OFF, ZERO behaviour change (the mTLS server is the
//     only listener, exactly as before — §11.4.122 no silent behaviour change).
//   - set (e.g. 127.0.0.1:9090) => a plain net/http server binds it and serves
//     ONLY /metrics (Prometheus text), NEVER the mutating CRUD/SSE/PAC control
//     surface. The mTLS control port keeps requiring client certs, unchanged.
//
// These tests bind REAL loopback sockets on an EPHEMERAL port (":0" — never a
// hardcoded 9090, never the compose) and drive REAL HTTP round-trips (Go client +
// the external `curl` binary) so the PASS carries real captured evidence
// (§11.4.69), never a metadata-only assertion.
//
// §1.1 paired mutation: making metricsRoutes serve the full control mux (s.mux)
// instead of a metrics-only mux makes TestMetricsListener_PlaintextServesOnlyMetrics
// FAIL (the mutating paths would be served on the plaintext port) — proving the
// "serves ONLY /metrics" assertion is real.
package api

import (
	"context"
	"crypto/x509"
	"io"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"digital.vasic.helixproxy/controlplane/internal/pac"
)

// newMetricsListenerServer builds a *server with the given MetricsAddr, backed by
// the in-memory unit-test fakes (§11.4.27). No mTLS certs are needed: the plaintext
// metrics listener is independent of the mTLS control port.
func newMetricsListenerServer(t *testing.T, metricsAddr string) *server {
	t.Helper()
	cfg := Config{Addr: "127.0.0.1:0", MetricsAddr: metricsAddr}
	return NewServer(cfg, newFakeQueries(), newFakeBus(), pac.NewGenerator()).(*server)
}

// writeEvidence writes captured runtime evidence to $HELIX_ISSUE53_EVIDENCE_DIR
// when set (so a supervising run persists the artifact under qa-results/issue53/).
// When unset it is a no-op — the Go assertions are the source of truth either way.
func writeEvidence(t *testing.T, name, content string) {
	t.Helper()
	dir := os.Getenv("HELIX_ISSUE53_EVIDENCE_DIR")
	if dir == "" {
		return
	}
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Logf("evidence dir: %v", err)
		return
	}
	if err := os.WriteFile(filepath.Join(dir, name), []byte(content), 0o644); err != nil {
		t.Logf("write evidence %s: %v", name, err)
	}
}

// TestMetricsListener_OffByDefault proves that with MetricsAddr empty NO extra
// listener is created — the mTLS server stays the only listener (zero behaviour
// change, §11.4.122). This is the off-by-default guarantee.
func TestMetricsListener_OffByDefault(t *testing.T) {
	s := newMetricsListenerServer(t, "")
	hs, addr, err := s.startMetricsListener()
	if err != nil {
		t.Fatalf("startMetricsListener(empty): unexpected error %v", err)
	}
	if hs != nil {
		_ = hs.Close()
		t.Fatal("MetricsAddr empty must yield NO plaintext listener (off-by-default), got a server")
	}
	if addr != "" {
		t.Fatalf("MetricsAddr empty must yield NO bound addr, got %q", addr)
	}
	if got := s.boundMetricsAddr(); got != "" {
		t.Fatalf("boundMetricsAddr with feature off must be empty, got %q", got)
	}
}

// TestMetricsListener_PlaintextServesOnlyMetrics is the core behaviour + §1.1
// mutation target: with MetricsAddr set, the plaintext port serves /metrics (200,
// real Prometheus text with a real metric name) but NOT the mutating control
// surface (404). Uses a real ephemeral socket + real curl.
func TestMetricsListener_PlaintextServesOnlyMetrics(t *testing.T) {
	s := newMetricsListenerServer(t, "127.0.0.1:0")
	hs, addr, err := s.startMetricsListener()
	if err != nil {
		t.Fatalf("startMetricsListener: %v", err)
	}
	if hs == nil || addr == "" {
		t.Fatal("MetricsAddr set must start a plaintext listener")
	}
	t.Cleanup(func() {
		ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
		defer cancel()
		_ = hs.Shutdown(ctx)
	})

	base := "http://" + addr
	c := &http.Client{Timeout: 5 * time.Second}

	// /metrics over PLAIN http returns 200 with real Prometheus exposition text.
	resp, err := c.Get(base + "/metrics")
	if err != nil {
		t.Fatalf("GET plaintext /metrics: %v", err)
	}
	body, _ := io.ReadAll(resp.Body)
	_ = resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("plaintext /metrics: want 200, got %d", resp.StatusCode)
	}
	// A real metric NAME the app registers must appear in the body.
	if !strings.Contains(string(body), MetricACLDecisionsTotal) {
		t.Fatalf("plaintext /metrics body missing real metric %q\n---\n%s", MetricACLDecisionsTotal, body)
	}

	// The mutating control surface MUST NOT be reachable on the plaintext port —
	// only /metrics is served there. Everything else is 404.
	for _, path := range []string{"/api/profiles", "/api/rules", "/api/users", "/events", "/proxy.pac"} {
		r2, err := c.Get(base + path)
		if err != nil {
			t.Fatalf("GET plaintext %s: %v", path, err)
		}
		code := r2.StatusCode
		_ = r2.Body.Close()
		if code != http.StatusNotFound {
			t.Fatalf("SECURITY: plaintext metrics port served %s (status %d) — it MUST serve ONLY /metrics", path, code)
		}
	}

	// Real external `curl` evidence (§11.4.69): capture the actual wire response of
	// the plaintext /metrics scrape AND a mutating path (proving the 404).
	if curl, lookErr := exec.LookPath("curl"); lookErr == nil {
		out, _ := exec.Command(curl, "-s", "-i", base+"/metrics").CombinedOutput()
		writeEvidence(t, "curl_metrics.txt", "$ curl -s -i "+base+"/metrics\n"+string(out))
		if !strings.Contains(string(out), "200") || !strings.Contains(string(out), MetricACLDecisionsTotal) {
			t.Fatalf("curl /metrics evidence missing 200 or metric name:\n%s", out)
		}
		out2, _ := exec.Command(curl, "-s", "-o", "/dev/null", "-w", "%{http_code}", base+"/api/profiles").CombinedOutput()
		writeEvidence(t, "curl_mutating_path_blocked.txt",
			"$ curl -s -o /dev/null -w '%{http_code}' "+base+"/api/profiles\nHTTP status: "+string(out2)+
				"\n(404 => mutating control surface is NOT exposed on the plaintext metrics port)\n")
		if strings.TrimSpace(string(out2)) != "404" {
			t.Fatalf("curl /api/profiles on plaintext port: want 404, got %q", out2)
		}
	}
}

// TestMetricsListener_GracefulShutdown proves the extra listener drains cleanly and
// leaves no goroutine serving (§11.4 no-leak): after Shutdown the port is closed and
// a subsequent scrape fails.
func TestMetricsListener_GracefulShutdown(t *testing.T) {
	s := newMetricsListenerServer(t, "127.0.0.1:0")
	hs, addr, err := s.startMetricsListener()
	if err != nil {
		t.Fatalf("startMetricsListener: %v", err)
	}
	c := &http.Client{Timeout: 3 * time.Second}
	if resp, err := c.Get("http://" + addr + "/metrics"); err != nil {
		t.Fatalf("pre-shutdown scrape: %v", err)
	} else {
		_ = resp.Body.Close()
	}
	shutCtx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	if err := hs.Shutdown(shutCtx); err != nil {
		t.Fatalf("graceful shutdown: %v", err)
	}
	if resp, err := c.Get("http://" + addr + "/metrics"); err == nil {
		_ = resp.Body.Close()
		t.Fatal("plaintext metrics listener still serving AFTER Shutdown — goroutine/socket leak")
	}
}

// TestMetricsListener_StartIntegration_GracefulOnCtxCancel drives the FULL Start()
// path (production buildTLSConfig + mTLS listener + the plaintext metrics listener)
// and proves the extra listener rides the SAME signal path: cancelling ctx drains
// BOTH servers and Start returns without leaking. Uses throwaway in-process certs
// (harness_test.go helpers) — never committed key material (§11.4.10).
func TestMetricsListener_StartIntegration_GracefulOnCtxCancel(t *testing.T) {
	ca, caKey, caPEM := mustGenCA(t)
	srvCert := mustGenLeaf(t, ca, caKey, "helix-control-plane",
		[]x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		[]net.IP{net.ParseIP("127.0.0.1"), net.ParseIP("::1")}, []string{"localhost"})
	dir := t.TempDir()
	cfg := Config{
		Addr:        "127.0.0.1:0",
		MetricsAddr: "127.0.0.1:0",
		TLSCert:     writeFile(t, dir, "server.crt", srvCert.certPEM),
		TLSKey:      writeFile(t, dir, "server.key", srvCert.keyPEM),
		ClientCA:    writeFile(t, dir, "ca.crt", caPEM.certPEM),
	}
	s := NewServer(cfg, newFakeQueries(), newFakeBus(), pac.NewGenerator()).(*server)

	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- s.Start(ctx) }()

	// Wait until the plaintext metrics listener has bound (Start started it).
	var addr string
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		if addr = s.boundMetricsAddr(); addr != "" {
			break
		}
		time.Sleep(10 * time.Millisecond)
	}
	if addr == "" {
		cancel()
		<-done
		t.Fatal("Start did not bind the plaintext metrics listener within 3s")
	}

	// Scrape plaintext /metrics through the REAL Start()-wired listener.
	c := &http.Client{Timeout: 3 * time.Second}
	resp, err := c.Get("http://" + addr + "/metrics")
	if err != nil {
		cancel()
		<-done
		t.Fatalf("scrape Start-wired plaintext /metrics: %v", err)
	}
	body, _ := io.ReadAll(resp.Body)
	_ = resp.Body.Close()
	if resp.StatusCode != http.StatusOK || !strings.Contains(string(body), MetricTunnelDownResponses) {
		t.Fatalf("Start-wired /metrics: status=%d, expected metric present; body:\n%s", resp.StatusCode, body)
	}
	writeEvidence(t, "start_integration_metrics.txt",
		"# Full Start() path, plaintext metrics listener at "+addr+"\nHTTP "+resp.Status+"\n"+
			firstLines(string(body), 25))

	// Cancel ctx: BOTH the mTLS server and the plaintext metrics listener drain.
	cancel()
	select {
	case err := <-done:
		if err != nil {
			t.Fatalf("Start returned error on graceful shutdown: %v", err)
		}
	case <-time.After(8 * time.Second):
		t.Fatal("Start did not return within 8s after ctx cancel — shutdown path leaked")
	}
	// The plaintext port is closed after Start returned.
	if resp, err := c.Get("http://" + addr + "/metrics"); err == nil {
		_ = resp.Body.Close()
		t.Fatal("plaintext metrics listener still serving after Start returned")
	}
}

// firstLines returns at most n lines of s (keeps evidence artifacts small).
func firstLines(s string, n int) string {
	lines := strings.SplitN(s, "\n", n+1)
	if len(lines) > n {
		lines = lines[:n]
	}
	return strings.Join(lines, "\n")
}
