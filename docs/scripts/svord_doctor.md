# svord_doctor.sh — VPN-LAN svord bridge preflight doctor

**Revision:** 1
**Last modified:** 2026-07-01T16:00:00Z
**Companion to:** [`scripts/svord_doctor.sh`](../../scripts/svord_doctor.sh)
**Authority:** Inherits `constitution/Constitution.md` per §11.4.35 · §11.4.18 script-documentation mandate.

## Overview

`svord_doctor.sh` is the Phase-0 preflight for the VPN-LAN service-access
feature (design: [`docs/design/vpn_lan_access/PLAN.md`](../design/vpn_lan_access/PLAN.md)
§3 + §5). It resolves the env-var **bridge contract** that decouples helix_proxy
from the sibling `svord_toolkit` VPN bridge (§11.4.28) and emits a single
machine-parseable verdict telling every downstream VPN-LAN test whether the
bridge is **UP**, **DOWN** (operator-blocked), or **MISCONFIGURED**.

The doctor never fakes an UP verdict (§11.4.6): a `BRIDGE: UP` requires the
operator-supplied health probe to exit 0 **and** the remote host to answer a
smoke probe. When the bridge is down or unreachable, downstream tests must
honestly SKIP with `network_unreachable_external` (§11.4.3 / §11.4.68 /
§11.4.69) — a fake PASS is forbidden.

## Prerequisites

- POSIX `sh` (validated under `sh -n` and `bash -n`, §11.4.67).
- [`tests/lib/svord_bridge.sh`](../../tests/lib/svord_bridge.sh) — the contract
  library the doctor sources.
- `ping` (preferred) or `nc` for the remote-host smoke probe.
- The 6 bridge-contract environment variables set (PLAN.md §3). Real values live
  in a **gitignored** `.env`; the tracked [`.env.example`](../../.env.example)
  documents the shape (names + illustrative paths only — no secrets, §11.4.10).

  | Env var | Meaning |
  |---|---|
  | `HELIX_SVORD_DIR` | Path to the sibling bridge project |
  | `HELIX_BRIDGE_CONNECT` | Command that brings the VPN up |
  | `HELIX_BRIDGE_DISCONNECT` | Command that tears the VPN down |
  | `HELIX_BRIDGE_HEALTH` | Health probe (exit 0 == up) — authoritative signal |
  | `HELIX_BRIDGE_SUBNET` | Reachable remote subnet (CIDR) |
  | `HELIX_BRIDGE_HOST` | Known remote host for smoke reachability |

## Usage

```sh
# 1. Point the bridge at your svord_toolkit checkout (once):
cp .env.example .env          # .env is gitignored — never commit it
$EDITOR .env                  # fill in real HELIX_* values

# 2. Source .env into the environment and run the doctor:
set -a; . ./.env; set +a
scripts/svord_doctor.sh; echo "exit=$?"
```

Optional override (used by tests): `SVORD_BRIDGE_LIB=/path/to/svord_bridge.sh`.

### Verdicts + exit codes

The final line always matches `^BRIDGE: `; parse it, ignore the `svord-doctor:`
diagnostic lines above it.

| Verdict line | Exit | Meaning |
|---|---|---|
| `BRIDGE: UP` | 0 | Contract resolved, hooks executable, health exit 0, host reachable |
| `BRIDGE: SKIP:network_unreachable_external` | 2 | Bridge down / host unreachable — OPERATOR-BLOCKED (§11.4.68) |
| `BRIDGE: SKIP:host_probe_unavailable` | 2 | No `ping`/`nc` present — reachability cannot be confirmed (honest, not UP) |
| `BRIDGE: MISCONFIGURED:env_unset` | 3 | One or more contract vars unset/empty |
| `BRIDGE: MISCONFIGURED:hook_not_executable:<vars>` | 3 | A hook's first-token path is missing / not executable |
| `BRIDGE: MISCONFIGURED:bridge_lib_missing` | 3 | `svord_bridge.sh` not found |

Downstream test harness convention: exit `0` → run the live path; exit `2` →
SKIP with `network_unreachable_external`; exit `3` → SKIP/FAIL as a
configuration error (fix the contract first).

## Edge cases

- **Contract unset** → `MISCONFIGURED:env_unset` (exit 3), NOT UP. The doctor
  lists exactly which vars are unset on the `svord-doctor:` diagnostic lines.
- **Hook path not executable** → `MISCONFIGURED:hook_not_executable:<vars>`
  (exit 3). Only the first whitespace token of each hook command is checked, so
  hooks may carry arguments (e.g. `.../svord-ssh-health --quiet`).
- **Unexpanded `${VAR}` in a hook value** → treated as a literal path; if it
  does not resolve to an existing file the doctor reports misconfigured. Source
  your `.env` with `set -a` so the shell expands the values first. The doctor
  never `eval`s hook contents (injection-safe, §11.4.10).
- **Health probe exits non-zero** → `SKIP:network_unreachable_external`
  (exit 2). This is the authoritative down signal; the host probe is not reached.
- **Host unreachable but health up** → `SKIP:network_unreachable_external`
  (exit 2). ICMP-filtered hosts fall back to a TCP probe (`nc`) before being
  declared down.
- **Neither `ping` nor `nc` present** → `SKIP:host_probe_unavailable` (exit 2) —
  the doctor refuses to claim UP it cannot confirm (§11.4.6).

## Internal behaviour

1. Resolve + source `tests/lib/svord_bridge.sh` (`SVORD_BRIDGE_LIB` override).
2. `bridge_load` — every one of the 6 contract vars set + non-empty, else
   `MISCONFIGURED:env_unset` (3).
3. For `HELIX_BRIDGE_CONNECT` / `_DISCONNECT` / `_HEALTH`: first token must be an
   existing, executable file, else `MISCONFIGURED:hook_not_executable` (3).
4. `bridge_up` — run `HELIX_BRIDGE_HEALTH`; non-zero → `SKIP:network_unreachable_external` (2).
5. Smoke-probe `HELIX_BRIDGE_HOST` (`ping -c1 -W1`, TCP fallback) → unreachable
   `SKIP:network_unreachable_external` (2); no probe tool `SKIP:host_probe_unavailable` (2).
6. Otherwise `BRIDGE: UP` (0).

The doctor is **invocation-only**: it runs the operator's hooks and one smoke
probe, writes nothing, and modifies neither the bridge project nor any remote
host (§11.4.122).

## Related scripts

- [`tests/lib/svord_bridge.sh`](../../tests/lib/svord_bridge.sh) — the sourceable
  contract library (`bridge_load`, `bridge_up`, `bridge_require`,
  `bridge_subnet`, `bridge_host`).
- [`.env.example`](../../.env.example) — the tracked contract template (§3).
- [`docs/design/vpn_lan_access/PLAN.md`](../design/vpn_lan_access/PLAN.md) — the
  feature design (§3 contract, §5 Phase 0).

## Anti-bluff evidence

Phase-0 discrimination proof (same local stub bridge, only the health exit code
differs → verdict flips UP ↔ SKIP) captured under
`qa-results/vpn_lan/phase0/<UTC-ts>/`:

| Condition | Verdict | Exit |
|---|---|---|
| contract UNSET | `MISCONFIGURED:env_unset` | 3 |
| stub health exit 0, host `127.0.0.1` | `UP` | 0 |
| stub health exit 1 (RED teeth) | `SKIP:network_unreachable_external` | 2 |

## Last verified date

2026-07-01 — `sh -n` + `bash -n` PASS; 3-verdict discrimination proof + lib
primitive proof captured under `qa-results/vpn_lan/phase0/20260701T155245Z/`.
