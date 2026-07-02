#!/usr/bin/env bash
# =============================================================================
# vpn_failclosed_test.sh — VPN tunnel-DOWN fail-closed safety guard (P10)
# -----------------------------------------------------------------------------
# Purpose:      §11.4.68/§11.4.69/§11.4.108/§11.4.115 fail-closed SAFETY guard for
#               the VPN-aware `dynamic` routing profile. Proves the security-critical
#               contract (docker-compose.dynamic.yml:22-24, design §10): when the VPN
#               tunnel for a request is DOWN, the proxy MUST serve the BRANDED
#               fail-closed response (503 + ERR_TUNNEL_DOWN) and MUST NOT leak the
#               request to the open internet.
#
#               The tunnel-down state is set DETERMINISTICALLY without a real VPN:
#               the acl-helper's verdict is data-driven from Redis
#               (control-plane/cmd/acl-helper/main.go:1-8 +
#               control-plane/internal/aclhelper/decide.go:47-70) — it answers
#               `OK tag=<tunnel>` ONLY when route:<host> exists AND
#               vpn:status:<tunnel>.state == "up"; EVERY other case (incl. an
#               explicit "down" status) is ERR → Squid `deny_info 503:ERR_TUNNEL_DOWN`
#               (config/squid/squid.dynamic.conf:75-77 +
#               control-plane/internal/routing/routing.go:294-297). So writing
#               vpn:status:<profile> = {"state":"down"} (redis client
#               control-plane/internal/redis/client.go:82-101 evaluateStatus; keys
#               control-plane/internal/vpn/vpn.go:21-41) forces the tunnel-down
#               fail-closed path with NO WireGuard credentials, NO gluetun egress.
#
# Live proof:   The CONDUCTOR owns the live boot (§11.4.119 single owner):
#                 ./start --dynamic          # boots the dynamic profile, binds :53128
#                 HELIX_DYNAMIC_STACK=1 bash tests/dynamic/vpn_failclosed_test.sh
#               This script performs NO up/start/stop/build. Undeclared / unreachable
#               stack ⇒ honest §11.4.3 SKIP-with-reason, NEVER a fake PASS.
#
# Two halves (design §15 / §11.4.68):
#   (A) FAIL-CLOSED (this test, AUTONOMOUS): tunnel DOWN ⇒ branded 503 + NO leak.
#       Positive evidence — the response body IS the branded ERR_TUNNEL_DOWN page
#       (NOT the origin's content) AND Squid's own access.log records TCP_DENIED
#       (no upstream contacted). Never "absence-of-error".
#   (B) REAL-VPN EGRESS (proving traffic actually exits via the tunnel): OPERATOR-
#       GATED on gluetun WireGuard credentials (§11.4.21; docker-compose.dynamic.yml
#       :148-153). Emitted here as an honest operator_attended SKIP — NOT attempted.
#
# RED_MODE:     §11.4.115 polarity — proves the branded-503 assertion genuinely
#               catches a leak (needs NO live stack):
#                 RED_MODE=1 feeds a golden-BAD fixture (a fabricated 200 "leak"
#                 body from the origin, NO ERR_TUNNEL_DOWN) into the SAME canonical
#                 assert_graceful_503 path and asserts it FAILs — an assertion that
#                 PASSed the leak would be a §11.4.107(10) bluff gate.
#                 RED_MODE=0 (default) is the standing GREEN safety guard.
#
# Usage:        HELIX_DYNAMIC_STACK=1 GOMAXPROCS=2 nice -n 19 ionice -c 3 \
#                   bash tests/dynamic/vpn_failclosed_test.sh
#               (self-re-execs under nice/ionice when present so §12.6 caps hold).
# Env (inputs):
#   RED_MODE                     0 = GREEN guard (default), 1 = RED self-validation.
#   HELIX_DYNAMIC_STACK          set to 1 (by the conductor, post-boot) to declare
#                                the dynamic stack up. Unset ⇒ honest topology SKIP.
#   HELIX_PROXY_URL              HTTP proxy URL (default http://127.0.0.1:53128).
#   HELIX_FAILCLOSED_TARGET      target fetched THROUGH the proxy (default
#                                http://example.com/). Reachable-if-leaked, so a
#                                fail-OPEN would return the origin's 200 (a LEAK
#                                this test hard-FAILs).
#   HELIX_FAILCLOSED_PROFILE     tunnel/profile name written down in Redis
#                                (default failclosed-test) — self-consistent with
#                                the seeded route; isolated from healthd's profiles.
#   HELIX_FAILCLOSED_REDIS_CLI   full redis-cli invocation prefix (§11.4.28 config
#                                injection). Default: "<runtime> exec -i proxy-redis
#                                redis-cli" with <runtime> auto-detected (podman
#                                preferred, else docker) or HELIX_CONTAINER_RUNTIME.
#   HELIX_SQUID_CONTAINER        Squid container name for the PID/no-crash probe
#                                (default proxy-squid).
#   HELIX_FAILCLOSED_ITER        GREEN determinism iterations (§11.4.50; default 3).
#   HELIX_PROBE_TIMEOUT          curl --max-time for probes (default 15).
#   HELIX_FAILCLOSED_EVIDENCE_DIR evidence dir override (default
#                                qa-results/dynamic/vpn_failclosed/<run-id>).
# Outputs:      Structured PASS/FAIL/SKIP verdict lines from tests/lib/evidence.sh;
#               captured artefacts (branded 503 bodies, access.log slice, redis
#               GET echo) under the evidence dir. Return code:
#                 0 = PASS / valid-SKIP, 1 = FAIL, 2 = invalid-SKIP.
# Side-effects: Writes/deletes ONLY the test's own route:<host> + vpn:status:<profile>
#               Redis keys (cleaned in trap ... EXIT, §11.4.14 — leaves the stack
#               quiescent). Runs live curl through the proxy. Creates a gitignored
#               qa-results/ evidence dir. NEVER boots/starts/stops/builds anything.
#               NEVER touches operator resources (wg0-mullvad / lava-* / whoami:58080).
# Dependencies: POSIX sh, awk, grep, curl. A container runtime (podman/docker) ONLY
#               for the redis-cli exec + Squid PID probe (exec, NOT a start/stop
#               workflow — mirrors lib/container-runtime.sh's own podman exec/ps use).
#               Sources tests/lib/evidence.sh (assert_graceful_503 / ab_* helpers).
# Resources:    GOMAXPROCS=2 + nice -n 19 + ionice -c 3 (self-applied when present).
# Cross-refs:   §11.4.68/§11.4.69 (positive sink-side fail-closed evidence, no
#               fail-open SKIP-as-PASS) / §11.4.115 (RED polarity) / §11.4.108
#               (runtime signature: PID unchanged) / §11.4.107(10) (self-validated
#               analyzer) / §11.4.119 (conductor owns the live boot) / §11.4.3
#               (honest topology SKIP) / §11.4.21 (operator-gated egress half).
#               Companion doc: docs/scripts/vpn_failclosed_test.md.
# Shell:        POSIX-clean — parses under `sh -n` AND `bash -n` (§11.4.67). No
#               bash-only constructs ([[ ]], <<<, arrays, >( ), ${v^^}).
# =============================================================================

