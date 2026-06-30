# `config/dnsproxy/` — per-tunnel DNS-privacy forwarder (config PLAN)

**Revision:** 1
**Last modified:** 2026-06-30T21:40:00Z
**Status:** NOT-YET-LIVE config plan. Structure/parse validated only — DNS
privacy & no-leak are owed to the live-tunnel wiring phase (plan **T7.1** /
Phase 7; the parent's **"P10"**). See "What is / isn't proven" below.

## What this is

A [`AdguardTeam/dnsproxy`](https://github.com/AdguardTeam/dnsproxy) DoT/DoH
forwarder config implementing spec §11 ② — *"DoH/DoT per-tunnel DNS + leak
prevention (dnsproxy sidecar)"*
(`docs/superpowers/specs/2026-06-30-vpn-aware-proxy-extension-design.md`).

| File | Purpose |
|---|---|
| `dnsproxy.yaml` | The forwarder config: loopback listener + DoT upstream (`tls://1.1.1.1`) + cache/bootstrap, every setting commented to the spec/env source. |
| `DNS_LEAK_TEST.md` | DESIGN of the T7.1 / "P10" DNS-leak proof (zero plaintext `:53` on the real uplink). Owed to the live tunnel — not run now. |
| `README.md` | This file. |

## Per-netns deployment model (how it composes with gluetun — "P10" wiring)

The dynamic-routing design is **one gluetun container = one network namespace =
one Redis status key** (`docs/DYNAMIC_ROUTING.md` §3.2). DNS privacy rides that
same model:

```
                gluetun netns (profile A)          ── WireGuard tunnel ──▶ internet
  ┌───────────────────────────────────────────┐
  │  Squid / Dante  ──resolv.conf 127.0.0.1──▶ │  dnsproxy :53 (loopback)
  │                                            │      │  upstream = tls://1.1.1.1 (DoT)
  └───────────────────────────────────────────┘      ▼  encrypted DNS egresses
                                                       THROUGH the tunnel, not host uplink
```

- **One dnsproxy instance per gluetun netns.** Deployed (in a later phase, by
  the compose/control-plane layer — NOT in this dir's scope) via the existing
  `network_mode: service:<gluetun>` pattern, so dnsproxy shares the tunnel's
  network namespace.
- **Loopback-only listener.** `dnsproxy.yaml` binds `127.0.0.1:53`. The
  same-netns Squid/Dante point their resolver at `127.0.0.1`; nothing outside
  the netns can reach it.
- **Encryption + tunnel-routing together.** Because dnsproxy lives *inside* the
  tunnel's netns, its DoT (or DoH) queries to the upstream are (a) encrypted by
  the DoT/DoH protocol and (b) routed out through the WireGuard tunnel — never
  on the host's real uplink. That is the data-plane basis for the no-leak proof.
- **Fail-closed alignment** (`DYNAMIC_ROUTING.md` §5): the surrounding routing
  layer is designed to 503 rather than fall through to a leaking direct query;
  dnsproxy's loopback-only surface keeps DNS from leaking even if a client
  mis-resolves.

## Env provenance (config-injected, never secrets — §11.4.28 / §11.4.10)

From `.env.example` (defaults mirrored as static values in `dnsproxy.yaml`; a
later compose/control-plane renderer substitutes per-netns values at deploy):

| `.env` var | dnsproxy.yaml setting |
|---|---|
| `DNS_OVER_TLS_ENABLED=true` | upstream uses `tls://` (DoT) |
| `DOT_UPSTREAM=tls://1.1.1.1` | `upstream:` |
| `DNS_SERVERS=8.8.8.8,8.8.4.4,1.1.1.1` | `bootstrap:` (hostname-form upstreams only) |
| `DNS_CACHING_ENABLED=true` | `cache: true` |
| `DNS_CACHE_TTL=3600` | `cache-max-ttl: 3600` |

No secrets live here — DoT/DoH to public resolvers needs none. VPN creds /
proxy-auth / mTLS keys are Podman secrets handled elsewhere (spec §12 /
§11.4.10), never in this dir.

## What is / isn't proven (§11.4.6 — no guessing)

- **PROVEN NOW (structure/parse only):** `dnsproxy.yaml` is accepted by
  `adguard/dnsproxy:latest` — it parses, every setting is honored (cache TTL
  override 60/3600, refuse-any, `upstream-mode=load_balance`, cache 4 MiB), and
  the server binds udp+tcp `127.0.0.1:53`. Evidence:
  `qa-results/p7-dnsproxy/dnsproxy_check.txt` (rootless podman, `--config-path`
  start → "listening" → clean stop; `RUN_EXIT=124` = stayed up after parse).
- **NOT proven yet (owed to T7.1 / "P10", needs a live gluetun tunnel):** that
  DNS is actually private, encrypted end-to-end, and **leak-free** — i.e. zero
  plaintext UDP/TCP `:53` on the real uplink with all DNS as DoT/DoH through the
  tunnel. That is the data-plane proof designed in `DNS_LEAK_TEST.md` and runs
  only once the per-netns wiring is live. Until then, **do not claim DNS
  privacy works.**

## Run the structural validation yourself

```bash
podman run --rm \
  -v "$(pwd)/config/dnsproxy:/c:ro,Z" \
  adguard/dnsproxy:latest --config-path=/c/dnsproxy.yaml
# expect: parses, logs "listening to udp/tcp ... 127.0.0.1:53"; Ctrl-C / timeout to stop.
```
