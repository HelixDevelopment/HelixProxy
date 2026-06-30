// Integration test: the control-API CRUD over a REAL Postgres (booted on-demand
// via rootless podman, schema applied), driven over REAL mTLS HTTP. No mocks
// (§11.4.27). If podman/PG is unavailable it SKIPs with a reason (§11.4.3) —
// never a fake pass. Skipped under -short. Uses a UNIQUE container name + UNIQUE
// high port and tears the container down via t.Cleanup (never touches operator
// resources like lava-postgres-thinker).
package api

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net"
	"net/http"
	"os"
	"os/exec"
	"testing"
	"time"

	"digital.vasic.helixproxy/controlplane/internal/store"
)

const schemaRelPath = "../../../sql/schema.sql"

func freePort(t *testing.T) int {
	t.Helper()
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("freePort: %v", err)
	}
	defer l.Close()
	return l.Addr().(*net.TCPAddr).Port
}

func bootPostgres(t *testing.T) *store.Postgres {
	t.Helper()
	if testing.Short() {
		t.Skip("integration: skipped under -short")
	}
	podman, err := exec.LookPath("podman")
	if err != nil {
		t.Skipf("integration SKIP: podman not on PATH (%v)", err)
	}
	if _, err := os.Stat(schemaRelPath); err != nil {
		t.Skipf("integration SKIP: schema not found at %s (%v)", schemaRelPath, err)
	}

	port := freePort(t)
	name := fmt.Sprintf("hp-it-api-pg-%d", port) // UNIQUE name; not an operator resource
	ctx := context.Background()

	run := exec.Command(podman, "run", "-d", "--rm", "--name", name,
		"-e", "POSTGRES_PASSWORD=postgres", "-e", "POSTGRES_DB=postgres",
		"-p", fmt.Sprintf("127.0.0.1:%d:5432", port), "postgres:16-alpine")
	if out, err := run.CombinedOutput(); err != nil {
		t.Skipf("integration SKIP: cannot start postgres: %v\n%s", err, out)
	}
	t.Cleanup(func() { _ = exec.Command(podman, "rm", "-f", name).Run() }) // teardown (trap)

	dsn := fmt.Sprintf("postgres://postgres:postgres@127.0.0.1:%d/postgres?sslmode=disable", port)
	deadline := time.Now().Add(60 * time.Second)
	var pg *store.Postgres
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
		t.Skipf("integration SKIP: postgres not ready within deadline (last err: %v)", err)
	}
	t.Cleanup(func() { _ = pg.Close() })

	schema, err := os.ReadFile(schemaRelPath)
	if err != nil {
		t.Fatalf("read schema: %v", err)
	}
	apply := exec.Command(podman, "exec", "-i", name, "psql", "-U", "postgres", "-d", "postgres", "-v", "ON_ERROR_STOP=1")
	apply.Stdin = bytes.NewReader(schema)
	if out, err := apply.CombinedOutput(); err != nil {
		t.Fatalf("apply schema: %v\n%s", err, out)
	}
	return pg
}

// TestIntegration_API_CRUD_RealPostgres drives a real PUT through the mTLS API
// into a real Postgres, then asserts BOTH the row landed AND an audit_log row was
// written by the mutation (spec §12 — every mutation audits).
func TestIntegration_API_CRUD_RealPostgres(t *testing.T) {
	pg := bootPostgres(t)
	h := newHarnessWith(t, pg, newFakeBus()) // real store, fake bus (CRUD doesn't need redis)
	c := h.clientWithCert(t)

	// PUT a profile over real mTLS → real Postgres.
	bodyIn, _ := json.Marshal(profileDTO{Name: "uk-wg", Type: "wireguard", SecretRef: "wg-uk", Enabled: true})
	req, _ := http.NewRequest(http.MethodPut, h.url+"/api/profiles", bytes.NewReader(bodyIn))
	req.Header.Set("Content-Type", "application/json")
	resp, err := c.Do(req)
	if err != nil {
		t.Fatalf("PUT profile: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("PUT profile: want 200, got %d", resp.StatusCode)
	}

	// Row really persisted in Postgres.
	ctx := context.Background()
	ps, err := pg.ListProfiles(ctx)
	if err != nil || len(ps) != 1 || ps[0].Name != "uk-wg" {
		t.Fatalf("profile not persisted in PG: %+v err=%v", ps, err)
	}

	// Audit row written with the mTLS cert CN as actor.
	var n int
	var actor string
	if err := pg.DB().QueryRowContext(ctx, "SELECT count(*), coalesce(max(actor),'') FROM audit_log WHERE action='profile.upsert'").Scan(&n, &actor); err != nil {
		t.Fatalf("count audit: %v", err)
	}
	if n != 1 || actor != "admin@helix" {
		t.Fatalf("audit row: want 1 by admin@helix, got n=%d actor=%q", n, actor)
	}
}
