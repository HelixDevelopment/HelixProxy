// health.go — the PURE data-plane health verdict (design spec §5/§13, Constitution
// §11.4.107 / §11.4.69). A tunnel is "up" ONLY when real byte counters advance,
// the WireGuard handshake is fresh, AND an egress IP is observed that is not the
// host's own IP. Every input is a fact gathered from the running system; nothing
// here reads a configured flag. The function is fail-closed: ANY missing / zero /
// empty / stale fact yields StateDown so a tunnel outage can never fall through
// to a leak.
package vpn

import "time"

// DecideHealth is the pure, side-effect-free up/down verdict for one poll cycle.
//
// StateUp is returned ONLY when ALL of the following data-plane facts hold:
//   - fresh handshake : cur.LastHandshake is non-zero AND the handshake age
//     (cur.CheckedAt - cur.LastHandshake) is within [0, freshness].
//   - tx advanced     : cur.Tx > prev.Tx — the tunnel transmitted bytes across
//     the poll interval (tx-delta > 0). A flat counter ⇒ no traffic ⇒ DOWN.
//   - egress observed : cur.EgressIP is non-empty (gluetun /v1/publicip/ip
//     returns "" when there is no real egress).
//   - egress != host  : when a host IP is known (hostIP != ""), the observed
//     egress IP differs from it (egress == host ⇒ traffic is NOT tunnelled).
//
// Any other combination ⇒ StateDown (fail-closed). freshness <= 0 means the
// handshake-freshness guard is unsatisfiable, so the verdict is always DOWN
// (a misconfigured window must never read "up").
func DecideHealth(prev, cur HealthSnapshot, hostIP string, freshness time.Duration) State {
	if freshness <= 0 {
		return StateDown
	}
	// Fresh handshake.
	if cur.LastHandshake.IsZero() {
		return StateDown
	}
	age := cur.CheckedAt.Sub(cur.LastHandshake)
	if age < 0 || age > freshness {
		return StateDown
	}
	// tx advanced (byte-delta > 0 across the interval).
	if cur.Tx <= prev.Tx {
		return StateDown
	}
	// egress observed.
	if cur.EgressIP == "" {
		return StateDown
	}
	// egress is not the host's own IP.
	if hostIP != "" && cur.EgressIP == hostIP {
		return StateDown
	}
	return StateUp
}

// DataPlaneEvaluator implements the HealthEvaluator contract by delegating to the
// pure DecideHealth rule with a configured freshness window. It is the production
// evaluator wired into cmd/healthd; a stub returning StateUp from a flag is a
// §11.4 bluff and is forbidden (see vpn.go HealthEvaluator doc).
type DataPlaneEvaluator struct {
	// Freshness is the maximum acceptable WireGuard handshake age.
	Freshness time.Duration
}

// Evaluate satisfies HealthEvaluator. hostIP may be "" when unknown.
func (e DataPlaneEvaluator) Evaluate(prev, cur HealthSnapshot, hostIP string) State {
	return DecideHealth(prev, cur, hostIP, e.Freshness)
}

// compile-time assertion that DataPlaneEvaluator satisfies the contract.
var _ HealthEvaluator = DataPlaneEvaluator{}
