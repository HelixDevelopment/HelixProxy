// Integration + chaos tests against a REAL gluetun (qmcgaw/gluetun:v3.40) and a
// REAL redis:7-alpine, booted on-demand via rootless podman (§11.4.27 / §11.4.76).
// No mocks. Host-safety (§12.9): df guard before any pull, images pulled
// sequentially, all `--rm`, all containers removed via t.Cleanup, GOMAXPROCS-bound
// by the runner. The operator's own containers/interfaces are NEVER touched
// (§11.4.174 — we only create + remove `hp-it-*` names we own).
//
// The anti-bluff proof (§11.4.107 / §11.4.69): gluetun with a FAKE custom-WireGuard
// config answers its control API with HTTP 200 but an EMPTY public_ip (no real
// egress, confirmed in spike G4). healthd MUST therefore write a DOWN snapshot —
// "the API said running" is NOT "up". SKIPs with a reason (§11.4.3) when podman /
// the images are unavailable; skipped under -short.
package main

import (
	"context"
	"fmt"
	"net"
	"net/http"
	"os/exec"
	"testing"
	"time"

	"digital.vasic.helixproxy/controlplane/internal/redis"
	"digital.vasic.helixproxy/controlplane/internal/vpn"
)

// A syntactically valid (length-correct, base64) but BOGUS WireGuard key — enough
// for gluetun to start its control server without a real tunnel (spike G4).
const (
	fakeWGPriv = "QODfjyV0bXFvVX9RVy5pIkPCQ8Yt3DkpVcF6h0Bv1n8="
	fakeWGPub  = "K3KQ2zZ8aXdvVX+RVy5pIkPCQ8Yt3DkpVcF6h0Bv2m4="
)

func freePort(t *testing.T) int {
	t.Helper()
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("freePort: %v", err)
	}
	defer l.Close()
	return l.Addr().(*net.TCPAddr).Port
}

func requirePodman(t *testing.T) string {
	t.Helper()
	if testing.Short() {
		t.Skip("integration: skipped under -short")
	}
	podman, err := exec.LookPath("podman")
	if err != nil {
		t.Skipf("integration SKIP (§11.4.3): podman not on PATH: %v", err)
	}
	return podman
}

func bootRedis(t *testing.T, podman string) (addr string) {
	t.Helper()
	port := freePort(t)
	name := fmt.Sprintf("hp-it-healthd-redis-%d", port)
	run := exec.Command(podman, "run", "-d", "--rm", "--name", name,
		"-p", fmt.Sprintf("127.0.0.1:%d:6379", port), "redis:7-alpine")
	if out, err := run.CombinedOutput(); err != nil {
		t.Skipf("integration SKIP: cannot start redis: %v\n%s", err, out)
	}
	t.Cleanup(func() { _ = exec.Command(podman, "rm", "-f", name).Run() })
	addr = fmt.Sprintf("127.0.0.1:%d", port)
	// readiness
	deadline := time.Now().Add(30 * time.Second)
	for time.Now().Before(deadline) {
		cctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
		c, err := redis.Open(cctx, addr, time.Minute)
		cancel()
		if err == nil {
			_ = c.Close()
			return addr
		}
		time.Sleep(400 * time.Millisecond)
	}
	t.Skip("integration SKIP: redis not ready within deadline")
	return ""
}

// bootGluetun starts gluetun:v3.40 with a fake custom-WireGuard config and returns
// the control-API base URL + the container name. It waits for the control server
// to answer. SKIPs (never fails) if the image/container/cap is unavailable.
func bootGluetun(t *testing.T, podman string) (baseURL, name string) {
	t.Helper()
	port := freePort(t)
	name = fmt.Sprintf("hp-it-healthd-gluetun-%d", port)
	run := exec.Command(podman, "run", "-d", "--rm", "--name", name,
		"--cap-add", "NET_ADMIN", "--device", "/dev/net/tun",
		"-p", fmt.Sprintf("127.0.0.1:%d:8000", port),
		"-e", "VPN_SERVICE_PROVIDER=custom",
		"-e", "VPN_TYPE=wireguard",
		"-e", "VPN_ENDPOINT_IP=127.0.0.1",
		"-e", "VPN_ENDPOINT_PORT=51820",
		"-e", "WIREGUARD_PUBLIC_KEY="+fakeWGPub,
		"-e", "WIREGUARD_PRIVATE_KEY="+fakeWGPriv,
		"-e", "WIREGUARD_ADDRESSES=10.64.0.2/32",
		"-e", "FIREWALL=off",
		"-e", "DOT=off",
		"qmcgaw/gluetun:v3.40")
	if out, err := run.CombinedOutput(); err != nil {
		t.Skipf("integration SKIP: cannot start gluetun: %v\n%s", err, out)
	}
	t.Cleanup(func() { _ = exec.Command(podman, "rm", "-f", name).Run() })

	baseURL = fmt.Sprintf("http://127.0.0.1:%d", port)
	httpc := &http.Client{Timeout: 2 * time.Second}
	deadline := time.Now().Add(45 * time.Second)
	for time.Now().Before(deadline) {
		req, _ := http.NewRequest(http.MethodGet, baseURL+"/v1/vpn/status", nil)
		resp, err := httpc.Do(req)
		if err == nil {
			_ = resp.Body.Close()
			if resp.StatusCode == http.StatusOK {
				return baseURL, name
			}
		}
		time.Sleep(700 * time.Millisecond)
	}
	t.Skip("integration SKIP: gluetun control API not ready within deadline")
	return "", ""
}

