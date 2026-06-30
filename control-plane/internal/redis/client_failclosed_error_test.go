// Failure-mode (c) coverage (§11.4.146 extend-to-all-cases): a Redis transport
// error MUST resolve to StateDown (fail-closed), never fall through to a leaking
// "up". Deterministic + fast — dials a guaranteed-closed local port (connection
// refused), no running Redis required.
package redis

import (
	"context"
	"net"
	"testing"
	"time"

	goredis "github.com/redis/go-redis/v9"

	"digital.vasic.helixproxy/controlplane/internal/vpn"
)

// closedPort returns a TCP port that was just opened and closed, so a dial to it
// is refused immediately (no server listening).
func closedPort(t *testing.T) int {
	t.Helper()
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("closedPort: %v", err)
	}
	p := l.Addr().(*net.TCPAddr).Port
	_ = l.Close()
	return p
}

// TestGetStatus_RedisUnreachableIsDown proves failure-mode (c): when Redis is
// unreachable, GetStatus returns a StateDown snapshot AND surfaces the error.
func TestGetStatus_RedisUnreachableIsDown(t *testing.T) {
	t.Parallel()
	addr := net.JoinHostPort("127.0.0.1", itoa(closedPort(t)))
	rdb := goredis.NewClient(&goredis.Options{
		Addr:         addr,
		DialTimeout:  300 * time.Millisecond,
		ReadTimeout:  300 * time.Millisecond,
		WriteTimeout: 300 * time.Millisecond,
		MaxRetries:   -1, // fail fast, no retry storm
	})
	defer rdb.Close()
	c := NewClient(rdb, testMaxAge)

	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()

	snap, err := c.GetStatus(ctx, "nordvpn-uk")
	if err == nil {
		t.Fatal("expected a transport error from unreachable Redis, got nil")
	}
	if snap.State != vpn.StateDown {
		t.Fatalf("redis-unreachable must be fail-closed DOWN, got %q", snap.State)
	}
	if snap.Profile != "nordvpn-uk" {
		t.Errorf("snapshot should still be labelled with the profile, got %q", snap.Profile)
	}
}

func itoa(i int) string {
	if i == 0 {
		return "0"
	}
	var b [20]byte
	pos := len(b)
	for i > 0 {
		pos--
		b[pos] = byte('0' + i%10)
		i /= 10
	}
	return string(b[pos:])
}
