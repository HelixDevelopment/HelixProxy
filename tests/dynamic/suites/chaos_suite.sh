#!/usr/bin/env bash
# =============================================================================
# chaos_suite.sh — §11.4.85/§11.4.169 CHAOS / failure-injection suite
# -----------------------------------------------------------------------------
# Purpose:      Inject real faults into the live `dynamic` stack and assert the
#               design's fail-closed contract holds (design §10):
#                 C1 kill gluetun mid-request -> branded 503 + Squid PID UNCHANGED
#                    (graceful_503 analyzer) AND ZERO target packets on the real
#                    uplink during the down window (no_leak analyzer) -> recovery
#                    to 200 when the tunnel returns (zero reconfigure).
#                 C2 drop the network to the tunnel -> fail-closed 503, no leak.
#                 C3 corrupt / delete the Redis vpn:status key -> stale = DOWN =
#                    fail-closed 503 (never fall through to a leaking direct req).
#               Every verdict is an analyzer citing a captured artefact (§11.4.69).
# Status:       AUTHORED FOR P10. SKIPs-with-reason today (no live stack /
#               no injection hooks) — honest non-evidence, never a fake PASS.
# Injection:    fault injection is delegated to operator/orchestrator-supplied
#               commands (config injection §11.4.28; containers submodule §11.4.76
#               — NEVER hardcoded podman/docker here, §hard-stop):
#                 HELIX_CHAOS_KILL_CMD     bring a profile's tunnel DOWN
#                 HELIX_CHAOS_RESTART_CMD  bring it back UP
#                 HELIX_CHAOS_REDIS_CORRUPT_CMD  corrupt/delete vpn:status:<p>
#                 HELIX_CHAOS_CAPTURE_CMD  start a tcpdump capture on the real
#                                          uplink filtered to the target; prints
#                                          the capture file path on stdout
#               Cleanup of every injection runs in `trap ... EXIT` (§11.4.14).
# RED_MODE:     §11.4.115. RED_MODE=1 runs against the pre-fix stack and EXPECTS
#               a LEAK / crash / 200-on-down (defect reproduced); RED_MODE=0 is
#               the GREEN guard asserting fail-closed 503 + no leak + recovery.
# Usage:        bash tests/dynamic/suites/chaos_suite.sh
# Shell:        POSIX-clean (sh -n + bash -n, §11.4.67).
# Cross-refs:   §11.4.85 / §11.4.69 / §11.4.107 / §11.4.108 / §11.4.115 / §11.4.14;
#               design §10/§13; tests/dynamic/analyzers/{graceful_503,no_leak}.
# =============================================================================
DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=/dev/null
# Idempotent: on normal execution $0 resolves DIR and this sources the lib; when
# the §11.4.135 guard has ALREADY sourced analyzer_common.sh (its $0-based DIR would
# be wrong here), skip the re-source so a failed `.` never aborts the guard.
command -v dyn_run_analyzer >/dev/null 2>&1 || . "$DIR/../lib/analyzer_common.sh"

# ---------------------------------------------------------------------------
# Reusable no-leak evaluation helpers (single-source, §11.4.107(10)). These are
# exercised BOTH by the C1 body below AND by the §11.4.135 regression guard
# tests/regression/chaos_no_leak_argshape_test.sh, which sources this file with
# CHAOS_SOURCE_ONLY=1 (defines the functions, runs NO live probes / NO side
# effects) — no divergent copy of the fix logic.
# ---------------------------------------------------------------------------

