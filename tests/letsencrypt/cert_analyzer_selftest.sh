#!/usr/bin/env bash
# =============================================================================
# cert_analyzer_selftest.sh — TAP self-test for tests/letsencrypt/cert_analyzer.sh
# -----------------------------------------------------------------------------
# Purpose:      Prove every cert_analyzer.sh function is CORRECT against the
#               golden-GOOD fixtures AND provably REJECTS every golden-BAD
#               fixture (expired / not-yet-valid / expired-just-now &
#               NotBefore/NotAfter boundary / wrong-CA / wrong-host /
#               near-expiry / substring-not-a-match / double-wildcard SAN /
#               empty-SAN (no CN fallback) / IP-only SAN / malformed-truncated
#               PEM) — the §11.4.107(10) self-validated-analyzer discipline: an
#               analyzer that ACCEPTS its golden-bad fixture is a bluff gate.
#               Fully hermetic (no network, no ACME,
#               no container boot); deterministic via a pinned "now" epoch
#               (§11.4.50).
# Usage:        bash tests/letsencrypt/cert_analyzer_selftest.sh
# Output:       TAP (Test Anything Protocol) on stdout + a copy under
#               qa-results/letsencrypt/cert-analyzer/<run-id>/selftest.tap.
#               Exit 0 iff ALL assertions pass (zero failures).
# Dependencies: bash (or any POSIX sh — body is POSIX-clean), openssl,
#               GNU `date -d`, awk/sed/tr. Fixtures self-bootstrap via
#               gen_fixtures.sh when absent (§11.4.77).
# Cross-refs:   Constitution §11.4.107(10) / §11.4.50 / §11.4.69 / §1.1;
#               design LETSENCRYPT_HTTPS.md §6 (unit row) +
#               LETSENCRYPT_HTTPS_PLAN.md Phase 3.
# Shell:        POSIX-clean body (no arrays / [[ ]] / <<<) — parses under sh -n.
# =============================================================================

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
LIB="$SCRIPT_DIR/cert_analyzer.sh"
FIX="$SCRIPT_DIR/fixtures"
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)

RUN_ID=$(date -u +%Y%m%dT%H%M%SZ)
QA_DIR="$REPO_ROOT/qa-results/letsencrypt/cert-analyzer/$RUN_ID"
mkdir -p "$QA_DIR"
TAP_OUT="$QA_DIR/selftest.tap"

# Bootstrap the golden fixtures if the tracked *.pem set is missing (§11.4.77).
if [ ! -s "$FIX/good_leaf.pem" ]; then
    sh "$FIX/gen_fixtures.sh" >/dev/null 2>&1 || true
fi

# Source the library under test.
# shellcheck source=/dev/null
. "$LIB"

# Pinned reference "now" — 2026-07-01T12:00:00Z. Deterministic (fixed date
# string -> fixed epoch), matching the FIXED validity windows baked into the
# fixtures by gen_fixtures.sh (§11.4.50).
NOW=$(date -u -d '2026-07-01T12:00:00Z' +%s)
# A "now" AFTER good_leaf's NotAfter (2026-08-30) — proves the SAME good fixture
# is testable as EXPIRED via the seam, with no time-travel.
NOW_LATER=$(date -u -d '2026-09-15T00:00:00Z' +%s)
# A "now" BEFORE good_leaf's NotBefore (2026-06-01) — not-yet-valid case.
NOW_EARLIER=$(date -u -d '2026-05-01T00:00:00Z' +%s)
# Exact validity-window boundaries of good_leaf (NotBefore 2026-06-01T00:00:00Z,
# NotAfter 2026-08-30T00:00:00Z). The contract is NotBefore <= now < NotAfter:
# the lower bound is INCLUSIVE, the upper bound is EXCLUSIVE. These pin the
# exact boundary semantics with NO new fixture (§11.4.50 now-seam).
NOW_NB=$(date -u -d '2026-06-01T00:00:00Z' +%s)          # == NotBefore
NOW_NA=$(date -u -d '2026-08-30T00:00:00Z' +%s)          # == NotAfter
NOW_NA_MINUS1=$((NOW_NA - 1))                            # one second before NotAfter

TESTS=0
FAILS=0

