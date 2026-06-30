// Postgres-backed implementation of the store.Queries contract (design spec §6),
// over the committed DDL in sql/schema.sql. Uses database/sql with the pgx v5
// stdlib driver (github.com/jackc/pgx/v5/stdlib). Every query is parameterised
// ($1, $2, …) — caller input is NEVER interpolated into SQL text, so SQL
// injection is structurally impossible. All methods honour the supplied context.
package store

import (
	"context"
	"database/sql"
	"errors"
	"fmt"

	_ "github.com/jackc/pgx/v5/stdlib" // register the "pgx" database/sql driver
)

// ErrNotFound is returned by Get* methods when no row matches.
var ErrNotFound = errors.New("store: not found")

// Postgres implements Queries over a *sql.DB opened with the pgx stdlib driver.
type Postgres struct {
	db *sql.DB
}

// compile-time assertion that *Postgres satisfies the contract.
var _ Queries = (*Postgres)(nil)

// New wraps an already-open *sql.DB (the database/sql connection pool).
func New(db *sql.DB) *Postgres { return &Postgres{db: db} }

// Open opens a pgx-stdlib pool against dsn and verifies connectivity with
// PingContext. The caller owns Close.
func Open(ctx context.Context, dsn string) (*Postgres, error) {
	db, err := sql.Open("pgx", dsn)
	if err != nil {
		return nil, fmt.Errorf("store: open: %w", err)
	}
	if err := db.PingContext(ctx); err != nil {
		_ = db.Close()
		return nil, fmt.Errorf("store: ping: %w", err)
	}
	return &Postgres{db: db}, nil
}

// DB exposes the underlying pool (e.g. for schema application in tests/migrations).
func (p *Postgres) DB() *sql.DB { return p.db }

// Close closes the underlying pool.
func (p *Postgres) Close() error { return p.db.Close() }

// =============================================================================
// SQL text — package-level constants so they are unit-testable (parameterisation,
// column correctness) without a live database.
// =============================================================================

