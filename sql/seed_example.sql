-- =============================================================================
-- Helix Proxy — example seed data (NON-SECRET)
-- =============================================================================
--
-- Purpose : populate a dev/test database with realistic example rows so the
--           control-plane, ER diagram, and docs can be demonstrated end-to-end.
-- Safety  : contains NO real credentials (§11.4.10). Every secret_ref is a
--           Podman-secret NAME placeholder; the config jsonb carries only
--           non-secret tunnel parameters and "secret-ref" pointers — never key
--           material. Safe to commit and re-run.
-- Apply   : psql -v ON_ERROR_STOP=1 -f sql/seed_example.sql   (after the schema)
-- Re-run  : idempotent — ON CONFLICT DO NOTHING on the natural keys.
-- =============================================================================

BEGIN;

-- ---- VPN profiles ---------------------------------------------------------
INSERT INTO vpn_profiles (name, type, config, secret_ref, enabled) VALUES
  ('eu-wg-primary', 'wireguard',
   '{"endpoint":"vpn-eu.example.net:51820","allowed_ips":"10.10.0.0/16","dns":"10.10.0.53","mtu":1380,"private_key_ref":"helix_vpn_eu_wg_key"}'::jsonb,
   'helix_vpn_eu_wg_key', true),
  ('us-wg-failover', 'wireguard',
   '{"endpoint":"vpn-us.example.net:51820","allowed_ips":"10.20.0.0/16","dns":"10.20.0.53","mtu":1380,"private_key_ref":"helix_vpn_us_wg_key"}'::jsonb,
   'helix_vpn_us_wg_key', true),
  ('apac-ovpn', 'openvpn',
   '{"remote":"vpn-apac.example.net","port":1194,"proto":"udp","auth_ref":"helix_vpn_apac_ovpn_auth"}'::jsonb,
   'helix_vpn_apac_ovpn_auth', true),
  ('legacy-openvpn', 'legacy',
   '{"note":"retained dperson/openvpn-client, deprecated (spec §5) — do not remove without operator confirmation per §11.4.122","auth_ref":"helix_vpn_legacy_auth"}'::jsonb,
   'helix_vpn_legacy_auth', false)
ON CONFLICT (name) DO NOTHING;

-- ---- Target hosts ---------------------------------------------------------
INSERT INTO target_hosts (public_alias, private_ip, port, protocol, vpn_profile_id, health_check, enabled)
SELECT 'internal-wiki.helix', '10.10.5.20', 443, 'https',
       (SELECT id FROM vpn_profiles WHERE name = 'eu-wg-primary'),
       'https://10.10.5.20/health', true
WHERE NOT EXISTS (SELECT 1 FROM target_hosts WHERE public_alias = 'internal-wiki.helix');

INSERT INTO target_hosts (public_alias, private_ip, port, protocol, vpn_profile_id, health_check, enabled)
SELECT 'metrics.helix', '10.10.5.30', 9090, 'http',
       (SELECT id FROM vpn_profiles WHERE name = 'eu-wg-primary'),
       'http://10.10.5.30/-/healthy', true
WHERE NOT EXISTS (SELECT 1 FROM target_hosts WHERE public_alias = 'metrics.helix');

INSERT INTO target_hosts (public_alias, private_ip, port, protocol, vpn_profile_id, health_check, enabled)
SELECT 'db-bastion.helix', '10.20.7.10', 5432, 'tcp',
       (SELECT id FROM vpn_profiles WHERE name = 'us-wg-failover'),
       '10.20.7.10:5432', true
WHERE NOT EXISTS (SELECT 1 FROM target_hosts WHERE public_alias = 'db-bastion.helix');

-- ---- Target tunnel tiers (ordered failover) -------------------------------
-- internal-wiki: primary EU, failover US.
INSERT INTO target_tunnel_tiers (target_host_id, vpn_profile_id, tier)
SELECT (SELECT id FROM target_hosts  WHERE public_alias = 'internal-wiki.helix'),
       (SELECT id FROM vpn_profiles  WHERE name = 'eu-wg-primary'), 0
