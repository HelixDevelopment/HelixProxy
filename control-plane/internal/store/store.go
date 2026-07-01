// Package store defines the Postgres persistence contract for the control-plane
// data model (design spec §6): vpn_profiles, target_hosts, proxy_rules, plus the
// failover-tier, proxy-auth, and audit-log extensions. The config-compiler reads
// through Queries; the control-API writes through it (spec §4).
//
// Phase 2 (plan T2.3): a real pgx-backed implementation lives in postgres.go,
// over the committed DDL in sql/schema.sql. This file defines the row types and
// the Queries contract; the SQL text is package-level constants in postgres.go so
// it is unit-testable for parameterisation/correctness.
//
// ID typing note (§11.4.6 no-guessing, §11.4.111 resolve-by-name): the committed
// schema uses UUID primary keys (`uuid_generate_v4()`), so every surrogate key /
// foreign key is a string here — NOT int64. audit_log.id is the one BIGINT
// IDENTITY column and stays int64. Nullable FK / predicate columns
// (target_hosts.vpn_profile_id, proxy_rules.match_host/match_path/target_host_id)
// map to "" ⇄ SQL NULL by documented convention.
package store

import (
	"context"
	"time"
)

// VPNType enumerates supported tunnel implementations (spec §6 / §5). The set
// mirrors the schema CHECK constraint vpn_profiles_type_chk.
type VPNType string

const (
	// VPNTypeWireGuard is the preferred type (throughput / CPU / audit surface).
	VPNTypeWireGuard VPNType = "wireguard"
	// VPNTypeOpenVPN is the compatibility type.
	VPNTypeOpenVPN VPNType = "openvpn"
	// VPNTypeLegacy is the retained-but-deprecated dperson/openvpn-client (spec §5).
	VPNTypeLegacy VPNType = "legacy"
)

// VPNProfile is one tunnel definition. One profile == one gluetun container ==
// one network namespace == one `vpn:status:<profile>` key (spec §5). ID is the
// UUID string; SecretRef names a Podman secret, never holds secret material
// (§11.4.10).
type VPNProfile struct {
	ID        string
	Name      string
	Type      VPNType
	Config    []byte // jsonb tunnel config (secret material lives by reference only)
	SecretRef string
	Enabled   bool
	Created   time.Time
	Updated   time.Time
}

// TargetHost is a host reachable only via a VPN profile, exposed under a public
// alias by the proxy (spec §6). VPNProfileID is "" when the FK is NULL (an
// orphaned target — the ON DELETE SET NULL case).
type TargetHost struct {
	ID           string
	PublicAlias  string
	PrivateIP    string
	Port         int
	Protocol     string
	VPNProfileID string // "" ⇄ NULL
	HealthCheck  string
	Enabled      bool
	Created      time.Time
	Updated      time.Time
}

// ProxyRule maps an inbound host/path match to a target, by priority (spec §6).
// MatchHost / MatchPath / TargetHostID are "" when the column is NULL.
type ProxyRule struct {
	ID           string
	Priority     int
	MatchHost    string // "" ⇄ NULL
	MatchPath    string // "" ⇄ NULL
	TargetHostID string // "" ⇄ NULL
	Enabled      bool
	Created      time.Time
	Updated      time.Time
}

// TargetTunnelTier is one entry in a target's ordered failover list — lower tier
// = higher preference (spec §6, feature §11 ①).
type TargetTunnelTier struct {
	TargetID     string
	VPNProfileID string
	Tier         int
	Created      time.Time
}

// ProxyUser is a per-user proxy-auth principal. The secret lives by reference
// (Podman secret / file ref) only, NEVER in the row (spec §12, §11.4.10).
type ProxyUser struct {
	ID        string
	Username  string
	SecretRef string
	Role      string
	Enabled   bool
	Created   time.Time
	Updated   time.Time
}

// AuditLogEntry records a control-plane mutation for the audit trail (spec §12).
// ID is the BIGINT IDENTITY surrogate key. Detail is the JSONB payload as a
// string (caller supplies valid JSON; "" is normalised to "{}").
type AuditLogEntry struct {
	ID     int64
	TS     time.Time
	Actor  string
	Action string
	Detail string
}

// Queries is the read/write contract over the data model. Implementations are
// the only place SQL lives; callers depend on this interface, not on pgx. All
// methods are context-aware and use parameterised SQL (no string interpolation
// of caller input — §ANTI-INJECTION).
type Queries interface {
	// WithTx runs fn inside a single store transaction: every mutation fn performs
	// on the supplied tx Queries (incl. its AppendAudit) commits together or rolls
	// back together. It is the transactional-integrity seam (P6 WARNING-4): a
	// control-API handler wraps its `mutate + AppendAudit` pair in WithTx so a failed
	// audit write rolls back the mutation — an un-audited mutation is impossible. The
	// STORE owns begin/commit/rollback; fn never commits/rolls back itself. fn MUST
	// use the supplied tx, not the outer Queries, and MUST NOT nest WithTx
	// (§11.4.6 honest boundary: nesting would begin a second, independent transaction
	// on the real Postgres pool — handlers never nest).
	WithTx(ctx context.Context, fn func(tx Queries) error) error

	// --- vpn_profiles ---
	ListProfiles(ctx context.Context) ([]VPNProfile, error)
	GetProfile(ctx context.Context, id string) (VPNProfile, error)
	UpsertProfile(ctx context.Context, p VPNProfile) (string, error)
	DeleteProfile(ctx context.Context, id string) error

	// --- target_hosts ---
	ListTargets(ctx context.Context) ([]TargetHost, error)
	// GetTargetHost resolves a target by its stable public_alias (§11.4.111
	// resolve-by-name) — the helper/compiler lookup key.
	GetTargetHost(ctx context.Context, publicAlias string) (TargetHost, error)
	UpsertTarget(ctx context.Context, t TargetHost) (string, error)
	DeleteTarget(ctx context.Context, id string) error

	// --- proxy_rules ---
	ListRules(ctx context.Context) ([]ProxyRule, error)
	// GetRuleByHost returns the highest-priority ENABLED rule whose match_host
	// equals host. ErrNotFound when no enabled rule matches.
	GetRuleByHost(ctx context.Context, host string) (ProxyRule, error)
	UpsertRule(ctx context.Context, r ProxyRule) (string, error)
	DeleteRule(ctx context.Context, id string) error

	// --- target_tunnel_tiers (ordered failover) ---
	// ListTiers returns a target's failover chain ordered by tier ASC (tier 0 =
	// primary), the order the circuit-breaker walks (spec §11 ①).
	ListTiers(ctx context.Context, targetID string) ([]TargetTunnelTier, error)
	UpsertTier(ctx context.Context, t TargetTunnelTier) error
	DeleteTier(ctx context.Context, targetID string, tier int) error

	// --- proxy_users ---
	ListUsers(ctx context.Context) ([]ProxyUser, error)
	UpsertUser(ctx context.Context, u ProxyUser) (string, error)

	// --- audit_log (append-only) ---
	AppendAudit(ctx context.Context, e AuditLogEntry) error
}