# run_case <expected-rc> <desc> -- <command...>
# Runs the command, captures its return code, emits a TAP line. PASS iff
# rc == expected.
run_case() {
    exp=$1
    desc=$2
    shift 2
    out=$("$@" 2>&1)
    rc=$?
    TESTS=$((TESTS + 1))
    if [ "$rc" = "$exp" ]; then
        printf 'ok %d - %s (rc=%d)\n' "$TESTS" "$desc" "$rc"
    else
        printf 'not ok %d - %s (got rc=%d, want %s)\n' "$TESTS" "$desc" "$rc" "$exp"
        printf '# verdict: %s\n' "$out"
        FAILS=$((FAILS + 1))
    fi
}

# neg <command...> — returns 0 iff <command> returns NON-zero. Used for the
# golden-bad / "property must be REJECTED" cases where the exact non-zero code
# (1 from our contract vs 2 from openssl verify) is not part of the contract —
# the contract is "0 iff the property holds; non-zero otherwise".
neg() {
    if "$@"; then return 1; else return 0; fi
}

# check_value <expected> <desc> <actual> — value-equality assertion (scalar).
check_value() {
    exp=$1
    desc=$2
    got=$3
    TESTS=$((TESTS + 1))
    if [ "$got" = "$exp" ]; then
        printf 'ok %d - %s (=%s)\n' "$TESTS" "$desc" "$got"
    else
        printf 'not ok %d - %s (got "%s", want "%s")\n' "$TESTS" "$desc" "$got" "$exp"
        FAILS=$((FAILS + 1))
    fi
}

