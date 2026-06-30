# Dante (sockd) dynamic-routing templates

**Revision:** 1
**Last modified:** 2026-07-01T00:00:00Z
**Status:** DESIGN / templates only — NOT yet wired into a running stack.

This directory holds the **template** the future control-plane `config-compiler`
(Stream B) renders to add `dynamic`-mode per-tunnel SOCKS egress to Dante. It is
**additive**: the rendered route blocks are **appended after** the shipped
`config/dante/sockd.conf` content (preserved verbatim) to build the deployed
config — the base config (`internal: :51080`, `external: proxy-dante`,
`socksmethod: none`, and its `client pass` / `socks pass` rules) is never
modified or removed (**§11.4.122**).

> **Why concatenation, not a native `include`:** Dante v1.4.4 has **no `include`
> directive** (CONFIRMED — `sockd -V` rejects both `include: "..."` and
> `include "..."` with a syntax error: `qa-results/p4_templates/dante_parse.txt`,
> TEST 1 & 3). Squid supports `include` (so the Squid template *is* included);
> Dante does not, so the compiler concatenates instead. The end result is the
> same additive guarantee: base content untouched, route blocks added.

## Files

| File | Purpose |
|---|---|
| `dynamic-routing.sockd.conf.tmpl` | Per-tunnel `route { ... }` blocks directing matching destinations out through that tunnel's gluetun egress. |

## Placeholders (the compiler fills these)

| Placeholder | Meaning |
|---|---|
| `{{TUNNEL_NAME}}` | Per-tunnel label (comment only), e.g. `tun_<profile>`. |
| `{{TARGET_CIDR}}` | Destination(s) routed through this tunnel (CIDR or host). |
| `{{PEER_HOST}}` | gluetun container host exposing this tunnel's egress proxy. |
| `{{PEER_PORT}}` | That gluetun proxy port (SOCKS upstream for chaining). |

The compiler renders **one `route` block per tunnel/target**.

## How the compiler fills + wires them

1. Read VPN profiles + target routes from PostgreSQL.
2. Substitute the placeholders, one `route` block per tunnel/target.
3. **Concatenate**: write the shipped `config/dante/sockd.conf` content verbatim,
   then append the rendered route blocks, into the deployed config (Dante has no
   `include` directive — see note above). The base lines stay byte-for-byte.
4. Apply via **`SIGHUP`** to the sockd mother process — only on a **structural**
   route change (new/removed tunnel or target).

## `proxyprotocol` / egress topology

The template chains matching destinations through the tunnel's gluetun proxy so
bytes leave via that VPN netns. Set `proxyprotocol` to match what gluetun
exposes:

- `proxyprotocol: socks_v5` — if a SOCKS upstream is exposed (template default).
- `proxyprotocol: http_connect` — for gluetun's HTTP proxy (`:8888`).

**Alternative interface-bind topology** (one container = one netns, §3.2): instead
of chaining, bind egress to the tunnel interface —

```
route {
    from: 0.0.0.0/0  to: {{TARGET_CIDR}}
    via: {{TUNNEL_IFACE}}
}
```

The compiler selects the form per deployment; the shipped template ships the
proxy-chaining form as the portable default.

## Confirmed facts & honest gaps (§11.4.6)

- **FACT (`F_spikes_G1-G4.md` §G3):** `SIGHUP` reloads sockd config and does
  **not** drop an active ESTABLISHED SOCKS session (20/20 chunks across a
  mid-stream reload, curl exit 0). Adding/removing a route is live-session safe.
- **`UNCONFIRMED:`** whether an in-flight session whose **route changed** keeps
  its OLD path or is re-evaluated — owed to **P9** (concurrent / repeated /
  route-change live captured-evidence test).
- **FACT (`qa-results/p4_templates/dante_parse.txt`, TEST 2):** the rendered
  `route { ... }` block **verifies clean** — `sockd -V -f <conf>` exit **0**
  (Dante v1.4.4, `vimagick/dante:latest`, via rootless `podman run --rm`). Only
  an unrelated "uid 0 not recommended" warning (running -V as root), not a route
  syntax issue.
- **FACT (TEST 1 & 3):** `sockd -V` REJECTS an `include` line (both `include:`
  and bare `include`) with a syntax error — hence the concatenation model above.
- **`UNCONFIRMED:`** full live SOCKS egress through a real per-tunnel upstream +
  the route-change-mid-session behaviour — owed to **P9** against the real stack
  (`sockd -V` validates syntax + interface, not live proxy chaining). Recorded
  honestly, not faked.

## Validation

See `qa-results/p4_templates/` (gitignored) for the rendered example and any
captured Dante parse attempt + its honest result.
