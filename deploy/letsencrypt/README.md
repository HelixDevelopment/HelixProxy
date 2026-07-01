# Let's Encrypt — Hermetic Caddy + Pebble + challtestsrv (DNS-01)

**Revision:** 2
**Last modified:** 2026-07-01T00:00:00Z
**Status:** Config + build authoring deliverable — files only. NOTHING booted, committed, or pushed. Build + boot + verification are the conductor's job (see "Conductor boot sequence" + "Residual PENDING").
**Authority:** Inherits the Helix Constitution (`constitution/Constitution.md`) per §11.4.35. Honors §11.4.10/§11.4.30 (secrets), §11.4.76/§11.4.161 (containers submodule, rootless Podman), §11.4.156 (renewal is in-process, NO cron/CI/hook), §11.4.173 (containerized build), §11.4.6 (unverified ⇒ PENDING).
**Design source:** [`docs/design/LETSENCRYPT_HTTPS.md`](../../docs/design/LETSENCRYPT_HTTPS.md).
**Research source (authoritative for this hermetic build):** [`docs/research/letsencrypt_hermetic_20260701/ANALYSIS.md`](../../docs/research/letsencrypt_hermetic_20260701/ANALYSIS.md) — "Recommended hermetic architecture", **Option A**.

---

## Overview

A hermetic, self-contained ACME stack the conductor builds + boots via the
containers submodule. Caddy is BOTH the ACME client AND the TLS terminator: it
obtains and **renews** a certificate for the test hostname `proxy.hermetic.test`
via **ACME DNS-01**, terminates public HTTPS, and reverse-proxies plaintext to
an internal upstream. Renewal + hot in-memory cert rotation run inside the
long-running Caddy process — **no cron, no CI, no git hook** (§11.4.156).

"Hermetic-first" (Option A): a **real** certificate is issued against a **local**
ACME server (**Pebble**) with DNS-01 solved locally by **pebble-challtestsrv**,
driven by a **small owned Caddy DNS module** (`caddy-challtestsrv-dns/`,
`dns.providers.challtestsrv`) built into a custom Caddy image — zero network,
zero Let's Encrypt rate-limit exposure, DNS-01 **genuinely exercised** end-to-end
(no `PEBBLE_VA_ALWAYS_VALID` shortcut — that would be a §11.4 PASS-bluff). The
SAME Caddyfile + compose then flip to LE staging → production by changing only
env values — no file edits.

### Files

| File | Role |
|---|---|
| `caddy-challtestsrv-dns/` | Owned libdns/caddy-dns provider module (`dns.providers.challtestsrv`): solves DNS-01 by POSTing set-txt/clear-txt to challtestsrv's mgmt API. `go.mod` + `provider.go` + `README.md`. |
| `Dockerfile.caddy` | xcaddy multi-stage build embedding the local module; pinned Caddy; non-root final user (rootless, §11.4.161). |
| `build.sh` | Rootless-Podman build recipe the conductor runs → `localhost/helix_proxy/caddy-challtestsrv:2.8.4`. |
| `Caddyfile` | Env-parameterized ACME issuer (Pebble dir), DNS-01 via `challtestsrv`, `resolvers challtestsrv:8053`, `acme_ca_root` → mounted `pebble.minica.pem`, TLS termination, `reverse_proxy`, `/health`. |
| `compose.hermetic.yml` | 3 services (`pebble`, `challtestsrv`, `caddy`) on a private pod network; pinned images; named volumes; caddy built from `Dockerfile.caddy`. |
| `.env.example` | Variable NAMES only (URLs, provider, secret NAME, ports, image pins). NO secret values. |
| `.gitignore` | Ignores `.env`, runtime `*.key`/`*.pem`, `data/`, `pebble-ca/`, secret files. |
| `README.md` | This file. |

---

## Service topology

