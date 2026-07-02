// health.go — the PURE data-plane health verdict (design spec §5/§13, Constitution
// §11.4.107 / §11.4.69 / §11.4.68). A tunnel is "up" ONLY when an egress IP is
// observed that is not the host's own IP AND at least ONE genuine, FRESH data-plane
// liveness proof holds — EITHER the WireGuard proof (fresh handshake + advancing tx
// counters) OR a fresh per-poll through-tunnel liveness probe (LiveProbeAt). Every
// input is a fact gathered from the running system; nothing here reads a configured
// flag. The function is fail-closed: ANY missing / zero / empty / stale fact yields
// StateDown so a tunnel outage can never fall through to a leak.
package vpn

import "time"

// DecideHealth is the pure, side-effect-free up/down verdict for one poll cycle.
//
// SHARED PRECONDITIONS (both proof paths require these — checked first):
//   - freshness > 0   : a non-positive window is unsatisfiable ⇒ always DOWN
//     (a misconfigured window must never read "up").
//   - egress observed : cur.EgressIP is non-empty (gluetun /v1/publicip/ip
//     returns "" when there is no real egress).
//   - egress != host  : when a host IP is known (hostIP != ""), the observed
//     egress IP differs from it (egress == host ⇒ traffic is NOT tunnelled).
//
// Then StateUp is returned when EITHER data-plane liveness proof holds:
//
//	(1) WireGuard proof (wgProofFresh): cur.LastHandshake is non-zero AND its age
//	    (cur.CheckedAt - cur.LastHandshake) is within [0, freshness] AND
//	    cur.Tx > prev.Tx (tx-delta > 0 across the interval — a flat counter ⇒ no
//	    traffic). This is the classic WireGuard path, preserved unchanged.
//
//	(2) Through-tunnel liveness proof (liveProbeFresh): cur.LiveProbeAt is non-zero
//	    AND its age (cur.CheckedAt - cur.LiveProbeAt) is within [0, freshness] — a
//	    real request egressed via the tunnel's forward proxy and returned THIS
//	    cycle (§11.4.68 fresh data-plane proof). This path exists because in a
//	    userspace-WireGuard gluetun deployment the wg handshake/tx counters are
//	    STRUCTURALLY UNOBTAINABLE (no `wg` binary; the control API exposes no
//	    transfer/handshake), so path (1) can never fire even for a genuinely-live
//	    tunnel. The probe is the fresh liveness signal that /v1/publicip/ip
//	    (a CACHED value) is not.
//
// Neither proof ⇒ StateDown (fail-closed). The two paths are an OR, but BOTH rest
// on the shared egress preconditions above, so a "fresh liveness" with an empty or
// host-equal egress is still DOWN — a leak can never fall through.
func DecideHealth(prev, cur HealthSnapshot, hostIP string, freshness time.Duration) State {
	if freshness <= 0 {
		return StateDown
	}
	// egress observed (shared precondition for BOTH proof paths).
	if cur.EgressIP == "" {
		return StateDown
	}
	// egress is not the host's own IP (shared precondition for BOTH proof paths).
	if hostIP != "" && cur.EgressIP == hostIP {
		return StateDown
	}
	// UP when EITHER genuine, fresh data-plane liveness proof holds.
	if wgProofFresh(prev, cur, freshness) {
		return StateUp
	}
	if liveProbeFresh(cur, freshness) {
		return StateUp
	}
	return StateDown
}

// wgProofFresh reports whether the WireGuard proof holds: a fresh (non-zero,
// in-window) handshake AND a positive tx-delta across the poll interval. It is the
// classic path, unchanged from the original DecideHealth. freshness is assumed > 0
// (DecideHealth guards it). Any zero/stale/flat fact ⇒ false (fail-closed).
func wgProofFresh(prev, cur HealthSnapshot, freshness time.Duration) bool {
	if cur.LastHandshake.IsZero() {
		return false
	}
	age := cur.CheckedAt.Sub(cur.LastHandshake)
	if age < 0 || age > freshness {
		return false
	}
	// tx advanced (byte-delta > 0 across the interval).
	return cur.Tx > prev.Tx
}

// liveProbeFresh reports whether a FRESH through-tunnel liveness probe succeeded
// this cycle: cur.LiveProbeAt is non-zero AND within [0, freshness] of CheckedAt.
// A zero LiveProbeAt (probe failed / not run / kill-switch-blocked) or a stale one
// ⇒ false (fail-closed). freshness is assumed > 0 (DecideHealth guards it).
func liveProbeFresh(cur HealthSnapshot, freshness time.Duration) bool {
	if cur.LiveProbeAt.IsZero() {
		return false
	}
	age := cur.CheckedAt.Sub(cur.LiveProbeAt)
	return age >= 0 && age <= freshness
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
