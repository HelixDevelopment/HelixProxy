// Integration test: the DATA-PLANE STRUCTURAL PROOF (§11.4.69 / §11.4.107). It
// boots a REAL postgres:16-alpine via rootless podman, applies the committed
// schema + seed, runs the real compiler (CompileAll) against the live data model,
// then validates the RENDERED Squid include against a REAL Squid (ubuntu/squid,
// 6.13) with `squid -k parse` and asserts EXIT 0 — "the template rendered" (a
// string match) is NOT sufficient (§11.4.6). The §1.1 paired mutation corrupts a
// rendered cache_peer (drops the `parent` keyword) and asserts `squid -k parse`
// now FAILS (the RED proof the parse assertion is not a tautology).
//
// No mocks (§11.4.27). If podman or an image is unavailable the test SKIPs with a
// reason (§11.4.3) — never a faked PASS. Skipped under `go test -short`.
package routing

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

	"digital.vasic.helixproxy/controlplane/internal/store"
)

const (
	schemaRelPath = "../../../sql/schema.sql"
	seedRelPath   = "../../../sql/seed_example.sql"
	squidImage    = "docker.io/ubuntu/squid:latest" // :latest VERIFIED = 6.13 (spec §20)
)

// minimalSquidConf mirrors the FAIL-CLOSED deployment placement (§11.4.108,
// config/squid/squid.dynamic.conf): the base carries NO unconditional
// `allow localnet` — the include sits BEFORE `http_access deny all` and supplies
// BOTH `deny !tun_up` (tunnel down → 503) AND the gated `allow localnet` (tunnel
// up → permitted). A missing include falls through to `deny all` (no leak).
const minimalSquidConf = `http_port 3128
acl localnet src 10.0.0.0/8
include /conf/dynamic-routing.conf
http_access deny all
`

func evidenceDir(t *testing.T) string {
	t.Helper()
	dir := filepath.Join("..", "..", "qa-results", "p4-compiler",
		"integration-"+time.Now().UTC().Format("20060102T150405Z"))
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Logf("evidence dir unavailable (%v) — continuing", err)
		return ""
	}
	return dir
}

func writeEvidence(t *testing.T, dir, name string, b []byte) {
	t.Helper()
	if dir == "" {
		return
	}
	p := filepath.Join(dir, name)
	if err := os.WriteFile(p, b, 0o644); err != nil {
		t.Logf("write evidence %s: %v", p, err)
		return
	}
	abs, _ := filepath.Abs(p)
	t.Logf("evidence: %s", abs)
}

// bootPostgresSeeded starts a throwaway postgres, applies schema + seed, SKIPs on
// any infra failure (§11.4.3). Returns a ready *store.Postgres + the container name.
func bootPostgresSeeded(t *testing.T, podman string) *store.Postgres {
	t.Helper()
	for _, p := range []string{schemaRelPath, seedRelPath} {
		if _, err := os.Stat(p); err != nil {
			t.Skipf("integration SKIP: %s not found (%v)", p, err)
		}
	}
	port := freePortRouting(t)
	name := fmt.Sprintf("hp-it-rt-pg-%d", port)
	ctx := context.Background()

	run := exec.Command(podman, "run", "-d", "--rm", "--name", name,
		"-e", "POSTGRES_PASSWORD=postgres", "-e", "POSTGRES_DB=postgres",
		"-p", fmt.Sprintf("127.0.0.1:%d:5432", port), "postgres:16-alpine")
	if out, err := run.CombinedOutput(); err != nil {
		t.Skipf("integration SKIP: cannot start postgres: %v\n%s", err, out)
	}
	t.Cleanup(func() { _ = exec.Command(podman, "rm", "-f", name).Run() })

	dsn := fmt.Sprintf("postgres://postgres:postgres@127.0.0.1:%d/postgres?sslmode=disable", port)
	deadline := time.Now().Add(60 * time.Second)
	var pg *store.Postgres
	var err error
	for time.Now().Before(deadline) {
		if exec.Command(podman, "exec", name, "pg_isready", "-U", "postgres", "-h", "127.0.0.1").Run() == nil {
			pctx, cancel := context.WithTimeout(ctx, 5*time.Second)
			pg, err = store.Open(pctx, dsn)
			cancel()
			if err == nil {
				break
			}
		}
		time.Sleep(750 * time.Millisecond)
	}
	if pg == nil {
		t.Skipf("integration SKIP: postgres not ready (last err: %v)", err)
	}
	t.Cleanup(func() { _ = pg.Close() })

	for _, f := range []string{schemaRelPath, seedRelPath} {
		sql, rerr := os.ReadFile(f)
		if rerr != nil {
			t.Fatalf("read %s: %v", f, rerr)
		}
		apply := exec.Command(podman, "exec", "-i", name, "psql", "-U", "postgres", "-d", "postgres", "-v", "ON_ERROR_STOP=1")
		apply.Stdin = bytes.NewReader(sql)
		if out, aerr := apply.CombinedOutput(); aerr != nil {
			t.Fatalf("apply %s failed: %v\n%s", f, aerr, out)
		}
	}
	return pg
}

