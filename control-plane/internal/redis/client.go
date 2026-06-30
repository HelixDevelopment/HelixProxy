// go-redis-backed implementation of the StatusBus contract (design spec §7), the
// live data-plane state bus. The defining property is FAIL-CLOSED (spec §10):
// a missing OR stale `vpn:status:<profile>` is reported as DOWN, never silently
// "up", so a tunnel outage (or a Redis outage) can never fall through to a leak.
//
// Two independent staleness mechanisms back fail-closed:
//   (1) Redis TTL — SetStatus writes with an expiry; an expired key is GONE, so
//       GetStatus sees a miss → DOWN.
//   (2) Freshness guard — even a present key whose CheckedAt is older than the
//       configured maxAge is downgraded to DOWN (defence in depth against a
//       publisher that stopped refreshing but left a key with a long TTL).
package redis

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"time"

	goredis "github.com/redis/go-redis/v9"

	"digital.vasic.helixproxy/controlplane/internal/vpn"
)

// Redis key / channel naming (resolve-by-name §11.4.111).
const (
	statusKeyPrefix = "vpn:status:"
	routeKeyPrefix  = "route:"
	eventsChannel   = "vpn:events"
)

// ErrRouteNotFound is returned by GetRoute when no route exists for a target.
// Callers MUST treat it as fail-closed (no route ⇒ refuse, never leak).
var ErrRouteNotFound = errors.New("redis: route not found")

// StatusKey / RouteKey are exported so tests and the helper agree on the layout.
func StatusKey(profile string) string { return statusKeyPrefix + profile }
func RouteKey(target string) string   { return routeKeyPrefix + target }

// Client implements StatusBus over a *goredis.Client. maxAge is the freshness
// window: a present snapshot older than maxAge is treated as DOWN. maxAge <= 0
// disables the freshness guard (TTL-only fail-closed).
type Client struct {
	rdb    *goredis.Client
	maxAge time.Duration
}

// compile-time assertion that *Client satisfies the contract.
var _ StatusBus = (*Client)(nil)

// NewClient wraps an existing go-redis client.
func NewClient(rdb *goredis.Client, maxAge time.Duration) *Client {
	return &Client{rdb: rdb, maxAge: maxAge}
}

// Open dials addr (e.g. "127.0.0.1:6379") and verifies connectivity with PING.
func Open(ctx context.Context, addr string, maxAge time.Duration) (*Client, error) {
	rdb := goredis.NewClient(&goredis.Options{Addr: addr})
	if err := rdb.Ping(ctx).Err(); err != nil {
		_ = rdb.Close()
		return nil, fmt.Errorf("redis: ping: %w", err)
	}
	return &Client{rdb: rdb, maxAge: maxAge}, nil
}

// Close closes the underlying client.
func (c *Client) Close() error { return c.rdb.Close() }

// evaluateStatus is the PURE fail-closed decision (no I/O) so it is unit-testable
// and its negation is provably caught (§1.1). Inputs: the profile name, the raw
// JSON bytes read from Redis (if any), whether the key was found, the current
// time, and the freshness window. Output: the snapshot to report.
//
// Rules (fail-closed):
//   - key absent              → DOWN
//   - corrupt/undecodable JSON → DOWN
//   - decoded State != up      → reported as-is (already down/unknown)
//   - decoded State == up but CheckedAt older than maxAge → downgraded to DOWN
//   - decoded State == up and fresh → reported as-is (the ONLY "up" path)
func evaluateStatus(profile string, raw []byte, found bool, now time.Time, maxAge time.Duration) vpn.HealthSnapshot {
	if !found {
		return vpn.HealthSnapshot{Profile: profile, State: vpn.StateDown, CheckedAt: now}
	}
	var snap vpn.HealthSnapshot
	if err := json.Unmarshal(raw, &snap); err != nil {
		return vpn.HealthSnapshot{Profile: profile, State: vpn.StateDown, CheckedAt: now}
	}
	if snap.Profile == "" {
		snap.Profile = profile
	}
	if snap.State != vpn.StateUp {
		return snap
	}
	if maxAge > 0 && now.Sub(snap.CheckedAt) > maxAge {
		snap.State = vpn.StateDown
		return snap
	}
	return snap
}

