// Unit tests (no database): assert the SQL query constants are parameterised
// (no caller input interpolated → SQL injection structurally impossible) and
// reference the correct tables/columns/ordering from sql/schema.sql. Runnable
// under `go test -short`.
package store

import (
	"context"
	"strings"
	"testing"
)

// allQueries pairs each SQL constant with the placeholders it must carry.
var allQueries = map[string]string{
	"sqlListProfiles":  sqlListProfiles,
	"sqlGetProfile":    sqlGetProfile,
	"sqlUpsertProfile": sqlUpsertProfile,
	"sqlDeleteProfile": sqlDeleteProfile,
	"sqlListTargets":   sqlListTargets,
	"sqlGetTargetHost": sqlGetTargetHost,
	"sqlUpsertTarget":  sqlUpsertTarget,
	"sqlDeleteTarget":  sqlDeleteTarget,
	"sqlListRules":     sqlListRules,
	"sqlGetRuleByHost": sqlGetRuleByHost,
	"sqlInsertRule":    sqlInsertRule,
	"sqlUpdateRule":    sqlUpdateRule,
	"sqlDeleteRule":    sqlDeleteRule,
	"sqlListTiers":     sqlListTiers,
	"sqlUpsertTier":    sqlUpsertTier,
	"sqlDeleteTier":    sqlDeleteTier,
	"sqlListUsers":     sqlListUsers,
	"sqlUpsertUser":    sqlUpsertUser,
	"sqlAppendAudit":   sqlAppendAudit,
}

// TestQueriesUseParameterPlaceholders proves no constant uses printf-style or
// string-concat interpolation; queries that accept input use $N placeholders.
func TestQueriesUseParameterPlaceholders(t *testing.T) {
	t.Parallel()
	// Forbidden interpolation markers — their presence would mean caller input
	// is woven into SQL text (injection vector).
	forbidden := []string{"%s", "%d", "%v", "%q", "' ||", "|| '", "+ \""}
	for name, q := range allQueries {
		for _, bad := range forbidden {
			if strings.Contains(q, bad) {
				t.Errorf("%s contains interpolation marker %q — injection risk", name, bad)
			}
		}
	}
	// Statements that take input MUST carry at least $1.
	mustParam := []string{
		"sqlGetProfile", "sqlUpsertProfile", "sqlDeleteProfile",
		"sqlGetTargetHost", "sqlUpsertTarget", "sqlDeleteTarget",
		"sqlGetRuleByHost", "sqlInsertRule", "sqlUpdateRule", "sqlDeleteRule",
		"sqlListTiers", "sqlUpsertTier", "sqlDeleteTier", "sqlUpsertUser",
		"sqlAppendAudit",
	}
	for _, name := range mustParam {
		if !strings.Contains(allQueries[name], "$1") {
			t.Errorf("%s must use a $1 parameter placeholder, has none", name)
		}
	}
}

// TestGetRuleByHostShape proves the hot-path rule lookup filters enabled rows and
// orders highest-priority first — the §6 / §8 semantics the compiler relies on.
func TestGetRuleByHostShape(t *testing.T) {
	t.Parallel()
	q := sqlGetRuleByHost
	for _, want := range []string{"FROM proxy_rules", "enabled = true", "match_host = $1", "ORDER BY priority DESC", "LIMIT 1"} {
		if !strings.Contains(q, want) {
			t.Errorf("sqlGetRuleByHost missing %q\nSQL: %s", want, q)
		}
	}
}

// TestListTiersOrderedAscending proves failover tiers are returned primary-first
// (tier 0 before tier 1) — the order the circuit-breaker walks (spec §11 ①).
func TestListTiersOrderedAscending(t *testing.T) {
	t.Parallel()
	q := sqlListTiers
	if !strings.Contains(q, "FROM target_tunnel_tiers") {
		t.Fatalf("sqlListTiers wrong table: %s", q)
	}
	if !strings.Contains(q, "ORDER BY tier ASC") {
		t.Errorf("sqlListTiers must order by tier ASC (primary first): %s", q)
	}
	if !strings.Contains(q, "target_host_id = $1") {
		t.Errorf("sqlListTiers must filter by target_host_id = $1: %s", q)
	}
}

// TestAuditIsAppendOnly proves the audit query is INSERT-only — never UPDATE or
// DELETE (§12 append-only).
func TestAuditIsAppendOnly(t *testing.T) {
	t.Parallel()
	q := strings.ToUpper(sqlAppendAudit)
	if !strings.HasPrefix(strings.TrimSpace(q), "INSERT INTO AUDIT_LOG") {
		t.Errorf("sqlAppendAudit must be an INSERT into audit_log: %s", sqlAppendAudit)
	}
	for _, bad := range []string{"UPDATE ", "DELETE "} {
		if strings.Contains(q, bad) {
			t.Errorf("sqlAppendAudit must not contain %q (append-only): %s", bad, sqlAppendAudit)
		}
	}
}

// TestUpsertsResolveByName proves the create-or-update statements key on the
// stable unique business key (name/public_alias/username), not a positional id
// (§11.4.111 resolve-by-name).
func TestUpsertsResolveByName(t *testing.T) {
	t.Parallel()
	cases := map[string]string{
		"sqlUpsertProfile": "ON CONFLICT (name)",
		"sqlUpsertTarget":  "ON CONFLICT (public_alias)",
		"sqlUpsertUser":    "ON CONFLICT (username)",
		"sqlUpsertTier":    "ON CONFLICT (target_host_id, tier)",
	}
	for name, want := range cases {
		if !strings.Contains(allQueries[name], want) {
			t.Errorf("%s must upsert via %q: %s", name, want, allQueries[name])
		}
	}
}

// TestErrNotFoundDistinct guards against ErrNotFound being accidentally nil.
func TestErrNotFoundDistinct(t *testing.T) {
	t.Parallel()
	if ErrNotFound == nil {
		t.Fatal("ErrNotFound must be a non-nil sentinel")
	}
}

// TestPostgresSatisfiesQueries is a compile+runtime assertion that *Postgres is a
// complete Queries implementation (mirrors the var _ Queries assertion).
func TestPostgresSatisfiesQueries(t *testing.T) {
	t.Parallel()
	// Compile-time assertion: *Postgres is a complete Queries implementation —
	// binding New(nil)'s concrete *Postgres to the interface fails to compile if a
	// method is missing (the real coverage). A runtime `if q == nil` is dead code
	// (SA4023): New always returns a non-nil *Postgres.
	var _ Queries = New(nil)
	// We do not call methods here (no DB); this only pins the interface.
	_ = context.Background()
}