```
                 host (rootless Podman user)
                 :8443 → caddy:443   :8080 → caddy:80
                 :14000/:15000 → pebble   :8055 → challtestsrv   (loopback, debug)
                              │
        ┌─────────────────────┴───────────────────────────────────────┐
        │           network: letsencrypt-hermetic (pod-internal)        │
        │                                                               │
        │   caddy ──ACME(DNS-01)──► pebble ──TXT DNS query──► challtestsrv│
        │     │  set-txt/clear-txt (mgmt :8055) ─────────────────►(mgmt) │
        │     │  resolvers challtestsrv:8053 (Caddy self-check) ───►(DNS)│
        │     └── reverse_proxy ──► CADDY_UPSTREAM (e.g. admin:80)       │
        │                                                               │
        │   volumes: letsencrypt-caddy-data (certs+acct key, gitignored)│
        │            letsencrypt-caddy-config                           │
        └───────────────────────────────────────────────────────────────┘
```

Flow: Caddy requests a cert from Pebble → Pebble issues a DNS-01 challenge →
Caddy's `challtestsrv` module writes the `_acme-challenge` TXT to challtestsrv →
Caddy's self-check (resolvers) confirms it → Pebble's VA resolves it via
challtestsrv → Pebble issues a leaf whose chain roots in Pebble's per-boot
issuance CA → Caddy serves it over `:443`.

---

## The two CAs (do NOT conflate — ANALYSIS.md Q6 gotcha #1)

- **`pebble.minica.pem`** signs Pebble's OWN HTTPS endpoints (`:14000` directory
  + `:15000` management). Caddy must **trust** it to *talk to* Pebble — that is
  `acme_ca_root` / `trusted_roots` (env `ACME_CA_ROOT`), the file mounted at
  `/run/pebble-ca/pebble.minica.pem`. PUBLIC test CA, never a secret. **Empty for
  real LE.**
- The **per-run issuance CA** at Pebble `:15000/roots/0` + `/intermediates/0`
  signs the leaf Pebble ISSUES. Pebble **regenerates it every boot**, so the
  **test** fetches it at verify time (below) and the analyzer asserts the leaf
  chains to it. NEVER pinned, NEVER trusted by Caddy.

---

## How the conductor boots it via the containers submodule (§11.4.76)

`compose.hermetic.yml` is a **standard compose file** consumed by the submodule
(no ad-hoc `podman run` of services — §11.4.76). Reference points in
`submodules/containers`: `pkg/compose/types.go:19` (`ComposeProject{Name,File,
Profile,Services}` — set `File` to this file), `pkg/compose/orchestrator.go:22`
(`Up`), `pkg/boot/manager.go:64` (`BootManager.BootAll`), `pkg/health/checker.go:30`
(`NewDefaultChecker` — TCP/HTTP readiness). The custom Caddy **image build** goes
through the submodule `pkg/crossbuild` (§11.4.173) or the equivalent `build.sh`
rootless-Podman recipe. Rootless (§11.4.161): all host-published ports are HIGH
(>1024); no host-network mode.

---

## Conductor boot sequence (exact ordered commands)

> These are the canonical rootless-Podman commands. The conductor runs them
> directly OR drives the equivalents through the containers submodule
> (`pkg/crossbuild` for step 1, `BootManager.BootAll` for step 3). Run from this
> directory (`deploy/letsencrypt/`). Nothing here touches the running data plane
> (`:53128`), `wg0-mullvad`, `lava-*`, or `whoami:58080`.

**1. Build the custom Caddy image (embeds the DNS-01 module).**
```sh
./build.sh                       # → localhost/helix_proxy/caddy-challtestsrv:2.8.4
                                 #   self-verifies dns.providers.challtestsrv is linked in
```

**2. Materialize Pebble's endpoint CA (CA #1) into ./pebble-ca/ (gitignored).**
```sh
mkdir -p pebble-ca
# one-shot --rm read of the PUBLIC test CA from the pinned pebble image
podman run --rm --entrypoint cat \
  ghcr.io/letsencrypt/pebble:2.6.0 /test/certs/pebble.minica.pem \
  > pebble-ca/pebble.minica.pem
# PENDING boot-verify: confirm the in-image path /test/certs/pebble.minica.pem.
```

**3. Boot the stack (challtestsrv + pebble first, health-gated, then caddy).**
```sh
# via the containers submodule BootManager.BootAll (preferred), OR the equivalent:
podman compose -f compose.hermetic.yml up -d
# depends_on + healthchecks order challtestsrv → pebble → caddy. Caddy's first
# request against proxy.hermetic.test triggers issuance (in-process ACME loop).
```

