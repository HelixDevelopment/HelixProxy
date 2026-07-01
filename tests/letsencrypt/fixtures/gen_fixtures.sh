#!/usr/bin/env bash
# =============================================================================
# gen_fixtures.sh — hermetic openssl generator for cert_analyzer fixtures
# -----------------------------------------------------------------------------
# Purpose:      Regenerate (§11.4.77) the golden-good + golden-bad certificate
#               fixtures that self-validate tests/letsencrypt/cert_analyzer.sh
#               (§11.4.107(10)). Everything here is EPHEMERAL throwaway test
#               material — self-signed TEST CAs, NOT real Let's Encrypt certs,
#               NO production private keys, NO secrets (§11.4.10). The generated
#               *.key / *.csr / *.srl are gitignored (tests/letsencrypt/
#               fixtures/.gitignore); only the public *.pem certs are tracked
#               and regenerated on demand by re-running this script.
# Usage:        GOMAXPROCS=2 nice -n 19 ionice -c 3 \
#                   bash tests/letsencrypt/fixtures/gen_fixtures.sh
#               (run from anywhere; it resolves its own directory).
# Inputs:       none (fully deterministic — FIXED validity windows baked in via
#               openssl -not_before / -not_after so fixtures do NOT depend on
#               the generation date; §11.4.50).
# Outputs:      Under tests/letsencrypt/fixtures/:
#                 test_ca.pem         — self-signed TEST CA (the "expected CA")
#                 good_leaf.pem       — issued by test_ca, CN/SAN proxy.test,
#                                       valid window straddling the ref "now"
#                 expired_leaf.pem    — issued by test_ca, SAN proxy.test,
#                                       NotAfter in the past (expired)
#                 nearexpiry_leaf.pem — issued by test_ca, SAN proxy.test,
#                                       ~5 days left at the ref "now"
#                 wrongca_leaf.pem    — self-signed by a DIFFERENT CA, SAN
#                                       proxy.test (right host, WRONG issuer)
#                 otherhost_leaf.pem  — issued by test_ca, SAN other.test
#                                       (right issuer, WRONG host)
#                 wildcard_leaf.pem   — issued by test_ca, SAN *.proxy.test
#                                       (exercises the single-leading-wildcard
#                                       branch of cert_san_matches)
#               plus gitignored *.key / *.csr / *.srl throwaway material.
# Side-effects: writes the files above; no network, no containers.
# Dependencies: POSIX sh, openssl (req -x509 / x509 -req with -not_before /
#               -not_after / -copy_extensions / -no_check_time — OpenSSL 3.2+).
# Cross-refs:   tests/letsencrypt/cert_analyzer.sh (the library under test),
#               tests/letsencrypt/cert_analyzer_selftest.sh (consumes these),
#               design LETSENCRYPT_HTTPS_PLAN.md Phase 3.
# Shell:        POSIX-clean — parses under `sh -n` AND `bash -n` (§11.4.67).
#
# REFERENCE "now" for the analyzer tests is 2026-07-01T12:00:00Z. The fixed
# windows below are chosen relative to that instant so the selftest can pin
# CERT_ANALYZER_NOW_EPOCH deterministically:
#   good        NotBefore 2026-06-01  NotAfter 2026-08-30  (~60 days remain)
#   nearexpiry  NotBefore 2026-04-01  NotAfter 2026-07-06  (~4-5 days remain)
#   expired     NotBefore 2026-01-01  NotAfter 2026-03-01  (already expired)
#   wrongca     NotBefore 2026-06-01  NotAfter 2026-08-30  (valid; wrong issuer)
#   otherhost   NotBefore 2026-06-01  NotAfter 2026-08-30  (valid; wrong host)
# =============================================================================
set -eu

FIX_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
cd "$FIX_DIR"

KEYBITS=2048

# Fixed validity windows (UTC, openssl YYYYMMDDHHMMSSZ form).
CA_NB=20260101000000Z
CA_NA=20270101000000Z
GOOD_NB=20260601000000Z
GOOD_NA=20260830000000Z
NEAR_NB=20260401000000Z
NEAR_NA=20260706000000Z
EXP_NB=20260101000000Z
EXP_NA=20260301000000Z