// SetStatus writes vpn:status:<profile> = JSON(snap) with a TTL. The TTL is what
// makes a stale key read as DOWN (it expires → GetStatus sees a miss).
func (c *Client) SetStatus(ctx context.Context, snap vpn.HealthSnapshot, ttlSeconds int) error {
	b, err := json.Marshal(snap)
	if err != nil {
		return fmt.Errorf("redis: marshal status: %w", err)
	}
	var ttl time.Duration
	if ttlSeconds > 0 {
		ttl = time.Duration(ttlSeconds) * time.Second
	}
	if err := c.rdb.Set(ctx, StatusKey(snap.Profile), b, ttl).Err(); err != nil {
		return fmt.Errorf("redis: set status: %w", err)
	}
	return nil
}

// GetStatus reads the snapshot for a profile, fail-closed: a missing or stale key
// yields a DOWN snapshot (never an error-suppressed "up").
func (c *Client) GetStatus(ctx context.Context, profile string) (vpn.HealthSnapshot, error) {
	raw, err := c.rdb.Get(ctx, StatusKey(profile)).Bytes()
	now := time.Now().UTC()
	if errors.Is(err, goredis.Nil) {
		return evaluateStatus(profile, nil, false, now, c.maxAge), nil
	}
	if err != nil {
		// A Redis transport error is itself fail-closed: report DOWN AND surface
		// the error so the caller can log/alert, but the snapshot is safe to use.
		return evaluateStatus(profile, nil, false, now, c.maxAge),
			fmt.Errorf("redis: get status: %w", err)
	}
	return evaluateStatus(profile, raw, true, now, c.maxAge), nil
}

// SetRoute writes the compiler-resolved route:<target> decision.
func (c *Client) SetRoute(ctx context.Context, r Route) error {
	b, err := json.Marshal(r)
	if err != nil {
		return fmt.Errorf("redis: marshal route: %w", err)
	}
	if err := c.rdb.Set(ctx, RouteKey(r.Target), b, 0).Err(); err != nil {
		return fmt.Errorf("redis: set route: %w", err)
	}
	return nil
}

// GetRoute reads the resolved route for a target. A miss returns ErrRouteNotFound
// (fail-closed: the helper refuses rather than guessing a route).
func (c *Client) GetRoute(ctx context.Context, target string) (Route, error) {
	raw, err := c.rdb.Get(ctx, RouteKey(target)).Bytes()
	if errors.Is(err, goredis.Nil) {
		return Route{}, ErrRouteNotFound
	}
	if err != nil {
		return Route{}, fmt.Errorf("redis: get route: %w", err)
	}
	var r Route
	if err := json.Unmarshal(raw, &r); err != nil {
		return Route{}, fmt.Errorf("redis: unmarshal route: %w", err)
	}
	return r, nil
}

// PublishEvent emits a state-change on vpn:events.
func (c *Client) PublishEvent(ctx context.Context, e Event) error {
	b, err := json.Marshal(e)
	if err != nil {
		return fmt.Errorf("redis: marshal event: %w", err)
	}
	if err := c.rdb.Publish(ctx, eventsChannel, b).Err(); err != nil {
		return fmt.Errorf("redis: publish event: %w", err)
	}
	return nil
}

// SubscribeEvents streams decoded events from vpn:events until ctx is cancelled.
// The returned channel is closed when ctx ends or the subscription drops.
// Undecodable messages are skipped (never block the stream).
func (c *Client) SubscribeEvents(ctx context.Context) (<-chan Event, error) {
	sub := c.rdb.Subscribe(ctx, eventsChannel)
	// Wait for the subscription to be established so a publish that races the
	// subscribe is not silently lost.
	if _, err := sub.Receive(ctx); err != nil {
		_ = sub.Close()
		return nil, fmt.Errorf("redis: subscribe: %w", err)
	}
	out := make(chan Event)
	go func() {
		defer close(out)
		defer func() { _ = sub.Close() }()
		ch := sub.Channel()
		for {
			select {
			case <-ctx.Done():
				return
			case msg, ok := <-ch:
				if !ok {
					return
				}
				var e Event
				if err := json.Unmarshal([]byte(msg.Payload), &e); err != nil {
					continue // skip undecodable payloads, keep the stream alive
				}
				select {
				case out <- e:
				case <-ctx.Done():
					return
				}
			}
		}
	}()
	return out, nil
}
