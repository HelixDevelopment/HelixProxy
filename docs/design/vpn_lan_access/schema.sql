-- =============================================================================
-- schema.sql — VPN-LAN discovered-host / route / protocol-capability registry
--
-- Revision:      1
-- Last modified: 2026-07-01T16:30:58Z
-- Status:        Design DDL — the "SQL and all others" definitions deliverable of
--                Phase 9 docs (docs/design/vpn_lan_access/PLAN.md §5 / §9).
-- Authority:     Inherits constitution/Constitution.md per §11.4.35. Companion to
--                architecture.md (§2 per-protocol routing decision table — this
--                schema stores that table as data), reflector_design.md (Phase 5
--                discovery), and the operator setup guide guides/vpn_lan_bridge_setup.md.
-- Feature:       feature/vpn-aware-dynamic-routing (§11.4.167)
--
-- Purpose:
--   A documented, minimal schema for an inventory/registry of what helix_proxy
--   has DISCOVERED on the svord VPN-internal subnet (10.0.0.0/8): the hosts, the
--   services they expose, the routing primitive helix_proxy uses to carry each
--   protocol, the static per-protocol capability catalogue (the architecture.md §2
--   decision table encoded as reference data), and an append-only discovery-event
--   audit log. This is a schema DEFINITION only — pure DDL + comments; it carries
--   NO secrets and NO live data (§11.4.10). Addresses in comment examples are the
--   documented recon addresses (10.6.100.221) — not credentials.
--
-- Dialect:
--   Written for SQLite (the project's SSoT engine; §11.4.93 uses SQLite for the
--   workable-items DB). Kept close to ANSI SQL: FOREIGN KEY + CHECK constraints,
--   no engine-specific types beyond SQLite's affinity model. `STRICT` tables are
--   used so declared column types are enforced (SQLite >= 3.37). Timestamps are
--   ISO-8601 UTC TEXT (e.g. '2026-07-01T16:30:58Z') per §11.4.44.
--
-- Anti-bluff note (§11.4.6 / §11.4.69):
--   discovery_event.verdict / skip_reason mirror the test harness's closed-set
--   vocabulary so a stored PASS is only ever an evidence-backed one (evidence_path
--   points at a qa-results/vpn_lan/<phase>/<ts>/ artefact). A stored PASS with no
--   evidence_path is a schema-level anti-pattern (see the CHECK on discovery_event).
--
-- Cross-references:
--   docs/design/vpn_lan_access/architecture.md   (§2 routing decision table)
--   docs/design/vpn_lan_access/PLAN.md           (§2 routing map, §3 contract)
--   docs/design/vpn_lan_access/reflector_design.md (Phase 5 discovery)
--   tests/vpn_lan/*.sh                           (produce the discovery_event rows)
-- =============================================================================

PRAGMA foreign_keys = ON;   -- enforce referential integrity (off by default in SQLite)

-- -----------------------------------------------------------------------------
-- protocol_capability
--   The static per-protocol CATALOGUE — the architecture.md §2 routing decision
--   table encoded as reference data. Seeded once, rarely changed. Every
--   host_service references exactly one row here by protocol_name so the correct
--   carrying primitive is a JOIN away, never re-derived ad hoc (§11.4.111 resolve
--   by a stable name, not by a magic constant scattered in code).
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS protocol_capability (
    capability_id   INTEGER PRIMARY KEY,            -- surrogate key (autoincrement rowid)
    protocol_name   TEXT    NOT NULL UNIQUE,         -- canonical protocol id, e.g. 'smb','nfs','imaps','webdav','googlecast','adb','mdns','miracast'
    default_port    INTEGER,                         -- well-known port (NULL for portless/USB/L2, e.g. miracast, fastboot)
    transport       TEXT    NOT NULL                 -- L4 transport
                    CHECK (transport IN ('tcp','udp','tcp+udp','http','usb','l2')),
    traffic_class   TEXT    NOT NULL                 -- the architecture.md §2 traffic class
                    CHECK (traffic_class IN ('unicast_tcp','unicast_udp','http_shaped','multicast_discovery','usb_level','l2_radio')),
    primitive       TEXT    NOT NULL                 -- the carrying primitive helix_proxy selects
                    CHECK (primitive IN ('l3_route','squid_proxy','remote_reflector','usbip','structurally_impossible')),
    why             TEXT    NOT NULL,                 -- the deciding fact (the WHY column of architecture.md §2) — human-readable
    status          TEXT    NOT NULL DEFAULT 'designed' -- lifecycle of the capability's support
                    CHECK (status IN ('designed','proven','operator_gated','honest_boundary','wont_fix')),
    reference_doc   TEXT                              -- pointer to the authoritative doc/section, e.g. 'architecture.md §2'
) STRICT;

-- Fast lookup by protocol_name (the JOIN key host_service uses).
CREATE UNIQUE INDEX IF NOT EXISTS ix_protocol_capability_name
    ON protocol_capability (protocol_name);

-- -----------------------------------------------------------------------------
-- discovered_host
--   A host observed on the remote VPN-internal subnet. The stable identity is the
--   routable IP address (§11.4.111 — bind by the stable 10.x address, NOT by an
--   enumeration ordinal); hostname (mDNS/NetBIOS) is advisory only because NetBIOS
--   name resolution is not routed across L3 (architecture.md §2).
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS discovered_host (
    host_id         INTEGER PRIMARY KEY,            -- surrogate key
    ip_addr         TEXT    NOT NULL UNIQUE,         -- routable address on the VPN subnet, e.g. '10.6.100.221' (the STABLE identity)
    hostname        TEXT,                            -- advisory mDNS/DNS-SD/NetBIOS name (may be NULL; not routable across L3)
    subnet_cidr     TEXT    NOT NULL DEFAULT '10.0.0.0/8', -- the HELIX_BRIDGE_SUBNET this host lives in
    discovery_method TEXT   NOT NULL                 -- how the host was first found
                    CHECK (discovery_method IN ('mdns','dnssd','ssdp','wsdiscovery','route_probe','manual')),
    reachable       INTEGER NOT NULL DEFAULT 0       -- 0/1 boolean: last known reachability over the routed VPN
                    CHECK (reachable IN (0,1)),
    first_seen_utc  TEXT    NOT NULL,                -- ISO-8601 UTC first-observation timestamp
    last_seen_utc   TEXT    NOT NULL,                -- ISO-8601 UTC most-recent-observation timestamp
    notes           TEXT                             -- free-form operator/agent note (NO secrets — §11.4.10)
) STRICT;

CREATE INDEX IF NOT EXISTS ix_discovered_host_reachable
    ON discovered_host (reachable);

-- -----------------------------------------------------------------------------
-- host_service
--   A concrete service (port + protocol) exposed by a discovered_host. Each row
--   ties a host to one protocol_capability so the carrying primitive is resolvable
--   by JOIN. A host may expose many services (SMB + NFS + IMAPS ...).
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS host_service (
    service_id      INTEGER PRIMARY KEY,            -- surrogate key
    host_id         INTEGER NOT NULL,               -- FK -> discovered_host (owning host)
    protocol_name   TEXT    NOT NULL,               -- FK -> protocol_capability.protocol_name (the capability catalogue)
    port            INTEGER,                         -- actual observed port (may differ from the catalogue default; NULL for portless)
    tls_mode        TEXT    NOT NULL DEFAULT 'none'  -- observed TLS posture (implicit-TLS preferred, RFC 8314 — architecture.md §2 email row)
                    CHECK (tls_mode IN ('none','implicit','starttls','unknown')),
    service_state   TEXT    NOT NULL DEFAULT 'unknown' -- last probe result for THIS service
                    CHECK (service_state IN ('open','filtered','closed','unknown')),
    banner          TEXT,                            -- optional service banner / mDNS TXT / device 'name' (e.g. Cast eureka_info name) — NO credentials
    first_seen_utc  TEXT    NOT NULL,                -- ISO-8601 UTC first-observation timestamp
    last_seen_utc   TEXT    NOT NULL,                -- ISO-8601 UTC most-recent-observation timestamp
    FOREIGN KEY (host_id)       REFERENCES discovered_host   (host_id)       ON DELETE CASCADE,
    FOREIGN KEY (protocol_name) REFERENCES protocol_capability(protocol_name) ON UPDATE CASCADE,
    UNIQUE (host_id, protocol_name, port)            -- one row per (host, protocol, port) tuple
) STRICT;

CREATE INDEX IF NOT EXISTS ix_host_service_host      ON host_service (host_id);
CREATE INDEX IF NOT EXISTS ix_host_service_protocol  ON host_service (protocol_name);

-- -----------------------------------------------------------------------------
-- route_entry
--   How helix_proxy actually CARRIES traffic to a host/service: the resolved
--   primitive plus its concrete parameters. Separate from protocol_capability
--   (the static catalogue) because a route is instance-specific and time-bound
--   (it exists only while the bridge is up and the carve-out is applied).
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS route_entry (
    route_id        INTEGER PRIMARY KEY,            -- surrogate key
    host_id         INTEGER,                         -- FK -> discovered_host (NULL for subnet-wide routes, e.g. the 10/8 L3 route)
    service_id      INTEGER,                         -- FK -> host_service (NULL when the route is host- or subnet-scoped, not per-service)
    primitive       TEXT    NOT NULL                 -- the carrying primitive actually applied (mirrors protocol_capability.primitive)
                    CHECK (primitive IN ('l3_route','squid_proxy','remote_reflector','usbip','structurally_impossible')),
    target_scope    TEXT    NOT NULL,                -- what the route covers, e.g. '10.0.0.0/8' (L3), '10.6.100.221:445' (host:port), 'squid:127.0.0.1:53128'
    primitive_detail TEXT,                           -- extra params: PASV port range, Squid proxy endpoint, reflector host, usbip busid — NO secrets
    ssrf_allowlisted INTEGER NOT NULL DEFAULT 0      -- 0/1: is this target covered by the narrow HELIX_BRIDGE_SUBNET carve-out? (architecture.md §4)
                    CHECK (ssrf_allowlisted IN (0,1)),
    active          INTEGER NOT NULL DEFAULT 0       -- 0/1: is this route currently in effect (bridge up + applied)?
                    CHECK (active IN (0,1)),
    created_utc     TEXT    NOT NULL,                -- ISO-8601 UTC when the route entry was created
    FOREIGN KEY (host_id)    REFERENCES discovered_host (host_id)    ON DELETE CASCADE,
    FOREIGN KEY (service_id) REFERENCES host_service   (service_id) ON DELETE CASCADE
) STRICT;

CREATE INDEX IF NOT EXISTS ix_route_entry_active ON route_entry (active);
CREATE INDEX IF NOT EXISTS ix_route_entry_host   ON route_entry (host_id);

-- -----------------------------------------------------------------------------
-- discovery_event
--   Append-only audit log of every discovery / probe / reflection / verdict event.
--   This is the evidence trail: a PASS row MUST cite an evidence_path (the schema
--   CHECK enforces it — a PASS with no evidence is the §11.4.69 PASS-bluff the
--   feature exists to prevent). SKIP rows carry a closed-set skip_reason matching
--   the test harness (svord_bridge.sh / ab_skip_with_reason).
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS discovery_event (
    event_id        INTEGER PRIMARY KEY,            -- surrogate key (append-only; never renumbered)
    event_utc       TEXT    NOT NULL,                -- ISO-8601 UTC event timestamp
    host_id         INTEGER,                         -- FK -> discovered_host (NULL for subnet-scoped / pre-host events)
    service_id      INTEGER,                         -- FK -> host_service (NULL when not service-specific)
    event_type      TEXT    NOT NULL                 -- what happened
                    CHECK (event_type IN ('host_discovered','service_discovered','reflector_reflected',
                                          'reachability_change','route_applied','route_removed','probe')),
    source          TEXT    NOT NULL                 -- the discovery/probe source
                    CHECK (source IN ('mdns','dnssd','ssdp','wsdiscovery','route_probe','reflector','manual','test_harness')),
    verdict         TEXT    NOT NULL                 -- the harness verdict vocabulary (PLAN.md §6 / §11.4.45)
                    CHECK (verdict IN ('PASS','SKIP','FAIL','INFO')),
    skip_reason     TEXT                             -- closed-set reason when verdict='SKIP' (matches ab_skip_with_reason)
                    CHECK (skip_reason IS NULL OR skip_reason IN
                           ('geo_restricted','operator_attended','hardware_not_present',
                            'topology_unsupported','network_unreachable_external','feature_disabled_by_config')),
    evidence_path   TEXT,                            -- path to captured evidence under qa-results/vpn_lan/... (REQUIRED for PASS)
    detail          TEXT,                            -- free-form detail (NO secrets — §11.4.10)
    FOREIGN KEY (host_id)    REFERENCES discovered_host (host_id)    ON DELETE SET NULL,
    FOREIGN KEY (service_id) REFERENCES host_service   (service_id) ON DELETE SET NULL,
    -- §11.4.69 anti-bluff at the data layer: a PASS is invalid without captured evidence,
    -- and a SKIP is invalid without a closed-set reason.
    CHECK (verdict <> 'PASS' OR (evidence_path IS NOT NULL AND evidence_path <> '')),
    CHECK (verdict <> 'SKIP' OR skip_reason IS NOT NULL)
) STRICT;

CREATE INDEX IF NOT EXISTS ix_discovery_event_time    ON discovery_event (event_utc);
CREATE INDEX IF NOT EXISTS ix_discovery_event_host    ON discovery_event (host_id);
CREATE INDEX IF NOT EXISTS ix_discovery_event_verdict ON discovery_event (verdict);

-- =============================================================================
-- Example queries (documentation — not executed as part of the DDL)
-- =============================================================================

-- Example 1 — every reachable host with each of its services and the routing
-- primitive helix_proxy uses to carry that protocol (the architecture.md §2 table,
-- joined to live discovery). Ordered by host then protocol.
--
--   SELECT  h.ip_addr,
--           h.hostname,
--           s.protocol_name,
--           s.port,
--           s.tls_mode,
--           pc.primitive,
--           pc.why
--   FROM    discovered_host   AS h
--   JOIN    host_service      AS s  ON s.host_id = h.host_id
--   JOIN    protocol_capability AS pc ON pc.protocol_name = s.protocol_name
--   WHERE   h.reachable = 1
--   ORDER BY h.ip_addr, s.protocol_name;

-- Example 2 — the discovery-event audit trail: every honest SKIP with its
-- closed-set reason, most recent first (proves the bridge-down path SKIPped
-- rather than fake-PASSing — §11.4.3 / §11.4.69).
--
--   SELECT  e.event_utc,
--           e.event_type,
--           e.source,
--           e.skip_reason,
--           COALESCE(h.ip_addr, '(subnet-scoped)') AS target,
--           e.detail
--   FROM    discovery_event AS e
--   LEFT JOIN discovered_host AS h ON h.host_id = e.host_id
--   WHERE   e.verdict = 'SKIP'
--   ORDER BY e.event_utc DESC;

-- Example 3 — which discovered services still lack an active route (work queue):
-- services on reachable hosts that have no active route_entry yet.
--
--   SELECT  h.ip_addr,
--           s.protocol_name,
--           s.port
--   FROM    host_service    AS s
--   JOIN    discovered_host AS h ON h.host_id = s.host_id
--   WHERE   h.reachable = 1
--     AND   NOT EXISTS (
--               SELECT 1 FROM route_entry AS r
--               WHERE  r.service_id = s.service_id
--                 AND  r.active = 1)
--   ORDER BY h.ip_addr, s.protocol_name;

-- Example 4 — hosts first found through the multicast reflector (Phase 5),
-- confirming discovery-via-reflection actually populated the registry.
--
--   SELECT  h.ip_addr,
--           h.hostname,
--           h.first_seen_utc
--   FROM    discovered_host AS h
--   WHERE   h.discovery_method IN ('mdns','dnssd','ssdp','wsdiscovery')
--   ORDER BY h.first_seen_utc DESC;
