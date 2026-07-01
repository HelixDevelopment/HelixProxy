// Unit tests (no Redis, no containers, NO network — runnable under `go test
// -short`) for the transport-error / fail-closed branches of every *Client method
// that talks to go-redis. The live happy paths (a real key round-trip, a real
// pub/sub delivery) are proven by client_integration_test.go against a running
// Redis; these tests deterministically exercise the branches that DO NOT need a
// data plane — every "the command failed" error-wrap path.
//
// Technique (zero network, zero infra): a go-redis client that has ALREADY been
// Close()d short-circuits every command with goredis.ErrClosed ("redis: client is
// closed") SYNCHRONOUSLY, before any socket is opened. So a closed client is a
// deterministic, hermetic fault injector for the transport-error branch of each
// method — no dial, no timeout, no running server. Open()'s ping-failure branch
// is reached the same way via an already-cancelled context (go-redis returns the
// context error before dialing).
//
// Each assertion pins genuine behaviour (§11.4.1 no FAIL-bluff, §11.4.115): the
// specific error-wrap PREFIX proves the right branch ran, errors.Is(...,
// ErrClosed) proves the wrap preserves the chain with %w (a regression to %v
// would FAIL it), and the returned VALUE proves fail-closed (a DOWN snapshot / an
// empty Route / a nil client / a nil channel — never a leaking success value).
package redis

import (
	"context"
	"errors"
	"strings"
	"testing"
	"time"

	goredis "github.com/redis/go-redis/v9"

	"digital.vasic.helixproxy/controlplane/internal/vpn"
)

// closedClient returns a *Client whose underlying go-redis client is already
// closed, so every command it issues fails synchronously with goredis.ErrClosed —
// a hermetic transport fault, no network involved.
func closedClient(t *testing.T) *Client {
	t.Helper()
	rdb := goredis.NewClient(&goredis.Options{Addr: "127.0.0.1:6379"})
	if err := rdb.Close(); err != nil {
		t.Fatalf("pre-close of go-redis client: %v", err)
	}
	return NewClient(rdb, testMaxAge)
}

// bg returns a short-deadline context; the closed client never blocks, so the
// deadline is only a safety net against a future regression that dials.
func bg(t *testing.T) context.Context {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	t.Cleanup(cancel)
	return ctx
}

// assertClosedWrap asserts err is non-nil, carries the given wrap prefix, and
// still unwraps to goredis.ErrClosed (proving the production code wrapped with %w,
// not %v — the difference a caller's errors.Is check depends on).
func assertClosedWrap(t *testing.T, err error, wantPrefix string) {
	t.Helper()
	if err == nil {
		t.Fatalf("want a transport error wrapped %q, got nil (fail-open!)", wantPrefix)
	}
	if !strings.HasPrefix(err.Error(), wantPrefix) {
		t.Errorf("err = %q, want prefix %q", err.Error(), wantPrefix)
	}
	if !errors.Is(err, goredis.ErrClosed) {
		t.Errorf("err %q does not unwrap to goredis.ErrClosed — wrap lost the chain (%%v not %%w?)", err.Error())
	}
}

// TestWriteMethods_TransportErrorWrapped covers the error-return branch of every
// single-error write method (SetStatus for both TTL branches, SetRoute,
// PublishEvent) in one table. Each must surface a wrapped, chain-preserving error
// rather than swallowing the failure.
func TestWriteMethods_TransportErrorWrapped(t *testing.T) {
	t.Parallel()
	c := closedClient(t)
	ctx := bg(t)
	snap := vpn.HealthSnapshot{Profile: "nordvpn-uk", State: vpn.StateUp, CheckedAt: time.Now().UTC()}

	cases := []struct {
		name       string
		call       func() error
		wantPrefix string
	}{
		// ttlSeconds > 0 takes the `ttl = ...` branch before the failing Set.
		{"SetStatus ttl>0", func() error { return c.SetStatus(ctx, snap, 30) }, "redis: set status:"},
		// ttlSeconds <= 0 takes the zero-TTL branch (ttl stays 0) then the failing Set.
		{"SetStatus ttl<=0", func() error { return c.SetStatus(ctx, snap, 0) }, "redis: set status:"},
		{"SetRoute", func() error { return c.SetRoute(ctx, Route{Target: "api.internal", Tunnel: "nordvpn-uk"}) }, "redis: set route:"},
		{"PublishEvent", func() error { return c.PublishEvent(ctx, Event{ProfileID: "nordvpn-uk", State: vpn.StateDown}) }, "redis: publish event:"},
	}
	for _, tc := range cases {
		tc := tc
		t.Run(tc.name, func(t *testing.T) {
			assertClosedWrap(t, tc.call(), tc.wantPrefix)
		})
	}
}

