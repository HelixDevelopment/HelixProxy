# caddy-challtestsrv-dns — hermetic DNS-01 provider for Caddy

**Revision:** 1
**Last modified:** 2026-07-01T00:00:00Z
**Module:** `github.com/helixproxy/caddy-challtestsrv-dns`
**Caddy module ID:** `dns.providers.challtestsrv`
**Authority:** Helix Constitution §11.4.10 (no secrets — this provider carries none), §11.4.74 (extend-don't-reimplement — a minimal owned module, no upstream `caddy-dns/challtestsrv` exists), §11.4.6 (interface version stated, not guessed).

A minimal [libdns](https://github.com/libdns/libdns)/[caddy-dns](https://github.com/caddy-dns) provider that solves the ACME **DNS-01** challenge against a [`pebble-challtestsrv`](https://github.com/letsencrypt/pebble/tree/main/cmd/pebble-challtestsrv) mock DNS server through its unauthenticated HTTP **management API**:

- `AppendRecords` → `POST <mgmt>/set-txt` `{"host":"_acme-challenge.<fqdn>.","value":"<digest>"}`
- `DeleteRecords` → `POST <mgmt>/clear-txt` `{"host":"_acme-challenge.<fqdn>."}`

It exists because stock Caddy ships **no** DNS-provider modules and cannot drive challtestsrv's bespoke API — see the deep-research `ANALYSIS.md` **Option A** (the fully-hermetic path: Pebble + challtestsrv + custom-built Caddy, DNS-01 genuinely exercised end-to-end).

## HERMETIC-TEST-ONLY

challtestsrv has **no authentication whatsoever**. Use this provider **only** inside a controlled, offline test network. It carries **no token / no secret** (nothing to leak, §11.4.10). For a real DNS-01 provider, use the operator's `caddy-dns/<provider>` module and a Podman-secret token instead (see `../README.md`).

## Caddyfile usage

```caddyfile
tls {
    dns challtestsrv http://challtestsrv:8055
    # …or, equivalently, with the subdirective:
    # dns challtestsrv {
    #     management_url http://challtestsrv:8055
    # }
    resolvers challtestsrv:8053
}
```

`management_url` is optional; it defaults to `http://challtestsrv:8055`. Caddy `{$VAR}` / `{env.VAR}` placeholders in the value are expanded at provision time.

## Build (via xcaddy)

Built into the custom Caddy image by `../Dockerfile.caddy` / `../build.sh`:

```
xcaddy build v2.8.4 \
  --with github.com/helixproxy/caddy-challtestsrv-dns=./caddy-challtestsrv-dns
```

The `=./caddy-challtestsrv-dns` suffix tells xcaddy to use THIS local module (a build-time go.mod `replace`), so no network fetch of the module is needed.

## Version compatibility (§11.4.6)

This module targets the **libdns v0.2.x struct-based `Record`** API (fields `Type`/`Name`/`Value`/`TTL`), matching **Caddy v2.8.x** (certmagic v0.21.x), where `certmagic.DNSProvider == libdns.RecordAppender + libdns.RecordDeleter` and a `dns.providers.*` module IS that provider directly.

- **Caddy v2.8.x – v2.9.x** (libdns v0.2.2): builds as-is.
- **Caddy ≥ 2.10** (certmagic ≥ 0.22, **libdns v1.0.0** typed-RR `Record` interface): the `AppendRecords`/`DeleteRecords` signatures and record access change (records become an interface with `RR()`), and DNS modules expose a `GetDNSProvider`-style accessor. This module then needs a small adaptation. **Residual PENDING** — the conductor pins the Caddy version at build (`CADDY_VERSION` in `../build.sh` / `../Dockerfile.caddy`) and applies the typed-RR adaptation if a ≥2.10 build is chosen.

## Files

| File | Role |
|---|---|
| `provider.go` | The provider: module registration, `Provision`, `UnmarshalCaddyfile`, `AppendRecords`, `DeleteRecords`. |
| `go.mod` | Module + direct requires (Caddy v2.8.4, libdns v0.2.2); xcaddy reconciles against the pinned Caddy at build. |
| `README.md` | This file. |

## Sources verified 2026-07-01

- libdns interfaces — https://github.com/libdns/libdns
- caddy-dns provider template — https://github.com/caddy-dns/template
- pebble-challtestsrv management API — https://github.com/letsencrypt/pebble/blob/main/cmd/pebble-challtestsrv/README.md
- Project deep research — `docs/research/letsencrypt_hermetic_20260701/ANALYSIS.md` (Q2, Q3 Option A, Q6)
