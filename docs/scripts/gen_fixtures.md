# `tests/letsencrypt/fixtures/gen_fixtures.sh` — operator guide

**Revision:** 1
**Last modified:** 2026-07-01T00:00:00Z
**Status:** Active hermetic `openssl` generator (§11.4.77 regeneration
mechanism) for the `cert_analyzer` golden-good / golden-bad fixture corpus.

> Companion (§11.4.18) to the in-source documentation block at the top of the
> script.

## Overview / Purpose

Regenerates the golden-good + golden-bad certificate fixtures that self-validate
`cert_analyzer.sh` (§11.4.107(10)). Everything it produces is EPHEMERAL
throwaway test material — self-signed TEST CAs, NOT real Let's Encrypt certs, NO
production private keys, NO secrets (§11.4.10). The generated `*.key` / `*.csr`
/ `*.srl` are gitignored (`tests/letsencrypt/fixtures/.gitignore`); only the
public `*.pem` certs are tracked and regenerated on demand by re-running this
script (§11.4.77).

Fully deterministic: FIXED validity windows are baked in via
`openssl -not_before` / `-not_after` so the fixtures do NOT depend on the
generation date — they are pinned relative to the reference "now"
`2026-07-01T12:00:00Z` used by the self-test (§11.4.50).

## Usage

```sh
GOMAXPROCS=2 nice -n 19 ionice -c 3 \
    bash tests/letsencrypt/fixtures/gen_fixtures.sh
```

Runs from anywhere — it resolves its own directory and `cd`s into it. Normally
invoked automatically by `cert_analyzer_selftest.sh` when the tracked `*.pem`
set is missing.

## Inputs

None (fully deterministic — validity windows are hard-coded constants).

## Outputs

Under `tests/letsencrypt/fixtures/` (tracked `*.pem`):

| Fixture | Content |
|---|---|
| `test_ca.pem` | self-signed TEST CA (the "expected CA"). |
| `good_leaf.pem` | issued by `test_ca`, SAN `proxy.test`, window straddling the ref now (~60d remain). |
| `expired_leaf.pem` | issued by `test_ca`, `NotAfter` in the past. |
| `nearexpiry_leaf.pem` | issued by `test_ca`, ~4-5 days left at ref now. |
| `wrongca_leaf.pem` | signed by a DIFFERENT CA, SAN `proxy.test` (right host, WRONG issuer). |
| `otherhost_leaf.pem` | issued by `test_ca`, SAN `other.test` (right issuer, WRONG host). |
| `wildcard_leaf.pem` | issued by `test_ca`, SAN `*.proxy.test`. |
| `doublewild_leaf.pem` | issued by `test_ca`, SAN `*.*.proxy.test` (malformed double-wildcard — must never match). |
| `nosan_leaf.pem` | issued by `test_ca`, CN `proxy.test`, NO SAN extension (empty-SAN). |
| `ipsan_leaf.pem` | issued by `test_ca`, SAN `IP:10.0.0.1` only (IP-only SAN). |
| `dnsandip_leaf.pem` | issued by `test_ca`, SAN `DNS:proxy.test,IP:10.0.0.1` (mixed). |
| `malformed_leaf.pem` | present-but-truncated/unparseable PEM (first 3 lines of `good_leaf.pem`). |

Plus gitignored `*.key` / `*.csr` / `*.srl` throwaway material. Emits a
`gen_fixtures: wrote <list>` line on stdout.

## Side-effects

Writes the files above into `tests/letsencrypt/fixtures/`; removes the
throwaway serial files (`test_ca.srl`, `wrong_ca.srl`) and each intermediate
`*.csr`. No network, no containers. `set -eu` (aborts on error / unset var).

## Dependencies

POSIX `sh`, `openssl` — specifically `req -x509` / `x509 -req` with
`-not_before` / `-not_after` / `-copy_extensions` / `-no_check_time`
(**OpenSSL 3.2+**), plus `head`, `rm`, `printf`. POSIX-clean — parses under
`sh -n` AND `bash -n` (§11.4.67).

## Edge cases

- **Malformed fixture** is produced deterministically by truncating
  `good_leaf.pem` to its first 3 lines — guaranteed unparseable regardless of
  key bytes.
- **Wildcard fixtures** exercise the single-leading-wildcard branch
  (`*.proxy.test`) and the illegal double-wildcard reject (`*.*.proxy.test`).
- **Empty-SAN / IP-only / mixed DNS+IP** fixtures pin the SAN-matching
  discipline (no CN fallback; dNSName-only; DNS isolated from IP).
- Re-running is idempotent — it overwrites the tracked `*.pem` set with
  byte-equivalent windows (dates are fixed; only the throwaway keys differ).

## Related scripts

- `tests/letsencrypt/cert_analyzer.sh` — the library these fixtures validate.
- `tests/letsencrypt/cert_analyzer_selftest.sh` — consumes the fixtures and
  self-bootstraps by running this generator when they are absent.
- Constitution §11.4.77 (regeneration mechanism), §11.4.10 (no real secrets),
  §11.4.107(10) (self-validated analyzer), §11.4.50; design
  `LETSENCRYPT_HTTPS_PLAN.md` Phase 3.

## Last verified

2026-07-01 — documented against the script source; `sh -n` / `bash -n`
parse-clean. Produces the tracked `*.pem` corpus consumed by
`cert_analyzer_selftest.sh` (requires OpenSSL 3.2+ for the date flags).
