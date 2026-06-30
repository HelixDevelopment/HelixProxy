package breaker

// tunnelbreaker.go — the per-tunnel circuit-breaker wrapper over
// sony/gobreaker/v2 (design spec §11 ①). Consecutive health-probe failures OPEN
// a tunnel's breaker; after a cooldown it half-opens to admit a single recovery
// probe, and a successful probe CLOSES it. Registry.Closed is the breaker half
// of the SelectTunnel state closure.
//
// NOTE: the package doc + the Decision/Decider scaffold live in the committed
// breaker.go; this file only adds the concrete breaker wrapper, so the package
// doc is intentionally NOT repeated here.

import (
	"errors"
	"sync"
	"time"

	"github.com/sony/gobreaker/v2"
)

// DefaultFailThreshold is the consecutive health-probe-failure count that trips a
// tunnel's breaker OPEN. Fail-closed: an OPEN breaker is removed from the
// SelectTunnel candidate set (§11.4 — never route onto a known-failing tunnel).
const DefaultFailThreshold uint32 = 3

// DefaultCooldown is the OPEN-state dwell time before the breaker half-opens to
// admit one recovery probe (maps to gobreaker Settings.Timeout).
const DefaultCooldown = 30 * time.Second

// errProbe is the sentinel a failed probe feeds gobreaker; gobreaker's default
// IsSuccessful counts any non-nil error as a failure.
var errProbe = errors.New("breaker: health probe failed")

// Options tunes a tunnel breaker. The zero Options is valid — each field falls
// back to its Default* const (§11.4.6: no surprising zero behaviour).
type Options struct {
	// FailThreshold is the consecutive failures that OPEN the breaker.
	// 0 ⇒ DefaultFailThreshold.
	FailThreshold uint32
	// Cooldown is the OPEN dwell before half-open. <= 0 ⇒ DefaultCooldown.
	Cooldown time.Duration
}

func (o Options) failThreshold() uint32 {
	if o.FailThreshold == 0 {
		return DefaultFailThreshold
	}
	return o.FailThreshold
}

func (o Options) cooldown() time.Duration {
	if o.Cooldown <= 0 {
		return DefaultCooldown
	}
	return o.Cooldown
}

// Breaker is a thin per-tunnel wrapper over sony/gobreaker/v2. It is safe for
// concurrent use (gobreaker serialises its own state internally).
type Breaker struct {
	cb *gobreaker.CircuitBreaker[struct{}]
}

// NewBreaker builds a per-tunnel breaker named for the tunnel. A fresh breaker
// starts CLOSED.
func NewBreaker(tunnel string, opts Options) *Breaker {
	thr := opts.failThreshold()
	return &Breaker{
		cb: gobreaker.NewCircuitBreaker[struct{}](gobreaker.Settings{
			Name:        tunnel,
			MaxRequests: 1, // one successful half-open probe closes the breaker
			Timeout:     opts.cooldown(),
			ReadyToTrip: func(c gobreaker.Counts) bool {
				return c.ConsecutiveFailures >= thr
			},
		}),
	}
}

// Record feeds one health-probe outcome into the breaker state machine. While the
// breaker is OPEN (cooldown not elapsed) the probe is short-circuited and ignored,
// exactly as gobreaker intends; once the cooldown elapses the next Record(true)
// runs as the half-open recovery probe and closes the breaker.
func (b *Breaker) Record(success bool) {
	_, _ = b.cb.Execute(func() (struct{}, error) {
		if success {
			return struct{}{}, nil
		}
		return struct{}{}, errProbe
	})
}

// Closed reports whether the breaker is in the CLOSED state — the ONLY state in
// which SelectTunnel may route live traffic onto the tunnel. HALF-OPEN (recovery
// probing) and OPEN both report false: fail-closed.
func (b *Breaker) Closed() bool { return b.cb.State() == gobreaker.StateClosed }

// State returns the breaker's current state string ("closed" / "half-open" /
// "open"), for logging and evidence capture.
func (b *Breaker) State() string { return b.cb.State().String() }

// Registry holds a lazily-created Breaker per tunnel name, so a tunnel never seen
// before is treated as CLOSED (eligible) until it actually accumulates failures.
// It is safe for concurrent use.
type Registry struct {
	opts     Options
	mu       sync.Mutex
	breakers map[string]*Breaker
}

// NewRegistry builds an empty registry; every per-tunnel breaker it creates uses
// opts.
func NewRegistry(opts Options) *Registry {
	return &Registry{opts: opts, breakers: make(map[string]*Breaker)}
}

// get returns the tunnel's breaker, creating a fresh CLOSED one on first sight.
func (r *Registry) get(tunnel string) *Breaker {
	r.mu.Lock()
	defer r.mu.Unlock()
	b, ok := r.breakers[tunnel]
	if !ok {
		b = NewBreaker(tunnel, r.opts)
		r.breakers[tunnel] = b
	}
	return b
}

// Record feeds a health-probe outcome into the named tunnel's breaker.
func (r *Registry) Record(tunnel string, success bool) { r.get(tunnel).Record(success) }

// Closed reports whether the named tunnel's breaker is CLOSED. An unseen tunnel is
// CLOSED (no failures observed yet). Suitable as the breaker half of the
// SelectTunnel state closure:
//
//	SelectTunnel(tiers, func(t string) (bool, bool) {
//		return reg.Closed(t), health.Up(t)
//	})
func (r *Registry) Closed(tunnel string) bool { return r.get(tunnel).Closed() }