// TestGetStatus_ClosedClientFailsClosed proves the transport-error branch of
// GetStatus: a non-Nil error (here ErrClosed) must yield a DOWN snapshot AND
// surface the wrapped error — never a silent "up". (Complements the
// closed-port-dial variant in client_failclosed_error_test.go with a zero-network
// path.)
func TestGetStatus_ClosedClientFailsClosed(t *testing.T) {
	t.Parallel()
	c := closedClient(t)

	snap, err := c.GetStatus(bg(t), "nordvpn-uk")
	assertClosedWrap(t, err, "redis: get status:")
	if snap.State != vpn.StateDown {
		t.Errorf("transport error must be fail-closed DOWN, got %q", snap.State)
	}
	if snap.Profile != "nordvpn-uk" {
		t.Errorf("snapshot must still be labelled with the profile, got %q", snap.Profile)
	}
}

// TestGetRoute_ClosedClientErrorWrapped proves GetRoute's non-Nil transport-error
// branch (distinct from the goredis.Nil→ErrRouteNotFound miss branch): the error
// is wrapped and the returned Route is the zero value (no partially-populated
// route leaks out on failure).
func TestGetRoute_ClosedClientErrorWrapped(t *testing.T) {
	t.Parallel()
	c := closedClient(t)

	r, err := c.GetRoute(bg(t), "api.internal")
	assertClosedWrap(t, err, "redis: get route:")
	// Fail-closed: not the ErrRouteNotFound miss, and no leaked route.
	if errors.Is(err, ErrRouteNotFound) {
		t.Error("transport error must NOT be reported as ErrRouteNotFound (that is the miss branch)")
	}
	if r != (Route{}) {
		t.Errorf("failed GetRoute must return the zero Route, got %+v", r)
	}
}

// TestSubscribeEvents_ClosedClientErrorWrapped proves SubscribeEvents surfaces the
// establish-subscription failure (sub.Receive) as a wrapped error and returns a
// nil channel — a caller must never receive a live-looking channel it can range
// over when the subscription never established.
func TestSubscribeEvents_ClosedClientErrorWrapped(t *testing.T) {
	t.Parallel()
	c := closedClient(t)

	ch, err := c.SubscribeEvents(bg(t))
	assertClosedWrap(t, err, "redis: subscribe:")
	if ch != nil {
		t.Error("failed SubscribeEvents must return a nil channel, got a non-nil one")
	}
}

// TestOpen_PingFailureWrapped proves Open's ping-guard branch: when the PING fails
// (here via an already-cancelled context, so no dial is attempted), Open must
// return a nil *Client AND a wrapped "redis: ping:" error — it must not hand back
// a usable-looking client whose connectivity was never verified (spec §7 / §10).
func TestOpen_PingFailureWrapped(t *testing.T) {
	t.Parallel()
	ctx, cancel := context.WithCancel(context.Background())
	cancel() // pre-cancel: go-redis returns the ctx error before opening a socket.

	c, err := Open(ctx, "127.0.0.1:6379", testMaxAge)
	if err == nil {
		t.Fatal("Open with a failing ping = nil error, want a wrapped ping error")
	}
	if !strings.HasPrefix(err.Error(), "redis: ping:") {
		t.Errorf("err = %q, want prefix %q", err.Error(), "redis: ping:")
	}
	if !errors.Is(err, context.Canceled) {
		t.Errorf("err %q must unwrap to context.Canceled (wrap must use %%w)", err.Error())
	}
	if c != nil {
		t.Errorf("Open must return a nil client when PING fails, got %+v", c)
	}
}

// TestClose_FreshClientSucceeds proves Close's success path: a fresh, never-dialed
// client closes cleanly (nil). This is the counterpart to the closed-client error
// paths above — Close itself must not error on a healthy client.
func TestClose_FreshClientSucceeds(t *testing.T) {
	t.Parallel()
	rdb := goredis.NewClient(&goredis.Options{Addr: "127.0.0.1:6379"})
	c := NewClient(rdb, testMaxAge)
	if err := c.Close(); err != nil {
		t.Errorf("Close() on a fresh client = %v, want nil", err)
	}
}