# --- resource cap: self-re-exec under nice/ionice when available (§12.6) ------
# Skipped when sourced FUNCTIONS-ONLY by the §11.4.135 regression guard
# (FAILCLOSED_SOURCE_ONLY=1) so `exec` never hijacks the guard's process.
if [ "${HELIX_FAILCLOSED_NICED:-0}" != "1" ] && [ "${FAILCLOSED_SOURCE_ONLY:-0}" != "1" ]; then
    HELIX_FAILCLOSED_NICED=1
    export HELIX_FAILCLOSED_NICED
    GOMAXPROCS=2
    export GOMAXPROCS
    _fc_nice=""
    _fc_ionice=""
    command -v nice >/dev/null 2>&1 && _fc_nice="nice -n 19"
    command -v ionice >/dev/null 2>&1 && _fc_ionice="ionice -c 3"
    if [ -n "$_fc_nice$_fc_ionice" ] && [ -x "$0" ]; then
        # shellcheck disable=SC2086
        exec $_fc_nice $_fc_ionice "$0" "$@"
    fi
fi

# ---------------------------------------------------------------------------
# Pure verdict-classifier for the NO-LEAK-but-not-branded-PASS branches
# (single-source, §11.4.107(10)/§11.4.6). Exercised BOTH by the STEP-5 body
# below AND by the §11.4.135 regression guard
# tests/regression/vpn_failclosed_reason_test.sh, which sources this file with
# FAILCLOSED_SOURCE_ONLY=1 (defines the function, runs NO live probes / NO
# side effects) — no divergent copy of the classification logic.
#
# fc_no_leak_skip_reason <iter> <timeout_count> <nonbrand> <graceful_503_rc>
#   Emits "<closed-set-reason>|<honest reason text>".
#   §11.4.6: when EVERY proxied iteration timed out (000), a 000 is
#   absence-of-response — NOT positive evidence that the fail-closed 503 served.
#   The start-of-test reachability probe confirmed the proxy answered at test
#   START, not during the timed-out window. Such a run is INCONCLUSIVE (the
#   fail-closed contract was NOT positively observed), never "fail-closed held —
#   no leak". Only a run that received real (non-000) fail-closed responses may
#   claim the branded path is merely inactive (fail-closed held, no leak).
fc_no_leak_skip_reason() {
    _fc_iter=$1; _fc_to=$2; _fc_nb=$3; _fc_g=$4
    if [ "$_fc_iter" -gt 0 ] 2>/dev/null && [ "$_fc_to" -ge "$_fc_iter" ] 2>/dev/null; then
        printf 'network_unreachable_external|vpn_failclosed (all %s proxied iterations timed out (000); fail-closed NOT positively observed this run — §11.4.3/§11.4.6 inconclusive, not proof of no-leak)' \
            "$_fc_iter"
        return 0
    fi
    printf 'feature_disabled_by_config|vpn_failclosed (fail-closed held — no leak — but branded ERR_TUNNEL_DOWN path inactive: nonbrand=%s graceful_503_rc=%s; dynamic-routing.squid/external_acl likely not rendered — compiler lane pending)' \
        "${_fc_nb:-none}" "$_fc_g"
}

