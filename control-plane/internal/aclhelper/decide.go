package aclhelper

import (
	"context"

	"digital.vasic.helixproxy/controlplane/internal/redis"
	"digital.vasic.helixproxy/controlplane/internal/vpn"
)

// Bus is the subset of redis.StatusBus the per-request decision needs. It is an
// interface (not the concrete *redis.Client) so the decision is unit-testable
// with a fake and the fail-closed negation is provably caught (§1.1). The real
// *redis.Client satisfies it.
type Bus interface {
	// GetRoute returns the compiler-resolved route for a target, or
	// redis.ErrRouteNotFound on a miss (fail-closed: no route ⇒ refuse).
	GetRoute(ctx context.Context, target string) (redis.Route, error)
	// GetStatus returns the fail-closed health snapshot for a tunnel/profile
	// (missing/stale/error ⇒ StateDown).
	GetStatus(ctx context.Context, profile string) (vpn.HealthSnapshot, error)
}

// Decider answers the per-request route+health question against a Bus.
type Decider struct {
	Bus Bus
}

// Decide is the PURE fail-closed routing verdict for one request Host (the
// decoded host from ParseLine). It returns (true, <tunnel>) — answer
// `OK tag=<tunnel>` — ONLY on the single affirmative path:
//
//	a route exists for host AND that route's tunnel is StateUp.
//
// EVERY other case returns (false, "") — answer ERR (→ Squid deny_info 503,
// docs/DYNAMIC_ROUTING.md §4/§5):
//
//   - empty / malformed host                  → ERR
//   - no route (redis.ErrRouteNotFound)        → ERR
//   - GetRoute transport error                 → ERR (never guess a route)
//   - route present but Tunnel field empty     → ERR (malformed route)
//   - GetStatus transport error                → ERR
//   - tunnel StateDown / StateUnknown          → ERR
//
// The route's Tunnel field is the single stable identifier (§11.4.111) used BOTH
// as the GetStatus profile key AND as the returned tag, so the compiler (which
// writes route:<target>) and the Squid cache_peer `name=` agree on one name.
func (d Decider) Decide(ctx context.Context, host string) (ok bool, tag string) {
	if host == "" {
		return false, ""
	}
	route, err := d.Bus.GetRoute(ctx, host)
	if err != nil {
		// ErrRouteNotFound OR any transport error: fail-closed.
		return false, ""
	}
	if route.Tunnel == "" {
		// A route with no tunnel is unusable — refuse rather than emit `OK tag=`.
		return false, ""
	}
	snap, err := d.Bus.GetStatus(ctx, route.Tunnel)
	if err != nil {
		// Transport error: the snapshot is already DOWN-safe, but be explicit.
		return false, ""
	}
	if snap.State != vpn.StateUp {
		// down / unknown ⇒ fail-closed (the negation of the ONLY "up" path).
		return false, ""
	}
	return true, route.Tunnel
}