const (
	sqlListProfiles = `SELECT id, name, type, config, COALESCE(secret_ref,''), enabled, created_at, updated_at
		FROM vpn_profiles ORDER BY name ASC`

	sqlGetProfile = `SELECT id, name, type, config, COALESCE(secret_ref,''), enabled, created_at, updated_at
		FROM vpn_profiles WHERE id = $1`

	// Upsert keyed on the unique name (resolve-by-name §11.4.111): a re-add of an
	// existing profile updates it in place rather than erroring.
	sqlUpsertProfile = `INSERT INTO vpn_profiles (name, type, config, secret_ref, enabled)
		VALUES ($1, $2, $3, NULLIF($4,''), $5)
		ON CONFLICT (name) DO UPDATE
		  SET type = EXCLUDED.type, config = EXCLUDED.config,
		      secret_ref = EXCLUDED.secret_ref, enabled = EXCLUDED.enabled
		RETURNING id`

	sqlDeleteProfile = `DELETE FROM vpn_profiles WHERE id = $1`

	sqlListTargets = `SELECT id, public_alias, host(private_ip), port, protocol,
		COALESCE(vpn_profile_id::text,''), COALESCE(health_check,''), enabled, created_at, updated_at
		FROM target_hosts ORDER BY public_alias ASC`

	sqlGetTargetHost = `SELECT id, public_alias, host(private_ip), port, protocol,
		COALESCE(vpn_profile_id::text,''), COALESCE(health_check,''), enabled, created_at, updated_at
		FROM target_hosts WHERE public_alias = $1`

	sqlUpsertTarget = `INSERT INTO target_hosts
		(public_alias, private_ip, port, protocol, vpn_profile_id, health_check, enabled)
		VALUES ($1, $2::inet, $3, $4, NULLIF($5,'')::uuid, NULLIF($6,''), $7)
		ON CONFLICT (public_alias) DO UPDATE
		  SET private_ip = EXCLUDED.private_ip, port = EXCLUDED.port,
		      protocol = EXCLUDED.protocol, vpn_profile_id = EXCLUDED.vpn_profile_id,
		      health_check = EXCLUDED.health_check, enabled = EXCLUDED.enabled
		RETURNING id`

	sqlDeleteTarget = `DELETE FROM target_hosts WHERE id = $1`

	sqlListRules = `SELECT id, priority, COALESCE(match_host,''), COALESCE(match_path,''),
		COALESCE(target_host_id::text,''), enabled, created_at, updated_at
		FROM proxy_rules ORDER BY priority DESC, created_at ASC`

	// Highest-priority enabled rule for an exact host match (compiler/helper hot path).
	sqlGetRuleByHost = `SELECT id, priority, COALESCE(match_host,''), COALESCE(match_path,''),
		COALESCE(target_host_id::text,''), enabled, created_at, updated_at
		FROM proxy_rules
		WHERE enabled = true AND match_host = $1
		ORDER BY priority DESC, created_at ASC
		LIMIT 1`

	sqlInsertRule = `INSERT INTO proxy_rules (priority, match_host, match_path, target_host_id, enabled)
		VALUES ($1, NULLIF($2,''), NULLIF($3,''), NULLIF($4,'')::uuid, $5)
		RETURNING id`

	sqlUpdateRule = `UPDATE proxy_rules
		SET priority = $2, match_host = NULLIF($3,''), match_path = NULLIF($4,''),
		    target_host_id = NULLIF($5,'')::uuid, enabled = $6
		WHERE id = $1
		RETURNING id`

	sqlDeleteRule = `DELETE FROM proxy_rules WHERE id = $1`

	// Ordered failover chain (tier ASC = primary first), spec §11 ①.
	sqlListTiers = `SELECT target_host_id, vpn_profile_id, tier, created_at
		FROM target_tunnel_tiers WHERE target_host_id = $1 ORDER BY tier ASC`

	sqlUpsertTier = `INSERT INTO target_tunnel_tiers (target_host_id, vpn_profile_id, tier)
		VALUES ($1::uuid, $2::uuid, $3)
		ON CONFLICT (target_host_id, tier) DO UPDATE
		  SET vpn_profile_id = EXCLUDED.vpn_profile_id`

	sqlDeleteTier = `DELETE FROM target_tunnel_tiers WHERE target_host_id = $1 AND tier = $2`

	sqlListUsers = `SELECT id, username, secret_ref, role, enabled, created_at, updated_at
		FROM proxy_users ORDER BY username ASC`

	sqlUpsertUser = `INSERT INTO proxy_users (username, secret_ref, role, enabled)
		VALUES ($1, $2, $3, $4)
		ON CONFLICT (username) DO UPDATE
		  SET secret_ref = EXCLUDED.secret_ref, role = EXCLUDED.role, enabled = EXCLUDED.enabled
		RETURNING id`

	// Append-only: INSERT only, never UPDATE/DELETE (§12). "" detail normalised to {}.
	sqlAppendAudit = `INSERT INTO audit_log (actor, action, detail)
		VALUES ($1, $2, COALESCE(NULLIF($3,'')::jsonb, '{}'::jsonb))`
)

// =============================================================================
// vpn_profiles
// =============================================================================

func scanProfile(s interface{ Scan(...any) error }) (VPNProfile, error) {
	var p VPNProfile
	err := s.Scan(&p.ID, &p.Name, &p.Type, &p.Config, &p.SecretRef, &p.Enabled, &p.Created, &p.Updated)
	return p, err
}

func (p *Postgres) ListProfiles(ctx context.Context) ([]VPNProfile, error) {
	rows, err := p.db.QueryContext(ctx, sqlListProfiles)
	if err != nil {
		return nil, fmt.Errorf("store: list profiles: %w", err)
	}
	defer rows.Close()
	out := []VPNProfile{}
	for rows.Next() {
		v, err := scanProfile(rows)
		if err != nil {
			return nil, fmt.Errorf("store: scan profile: %w", err)
		}
		out = append(out, v)
	}
	return out, rows.Err()
}

func (p *Postgres) GetProfile(ctx context.Context, id string) (VPNProfile, error) {
	v, err := scanProfile(p.db.QueryRowContext(ctx, sqlGetProfile, id))
	if errors.Is(err, sql.ErrNoRows) {
		return VPNProfile{}, ErrNotFound
	}
	if err != nil {
		return VPNProfile{}, fmt.Errorf("store: get profile: %w", err)
	}
	return v, nil
}