// squidParse writes the include + a minimal squid.conf into a temp dir and runs
// `squid -k parse` inside the squid image (rootless `podman run --rm`). Returns
// the combined output + exit code.
func squidParse(t *testing.T, podman string, include []byte) ([]byte, int) {
	t.Helper()
	tmp := t.TempDir()
	if err := os.WriteFile(filepath.Join(tmp, "dynamic-routing.conf"), include, 0o644); err != nil {
		t.Fatalf("write include: %v", err)
	}
	if err := os.WriteFile(filepath.Join(tmp, "squid.conf"), []byte(minimalSquidConf), 0o644); err != nil {
		t.Fatalf("write squid.conf: %v", err)
	}
	cmd := exec.Command(podman, "run", "--rm", "--entrypoint", "squid",
		"-v", tmp+":/conf:ro,Z", squidImage, "-k", "parse", "-f", "/conf/squid.conf")
	out, err := cmd.CombinedOutput()
	code := 0
	if err != nil {
		code = 1
		if ee, ok := err.(*exec.ExitError); ok {
			code = ee.ExitCode()
		}
	}
	return out, code
}

func TestIntegration_CompileAndSquidParse(t *testing.T) {
	if testing.Short() {
		t.Skip("integration: skipped under -short")
	}
	podman, err := exec.LookPath("podman")
	if err != nil {
		t.Skipf("integration SKIP: podman not on PATH (%v)", err)
	}

	pg := bootPostgresSeeded(t, podman)
	ev := evidenceDir(t)

	// Real compile against the live, seeded data model.
	eng := New("/bin/true", "") // /bin/true exists in the squid image
	arts, routes, err := eng.CompileAll(context.Background(), pg)
	if err != nil {
		t.Fatalf("CompileAll against live PG: %v", err)
	}
	writeEvidence(t, ev, "rendered_squid_dynamic-routing.conf", arts.SquidInclude)
	writeEvidence(t, ev, "rendered_dante_routes.conf", arts.DanteRoutes)
	writeEvidence(t, ev, "rendered_pac.pac", arts.PAC)

	// Seed (eu-wg-primary, us-wg-failover, apac-ovpn enabled; legacy disabled) →
	// 3 cache_peers; 3 enabled targets → 3 routes.
	if !strings.Contains(string(arts.SquidInclude), "cache_peer gluetun-eu-wg-primary parent 8888") {
		t.Errorf("expected eu cache_peer in rendered include:\n%s", arts.SquidInclude)
	}
	if n := strings.Count(string(arts.SquidInclude), "cache_peer "); n != 3 {
		t.Errorf("expected 3 cache_peer lines (3 enabled profiles), got %d", n)
	}
	if len(routes) != 3 {
		t.Errorf("expected 3 resolved routes, got %d: %+v", len(routes), routes)
	}

	// ---- DATA-PLANE STRUCTURAL PROOF: real Squid must parse it (exit 0) -------
	out, code := squidParse(t, podman, arts.SquidInclude)
	writeEvidence(t, ev, "squid_parse_valid.txt",
		[]byte(fmt.Sprintf("exit=%d\n%s", code, out)))
	if code != 0 {
		t.Fatalf("squid -k parse on rendered include FAILED (exit %d) — not just a string match:\n%s", code, out)
	}
	t.Logf("squid -k parse exit 0 on rendered include (%d bytes) — data-plane structural proof", len(arts.SquidInclude))

	// ---- §1.1 PAIRED MUTATION: corrupt a cache_peer (drop `parent`) -----------
	// The valid config parses (above); the mutant MUST fail parse, proving the
	// exit-0 assertion is not a tautology (it genuinely tests Squid syntax).
	mutant := bytes.Replace(arts.SquidInclude, []byte(" parent 8888 "), []byte(" 8888 "), 1)
	if bytes.Equal(mutant, arts.SquidInclude) {
		t.Fatal("mutation no-op: ` parent 8888 ` not found in rendered include")
	}
	mout, mcode := squidParse(t, podman, mutant)
	writeEvidence(t, ev, "squid_parse_mutated_RED.txt",
		[]byte(fmt.Sprintf("exit=%d (expected non-zero — RED)\n%s", mcode, mout)))
	if mcode == 0 {
		t.Fatalf("§1.1 MUTATION ESCAPED: mutated config (dropped `parent`) still parsed exit 0 — the parse gate is a bluff:\n%s", mout)
	}
	t.Logf("§1.1 mutation RED confirmed: mutated include fails squid -k parse (exit %d)", mcode)
}

func freePortRouting(t *testing.T) int {
	t.Helper()
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("freePort: %v", err)
	}
	defer l.Close()
	return l.Addr().(*net.TCPAddr).Port
}
