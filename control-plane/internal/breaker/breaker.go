// Package breaker defines the per-target circuit-breaker + tunnel tier-failover
// decision (design spec §11 ①, §10). It wraps sony/gobreaker/v2: a failing tunnel
// trips its breaker and SelectTunnel fails the route over to the next healthy
// tier — or returns "" (a graceful 503, fail-closed, never a leak onto a known-
// failing tunnel).
//
// The package is two halves:
//   - selection.go     — SelectTunnel: the PURE, side-effect-free, fail-closed
//     tier-failover verdict (the heart). Lowest-tier tunnel that is breaker-CLOSED
//     AND health-UP, else "".
//   - tunnelbreaker.go — Breaker + Registry: the gobreaker/v2 state machine that
//     supplies the breaker half of SelectTunnel's state closure.
//
// §11.4.6 honest boundary: this package is the tier-failover LOGIC. Wiring it into
// the external-acl-helper's per-request path (spec §4 component 3) — so a live
// health/breaker flip re-selects the route — is a later integration step and the
// package is intentionally not imported anywhere yet.
//
// History (§11.4.124): the P0 scaffold (commit 5f917a7) carried placeholder
// Decision/Decider types here marked "real impl lands during plan T5.2". T5.2 is
// this phase (P5b); the real implementation landed with a pure SelectTunnel +
// Registry API, so those zero-consumer placeholders were retired (no importer of
// internal/breaker existed; Decision/Decider had no callers).
package breaker
