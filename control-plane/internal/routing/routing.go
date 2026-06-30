// Package routing is the config-compiler (design spec §4 component 2): it reads
// the data model and renders the Squid generated include, the Dante route
// config, and the PAC file. Routing + up/down dynamism is applied via Redis per
// request; only STRUCTURAL changes (a new tunnel/cache_peer) trigger a Squid
// reconfigure / Dante SIGHUP — never up/down (spec §8 / §9).
//
// SCAFFOLD (Phase 4): real renderers land in internal/routing during plan
// T4.1–T4.3. This file defines only the artifact types and the Compiler contract.
package routing

import (
	"context"

	"digital.vasic.helixproxy/controlplane/internal/store"
)

// Artifacts is the rendered output set produced by one compile pass.
type Artifacts struct {
	// SquidInclude is the generated Squid include: per-tunnel `cache_peer`,
	// `cache_peer_access`, `never_direct allow all`, `deny_info 503:ERR_TUNNEL_DOWN`.
	SquidInclude []byte
	// DanteRoutes is the generated `route { ... via <per-tunnel upstream> }` config.
	DanteRoutes []byte
	// PAC is the rendered FindProxyForURL proxy auto-config file.
	PAC []byte
}

// Compiler renders deployment artifacts from the Postgres data model (spec §8/§9).
// It does NOT apply them — application (write-to-disk + structural reload) is the
// caller's job in cmd/compiler so the byte-path stays out of the control-plane.
type Compiler interface {
	Compile(ctx context.Context, q store.Queries) (Artifacts, error)
}