// TestIntegration_HealthdWritesDownAgainstRealGluetun is the end-to-end fail-closed
// proof: real gluetun (empty egress) + real redis → healthd writes DOWN and
// publishes a down transition on vpn:events.
func TestIntegration_HealthdWritesDownAgainstRealGluetun(t *testing.T) {
	podman := requirePodman(t)
	redisAddr := bootRedis(t, podman) // boot redis first (sequential pulls)
	base, _ := bootGluetun(t, podman)

	rc, err := redis.Open(context.Background(), redisAddr, time.Minute)
	if err != nil {
		t.Fatalf("open redis: %v", err)
	}
	defer func() { _ = rc.Close() }()

	// Sanity: the control API really answers 200 with an EMPTY public_ip (the
	// don't-be-fooled fact). If gluetun got a real egress somehow, this is no
	// longer the no-egress scenario — surface it rather than assert blindly.
	ctrl := vpn.NewControlClient(base)
	ip, _ := ctrl.EgressIP(context.Background(), "demo")
	t.Logf("gluetun control API reachable; observed egress public_ip=%q (expected empty — no real tunnel)", ip)

	c := config{interval: 1 * time.Second, ttlSeconds: 5, freshness: 180 * time.Second, hostIP: ""}
	s := liveSampler{ctrl: ctrl, wg: vpn.WGReader{}, ifName: "wg0"}

	// Subscribe BEFORE the loop so the unknown→down transition event is captured.
	subCtx, subCancel := context.WithCancel(context.Background())
	defer subCancel()
	events, err := rc.SubscribeEvents(subCtx)
	if err != nil {
		t.Fatalf("subscribe: %v", err)
	}
	time.Sleep(200 * time.Millisecond) // let subscription settle

	loopCtx, loopCancel := context.WithCancel(context.Background())
	go runProfile(loopCtx, c, "demo", s, vpn.DataPlaneEvaluator{Freshness: c.freshness}, rc)

	// Wait for a couple of polls, then read the status the loop wrote.
	time.Sleep(2500 * time.Millisecond)
	got, err := rc.GetStatus(context.Background(), "demo")
	loopCancel()
	if err != nil {
		t.Fatalf("GetStatus: %v", err)
	}
	if got.State != vpn.StateDown {
		t.Fatalf("ANTI-BLUFF FAIL: real gluetun with no egress must yield DOWN, got %+v", got)
	}
	if got.EgressIP != "" {
		t.Logf("note: egress was non-empty (%q) yet verdict DOWN — wg byte-delta/handshake absent, still correctly fail-closed", got.EgressIP)
	}
	t.Logf("PASS: healthd wrote DOWN snapshot for real gluetun (no real egress): %+v", got)

	// Confirm the unknown→down transition was published on the real bus.
	select {
	case ev, ok := <-events:
		if !ok {
			t.Fatal("event channel closed before delivery")
		}
		if ev.State != vpn.StateDown || ev.ProfileID != "demo" {
			t.Errorf("first event = %+v, want {demo down}", ev)
		}
		t.Logf("PASS: down transition published on vpn:events: %+v", ev)
	case <-time.After(5 * time.Second):
		t.Fatal("timed out waiting for the down transition event")
	}
}

// TestChaos_RealGluetunStoppedMidLoopStaysDown stops the real gluetun container
// mid-loop and proves the loop handles the disappearance fail-closed: it keeps
// writing fresh DOWN snapshots (advancing CheckedAt) and never flips to UP. This
// is real-container chaos (process-death injection, §11.4.85).
func TestChaos_RealGluetunStoppedMidLoopStaysDown(t *testing.T) {
	podman := requirePodman(t)
	redisAddr := bootRedis(t, podman)
	base, gluetunName := bootGluetun(t, podman)

	rc, err := redis.Open(context.Background(), redisAddr, time.Minute)
	if err != nil {
		t.Fatalf("open redis: %v", err)
	}
	defer func() { _ = rc.Close() }()

	c := config{interval: 1 * time.Second, ttlSeconds: 5, freshness: 180 * time.Second}
	s := liveSampler{ctrl: vpn.NewControlClient(base), wg: vpn.WGReader{}, ifName: "wg0"}

	loopCtx, loopCancel := context.WithCancel(context.Background())
	defer loopCancel()
	go runProfile(loopCtx, c, "demo", s, vpn.DataPlaneEvaluator{Freshness: c.freshness}, rc)

	// Let it poll the live container a couple of times (DOWN, no egress).
	time.Sleep(2 * time.Second)
	pre, _ := rc.GetStatus(context.Background(), "demo")
	if pre.State != vpn.StateDown {
		t.Fatalf("pre-chaos state must be DOWN, got %+v", pre)
	}

	// CHAOS: kill the gluetun container mid-loop (we only ever touch our own name).
	if out, err := exec.Command(podman, "rm", "-f", gluetunName).CombinedOutput(); err != nil {
		t.Skipf("chaos SKIP: could not stop gluetun: %v\n%s", err, out)
	}
	t.Logf("CHAOS: stopped gluetun container %s mid-loop", gluetunName)

	// After the container is gone, the egress probe errors → sample errors →
	// fresh DOWN snapshots. Assert the loop keeps writing DOWN with an advancing
	// CheckedAt (it did not crash, did not flip UP, did not go stale).
	time.Sleep(3 * time.Second)
	post, err := rc.GetStatus(context.Background(), "demo")
	if err != nil {
		t.Fatalf("post-chaos GetStatus: %v", err)
	}
	if post.State != vpn.StateDown {
		t.Fatalf("post-chaos state must stay DOWN, got %+v", post)
	}
	if !post.CheckedAt.After(pre.CheckedAt) {
		t.Errorf("loop should keep writing fresh DOWN snapshots after container death: pre=%v post=%v",
			pre.CheckedAt, post.CheckedAt)
	}
	t.Logf("PASS: loop stayed DOWN + fresh after gluetun death (pre=%v post=%v)", pre.CheckedAt, post.CheckedAt)
}
