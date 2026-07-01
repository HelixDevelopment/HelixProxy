# `challenges/scripts/no_suspend_calls_challenge.sh` — operator guide

**Revision:** 1
**Last modified:** 2026-07-01T00:00:00Z
**Status:** Active CONST-033 source-tree gate. Thin challenge wrapper around the
static scanner `check-no-suspend-calls.sh`.

> Companion (§11.4.18) to the in-source documentation block at the top of the
> script.

## Overview / Purpose

CONST-033 forbids any code that triggers a host-level power-state transition
(suspend / hibernate / hybrid-sleep / poweroff / halt / reboot / kexec). This
challenge asserts the project's **source tree** contains zero such forbidden
invocations. It is the source-side complement of
`host_no_auto_suspend_challenge.sh` (which checks the running host's state).

It is a wrapper: it locates and runs `check-no-suspend-calls.sh` (the actual
scanner) against the project root and propagates its verdict. It resolves the
scanner relative to its own location, so it works whether invoked from the
project root or from `challenges/scripts/`.

## Usage

```sh
bash challenges/scripts/no_suspend_calls_challenge.sh
```

No arguments. It walks up from its own directory until it finds
`scripts/host-power-management/check-no-suspend-calls.sh`, treats that
directory's parent as the project root, and scans it.

## Inputs

- None on the command line.
- Discovers the project root by walking parent directories from
  `${BASH_SOURCE[0]}` looking for
  `scripts/host-power-management/check-no-suspend-calls.sh`.

## Outputs

- A header (`Scanner:` / `Root:` paths), the scanner's own findings, and a
  `=== summary: PASS|FAIL ===` line on stdout; violations (if any) are printed
  by the scanner.
- Exit code: `0` = clean (no forbidden calls); `1` = one or more violations;
  `2` = the scanner could not be located.

## Side-effects

None. Read-only static scan of the source tree — no files written, no host
power state touched (§11.4.14).

## Dependencies

`bash`; the delegated scanner
`scripts/host-power-management/check-no-suspend-calls.sh` (which itself uses
`grep`/`find`-class tooling to walk the tree). If the scanner is missing the
wrapper exits `2` with a diagnostic rather than a false PASS (§11.4.1).

## Edge cases

- **Scanner not found** (walking up to `/` fails) → exit `2`, message
  `cannot locate scripts/host-power-management/check-no-suspend-calls.sh`.
- **Invoked from any cwd** → the self-relative root resolution makes the
  verdict independent of the working directory.
- The scanner excludes third-party / generated / justified-non-host-context
  directories (`.git`, `vendor`, `upstreams`, the constitution submodule, …) so
  a documentation reference to a forbidden command is not a false positive.

## Related scripts

- `scripts/host-power-management/check-no-suspend-calls.sh` — the wrapped
  scanner (the real logic).
- `challenges/scripts/host_no_auto_suspend_challenge.sh` — the HOST-state gate
  (this one is the SOURCE-tree gate).
- Constitution CONST-033 (host power-management hard ban), §11.4.1.

## Last verified

2026-07-01 — documented against the script + scanner source; `sh -n` /
`bash -n` parse-clean. Run as part of the CONST-033 source-tree verification.
