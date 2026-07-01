// Hermetic unit tests (no Redis, no signals, no network): the stdin/stdout
// protocol loop, the per-request timeout wrapper's empty-host short-circuit, and
// the env helpers. A fake Bus (redis.StatusBus subset) drives the fail-closed
// decision through real os.Pipe stdin/stdout so the wiring in loop/decideWithTimeout
// is exercised end-to-end WITHOUT a live server (mocks/fakes are permitted only in
// these _test.go unit tests, §11.4.27). Runnable + race-clean under `go test -short`.
package main

import (
	"context"
	"io"
	"os"
	"strings"
	"testing"
	"time"

	"digital.vasic.helixproxy/controlplane/internal/aclhelper"
	"digital.vasic.helixproxy/controlplane/internal/redis"
	"digital.vasic.helixproxy/controlplane/internal/vpn"
)

// fakeBus is a map-backed redis-free implementation of aclhelper.Bus. A miss on
// GetRoute is redis.ErrRouteNotFound (fail-closed); GetStatus defaults an unknown
// profile to StateDown. When forbid is set, ANY call fails the test — used to
// prove decideWithTimeout short-circuits an empty host without touching Redis.
type fakeBus struct {
	routes   map[string]redis.Route
	statuses map[string]vpn.State
	forbid   *testing.T
}

func (f *fakeBus) GetRoute(_ context.Context, target string) (redis.Route, error) {
	if f.forbid != nil {
		f.forbid.Fatalf("GetRoute(%q) called but the decision should have short-circuited", target)
	}
	if r, ok := f.routes[target]; ok {
		return r, nil
	}
	return redis.Route{}, redis.ErrRouteNotFound
}

func (f *fakeBus) GetStatus(_ context.Context, profile string) (vpn.HealthSnapshot, error) {
	if f.forbid != nil {
		f.forbid.Fatalf("GetStatus(%q) called but the decision should have short-circuited", profile)
	}
	st, ok := f.statuses[profile]
	if !ok {
		st = vpn.StateDown
	}
	return vpn.HealthSnapshot{Profile: profile, State: st, CheckedAt: time.Now().UTC()}, nil
}

// upDecider returns a Decider whose fake Bus routes "up-host" → an UP tunnel and
// "down-host" → a DOWN tunnel; every other host is a route miss (ERR).
func upDecider() aclhelper.Decider {
	return aclhelper.Decider{Bus: &fakeBus{
		routes: map[string]redis.Route{
			"up-host":   {Target: "up-host", Tunnel: "tun_up"},
			"down-host": {Target: "down-host", Tunnel: "tun_down"},
		},
		statuses: map[string]vpn.State{
			"tun_up":   vpn.StateUp,
			"tun_down": vpn.StateDown,
		},
	}}
}

// TestLoop_ProtocolRoundTrip drives loop over real os.Pipe stdin/stdout across
// BOTH serial and concurrency framing and asserts the exact per-line replies:
// a healthy route → OK tag, concurrency echoes the channel-id, a down tunnel and
// a route miss and a blank line all fail closed to ERR. Proves the read→decide→
// write→flush wiring, not just the pure decision.
func TestLoop_ProtocolRoundTrip(t *testing.T) {
	inR, inW, err := osPipe(t)
	if err != nil {
		t.Fatalf("in pipe: %v", err)
	}
	outR, outW, err := osPipe(t)
	if err != nil {
		t.Fatalf("out pipe: %v", err)
	}

	// Buffer all input then EOF; loop drains the kernel pipe buffer (well under
	// 64 KiB) so no reader goroutine is needed — single-goroutine, race-clean.
	input := "up-host\n" + // serial, healthy       → OK tag=tun_up
		"7 up-host\n" + //    concurrency, healthy   → 7 OK tag=tun_up
		"down-host\n" + //    tunnel DOWN            → ERR (fail-closed)
		"no-route\n" + //     route miss             → ERR
		"\n" //               blank line (empty host)→ ERR
	if _, err := io.WriteString(inW, input); err != nil {
		t.Fatalf("write input: %v", err)
	}
	_ = inW.Close()

	if err := loop(context.Background(), upDecider(), inR, outW, 2*time.Second); err != nil {
		t.Fatalf("loop returned error on clean EOF: %v", err)
	}
	_ = outW.Close()

	out, err := io.ReadAll(outR)
	if err != nil {
		t.Fatalf("read replies: %v", err)
	}
	got := strings.Split(strings.TrimRight(string(out), "\n"), "\n")
	want := []string{
		"OK tag=tun_up",
		"7 OK tag=tun_up",
		"ERR",
		"ERR",
		"ERR",
	}
	if len(got) != len(want) {
		t.Fatalf("reply count = %d %q, want %d %q", len(got), got, len(want), want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Errorf("reply[%d] = %q, want %q", i, got[i], want[i])
		}
	}
}