**4. Fetch THIS run's issuance CA bundle (CA #2) for verification.**
```sh
# Pebble regenerates the issuance CA each boot — fetch from the loopback mgmt port.
curl -sk https://127.0.0.1:15000/roots/0         -o pebble_root.pem
curl -sk https://127.0.0.1:15000/intermediates/0 -o pebble_intermediate.pem
cat pebble_intermediate.pem pebble_root.pem      > pebble_ca_bundle.pem
```

**5. Pull the leaf Caddy is actually serving + run the analyzer.**
```sh
# served leaf (proves the deployed artifact; :8443 is the host publish of caddy:443)
openssl s_client -connect 127.0.0.1:8443 -servername proxy.hermetic.test </dev/null \
  2>/dev/null | openssl x509 > served_leaf.pem
#   (alternative: read the leaf from the letsencrypt-caddy-data volume at
#    /data/caddy/certificates/<acme-ca-dir>/proxy.hermetic.test/proxy.hermetic.test.crt)

# consume the client-and-challenge-AGNOSTIC analyzer (tests/letsencrypt/cert_analyzer.sh)
. ../../tests/letsencrypt/cert_analyzer.sh
cert_chain_roots_in served_leaf.pem pebble_ca_bundle.pem   # chains to THIS run's Pebble CA
cert_not_expired    served_leaf.pem                        # inside validity now
cert_san_matches    served_leaf.pem proxy.hermetic.test    # SAN covers the served host
cert_days_remaining served_leaf.pem                        # scalar for reporting
```
Persist `served_leaf.pem`, `pebble_ca_bundle.pem`, and the analyzer output under
`qa-results/<run-id>/letsencrypt/` (§11.4.69 captured evidence).

**6. Phase-5 rotation test (optional, deterministic force-renew — ANALYSIS.md Q4/§11.4.115).**
Set `CADDY_ADMIN=0.0.0.0:2019` + `CADDY_RENEWAL_RATIO=1`, reload, and assert the
served leaf's **serial changed** + still chains + zero-downtime across the swap.

---

## Env / secret contract (NAMES only — §11.4.10)

Full list with comments in [`.env.example`](.env.example).

- **Canonical DNS-provider secret NAME: `helixproxy_caddy_dns_token`** (reconciled
  2026-07-01 — matches the existing `helixproxy_api_*` family in `tls.go` + the
  design doc). Mount PATH `/run/secrets/helixproxy_caddy_dns_token` (env
  `ACME_DNS_TOKEN_FILE`). Caddy reads the value at runtime via `{file.<path>}` —
  **the value never appears in any tracked file, env, or compose**.
- **The hermetic challtestsrv path needs NO token** (challtestsrv is
  unauthenticated). So the top-level `secrets:` block AND the caddy `secrets:`
  mount are **commented** — a hermetic boot requires no secret. The operator
  provisions + uncomments them ONLY for the staging/prod real-provider path:
  `podman secret create helixproxy_caddy_dns_token <token-file>`.
- Caddy's ACME account key + issued certs + private keys live in the gitignored
  named volume `letsencrypt-caddy-data`; regeneration = ACME re-issue (§11.4.77).

---

## Ports (all high, >1024 — rootless-friendly)

| Service | Host port (default) | Container port | Bind | Purpose |
|---|---|---|---|---|
| caddy | `CADDY_HTTPS_PORT=8443` | 443 | published | HTTPS / TLS termination |
| caddy | `CADDY_HTTP_PORT=8080` | 80 | published | HTTP→HTTPS redirect only |
| caddy | `CADDY_ADMIN_PORT=2019` | 2019 | 127.0.0.1 (rotation test only) | admin API (`POST /load`) |
| pebble | `PEBBLE_DIR_PORT=14000` | 14000 | 127.0.0.1 | ACME directory (evidence) |
| pebble | `PEBBLE_MGMT_PORT=15000` | 15000 | 127.0.0.1 | mgmt API / fetch per-boot issuance CA |
| challtestsrv | `CHALLTESTSRV_MGMT_PORT=8055` | 8055 | 127.0.0.1 | set/clear TXT (mgmt) |
| challtestsrv | — | 8053/5002/5001 | pod-internal | DNS / HTTP-01 / TLS-ALPN (no host publish) |

