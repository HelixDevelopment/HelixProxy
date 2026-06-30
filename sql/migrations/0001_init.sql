-- =============================================================================
-- Migration 0001 — init
-- Helix Proxy VPN-Aware Dynamic Routing Extension — initial schema.
-- =============================================================================
--
-- Authority : design spec §6 + sql/schema.sql (cumulative result of all
--             migrations == sql/schema.sql for this release).
-- Apply with: psql -v ON_ERROR_STOP=1 -f sql/migrations/0001_init.sql
--
-- Idempotency: wrapped so re-running is a safe no-op. A schema_migrations
-- ledger records applied versions; if 0001 is already recorded the body is
-- skipped. All object creation additionally uses IF NOT EXISTS / CREATE OR
-- REPLACE so a partial prior run still converges.
-- =============================================================================

BEGIN;

-- Migration ledger (created on first migration, idempotent).
CREATE TABLE IF NOT EXISTS schema_migrations (
    version     INTEGER PRIMARY KEY,
    name        VARCHAR(255) NOT NULL,
    applied_at  TIMESTAMPTZ  NOT NULL DEFAULT now()
);

COMMENT ON TABLE schema_migrations IS 'Forward-migration ledger: one row per applied numbered migration.';

DO $migration$
BEGIN
    IF EXISTS (SELECT 1 FROM schema_migrations WHERE version = 1) THEN
        RAISE NOTICE 'migration 0001_init already applied — skipping';
        RETURN;
    END IF;

    -- ---- extensions -------------------------------------------------------
    CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

    -- ---- shared updated_at trigger function -------------------------------
    CREATE OR REPLACE FUNCTION set_updated_at()
    RETURNS TRIGGER AS $fn$
    BEGIN
        NEW.updated_at = now();
        RETURN NEW;
    END;
    $fn$ LANGUAGE plpgsql;

    -- ---- vpn_profiles -----------------------------------------------------
    CREATE TABLE IF NOT EXISTS vpn_profiles (
        id          UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
        name        VARCHAR(255) NOT NULL UNIQUE,
        type        VARCHAR(50)  NOT NULL DEFAULT 'wireguard',
        config      JSONB        NOT NULL DEFAULT '{}'::jsonb,
        secret_ref  VARCHAR(255),
        enabled     BOOLEAN      NOT NULL DEFAULT true,
        created_at  TIMESTAMPTZ  NOT NULL DEFAULT now(),
        updated_at  TIMESTAMPTZ  NOT NULL DEFAULT now(),
        CONSTRAINT vpn_profiles_type_chk
            CHECK (type IN ('wireguard', 'openvpn', 'legacy'))
    );

    -- ---- target_hosts -----------------------------------------------------
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

    -- ---- target_tunnel_tiers ---------------------------------------------
    CREATE TABLE IF NOT EXISTS target_tunnel_tiers (
        target_host_id  UUID    NOT NULL REFERENCES target_hosts(id) ON DELETE CASCADE,
        vpn_profile_id  UUID    NOT NULL REFERENCES vpn_profiles(id) ON DELETE CASCADE,
        tier            INTEGER NOT NULL DEFAULT 0,
        created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
        PRIMARY KEY (target_host_id, tier),
        CONSTRAINT target_tunnel_tiers_tier_chk
            CHECK (tier >= 0),
        CONSTRAINT target_tunnel_tiers_unique_profile
            UNIQUE (target_host_id, vpn_profile_id)
    );
    CREATE INDEX IF NOT EXISTS idx_ttt_profile ON target_tunnel_tiers(vpn_profile_id);

    -- ---- proxy_rules ------------------------------------------------------
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
    CREATE INDEX IF NOT EXISTS idx_proxy_rules_priority ON proxy_rules(priority DESC);
    CREATE INDEX IF NOT EXISTS idx_proxy_rules_target   ON proxy_rules(target_host_id);
    CREATE INDEX IF NOT EXISTS idx_proxy_rules_match_host
        ON proxy_rules(match_host) WHERE enabled = true;

    -- ---- proxy_users ------------------------------------------------------
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
        CONSTRAINT proxy_users_secret_ref_nonempty_chk
            CHECK (length(trim(secret_ref)) > 0)
    );

    -- ---- audit_log --------------------------------------------------------
    CREATE TABLE IF NOT EXISTS audit_log (
        id      BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
        ts      TIMESTAMPTZ NOT NULL DEFAULT now(),
        actor   VARCHAR(255) NOT NULL,
        action  VARCHAR(100) NOT NULL,
        detail  JSONB        NOT NULL DEFAULT '{}'::jsonb
    );
    CREATE INDEX IF NOT EXISTS idx_audit_log_ts     ON audit_log(ts DESC);
    CREATE INDEX IF NOT EXISTS idx_audit_log_actor  ON audit_log(actor);
    CREATE INDEX IF NOT EXISTS idx_audit_log_action ON audit_log(action);

    -- ---- record migration -------------------------------------------------
    INSERT INTO schema_migrations (version, name) VALUES (1, '0001_init');
END
$migration$;

-- ---- triggers ------------------------------------------------------------
-- Triggers are dropped+recreated outside the guard so they converge even on a
-- partial prior run (CREATE TRIGGER has no IF NOT EXISTS before PG 14).
DROP TRIGGER IF EXISTS trg_vpn_profiles_updated_at ON vpn_profiles;
CREATE TRIGGER trg_vpn_profiles_updated_at
    BEFORE UPDATE ON vpn_profiles
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

DROP TRIGGER IF EXISTS trg_target_hosts_updated_at ON target_hosts;
CREATE TRIGGER trg_target_hosts_updated_at
    BEFORE UPDATE ON target_hosts
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

DROP TRIGGER IF EXISTS trg_proxy_rules_updated_at ON proxy_rules;
CREATE TRIGGER trg_proxy_rules_updated_at
    BEFORE UPDATE ON proxy_rules
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

DROP TRIGGER IF EXISTS trg_proxy_users_updated_at ON proxy_users;
CREATE TRIGGER trg_proxy_users_updated_at
    BEFORE UPDATE ON proxy_users
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

COMMIT;
