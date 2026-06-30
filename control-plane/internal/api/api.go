// Package api is the control-plane REST API + admin UI server (design spec §4
// component 4, §11 ⑥): CRUD over profiles/targets/rules/users, live status via
// SSE, a Prometheus /metrics endpoint, the FindProxyForURL PAC endpoint, and
// mTLS. It replaces the traefik/whoami placeholder. The admin UI uses
// templ+htmx+SSE with OpenDesign tokens (§11.4.162), light+dark, proven by
// host-rendered pixel proof (§11.4.170).
//
// SCAFFOLD (Phase 6): real handlers + the templ/htmx UI land in internal/api
// during plan T6.1/T6.2. This file defines only the server contract + config.
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
