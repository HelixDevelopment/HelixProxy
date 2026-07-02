// Package routing is the config-compiler (design spec §4 component 2): it reads
// the Postgres data model (store.Queries) and renders the deployment artifacts —
// the Squid generated include, the Dante route blocks, and the PAC file — plus
// the resolved per-target `route:<target>` decisions that the compiler seeds into
// Redis (spec §7). Routing + up/down dynamism is applied via the external-acl
// helper + Redis per request; ONLY structural changes (a tunnel/target added or
// removed) trigger a Squid `reconfigure` / Dante SIGHUP — never a tunnel merely
// going up or down (spec §8 / §9).
//
// The render functions here are PURE (no I/O): they take resolved value types and
// return bytes, so they are unit-testable in isolation against committed golden
// files. The Engine wires them to a store.Queries for the live compile pass.
//
// FILL CONTRACT (config/squid/templates/README.md, no-guessing §11.4.6): the
// Squid include emits the external_acl_type + `acl tun_up` block ONCE, repeats the
// cache_peer + cache_peer_access PAIR once per enabled tunnel, then emits the
// fail-closed block ONCE — `never_direct allow all`, then `http_access deny !tun_up`
// (tunnel down → branded 503), then the GATED `http_access allow localnet` (the
// ONLY client-allow; reached only when the tunnel is up). The baked fail-closed
// base config/squid/squid.dynamic.conf places `include /etc/squid/conf.d/*.squid`
// BEFORE its terminal `http_access deny all` and carries NO unconditional
// `allow localnet`, so a MISSING include (compiler not run) fails closed at
// `deny all` (§11.4.108). Dante has no `include` directive, so its routes are
// ADDITIVE BY CONCATENATION (base sockd.conf verbatim + appended route{} blocks) —
// cmd/compiler performs the concatenation; this package renders only the blocks.
package routing

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"sort"
	"strconv"
	"strings"
	"text/template"

	"digital.vasic.helixproxy/controlplane/internal/redis"
	"digital.vasic.helixproxy/controlplane/internal/store"
)

// DefaultPeerPort is the gluetun built-in HTTP forward-proxy port (FACT: gluetun's
// HTTPPROXY listener defaults to 8888). A profile MAY override it via a numeric
// `peer_port` key in its config jsonb; the gluetun host MAY be overridden via a
// string `peer_host` key. Absent both, the compiler derives them deterministically
// (gluetun-<profile> : 8888) so a render is reproducible (§11.4.6 no-guessing).
const DefaultPeerPort = 8888

// DefaultPACProxy is the PAC return value for VPN-routed targets when the operator
// does not override it. Non-target hosts return DIRECT (split-tunnel, spec §11 ⑤).
const DefaultPACProxy = "PROXY proxy-squid:34128"

// Artifacts is the rendered output set produced by one compile pass.
type Artifacts struct {
	// SquidInclude is the generated Squid include: external_acl wiring + per-tunnel
	// `cache_peer`/`cache_peer_access` + the fail-closed `deny_info 503` block.
	SquidInclude []byte
	// DanteRoutes is the generated `route { ... }` blocks (one per target/tunnel),
	// APPENDED after the shipped sockd.conf by cmd/compiler (Dante has no include).
	DanteRoutes []byte
	// PAC is the rendered FindProxyForURL proxy auto-config file body.
	PAC []byte
}

// Compiler renders deployment artifacts from the Postgres data model (spec §8/§9).
// Application (write-to-disk + structural reload) is the caller's job in
// cmd/compiler so the byte-path stays out of the control-plane.
type Compiler interface {
	Compile(ctx context.Context, q store.Queries) (Artifacts, error)
}

// Tunnel is one resolved per-tunnel egress (a Squid cache_peer). Name is the
// cache_peer token `tun_<profile>`; Profile is the unprefixed profile name (the
// `vpn:status:<profile>` key + route Tunnel field, resolve-by-name §11.4.111).
type Tunnel struct {
	Profile  string
	Name     string
	PeerHost string
	PeerPort int
}

