package breaker

// Tier pairs a tunnel/profile name with its failover tier. Lower Tier == higher
// preference (tier 1 is the primary, tier 2 the first failover, …). The design
// spec (§10 / §11 ①) feeds SelectTunnel a target's tiers ordered ascending by
// Tier; SelectTunnel does NOT rely on that ordering and selects by the smallest
// Tier value among eligible tunnels, so an out-of-order slice is still correct.
type Tier struct {
	Tunnel string
	Tier   int
}

// SelectTunnel is the PURE (no I/O) tier-failover route decision and the
// fail-closed heart of the breaker package. It returns the LOWEST-tier tunnel
// whose breaker is CLOSED *and* whose health is UP, as reported by the caller's
// `state` closure. If NO tunnel qualifies — every tier open/down, an empty tier
// list, or a nil state closure — it returns "" (fail-closed): the caller emits
// ERR / no route and Squid surfaces a graceful 503. It NEVER picks an
// open-breaker or down tunnel.
//
// This mirrors the redis/aclhelper fail-closed primitives already in the tree
// (§11.4 anti-bluff): the single affirmative path is "breaker CLOSED AND health
// UP"; every other case is the refusal. Selection is by minimum Tier value;
// ties (equal Tier) resolve to the first such tunnel in slice order.
func SelectTunnel(tiers []Tier, state func(tunnel string) (breakerClosed bool, healthUp bool)) (chosen string) {
	if len(tiers) == 0 || state == nil {
		return ""
	}

	found := false
	bestTier := 0
	for _, t := range tiers {
		breakerClosed, healthUp := state(t.Tunnel)
		if !breakerClosed || !healthUp {
			// Fail-closed: an open breaker OR a down tunnel is never eligible.
			continue
		}
		if !found || t.Tier < bestTier {
			found = true
			bestTier = t.Tier
			chosen = t.Tunnel
		}
	}
	if !found {
		return ""
	}
	return chosen
}
