// Package redis defines the live data-plane STATE-BUS contract (design spec §7):
// the authoritative, fail-closed source the external-acl-helper consults per
// request and that the vpn-health-publisher + config-compiler write to. Routing
// and up/down dynamism flow through here per request, so Squid/Dante need no
// reconfigure on a tunnel toggle (spec §4 principle, §8).
//
// SCAFFOLD (Phase 2): a real client (e.g. github.com/redis/go-redis/v9) is wired
// in internal/redis during plan T2.3. This file defines only the StatusBus
// contract and value types; there is no implementation yet.
package redis

import (
	"context"

	"digital.vasic.helixproxy/controlplane/internal/vpn"
)

// Route is the compiler-resolved routing decision for one target, stored under
// the Redis key `route:<target>` (spec §7).
type Route struct {
	Target       string `json:"target"`
	Tunnel       string `json:"tunnel"`
	Tier         int    `json:"tier"`
	BreakerState string `json:"breaker_state"`
}

// Event is a tunnel state-change message published on the `vpn:events` channel
// (spec §7) so the helper and admin UI update instantly.
type Event struct {
	ProfileID string    `json:"profile_id"`
	State     vpn.State `json:"state"`
}

// StatusBus is the live data-plane state bus. Implementations MUST fail closed:
// a missing or stale (TTL-expired) `vpn:status:<profile>` key is treated as down
// so a tunnel outage can never fall through to a leak (spec §10).
type StatusBus interface {
	// SetStatus writes `vpn:status:<profile>` with a TTL (seconds); the TTL is
	// what makes a stale key read as down.
	SetStatus(ctx context.Context, snap vpn.HealthSnapshot, ttlSeconds int) error
	// GetStatus reads the current snapshot for a profile, returning a
	// StateDown/StateUnknown snapshot when the key is absent or stale.
	GetStatus(ctx context.Context, profile string) (vpn.HealthSnapshot, error)
	// SetRoute writes the resolved `route:<target>` decision (compiler-written).
	SetRoute(ctx context.Context, r Route) error
	// GetRoute reads the resolved route for a target (helper per-request lookup).
	GetRoute(ctx context.Context, target string) (Route, error)
	// PublishEvent emits a state-change on `vpn:events`.
	PublishEvent(ctx context.Context, e Event) error
	// SubscribeEvents streams state-change events until ctx is cancelled.
	SubscribeEvents(ctx context.Context) (<-chan Event, error)
}