# All output is tee'd to the TAP artefact.
{
printf '# cert_analyzer.sh self-test — run-id %s\n' "$RUN_ID"
printf '# pinned now=%s (2026-07-01T12:00:00Z) — hermetic, deterministic (§11.4.50)\n' "$NOW"

# --- Layer 0: parseability gates (§11.4.67) --------------------------------
run_case 0 "cert_analyzer.sh parses under sh -n"   sh -n "$LIB"
run_case 0 "cert_analyzer.sh parses under bash -n" bash -n "$LIB"
run_case 0 "gen_fixtures.sh parses under sh -n"    sh -n "$FIX/gen_fixtures.sh"

# --- Fixture presence (the golden corpus must exist) -----------------------
for _fx in test_ca good_leaf expired_leaf nearexpiry_leaf wrongca_leaf otherhost_leaf wildcard_leaf \
           doublewild_leaf nosan_leaf ipsan_leaf dnsandip_leaf malformed_leaf; do
    run_case 0 "fixture present: $_fx.pem" test -s "$FIX/$_fx.pem"
done

# ===========================================================================
# §11.4.107(10) SELF-VALIDATION: golden-GOOD accepted, golden-BAD REJECTED.
# ===========================================================================

# --- cert_not_expired -------------------------------------------------------
run_case 0 "not_expired: good leaf inside window @now -> valid (golden-good)" \
    cert_not_expired "$FIX/good_leaf.pem" "$NOW"
run_case 0 "not_expired: near-expiry leaf still inside window @now -> valid" \
    cert_not_expired "$FIX/nearexpiry_leaf.pem" "$NOW"
run_case 0 "not_expired: SAME good leaf @NOW+ (past NotAfter) -> EXPIRED (seam, no time-travel §11.4.50)" \
    neg cert_not_expired "$FIX/good_leaf.pem" "$NOW_LATER"
run_case 0 "not_expired: good leaf @NOW- (before NotBefore) -> NOT-YET-VALID (rejected)" \
    neg cert_not_expired "$FIX/good_leaf.pem" "$NOW_EARLIER"
run_case 0 "not_expired: expired leaf @now -> EXPIRED (golden-bad rejected)" \
    neg cert_not_expired "$FIX/expired_leaf.pem" "$NOW"
run_case 2 "not_expired: unparseable/absent pem -> rc 2 (§11.4.1 no false-PASS)" \
    cert_not_expired "$FIX/does_not_exist.pem" "$NOW"
# Exact validity-window boundaries (NotBefore inclusive, NotAfter exclusive).
run_case 0 "not_expired: good leaf @now==NotBefore -> valid (lower bound INCLUSIVE, boundary)" \
    cert_not_expired "$FIX/good_leaf.pem" "$NOW_NB"
run_case 0 "not_expired: good leaf @now==NotAfter -> EXPIRED-just-now (upper bound EXCLUSIVE, golden-bad boundary)" \
    neg cert_not_expired "$FIX/good_leaf.pem" "$NOW_NA"
run_case 0 "not_expired: good leaf @now==NotAfter-1s -> still valid (last valid second, boundary)" \
    cert_not_expired "$FIX/good_leaf.pem" "$NOW_NA_MINUS1"
# Malformed/truncated-but-PRESENT PEM (distinct from an absent file): every
# parse-dependent function MUST reject it, never a false-PASS (§11.4.1).
run_case 2 "not_expired: malformed/truncated PEM (present, unparseable) -> rc 2 (golden-bad)" \
    cert_not_expired "$FIX/malformed_leaf.pem" "$NOW"

# --- cert_days_remaining (deterministic scalar) ----------------------------
check_value 59   "days_remaining: good leaf @now -> 59" \
    "$(cert_days_remaining "$FIX/good_leaf.pem" "$NOW")"
check_value 4    "days_remaining: near-expiry leaf @now -> 4" \
    "$(cert_days_remaining "$FIX/nearexpiry_leaf.pem" "$NOW")"
check_value -122 "days_remaining: expired leaf @now -> -122 (negative, already past)" \
    "$(cert_days_remaining "$FIX/expired_leaf.pem" "$NOW")"
run_case 2 "days_remaining: malformed/truncated PEM -> rc 2, no scalar emitted (golden-bad)" \
    cert_days_remaining "$FIX/malformed_leaf.pem" "$NOW"

# --- cert_san_matches (exact + single-wildcard; NEVER a substring) ---------
run_case 0 "san_matches: good leaf SAN covers exact host proxy.test (golden-good)" \
    cert_san_matches "$FIX/good_leaf.pem" proxy.test
run_case 0 "san_matches: other-host leaf does NOT cover proxy.test (golden-bad rejected)" \
    neg cert_san_matches "$FIX/otherhost_leaf.pem" proxy.test
run_case 0 "san_matches: SUBSTRING 'oxy.test' does NOT match proxy.test (no naive substring)" \
    neg cert_san_matches "$FIX/good_leaf.pem" oxy.test
run_case 0 "san_matches: SUPERSTRING 'proxy.test.evil' does NOT match proxy.test" \
    neg cert_san_matches "$FIX/good_leaf.pem" proxy.test.evil
run_case 2 "san_matches: empty hostname -> rc 2 (no false-PASS)" \
    cert_san_matches "$FIX/good_leaf.pem" ""
run_case 0 "san_matches: wildcard *.proxy.test COVERS a.proxy.test (one left label)" \
    cert_san_matches "$FIX/wildcard_leaf.pem" a.proxy.test
run_case 0 "san_matches: wildcard *.proxy.test does NOT cover apex proxy.test" \
    neg cert_san_matches "$FIX/wildcard_leaf.pem" proxy.test
run_case 0 "san_matches: wildcard *.proxy.test does NOT cover a.b.proxy.test (two labels)" \
    neg cert_san_matches "$FIX/wildcard_leaf.pem" a.b.proxy.test
# Malformed double-wildcard SAN (*.*.proxy.test) must NOT match any real host.
run_case 0 "san_matches: double-wildcard *.*.proxy.test does NOT match a.proxy.test (golden-bad)" \
    neg cert_san_matches "$FIX/doublewild_leaf.pem" a.proxy.test
run_case 0 "san_matches: double-wildcard *.*.proxy.test does NOT match a.b.proxy.test (golden-bad)" \
    neg cert_san_matches "$FIX/doublewild_leaf.pem" a.b.proxy.test
# Empty-SAN cert: CN=proxy.test but NO subjectAltName — must NOT match (no CN
# fallback), yet it IS a valid cert issued by test_ca (proves the reject is due
# to the empty SAN, not a broken cert).
run_case 0 "san_matches: empty-SAN cert (CN only) does NOT match proxy.test — no CN fallback (golden-bad)" \
    neg cert_san_matches "$FIX/nosan_leaf.pem" proxy.test
run_case 0 "san_matches: empty-SAN cert is nonetheless a valid cert issued by test_ca (control)" \
    cert_chain_roots_in "$FIX/nosan_leaf.pem" "$FIX/test_ca.pem"
# IP-only SAN: cert_san_matches is dNSName-only — neither the IP literal nor any
# DNS name matches an iPAddress-only SAN.
run_case 0 "san_matches: IP-only SAN does NOT match the IP literal 10.0.0.1 (DNS-only discipline, golden-bad)" \
    neg cert_san_matches "$FIX/ipsan_leaf.pem" 10.0.0.1
run_case 0 "san_matches: IP-only SAN does NOT match a DNS name proxy.test (golden-bad)" \
    neg cert_san_matches "$FIX/ipsan_leaf.pem" proxy.test
# Mixed DNS+IP SAN: the dNSName is isolated from the iPAddress — proxy.test
# STILL matches (golden-good — the IP does not corrupt DNS extraction).
run_case 0 "san_matches: mixed DNS+IP SAN still matches DNS host proxy.test (golden-good)" \
    cert_san_matches "$FIX/dnsandip_leaf.pem" proxy.test

# --- cert_chain_roots_in (issued-by-EXPECTED-CA; validity-independent) ------
run_case 0 "chain_roots_in: good leaf roots in test_ca (golden-good — issued by it)" \
    cert_chain_roots_in "$FIX/good_leaf.pem" "$FIX/test_ca.pem"
run_case 0 "chain_roots_in: expired leaf STILL roots in test_ca (issuance is time-independent)" \
    cert_chain_roots_in "$FIX/expired_leaf.pem" "$FIX/test_ca.pem"
run_case 0 "chain_roots_in: wrong-CA leaf does NOT root in test_ca (golden-bad rejected)" \
    neg cert_chain_roots_in "$FIX/wrongca_leaf.pem" "$FIX/test_ca.pem"
run_case 2 "chain_roots_in: absent leaf/ca file -> rc 2 (no false-PASS)" \
    cert_chain_roots_in "$FIX/does_not_exist.pem" "$FIX/test_ca.pem"
run_case 0 "chain_roots_in: malformed/truncated leaf does NOT verify to test_ca -> rejected (golden-bad)" \
    neg cert_chain_roots_in "$FIX/malformed_leaf.pem" "$FIX/test_ca.pem"

# --- cert_renewal_due (threshold trigger) ----------------------------------
run_case 0 "renewal_due: near-expiry (4d) <= 30d threshold -> DUE @now" \
    cert_renewal_due "$FIX/nearexpiry_leaf.pem" 30 "$NOW"
run_case 0 "renewal_due: expired (negative days) -> DUE @now" \
    cert_renewal_due "$FIX/expired_leaf.pem" 30 "$NOW"
run_case 0 "renewal_due: good (59d) > 30d threshold -> NOT due @now (rejected)" \
    neg cert_renewal_due "$FIX/good_leaf.pem" 30 "$NOW"
run_case 0 "renewal_due: near-expiry (4d) > 3d threshold -> NOT due @now (boundary)" \
    neg cert_renewal_due "$FIX/nearexpiry_leaf.pem" 3 "$NOW"

# --- env seam (CERT_ANALYZER_NOW_EPOCH) precedence -------------------------
# The SAME good leaf is valid under a mid-window env-now and expired under a
# past-NotAfter env-now — proving the §11.4.50 per-run seam works without a
# positional arg.
export CERT_ANALYZER_NOW_EPOCH="$NOW"
run_case 0 "env-seam: good leaf valid under CERT_ANALYZER_NOW_EPOCH=now" \
    cert_not_expired "$FIX/good_leaf.pem"
export CERT_ANALYZER_NOW_EPOCH="$NOW_LATER"
run_case 0 "env-seam: SAME good leaf EXPIRED under CERT_ANALYZER_NOW_EPOCH=now+ (rejected)" \
    neg cert_not_expired "$FIX/good_leaf.pem"
unset CERT_ANALYZER_NOW_EPOCH

# --- TAP plan + summary -----------------------------------------------------
printf '1..%d\n' "$TESTS"
printf '# tests=%d passed=%d failed=%d\n' "$TESTS" "$((TESTS - FAILS))" "$FAILS"
if [ "$FAILS" -eq 0 ]; then
    printf '# RESULT: ALL PASS — analyzer accepts every golden-GOOD property AND rejects every golden-BAD (§11.4.107(10))\n'
else
    printf '# RESULT: FAILURES PRESENT (%d) — a golden-bad slipped through OR a golden-good was wrongly rejected\n' "$FAILS"
fi
} | tee "$TAP_OUT"

# Re-derive failure from the artefact (the tee'd pipeline ran in a subshell).
if grep -q '^not ok ' "$TAP_OUT"; then
    printf '\nSelf-test artefact: %s\n' "$TAP_OUT" >&2
    exit 1
fi
printf '\nSelf-test artefact: %s\n' "$TAP_OUT" >&2
exit 0
