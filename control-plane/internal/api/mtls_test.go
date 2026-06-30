package api

import (
	"net/http"
	"testing"
)

// TestMTLS_FailClosed_NoClientCertRejected is the FAIL-CLOSED property test
// (§11.4 / spec §10/§12) and the §1.1 paired-mutation target. A client that
// presents NO client certificate MUST be rejected at the TLS handshake — the
// request never reaches a handler. Flipping buildTLSConfig's
// `cfg.ClientAuth = tls.RequireAndVerifyClientCert` (tls.go) to tls.NoClientCert
// makes this no-cert request SUCCEED, and this assertion FAILs — proving the test
// genuinely exercises the fail-closed property.
func TestMTLS_FailClosed_NoClientCertRejected(t *testing.T) {
	h := newHarness(t)

	resp, err := h.clientNoCert().Get(h.url + "/api/profiles")
	if err == nil {
		if resp != nil {
			_ = resp.Body.Close()
		}
		t.Fatalf("FAIL-CLOSED VIOLATED: a request with NO client cert was served "+
			"(status %v) — mTLS must reject it at the handshake", resp.Status)
	}
	// A genuine handshake rejection (no usable response).
	t.Logf("no-client-cert correctly rejected at TLS layer: %v", err)
}

// TestMTLS_ValidClientCertAccepted is the positive counterpart: a fully-valid
// mTLS peer (cert signed by the trusted client CA) reaches the handler and gets a
// real 200. Without this, a buildTLSConfig that rejected EVERYONE would also pass
// the fail-closed test — this proves the gate admits the right caller too.
func TestMTLS_ValidClientCertAccepted(t *testing.T) {
	h := newHarness(t)

	resp, err := h.clientWithCert(t).Get(h.url + "/api/profiles")
	if err != nil {
		t.Fatalf("valid client cert rejected: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("valid client cert: want 200, got %d", resp.StatusCode)
	}
}