ON CONFLICT (target_host_id, tier) DO NOTHING;

INSERT INTO target_tunnel_tiers (target_host_id, vpn_profile_id, tier)
SELECT (SELECT id FROM target_hosts  WHERE public_alias = 'internal-wiki.helix'),
       (SELECT id FROM vpn_profiles  WHERE name = 'us-wg-failover'), 1
ON CONFLICT (target_host_id, tier) DO NOTHING;

-- metrics: primary EU, failover APAC.
INSERT INTO target_tunnel_tiers (target_host_id, vpn_profile_id, tier)
SELECT (SELECT id FROM target_hosts  WHERE public_alias = 'metrics.helix'),
       (SELECT id FROM vpn_profiles  WHERE name = 'eu-wg-primary'), 0
ON CONFLICT (target_host_id, tier) DO NOTHING;

INSERT INTO target_tunnel_tiers (target_host_id, vpn_profile_id, tier)
SELECT (SELECT id FROM target_hosts  WHERE public_alias = 'metrics.helix'),
       (SELECT id FROM vpn_profiles  WHERE name = 'apac-ovpn'), 1
ON CONFLICT (target_host_id, tier) DO NOTHING;

-- db-bastion: single tunnel (US).
INSERT INTO target_tunnel_tiers (target_host_id, vpn_profile_id, tier)
SELECT (SELECT id FROM target_hosts  WHERE public_alias = 'db-bastion.helix'),
       (SELECT id FROM vpn_profiles  WHERE name = 'us-wg-failover'), 0
ON CONFLICT (target_host_id, tier) DO NOTHING;

-- ---- Proxy rules ----------------------------------------------------------
INSERT INTO proxy_rules (priority, match_host, match_path, target_host_id, enabled)
SELECT 100, 'internal-wiki.helix', NULL,
       (SELECT id FROM target_hosts WHERE public_alias = 'internal-wiki.helix'), true
WHERE NOT EXISTS (
    SELECT 1 FROM proxy_rules WHERE match_host = 'internal-wiki.helix' AND match_path IS NULL
);

INSERT INTO proxy_rules (priority, match_host, match_path, target_host_id, enabled)
SELECT 90, 'metrics.helix', '/api/',
       (SELECT id FROM target_hosts WHERE public_alias = 'metrics.helix'), true
WHERE NOT EXISTS (
    SELECT 1 FROM proxy_rules WHERE match_host = 'metrics.helix' AND match_path = '/api/'
);

INSERT INTO proxy_rules (priority, match_host, match_path, target_host_id, enabled)
SELECT 80, 'db-bastion.helix', NULL,
       (SELECT id FROM target_hosts WHERE public_alias = 'db-bastion.helix'), true
WHERE NOT EXISTS (
    SELECT 1 FROM proxy_rules WHERE match_host = 'db-bastion.helix' AND match_path IS NULL
);

-- ---- Proxy users (auth identities — NO passwords, refs only) --------------
INSERT INTO proxy_users (username, secret_ref, role, enabled) VALUES
  ('admin',      'helix_proxy_user_admin_htpasswd', 'admin', true),
  ('svc-ci',     'helix_proxy_user_svcci_token',    'user',  true),
  ('analyst-1',  'helix_proxy_user_analyst1_htpasswd', 'user', true)
ON CONFLICT (username) DO NOTHING;

-- ---- Audit log (example bootstrap events) ---------------------------------
INSERT INTO audit_log (actor, action, detail) VALUES
  ('system',           'seed.load',      '{"source":"sql/seed_example.sql","note":"example non-secret bootstrap data"}'::jsonb),
  ('config-compiler',  'config.compile', '{"profiles":4,"targets":3,"rules":3}'::jsonb),
  ('admin',            'user.login',     '{"username":"admin","via":"control-api","mtls":true}'::jsonb);

COMMIT;