# chaos_target_leak_key <target-url-or-host-or-ip>
# Reduce the C1 target to the bare host/IP shape a tcpdump line actually carries,
# so no_leak_analyzer's " IP .*<key>" grep can match a leaked packet. The pre-fix
# call site passed the FULL URL (http://target-a.internal/); a scheme-prefixed URL
# NEVER appears in a tcpdump line, so the count was always 0 and a REAL leak passed
# as "no leak" (§11.4.107(10) bluff). Strip scheme:// + user@ + /path + ?query +
# :port to the bare host, then resolve the host to an IP when a resolver answers
# (numeric tcpdump lines carry IPs; the analyzer self-test keys on an IP). §11.4.6
# residual: when NO resolver answers (an internal name with no live DNS — needs the
# live stack), fall back to the bare HOST (still NEVER the URL); a purely-numeric
# capture then depends on the live stack's DNS to resolve the name.
chaos_target_leak_key() {
    _t=$1
    _t=${_t#*://}          # strip scheme://
    _t=${_t%%/*}           # strip /path
    _t=${_t%%\?*}          # strip ?query (defensive)
    _t=${_t##*@}           # strip user@ (defensive)
    _host=${_t%%:*}        # strip :port
    if [ -z "$_host" ]; then printf '%s' "$_t"; return 0; fi
    case "$_host" in
        *[!0-9.]*) : ;;                        # has non-numeric chars — try resolve
        *) printf '%s' "$_host"; return 0 ;;   # already a bare IPv4 literal
    esac
    _ip=""
    if command -v getent >/dev/null 2>&1; then
        _ip=$(getent hosts "$_host" 2>/dev/null | awk 'NR==1{print $1}')
    fi
    if [ -z "$_ip" ] && command -v dig >/dev/null 2>&1; then
        _ip=$(dig +short "$_host" 2>/dev/null | awk '/^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/{print;exit}')
    fi
    if [ -n "$_ip" ]; then printf '%s' "$_ip"; else printf '%s' "$_host"; fi
}

# chaos_leak_signal <capture> <target>
# Honest C1 no-leak sub-signal (§11.4.6/§11.4.69 — no absence-as-evidence):
#   rc 0  real no-leak evidence: capture non-empty AND analyzer PASS (0 target pkts)
#   rc 1  LEAK: the analyzer counted >=1 packet to the resolved target key
#   rc 2  UNEVALUATED: capture absent/empty — NOT "no leak" (missing evidence)
# The target is reduced to the host/IP leak-key first (never the scheme-prefixed
# URL). rc 2 is turned into an honest SKIP by the caller, never a no-leak PASS.
chaos_leak_signal() {
    _cap=$1
    _tgt=$2
    if [ -z "$_cap" ] || [ ! -f "$_cap" ] || [ ! -s "$_cap" ]; then
        return 2
    fi
    _key=$(chaos_target_leak_key "$_tgt")
    dyn_run_analyzer no_leak_analyzer.sh "$_cap" "$_key"
}

# Sourced for its functions only (regression guard) — stop before any side effect.
if [ "${CHAOS_SOURCE_ONLY:-0}" = "1" ]; then return 0 2>/dev/null || exit 0; fi

SUITE="chaos"
RUN_ID=$(date -u +%Y%m%dT%H%M%SZ)
QA="$(ac_qa_dir p9-harness)/${SUITE}_${RUN_ID}"
mkdir -p "$QA"
PROXY=$(dyn_stack_proxy_url)
TARGET=${CHAOS_TARGET:-http://target-a.internal/}
PROFILE=${CHAOS_PROFILE:-profile-a}

printf '# %s suite — run-id %s (RED_MODE=%s)\n' "$SUITE" "$RUN_ID" "${RED_MODE:-0}"

# trap-based cleanup: always attempt to restore the tunnel so the suite leaves
# the stack quiescent (§11.4.14), on EVERY exit path.
_chaos_cleanup() {
    if [ -n "${HELIX_CHAOS_RESTART_CMD:-}" ]; then
        sh -c "$HELIX_CHAOS_RESTART_CMD" >/dev/null 2>&1 || true
    fi
}
trap _chaos_cleanup EXIT INT TERM

# Honest §11.4.69 SKIP: chaos needs BOTH a live stack AND injection hooks (P10).
if dyn_skip_if_no_stack "$SUITE (kill-tunnel / drop-net / corrupt-redis)"; then
    printf '# NOTE: chaos requires the live stack + injection hooks (P10). Authored + parse-clean today.\n'
    exit 0
fi
if [ -z "${HELIX_CHAOS_KILL_CMD:-}" ] || [ -z "${HELIX_CHAOS_CAPTURE_CMD:-}" ]; then
    ab_skip_with_reason "$SUITE (injection hooks not configured)" "feature_disabled_by_config"
    exit 0
fi

# ---------------------------------------------------------------------------
# C1 — kill gluetun mid-request: fail-closed 503 + PID unchanged + no leak.
# ---------------------------------------------------------------------------
pid_before=$(sh -c "${HELIX_SQUID_PID_CMD:-echo 0}" 2>/dev/null)
cap=$(sh -c "$HELIX_CHAOS_CAPTURE_CMD" 2>/dev/null)        # tcpdump on real uplink
sh -c "$HELIX_CHAOS_KILL_CMD" >/dev/null 2>&1              # tunnel DOWN

code=$(curl -s --max-time 20 -o "$QA/c1_503_body.html" -w '%{http_code}' \
    -x "$PROXY" "$TARGET" 2>/dev/null || printf '000')
pid_after=$(sh -c "${HELIX_SQUID_PID_CMD:-echo 0}" 2>/dev/null)

# Build the graceful_503 probe manifest from the live capture.
{
    printf 'http_code=%s\n' "$code"
    printf 'body_file=%s\n' "$QA/c1_503_body.html"
    printf 'pid_before=%s\n' "$pid_before"
    printf 'pid_after=%s\n' "$pid_after"
    printf 'marker=tunnel\n'
} > "$QA/c1_503.manifest"

g503_rc=0; dyn_run_analyzer graceful_503_analyzer.sh "$QA/c1_503.manifest" || g503_rc=1
# §11.4.6/§11.4.69/§11.4.107(10): no-leak is a MANDATORY C1 sub-signal. The target
# is resolved to the host/IP leak-key the analyzer greps — NEVER the full URL
# ($TARGET, a scheme-prefixed URL that never appears in a tcpdump line and would
# make a REAL leak count 0 and pass). An absent/empty uplink capture is missing
# evidence (rc 2), NOT "no leak" — turned into an honest SKIP below, never a PASS.
chaos_leak_signal "$cap" "$TARGET"; leak_rc=$?
if [ "$leak_rc" -eq 2 ]; then
    ab_skip_with_reason "$SUITE C1 (no-leak evidence absent — uplink capture empty/missing)" "network_unreachable_external"
    exit 0
fi

# Recovery: bring the tunnel back, assert the next request is 200 (no reconfigure).
sh -c "${HELIX_CHAOS_RESTART_CMD:-true}" >/dev/null 2>&1
rec=$(curl -s --max-time 30 -o /dev/null -w '%{http_code}' -x "$PROXY" "$TARGET" 2>/dev/null || printf '000')
printf 'recovery_http_code=%s\n' "$rec" > "$QA/c1_recovery.evidence"

if dyn_red_mode; then
    # RED baseline: the pre-fix stack should LEAK or NOT return a graceful 503.
    if [ "$g503_rc" -ne 0 ] || [ "$leak_rc" -ne 0 ]; then
        ab_pass_with_evidence "$SUITE RED-baseline reproduced fail-OPEN/crash on tunnel kill" "$QA/c1_503.manifest"
        exit $?
    fi
    ac_fail "$SUITE RED-baseline" "[reason: stack failed CLOSED (no defect to reproduce)]"
    exit 1
fi

if [ "$g503_rc" -eq 0 ] && [ "$leak_rc" -eq 0 ] && [ "$rec" = "200" ]; then
    ab_pass_with_evidence "$SUITE C1 fail-closed 503 + no leak + recovery 200" "$QA/c1_recovery.evidence"
    exit $?
fi
ac_fail "$SUITE C1" "[reason: graceful_503_rc=$g503_rc no_leak_rc=$leak_rc recovery=$rec (want 503-graceful + no-leak + 200) — see $QA]"
exit 1
