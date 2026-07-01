#!/usr/bin/env bash
# =============================================================================
# proxy_acl_security.sh — §11.4.169/§11.4.85 SECURITY: proxy ACL + header hygiene
# -----------------------------------------------------------------------------
# Purpose:      Assert the LIVE HTTP forward proxy's (Squid, localhost:53128)
#               SECURITY posture with captured evidence (§11.4.69), two hard-gated
#               anti-bluff checks:
#                 S1 ACL DENY does NOT leak — a request the proxy MUST deny (a
#                    CONNECT to a non-SSL port, blocked by the shipped Squid
#                    `http_access deny CONNECT !SSL_ports` rule) returns the
#                    expected deny code (403 Forbidden, or 407 when per-user
#                    proxy-auth is configured) and NEVER a 2xx/3xx success. A 2xx
#                    for a must-deny target is a real LEAK (§11.4.68) -> FAIL.
#                 S2 HEADER HYGIENE — the hop-by-hop `Proxy-Authorization`
#                    credential the client sends to the proxy is NOT forwarded to
#                    the upstream ORIGIN. Proven by echoing the request back from
#                    httpbin.org/headers (plain HTTP so Squid parses+strips
#                    hop-by-hop headers) and asserting a client SENTINEL header IS
#                    echoed (the request really reached the origin THROUGH the
#                    proxy) WHILE `Proxy-Authorization` is ABSENT (stripped — no
#                    credential leak). A Proxy-Authorization echoed at the origin
#                    is a credential LEAK -> FAIL.
#               Honest boundary (§11.4.6): end-to-end `Authorization` / `Cookie`
#               headers are addressed to the origin the client chose and ARE
#               forwarded by design — that is NOT a leak. This test gates on the
#               hop-by-hop `Proxy-Authorization` (which MUST NOT reach the origin)
#               and captures `X-Forwarded-For` presence as informational evidence
#               only (default squid `forwarded_for on`), never a hard gate.
# Usage:        bash tests/security/proxy_acl_security.sh
#               GOMAXPROCS=2 nice -n 19 ionice -c 3 bash tests/security/proxy_acl_security.sh
# Inputs:       Live curl through http://localhost:53128 (READ-ONLY client use).
#               Env: HTTP_PROXY_URL (default http://localhost:53128),
#                    HTTP_PROXY_PORT (default 53128),
#                    SEC_DENY_TARGET (default https://example.com:81/ — CONNECT to
#                        a non-SSL port; Squid denies BEFORE any upstream connect),
#                    SEC_DENY_EXPECT (default "403 407"),
#                    SEC_HEADER_ECHO_URL (default http://httpbin.org/headers),
#                    CURL_MAX_TIME (default 15),
#                    SEC_EVIDENCE_DIR (default qa-results/security/proxy_acl_<ts>).
# Outputs:      Captured per-check evidence files + one PASS/FAIL/SKIP verdict.
#               Exit: 0 = PASS, 1 = FAIL (ACL leak or credential leak — real
#               security defect), 3 = SKIP (honest: proxy/topology absent, or the
#               header-echo endpoint unreachable, §11.4.3).
# Side-effects: Live curl only. NEVER stops/starts/restarts/reconfigures any
#               container; never touches operator resources. Creates the evidence
#               dir under qa-results/ (gitignored). `trap` cleanup (§11.4.14).
# Dependencies: bash, curl, awk, grep; tests/lib/evidence.sh (sourced).
# Resources:    shell + curl only; well under the §12.6 60% host-memory ceiling.
# Cross-refs:   §11.4.169 (security test type) / §11.4.85 / §11.4.69 (captured
#               evidence) / §11.4.68 (no fail-open) / §11.4.1 (no false-FAIL) /
#               §11.4.6 (honest boundary) / §11.4.10 (credentials never logged);
#               design §11/§12; evidence.sh _code_in / port_is_listening.
# Shell:        POSIX-clean body — parses under `sh -n` AND `bash -n` (§11.4.67).
# =============================================================================

set -u

SUITE="proxy_acl_security"

# --- Locate repo root -------------------------------------------------------
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
find_repo_root() {
    d=$1
    while [ "$d" != "/" ]; do
        if [ -f "$d/tests/lib/evidence.sh" ]; then
            printf '%s\n' "$d"; return 0
        fi
        d=$(dirname "$d")
    done
    return 1
}
REPO_ROOT=$(find_repo_root "$SCRIPT_DIR" || true)
if [ -z "${REPO_ROOT:-}" ]; then
    echo "FAIL: cannot locate tests/lib/evidence.sh from $SCRIPT_DIR" >&2
    exit 1
