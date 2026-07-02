#!/usr/bin/env bash
# =============================================================================
# proxy_acl_security.sh — §11.4.169/§11.4.85 SECURITY: proxy ACL + header hygiene
# -----------------------------------------------------------------------------
# Purpose:      Assert the LIVE HTTP forward proxy's (Squid, localhost:53128)
#               SECURITY posture with captured evidence (§11.4.69), two hard-gated
#               anti-bluff checks:
#                 S1 ACL DENY is enforced + does NOT leak — a CONNECT to a non-SSL
#                    port (blocked by the shipped Squid `http_access deny CONNECT
#                    !SSL_ports` rule) is PROVEN denied by reading Squid's OWN
#                    access.log (via `podman exec`, read-only): a `TCP_DENIED/403
#                    ... CONNECT <target> ... HIER_NONE` line proves BOTH the policy
#                    denial fired AND that no upstream was contacted (HIER_NONE =
#                    no egress = no leak). Client codes are unreliable here (Squid
#                    closes the denied tunnel → curl 000), so the log is the oracle
#                    (§11.4.69). A `TCP_TUNNEL`/`HIER_DIRECT` line for the must-deny
#                    target is a real LEAK (§11.4.68) -> FAIL; log unreadable ->
#                    honest SKIP (§11.4.3), never a fail-open PASS.
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
#                    SEC_DENY_TARGET (default https://example.com:80/ — CONNECT to
#                        non-SSL port 80; Squid denies via deny CONNECT !SSL_ports),
#                    SEC_DENY_HOSTPORT (default example.com:80 — the host:port token
#                        matched in the Squid access.log deny line),
#                    SEC_SQUID_CONTAINER (default proxy-squid — read access.log via
#                        `podman exec`, read-only), SEC_SQUID_LOG (default
#                        /var/log/squid/access.log),
#                    SEC_HEADER_ECHO_URL (default http://httpbin.org/headers),
#                    CURL_MAX_TIME (default 15),
#                    SEC_EVIDENCE_DIR (default qa-results/security/proxy_acl_<ts>).
# Outputs:      Captured per-check evidence files + one PASS/FAIL/SKIP verdict.
#               Exit: 0 = PASS, 1 = FAIL (ACL leak or credential leak — real
#               security defect), 3 = SKIP (honest: proxy/topology absent, or the
#               header-echo endpoint unreachable, §11.4.3).
# Side-effects: Live curl + a READ-ONLY `podman exec proxy-squid` (tail/wc the
#               access.log — never mutates the container). NEVER stops/starts/
#               restarts/reconfigures any container; never touches operator
#               resources. Creates the evidence dir under qa-results/ (gitignored).
#               `trap` cleanup (§11.4.14).
# Dependencies: bash, curl, awk, grep, sed, podman (read-only exec);
#               tests/lib/evidence.sh (sourced).
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
# §11.4.107(10) single source of truth for the honest group verdict — the SAME
# function the §11.4.135 regression guard drives (no divergent copy).
# shellcheck source=/dev/null
. "$REPO_ROOT/tests/lib/acl_group_verdict.sh"