# _mk_leaf <name> <cn> <san_dns> <not_before> <not_after> <ca_pem> <ca_key>
# Generate a key + CSR (SAN requested in the CSR) then sign it with the given
# CA, copying the SAN into the issued cert. Produces <name>.pem (tracked).
_mk_leaf() {
    _name=$1; _cn=$2; _san=$3; _nb=$4; _na=$5; _ca=$6; _cak=$7
    openssl req -newkey "rsa:$KEYBITS" -sha256 -nodes \
        -keyout "$_name.key" -out "$_name.csr" \
        -subj "/CN=$_cn" \
        -addext "subjectAltName=DNS:$_san" >/dev/null 2>&1
    openssl x509 -req -in "$_name.csr" \
        -CA "$_ca" -CAkey "$_cak" -CAcreateserial \
        -sha256 -not_before "$_nb" -not_after "$_na" \
        -copy_extensions copy \
        -out "$_name.pem" >/dev/null 2>&1
    rm -f "$_name.csr"
}

# --- The expected TEST CA (issuer for the "good" family) --------------------
openssl req -x509 -newkey "rsa:$KEYBITS" -sha256 -nodes \
    -keyout test_ca.key -out test_ca.pem \
    -subj "/CN=Helix Proxy Test CA" \
    -not_before "$CA_NB" -not_after "$CA_NA" \
    -addext "basicConstraints=critical,CA:TRUE" \
    -addext "keyUsage=critical,keyCertSign,cRLSign" >/dev/null 2>&1

# --- A DIFFERENT (wrong) CA — used only to self-sign the wrongca leaf -------
openssl req -x509 -newkey "rsa:$KEYBITS" -sha256 -nodes \
    -keyout wrong_ca.key -out wrong_ca.pem \
    -subj "/CN=Some Other Test CA" \
    -not_before "$GOOD_NB" -not_after "$GOOD_NA" \
    -addext "basicConstraints=critical,CA:TRUE" \
    -addext "keyUsage=critical,keyCertSign,cRLSign" >/dev/null 2>&1

# --- Golden-GOOD: right issuer, right host, valid window --------------------
_mk_leaf good_leaf       proxy.test proxy.test "$GOOD_NB" "$GOOD_NA" test_ca.pem test_ca.key

# --- Golden-BAD (expired): right issuer + host, NotAfter in the past --------
_mk_leaf expired_leaf    proxy.test proxy.test "$EXP_NB"  "$EXP_NA"  test_ca.pem test_ca.key

# --- Golden-BAD (near-expiry): right issuer + host, ~5 days left -------------
_mk_leaf nearexpiry_leaf proxy.test proxy.test "$NEAR_NB" "$NEAR_NA" test_ca.pem test_ca.key

# --- Golden-BAD (wrong host): right issuer, SAN other.test ------------------
_mk_leaf otherhost_leaf  other.test other.test "$GOOD_NB" "$GOOD_NA" test_ca.pem test_ca.key

# --- Golden-BAD (wrong CA): right host + valid window, WRONG issuer ---------
# Signed by wrong_ca (NOT test_ca), so it must NOT verify to test_ca.pem.
_mk_leaf wrongca_leaf    proxy.test proxy.test "$GOOD_NB" "$GOOD_NA" wrong_ca.pem wrong_ca.key

# --- Wildcard: issued by test_ca, SAN *.proxy.test (exercises the wildcard
# branch — matches one extra left label, e.g. a.proxy.test, but NOT the bare
# apex proxy.test and NOT a.b.proxy.test). ----------------------------------
_mk_leaf wildcard_leaf   "*.proxy.test" "*.proxy.test" "$GOOD_NB" "$GOOD_NA" test_ca.pem test_ca.key

# Drop the throwaway serial + the wrong-CA material we no longer need tracked;
# wrong_ca.pem/key stay gitignored (regenerable), test_ca.key stays gitignored.
rm -f test_ca.srl wrong_ca.srl

printf 'gen_fixtures: wrote'
for _f in test_ca good_leaf expired_leaf nearexpiry_leaf otherhost_leaf wrongca_leaf wildcard_leaf; do
    printf ' %s.pem' "$_f"
done
printf '\n'
