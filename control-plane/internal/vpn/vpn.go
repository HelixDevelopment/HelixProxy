// Package vpn models VPN-tunnel health as a DATA-PLANE FACT (Constitution
// §11.4.107 / §11.4.69): a tunnel is "up" only when real byte counters advance,
// the WireGuard handshake is fresh, AND the observed egress IP differs from the
// host IP — never because a config file says so. This package owns the
// vpn-health-publisher contracts (design spec §4 component 1, §5, §7).
//
// SCAFFOLD (Phase 3): real implementations — the gluetun control-API client, the
// `wg show <if> transfer` byte-delta reader, and the egress probe — land in
// internal/vpn + cmd/healthd during plan T3.1/T3.2. This file defines only the
// contracts and value types; there is no business logic yet.
package vpn

import (
	"context"
	"time"
)

// State is the data-plane health verdict for a single tunnel/profile.
type State string

const (
	// StateUp means data-plane signals confirm the tunnel carries traffic.
	StateUp State = "up"
	// StateDown means the tunnel is down; routing through it must fail closed.
	StateDown State = "down"
	// StateUnknown is the fail-closed default before a first valid probe.
	StateUnknown State = "unknown"
)

// HealthSnapshot is the data-plane truth for one VPN profile at one instant.
// It is serialized as JSON into the Redis key `vpn:status:<profile>` (spec §7);
// a stale/expired key MUST be read as down (fail-closed, spec §10).
type HealthSnapshot struct {
	Profile       string    `json:"profile"`
	State         State     `json:"state"`
	LastHandshake time.Time `json:"last_handshake"`
	Rx            uint64    `json:"rx"` // cumulative bytes received on the tunnel iface
	Tx            uint64    `json:"tx"` // cumulative bytes transmitted on the tunnel iface
	EgressIP      string    `json:"egress_ip"`
	CheckedAt     time.Time `json:"checked_at"`
}

// Prober gathers raw data-plane signals for a single profile. Every method
// returns a fact observed from the running system, never a configured value.
type Prober interface {
	// Transfer returns the current cumulative rx/tx byte counters for the
	// profile's tunnel interface (e.g. parsed from `wg show <if> transfer`).
	Transfer(ctx context.Context, profile string) (rx, tx uint64, err error)
	// Handshake returns the time of the most recent successful WireGuard handshake.
	Handshake(ctx context.Context, profile string) (time.Time, error)
	// EgressIP returns the public egress IP observed through the tunnel
	// (e.g. via the gluetun `/v1/publicip/ip` control-API endpoint).
	EgressIP(ctx context.Context, profile string) (string, error)
}

// HealthEvaluator turns successive probe snapshots into an up/down verdict. The
// verdict MUST be a data-plane fact: tx-delta>0 AND fresh handshake AND
// egress != host IP (plan T3.2). A stub that returns StateUp from a configured
// flag is a §11.4 bluff and is forbidden.
type HealthEvaluator interface {
	Evaluate(prev, cur HealthSnapshot, hostIP string) State
}

// Publisher writes a computed HealthSnapshot to the live status bus and emits a
// state-change event on `vpn:events` (spec §7). It is satisfied by
// internal/redis.StatusBus in the real wiring.
type Publisher interface {
	Publish(ctx context.Context, snap HealthSnapshot) error
}
