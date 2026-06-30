CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

CREATE TABLE vpn_profiles (
    id          UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    name        VARCHAR(255) NOT NULL UNIQUE,
    type        VARCHAR(50) NOT NULL DEFAULT 'wireguard',
    config      JSONB NOT NULL,
    enabled     BOOLEAN NOT NULL DEFAULT true,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE target_hosts (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    public_alias    VARCHAR(255) NOT NULL UNIQUE,
    private_ip      INET NOT NULL,
    port            INTEGER NOT NULL DEFAULT 80,
    protocol        VARCHAR(10) NOT NULL DEFAULT 'http',
    vpn_profile_id  UUID REFERENCES vpn_profiles(id) ON DELETE SET NULL,
    health_check    VARCHAR(500),
    enabled         BOOLEAN NOT NULL DEFAULT true,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE proxy_rules (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    priority        INTEGER NOT NULL DEFAULT 0,
    match_host      VARCHAR(255),
    match_path      VARCHAR(500),
    target_host_id  UUID REFERENCES target_hosts(id) ON DELETE CASCADE,
    enabled         BOOLEAN NOT NULL DEFAULT true,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_target_hosts_alias ON target_hosts(public_alias);
CREATE INDEX idx_proxy_rules_priority ON proxy_rules(priority);
