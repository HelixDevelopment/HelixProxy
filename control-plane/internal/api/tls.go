// mTLS configuration for the control-API (design spec §12, §11 ⑥). The control
// plane is the trust boundary: every request MUST present a client certificate
// signed by the configured client CA, verified at the TLS handshake — a request
// with NO client cert or an untrusted one is rejected BEFORE any handler runs.
// That is the FAIL-CLOSED property (§11.4 / spec §10): no valid client identity ⇒
// no access, never a fall-through to an unauthenticated handler.
//
// Key material is NEVER embedded: the cert, key, and client-CA are loaded from
// FILE PATHS (the Podman-secret mount points named by CONTROL_API_TLS_CERT /
// CONTROL_API_TLS_KEY / CONTROL_API_TLS_CLIENT_CA), never from the source or the
// database (§11.4.10).
package api

import (
	"crypto/tls"
	"crypto/x509"
	"fmt"
	"os"
)

// buildTLSConfig loads the server cert/key and the client-CA pool from the paths
// in cfg and returns a *tls.Config that REQUIRES AND VERIFIES a client cert. Any
// missing/unreadable path is a hard error (fail-closed: we refuse to start an
// mTLS server we cannot actually authenticate against — never silently downgrade).
func buildTLSConfig(cfg Config) (*tls.Config, error) {
	if cfg.TLSCert == "" || cfg.TLSKey == "" || cfg.ClientCA == "" {
		return nil, fmt.Errorf("api: mTLS requires CONTROL_API_TLS_CERT/CONTROL_API_TLS_KEY/CONTROL_API_TLS_CLIENT_CA paths (got cert=%q key=%q client_ca=%q)",
			cfg.TLSCert, cfg.TLSKey, cfg.ClientCA)
	}

	serverCert, err := tls.LoadX509KeyPair(cfg.TLSCert, cfg.TLSKey)
	if err != nil {
		return nil, fmt.Errorf("api: load server keypair: %w", err)
	}

	caPEM, err := os.ReadFile(cfg.ClientCA)
	if err != nil {
		return nil, fmt.Errorf("api: read client CA: %w", err)
	}
	clientCAs := x509.NewCertPool()
	if !clientCAs.AppendCertsFromPEM(caPEM) {
		return nil, fmt.Errorf("api: client CA %q contained no usable certificates", cfg.ClientCA)
	}

	cfgTLS := &tls.Config{
		Certificates: []tls.Certificate{serverCert},
		ClientCAs:    clientCAs,
		MinVersion:   tls.VersionTLS12,
	}
	// FAIL-CLOSED (§11.4 / spec §10, §1.1-guarded): require AND verify a client
	// cert at the handshake. Flipping this to tls.NoClientCert disables mTLS and
	// makes the no-client-cert request succeed — the paired mutation that proves
	// the fail-closed test is real.
	cfgTLS.ClientAuth = tls.RequireAndVerifyClientCert
	return cfgTLS, nil
}
