#!/bin/sh
#######################################################################
# §11.4.135 regression guard — cert_analyzer self-validation (LE Phase 3).
#
# Purpose:
#   Prove `tests/letsencrypt/cert_analyzer.sh` is a SELF-VALIDATED analyzer
#   (§11.4.107(10)): it ACCEPTS every golden-GOOD certificate property AND
#   REJECTS every golden-BAD one (expired / wrong-CA / wrong-host /
#   substring-not-a-match). An analyzer that accepts its golden-bad fixture is
#   a BLUFF GATE — it would report "cert OK" for a broken/wrong cert, the exact
#   §11.4 PASS-bluff at the certificate-validation layer. Hermetic: no network,
#   no ACME, no container boot; deterministic via a pinned "now" (§11.4.50).
#
# What it actually does (drives the REAL analyzer from cert_analyzer.sh):
#   GREEN — sources cert_analyzer.sh + the golden fixtures and asserts the full
#           accept/reject matrix, INCLUDING the golden-bad rejections that make
#           the analyzer trustworthy (expired -> not-valid, wrong-CA -> no root,
#           wrong-host -> no SAN match, substring -> no match).
#   RED   — runs PRE-FIX-style NAIVE analyzers (the two classic bluffs: a
#           "presence-only" checker that skips the expiry gate, and a SAN
#           SUBSTRING matcher) against the golden-bad fixtures and asserts they
#           WRONGLY ACCEPT them — reproducing the bluff the real analyzer closes.
#           A RED that cannot reproduce the bluff is a §11.4.7 finding.
#
# §11.4.115 polarity switch (RED_MODE):
#   RED_MODE=0 (default GREEN guard) — PASS iff the REAL analyzer gives the full
#              correct accept/reject matrix (every golden-bad rejected).
#   RED_MODE=1 (reproduce) — PASS iff the naive pre-fix analyzers ACCEPT a
#              golden-bad (skip-expiry accepts the expired leaf; substring
#              accepts 'oxy.test' against proxy.test) — the bluff reproduced.
#
# Usage:
#   tests/regression/cert_analyzer_selfvalidation_test.sh            # GREEN guard
#   RED_MODE=1 tests/regression/cert_analyzer_selfvalidation_test.sh # reproduce
#
# Inputs:   RED_MODE (env, default 0). No CLI args.
# Outputs:  PASS/FAIL verdict on stdout + evidence under
#           qa-results/regression/cert_analyzer_selfvalidation/. Exit 0=PASS,1=FAIL.
# Dependencies: sh, openssl, GNU date, mktemp (cert_analyzer.sh: awk/sed/tr).
# Cross-references:
#   - Under test: tests/letsencrypt/cert_analyzer.sh (the analyzer).
#   - Golden fixtures + generator: tests/letsencrypt/fixtures/ + gen_fixtures.sh.
#   - Unit self-validation matrix: tests/letsencrypt/cert_analyzer_selftest.sh.
#   - Design: docs/design/LETSENCRYPT_HTTPS.md §6 + LETSENCRYPT_HTTPS_PLAN.md Phase 3.
#   - Companion doc: docs/scripts/cert_analyzer_selfvalidation_test.md.
#######################################################################
set -eu

RED_MODE="${RED_MODE:-0}"
REPO_ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
FIX="$REPO_ROOT/tests/letsencrypt/fixtures"
EVID_DIR="$REPO_ROOT/qa-results/regression/cert_analyzer_selfvalidation"
mkdir -p "$EVID_DIR"
EVID_FILE="$EVID_DIR/cert_analyzer_selfvalidation.$$.txt"

# Bootstrap the golden fixtures if absent (§11.4.77).
if [ ! -s "$FIX/good_leaf.pem" ]; then
    sh "$FIX/gen_fixtures.sh" >/dev/null 2>&1 || true
fi

# Source the REAL analyzer under test (never re-implement it).
# shellcheck source=/dev/null
. "$REPO_ROOT/tests/letsencrypt/cert_analyzer.sh"

# Pinned reference "now" — matches the fixed fixture windows (§11.4.50).
NOW="$(date -u -d '2026-07-01T12:00:00Z' +%s)"