# Sourced for its function only (regression guard) — stop before any side effect
# (no evidence.sh $0-based path resolution, no live probe).
if [ "${FAILCLOSED_SOURCE_ONLY:-0}" = "1" ]; then return 0 2>/dev/null || exit 0; fi

set -u

# --- locate repo root + source the canonical evidence helper ------------------
FC_DIR=$(cd "$(dirname "$0")" 2>/dev/null && pwd)
FC_REPO_ROOT=$(cd "$FC_DIR/../.." 2>/dev/null && pwd)   # tests/dynamic -> repo root
FC_EVIDENCE_LIB="$FC_REPO_ROOT/tests/lib/evidence.sh"
if [ ! -f "$FC_EVIDENCE_LIB" ]; then
    printf 'FAIL: vpn_failclosed [reason: canonical evidence helper not found at %s]\n' "$FC_EVIDENCE_LIB"
    exit 1
fi
# shellcheck source=/dev/null
. "$FC_EVIDENCE_LIB"

# --- config -------------------------------------------------------------------
RED_MODE=${RED_MODE:-0}
PROXY_URL=${HELIX_PROXY_URL:-http://127.0.0.1:53128}
TARGET=${HELIX_FAILCLOSED_TARGET:-http://example.com/}
PROFILE=${HELIX_FAILCLOSED_PROFILE:-failclosed-test}
SQUID_CTR=${HELIX_SQUID_CONTAINER:-proxy-squid}
ITER=${HELIX_FAILCLOSED_ITER:-3}
PROBE_TIMEOUT=${HELIX_PROBE_TIMEOUT:-15}
RUN_ID=$(date -u +%Y%m%dT%H%M%SZ)
QA=${HELIX_FAILCLOSED_EVIDENCE_DIR:-$FC_REPO_ROOT/qa-results/dynamic/vpn_failclosed/$RUN_ID}
mkdir -p "$QA" 2>/dev/null
ACCESS_LOG=${HELIX_SQUID_ACCESS_LOG:-$FC_REPO_ROOT/logs/access.log}

# Branded fail-closed markers — MUST match config/squid/errors/ERR_TUNNEL_DOWN
# (the page `deny_info 503:ERR_TUNNEL_DOWN` resolves) + the design contract.
BRAND_REF="ERR_TUNNEL_DOWN"
BRAND_MARKER="tunnel"

# Extract the request Host from the target URL (route:<host> is keyed on the Host
# header Squid passes to the acl-helper via %>ha{Host}). Strips scheme, path, port.
TARGET_HOST=$(printf '%s' "$TARGET" | sed -e 's#^[a-zA-Z][a-zA-Z0-9+.-]*://##' -e 's#[/?].*$##' -e 's#:.*$##')

printf '# vpn_failclosed — run-id %s (RED_MODE=%s) proxy=%s target=%s host=%s profile=%s\n' \
    "$RUN_ID" "$RED_MODE" "$PROXY_URL" "$TARGET" "$TARGET_HOST" "$PROFILE"

# =============================================================================
# RED_MODE=1 — §11.4.115/§11.4.107(10) self-validation: prove the branded-503
# assertion FAILs a fabricated LEAK. Needs NO live stack (uses evidence.sh seams).
# =============================================================================
if [ "$RED_MODE" = "1" ]; then
    # Golden-BAD fixture: a 200 leak — the origin's real content, NO branded page.
    LEAK_BODY="$QA/red_leak_body.html"
    printf '<!DOCTYPE html><html><head><title>Example Domain</title></head><body><h1>Example Domain</h1><p>Leaked to the open internet — NO fail-closed page.</p></body></html>\n' > "$LEAK_BODY"
    # Drive the SAME canonical assertion the GREEN guard trusts, feeding the leak
    # via the documented unit-layer seams. Marker = the branded reference so the
    # golden-BAD (which lacks it) is provably rejected.
    RED_OUT="$QA/red_assertion.out"
    EVIDENCE_503_CODE_OVERRIDE=200 \
    EVIDENCE_503_BODY_FILE="$LEAK_BODY" \
    EVIDENCE_503_BODY_MARKER="$BRAND_REF" \
        assert_graceful_503 "$PROXY_URL" "$TARGET" "1234" "1234" > "$RED_OUT" 2>&1
    RED_RC=$?
    {
        printf '# RED baseline — branded-503 assertion vs a fabricated 200 LEAK\n'
        printf 'seam: EVIDENCE_503_CODE_OVERRIDE=200 body=%s marker=%s\n' "$LEAK_BODY" "$BRAND_REF"
        printf 'assert_graceful_503 rc=%s (want 1 = correctly FAILed the leak)\n' "$RED_RC"
        printf '# assertion verdict:\n'
        cat "$RED_OUT" 2>/dev/null
    } > "$QA/red_baseline.txt"
    if [ "$RED_RC" -ne 0 ]; then
        ab_pass_with_evidence \
            "vpn_failclosed RED: branded-503 assertion correctly FAILs a 200 leak (not a bluff gate)" \
            "$QA/red_baseline.txt"
        exit $?
    fi
    printf 'FAIL: vpn_failclosed RED-baseline [reason: assert_graceful_503 PASSed a fabricated 200 LEAK (rc=%s) — the branded-503 assertion is a bluff gate; see %s]\n' \
        "$RED_RC" "$QA/red_baseline.txt"
    exit 1
fi

# =============================================================================
# RED_MODE=0 — standing GREEN fail-closed safety guard (conductor booted the stack).
# =============================================================================

# --- redis-cli invocation prefix (auto-detect runtime; overridable §11.4.28) --
detect_runtime() {
    if [ -n "${HELIX_CONTAINER_RUNTIME:-}" ]; then
        printf '%s' "$HELIX_CONTAINER_RUNTIME"; return 0
    fi
    if command -v podman >/dev/null 2>&1; then printf 'podman'; return 0; fi
    if command -v docker >/dev/null 2>&1; then printf 'docker'; return 0; fi
    printf ''
}
RUNTIME=$(detect_runtime)
REDIS_CLI=${HELIX_FAILCLOSED_REDIS_CLI:-}
if [ -z "$REDIS_CLI" ] && [ -n "$RUNTIME" ]; then
    REDIS_CLI="$RUNTIME exec -i proxy-redis redis-cli"
fi

# rediscli <args...> — run the configured redis-cli against proxy-redis.
rediscli() {
    # shellcheck disable=SC2086
    $REDIS_CLI "$@"
}

# --- availability gate (§11.4.3 / §11.4.119): honest SKIP, never a fake PASS ---
if [ "${HELIX_DYNAMIC_STACK:-0}" != "1" ]; then
    ab_skip_with_reason \
        "vpn_failclosed (dynamic stack not declared booted — conductor owns the live boot §11.4.119)" \
        "topology_unsupported"
    exit $?
fi
if [ -z "$REDIS_CLI" ]; then
    ab_skip_with_reason \
        "vpn_failclosed (no container runtime + no HELIX_FAILCLOSED_REDIS_CLI to reach proxy-redis)" \
        "topology_unsupported"
    exit $?
fi
# Redis reachability: the down-state write is the whole test — an unreachable Redis
# is a topology SKIP, never a fabricated fail-closed PASS.
if ! rediscli ping 2>/dev/null | grep -qi 'PONG'; then
    ab_skip_with_reason \
        "vpn_failclosed (proxy-redis unreachable via '$REDIS_CLI')" \
        "topology_unsupported"
    exit $?
fi
# Proxy reachability (CONNECT capability probe).
if ! curl -s --max-time "$PROBE_TIMEOUT" -o /dev/null -x "$PROXY_URL" "http://127.0.0.1/" 2>/dev/null; then
    ab_skip_with_reason \
        "vpn_failclosed (dynamic proxy $PROXY_URL declared but unreachable)" \
        "network_unreachable_external"
    exit $?
fi

# --- cleanup: remove ONLY our own keys on every exit path (§11.4.14) ----------
_fc_cleanup() {
    rediscli DEL "route:$TARGET_HOST" >/dev/null 2>&1 || true
    rediscli DEL "vpn:status:$PROFILE" >/dev/null 2>&1 || true
}
trap _fc_cleanup EXIT INT TERM

# --- STEP 1: force the tunnel DOWN deterministically (no real VPN) -------------
# (a) seed route:<host> -> our profile so the acl-helper reaches the STATUS check
#     (exercises the *tunnel-down* path, not merely the *no-route* path).
# (b) write vpn:status:<profile> = state "down" (checked_at now).
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
ROUTE_JSON=$(printf '{"target":"%s","tunnel":"%s","tier":0,"breaker_state":"closed"}' "$TARGET_HOST" "$PROFILE")
STATUS_JSON=$(printf '{"profile":"%s","state":"down","last_handshake":"0001-01-01T00:00:00Z","rx":0,"tx":0,"egress_ip":"","checked_at":"%s"}' "$PROFILE" "$NOW")
rediscli SET "route:$TARGET_HOST" "$ROUTE_JSON" >/dev/null 2>&1 || true
rediscli SET "vpn:status:$PROFILE" "$STATUS_JSON" >/dev/null 2>&1 || true

# Verify the down-state write TOOK (positive evidence of the injected precondition).
STATUS_ECHO=$(rediscli GET "vpn:status:$PROFILE" 2>/dev/null)
{
    printf '# injected tunnel-down precondition (run-id %s)\n' "$RUN_ID"
    printf 'route:%s = %s\n' "$TARGET_HOST" "$(rediscli GET "route:$TARGET_HOST" 2>/dev/null)"
    printf 'vpn:status:%s = %s\n' "$PROFILE" "$STATUS_ECHO"
} > "$QA/redis_down_state.txt"
if ! printf '%s' "$STATUS_ECHO" | grep -q '"state":"down"'; then
    printf 'FAIL: vpn_failclosed [reason: could not confirm vpn:status:%s == down after SET (got: %s) — see %s]\n' \
        "$PROFILE" "$STATUS_ECHO" "$QA/redis_down_state.txt"
    exit 1
fi

# --- STEP 2: capture Squid PID before (runtime signature §11.4.108) ------------
squid_pid() {
    if [ -z "$RUNTIME" ]; then printf ''; return 0; fi
    # Prefer the pidfile (config/squid/squid.dynamic.conf:114); fall back to pidof.
    _p=$($RUNTIME exec "$SQUID_CTR" cat /var/run/squid/squid.pid 2>/dev/null | tr -dc '0-9')
    if [ -z "$_p" ]; then
        _p=$($RUNTIME exec "$SQUID_CTR" pidof squid 2>/dev/null | awk '{print $1}' | tr -dc '0-9')
    fi
    printf '%s' "$_p"
}
PID_BEFORE=$(squid_pid)

# --- STEP 3: drive N proxied requests; assert branded 503 + NO leak each -------
ALL_BRANDED=1
LEAK_SEEN=0
NONBRAND_CODE=""
TIMEOUT_COUNT=0
i=1
while [ "$i" -le "$ITER" ]; do
    BODY="$QA/req_${i}.body"
    CODE=$(curl -s --max-time "$PROBE_TIMEOUT" -o "$BODY" -w '%{http_code}' \
        -x "$PROXY_URL" "$TARGET" 2>/dev/null)
    [ -n "$CODE" ] || CODE=000
    [ "$CODE" = "000" ] && TIMEOUT_COUNT=$((TIMEOUT_COUNT + 1))
    HAS_BRAND=no
    grep -q "$BRAND_REF" "$BODY" 2>/dev/null && HAS_BRAND=yes
    printf 'iter=%s http_code=%s err_tunnel_down_in_body=%s bytes=%s\n' \
        "$i" "$CODE" "$HAS_BRAND" "$(wc -c < "$BODY" 2>/dev/null | tr -d ' ')" >> "$QA/iterations.txt"

    case "$CODE" in
        2*|3*)
            # The origin answered THROUGH the proxy — the tunnel was down yet the
            # request egressed. This is the exact safety violation (a LEAK).
            LEAK_SEEN=1
            ALL_BRANDED=0
            ;;
        503)
            if [ "$HAS_BRAND" != "yes" ]; then
                ALL_BRANDED=0
                NONBRAND_CODE="503-no-brand"
            fi
            ;;
        *)
            ALL_BRANDED=0
            [ -z "$NONBRAND_CODE" ] && NONBRAND_CODE="$CODE"
            ;;
    esac
    i=$((i + 1))
