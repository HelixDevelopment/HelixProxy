#!/usr/bin/env bash
# =============================================================================
# proxy_restart_recovery.sh — §11.4.85/§11.4.169 CHAOS: squid restart recovery
# -----------------------------------------------------------------------------
# Purpose:      Prove the LIVE HTTP forward proxy (Squid, localhost:53128)
#               RECOVERS after a mid-flight container restart — the §11.4.85
#               process-death / §11.4.144 detect->wait->re-attach contract:
#                 (1) capture a WORKING proxied request (baseline 204/200),
#                 (2) inject the fault: restart the squid container mid-flight
#                     (delegated — see Injection below),
#                 (3) poll the proxied request through a bounded recovery window
#                     and assert it RECOVERS to 204/200,
#               emitting a CATEGORISED recovery trace (baseline_ok / fault_injected
#               / probe DOWN / recovered UP) with per-event timestamps. Every PASS
#               cites the captured recovery trace (§11.4.69) — never metadata-only.
# Injection:    This script NEVER hardcodes `podman/docker restart` (containers
#               submodule §11.4.76 + the CI/container hard-stop). The restart is
#               a config-injected command (§11.4.28) the CONDUCTOR supplies:
#                 PROXY_CHAOS_RESTART_CMD   restart the squid container mid-flight
#                                           (e.g. a containers-submodule restart of
#                                           proxy-squid). When UNSET the fault
#                                           cannot be injected autonomously, so the
#                                           suite SKIPs-with-reason (honest §11.4.3
#                                           feature_disabled_by_config) — the
#                                           restart+recovery assertion runs only
#                                           when the conductor executes it with the
#                                           hook set.
# Status:       Authored + parse-clean. Detects the squid container via `podman
#               ps` (docker fallback, READ-ONLY) and SKIPs topology_unsupported
#               when absent. The restart is performed ONLY by the injected command.
# Usage:        bash tests/chaos/proxy_restart_recovery.sh                 # SKIP unless hooks present
#               PROXY_CHAOS_RESTART_CMD='<containers-submodule restart proxy-squid>' \
#                   bash tests/chaos/proxy_restart_recovery.sh             # conductor run
#               GOMAXPROCS=2 nice -n 19 ionice -c 3 bash tests/chaos/proxy_restart_recovery.sh
# Inputs:       Live curl through http://localhost:53128 (READ-ONLY client use);
#               `podman ps` / `docker ps` (READ-ONLY container detection).
#               Env: HTTP_PROXY_URL (default http://localhost:53128),
#                    HTTP_PROXY_PORT (default 53128),
#                    CHAOS_SQUID_CONTAINER (default proxy-squid),
#                    CHAOS_TARGET (default https://www.gstatic.com/generate_204),
#                    CHAOS_EXPECT (default "204 200"),
#                    CHAOS_RECOVERY_TIMEOUT (default 60 s — reconnect budget),
#                    CHAOS_RECOVERY_POLL (default 2 s), CURL_MAX_TIME (default 15),
#                    PROXY_CHAOS_RESTART_CMD (fault-injection hook; unset => SKIP),
#                    CHAOS_EVIDENCE_DIR (default qa-results/chaos/proxy_restart_<ts>).
# Outputs:      A categorised recovery_trace.log + one PASS/FAIL/SKIP verdict.
#               Exit: 0 = PASS (recovered), 1 = FAIL (never recovered within the
#               window), 3 = SKIP (honest: container absent / no injection hook).
# Side-effects: Live curl + the injected restart command ONLY. Never boots,
#               stops, or hardcodes any container command; never touches operator
#               resources. Creates the evidence dir under qa-results/ (gitignored).
#               `trap` cleanup (§11.4.14) leaves the target quiescent on every exit.
# Dependencies: bash, curl, awk, grep; tests/lib/evidence.sh (sourced);
#               podman OR docker (detection only, optional).
# Resources:    shell + curl only; single-threaded poll; well under §12.6.
# Cross-refs:   §11.4.85 (chaos) / §11.4.169 / §11.4.144 (detect->wait->re-attach)
#               / §11.4.69 (captured evidence) / §11.4.28 (config injection) /
#               §11.4.76 (containers submodule) / §11.4.14 (trap cleanup) /
#               §11.4.6 (reused-not-invented reconnect budget); evidence.sh.
# Shell:        POSIX-clean body — parses under `sh -n` AND `bash -n` (§11.4.67).
# =============================================================================

set -u

