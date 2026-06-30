-- =============================================================================
-- Helix Proxy — VPN-Aware Dynamic Routing Extension
-- Canonical PostgreSQL schema (full, current-state DDL)
-- =============================================================================
--
-- Authority   : Design spec docs/superpowers/specs/2026-06-30-vpn-aware-proxy-
--               extension-design.md §6 + research scaffold
--               docs/research/mvp/proxy-vpn-extension/sql/schema.sql.
-- Target      : PostgreSQL 15+ (validated on 16-alpine).
-- Scope       : The Postgres control-plane source of truth. The Go control-plane
--               (config-compiler / health-publisher / external-acl-helper /
--               control-API) reads this and renders Squid/Dante config + writes
--               Redis. NOTHING in this schema stores a plaintext secret
--               (§11.4.10): VPN creds and proxy-auth secrets live in Podman
--               secrets; only the *reference name* is stored here.
--
-- This file is the declarative full schema. Forward migrations live under
-- sql/migrations/ and MUST keep this file as their cumulative result
-- (sql/migrations/0001_init.sql == this schema for the initial release).
--
-- Idempotency: object creation uses IF NOT EXISTS where PostgreSQL supports it
-- so a re-run against an existing database is a no-op rather than an error.
-- =============================================================================

-- uuid_generate_v4() for primary keys.
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- -----------------------------------------------------------------------------
-- Shared trigger function: keep updated_at honest on every UPDATE.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION set_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = now();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION set_updated_at() IS
    'BEFORE UPDATE trigger helper: stamps updated_at = now() on every row mutation.';

-- =============================================================================
-- TABLE: vpn_profiles
-- One row per VPN tunnel definition. One profile == one gluetun container ==
-- one network namespace == one Redis key vpn:status:<name> (spec §5/§7).
-- =============================================================================
CREATE TABLE IF NOT EXISTS vpn_profiles (
    id          UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    name        VARCHAR(255) NOT NULL UNIQUE,
    type        VARCHAR(50)  NOT NULL DEFAULT 'wireguard',
    config      JSONB        NOT NULL DEFAULT '{}'::jsonb,
    secret_ref  VARCHAR(255),
    enabled     BOOLEAN      NOT NULL DEFAULT true,
    created_at  TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at  TIMESTAMPTZ  NOT NULL DEFAULT now(),

    -- Only the tunnel types the VPN layer (spec §5) actually implements.
    CONSTRAINT vpn_profiles_type_chk
        CHECK (type IN ('wireguard', 'openvpn', 'legacy'))
);

COMMENT ON TABLE  vpn_profiles               IS 'VPN tunnel definitions; 1 profile = 1 gluetun container = 1 netns = 1 vpn:status:<name> Redis key.';
COMMENT ON COLUMN vpn_profiles.id            IS 'Surrogate primary key (UUID v4).';
COMMENT ON COLUMN vpn_profiles.name          IS 'Stable human/machine-friendly identifier; used verbatim as the Redis status key suffix and Squid cache_peer name (resolve by name, never by index — §11.4.111).';
COMMENT ON COLUMN vpn_profiles.type          IS 'Tunnel technology: wireguard (preferred), openvpn (compat), legacy (the retained-but-deprecated dperson/openvpn-client, spec §5).';
COMMENT ON COLUMN vpn_profiles.config        IS 'Non-secret tunnel parameters as JSONB (endpoint host/port, allowed_ips, DNS server, MTU, gluetun provider knobs). NEVER a private key/password — those are Podman secrets referenced by secret_ref (§11.4.10).';
COMMENT ON COLUMN vpn_profiles.secret_ref    IS 'Name of the Podman secret holding this tunnel''s credentials (wg private key / ovpn auth). A reference string only — never the secret material itself (§11.4.10).';
COMMENT ON COLUMN vpn_profiles.enabled       IS 'When false the compiler omits this profile from generated Squid/Dante config and the health-publisher stops polling it.';
COMMENT ON COLUMN vpn_profiles.created_at    IS 'Row creation timestamp (UTC).';
COMMENT ON COLUMN vpn_profiles.updated_at    IS 'Last mutation timestamp (UTC); maintained by the set_updated_at trigger.';

