# `tests/regression/assert_egress_ip_host_unknown_test.sh` — operator guide

**Revision:** 2
**Last modified:** 2026-07-01T12:00:00Z
**Status:** Active standing regression guard (§11.4.135) for finding F7 (+ F-1 hardening).

> Companion (§11.4.18) to the in-source documentation block at the top of the
> script. Sibling of `docs/scripts/external_egress_verdict_test.md`.

## Overview

A standing regression guard that proves `tests/lib/evidence.sh`'s
`assert_egress_ip()` never **fake-PASSes** the VPN-routing proof when the host's
**real IP is not a trustworthy public IP** — unknown, empty, non-IP garbage (a
captive-portal / rate-limit HTML body a `curl -s` 200 can echo), or a
non-public sentinel like `0.0.0.0` / `127.x` (**F-1 hardening**).

The proof (design §15) has **two independent halves**:

1. `egress == expected_exit` — traffic left via the expected VPN tunnel exit; and
2. `egress != host_real` — traffic did **not** simply leave the host's own uplink
   (an egress that equals the host's real IP means **no VPN routing happened** —
   the §15 bluff).

Pre-fix, when a caller's IP-echo fallback fired — `curl ifconfig.me || echo
"unknown"` in `verify-proxy.sh` / `final-verify.sh` / `comprehensive-test.sh`, or
`|| true` (empty) in `real_vpn_egress_proof.sh` — `host_real` became the literal
`"unknown"` / `""`. Comparing the observed egress against `"unknown"`/`""`
trivially satisfies "different", so the `egress != host` half **silently
collapsed**: a genuine `egress == host` (no-VPN) case could still PASS. That is the
§11.4.68 **fail-open** — the anti-VPN-bluff check losing half its assertion the
moment the host IP is unknown.

The fix: when `host_real` is `unknown`/empty the `!=host` half is **unverifiable**,
so the call is classified as follows (never a fail-open PASS):

| `host_real` | observed vs `expected_exit` | verdict | rc | meaning |
|---|---|---|---|---|
| known | `==` exit, `!=` host | `PASS` | 0 | genuine proof — both halves verified |
| known | `==` host | `FAIL` | 1 | the §15 bluff — no VPN routing |
| known | `!=` exit | `FAIL` | 1 | wrong exit |
| `unknown` / `""` / garbage / sentinel | `!=` exit | `FAIL` | 1 | wrong exit is a **provable** defect regardless of host |
| `unknown` / `""` / garbage / sentinel | `==` exit | `OPERATOR-BLOCKED` | 2 | `!=host` half **unverifiable** — never PASS; §11.4.69 reason `network_unreachable_external`; rerun once the host public IP is determinable |

**F-1:** `host_real` is validated to be **IP-shaped** (IPv4 with 0–255 octets, or an
IPv6 hex:colon form) via `_evidence_ip_shaped` rather than deny-listing the two
literal sentinels `""`/`"unknown"`. A non-empty, non-`"unknown"` **garbage** value
(HTML body) or a non-public sentinel (`0.0.0.0`, `127.x`, `::`, `::1`) is exactly as
unverifiable as an empty one and takes the same exit-2 branch — closing the residual
window where a garbage `host_real` could re-collapse the `!=host` half.

Return `2` (OPERATOR-BLOCKED) rather than a return-`0` SKIP is deliberate: for a
sink-unreachable condition §11.4.68 mandates **exit-2 OPERATOR-BLOCKED, never a
fail-open SKIP-as-PASS**. Existing `if assert_egress_ip …; then test_pass; else
test_fail; fi` callers route the non-zero into their FAIL/block branch — safe (the
old behaviour would have fake-PASSed).

It does **not** grep the source. GREEN sources the **real** shipped
`assert_egress_ip` and drives it through the committed `EVIDENCE_OBSERVED_IP_FILE`
fixtures — deterministic, no network.

## Prerequisites

- POSIX `sh`, `awk`, `tr` (via sourced `evidence.sh`). No network, no privileges.
- Committed fixtures `tests/lib/fixtures/egress_observed_vpn.ip` (`185.65.135.70`)
  and `egress_observed_host.ip` (`203.0.113.45`).

## Usage examples

```bash
# GREEN guard (default) — fail-open closed, provable defect FAILs, genuine PASS kept:
tests/regression/assert_egress_ip_host_unknown_test.sh            # exit 0 = PASS