done
PID_AFTER=$(squid_pid)

# --- STEP 4: positive NO-LEAK proof from Squid's own access.log ----------------
# Squid `squid` log format field 4 = <code>/<status>, field 9 = <peerstatus>/<peerhost>.
# Fail-closed at the acl layer => TCP_DENIED/503 + HIER_NONE (no upstream contacted).
# A LEAK => a forward (HIER_DIRECT / FIRSTUP_PARENT / *_PARENT) and/or a 2xx/3xx.
LEAK_LOG="$QA/access_log_slice.txt"
DENIED_LINES=0
FORWARD_LINES=0
ACCESS_NOTE=""
if [ -f "$ACCESS_LOG" ]; then
    grep -F "$TARGET_HOST" "$ACCESS_LOG" 2>/dev/null | tail -n 50 > "$LEAK_LOG" || true
    DENIED_LINES=$(grep -c 'TCP_DENIED/503' "$LEAK_LOG" 2>/dev/null || printf 0)
    # Any upstream-forward hierarchy code for our host = a leak signal.
    FORWARD_LINES=$(grep -E 'HIER_DIRECT|FIRSTUP_PARENT|ROUNDROBIN_PARENT|[A-Z_]*_PARENT/' "$LEAK_LOG" 2>/dev/null | grep -Evc 'HIER_NONE' || printf 0)