CREATE TRIGGER trg_vpn_profiles_updated_at
    BEFORE UPDATE ON vpn_profiles
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- =============================================================================
-- TABLE: target_hosts
-- A backend reachable (often) only via a VPN tunnel. public_alias is the
-- externally-presented hostname clients use; the proxy maps it to the private
-- destination and the bound VPN profile.
-- =============================================================================
CREATE TABLE IF NOT EXISTS target_hosts (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    public_alias    VARCHAR(255) NOT NULL UNIQUE,
    private_ip      INET         NOT NULL,
    port            INTEGER      NOT NULL DEFAULT 80,
    protocol        VARCHAR(10)  NOT NULL DEFAULT 'http',
    vpn_profile_id  UUID         REFERENCES vpn_profiles(id) ON DELETE SET NULL,
    health_check    VARCHAR(500),
    enabled         BOOLEAN      NOT NULL DEFAULT true,
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),

    CONSTRAINT target_hosts_port_chk
        CHECK (port BETWEEN 1 AND 65535),
    CONSTRAINT target_hosts_protocol_chk
        CHECK (protocol IN ('http', 'https', 'tcp', 'socks5'))
);

COMMENT ON TABLE  target_hosts                IS 'Backends reachable (typically) only through a VPN tunnel; the routing destinations of the proxy.';
COMMENT ON COLUMN target_hosts.id             IS 'Surrogate primary key (UUID v4).';
COMMENT ON COLUMN target_hosts.public_alias   IS 'Externally-presented hostname clients request (the Squid Host-header / Dante destination match key).';
COMMENT ON COLUMN target_hosts.private_ip     IS 'Private destination address inside the VPN (INET; IPv4 or IPv6 for the dual-stack feature, spec §11⑦).';
COMMENT ON COLUMN target_hosts.port           IS 'Destination TCP port on the backend (1-65535).';
COMMENT ON COLUMN target_hosts.protocol       IS 'Application protocol used to reach the backend: http | https | tcp | socks5.';
COMMENT ON COLUMN target_hosts.vpn_profile_id IS 'Default/primary tunnel for this target. ON DELETE SET NULL: deleting a profile orphans the target (it stops routing) rather than silently deleting the target; ordered failover lives in target_tunnel_tiers.';
COMMENT ON COLUMN target_hosts.health_check   IS 'Optional health-probe spec (URL or host:port) the health-publisher uses to confirm the backend is live through the tunnel — a data-plane signal, not a "configured" claim (spec §13).';
COMMENT ON COLUMN target_hosts.enabled        IS 'When false the target is excluded from generated routing config.';
COMMENT ON COLUMN target_hosts.created_at     IS 'Row creation timestamp (UTC).';
COMMENT ON COLUMN target_hosts.updated_at     IS 'Last mutation timestamp (UTC); maintained by the set_updated_at trigger.';

CREATE TRIGGER trg_target_hosts_updated_at
    BEFORE UPDATE ON target_hosts
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- =============================================================================
-- TABLE: target_tunnel_tiers   (spec §6 extension / §11 feature ①)
-- Ordered failover list: for a given target, which tunnels to try and in what
-- order. tier 0 = primary, 1 = first failover, etc. The circuit-breaker
-- (external-acl-helper, sony/gobreaker) walks tiers ascending until it finds an
-- "up" tunnel, else returns a graceful 503 (spec §10/§11①).
-- PRIMARY KEY(target_host_id, tier) enforces one tunnel per tier per target.
-- =============================================================================
CREATE TABLE IF NOT EXISTS target_tunnel_tiers (
    target_host_id  UUID    NOT NULL REFERENCES target_hosts(id)  ON DELETE CASCADE,
    vpn_profile_id  UUID    NOT NULL REFERENCES vpn_profiles(id)  ON DELETE CASCADE,
    tier            INTEGER NOT NULL DEFAULT 0,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),

    PRIMARY KEY (target_host_id, tier),
    CONSTRAINT target_tunnel_tiers_tier_chk
        CHECK (tier >= 0),
    -- A given tunnel may appear at most once in a target's failover chain.
    CONSTRAINT target_tunnel_tiers_unique_profile
        UNIQUE (target_host_id, vpn_profile_id)
);

