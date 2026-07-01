# `tests/chaos/proxy_restart_recovery.sh` — operator guide

**Revision:** 1
**Last modified:** 2026-07-01T00:00:00Z
**Status:** Authored + parse-clean. Detects the Squid container (READ-ONLY) and
honest-`SKIP`s (§11.4.3) when it is absent or when the restart hook is not
configured. The restart + recovery assertion runs when the **conductor** supplies
the injection command.

> Companion (§11.4.18) to the in-source documentation block at the top of the
> script.

## Overview

§11.4.85 / §11.4.169 **chaos** suite proving the LIVE HTTP forward proxy (Squid,
`localhost:53128`) **recovers after a mid-flight container restart** — the
process-death / §11.4.144 detect → wait → re-attach contract:

1. capture a **working** proxied request (baseline `204`/`200`),
2. inject the fault — restart the squid container (delegated, see below),
3. poll the proxied request through a **bounded recovery window** and assert it
   recovers to `204`/`200`,

emitting a **categorised recovery trace** (`baseline_ok` / `fault_injected` /
`probe … state=DOWN` / `recovered … state=UP`) with per-event UTC timestamps.
Every PASS cites the captured `recovery_trace.log` (§11.4.69).

## Fault injection (delegated — never hardcoded)

The script **never** hardcodes `podman`/`docker restart` — the containers
submodule (§11.4.76) plus the container/CI hard-stop forbid ad-hoc container
commands. The restart is a **config-injected** command (§11.4.28) the conductor
supplies via `PROXY_CHAOS_RESTART_CMD`. When it is **unset**, the fault cannot be
injected autonomously, so the suite `SKIP`s-with-reason
(`feature_disabled_by_config`) — the authoring agent never restarts a container.

## Prerequisites

- Committed library `tests/lib/evidence.sh` (sourced).
- `curl`, `awk`, `grep`, POSIX `sh`, `date`.
- `podman` OR `docker` for READ-ONLY container detection (optional).
- For the live assertion: a running `proxy-squid` container **and**
  `PROXY_CHAOS_RESTART_CMD` set to a containers-submodule restart command.
- Write access to `qa-results/` (gitignored).

## Usage examples

- Authoring / no-hook run (honest SKIP):
  `bash tests/chaos/proxy_restart_recovery.sh`
- Conductor run with the injection hook:
  `PROXY_CHAOS_RESTART_CMD='<containers-submodule restart proxy-squid>' bash tests/chaos/proxy_restart_recovery.sh`
- Under host-safety caps:
  `GOMAXPROCS=2 nice -n 19 ionice -c 3 PROXY_CHAOS_RESTART_CMD='…' bash tests/chaos/proxy_restart_recovery.sh`

Env knobs: `HTTP_PROXY_URL` (default `http://localhost:53128`), `HTTP_PROXY_PORT`
(default `53128`), `CHAOS_SQUID_CONTAINER` (default `proxy-squid`), `CHAOS_TARGET`
(default `https://www.gstatic.com/generate_204`), `CHAOS_EXPECT` (default
`204 200`), `CHAOS_RECOVERY_TIMEOUT` (default `60` s — the reused reconnect
budget), `CHAOS_RECOVERY_POLL` (default `2` s), `CURL_MAX_TIME` (default `15`),
`PROXY_CHAOS_RESTART_CMD` (injection hook), `CHAOS_EVIDENCE_DIR` (default
`qa-results/chaos/proxy_restart_<ts>`).

## Edge cases

- **Squid container not running** → `SKIP` (`topology_unsupported`). Exit `3`.
- **No healthy baseline through the proxy** → `SKIP` (`topology_unsupported`) —
  a broken baseline is a different defect owned by the forward-proxy suites, not
  a recovery failure. Exit `3`.
- **`PROXY_CHAOS_RESTART_CMD` unset** → `SKIP` (`feature_disabled_by_config`) —
  the fault is not injectable autonomously. Exit `3`.
- **Recovers within the window** → `PASS`, citing `recovery_trace.log`. Exit `0`.
- **Never recovers within `CHAOS_RECOVERY_TIMEOUT`** → `FAIL`. Exit `1`.

## Internal behaviour

- `#!/usr/bin/env bash`, POSIX-clean body (`sh -n` + `bash -n`, §11.4.67).
- READ-ONLY `podman ps` / `docker ps` detection (whole-name match).
- Bounded poll loop uses the reused reconnect budget (never invented, §11.4.6):
  poll every `CHAOS_RECOVERY_POLL` s up to `CHAOS_RECOVERY_TIMEOUT` s.
- `trace()` writes categorised timestamped events to `recovery_trace.log`.
- `trap ... EXIT INT TERM` leaves the target quiescent (§11.4.14).
- Resources: shell + curl only, single-threaded poll, well under §12.6.

## Related

- `tests/lib/evidence.sh` — sourced anti-bluff evidence library.
- `tests/dynamic/suites/chaos_suite.sh` — the P10 dynamic-stack chaos suite (same
  delegated-injection pattern).
- `tests/stress/proxy_forward_stress.sh`, `tests/security/proxy_acl_security.sh`
  — sibling stress + security suites.
- Constitution §11.4.85 / §11.4.169 / §11.4.144 / §11.4.69 / §11.4.28 / §11.4.76 /
  §11.4.14 / §11.4.6.

## Last verified

2026-07-01 — authored; `sh -n` + `bash -n` parse-clean; no-hook run yields an
honest SKIP. The restart + recovery assertion is exercised by the conductor with
`PROXY_CHAOS_RESTART_CMD` set.