# --- Config -----------------------------------------------------------------
PROXY_URL=${HTTP_PROXY_URL:-http://localhost:53128}
PROXY_PORT=${HTTP_PROXY_PORT:-53128}
DENY_TARGET=${SEC_DENY_TARGET:-https://example.com:80/}
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
# §11.4.120/§11.4.1 honest-aggregate: the group verdict is PASS only when the
# security-CRITICAL checks actually PASSED — S1 (ACL-deny + no-leak) and S4
# (SOCKS5-SSRF block). S2 (Proxy-Authorization strip) + S3 (Via hygiene) are
# non-critical to the group gate (S3 is an info-leak regression guard; run-tests.sh
# surfaces only S1 + S4 as the critical checks). A non-critical PASS while a
# critical check SKIPPED must NOT manufacture a group PASS (that over-claims
# security coverage). These per-critical flags drive the aggregate below.
S1_PASS=0; S4_PASS=0

# §11.4.14: no background workers are spawned (all curls are foreground +
# --max-time bounded). Cleanup is a documented no-op; captured evidence under
# EVIDENCE_DIR is preserved. We do NOT `kill 0` (it would signal the whole
# process group incl. the conductor).
_sec_cleanup() { :; }
trap _sec_cleanup EXIT INT TERM

echo "=== $SUITE — run $RUN_TS ==="
echo "proxy=$PROXY_URL  evidence=$EVIDENCE_DIR"

# ---------------------------------------------------------------------------
# S1 — ACL deny is ENFORCED and does NOT leak (authoritative sink-side, §11.4.69).
#   A CONNECT to a non-SSL port is denied by Squid's shipped
#   `http_access deny CONNECT !SSL_ports`. Client-observed codes are UNRELIABLE
#   here — Squid closes the denied CONNECT tunnel, so curl reports 000 (this is the
#   ambiguity that previously forced an honest SKIP). The verdict therefore reads
#   Squid's OWN access.log via `podman exec` (read-only): a
#   `TCP_DENIED/403 ... CONNECT <target> ... HIER_NONE` line PROVES both the policy
#   denial fired AND that NO upstream was ever contacted (HIER_NONE = no egress =
#   no leak, §11.4.68). A `TCP_TUNNEL`/`HIER_DIRECT` line for the must-deny target
#   is a real LEAK -> FAIL. Log unreadable / proxy absent -> honest SKIP (§11.4.3),
#   NEVER a fail-open PASS.
# ---------------------------------------------------------------------------
S1_EV="$EVIDENCE_DIR/s1_acl_deny.evidence"
SQUID_CTR=${SEC_SQUID_CONTAINER:-proxy-squid}
SQUID_LOG=${SEC_SQUID_LOG:-/var/log/squid/access.log}
DENY_HOSTPORT=${SEC_DENY_HOSTPORT:-example.com:80}
if port_is_listening "$PROXY_PORT"; then listen=yes; else listen=no; fi

# Snapshot the authoritative access.log line count BEFORE the probe (read-only).
log_before=$(podman exec "$SQUID_CTR" sh -c "wc -l < '$SQUID_LOG'" 2>/dev/null || printf '')

# Fire the must-deny CONNECT. The client code is SUPPLEMENTARY only — Squid closes
# the denied tunnel so curl typically reports 000; the access.log is the oracle.
deny_code=$(curl -sS --max-time "$MAX_TIME" -o /dev/null -w '%{http_code}' \
    -x "$PROXY_URL" "$DENY_TARGET" 2>/dev/null || printf '000')

# Classify by the lines THIS probe appended to the authoritative sink.
_hp_re=$(printf '%s' "$DENY_HOSTPORT" | sed 's/\./\\./g')
deny_line=""; leak_line=""
if [ -n "$log_before" ]; then
    appended=$(podman exec "$SQUID_CTR" sh -c "tail -n +$((log_before + 1)) '$SQUID_LOG'" 2>/dev/null || printf '')
    deny_line=$(printf '%s\n' "$appended" | grep -E "CONNECT ${_hp_re} " | grep -E 'TCP_DENIED' | tail -1)
    leak_line=$(printf '%s\n' "$appended" | grep -E "CONNECT ${_hp_re} " | grep -E 'TCP_TUNNEL|HIER_DIRECT' | tail -1)
fi

{
    printf '=== S1: ACL deny enforced + no leak (authoritative access.log) ===\n'
    printf 'deny_target=%s (CONNECT to non-SSL port :%s — must be denied by http_access deny CONNECT !SSL_ports)\n' "$DENY_TARGET" "${DENY_HOSTPORT##*:}"
    printf 'squid_container=%s log=%s port_%s_listening=%s\n' "$SQUID_CTR" "$SQUID_LOG" "$PROXY_PORT" "$listen"
    printf 'client_http_code=%s (supplementary — Squid closes the denied CONNECT tunnel)\n' "$deny_code"
    printf 'authoritative_deny_line=%s\n' "${deny_line:-<none>}"
    printf 'leak_line=%s\n' "${leak_line:-<none>}"
} > "$S1_EV"

if [ "$listen" = "no" ]; then
    printf 'verdict=SKIP:topology_unsupported (proxy port not listening)\n' >> "$S1_EV"
    echo "[S1] SKIP proxy :$PROXY_PORT not listening"
    ab_skip_with_reason "S1 ACL deny (proxy :$PROXY_PORT not listening)" "topology_unsupported"
    N_SKIP=$((N_SKIP + 1))
elif [ -z "$log_before" ]; then
    printf 'verdict=SKIP:topology_unsupported (squid access.log not readable via podman exec %s — no fail-open)\n' "$SQUID_CTR" >> "$S1_EV"
    echo "[S1] SKIP squid access.log unreadable (container $SQUID_CTR) — no fail-open"
    ab_skip_with_reason "S1 ACL deny (access.log unreadable in $SQUID_CTR)" "topology_unsupported"
    N_SKIP=$((N_SKIP + 1))
elif [ -n "$leak_line" ]; then
    printf 'verdict=FAIL (LEAK: must-deny CONNECT forwarded upstream)\n' >> "$S1_EV"
    echo "[S1] FAIL LEAK — proxy forwarded a must-deny CONNECT: $leak_line"
    _evidence_emit FAIL "S1 ACL deny" "[reason: access.log shows must-deny CONNECT $DENY_HOSTPORT forwarded upstream ($leak_line) — ACL LEAK (§11.4.68); see $S1_EV]"
    N_FAIL=$((N_FAIL + 1))
elif [ -n "$deny_line" ]; then
    if printf '%s' "$deny_line" | grep -q 'HIER_NONE'; then
        printf 'verdict=PASS (TCP_DENIED + HIER_NONE = deny enforced, no upstream contacted, no leak)\n' >> "$S1_EV"
        echo "[S1] PASS ACL deny enforced + no leak (TCP_DENIED, HIER_NONE): $deny_line"
        ab_pass_with_evidence "S1 ACL deny enforced + HIER_NONE no-leak for must-deny $DENY_HOSTPORT" "$S1_EV"
        N_PASS=$((N_PASS + 1)); S1_PASS=1
    else
        printf 'verdict=FAIL (denied but hierarchy != HIER_NONE — cannot prove no upstream contact)\n' >> "$S1_EV"
        echo "[S1] FAIL deny line lacks HIER_NONE: $deny_line"
        _evidence_emit FAIL "S1 ACL deny" "[reason: TCP_DENIED but hierarchy != HIER_NONE ($deny_line) — no-leak not provable; see $S1_EV]"
        N_FAIL=$((N_FAIL + 1))
    fi
else
    # Listening + log readable but NO deny line AND no leak line for the target:
    # the must-deny request left no authoritative trace — cannot prove deny; SKIP.
    printf 'verdict=SKIP:topology_unsupported (no access.log deny/leak line for %s — client_code=%s)\n' "$DENY_HOSTPORT" "$deny_code" >> "$S1_EV"
    echo "[S1] SKIP no authoritative access.log line for $DENY_HOSTPORT (client_code=$deny_code)"
    ab_skip_with_reason "S1 ACL deny (no authoritative access.log trace for $DENY_HOSTPORT)" "topology_unsupported"
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
# S4 — SOCKS5 SSRF hardening (§11.4.169 / §11.4.135 guard, §11.4.69 sink-side).
# The SOCKS5 proxy MUST NOT forward a client CONNECT to internal / link-local /
# loopback destinations. RED (pre-`socks block`): dante forwarded the CONNECT.
# GREEN: dante blocks by ruleset → refusal (code 000) AND — the AUTHORITATIVE
# signal — a `block(N) ... <target>` line in dante's OWN log (§11.4.69 positive
# sink-side evidence).  §11.4.107(10)/§11.4.142 review finding: elapsed-time
# alone is a topology-dependent, bluff-capable discriminator — on a host that
# fast-*refuses* link-local (RST / no-route) an UN-blocked dante would forward,
# fail fast, and yield code 000 in < MAX_TIME/2 → a FALSE PASS with the block
# rules removed. So the block-log line is REQUIRED for PASS; a refusal WITHOUT a
# matching block-log line is a FAIL (dante forwarded, did not block); if dante's
# log cannot be read at all we SKIP (topology_unsupported — the sink signal is
# unobtainable, never a timing-only PASS, §11.4.69 no-fail-open). Timing is kept
# as corroborating evidence in the artifact, not as the decision.
# ---------------------------------------------------------------------------
S4_EV="$EVIDENCE_DIR/s4_socks_ssrf.evidence"
SOCKS_URL=${SEC_SOCKS_URL:-socks5h://127.0.0.1:51080}
SSRF_TARGET=${SEC_SSRF_TARGET:-169.254.169.254}
DANTE_CTR=${SEC_DANTE_CONTAINER:-proxy-dante}
DANTE_LOG=${SEC_DANTE_LOG:-/var/log/sockd.log}
socks_ctrl=$(curl -s -o /dev/null -w '%{http_code}' --max-time "$MAX_TIME" -x "$SOCKS_URL" http://www.gstatic.com/generate_204 2>/dev/null || printf '000')
if [ "$socks_ctrl" != "204" ]; then
    printf '=== S4: SOCKS5 SSRF ===\nverdict=SKIP (SOCKS5 control probe=%s, not 204)\n' "$socks_ctrl" > "$S4_EV"
    echo "[S4] SKIP SOCKS5 proxy not serving (control=$socks_ctrl) — SSRF gate not assertable"
    ab_skip_with_reason "S4 SOCKS5 SSRF (proxy :51080 not serving / topology absent)" "topology_unsupported"
    N_SKIP=$((N_SKIP + 1))
else
    # Snapshot dante's own log length BEFORE the probe so we read ONLY the lines
    # this probe appends (avoids matching a block from a prior run). The dante
    # block(N) log line is the AUTHORITATIVE positive sink-side signal (§11.4.69).
    dante_log_avail=no; log_before=0
    if _lb=$(podman exec "$DANTE_CTR" sh -c "wc -l < '$DANTE_LOG'" 2>/dev/null); then
        _lb=$(printf '%s' "$_lb" | tr -dc '0-9')
        [ -n "$_lb" ] && { log_before=$_lb; dante_log_avail=yes; }
    fi
    ssrf_t0=$(date +%s.%N 2>/dev/null || date +%s)
    ssrf_code=$(curl -s -o /dev/null -w '%{http_code}' --max-time "$MAX_TIME" -x "$SOCKS_URL" "http://$SSRF_TARGET/" 2>/dev/null); ssrf_rc=$?
    [ -n "$ssrf_code" ] || ssrf_code=000
    ssrf_t1=$(date +%s.%N 2>/dev/null || date +%s)
    ssrf_dt=$(awk -v a="$ssrf_t0" -v b="$ssrf_t1" 'BEGIN{printf "%.2f", b-a}')
    fast=no
    awk -v d="$ssrf_dt" -v m="$MAX_TIME" 'BEGIN{exit !(d < m/2)}' && fast=yes
    # Authoritative discriminator: a `block(N) ... <target>` line dante appended
    # for THIS target during THIS probe (matched below with grep -E + a sed-
    # escaped, EOL-anchored target — POSIX, keeps sh -n clean, §11.4.67).
    block_log_seen=no; block_line=""
    if [ "$dante_log_avail" = yes ]; then
        # Anchor the target to the destination field ("<ip>.<port>" at end of the
        # block line) so an overridden prefix target (e.g. 10.0.0.1) cannot
        # substring-match a longer blocked dest (10.0.0.10) — review finding,
        # §11.4.6. Escape the IP dots for the ERE (POSIX sed, keeps sh -n clean).
        _tgt_re=$(printf '%s' "$SSRF_TARGET" | sed 's/\./\\./g')
        block_line=$(podman exec "$DANTE_CTR" sh -c "tail -n +$((log_before + 1)) '$DANTE_LOG'" 2>/dev/null \
            | grep -E 'block\([0-9]+\)' | grep -E " ${_tgt_re}\.[0-9]+[[:space:]]*\$" | tail -1)
        [ -n "$block_line" ] && block_log_seen=yes
    fi
    {
        printf '=== S4: SOCKS5 SSRF hardening ===\n'
        printf 'socks_url=%s control_204=%s\n' "$SOCKS_URL" "$socks_ctrl"
        printf 'ssrf_target=%s code=%s curl_rc=%s elapsed=%ss fast=%s\n' "$SSRF_TARGET" "$ssrf_code" "$ssrf_rc" "$ssrf_dt" "$fast"
        printf 'dante_log_avail=%s block_log_seen=%s (AUTHORITATIVE sink signal, §11.4.69)\n' "$dante_log_avail" "$block_log_seen"
        [ -n "$block_line" ] && printf 'dante_block_line=%s\n' "$block_line"
    } > "$S4_EV"
    if [ "$dante_log_avail" != yes ]; then
        echo "[S4] SKIP dante log unreadable (container=$DANTE_CTR log=$DANTE_LOG) — sink signal unobtainable, timing alone insufficient"
        ab_skip_with_reason "S4 SOCKS5 SSRF (dante block-log unreadable — cannot obtain §11.4.69 sink signal)" "topology_unsupported"
        N_SKIP=$((N_SKIP + 1))
    elif [ "$block_log_seen" = yes ]; then
        echo "[S4] PASS SOCKS5 SSRF blocked ($SSRF_TARGET — dante block() log line present, code=$ssrf_code ${ssrf_dt}s fast=$fast)"
        ab_pass_with_evidence "S4 SOCKS5 SSRF: internal $SSRF_TARGET blocked by ruleset (dante block() log line, §11.4.69 sink-side)" "$S4_EV"
        N_PASS=$((N_PASS + 1)); S4_PASS=1
    else
        echo "[S4] FAIL SOCKS5 did NOT block $SSRF_TARGET (no dante block() log line; code=$ssrf_code rc=$ssrf_rc ${ssrf_dt}s fast=$fast) — CONNECT forwarded, SSRF possible"
        _evidence_emit FAIL "S4 SOCKS5 SSRF" "[reason: no dante block() line for internal $SSRF_TARGET — the CONNECT was forwarded, not blocked (SSRF, §11.4.68/.69/.169); add/restore socks block rules; see $S4_EV]"
        N_FAIL=$((N_FAIL + 1))
    fi
fi

# ---------------------------------------------------------------------------
# Aggregate (§11.4.120/§11.4.1 honest verdict) —
#   FAIL  if ANY sub-check FAILed (a real leak/defect trumps everything);
#   PASS  ONLY if BOTH security-CRITICAL checks PASSed — S1 (ACL-deny + no-leak)
#         AND S4 (SOCKS5-SSRF block). A non-critical PASS (S2/S3) while a critical
#         check SKIPPED does NOT earn a group PASS — that would over-claim security
#         coverage the run never proved;
#   SKIP  otherwise (a critical check could not run — coverage honestly absent),
#         naming which critical check(s) were absent.
# ---------------------------------------------------------------------------
echo
echo "=== $SUITE aggregate: pass=$N_PASS fail=$N_FAIL skip=$N_SKIP (S1_PASS=$S1_PASS S4_PASS=$S4_PASS) ==="
# §11.4.107(10): the group decision is the SINGLE-SOURCE acl_group_verdict()
# (tests/lib/acl_group_verdict.sh) — the IDENTICAL function the §11.4.135
# regression guard drives. Behaviour-preserving: same PASS/FAIL/SKIP text + same
# 0/1/3 exit as the prior inline block.
_agg_verdict=$(acl_group_verdict "$S1_PASS" "$S4_PASS" "$N_FAIL")
_agg_rc=$?
echo "OVERALL=$_agg_verdict"
exit "$_agg_rc"