COMMENT ON TABLE  target_tunnel_tiers                IS 'Ordered VPN-tunnel failover chain per target (spec §11 feature ①). tier 0 = primary; the circuit-breaker tries ascending tiers until one is up, else graceful 503.';
COMMENT ON COLUMN target_tunnel_tiers.target_host_id IS 'Target this failover chain belongs to. ON DELETE CASCADE: removing the target removes its chain.';
COMMENT ON COLUMN target_tunnel_tiers.vpn_profile_id IS 'Tunnel to use at this tier. ON DELETE CASCADE: removing the profile removes the tier rows that reference it.';
COMMENT ON COLUMN target_tunnel_tiers.tier           IS 'Zero-based failover order: 0 = primary, 1 = first failover, … Lower tier is tried first.';
COMMENT ON COLUMN target_tunnel_tiers.created_at     IS 'Row creation timestamp (UTC).';

CREATE INDEX IF NOT EXISTS idx_ttt_profile ON target_tunnel_tiers(vpn_profile_id);

-- =============================================================================
-- TABLE: proxy_rules
-- Request-matching rules that select a target. Highest priority first (the
-- compiler orders by priority DESC). match_host / match_path are optional
-- predicates; a NULL predicate matches anything.
-- =============================================================================
CREATE TABLE IF NOT EXISTS proxy_rules (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    priority        INTEGER      NOT NULL DEFAULT 0,
    match_host      VARCHAR(255),
    match_path      VARCHAR(500),
    target_host_id  UUID         REFERENCES target_hosts(id) ON DELETE CASCADE,
    enabled         BOOLEAN      NOT NULL DEFAULT true,
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),

    CONSTRAINT proxy_rules_match_present_chk
        CHECK (match_host IS NOT NULL OR match_path IS NOT NULL)
);

COMMENT ON TABLE  proxy_rules                IS 'Request-matching rules that map an incoming request to a target_host; evaluated highest priority first.';
COMMENT ON COLUMN proxy_rules.id             IS 'Surrogate primary key (UUID v4).';
COMMENT ON COLUMN proxy_rules.priority       IS 'Match precedence; the compiler evaluates rules in DESC priority order (higher wins).';
COMMENT ON COLUMN proxy_rules.match_host     IS 'Optional Host predicate (exact or glob, interpreted by the compiler). NULL = match any host. At least one of match_host/match_path must be set.';
COMMENT ON COLUMN proxy_rules.match_path     IS 'Optional request-path predicate. NULL = match any path. At least one of match_host/match_path must be set.';
COMMENT ON COLUMN proxy_rules.target_host_id IS 'Target selected when this rule matches. ON DELETE CASCADE: deleting the target removes its rules.';
COMMENT ON COLUMN proxy_rules.enabled        IS 'When false the rule is excluded from generated config.';
COMMENT ON COLUMN proxy_rules.created_at     IS 'Row creation timestamp (UTC).';
COMMENT ON COLUMN proxy_rules.updated_at     IS 'Last mutation timestamp (UTC); maintained by the set_updated_at trigger.';

