# Squid dynamic-routing templates

**Revision:** 1
**Last modified:** 2026-07-01T00:00:00Z
**Status:** DESIGN / templates only — NOT yet wired into a running stack.

This directory holds the **template** the future control-plane `config-compiler`
(Stream B) renders to add `dynamic`-mode routing to Squid. It is **additive**:
the rendered output is pulled into the shipped `config/squid/squid.conf` via a
single `include` line — the base config is never modified or removed
(**§11.4.122**).

## Files

| File | Purpose |
|---|---|
| `dynamic-routing.conf.tmpl` | Per-stack Squid include: external_acl helper wiring, per-tunnel `cache_peer`(s), and the fail-closed `deny_info 503`. |
| `../errors/ERR_TUNNEL_DOWN` | Branded HTML error page served by `deny_info 503:ERR_TUNNEL_DOWN`. |

## Placeholders (the compiler fills these)

| Placeholder | Meaning |
|---|---|
| `{{ACL_HELPER_PATH}}` | Absolute path to the external_acl helper binary (the Go binary that reads Redis and answers `OK tag=<tunnel>` / `ERR`). |
| `{{TUNNEL_NAME}}` | Per-tunnel `cache_peer` name, e.g. `tun_<profile>`. |
| `{{PEER_HOST}}` | gluetun container host/name for this tunnel. |
| `{{PEER_PORT}}` | gluetun parent (forward-proxy) port for this tunnel. |

The compiler emits the `external_acl_type` + `acl tun_up` block **once**, repeats
the `cache_peer` + `cache_peer_access` **pair once per tunnel**, then emits the
fail-closed block **once**.

## How the compiler fills + wires them

1. Read VPN profiles from PostgreSQL (source of truth).
2. Substitute the placeholders above, one rendered file per `dynamic` stack
   (e.g. `/etc/squid/conf.d/dynamic-routing.conf`).
3. Insert a single `include <rendered-path>` into `config/squid/squid.conf`.
   **Placement matters:** the `http_access deny !tun_up` line must be reached
   *before* the base `http_access allow localnet`, so the compiler inserts the
   include **above** the base allow rules (Squid evaluates `http_access`
   top-to-bottom, first match wins). The base file's lines are otherwise
   untouched.
4. Copy `../errors/ERR_TUNNEL_DOWN` into Squid's active error directory (the
   `error_directory`, or the per-language default e.g.
   `/usr/share/squid/errors/en/`) so `deny_info` resolves the page.
5. Apply via Squid `reconfigure` — only on **structural** change (new/removed
   tunnel or peer). Tunnel **up/down** flips need **no** reconfigure: the
   external_acl helper re-reads Redis every request (`ttl=0`).

## Confirmed facts (no guessing — §11.4.6)

- Base image is **Squid 6.13** (FACT, `F_spikes_G1-G4.md` §G2). **Pin note (this
  stream's finding):** docker.io/ubuntu/squid has **no bare `6.13` tag**
  (published: `6.13-25.04_beta`/`_edge`, `latest`, `edge`); pin by `:latest`
  verified 6.13, the `6.13-25.04_*` tag, or a digest.
- The template uses **`%>ha{Host}`** — `%>{Host}` is **deprecated** in 6.13.
- The full directive set (`cache_peer parent no-query name=` /
  `external_acl_type %>ha{Host}` / `acl external` / `cache_peer_access allow` /
  `never_direct allow all` / `deny_info 503:ERR_TUNNEL_DOWN`) parses
  **`squid -k parse` exit 0** (FACT, §G2 + this stream's `qa-results/p4_templates/`).

## Optional: `concurrency=N`

If the helper implements Squid's concurrency channel-id protocol, the compiler
MAY append `concurrency=N` to the `external_acl_type` line for throughput. The
template omits it (serial) so the rendered example is helper-agnostic.

## Validation

See `qa-results/p4_templates/` (gitignored) for the rendered example, the
minimal `squid.conf` that `include`s it, and the captured `squid -k parse`
output run inside `ubuntu/squid:6.13` via rootless `podman run --rm`.
