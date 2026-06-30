// Integration tests against a REAL Redis booted on-demand via rootless podman
// (redis:7-alpine). No mocks (§11.4.27). Exercises real SET/GET, real TTL-expiry
// fail-closed (the §10 contract proven against the actual server, not a fake
// clock), real route SET/GET, and real PUBLISH/SUBSCRIBE. SKIPs with a reason
// (§11.4.3) if podman or the container is unavailable; skipped under -short.
package redis

import (
	"context"
	"fmt"
	"net"
	"os/exec"
	"testing"
	"time"

	"digital.vasic.helixproxy/controlplane/internal/vpn"
)

func bootRedis(t *testing.T) *Client {
	t.Helper()
	if testing.Short() {
		t.Skip("integration: skipped under -short")
	}
	podman, err := exec.LookPath("podman")
	if err != nil {
		t.Skipf("integration SKIP: podman not on PATH (%v)", err)
	}
	port := freePortRedis(t)
	name := fmt.Sprintf("hp-it-redis-%d", port)

	run := exec.Command(podman, "run", "-d", "--rm", "--name", name,
		"-p", fmt.Sprintf("127.0.0.1:%d:6379", port),
		"redis:7-alpine")
	if out, err := run.CombinedOutput(); err != nil {
		t.Skipf("integration SKIP: cannot start redis container: %v\n%s", err, out)
	}
	t.Cleanup(func() { _ = exec.Command(podman, "rm", "-f", name).Run() })

	addr := fmt.Sprintf("127.0.0.1:%d", port)
	deadline := time.Now().Add(30 * time.Second)
	var c *Client
	for time.Now().Before(deadline) {
		cctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
		c, err = Open(cctx, addr, 30*time.Second)
		cancel()
		if err == nil {
			break
		}
		time.Sleep(500 * time.Millisecond)
	}
	if c == nil {
		t.Skipf("integration SKIP: redis not ready within deadline (last err: %v)", err)
	}
	t.Cleanup(func() { _ = c.Close() })
	return c
}

func TestIntegrationRedis_StatusRoundTrip(t *testing.T) {
	c := bootRedis(t)
	ctx := context.Background()

	snap := vpn.HealthSnapshot{
		Profile: "nordvpn-uk", State: vpn.StateUp, Rx: 1000, Tx: 2000,
		EgressIP: "203.0.113.9", CheckedAt: time.Now().UTC(), LastHandshake: time.Now().UTC(),
	}
	if err := c.SetStatus(ctx, snap, 60); err != nil {
		t.Fatalf("SetStatus: %v", err)
	}
	got, err := c.GetStatus(ctx, "nordvpn-uk")
	if err != nil {
		t.Fatalf("GetStatus: %v", err)
	}
	if got.State != vpn.StateUp || got.EgressIP != "203.0.113.9" || got.Rx != 1000 || got.Tx != 2000 {
		t.Errorf("status round-trip mismatch: %+v", got)
	}

	// Missing profile is fail-closed DOWN against the real server.
	miss, err := c.GetStatus(ctx, "does-not-exist")
	if err != nil {
		t.Fatalf("GetStatus(missing): %v", err)
	}
	if miss.State != vpn.StateDown {
		t.Errorf("missing key must be DOWN, got %q", miss.State)
	}
}

// TestIntegrationRedis_TTLExpiryIsFailClosed proves the §10 TTL contract against
// the REAL server: an up-snapshot written with a 1s TTL reads UP, then after the
// key expires the SAME GetStatus reads DOWN — no fake clock, real Redis expiry.
func TestIntegrationRedis_TTLExpiryIsFailClosed(t *testing.T) {
	c := bootRedis(t)
	ctx := context.Background()

	snap := vpn.HealthSnapshot{Profile: "ephemeral", State: vpn.StateUp, CheckedAt: time.Now().UTC()}
	if err := c.SetStatus(ctx, snap, 1); err != nil { // 1-second TTL
		t.Fatalf("SetStatus: %v", err)
	}
	up, err := c.GetStatus(ctx, "ephemeral")
	if err != nil || up.State != vpn.StateUp {
		t.Fatalf("pre-expiry must be UP: state=%q err=%v", up.State, err)
	}

	// Wait past the TTL; the real server drops the key.
	time.Sleep(1500 * time.Millisecond)

	down, err := c.GetStatus(ctx, "ephemeral")
	if err != nil {
		t.Fatalf("post-expiry GetStatus: %v", err)
	}
	if down.State != vpn.StateDown {
		t.Errorf("after TTL expiry the key must read DOWN (fail-closed), got %q", down.State)
	}
}

func TestIntegrationRedis_RouteRoundTrip(t *testing.T) {
	c := bootRedis(t)
	ctx := context.Background()

	if _, err := c.GetRoute(ctx, "absent"); err != ErrRouteNotFound {
		t.Errorf("missing route: want ErrRouteNotFound, got %v", err)
	}
	r := Route{Target: "api.internal", Tunnel: "nordvpn-uk", Tier: 0, BreakerState: "closed"}
	if err := c.SetRoute(ctx, r); err != nil {
		t.Fatalf("SetRoute: %v", err)
	}
	got, err := c.GetRoute(ctx, "api.internal")
	if err != nil {
		t.Fatalf("GetRoute: %v", err)
	}
	if got != r {
		t.Errorf("route round-trip mismatch: %+v != %+v", got, r)
	}
}

// TestIntegrationRedis_PubSub proves real PUBLISH/SUBSCRIBE: a published event is
// delivered, decoded, on the subscriber channel.
func TestIntegrationRedis_PubSub(t *testing.T) {
	c := bootRedis(t)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	events, err := c.SubscribeEvents(ctx)
	if err != nil {
		t.Fatalf("SubscribeEvents: %v", err)
	}

	want := Event{ProfileID: "nordvpn-uk", State: vpn.StateDown}
	// Brief settle, then publish.
	time.Sleep(200 * time.Millisecond)
	if err := c.PublishEvent(ctx, want); err != nil {
		t.Fatalf("PublishEvent: %v", err)
	}

	select {
	case got, ok := <-events:
		if !ok {
			t.Fatal("event channel closed before delivery")
		}
		if got != want {
			t.Errorf("received %+v, want %+v", got, want)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("timed out waiting for published event")
	}
}

func freePortRedis(t *testing.T) int {
	t.Helper()
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("freePort: %v", err)
	}
	defer l.Close()
	return l.Addr().(*net.TCPAddr).Port
}
