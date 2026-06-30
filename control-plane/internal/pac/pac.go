// Package pac generates the proxy auto-config (PAC) `FindProxyForURL` artifact
// and backs the dynamic PAC endpoint served by the control-API (design spec
// §11 ⑤, §4 component 4) — enabling health/geo routing, hot-reload and
// split-tunnel without touching the byte path.
//
// SCAFFOLD (Phase 6): real generator lands in internal/pac during plan T6.1.
package pac

import "context"

// Entry is one host->proxy mapping rendered into FindProxyForURL.
type Entry struct {
	HostGlob string // e.g. "*.internal.example"
	Proxy    string // a PAC return value, e.g. "PROXY squid:53128" or "DIRECT"
}

// Generator renders a PAC file body from the resolved entry set (spec §11 ⑤).
type Generator interface {
	Generate(ctx context.Context, entries []Entry) ([]byte, error)
}