# --- PRE-FIX NAIVE analyzers (the bluffs the real analyzer closes) ----------
# Bluff #1 — "presence-only" validity: treat a cert as good if it merely roots
# in the expected CA, IGNORING the expiry window (§11.4.107 stale/expired bluff).
_naive_valid_ignoring_expiry() {
    cert_chain_roots_in "$1" "$2"   # NO not-expired gate -> accepts expired
}
# Bluff #2 — SAN SUBSTRING match instead of exact/wildcard token match.
_naive_san_substring() {
    _nss_sans=$(openssl x509 -in "$1" -noout -ext subjectAltName 2>/dev/null)
    case "$_nss_sans" in
        *"$2"*) return 0 ;;   # substring present anywhere -> naive accept
        *)      return 1 ;;
    esac
}

verdict=FAIL
exit_code=1

if [ "$RED_MODE" = "1" ]; then
    # Reproduce BOTH bluffs on golden-bad inputs the REAL analyzer rejects.
    b1=FAIL; b2=FAIL
    if _naive_valid_ignoring_expiry "$FIX/expired_leaf.pem" "$FIX/test_ca.pem"; then
        b1=PASS   # naive accepted the EXPIRED leaf -> bluff reproduced
    fi
    if _naive_san_substring "$FIX/good_leaf.pem" "oxy.test"; then
        b2=PASS   # naive accepted the SUBSTRING 'oxy.test' -> bluff reproduced
    fi
    if [ "$b1" = "PASS" ] && [ "$b2" = "PASS" ]; then
        verdict=PASS; exit_code=0
        msg="RED reproduced: naive presence-only analyzer ACCEPTS the expired golden-bad AND naive SAN-substring ACCEPTS 'oxy.test' vs proxy.test — the bluffs the real analyzer closes"
    else
        msg="RED could-not-reproduce: naive bluff did not fire (skip-expiry=$b1 substring=$b2) — finding per §11.4.7"
    fi
else
    ok=yes
    accept() {   # <label> <cmd...> : the REAL analyzer MUST return 0 (accept)
        _lbl=$1; shift
        if "$@"; then :; else ok=no; echo "  MISMATCH(accept): $_lbl -> analyzer REJECTED a golden-good"; fi
    }
    reject() {   # <label> <cmd...> : the REAL analyzer MUST return non-zero (reject)
        _lbl=$1; shift
        if "$@"; then ok=no; echo "  MISMATCH(reject): $_lbl -> analyzer ACCEPTED a golden-bad (BLUFF)"; fi
    }

    # golden-GOOD accepted
    accept "not_expired good"        cert_not_expired    "$FIX/good_leaf.pem" "$NOW"
    accept "san good proxy.test"     cert_san_matches    "$FIX/good_leaf.pem" proxy.test
    accept "chain good in test_ca"   cert_chain_roots_in "$FIX/good_leaf.pem" "$FIX/test_ca.pem"
    accept "renewal near-expiry due" cert_renewal_due    "$FIX/nearexpiry_leaf.pem" 30 "$NOW"

    # golden-BAD rejected (the trust-establishing half)
    reject "not_expired expired"     cert_not_expired    "$FIX/expired_leaf.pem" "$NOW"
    reject "chain wrong-CA in test_ca" cert_chain_roots_in "$FIX/wrongca_leaf.pem" "$FIX/test_ca.pem"
    reject "san other-host proxy.test" cert_san_matches   "$FIX/otherhost_leaf.pem" proxy.test
    reject "san substring oxy.test"  cert_san_matches    "$FIX/good_leaf.pem" oxy.test
    reject "renewal good not-due"    cert_renewal_due    "$FIX/good_leaf.pem" 30 "$NOW"

    if [ "$ok" = "yes" ]; then
        verdict=PASS; exit_code=0
        msg="GREEN: cert_analyzer accepts every golden-GOOD property AND rejects every golden-BAD (expired / wrong-CA / wrong-host / substring / not-due) — self-validated per §11.4.107(10)"
    else
        msg="REGRESSION: a golden-bad was ACCEPTED or a golden-good was REJECTED — the analyzer is a bluff gate"
    fi
fi

{
    echo "cert_analyzer self-validation regression guard — §11.4.107(10)/§11.4.115/§11.4.135"
    echo "timestamp_utc: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "RED_MODE: $RED_MODE"
    echo "pinned_now_epoch: $NOW (2026-07-01T12:00:00Z)"
    echo "verdict: $verdict"
    echo "detail: $msg"
} > "$EVID_FILE"

echo "[$verdict] cert-analyzer-self-validation (RED_MODE=$RED_MODE): $msg"
echo "evidence: $EVID_FILE"
exit "$exit_code"