Reaching Caddy on the real `:443` from outside is an operator **sysctl/NAT**
decision (design §4.4) — NOT performed here (CONST-033, no host network change).

---

## Resolved since Revision 1

- **Custom xcaddy DNS image (was PENDING #1).** RESOLVED — `caddy-challtestsrv-dns/`
  owned module (`dns.providers.challtestsrv`) + `Dockerfile.caddy` (xcaddy
  `--with …=./caddy-challtestsrv-dns`) + `build.sh`. No dependency on a
  non-existent upstream `caddy-dns/challtestsrv`.
- **Secret naming (was PENDING #9).** RESOLVED — canonical `helixproxy_caddy_dns_token`
  used consistently in `Caddyfile`, `compose.hermetic.yml`, `.env.example`.
- **Pebble/challtestsrv flags (was PENDING #6).** Reconciled: pebble
  `PEBBLE_VA_NOSLEEP=1 PEBBLE_WFE_NONCEREJECT=0 PEBBLE_VA_ALWAYS_VALID=0`, cmd
  `-dnsserver challtestsrv:8053 -strict false`; challtestsrv `-defaultIPv6 ""`.
- **Pebble CA trust materialization (was PENDING #3).** Concrete mechanism now in
  "Conductor boot sequence" step 2 (residual: confirm the in-image CA path).
- **Caddy DNS-01 wiring.** Caddyfile pins `dns challtestsrv`, `resolvers
  challtestsrv:8053`, `acme_ca https://pebble:14000/dir`, `acme_ca_root` →
  mounted `pebble.minica.pem`, with the two-CA distinction commented.

---

## Residual PENDING (still boot-verify or operator/test scope — §11.4.6)

1. **Image tag/digest confirmation (§11.4.173).** `PEBBLE_IMAGE` /
   `CHALLTESTSRV_IMAGE` are pinned to `v2.6.0` on GHCR — confirm the exact tag is
   published and pin `@sha256:<digest>` for full reproducibility.
2. **Caddy ≥ 2.10 libdns adaptation.** The module targets libdns v0.2.x (Caddy
   2.8.x). A build at Caddy ≥ 2.10 (libdns v1.0.0 typed-RR) needs the small
   `RR()`-based adaptation — see `caddy-challtestsrv-dns/README.md`. `CADDY_VERSION`
   is pinned to `2.8.4`; bump deliberately.
3. **In-image paths / healthcheck tooling.** The `/test/certs/pebble.minica.pem`
   path (step 2) and the `wget`/`nc` healthcheck tools assume the pinned images
   ship them — confirm at boot, or move readiness to the submodule `pkg/health`
   TCP/HTTP checkers.
4. **Real-provider (staging/prod) module.** For LE staging/prod, build
   `CADDY_IMAGE` with `caddy-dns/<provider>` and provision the
   `helixproxy_caddy_dns_token` secret — module + provider chosen when a real
   domain is available (design Decision B).
5. **`:443` reachability.** Operator sysctl `net.ipv4.ip_unprivileged_port_start`
   or firewall NAT for public serving (design §4.4) — operator action.
6. **Rotation-test confounders.** ARI may override `renewal_window_ratio`
   (fall back to delete-storage+reload); the exact Caddy "obtained/renewed" log
   string is UNCONFIRMED — the changed-serial assertion is the primary proof
   (ANALYSIS.md Q4/Q6).
7. **Design-doc cross-file secret-name sync.** `docs/design/LETSENCRYPT_HTTPS.md`
   already uses `helixproxy_caddy_dns_token` (the canonical name) — a doc pass
   should confirm no stale `helix_proxy_acme_dns_token` reference remains
   anywhere outside `deploy/letsencrypt/` (out of THIS deliverable's write scope).
8. **Full §11.4.169 test matrix.** Hermetic issuance, staging, renewal/rotation,
   negative (fail-closed), security leak-grep, stress + chaos — per design §6,
   captured under `qa-results/<run-id>/letsencrypt/`. None run here.
