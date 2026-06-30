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
type Config struct {
	Addr     string
	TLSCert  string
	TLSKey   string
	ClientCA string
}

// Server is the control-API + admin-UI lifecycle contract.
type Server interface {
	// Start begins serving and blocks until ctx is cancelled or it errors.
	Start(ctx context.Context) error
}