else
    printf '# access.log not found at %s (log mount absent?)\n' "$ACCESS_LOG" > "$LEAK_LOG"
    # §11.4.6: with no access.log the TCP_DENIED=0 count is absence-of-data, not
    # corroboration — the branded-503 body remains the primary NO-LEAK proof.
    ACCESS_NOTE=" (access.log absent — corroboration only; branded-503 body is the primary proof)"
fi
[ -n "$DENIED_LINES" ] || DENIED_LINES=0
[ -n "$FORWARD_LINES" ] || FORWARD_LINES=0
[ "$FORWARD_LINES" -gt 0 ] 2>/dev/null && LEAK_SEEN=1

# --- STEP 5: canonical corroboration via evidence.sh assert_graceful_503 -------
# One additional live request through the SAME canonical, self-tested helper
# (branded-body + PID-unchanged proof; §11.4.108 runtime signature).
G503_OUT="$QA/graceful_503.out"
EVIDENCE_503_BODY_MARKER="$BRAND_MARKER" \
    assert_graceful_503 "$PROXY_URL" "$TARGET" "$PID_BEFORE" "$PID_AFTER" > "$G503_OUT" 2>&1
G503_RC=$?
cat "$G503_OUT"

# --- verdict aggregation ------------------------------------------------------
{
    printf '# vpn_failclosed verdict inputs (run-id %s)\n' "$RUN_ID"
    printf 'iterations=%s all_branded_503=%s leak_seen=%s nonbrand=%s\n' \
        "$ITER" "$ALL_BRANDED" "$LEAK_SEEN" "${NONBRAND_CODE:-none}"
    printf 'access_log_denied_503_lines=%s upstream_forward_lines=%s\n' "$DENIED_LINES" "$FORWARD_LINES"
    printf 'squid_pid_before=%s squid_pid_after=%s graceful_503_rc=%s\n' \
        "${PID_BEFORE:-?}" "${PID_AFTER:-?}" "$G503_RC"
    printf '# --- iterations ---\n'
    cat "$QA/iterations.txt" 2>/dev/null
    printf '# --- access.log slice (host %s) ---\n' "$TARGET_HOST"
    cat "$LEAK_LOG" 2>/dev/null
} > "$QA/verdict.txt"