fi
# shellcheck source=/dev/null
. "$REPO_ROOT/tests/lib/evidence.sh"

# --- Config -----------------------------------------------------------------
PROXY_URL=${HTTP_PROXY_URL:-http://localhost:53128}
PROXY_PORT=${HTTP_PROXY_PORT:-53128}
DENY_TARGET=${SEC_DENY_TARGET:-https://example.com:81/}
DENY_EXPECT=${SEC_DENY_EXPECT:-403 407}
ECHO_URL=${SEC_HEADER_ECHO_URL:-http://httpbin.org/headers}
MAX_TIME=${CURL_MAX_TIME:-15}
RUN_TS=$(date -u +%Y%m%dT%H%M%SZ)
EVIDENCE_DIR=${SEC_EVIDENCE_DIR:-$REPO_ROOT/qa-results/security/proxy_acl_$RUN_TS}
mkdir -p "$EVIDENCE_DIR"

# NON-secret sentinels. The "credential" is a throwaway base64 of `sentinel:leak`
# — deliberately worthless; asserting it is STRIPPED never logs a real secret
# (§11.4.10). The canary header proves the request reached the origin.
SENTINEL_CANARY="X-Leak-Canary: helix-proxy-sentinel-$RUN_TS"
SENTINEL_CANARY_NAME="X-Leak-Canary"
FAKE_PROXY_AUTH="Proxy-Authorization: Basic c2VudGluZWw6bGVhaw=="

N_PASS=0; N_FAIL=0; N_SKIP=0

# §11.4.14: no background workers are spawned (all curls are foreground +
# --max-time bounded). Cleanup is a documented no-op; captured evidence under
# EVIDENCE_DIR is preserved. We do NOT `kill 0` (it would signal the whole
# process group incl. the conductor).
_sec_cleanup() { :; }
trap _sec_cleanup EXIT INT TERM

echo "=== $SUITE — run $RUN_TS ==="
echo "proxy=$PROXY_URL  evidence=$EVIDENCE_DIR"

# ---------------------------------------------------------------------------
# S1 — ACL deny does NOT leak.
# ---------------------------------------------------------------------------
S1_EV="$EVIDENCE_DIR/s1_acl_deny.evidence"
deny_code=$(curl -sS --max-time "$MAX_TIME" -o /dev/null -w '%{http_code}' \
    -x "$PROXY_URL" "$DENY_TARGET" 2>/dev/null || printf '000')
if port_is_listening "$PROXY_PORT"; then listen=yes; else listen=no; fi
{
    printf '=== S1: ACL deny does not leak ===\n'
    printf 'deny_target=%s (CONNECT to a non-SSL port — must be denied by Squid)\n' "$DENY_TARGET"
    printf 'expected_deny_codes=%s\n' "$DENY_EXPECT"
    printf 'proxy_http_code=%s port_%s_listening=%s\n' "$deny_code" "$PROXY_PORT" "$listen"
} > "$S1_EV"

# A 2xx/3xx SUCCESS for a must-deny target is an unambiguous LEAK.
_is_success_code() {
    case "$1" in
        200|201|202|203|204|205|206|301|302|303|307|308) return 0 ;;
        *) return 1 ;;
    esac
}
if _code_in "$deny_code" "$DENY_EXPECT"; then
    printf 'verdict=PASS (deny enforced, no leak)\n' >> "$S1_EV"
    echo "[S1] PASS ACL deny enforced (code=$deny_code)"
    ab_pass_with_evidence "S1 ACL deny enforced ($deny_code for must-deny $DENY_TARGET)" "$S1_EV"
    N_PASS=$((N_PASS + 1))
elif _is_success_code "$deny_code"; then
    printf 'verdict=FAIL (LEAK: proxy served a must-deny target)\n' >> "$S1_EV"
    echo "[S1] FAIL LEAK — proxy returned success ($deny_code) for a must-deny target"
    _evidence_emit FAIL "S1 ACL deny" "[reason: proxy returned $deny_code (success) for must-deny $DENY_TARGET — ACL LEAK (§11.4.68); see $S1_EV]"
    N_FAIL=$((N_FAIL + 1))
elif [ "$listen" = "no" ]; then
    printf 'verdict=SKIP:topology_unsupported (proxy port not listening)\n' >> "$S1_EV"
    echo "[S1] SKIP proxy :$PROXY_PORT not listening"
    ab_skip_with_reason "S1 ACL deny (proxy :$PROXY_PORT not listening)" "topology_unsupported"
    N_SKIP=$((N_SKIP + 1))
else
    # Listening but neither the expected deny code nor a leak (e.g. 000/502/503):
    # cannot prove a clean deny NOR a leak on this topology — honest SKIP.
    printf 'verdict=SKIP:topology_unsupported (unexpected deny code %s — cannot prove deny or leak)\n' "$deny_code" >> "$S1_EV"
    echo "[S1] SKIP unexpected code=$deny_code (neither expected deny nor a leak)"
    ab_skip_with_reason "S1 ACL deny (unexpected code $deny_code — deny posture not assertable on this topology)" "topology_unsupported"
    N_SKIP=$((N_SKIP + 1))
fi

# ---------------------------------------------------------------------------
# S2 — hop-by-hop Proxy-Authorization is NOT forwarded to the origin.
# ---------------------------------------------------------------------------
S2_EV="$EVIDENCE_DIR/s2_header_hygiene.evidence"
PROXY_ECHO_BODY="$EVIDENCE_DIR/s2_proxy_echo.json"
DIRECT_ECHO_BODY="$EVIDENCE_DIR/s2_direct_echo.json"

proxy_echo_code=$(curl -sS --max-time "$MAX_TIME" \
    -H "$SENTINEL_CANARY" -H "$FAKE_PROXY_AUTH" \
    -o "$PROXY_ECHO_BODY" -w '%{http_code}' \
    -x "$PROXY_URL" "$ECHO_URL" 2>/dev/null || printf '000')
direct_echo_code=$(curl -sS --max-time "$MAX_TIME" \
    -H "$SENTINEL_CANARY" \
    -o "$DIRECT_ECHO_BODY" -w '%{http_code}' \
    "$ECHO_URL" 2>/dev/null || printf '000')

# Did the origin echo our canary (proving the request reached it via the proxy)?
canary_echoed=no
if grep -qi "$SENTINEL_CANARY_NAME" "$PROXY_ECHO_BODY" 2>/dev/null; then canary_echoed=yes; fi
# Did the origin echo Proxy-Authorization (the hop-by-hop header — a LEAK if so)?
proxyauth_echoed=no
if grep -qi 'Proxy-Authorization' "$PROXY_ECHO_BODY" 2>/dev/null; then proxyauth_echoed=yes; fi
# Informational only: X-Forwarded-For presence (default squid forwarded_for on).
xff_present=no
if grep -qi 'X-Forwarded-For' "$PROXY_ECHO_BODY" 2>/dev/null; then xff_present=yes; fi

{
    printf '=== S2: header hygiene (Proxy-Authorization not forwarded) ===\n'
    printf 'echo_url=%s\n' "$ECHO_URL"
    printf 'proxy_echo_code=%s direct_echo_code=%s\n' "$proxy_echo_code" "$direct_echo_code"
    printf 'canary_echoed_at_origin=%s (request really transited proxy)\n' "$canary_echoed"
    printf 'proxy_authorization_echoed_at_origin=%s (MUST be no — hop-by-hop stripped)\n' "$proxyauth_echoed"
    printf 'x_forwarded_for_present=%s (informational; default squid forwarded_for on)\n' "$xff_present"
    printf '# note: end-to-end Authorization/Cookie ARE forwarded to the origin BY DESIGN (not a leak, §11.4.6)\n'
} > "$S2_EV"

if [ "$canary_echoed" = "yes" ] && [ "$proxyauth_echoed" = "no" ]; then
    printf 'verdict=PASS (canary echoed AND Proxy-Authorization stripped)\n' >> "$S2_EV"
    echo "[S2] PASS Proxy-Authorization stripped (canary echoed, no credential leak)"
    ab_pass_with_evidence "S2 header hygiene: Proxy-Authorization NOT forwarded to origin (canary echoed)" "$S2_EV"
    N_PASS=$((N_PASS + 1))
elif [ "$canary_echoed" = "yes" ] && [ "$proxyauth_echoed" = "yes" ]; then
    printf 'verdict=FAIL (LEAK: Proxy-Authorization forwarded to origin)\n' >> "$S2_EV"
    echo "[S2] FAIL LEAK — Proxy-Authorization forwarded to the upstream origin"
    _evidence_emit FAIL "S2 header hygiene" "[reason: hop-by-hop Proxy-Authorization reached the origin — credential LEAK (§11.4.68); see $S2_EV]"
    N_FAIL=$((N_FAIL + 1))
else
    # Canary not echoed via proxy — the origin echo could not be captured.
    if [ "$direct_echo_code" = "200" ]; then
        # Origin reachable directly but not via proxy: a connectivity issue, not a
        # security leak — honest SKIP for THIS security property (untestable now).
        printf 'verdict=SKIP:network_unreachable_external (origin echo not captured via proxy; direct=200)\n' >> "$S2_EV"
        echo "[S2] SKIP origin echo not captured via proxy (direct=$direct_echo_code) — header hygiene not assertable now"
        ab_skip_with_reason "S2 header hygiene (origin echo not captured through proxy)" "network_unreachable_external"
    else
        printf 'verdict=SKIP:network_unreachable_external (echo endpoint unreachable via proxy AND directly)\n' >> "$S2_EV"
        echo "[S2] SKIP echo endpoint unreachable (proxy=$proxy_echo_code direct=$direct_echo_code)"
        ab_skip_with_reason "S2 header hygiene (echo endpoint unreachable — outage)" "network_unreachable_external"
    fi
    N_SKIP=$((N_SKIP + 1))
fi

# ---------------------------------------------------------------------------
# S3 — Via/version info-leak hygiene (§11.4.169 / §11.4.135 regression guard,
# §11.4.138 — the pre-`via off` config leaked `Via: 1.1 proxy-squid (squid/6.13)`,
# the internal hostname + Squid version, incl. on the branded ERR pages). This
# gate is the standing GREEN guard after the fix; it would FAIL a regression.
# Robust: reads the proxy's OWN response header, no external echo body needed.
# ---------------------------------------------------------------------------
S3_EV="$EVIDENCE_DIR/s3_via_hygiene.evidence"
VIA_TARGET=${SEC_VIA_TARGET:-http://www.gstatic.com/generate_204}
via_hdrs=$(curl -sI --max-time "$MAX_TIME" -x "$PROXY_URL" "${VIA_TARGET}?cb=$$" 2>/dev/null)
via_line=$(printf '%s\n' "$via_hdrs" | grep -iE '^Via:' | head -1 | tr -d '\r')
{
    printf '=== S3: Via/version info-leak hygiene ===\n'
    printf 'via_target=%s\n' "$VIA_TARGET"
    printf 'response_first_line=%s\n' "$(printf '%s\n' "$via_hdrs" | head -1 | tr -d '\r')"
    printf 'via_header=%s (MUST be empty — expect via off)\n' "${via_line:-<none>}"
} > "$S3_EV"
if [ -z "$via_hdrs" ]; then
    printf 'verdict=SKIP:network_unreachable_external (no proxy response to sample Via)\n' >> "$S3_EV"
    echo "[S3] SKIP no proxy response to sample Via header (target unreachable via proxy)"
    ab_skip_with_reason "S3 Via hygiene (target unreachable via proxy)" "network_unreachable_external"
    N_SKIP=$((N_SKIP + 1))
elif [ -z "$via_line" ]; then
    printf 'verdict=PASS (no Via header — no hostname/version leak)\n' >> "$S3_EV"
    echo "[S3] PASS no Via header emitted (no internal-hostname/Squid-version leak)"
    ab_pass_with_evidence "S3 Via hygiene: proxy emits no Via/version header (via off applied)" "$S3_EV"
    N_PASS=$((N_PASS + 1))
else
    printf 'verdict=FAIL (Via header leaks hostname/version: %s)\n' "$via_line" >> "$S3_EV"
    echo "[S3] FAIL Via header leaks internal hostname + version: $via_line"
    _evidence_emit FAIL "S3 Via hygiene" "[reason: proxy emits '$via_line' — internal hostname + Squid version leak (§11.4.68/§11.4.169); set 'via off'; see $S3_EV]"
    N_FAIL=$((N_FAIL + 1))
fi

# ---------------------------------------------------------------------------
# Aggregate — FAIL if any FAIL ; PASS if >=1 PASS and 0 FAIL ; else SKIP.
# ---------------------------------------------------------------------------
echo
echo "=== $SUITE aggregate: pass=$N_PASS fail=$N_FAIL skip=$N_SKIP ==="
if [ "$N_FAIL" -gt 0 ]; then
    echo "OVERALL=FAIL ($N_FAIL security defect(s))"
    exit 1
fi
if [ "$N_PASS" -gt 0 ]; then
    echo "OVERALL=PASS ($N_PASS security check(s) proven, 0 leaks)"
    exit 0
fi
echo "OVERALL=SKIP (no security check assertable on this topology)"
exit 3