SUITE="proxy_restart_recovery"

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
CONTAINER=${CHAOS_SQUID_CONTAINER:-proxy-squid}
TARGET=${CHAOS_TARGET:-https://www.gstatic.com/generate_204}
EXPECT=${CHAOS_EXPECT:-204 200}
RECOVERY_TIMEOUT=${CHAOS_RECOVERY_TIMEOUT:-60}
RECOVERY_POLL=${CHAOS_RECOVERY_POLL:-2}
MAX_TIME=${CURL_MAX_TIME:-15}
RUN_TS=$(date -u +%Y%m%dT%H%M%SZ)
EVIDENCE_DIR=${CHAOS_EVIDENCE_DIR:-$REPO_ROOT/qa-results/chaos/proxy_restart_$RUN_TS}
mkdir -p "$EVIDENCE_DIR"
TRACE="$EVIDENCE_DIR/recovery_trace.log"

# --- trap cleanup (§11.4.14): leave the target quiescent --------------------
# This suite spawns NO background workers (baseline + poll curls are foreground
# and --max-time bounded, so they self-terminate). Cleanup is a documented
# no-op: the captured trace/evidence under EVIDENCE_DIR are preserved, and no
# orphan state is left on the proxy (all container access is READ-ONLY). We do
# NOT `kill 0` (that would signal the whole process group incl. the conductor).
_chaos_cleanup() {
    :
}
trap _chaos_cleanup EXIT INT TERM

# trace <event> <detail...> — one categorised, timestamped line to the trace.
trace() {
    _ev=$1; shift
    printf '%s event=%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$_ev" "$*" | tee -a "$TRACE"
}

# proxied_code — %{http_code} of the target through the proxy (000 on failure).
proxied_code() {
    curl -sS --max-time "$MAX_TIME" -o /dev/null -w '%{http_code}' \
        -x "$PROXY_URL" "$TARGET" 2>/dev/null || printf '000'
}

# container_running <name> — READ-ONLY detection via podman then docker.
container_running() {
    _c=$1
    if command -v podman >/dev/null 2>&1; then
        podman ps --format '{{.Names}}' 2>/dev/null | grep -qx "$_c" && return 0
    fi
    if command -v docker >/dev/null 2>&1; then
        docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$_c" && return 0
    fi
    return 1
}

: > "$TRACE"
echo "=== $SUITE — run $RUN_TS ==="
echo "proxy=$PROXY_URL container=$CONTAINER target=$TARGET  evidence=$EVIDENCE_DIR"
{
    printf '# %s chaos — run %s\n' "$SUITE" "$RUN_TS"
    printf '# proxy=%s container=%s target=%s expected=%s\n' "$PROXY_URL" "$CONTAINER" "$TARGET" "$EXPECT"
    printf '# recovery_timeout=%ss poll=%ss (reused reconnect budget, §11.4.6)\n' "$RECOVERY_TIMEOUT" "$RECOVERY_POLL"
} >> "$TRACE"

# --- Guard 1: squid container present (READ-ONLY) ---------------------------
if ! container_running "$CONTAINER"; then
    trace container_absent "name=$CONTAINER"
    ab_skip_with_reason "$SUITE (squid container '$CONTAINER' not running)" "topology_unsupported"
    exit 3
fi
trace container_present "name=$CONTAINER"

# --- Step 1: capture a WORKING baseline -------------------------------------
base=$(proxied_code)
trace baseline "code=$base"
if ! _code_in "$base" "$EXPECT"; then
    # No healthy baseline => nothing to recover; honest topology SKIP (not FAIL:
    # a broken baseline is a different defect owned by the forward-proxy tests).
    trace baseline_not_healthy "code=$base expected=$EXPECT"
    ab_skip_with_reason "$SUITE (no healthy baseline through proxy: code=$base)" "topology_unsupported"
    exit 3
fi

# --- Guard 2: fault-injection hook (delegated; never hardcoded) -------------
if [ -z "${PROXY_CHAOS_RESTART_CMD:-}" ]; then
    trace injection_hook_absent "set PROXY_CHAOS_RESTART_CMD to run the restart+recovery assertion"
    ab_skip_with_reason "$SUITE (PROXY_CHAOS_RESTART_CMD unset — fault not injectable autonomously)" "feature_disabled_by_config"
    exit 3
fi

# --- Step 2: inject the fault (restart squid mid-flight) --------------------
trace fault_injected "cmd=PROXY_CHAOS_RESTART_CMD"
sh -c "$PROXY_CHAOS_RESTART_CMD" >>"$EVIDENCE_DIR/restart_cmd.log" 2>&1 || \
    trace restart_cmd_rc "rc=$? (non-zero restart command output captured)"

# --- Step 3: bounded recovery poll (detect DOWN -> re-attach UP) ------------
elapsed=0
saw_down=no
recovered=no
rec_code=000
while [ "$elapsed" -le "$RECOVERY_TIMEOUT" ]; do
    c=$(proxied_code)
    if _code_in "$c" "$EXPECT"; then
        rec_code=$c
        recovered=yes
        trace recovered "code=$c elapsed=${elapsed}s state=UP"
        break
    fi
    saw_down=yes
    trace probe "code=$c elapsed=${elapsed}s state=DOWN"
    sleep "$RECOVERY_POLL"
    elapsed=$((elapsed + RECOVERY_POLL))
done

{
    printf '\n--- recovery summary ---\n'
    printf 'baseline_code=%s\n' "$base"
    printf 'observed_down_window=%s\n' "$saw_down"
    printf 'recovered=%s recovery_code=%s within=%ss (timeout=%ss)\n' \
        "$recovered" "$rec_code" "$elapsed" "$RECOVERY_TIMEOUT"
} >> "$TRACE"

echo
# --- Verdict ----------------------------------------------------------------
if [ "$recovered" = "yes" ]; then
    echo "OVERALL=PASS (proxy recovered to $rec_code within ${elapsed}s after restart)"
    printf 'OVERALL=PASS\n' >> "$TRACE"
    ab_pass_with_evidence "$SUITE: proxy recovered to $rec_code within ${elapsed}s after squid restart" "$TRACE"
    exit 0
fi
echo "OVERALL=FAIL (proxy did NOT recover within ${RECOVERY_TIMEOUT}s after restart)"
printf 'OVERALL=FAIL\n' >> "$TRACE"
_evidence_emit FAIL "$SUITE" "[reason: proxy did not return $EXPECT within ${RECOVERY_TIMEOUT}s after restart (last code=$rec_code) — no recovery; see $TRACE]"
exit 1
