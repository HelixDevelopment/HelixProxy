# `challenges/scripts/host_no_auto_suspend_challenge.sh` — operator guide

**Revision:** 1
**Last modified:** 2026-07-01T00:00:00Z
**Status:** Active CONST-033 host-hardening reproduction guard. Self-contained
(no framework dependency). Verifies the DEVELOPER HOST cannot auto-suspend.

> Companion (§11.4.18) to the in-source documentation block at the top of the
> script.

## Overview / Purpose

CONST-033 forbids any host-level power-state transition (auto-suspend has
historically caused data loss on the mission-critical host). This challenge
asserts that the host it runs on cannot be suspended / hibernated / put into
hybrid-sleep by any user, session, desktop environment, greeter, or cron job —
"defence in depth". It checks the runtime host state produced by the sibling
`install-host-suspend-guard.sh` fix (target masking + `sleep.conf` override +
logind `IdleAction` override), not the source tree (that is
`no_suspend_calls_challenge.sh`).

Four assertions (all must pass):

1. `systemctl is-enabled` reports `masked` for **all four** of `sleep.target`,
   `suspend.target`, `hibernate.target`, `hybrid-sleep.target`.
2. `AllowSuspend=no` is present in `/etc/systemd/sleep.conf` or any
   `/etc/systemd/sleep.conf.d/*.conf` drop-in.
3. logind `IdleAction` is `ignore` (or unset, which defaults to ignore).
4. The journal shows zero `The system will suspend now` broadcasts since the
   fix marker `/etc/systemd/sleep.conf.d/00-no-suspend.conf` was written.

## Usage

```sh
bash challenges/scripts/host_no_auto_suspend_challenge.sh
```

No arguments. Run it after `install-host-suspend-guard.sh` has hardened the
host. It reads system state only — it never changes power settings.

## Inputs

- None on the command line.
- Reads host state: `systemctl is-enabled` for the four sleep targets;
  `/etc/systemd/sleep.conf` + `/etc/systemd/sleep.conf.d/*.conf`;
  `/etc/systemd/logind.conf` + `/etc/systemd/logind.conf.d/*.conf`; the fix
  marker `/etc/systemd/sleep.conf.d/00-no-suspend.conf`; and `journalctl` since
  the marker's mtime.

## Outputs

- Human-readable `PASS:` / `FAIL:` lines per assertion, a per-target state
  listing, and a `=== summary: N pass, M fail ===` line on stdout.
- Exit code: `0` = all 4 assertions PASS; `1` = one or more FAIL; `2` =
  invocation error (documented in-source; not currently reached by any code
  path).

## Side-effects

None. Purely read-only host introspection — no files written, no services
touched, no power state changed. (§11.4.14 quiescent — the target host is left
exactly as found.)

## Dependencies

`bash`, `systemctl`, `journalctl`, `grep`, `stat`, `date`, `tr`, `cut`, `head`
(systemd host). Absent optional inputs degrade to `<unset>` / `unknown` rather
than crashing (`set -uo pipefail` with guarded command substitutions,
§11.4.1).

## Edge cases

- **Fix marker missing** → assertion 4 FAILs with a pointer to run
  `install-host-suspend-guard.sh`.
- **A sleep target not masked** → assertion 1 FAILs, listing the offending
  `target(state)`.
- **`IdleAction` unset** is treated as safe (systemd defaults to ignore).
- Assertion 4 dates the window from the marker's mtime, so pre-fix suspend
  broadcasts do not count against the current hardening.

## Related scripts

- `scripts/host-power-management/install-host-suspend-guard.sh` — the fix this
  challenge validates.
- `challenges/scripts/no_suspend_calls_challenge.sh` — the SOURCE-tree gate
  (this one is the HOST-state gate).
- `scripts/host-power-management/check-no-suspend-calls.sh` — the static
  scanner.
- Constitution CONST-033 (host power-management hard ban), §11.4.14.

## Last verified

2026-07-01 — documented against the script source; `sh -n` / `bash -n`
parse-clean. The live host-state assertions run on a systemd host per
CONST-033 verification.