// DanteRoute is one resolved Dante egress route (a target chained through its
// primary tunnel's gluetun upstream).
type DanteRoute struct {
	Name       string // tun_<profile> (comment label)
	TargetCIDR string // destination host/CIDR routed through this tunnel
	PeerHost   string
	PeerPort   int
}

// Engine is the live Compiler implementation. HelperPath is the absolute path of
// the external_acl helper binary the rendered Squid include wires; PACProxy is the
// PAC return value for routed targets (defaults applied by New).
type Engine struct {
	HelperPath string
	PACProxy   string
}

var _ Compiler = (*Engine)(nil)

// New builds an Engine, applying defaults for empty fields.
func New(helperPath, pacProxy string) *Engine {
	if pacProxy == "" {
		pacProxy = DefaultPACProxy
	}
	return &Engine{HelperPath: helperPath, PACProxy: pacProxy}
}

// Compile satisfies the Compiler interface (artifacts only).
func (e *Engine) Compile(ctx context.Context, q store.Queries) (Artifacts, error) {
	arts, _, err := e.CompileAll(ctx, q)
	return arts, err
}

// CompileAll runs one read pass over the data model and returns BOTH the rendered
// artifacts AND the resolved per-target route decisions (so cmd/compiler seeds
// Redis without a second query). Enabled profiles become cache_peers; each target
// is mapped to its primary tunnel (tier 0, else target.vpn_profile_id) — orphan
// targets whose profile cannot be resolved are skipped (fail-closed, no guessing).
func (e *Engine) CompileAll(ctx context.Context, q store.Queries) (Artifacts, []redis.Route, error) {
	profiles, err := q.ListProfiles(ctx)
	if err != nil {
		return Artifacts{}, nil, fmt.Errorf("routing: list profiles: %w", err)
	}
	targets, err := q.ListTargets(ctx)
	if err != nil {
		return Artifacts{}, nil, fmt.Errorf("routing: list targets: %w", err)
	}

	// Enabled tunnels (cache_peers) + lookup maps keyed by stable identity.
	tunnels := ResolveTunnels(profiles)
	peerByProfile := make(map[string]Tunnel, len(tunnels))
	for _, t := range tunnels {
		peerByProfile[t.Profile] = t
	}
	nameByID := make(map[string]string, len(profiles))
	for _, p := range profiles {
		nameByID[p.ID] = p.Name
	}

	var dRoutes []DanteRoute
	var routes []redis.Route
	for _, tgt := range targets {
		if !tgt.Enabled {
			continue
		}
		tiers, terr := q.ListTiers(ctx, tgt.ID)
		if terr != nil {
			return Artifacts{}, nil, fmt.Errorf("routing: list tiers for %s: %w", tgt.PublicAlias, terr)
		}
		profileName, tier, ok := primaryTunnel(tgt, tiers, nameByID)
		if !ok {
			continue // orphan target: no resolvable tunnel — fail-closed, skip
		}
		peer, ok := peerByProfile[profileName]
		if !ok {
			continue // primary tunnel disabled/absent — skip rather than guess
		}
		dRoutes = append(dRoutes, DanteRoute{
			Name: peer.Name, TargetCIDR: tgt.PrivateIP, PeerHost: peer.PeerHost, PeerPort: peer.PeerPort,
		})
		routes = append(routes, redis.Route{
			Target: tgt.PublicAlias, Tunnel: profileName, Tier: tier, BreakerState: "closed",
		})
	}

	aliases := make([]string, 0, len(targets))
	for _, tgt := range targets {
		if tgt.Enabled {
			aliases = append(aliases, tgt.PublicAlias)
		}
	}

	return Artifacts{
		SquidInclude: RenderSquidInclude(e.HelperPath, tunnels),
		DanteRoutes:  RenderDanteRoutes(dRoutes),
		PAC:          RenderPAC(e.PACProxy, aliases),
	}, routes, nil
}