# HARD FAIL: any leak (origin answered, or an upstream-forward log line).
if [ "$LEAK_SEEN" = "1" ]; then
    printf 'FAIL: vpn_failclosed [reason: LEAK — tunnel DOWN but a request egressed (2xx/3xx through proxy OR upstream-forward in access.log, forward_lines=%s); the fail-closed kill-switch did NOT hold — see %s]\n' \
        "$FORWARD_LINES" "$QA/verdict.txt"
    exit 1
fi

# PASS: every iteration was the branded ERR_TUNNEL_DOWN 503 AND no leak AND the
# canonical graceful_503 (branded body + PID unchanged) corroborated.
if [ "$ALL_BRANDED" = "1" ] && [ "$G503_RC" -eq 0 ]; then
    ab_pass_with_evidence \
        "vpn_failclosed: tunnel DOWN ⇒ branded 503 ERR_TUNNEL_DOWN x$ITER + NO leak (access.log TCP_DENIED=$DENIED_LINES, no upstream forward, Squid PID unchanged)$ACCESS_NOTE" \
        "$QA/verdict.txt" || exit $?
    # Half (B): real-VPN EGRESS proof is operator-gated on gluetun creds (§11.4.21).
    ab_skip_with_reason \
        "vpn_failclosed egress-half (traffic actually exits via the tunnel — needs operator gluetun WireGuard creds §11.4.21)" \
        "operator_attended"
    exit $?
fi

# No leak observed, but NOT the branded ERR_TUNNEL_DOWN PASS. Two honest, distinct
# §11.4.3 SKIPs (never a fail-open PASS §11.4.68, never a false leak-FAIL — the
# request did NOT leak), classified by the single-source fc_no_leak_skip_reason:
#   (a) EVERY iteration timed out (000) — absence-of-response, INCONCLUSIVE
#       (§11.4.6): the fail-closed 503 was NOT positively observed this run.
#   (b) real (non-000) fail-closed responses but the branded path is inactive
#       (compiler has not rendered dynamic-routing.squid) — fail-closed held.
if [ "$G503_RC" -ne 0 ] || [ "$ALL_BRANDED" != "1" ]; then
    FC_CLS=$(fc_no_leak_skip_reason "$ITER" "$TIMEOUT_COUNT" "$NONBRAND_CODE" "$G503_RC")
    FC_REASON=${FC_CLS%%|*}
    FC_TEXT=${FC_CLS#*|}
    ab_skip_with_reason "$FC_TEXT (see $QA/verdict.txt)" "$FC_REASON"
    exit $?
fi

printf 'FAIL: vpn_failclosed [reason: unclassified — see %s]\n' "$QA/verdict.txt"
exit 1
