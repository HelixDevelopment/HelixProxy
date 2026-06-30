// Integration test for the compiler BINARY's run() path (deliverable #2: real
// Redis route:<target> seeding) — end-to-end against REAL postgres + REAL redis
// booted via rootless podman, and a REAL Squid parse of the WRITTEN include
// (§11.4.69 data-plane proof; §11.4.27 no mocks). run() reads the seeded data
// model, writes the Squid include / concatenated Dante config / PAC, and seeds the
// resolved routes into Redis; this test reads them back and parses the include.
// SKIPs with a reason (§11.4.3) if podman / an image is unavailable; under -short.
package main

import (
	"bytes"
	"context"
	"fmt"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"digital.vasic.helixproxy/controlplane/internal/redis"
)

const (
	schemaRel    = "../../../sql/schema.sql"
	seedRel      = "../../../sql/seed_example.sql"
	danteBaseRel = "../../../config/dante/sockd.conf"
	squidImage   = "docker.io/ubuntu/squid:latest"
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

func bootPG(t *testing.T, podman string) (dsn, name string) {
	t.Helper()
	port := freePort(t)
	name = fmt.Sprintf("hp-it-cc-pg-%d", port)
	if out, err := exec.Command(podman, "run", "-d", "--rm", "--name", name,
		"-e", "POSTGRES_PASSWORD=postgres", "-e", "POSTGRES_DB=postgres",
		"-p", fmt.Sprintf("127.0.0.1:%d:5432", port), "postgres:16-alpine").CombinedOutput(); err != nil {
		t.Skipf("integration SKIP: cannot start postgres: %v\n%s", err, out)
	}
	t.Cleanup(func() { _ = exec.Command(podman, "rm", "-f", name).Run() })
	dsn = fmt.Sprintf("postgres://postgres:postgres@127.0.0.1:%d/postgres?sslmode=disable", port)

	deadline := time.Now().Add(60 * time.Second)
	ready := false
	for time.Now().Before(deadline) {
		if exec.Command(podman, "exec", name, "pg_isready", "-U", "postgres", "-h", "127.0.0.1").Run() == nil {
			ready = true
			break
		}
		time.Sleep(750 * time.Millisecond)
	}
	if !ready {
		t.Skip("integration SKIP: postgres not ready within deadline")
	}
	for _, f := range []string{schemaRel, seedRel} {
		sql, err := os.ReadFile(f)
		if err != nil {
			t.Skipf("integration SKIP: read %s: %v", f, err)
		}
		apply := exec.Command(podman, "exec", "-i", name, "psql", "-U", "postgres", "-d", "postgres", "-v", "ON_ERROR_STOP=1")
		apply.Stdin = bytes.NewReader(sql)
		if out, err := apply.CombinedOutput(); err != nil {
			t.Fatalf("apply %s: %v\n%s", f, err, out)
		}
	}
	return dsn, name
}

func bootRedis(t *testing.T, podman string) string {
	t.Helper()
	port := freePort(t)
	name := fmt.Sprintf("hp-it-cc-redis-%d", port)
	if out, err := exec.Command(podman, "run", "-d", "--rm", "--name", name,
		"-p", fmt.Sprintf("127.0.0.1:%d:6379", port), "redis:7-alpine").CombinedOutput(); err != nil {
		t.Skipf("integration SKIP: cannot start redis: %v\n%s", err, out)
	}
	t.Cleanup(func() { _ = exec.Command(podman, "rm", "-f", name).Run() })
	addr := fmt.Sprintf("127.0.0.1:%d", port)
	deadline := time.Now().Add(30 * time.Second)
	for time.Now().Before(deadline) {
		cctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
		c, err := redis.Open(cctx, addr, 0)
		cancel()
		if err == nil {
			_ = c.Close()
			return addr
		}
		time.Sleep(500 * time.Millisecond)
	}
	t.Skip("integration SKIP: redis not ready within deadline")
	return ""
}

func TestIntegration_RunSeedsRedisAndWritesArtifacts(t *testing.T) {
	if testing.Short() {
		t.Skip("integration: skipped under -short")
	}
	podman, err := exec.LookPath("podman")
	if err != nil {
		t.Skipf("integration SKIP: podman not on PATH (%v)", err)
	}
	if _, err := os.Stat(danteBaseRel); err != nil {
		t.Skipf("integration SKIP: dante base not found (%v)", err)
	}
	dsn, _ := bootPG(t, podman)
	redisAddr := bootRedis(t, podman)

	out := t.TempDir()
	squidOut := filepath.Join(out, "dynamic-routing.conf")
	danteOut := filepath.Join(out, "sockd.deployed.conf")
	pacOut := filepath.Join(out, "proxy.pac")

	args := []string{
		"--dsn", dsn,
		"--redis-addr", redisAddr,
		"--helper-path", "/bin/true",
		"--squid-out", squidOut,
		"--dante-base", danteBaseRel,
		"--dante-out", danteOut,
		"--pac-out", pacOut,
	}
	if err := run(args); err != nil {
		t.Fatalf("run(): %v", err)
	}

	// Artifacts written + non-empty.
	squid, err := os.ReadFile(squidOut)
	if err != nil || len(squid) == 0 {
		t.Fatalf("squid-out missing/empty: %v", err)
	}
	if !strings.Contains(string(squid), "external_acl_type vpn_route") {
		t.Errorf("squid include not rendered:\n%s", squid)
	}
	// Dante concatenation: base verbatim THEN appended route blocks.
	base, _ := os.ReadFile(danteBaseRel)
	dante, err := os.ReadFile(danteOut)
	if err != nil {
		t.Fatalf("read dante-out: %v", err)
	}
	if !bytes.HasPrefix(dante, base) {
		t.Errorf("dante-out must START with the verbatim base (concatenation, §9)")
	}
	if !strings.Contains(string(dante), "route {") {
		t.Errorf("dante-out missing appended route blocks:\n%s", dante)
	}
	pac, err := os.ReadFile(pacOut)
	if err != nil || !strings.Contains(string(pac), "function FindProxyForURL") {
		t.Fatalf("pac-out missing/invalid: %v", err)
	}

	// ---- Redis route:<target> seeding READ BACK (deliverable #2 proof) --------
	rc, err := redis.Open(context.Background(), redisAddr, 0)
	if err != nil {
		t.Fatalf("open redis for verify: %v", err)
	}
	defer func() { _ = rc.Close() }()
	for target, wantTunnel := range map[string]string{
		"internal-wiki.helix": "eu-wg-primary",
		"metrics.helix":       "eu-wg-primary",
		"db-bastion.helix":    "us-wg-failover",
	} {
		r, gerr := rc.GetRoute(context.Background(), target)
		if gerr != nil {
			t.Errorf("GetRoute(%s): %v", target, gerr)
			continue
		}
		if r.Tunnel != wantTunnel || r.BreakerState != "closed" {
			t.Errorf("route %s = %+v, want tunnel=%s breaker=closed", target, r, wantTunnel)
		}
	}
	// A non-seeded target is fail-closed (ErrRouteNotFound), never a guessed route.
	if _, err := rc.GetRoute(context.Background(), "not-a-target"); err != redis.ErrRouteNotFound {
		t.Errorf("unseeded target: want ErrRouteNotFound, got %v", err)
	}

	// ---- WRITTEN squid include parses on real Squid (exit 0) ------------------
	tmp := t.TempDir()
	_ = os.WriteFile(filepath.Join(tmp, "dynamic-routing.conf"), squid, 0o644)
	_ = os.WriteFile(filepath.Join(tmp, "squid.conf"), []byte(
		"http_port 3128\nacl localnet src 10.0.0.0/8\ninclude /conf/dynamic-routing.conf\nhttp_access allow localnet\nhttp_access deny all\n"), 0o644)
	cmd := exec.Command(podman, "run", "--rm", "--entrypoint", "squid",
		"-v", tmp+":/conf:ro,Z", squidImage, "-k", "parse", "-f", "/conf/squid.conf")
	pout, perr := cmd.CombinedOutput()
	if perr != nil {
		t.Fatalf("squid -k parse on WRITTEN include failed: %v\n%s", perr, pout)
	}
	t.Logf("binary run(): wrote 3 artifacts, seeded 3 routes to redis, written squid include parses exit 0")
}
