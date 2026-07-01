// Integration tests against a REAL PostgreSQL booted on-demand via rootless
// podman (postgres:16-alpine), with the committed sql/schema.sql applied. No
// mocks (§11.4.27). If podman or the container is unavailable, the test SKIPs
// with a reason (§11.4.3) — never a fake pass. Skipped automatically under
// `go test -short`.
package store

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"net"
	"os"
	"os/exec"
	"testing"
	"time"
)

const schemaRelPath = "../../../sql/schema.sql"

// bootPostgres starts a throwaway postgres:16-alpine, applies the schema, and
// returns a ready *Postgres. It registers teardown via t.Cleanup (the Go
// equivalent of a shell trap). On any infra failure it SKIPs (§11.4.3).
func bootPostgres(t *testing.T) *Postgres {
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
	name := fmt.Sprintf("hp-it-pg-%d", port)
	ctx := context.Background()

	// --rm so the container self-deletes on stop; small cached image.
	run := exec.Command(podman, "run", "-d", "--rm", "--name", name,
		"-e", "POSTGRES_PASSWORD=postgres",
		"-e", "POSTGRES_DB=postgres",
		"-p", fmt.Sprintf("127.0.0.1:%d:5432", port),
		"postgres:16-alpine")
	if out, err := run.CombinedOutput(); err != nil {
		t.Skipf("integration SKIP: cannot start postgres container: %v\n%s", err, out)
	}
	t.Cleanup(func() {
		_ = exec.Command(podman, "rm", "-f", name).Run()
	})

	dsn := fmt.Sprintf("postgres://postgres:postgres@127.0.0.1:%d/postgres?sslmode=disable", port)

	// Wait for readiness: pg_isready inside the container, then a real Ping.
	deadline := time.Now().Add(60 * time.Second)
	var pg *Postgres
	for time.Now().Before(deadline) {
		ready := exec.Command(podman, "exec", name, "pg_isready", "-U", "postgres", "-h", "127.0.0.1")
		if ready.Run() == nil {
			pctx, cancel := context.WithTimeout(ctx, 5*time.Second)
			pg, err = Open(pctx, dsn)
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

	// Apply the committed schema via psql inside the container (stdin).
	schema, err := os.ReadFile(schemaRelPath)
	if err != nil {
		t.Fatalf("read schema: %v", err)
	}
	apply := exec.Command(podman, "exec", "-i", name, "psql", "-U", "postgres", "-d", "postgres", "-v", "ON_ERROR_STOP=1")
	apply.Stdin = bytes.NewReader(schema)
	if out, err := apply.CombinedOutput(); err != nil {
		t.Fatalf("apply schema failed: %v\n%s", err, out)
	}
	return pg
}

func TestIntegration_ProfilesCRUD(t *testing.T) {
	pg := bootPostgres(t)
	ctx := context.Background()

	id, err := pg.UpsertProfile(ctx, VPNProfile{
		Name: "nordvpn-uk", Type: VPNTypeWireGuard,
		Config: []byte(`{"endpoint":"uk1.example:51820"}`), SecretRef: "wg-uk-key", Enabled: true,
	})
	if err != nil {
		t.Fatalf("upsert profile: %v", err)
	}
	if id == "" {
		t.Fatal("upsert returned empty UUID")
	}

	got, err := pg.GetProfile(ctx, id)
	if err != nil {
		t.Fatalf("get profile: %v", err)
	}
	if got.Name != "nordvpn-uk" || got.Type != VPNTypeWireGuard || got.SecretRef != "wg-uk-key" || !got.Enabled {
		t.Errorf("profile round-trip mismatch: %+v", got)
	}
	if string(got.Config) == "" {
		t.Error("config not persisted")
	}

	// Upsert-by-name updates in place (same id back).
	id2, err := pg.UpsertProfile(ctx, VPNProfile{Name: "nordvpn-uk", Type: VPNTypeOpenVPN, Enabled: false})
	if err != nil {
		t.Fatalf("re-upsert: %v", err)
	}
	if id2 != id {
		t.Errorf("upsert-by-name should keep id: %s != %s", id2, id)
	}
	got2, _ := pg.GetProfile(ctx, id)
	if got2.Type != VPNTypeOpenVPN || got2.Enabled {
		t.Errorf("update-in-place failed: %+v", got2)
	}

	list, err := pg.ListProfiles(ctx)
	if err != nil || len(list) != 1 {
		t.Fatalf("list profiles: len=%d err=%v", len(list), err)
	}

	if err := pg.DeleteProfile(ctx, id); err != nil {
		t.Fatalf("delete profile: %v", err)
	}
	if _, err := pg.GetProfile(ctx, id); err != ErrNotFound {
		t.Errorf("get after delete: want ErrNotFound, got %v", err)
	}
}

func TestIntegration_TargetsTiersRules(t *testing.T) {
	pg := bootPostgres(t)
	ctx := context.Background()

	primaryID, _ := pg.UpsertProfile(ctx, VPNProfile{Name: "tun-primary", Type: VPNTypeWireGuard, Enabled: true})
	backupID, _ := pg.UpsertProfile(ctx, VPNProfile{Name: "tun-backup", Type: VPNTypeWireGuard, Enabled: true})

	targetID, err := pg.UpsertTarget(ctx, TargetHost{
		PublicAlias: "api.internal", PrivateIP: "10.8.0.5", Port: 8443, Protocol: "https",
		VPNProfileID: primaryID, HealthCheck: "https://api.internal/health", Enabled: true,
	})
	if err != nil {
		t.Fatalf("upsert target: %v", err)
	}

	tgt, err := pg.GetTargetHost(ctx, "api.internal")
	if err != nil {
		t.Fatalf("get target: %v", err)
	}
	if tgt.ID != targetID || tgt.PrivateIP != "10.8.0.5" || tgt.Port != 8443 || tgt.Protocol != "https" || tgt.VPNProfileID != primaryID {
		t.Errorf("target round-trip mismatch: %+v", tgt)
	}

	// Ordered failover tiers — must come back primary (0) before backup (1).
	if err := pg.UpsertTier(ctx, TargetTunnelTier{TargetID: targetID, VPNProfileID: backupID, Tier: 1}); err != nil {
		t.Fatalf("upsert tier1: %v", err)
	}
	if err := pg.UpsertTier(ctx, TargetTunnelTier{TargetID: targetID, VPNProfileID: primaryID, Tier: 0}); err != nil {
		t.Fatalf("upsert tier0: %v", err)
	}
	tiers, err := pg.ListTiers(ctx, targetID)
	if err != nil {
		t.Fatalf("list tiers: %v", err)
	}
	if len(tiers) != 2 || tiers[0].Tier != 0 || tiers[0].VPNProfileID != primaryID || tiers[1].Tier != 1 {
		t.Errorf("tiers not ordered primary-first: %+v", tiers)
	}

	// Rules: two enabled for same host, different priority — higher wins.
	if _, err := pg.UpsertRule(ctx, ProxyRule{Priority: 10, MatchHost: "api.internal", TargetHostID: targetID, Enabled: true}); err != nil {
		t.Fatalf("upsert rule lo: %v", err)
	}
	hiID, err := pg.UpsertRule(ctx, ProxyRule{Priority: 100, MatchHost: "api.internal", TargetHostID: targetID, Enabled: true})
	if err != nil {
		t.Fatalf("upsert rule hi: %v", err)
	}
	rule, err := pg.GetRuleByHost(ctx, "api.internal")
	if err != nil {
		t.Fatalf("get rule by host: %v", err)
	}
	if rule.ID != hiID || rule.Priority != 100 {
		t.Errorf("GetRuleByHost should return highest priority: %+v", rule)
	}
	if _, err := pg.GetRuleByHost(ctx, "no.such.host"); err != ErrNotFound {
		t.Errorf("missing host: want ErrNotFound, got %v", err)
	}

	// Cascade: deleting the target removes its tiers + rules (schema ON DELETE CASCADE).
	if err := pg.DeleteTarget(ctx, targetID); err != nil {
		t.Fatalf("delete target: %v", err)
	}
	if tiers, _ := pg.ListTiers(ctx, targetID); len(tiers) != 0 {
		t.Errorf("tiers not cascade-deleted: %+v", tiers)
	}
}

func TestIntegration_UsersAndAudit(t *testing.T) {
	pg := bootPostgres(t)
	ctx := context.Background()

	uid, err := pg.UpsertUser(ctx, ProxyUser{Username: "alice", SecretRef: "htpasswd-alice", Role: "admin", Enabled: true})
	if err != nil || uid == "" {
		t.Fatalf("upsert user: id=%q err=%v", uid, err)
	}
	users, err := pg.ListUsers(ctx)
	if err != nil || len(users) != 1 || users[0].Username != "alice" || users[0].Role != "admin" || users[0].SecretRef != "htpasswd-alice" {
		t.Fatalf("list users: %+v err=%v", users, err)
	}

	// Append-only audit; verify the row landed via a direct count.
	if err := pg.AppendAudit(ctx, AuditLogEntry{Actor: "alice", Action: "profile.create", Detail: `{"name":"nordvpn-uk"}`}); err != nil {
		t.Fatalf("append audit: %v", err)
	}
	if err := pg.AppendAudit(ctx, AuditLogEntry{Actor: "system", Action: "tunnel.failover", Detail: ""}); err != nil {
		t.Fatalf("append audit (empty detail): %v", err)
	}
	var n int
	if err := pg.DB().QueryRowContext(ctx, "SELECT count(*) FROM audit_log").Scan(&n); err != nil {
		t.Fatalf("count audit: %v", err)
	}
	if n != 2 {
		t.Errorf("audit_log rows = %d, want 2", n)
	}
	// Empty detail normalised to {}.
	var detail string
	if err := pg.DB().QueryRowContext(ctx, "SELECT detail::text FROM audit_log WHERE action='tunnel.failover'").Scan(&detail); err != nil {
		t.Fatalf("read detail: %v", err)
	}
	if detail != "{}" {
		t.Errorf("empty detail should normalise to {}, got %q", detail)
	}
}

// TestIntegration_WithTxAtomicAuditAndMutation proves, against a REAL Postgres,
// that WithTx commits a mutation + its audit row together and rolls BOTH back on
// error — the P6 WARNING-4 transactional-integrity guarantee at the real DB layer.
func TestIntegration_WithTxAtomicAuditAndMutation(t *testing.T) {
	pg := bootPostgres(t)
	ctx := context.Background()

	countProfiles := func() int {
		var n int
		if err := pg.DB().QueryRowContext(ctx, "SELECT count(*) FROM vpn_profiles").Scan(&n); err != nil {
			t.Fatalf("count profiles: %v", err)
		}
		return n
	}
	countAudit := func() int {
		var n int
		if err := pg.DB().QueryRowContext(ctx, "SELECT count(*) FROM audit_log").Scan(&n); err != nil {
			t.Fatalf("count audit: %v", err)
		}
		return n
	}

	// (1) Commit path: a mutation + audit inside WithTx both persist.
	if err := pg.WithTx(ctx, func(tx Queries) error {
		id, e := tx.UpsertProfile(ctx, VPNProfile{Name: "tx-commit", Type: VPNTypeWireGuard, Enabled: true})
		if e != nil {
			return e
		}
		return tx.AppendAudit(ctx, AuditLogEntry{Actor: "tester", Action: "profile.upsert", Detail: `{"id":"` + id + `"}`})
	}); err != nil {
		t.Fatalf("WithTx commit path: %v", err)
	}
	if p, a := countProfiles(), countAudit(); p != 1 || a != 1 {
		t.Fatalf("commit path: want 1 profile + 1 audit, got %d / %d", p, a)
	}

	// (2) Rollback path: the audit append "fails" (fn returns an error AFTER the
	// mutation). The mutation MUST NOT persist — no un-audited profile, no audit row.
	injected := errors.New("injected audit failure")
	err := pg.WithTx(ctx, func(tx Queries) error {
		if _, e := tx.UpsertProfile(ctx, VPNProfile{Name: "tx-rollback", Type: VPNTypeWireGuard, Enabled: true}); e != nil {
			return e
		}
		return injected // simulates AppendAudit failing inside the same transaction
	})
	if !errors.Is(err, injected) {
		t.Fatalf("rollback path: want the injected error back, got %v", err)
	}
	if p, a := countProfiles(), countAudit(); p != 1 || a != 1 {
		t.Fatalf("rollback path: the un-audited mutation must NOT persist — want still 1 profile + 1 audit, got %d / %d", p, a)
	}
	var rolledBack int
	if err := pg.DB().QueryRowContext(ctx, "SELECT count(*) FROM vpn_profiles WHERE name = $1", "tx-rollback").Scan(&rolledBack); err != nil {
		t.Fatalf("count rolled-back profile: %v", err)
	}
	if rolledBack != 0 {
		t.Fatalf("rolled-back profile must be absent: found %d rows named tx-rollback", rolledBack)
	}
}

// TestIntegration_NoSQLInjection proves parameterisation: a malicious alias is
// treated as data, not SQL — it matches nothing and the table survives.
func TestIntegration_NoSQLInjection(t *testing.T) {
	pg := bootPostgres(t)
	ctx := context.Background()

	if _, err := pg.UpsertTarget(ctx, TargetHost{PublicAlias: "benign", PrivateIP: "10.0.0.1", Port: 80, Protocol: "http", Enabled: true}); err != nil {
		t.Fatalf("seed: %v", err)
	}
	evil := "benign'; DROP TABLE target_hosts; --"
	if _, err := pg.GetTargetHost(ctx, evil); err != ErrNotFound {
		t.Errorf("injection alias: want ErrNotFound, got %v", err)
	}
	// Table must still exist + still hold the benign row.
	var n int
	if err := pg.DB().QueryRowContext(ctx, "SELECT count(*) FROM target_hosts").Scan(&n); err != nil {
		t.Fatalf("table gone — injection succeeded?! %v", err)
	}
	if n != 1 {
		t.Errorf("target_hosts row count = %d, want 1 (injection must be inert)", n)
	}
}

// --- small helpers (no extra deps) ---

func freePort(t *testing.T) int {
	t.Helper()
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("freePort: %v", err)
	}
	defer l.Close()
	return l.Addr().(*net.TCPAddr).Port
}
