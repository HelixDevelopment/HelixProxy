// Package api is the control-plane REST API server (design spec §4 component 4,
// §11 ③⑤⑥): CRUD over profiles/targets/rules/tiers/users, live status via SSE, a
// Prometheus /metrics endpoint, the FindProxyForURL PAC endpoint, and mTLS. It
// replaces the traefik/whoami placeholder.
//
// This file defines the server CONTRACT + config; the concrete implementation
// lives in server.go (lifecycle + routing), handlers.go (REST/SSE/PAC), metrics.go
// (Prometheus), and tls.go (fail-closed mTLS). The templ/htmx admin UI
// (OpenDesign §11.4.162, host-rendered pixel proof §11.4.170) is a SEPARATE later
// stream and is NOT part of this control-API server.
package api

import "context"

// Config holds the server's bind address + TLS settings. ClientCA enables the
// mTLS client-cert verification required on the control-API (spec §12).
//
// MetricsAddr is the OPTIONAL separate plaintext listen address for the Prometheus
// /metrics endpoint (CONTROL_API_METRICS_ADDR, e.g. "127.0.0.1:9090"). EMPTY is the
// default and means the feature is OFF: the mTLS server is the only listener, with
// ZERO behaviour change (§11.4.122). When set, a plain net/http server binds it and
// serves ONLY /metrics — the mutating control surface stays on the fail-closed mTLS
// port, unchanged. Its bind address is security-load-bearing: prefer a pod-internal
// / loopback interface — a 0.0.0.0 bind exposes unauthenticated metrics to whatever
// network can reach it (acceptable ONLY when that network is the trust boundary).
type Config struct {
	Addr        string
	TLSCert     string
	TLSKey      string
	ClientCA    string
	MetricsAddr string
}

// Server is the control-API + admin-UI lifecycle contract.
type Server interface {
	// Start begins serving and blocks until ctx is cancelled or it errors.
	Start(ctx context.Context) error
}