// primaryTunnel resolves a target's primary tunnel profile name + its tier. Tier 0
// (lowest) is preferred; tiers are listed tier-ASC by the store. Falls back to the
// target's own vpn_profile_id (tier 0) when no tiers are configured.
func primaryTunnel(tgt store.TargetHost, tiers []store.TargetTunnelTier, nameByID map[string]string) (string, int, bool) {
	if len(tiers) > 0 {
		if name, ok := nameByID[tiers[0].VPNProfileID]; ok && name != "" {
			return name, tiers[0].Tier, true
		}
		return "", 0, false
	}
	if tgt.VPNProfileID != "" {
		if name, ok := nameByID[tgt.VPNProfileID]; ok && name != "" {
			return name, 0, true
		}
	}
	return "", 0, false
}

// ResolveTunnels maps the ENABLED profiles to cache_peer tunnels, ordered by
// profile name (deterministic render). Disabled profiles are excluded — a disabled
// tunnel never gets a cache_peer.
func ResolveTunnels(profiles []store.VPNProfile) []Tunnel {
	out := make([]Tunnel, 0, len(profiles))
	for _, p := range profiles {
		if !p.Enabled {
			continue
		}
		host, port := peerEndpoint(p)
		out = append(out, Tunnel{
			Profile:  p.Name,
			Name:     "tun_" + sanitizeToken(p.Name),
			PeerHost: host,
			PeerPort: port,
		})
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Profile < out[j].Profile })
	return out
}

// peerEndpoint derives a tunnel's gluetun proxy host:port: optional `peer_host` /
// `peer_port` keys in the profile config jsonb override the deterministic defaults
// (gluetun-<profile> : DefaultPeerPort). Malformed config falls back to defaults.
func peerEndpoint(p store.VPNProfile) (string, int) {
	host := "gluetun-" + sanitizeToken(p.Name)
	port := DefaultPeerPort
	if len(p.Config) > 0 {
		var m map[string]any
		if json.Unmarshal(p.Config, &m) == nil {
			if v, ok := m["peer_host"].(string); ok && v != "" {
				host = v
			}
			switch v := m["peer_port"].(type) {
			case float64:
				if v > 0 {
					port = int(v)
				}
			case string:
				if n, err := strconv.Atoi(v); err == nil && n > 0 {
					port = n
				}
			}
		}
	}
	return host, port
}

// sanitizeToken makes a string safe as a single Squid config token (no whitespace
// or control runs). Already-valid names (e.g. "eu-wg-primary") pass through.
func sanitizeToken(s string) string {
	var b strings.Builder
	for _, r := range s {
		switch {
		case r >= 'a' && r <= 'z', r >= 'A' && r <= 'Z', r >= '0' && r <= '9',
			r == '_', r == '-', r == '.':
			b.WriteRune(r)
		default:
			b.WriteRune('_')
		}
	}
	if b.Len() == 0 {
		return "unnamed"
	}
	return b.String()
}

// --- pure renderers ---------------------------------------------------------