CREATE TRIGGER trg_proxy_rules_updated_at
    BEFORE UPDATE ON proxy_rules
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE INDEX IF NOT EXISTS idx_proxy_rules_priority ON proxy_rules(priority DESC);
CREATE INDEX IF NOT EXISTS idx_proxy_rules_target   ON proxy_rules(target_host_id);
-- Fast lookup of enabled rules by host (the compiler's hot path).
CREATE INDEX IF NOT EXISTS idx_proxy_rules_match_host
    ON proxy_rules(match_host) WHERE enabled = true;

-- =============================================================================
-- TABLE: proxy_users   (spec §6 extension / §12 zero-trust auth)
-- Per-user proxy authentication identities. NO password column ever — the
-- secret (htpasswd entry / bcrypt hash / token) lives in a Podman secret;
-- secret_ref names it (§11.4.10).
-- =============================================================================
CREATE TABLE IF NOT EXISTS proxy_users (
    id          UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    username    VARCHAR(255) NOT NULL UNIQUE,
    secret_ref  VARCHAR(255) NOT NULL,
    role        VARCHAR(50)  NOT NULL DEFAULT 'user',
    enabled     BOOLEAN      NOT NULL DEFAULT true,
    created_at  TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at  TIMESTAMPTZ  NOT NULL DEFAULT now(),

    CONSTRAINT proxy_users_role_chk
        CHECK (role IN ('admin', 'user')),
    -- Defensive: the ref must not look like a bare secret committed by mistake.
    CONSTRAINT proxy_users_secret_ref_nonempty_chk
        CHECK (length(trim(secret_ref)) > 0)
);

COMMENT ON TABLE  proxy_users             IS 'Per-user proxy-auth identities (Squid basic/digest auth, control-API). Holds NO password — only secret_ref naming a Podman secret (§11.4.10/§12).';
COMMENT ON COLUMN proxy_users.id          IS 'Surrogate primary key (UUID v4).';
COMMENT ON COLUMN proxy_users.username    IS 'Login name presented to the proxy / control-API; unique.';
COMMENT ON COLUMN proxy_users.secret_ref  IS 'Name of the Podman secret holding this user''s credential material (htpasswd line / bcrypt hash / API token). A reference only — NEVER the plaintext password (§11.4.10).';
COMMENT ON COLUMN proxy_users.role        IS 'Authorization role: admin (full control-API CRUD) or user (proxy egress only).';
COMMENT ON COLUMN proxy_users.enabled     IS 'When false the user is denied authentication.';
COMMENT ON COLUMN proxy_users.created_at  IS 'Row creation timestamp (UTC).';
COMMENT ON COLUMN proxy_users.updated_at  IS 'Last mutation timestamp (UTC); maintained by the set_updated_at trigger.';

CREATE TRIGGER trg_proxy_users_updated_at
    BEFORE UPDATE ON proxy_users
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- =============================================================================
-- TABLE: audit_log   (spec §6 extension / §12 audit)
-- Append-only record of every control-plane mutation and security-relevant
-- event (who did what, when, with what detail). Never UPDATEd or DELETEd by the
-- application (retention/rotation is an operational concern).
-- =============================================================================
CREATE TABLE IF NOT EXISTS audit_log (
    id      BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    ts      TIMESTAMPTZ NOT NULL DEFAULT now(),
    actor   VARCHAR(255) NOT NULL,
    action  VARCHAR(100) NOT NULL,
    detail  JSONB        NOT NULL DEFAULT '{}'::jsonb
);

COMMENT ON TABLE  audit_log         IS 'Append-only audit trail of control-plane mutations and security events (§12). Application never UPDATE/DELETEs rows.';
COMMENT ON COLUMN audit_log.id      IS 'Monotonic surrogate key (IDENTITY bigint); ordering reflects insertion order.';
COMMENT ON COLUMN audit_log.ts      IS 'Event timestamp (UTC).';
COMMENT ON COLUMN audit_log.actor   IS 'Who triggered the event: a proxy_users.username, a service name (e.g. config-compiler), or "system".';
COMMENT ON COLUMN audit_log.action  IS 'Short verb describing the event (e.g. profile.create, target.update, rule.delete, user.login, tunnel.failover).';
COMMENT ON COLUMN audit_log.detail  IS 'Structured event payload as JSONB (changed fields, old/new values, request id). MUST NOT contain secret material (§11.4.10).';

-- Common audit queries: by time window, by actor, by action.
CREATE INDEX IF NOT EXISTS idx_audit_log_ts     ON audit_log(ts DESC);
CREATE INDEX IF NOT EXISTS idx_audit_log_actor  ON audit_log(actor);
CREATE INDEX IF NOT EXISTS idx_audit_log_action ON audit_log(action);

-- =============================================================================
-- End of schema.
-- =============================================================================
