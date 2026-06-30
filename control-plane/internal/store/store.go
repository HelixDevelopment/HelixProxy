// Package store defines the Postgres persistence contract for the control-plane
// data model (design spec §6): vpn_profiles, target_hosts, proxy_rules, plus the
// failover-tier, proxy-auth, and audit-log extensions. The config-compiler reads
// through Queries; the control-API writes through it (spec §4).
//
// SCAFFOLD (Phase 2): a real pgx-backed implementation lands in internal/store
// during plan T2.3, after the DDL/migrations in sql/ (plan T0.2). This file
// defines only the row types and the Queries contract; there is no SQL yet.
package store

import (
	"context"
	"time"
)

// VPNType enumerates supported tunnel implementations (spec §6 / §5).
type VPNType string

const (
	// VPNTypeWireGuard is the preferred type (throughput / CPU / audit surface).
	VPNTypeWireGuard VPNType = "wireguard"
	// VPNTypeOpenVPN is the compatibility type (covers the legacy profile, spec §5).
	VPNTypeOpenVPN VPNType = "openvpn"
)

// VPNProfile is one tunnel definition. One profile == one gluetun container ==
// one network namespace == one `vpn:status:<profile>` key (spec §5).
type VPNProfile struct {
	ID      int64
	Name    string
	Type    VPNType
	Config  []byte // jsonb tunnel config (secret material lives by reference only)
	Enabled bool
	Created time.Time
	Updated time.Time
}

// TargetHost is a host reachable only via a VPN profile, exposed under a public
// alias by the proxy (spec §6).
type TargetHost struct {
	ID           int64
	PublicAlias  string
	PrivateIP    string
	Port         int
	Protocol     string
	VPNProfileID int64
	HealthCheck  string
	Enabled      bool
}

// ProxyRule maps an inbound host/path match to a target, by priority (spec §6).
type ProxyRule struct {
	ID           int64
	Priority     int
	MatchHost    string
	MatchPath    string
	TargetHostID int64
	Enabled      bool
}

// TargetTunnelTier is one entry in a target's ordered failover list — lower tier
// = higher preference (spec §6, feature §11 ①).
type TargetTunnelTier struct {
	TargetID     int64
	VPNProfileID int64
	Tier         int
}

// ProxyUser is a per-user proxy-auth principal. The secret lives by reference
// (Podman secret / file ref) only, NEVER in the row (spec §12, §11.4.10).
type ProxyUser struct {
	ID        int64
	Username  string
	SecretRef string
}

// AuditLogEntry records a control-plane mutation for the audit trail (spec §12).
type AuditLogEntry struct {
	ID     int64
	TS     time.Time
	Actor  string
	Action string
	Detail string
}

// Queries is the read/write contract over the data model. Implementations are
// the only place SQL lives; callers depend on this interface, not on pgx.
type Queries interface {
	ListProfiles(ctx context.Context) ([]VPNProfile, error)
	ListTargets(ctx context.Context) ([]TargetHost, error)
	ListRules(ctx context.Context) ([]ProxyRule, error)
	ListTiers(ctx context.Context, targetID int64) ([]TargetTunnelTier, error)
	UpsertProfile(ctx context.Context, p VPNProfile) (int64, error)
	UpsertTarget(ctx context.Context, t TargetHost) (int64, error)
	UpsertRule(ctx context.Context, r ProxyRule) (int64, error)
	AppendAudit(ctx context.Context, e AuditLogEntry) error
}
