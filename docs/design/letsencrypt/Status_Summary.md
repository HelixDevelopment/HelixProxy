# Let's Encrypt HTTPS — Status Summary

**Revision:** 1
**Last modified:** 2026-07-01T12:15:00Z
**Status:** Companion summary of [`Status.md`](Status.md) (§11.4.56 two-audience).

---

## Page 1 — For the operator / stakeholders (plain language)

We are adding **automatic HTTPS** to the proxy using **Let's Encrypt** — free, auto-renewing
TLS certificates — with **Caddy** doing the certificate work in-process (no scripts or cron
to babysit) and the **DNS-01** method so it works even without opening ports on the host.

**What works today:**

- The three setup decisions are locked in (Caddy, DNS-01, test-first then defer the real
  domain).
- A **certificate checker** is built and proven: it can tell whether a resulting certificate
  is still valid, how many days are left, whether it covers the right hostname, and whether it
  was issued by the expected authority — all offline, and it is self-tested so it cannot lie
  (a deliberately-broken certificate is always caught).

**What's still pending / needs you:**

- Issuing a real certificate end-to-end (first against a local test server, then Let's Encrypt
  **staging**) — the next automated step is the local hermetic test.
- **Going live on the real domain** needs you to provide a DNS provider API token and give the
  go-ahead. Until then nothing touches production.

**Bottom line:** the foundation and the safety-checker are done and proven; certificate issuance
and the real-domain go-live are the remaining steps, the last one waiting on your go-ahead.

---

## Page 2 — For software engineers

- **Task:** #59 Let's Encrypt HTTPS + auto-renewal + rotation (feature workstream, §11.4.167).
- **Phase 0 (PASS):** operator decisions captured via §11.4.66 — Caddy auto-HTTPS / DNS-01 /
  hermetic+staging-first, defer real domain. Design `LETSENCRYPT_HTTPS.md` + plan `_PLAN.md` @ `fddd25c`.
- **Phase 1 cert-analyzer (PASS):** `tests/letsencrypt/cert_analyzer.sh` — 5 pure, now-seam-deterministic
  (§11.4.50 `CERT_ANALYZER_NOW_EPOCH`) functions; SAN match is exact-token + single-leading-wildcard
  (no substring, mirrors `_code_in`); chain check is issuance-only (`openssl verify -no_check_time`),
  orthogonal to expiry. Self-validated §11.4.107(10): `cert_analyzer_selftest.sh` 37/37;
  `tests/regression/cert_analyzer_selfvalidation_test.sh` GREEN+`RED_MODE=1` PASS; §1.1 mutation
  (SAN exact→substring) → guard FAIL, restore byte-identical md5 `a06e0f89ee9993fe5de368be852e4eff`.
  Fixtures: public `*.pem` tracked, `*.key`/`*.csr`/`*.srl` gitignored (§11.4.10), regen via
  `fixtures/gen_fixtures.sh` (§11.4.77).
- **Pending (autonomous):** custom Caddy DNS-01 image (§11.4.76 containers submodule, rootless §11.4.161),
  Phase 2 compose+secret+volume wiring, Phase 3 Pebble hermetic issuance (anti-bluff core), Phase 5
  renewal/rotation sim.
- **OPERATOR-BLOCKED:** Phase 4 LE-staging (real DNS-01 token §11.4.10), Phase 6 prod cutover (real-domain go-live gate, design §9).
- **Guard wiring:** `cert_analyzer_selfvalidation_test.sh` to be registered in `run-tests.sh`
  `test_regression_guards()` (§11.4.135) with the LE lane commit.
- **Anti-bluff:** every non-PASS row is honestly PENDING/OPERATOR-BLOCKED (§11.4.6) — no
  metadata-only PASS; the analyzer is ready to assert the output of the issuance phases when they land.