// TestLoop_ContextCancelledReturnsCleanly proves the top-of-loop ctx.Err() guard:
// a pre-cancelled context returns nil immediately and writes NO reply, even with
// input waiting on the pipe.
func TestLoop_ContextCancelledReturnsCleanly(t *testing.T) {
	inR, inW, err := osPipe(t)
	if err != nil {
		t.Fatalf("in pipe: %v", err)
	}
	outR, outW, err := osPipe(t)
	if err != nil {
		t.Fatalf("out pipe: %v", err)
	}
	if _, err := io.WriteString(inW, "up-host\n"); err != nil {
		t.Fatalf("write input: %v", err)
	}
	_ = inW.Close()

	ctx, cancel := context.WithCancel(context.Background())
	cancel() // cancelled before loop runs

	if err := loop(ctx, upDecider(), inR, outW, 2*time.Second); err != nil {
		t.Fatalf("loop on cancelled ctx = %v, want nil", err)
	}
	_ = outW.Close()

	out, err := io.ReadAll(outR)
	if err != nil {
		t.Fatalf("read replies: %v", err)
	}
	if len(out) != 0 {
		t.Errorf("cancelled loop wrote %q, want no output", out)
	}
}

// TestLoop_FlushErrorSurfaces proves the flush-error branch: when stdout's reader
// is gone (broken pipe), loop returns a non-nil "reply" write/flush error instead
// of silently swallowing it.
func TestLoop_FlushErrorSurfaces(t *testing.T) {
	inR, inW, err := osPipe(t)
	if err != nil {
		t.Fatalf("in pipe: %v", err)
	}
	outR, outW, err := osPipe(t)
	if err != nil {
		t.Fatalf("out pipe: %v", err)
	}
	_ = outR.Close() // reader gone → subsequent writes to outW fail (EPIPE)

	if _, err := io.WriteString(inW, "up-host\n"); err != nil {
		t.Fatalf("write input: %v", err)
	}
	_ = inW.Close()

	err = loop(context.Background(), upDecider(), inR, outW, 2*time.Second)
	if err == nil {
		t.Fatal("loop must surface the broken-pipe write/flush error, got nil")
	}
	if !strings.Contains(err.Error(), "reply") {
		t.Errorf("error = %v, want a write/flush 'reply' error", err)
	}
	_ = outW.Close()
}

// TestDecideWithTimeout covers both branches: an empty host short-circuits to ERR
// WITHOUT touching Redis (the fake fails the test if called), and a non-empty host
// runs the real timed decision through the fake Bus.
func TestDecideWithTimeout(t *testing.T) {
	t.Run("empty host short-circuits without touching Redis", func(t *testing.T) {
		dec := aclhelper.Decider{Bus: &fakeBus{forbid: t}}
		ok, tag := decideWithTimeout(context.Background(), dec, "", time.Second)
		if ok || tag != "" {
			t.Errorf("empty host = (%v,%q), want (false,\"\")", ok, tag)
		}
	})
	t.Run("healthy host yields OK tag", func(t *testing.T) {
		ok, tag := decideWithTimeout(context.Background(), upDecider(), "up-host", time.Second)
		if !ok || tag != "tun_up" {
			t.Errorf("healthy host = (%v,%q), want (true,\"tun_up\")", ok, tag)
		}
	})
	t.Run("down tunnel fails closed", func(t *testing.T) {
		ok, tag := decideWithTimeout(context.Background(), upDecider(), "down-host", time.Second)
		if ok || tag != "" {
			t.Errorf("down tunnel = (%v,%q), want (false,\"\")", ok, tag)
		}
	})
}

// TestEnvOr covers the set and unset branches. Not parallel: uses t.Setenv.
func TestEnvOr(t *testing.T) {
	const key = "HELIX_TEST_ENVOR_KEY"
	os.Unsetenv(key)
	if got := envOr(key, "fallback"); got != "fallback" {
		t.Errorf("unset envOr = %q, want fallback", got)
	}
	t.Setenv(key, "explicit")
	if got := envOr(key, "fallback"); got != "explicit" {
		t.Errorf("set envOr = %q, want explicit", got)
	}
}

// TestEnvDuration covers unset→default, a valid duration, and an unparseable value
// falling back to the default (the error branch). Not parallel: uses t.Setenv.
func TestEnvDuration(t *testing.T) {
	const key = "HELIX_TEST_ENVDURATION_KEY"
	def := 5 * time.Second

	os.Unsetenv(key)
	if got := envDuration(key, def); got != def {
		t.Errorf("unset envDuration = %v, want %v", got, def)
	}

	t.Setenv(key, "250ms")
	if got := envDuration(key, def); got != 250*time.Millisecond {
		t.Errorf("valid envDuration = %v, want 250ms", got)
	}

	t.Setenv(key, "not-a-duration")
	if got := envDuration(key, def); got != def {
		t.Errorf("unparseable envDuration = %v, want default %v (fallback)", got, def)
	}
}

// osPipe is a tiny wrapper so a failed os.Pipe registers cleanup and a clear error.
func osPipe(t *testing.T) (r *os.File, w *os.File, err error) {
	t.Helper()
	r, w, err = os.Pipe()
	if err == nil {
		t.Cleanup(func() { _ = r.Close(); _ = w.Close() })
	}
	return r, w, err
}