# RED reproduce — the pre-fix replica fake-PASSes the hidden §15 bluff:
RED_MODE=1 tests/regression/assert_egress_ip_host_unknown_test.sh # exit 0 = defect reproduced
```

## §11.4.115 RED_MODE polarity

| `RED_MODE` | What it runs | PASS means |
|---|---|---|
| `0` (default) | the REAL shipped `assert_egress_ip` (sourced from `evidence.sh`) | host `unknown`/`""` + `egress==exit` → `2`; host `unknown` + `egress==host` → `2`; host `unknown` + wrong exit → `1`; host known + `egress==exit && !=host` → `0` (GREEN guard) |
| `1` | a faithful PRE-FIX replica (3-check logic, no host-unknown guard) | `egress==host==expected` with host `"unknown"` → rc `0` PASS → the §11.4.68 fail-open reproduces |

A `RED_MODE=1` run that cannot reproduce is a finding per §11.4.7, not a pass.

## Edge cases

- **Fix reverted / guard neutered** (the `host_real` unknown/empty branch removed
  or made unreachable) → the GREEN guard reports `REGRESSION: unknown/empty host no
  longer refused …` and exits 1 (the §1.1 paired-mutation behaviour, verified
  against the real function).
- **Wrong-exit under unknown host** stays a `FAIL(1)` — an egress that is
  definitively not the expected VPN exit is a provable defect independent of host
  knowledge, so the guard must **not** let the unknown-host branch swallow it into
  an OPERATOR-BLOCKED.
- **Genuine PASS preserved** — a fully-known, correctly-routed case
  (`egress==exit && !=host`) must still return `0`; the guard asserts this so the
  fix cannot over-block.

## Internal behaviour

- `#!/bin/sh`, `set -eu`; POSIX-only, `sh -n` / `bash -n` parse-clean (§11.4.67).
- GREEN sources `tests/lib/evidence.sh` and drives the real `assert_egress_ip` via
  the `EVIDENCE_OBSERVED_IP_FILE` unit-test seam with the committed fixtures.
- RED runs a self-contained pre-fix replica (no network, no seam).
- Writes one evidence file per run under
  `qa-results/regression/assert_egress_ip_host_unknown/` (gitignored).

## Related

- Fix site: `tests/lib/evidence.sh` — `assert_egress_ip()` host-unknown guard.
- Unit-layer cases: `tests/lib/evidence_selftest.sh` — the F7 block
  (`run_case 2 … host UNKNOWN/EMPTY …`, `run_case 1 … WRONG exit …`).
- Callers protected: `tests/verify-proxy.sh`, `tests/final-verify.sh`,
  `tests/comprehensive-test.sh`, `tests/egress_proof/real_vpn_egress_proof.sh`,
  `tests/dynamic/analyzers/egress_neq_host_analyzer.sh`.
- `tests/run-tests.sh` — registers this guard (GREEN + `RED_MODE=1`) in the standing
  `test_regression_guards()` suite as `BUGFIX-0018 assert-egress …` (§11.4.135).
- `docs/issues/fixed/BUGFIXES.md` — BUGFIX-0018 (F7 + F-1).

## Last verified

2026-07-01 — `sh -n` / `bash -n` parse-clean; GREEN asserts `2/2/2/1/0` for the five
canonical cases **plus** the two F-1 cases (`0.0.0.0` sentinel + garbage-HTML hidden
bluff → `2/2`) (exit 0); `RED_MODE=1` reproduces the fail-open (exit 0); paired §1.1
mutation (`return 2` → `return 0` in the unverifiable-host branch) makes GREEN FAIL
(exit 1 — "fail-open re-opened"), then restores byte-identical (`md5 976cb15…` before
== after); full `evidence_selftest.sh` = 45 pass / 0 fail; registered in the standing
`run-tests.sh` suite (full run: 59 run / 53 pass / 6 skip / 0 fail).