var squidTmpl = template.Must(template.New("squid").Parse(
	`# =============================================================================
# Helix Proxy — Squid dynamic-routing include   (GENERATED — DO NOT EDIT BY HAND)
# =============================================================================
# Generated by : control-plane config-compiler (spec §4 component 2). ADDITIVE
#   include (§11.4.122): pulled into config/squid/squid.dynamic.conf BEFORE its
#   terminal ` + "`http_access deny all`" + `. It supplies ` + "`http_access deny !tun_up`" + ` and
#   then the GATED ` + "`http_access allow localnet`" + ` — the base carries NO unconditional
#   ` + "`allow localnet`" + `, so a missing include fails closed (§11.4.108).
#   Re-rendered ONLY on a STRUCTURAL change (tunnel added/removed) + applied via
#   Squid ` + "`reconfigure`" + ` — NEVER on a tunnel going up/down (that is the helper
#   + Redis, zero reconfigure). Squid 6.13 form ` + "`%>ha{Host}`" + ` (` + "`%>{Host}`" + ` deprecated).
# -----------------------------------------------------------------------------
external_acl_type vpn_route ttl=0 negative_ttl=0 %>ha{Host} {{.HelperPath}}
acl tun_up external vpn_route
{{range .Tunnels}}
# {{.Name}}: egress via gluetun {{.PeerHost}}:{{.PeerPort}} when its tunnel is up
cache_peer {{.PeerHost}} parent {{.PeerPort}} 0 no-query name={{.Name}}
cache_peer_access {{.Name}} allow tun_up
cache_peer_access {{.Name}} deny all
{{end}}
# --- fail-closed: never egress directly; serve a branded 503 when down -------
# ORDERING IS LOAD-BEARING (§11.4.108): ` + "`deny !tun_up`" + ` (tunnel down → branded
# 503) is evaluated BEFORE the gated ` + "`allow localnet`" + ` (tunnel up → permitted).
# The base squid.dynamic.conf carries NO unconditional ` + "`allow localnet`" + `, so this
# is the ONLY client-allow — a missing include falls through to ` + "`deny all`" + `.
never_direct allow all
http_access deny !tun_up
http_access allow localnet
deny_info 503:ERR_TUNNEL_DOWN tun_up
`))

// RenderSquidInclude renders the Squid dynamic-routing include per the FILL
// CONTRACT: the external_acl/acl block once, the cache_peer pair once per tunnel,
// the fail-closed block once.
func RenderSquidInclude(helperPath string, tunnels []Tunnel) []byte {
	if helperPath == "" {
		helperPath = "/usr/lib/helix-proxy/acl-helper"
	}
	var buf bytes.Buffer
	_ = squidTmpl.Execute(&buf, struct {
		HelperPath string
		Tunnels    []Tunnel
	}{helperPath, tunnels})
	return buf.Bytes()
}

var danteTmpl = template.Must(template.New("dante").Parse(
	`# =============================================================================
# Helix Proxy — Dante (sockd) dynamic-routing routes   (GENERATED — DO NOT EDIT)
# =============================================================================
# APPENDED (by cmd/compiler) after the shipped config/dante/sockd.conf verbatim —
# Dante v1.4.4 has NO ` + "`include`" + ` directive, so dynamism = concat + SIGHUP (§9).
# One route block per target/tunnel; base lines are never modified (§11.4.122).
# -----------------------------------------------------------------------------
{{range .}}
# {{.Name}}: send traffic destined for {{.TargetCIDR}} out via this tunnel.
route {
    from: 0.0.0.0/0   to: {{.TargetCIDR}}   via: {{.PeerHost}} port = {{.PeerPort}}
    proxyprotocol: socks_v5
    method: none
}
{{end}}`))

// RenderDanteRoutes renders the per-target Dante route blocks (the appended half
// of the concatenated deployed sockd.conf).
func RenderDanteRoutes(routes []DanteRoute) []byte {
	var buf bytes.Buffer
	_ = danteTmpl.Execute(&buf, routes)
	return buf.Bytes()
}

var pacTmpl = template.Must(template.New("pac").Parse(
	`// Helix Proxy — proxy auto-config (GENERATED — DO NOT EDIT BY HAND).
// VPN-routed target aliases go through the proxy; everything else is DIRECT
// (split-tunnel, spec §11 ⑤). Regenerated only on a structural change.
function FindProxyForURL(url, host) {
{{- range .Aliases}}
    if (shExpMatch(host, {{printf "%q" .}})) { return {{printf "%q" $.Proxy}}; }
{{- end}}
    return "DIRECT";
}
`))

// RenderPAC renders the FindProxyForURL body mapping each target alias to the
// proxy. Aliases are sorted for deterministic output.
func RenderPAC(proxy string, aliases []string) []byte {
	if proxy == "" {
		proxy = DefaultPACProxy
	}
	sorted := append([]string(nil), aliases...)
	sort.Strings(sorted)
	var buf bytes.Buffer
	_ = pacTmpl.Execute(&buf, struct {
		Aliases []string
		Proxy   string
	}{sorted, proxy})
	return buf.Bytes()
}
