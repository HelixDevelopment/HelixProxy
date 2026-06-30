package main

import (
	"bufio"
	"context"
	"io"
	"os"
	"os/exec"
	"strings"
	"testing"
	"time"

	"digital.vasic.helixproxy/controlplane/internal/redis"
	"digital.vasic.helixproxy/controlplane/internal/vpn"
)

// TestIntegration_RealHelperRealRedis drives the REAL acl-helper binary over its
// REAL stdin/stdout protocol against a REAL Redis (no mocks, no string-match):
// it builds the binary, seeds route+status through the committed redis.Client,
// then asserts OK tag on a healthy tunnel and ERR (fail-closed) on down / deleted
// route. Honest §11.4.3 SKIP-with-reason when Redis is not reachable — never a
// faked PASS. Run via scripts that boot redis:7-alpine (rootless podman) and set
// REDIS_ADDR; resource-capped per §12 (GOMAXPROCS=2, nice, ionice, -p 1).
func TestIntegration_RealHelperRealRedis(t *testing.T) {
	if testing.Short() {
		t.Skip("SKIP-OK: integration test needs real Redis (omit -short)")
	}
	addr := os.Getenv("REDIS_ADDR")
	if addr == "" {
		addr = "127.0.0.1:6379"
	}

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	bus, err := redis.Open(ctx, addr, 0)
	if err != nil {
		t.Skipf("SKIP-OK (§11.4.3): Redis not reachable at %s: %v", addr, err)
	}
	defer func() { _ = bus.Close() }()

	const target = "integration-target.example"
	const tunnel = "tun_integration"

	// Seed a route + an UP status through the committed client (real writes).
	if err := bus.SetRoute(ctx, redis.Route{Target: target, Tunnel: tunnel, Tier: 0}); err != nil {
		t.Fatalf("seed route: %v", err)
	}
	if err := bus.SetStatus(ctx, vpn.HealthSnapshot{
		Profile: tunnel, State: vpn.StateUp, LastHandshake: time.Now().UTC(), Tx: 1, EgressIP: "203.0.113.7",
		CheckedAt: time.Now().UTC(),
	}, 60); err != nil {
		t.Fatalf("seed status up: %v", err)
	}

	// Build the helper binary (scoped build of this package only).
	bin := buildHelper(t)

	// Start the helper with REDIS_ADDR pointed at the real server.
	cmd := exec.CommandContext(ctx, bin)
	cmd.Env = append(cmd.Environ(), "REDIS_ADDR="+addr)
	stdin, err := cmd.StdinPipe()
	if err != nil {
		t.Fatalf("stdin pipe: %v", err)
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		t.Fatalf("stdout pipe: %v", err)
	}
	if err := cmd.Start(); err != nil {
		t.Fatalf("start helper: %v", err)
	}
	t.Cleanup(func() { _ = stdin.Close(); _ = cmd.Process.Kill(); _ = cmd.Wait() })
	br := bufio.NewReader(stdout)

	transcript := &strings.Builder{}
	ask := func(line string) string {
		if _, err := io.WriteString(stdin, line); err != nil {
			t.Fatalf("write %q: %v", line, err)
		}
		reply := readLine(t, br, 5*time.Second)
		transcript.WriteString("> " + strings.TrimRight(line, "\n") + "\n< " + reply + "\n")
		return reply
	}

	// 1) Healthy route+up -> OK tag (serial framing).
	if got := ask(target + "\n"); got != "OK tag="+tunnel {
		t.Fatalf("up serial: reply = %q, want %q", got, "OK tag="+tunnel)
	}
	// 2) Concurrency framing -> channel echoed.
	if got := ask("7 " + target + "\n"); got != "7 OK tag="+tunnel {
		t.Fatalf("up concurrency: reply = %q, want %q", got, "7 OK tag="+tunnel)
	}
	// 3) Flip the tunnel DOWN -> ERR (fail-closed, zero reconfigure).
	if err := bus.SetStatus(ctx, vpn.HealthSnapshot{Profile: tunnel, State: vpn.StateDown, CheckedAt: time.Now().UTC()}, 60); err != nil {
		t.Fatalf("flip status down: %v", err)
	}
	if got := ask(target + "\n"); got != "ERR" {
		t.Fatalf("down: reply = %q, want ERR", got)
	}
	// 4) Unknown host (no route) -> ERR.
	if got := ask("no-such-target.example\n"); got != "ERR" {
		t.Fatalf("no-route: reply = %q, want ERR", got)
	}

	t.Logf("real stdin/stdout transcript:\n%s", transcript.String())
}

func buildHelper(t *testing.T) string {
	t.Helper()
	bin := t.TempDir() + "/acl-helper"
	build := exec.Command("go", "build", "-o", bin, ".")
	if out, err := build.CombinedOutput(); err != nil {
		t.Fatalf("build helper: %v\n%s", err, out)
	}
	return bin
}

func readLine(t *testing.T, br *bufio.Reader, timeout time.Duration) string {
	t.Helper()
	type res struct {
		s   string
		err error
	}
	ch := make(chan res, 1)
	go func() {
		s, err := br.ReadString('\n')
		ch <- res{s, err}
	}()
	select {
	case r := <-ch:
		if r.err != nil && r.s == "" {
			t.Fatalf("read reply: %v", r.err)
		}
		return strings.TrimRight(r.s, "\r\n")
	case <-time.After(timeout):
		t.Fatalf("timed out waiting for helper reply")
		return ""
	}
}
