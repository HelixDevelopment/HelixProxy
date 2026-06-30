#!/usr/bin/env bash
# =============================================================================
# auth_407_analyzer.sh — signal 6: proxy auth (unauth -> 407 AND creds -> 200)
# -----------------------------------------------------------------------------
# Signal:       zero-trust per-user proxy auth (§11.4.69 permission_grant; design
#               §11 ④ + §12 Squid per-user auth). FRESH oracle — no evidence.sh
#               helper exists for this signal yet.
# Oracle:       BOTH halves are required: an UNAUTHENTICATED request through the
#               proxy must be rejected with HTTP 407 (Proxy Authentication
#               Required) AND a request with VALID credentials must succeed with
#               200. Either half alone is a half-truth; the §11.4.69-class bluff
#               is a 200 WITHOUT credentials (auth not enforced — bypass).
# golden-good:  unauth_http_code=407 AND auth_http_code=200 -> PASS.
# golden-BAD:   unauth_http_code=200 (auth bypassed) -> MUST FAIL.
# Manifest:     key=val text file:
#                 unauth_http_code=407
#                 auth_http_code=200
#               OR two captured %{http_code} files:
#                 auth_407_analyzer.sh analyze <unauth-code-file> <auth-code-file>
# Usage:        auth_407_analyzer.sh analyze <manifest-or-unauth-file> [auth-file]
#               auth_407_analyzer.sh --selftest        (default action)
# Output:       PASS:/FAIL: verdict; rc 0 = PASS, 1 = FAIL.
# Anti-bluff:   asserting ONLY that valid creds yield 200 would green an
#               auth-disabled proxy (every request 200) — the 407-on-unauth half
#               is what proves enforcement (§11.4.6 no-guessing).
# Shell:        POSIX-clean (sh -n + bash -n, §11.4.67).
# Cross-refs:   §11.4.69 / §11.4.107 / §11.4.115; design §11 ④ / §12.
# =============================================================================
_ANZ_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=/dev/null
. "$_ANZ_DIR/../lib/analyzer_common.sh"
_FIX="$_ANZ_DIR/fixtures/auth_407"

_auth_get() {
    awk -F= -v k="$2" '$1 == k { sub(/^[^=]*=/, ""); gsub(/[ \t\r]/,""); print; exit }' "$1" 2>/dev/null
}
_auth_first_token() {
    tr -d '\r' < "$1" 2>/dev/null | awk 'NF { print $1; exit }'
}

# analyze_auth_407 <manifest-or-unauth-code-file> [auth-code-file]
analyze_auth_407() {
    a=$1
    b=${2:-}
    if [ -z "$a" ] || [ ! -f "$a" ]; then
        ac_fail "auth_407" "[reason: probe artefact missing: ${a:-<none>}]"
        return 1
    fi
    if [ -n "$b" ]; then
        # Two-file form: $a = unauth %{http_code}, $b = auth %{http_code}.
        if [ ! -f "$b" ]; then
            ac_fail "auth_407" "[reason: auth-code file missing: $b]"
            return 1
        fi
        unauth=$(_auth_first_token "$a")
        auth=$(_auth_first_token "$b")
        evidence=$a
    else
        # Manifest form.
        unauth=$(_auth_get "$a" unauth_http_code)
        auth=$(_auth_get "$a" auth_http_code)
        evidence=$a
    fi

    if [ "$unauth" != "407" ]; then
        ac_fail "auth_407" "[reason: unauthenticated request returned $unauth, expected 407 — auth NOT enforced (bypass)]"
        return 1
    fi
    if [ "$auth" != "200" ]; then
        ac_fail "auth_407" "[reason: valid-credential request returned $auth, expected 200 — auth rejects good creds]"
        return 1
    fi
    if [ "$AC_EVIDENCE_AVAILABLE" = "1" ]; then
        ab_pass_with_evidence "auth_407 (unauth->407 AND creds->200)" "$evidence"
        return $?
    fi
    ac_pass "auth_407" "[evidence: unauth=407 auth=200 ($evidence)]"
}

_selftest_auth_407() {
    ac_selftest_reset
    printf '# auth_407_analyzer self-test\n'
    ac_expect 0 "golden-good: unauth=407 AND auth=200 -> PASS" \
        -- analyze_auth_407 "$_FIX/golden_good.manifest"
    ac_expect 1 "golden-BAD: unauth=200 (auth bypassed) -> FAIL" \
        -- analyze_auth_407 "$_FIX/golden_bad_bypass.manifest"
    ac_expect 1 "golden-BAD: valid creds rejected (auth=403) -> FAIL" \
        -- analyze_auth_407 "$_FIX/golden_bad_creds_rejected.manifest"
    ac_expect 0 "golden-good: two-file %{http_code} form -> PASS" \
        -- analyze_auth_407 "$_FIX/unauth_407.code" "$_FIX/auth_200.code"
    ac_expect 1 "golden-BAD: two-file form, unauth file = 200 -> FAIL" \
        -- analyze_auth_407 "$_FIX/unauth_200.code" "$_FIX/auth_200.code"
    ac_expect 1 "negative: missing manifest -> FAIL" \
        -- analyze_auth_407 "$_FIX/does_not_exist.manifest"
    ac_selftest_summary "auth_407_analyzer"
}

case "${1:-}" in
    analyze) shift; analyze_auth_407 "$@" ;;
    --selftest|selftest|"") _selftest_auth_407 ;;
    *) analyze_auth_407 "$@" ;;
esac