func (p *Postgres) UpsertProfile(ctx context.Context, v VPNProfile) (string, error) {
	cfg := v.Config
	if len(cfg) == 0 {
		cfg = []byte("{}")
	}
	typ := v.Type
	if typ == "" {
		typ = VPNTypeWireGuard
	}
	var id string
	err := p.db.QueryRowContext(ctx, sqlUpsertProfile, v.Name, typ, cfg, v.SecretRef, v.Enabled).Scan(&id)
	if err != nil {
		return "", fmt.Errorf("store: upsert profile: %w", err)
	}
	return id, nil
}

func (p *Postgres) DeleteProfile(ctx context.Context, id string) error {
	_, err := p.db.ExecContext(ctx, sqlDeleteProfile, id)
	if err != nil {
		return fmt.Errorf("store: delete profile: %w", err)
	}
	return nil
}

// =============================================================================
// target_hosts
// =============================================================================

func scanTarget(s interface{ Scan(...any) error }) (TargetHost, error) {
	var t TargetHost
	err := s.Scan(&t.ID, &t.PublicAlias, &t.PrivateIP, &t.Port, &t.Protocol,
		&t.VPNProfileID, &t.HealthCheck, &t.Enabled, &t.Created, &t.Updated)
	return t, err
}

func (p *Postgres) ListTargets(ctx context.Context) ([]TargetHost, error) {
	rows, err := p.db.QueryContext(ctx, sqlListTargets)
	if err != nil {
		return nil, fmt.Errorf("store: list targets: %w", err)
	}
	defer rows.Close()
	out := []TargetHost{}
	for rows.Next() {
		t, err := scanTarget(rows)
		if err != nil {
			return nil, fmt.Errorf("store: scan target: %w", err)
		}
		out = append(out, t)
	}
	return out, rows.Err()
}

func (p *Postgres) GetTargetHost(ctx context.Context, publicAlias string) (TargetHost, error) {
	t, err := scanTarget(p.db.QueryRowContext(ctx, sqlGetTargetHost, publicAlias))
	if errors.Is(err, sql.ErrNoRows) {
		return TargetHost{}, ErrNotFound
	}
	if err != nil {
		return TargetHost{}, fmt.Errorf("store: get target: %w", err)
	}
	return t, nil
}

func (p *Postgres) UpsertTarget(ctx context.Context, t TargetHost) (string, error) {
	port := t.Port
	if port == 0 {
		port = 80
	}
	proto := t.Protocol
	if proto == "" {
		proto = "http"
	}
	var id string
	err := p.db.QueryRowContext(ctx, sqlUpsertTarget,
		t.PublicAlias, t.PrivateIP, port, proto, t.VPNProfileID, t.HealthCheck, t.Enabled).Scan(&id)
	if err != nil {
		return "", fmt.Errorf("store: upsert target: %w", err)
	}
	return id, nil
}

func (p *Postgres) DeleteTarget(ctx context.Context, id string) error {
	_, err := p.db.ExecContext(ctx, sqlDeleteTarget, id)
	if err != nil {
		return fmt.Errorf("store: delete target: %w", err)
	}
	return nil
}

// =============================================================================
// proxy_rules
// =============================================================================

func scanRule(s interface{ Scan(...any) error }) (ProxyRule, error) {
	var r ProxyRule
	err := s.Scan(&r.ID, &r.Priority, &r.MatchHost, &r.MatchPath, &r.TargetHostID,
		&r.Enabled, &r.Created, &r.Updated)
	return r, err
}

func (p *Postgres) ListRules(ctx context.Context) ([]ProxyRule, error) {
	rows, err := p.db.QueryContext(ctx, sqlListRules)
	if err != nil {
		return nil, fmt.Errorf("store: list rules: %w", err)
	}
	defer rows.Close()
	out := []ProxyRule{}
	for rows.Next() {
		r, err := scanRule(rows)
		if err != nil {
			return nil, fmt.Errorf("store: scan rule: %w", err)
		}
		out = append(out, r)
	}
	return out, rows.Err()
}

