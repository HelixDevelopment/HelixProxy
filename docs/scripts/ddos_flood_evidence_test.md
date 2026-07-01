# ddos_flood_evidence_test.sh — §11.4.18 companion doc

**Revision:** 1
**Last modified:** 2026-07-01T00:00:00Z

## Overview

`tests/regression/ddos_flood_evidence_test.sh` is the §11.4.135 standing
regression guard for finding **F5** — the DDoS / load-flood suite
(`tests/dynamic/suites/ddos_flood_suite.sh`) used to score a
"survived the flood / degraded-not-collapsed" **PASS without any positive
captured evidence that a flood was ever generated**. It is a fixture-driven
guard: it extracts the real pure classifier `flood_survival_verdict()` from
the tracked suite and drives it with canonical fixtures. It needs **no live
stack, no network, and no containers**.

## Prerequisites

- POSIX `sh`, `awk`, `mktemp`, and `bash` (the extracted-function probe runner).
- The tracked suite `tests/dynamic/suites/ddos_flood_suite.sh` containing the
  `flood_survival_verdict()` function (the fix under guard).

## Usage examples

```sh
# GREEN guard (default) — asserts the FIXED classifier refuses the zero-flood
# bluff, PASSes a real survived flood, still FAILs a real crash, and honestly
# SKIPs when the proxy is absent.
tests/regression/ddos_flood_evidence_test.sh

# RED reproduce — asserts the PRE-FIX survival gate (pid_stable=1 && rec=200
# ONLY, ignoring the flood counter) PASSes a zero-flood run (the §11.4.1 bluff).
RED_MODE=1 tests/regression/ddos_flood_evidence_test.sh
```

Run under host-safety caps per the constitution:

```sh
GOMAXPROCS=2 nice -n 19 ionice -c 3 tests/regression/ddos_flood_evidence_test.sh
```

Exit code: `0` = PASS, `1` = FAIL. A structured verdict line plus an evidence
file under `qa-results/regression/ddos_flood_evidence/` are produced on every
run.

## The four GREEN fixtures

`flood_survival_verdict <pid_stable> <recovery_code> <flood_total> <flood_responses> <proxy_listening>`

| Fixture   | Args                    | Expected verdict               | Why |
|-----------|-------------------------|--------------------------------|-----|
| ZERO      | `1 200 0 0 yes`         | `FAIL:no-flood-evidence`       | Proxy up but the flood issued zero requests → the "survived a flood" claim is vacuous (§11.4.1 bluff refused). |
| SURVIVED  | `1 200 3000 2950 yes`   | `PASS`                         | A real flood (3000 issued, 2950 measurable), PID stable, recovered to 200. |
| CRASHED   | `0 000 3000 100 yes`    | `FAIL:crashed-or-no-recovery`  | A real flood but PID changed / no recovery — the anti-bluff crash catch preserved. |
| ABSENT    | `1 200 0 0 no`          | `SKIP:topology_unsupported`    | No flood evidence AND the proxy is not listening → honest topology SKIP, never a silent PASS. |

## Edge cases

- **Non-numeric counters** — `flood_survival_verdict` sanitises `flood_total`
  and `flood_responses` to `0` when empty/non-numeric (`case … *[!0-9]*`), so a
  malformed counter degrades to "no flood evidence" (FAIL/SKIP), never a bluff
  PASS.
- **Multi-line probe output** — the guard matches with `case … in *A*B*` globs;
  `*` spans newlines in POSIX `case`, so the ordered four-fixture assertion holds.
- **RED cannot reproduce** — if the pre-fix replica does NOT PASS the zero-flood
  fixture, the guard reports a §11.4.7 finding rather than a false GREEN.

## Internal behaviour

The guard writes a small probe script to a `mktemp` file:

- **GREEN** — `awk`-extracts the `flood_survival_verdict()` body verbatim from
  the tracked suite (real function, not a grep of expected strings), appends
  four `echo "<LABEL>=$(flood_survival_verdict …)"` drivers, and runs it under
  `bash`. It PASSes iff the concatenated output matches
  `*ZERO=FAIL:no-flood-evidence*SURVIVED=PASS*CRASHED=FAIL:crashed-or-no-recovery*ABSENT=SKIP:topology_unsupported*`.
- **RED** — emits the faithful pre-fix replica
  `_prefix_flood_verdict() { [ "$1" = 1 ] && [ "$2" = 200 ] && echo PASS || echo FAIL; }`
  and asserts it prints `ZERO=PASS` for the zero-flood fixture (the reproduced
  bluff).

## §1.1 paired mutation

Mutating the suite's `flood_survival_verdict` so the zero-count case wrongly
PASSes (e.g. neutralising the `flood_total<=0 || flood_responses<=0` guard) makes
the GREEN run's `ZERO=FAIL:no-flood-evidence` expectation fail — the guard emits
`REGRESSION: …` and exits `1` with a real assertion mismatch (not a parse error).
Restoring the suite byte-identical (md5 match) returns the guard to GREEN.

## Related scripts

- `tests/dynamic/suites/ddos_flood_suite.sh` — the suite under guard (the fix).
- `tests/lib/evidence.sh` — `ab_pass_with_evidence` / `ab_skip_with_reason` /
  `port_is_listening` helpers the suite reuses.
- `tests/regression/external_egress_verdict_test.sh` — the house pattern this
  guard is modelled on.

**Last verified:** 2026-07-01
