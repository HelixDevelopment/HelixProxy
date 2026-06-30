// Package breaker defines the per-target circuit-breaker + tunnel tier-failover
// decision (design spec §11 ①, §10). The real implementation wraps
// sony/gobreaker/v2 and is embedded in the external-acl-helper's per-request
// path (spec §4 component 3) so a failing tunnel trips the breaker and traffic
// fails over to the next healthy tier — or returns a graceful 503.
//
// SCAFFOLD (Phase 5): real impl lands in internal/breaker during plan T5.2.
package breaker

import "context"

// Decision is the helper's per-request verdict: which tunnel to use, or deny.
type Decision struct {
	Tunnel string // chosen tunnel/profile name; empty when Allow is false
	Tier   int    // failover tier that was selected
	Allow  bool   // false => helper returns ERR => Squid emits a graceful 503
}

// Decider picks the highest-preference healthy tunnel for a target, honoring the
// target's ordered failover tiers and per-target breaker state (spec §10 / §11 ①).
// It MUST fail closed: when no tier is up, Allow is false (graceful 503, no leak).
type Decider interface {
	// Decide chooses a tunnel for the target (or denies, fail-closed).
	Decide(ctx context.Context, target string) Decision
	// Record feeds a per-request outcome back into the target/tunnel breaker.
	Record(target, tunnel string, success bool)
}