func (p *Postgres) GetRuleByHost(ctx context.Context, host string) (ProxyRule, error) {
	r, err := scanRule(p.db.QueryRowContext(ctx, sqlGetRuleByHost, host))
	if errors.Is(err, sql.ErrNoRows) {
		return ProxyRule{}, ErrNotFound
	}
	if err != nil {
		return ProxyRule{}, fmt.Errorf("store: get rule by host: %w", err)
	}
	return r, nil
}

func (p *Postgres) UpsertRule(ctx context.Context, r ProxyRule) (string, error) {
	var id string
	var err error
	if r.ID != "" {
		err = p.db.QueryRowContext(ctx, sqlUpdateRule,
			r.ID, r.Priority, r.MatchHost, r.MatchPath, r.TargetHostID, r.Enabled).Scan(&id)
		if errors.Is(err, sql.ErrNoRows) {
			return "", ErrNotFound
		}
	} else {
		err = p.db.QueryRowContext(ctx, sqlInsertRule,
			r.Priority, r.MatchHost, r.MatchPath, r.TargetHostID, r.Enabled).Scan(&id)
	}
	if err != nil {
		return "", fmt.Errorf("store: upsert rule: %w", err)
	}
	return id, nil
}

func (p *Postgres) DeleteRule(ctx context.Context, id string) error {
	_, err := p.db.ExecContext(ctx, sqlDeleteRule, id)
	if err != nil {
		return fmt.Errorf("store: delete rule: %w", err)
	}
	return nil
}

// =============================================================================
// target_tunnel_tiers
// =============================================================================

func (p *Postgres) ListTiers(ctx context.Context, targetID string) ([]TargetTunnelTier, error) {
	rows, err := p.db.QueryContext(ctx, sqlListTiers, targetID)
	if err != nil {
		return nil, fmt.Errorf("store: list tiers: %w", err)
	}
	defer rows.Close()
	out := []TargetTunnelTier{}
	for rows.Next() {
		var t TargetTunnelTier
		if err := rows.Scan(&t.TargetID, &t.VPNProfileID, &t.Tier, &t.Created); err != nil {
			return nil, fmt.Errorf("store: scan tier: %w", err)
		}
		out = append(out, t)
	}
	return out, rows.Err()
}

func (p *Postgres) UpsertTier(ctx context.Context, t TargetTunnelTier) error {
	_, err := p.db.ExecContext(ctx, sqlUpsertTier, t.TargetID, t.VPNProfileID, t.Tier)
	if err != nil {
		return fmt.Errorf("store: upsert tier: %w", err)
	}
	return nil
}

func (p *Postgres) DeleteTier(ctx context.Context, targetID string, tier int) error {
	_, err := p.db.ExecContext(ctx, sqlDeleteTier, targetID, tier)
	if err != nil {
		return fmt.Errorf("store: delete tier: %w", err)
	}
	return nil
}

// =============================================================================
// proxy_users
// =============================================================================

func (p *Postgres) ListUsers(ctx context.Context) ([]ProxyUser, error) {
	rows, err := p.db.QueryContext(ctx, sqlListUsers)
	if err != nil {
		return nil, fmt.Errorf("store: list users: %w", err)
	}
	defer rows.Close()
	out := []ProxyUser{}
	for rows.Next() {
		var u ProxyUser
		if err := rows.Scan(&u.ID, &u.Username, &u.SecretRef, &u.Role, &u.Enabled, &u.Created, &u.Updated); err != nil {
			return nil, fmt.Errorf("store: scan user: %w", err)
		}
		out = append(out, u)
	}
	return out, rows.Err()
}

func (p *Postgres) UpsertUser(ctx context.Context, u ProxyUser) (string, error) {
	role := u.Role
	if role == "" {
		role = "user"
	}
	var id string
	err := p.db.QueryRowContext(ctx, sqlUpsertUser, u.Username, u.SecretRef, role, u.Enabled).Scan(&id)
	if err != nil {
		return "", fmt.Errorf("store: upsert user: %w", err)
	}
	return id, nil
}

// =============================================================================
// audit_log (append-only)
// =============================================================================

func (p *Postgres) AppendAudit(ctx context.Context, e AuditLogEntry) error {
	_, err := p.db.ExecContext(ctx, sqlAppendAudit, e.Actor, e.Action, e.Detail)
	if err != nil {
		return fmt.Errorf("store: append audit: %w", err)
	}
	return nil
}
