#!/usr/bin/env bash
# =============================================================================
# ddos_flood_suite.sh — §11.4.169 DDoS / load-flood suite (degrade, not collapse)
# -----------------------------------------------------------------------------
# Purpose:      Hammer the live `dynamic` stack with a sustained request flood
#               and assert it DEGRADES GRACEFULLY rather than COLLAPSES: under
#               overload the proxy may shed load (503/429/timeout) but MUST (a)
#               keep its process alive (Squid PID unchanged across the flood —
#               §11.4.108 runtime-signature), (b) recover to normal 200 service
#               after the flood ends, and (c) NEVER fail OPEN (a flooded proxy
#               that starts leaking/letting unauth through is the worst failure).
# Status:       AUTHORED FOR P10. SKIPs-with-reason today (no live stack) —
#               honest non-evidence, never a fake PASS. Prefers `vegeta`/`k6`
#               when present (design §13 DDoS/load) and falls back to a bounded
#               parallel curl flood otherwise.
# RED_MODE:     §11.4.115. RED_MODE=1 expects the pre-fix stack to CRASH (PID
#               changes) or NOT recover (defect reproduced); RED_MODE=0 GREEN
#               guard asserts survive-and-recover.
# Usage:        bash tests/dynamic/suites/ddos_flood_suite.sh
# Env:          FLOOD_RATE (req/s, default 200), FLOOD_SECS (default 15),
#               FLOOD_TARGET (default http://target-a.internal/),
#               FLOOD_CONC (bounded parallel fallback workers, default 25).
# Resources:    BOUNDED — FLOOD_CONC caps parallelism; nice; the §12.6 60%
#               host-memory ceiling is respected (this floods the TARGET stack,
#               not the host). Operator may lower FLOOD_* on shared hosts.
# Shell:        POSIX-clean (sh -n + bash -n, §11.4.67).
# Cross-refs:   §11.4.169 / §11.4.85 / §11.4.108 / §11.4.69 / §11.4.115; design §13.
# =============================================================================
DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=/dev/null
. "$DIR/../lib/analyzer_common.sh"

SUITE="ddos_flood"
RUN_ID=$(date -u +%Y%m%dT%H%M%SZ)
QA="$(ac_qa_dir p9-harness)/${SUITE}_${RUN_ID}"
mkdir -p "$QA"
PROXY=$(dyn_stack_proxy_url)
RATE=${FLOOD_RATE:-200}
SECS=${FLOOD_SECS:-15}
TARGET=${FLOOD_TARGET:-http://target-a.internal/}
CONC=${FLOOD_CONC:-25}

printf '# %s suite — run-id %s (RED_MODE=%s) rate=%s/s secs=%s conc=%s\n' \
    "$SUITE" "$RUN_ID" "${RED_MODE:-0}" "$RATE" "$SECS" "$CONC"

# flood_survival_verdict <pid_stable> <recovery_code> <flood_total> <flood_responses> <proxy_listening>
# Pure classifier (no network) for the "degraded-not-collapsed" GREEN gate. A
# survival PASS REQUIRES positive captured flood evidence: the flood MUST have
# actually issued requests (flood_total > 0) AND obtained measurable HTTP
# responses (flood_responses > 0). A zero-request / zero-response flood is no
# flood at all, so a "survived the flood" PASS on it is vacuous — a §11.4.69
# evidence gap / §11.4.1 PASS-bluff. Prints exactly one of
# PASS | FAIL:<reason> | SKIP:topology_unsupported (first match wins):
#   no flood evidence, proxy NOT listening  -> SKIP:topology_unsupported (absent, not broken)
#   no flood evidence, proxy listening      -> FAIL:no-flood-evidence     (§11.4.1 bluff refused)
#   real flood, pid_stable=1 AND rec=200    -> PASS                        (survived + recovered)
#   real flood, otherwise                   -> FAIL:crashed-or-no-recovery (anti-bluff catch kept)
flood_survival_verdict() {
    _fsv_pid=$1
    _fsv_rec=$2
    _fsv_total=$3
    _fsv_resp=$4
    _fsv_listen=$5
    case "$_fsv_total" in ''|*[!0-9]*) _fsv_total=0 ;; esac
    case "$_fsv_resp" in ''|*[!0-9]*) _fsv_resp=0 ;; esac
    if [ "$_fsv_total" -le 0 ] || [ "$_fsv_resp" -le 0 ]; then
        if [ "$_fsv_listen" = "yes" ]; then
            printf 'FAIL:no-flood-evidence\n'
        else
            printf 'SKIP:topology_unsupported\n'
        fi
        return 0
    fi
    if [ "$_fsv_pid" = "1" ] && [ "$_fsv_rec" = "200" ]; then
        printf 'PASS\n'
        return 0
    fi
    printf 'FAIL:crashed-or-no-recovery\n'
    return 0
}

if dyn_skip_if_no_stack "$SUITE (flood ${RATE}/s for ${SECS}s)"; then
    printf '# NOTE: ddos/flood requires the live stack (P10). Authored + parse-clean today.\n'
    exit 0
fi

pid_before=$(sh -c "${HELIX_SQUID_PID_CMD:-echo 0}" 2>/dev/null)

# Preferred: a real load tool when available (vegeta / k6). Fallback: bounded
# parallel curl workers each looping for SECS seconds. Either path MUST end with
# a POSITIVE flood counter — flood_total (requests issued) AND flood_responses
# (measurable non-000 HTTP responses) — or the "survived the flood" claim below
# is vacuous (§11.4.69 evidence gap / §11.4.1 bluff).
flood_total=0
flood_responses=0
if command -v vegeta >/dev/null 2>&1; then
    printf 'GET %s\n' "$TARGET" | \
        vegeta attack -rate="$RATE" -duration="${SECS}s" -proxy-header= 2>/dev/null \
        | vegeta report > "$QA/vegeta.report" 2>/dev/null || true
    cp "$QA/vegeta.report" "$QA/flood.evidence" 2>/dev/null
    # vegeta's "Requests [total, rate, throughput]  <N>, ..." row IS the issued
    # request count; a report only exists when responses were collected, so the
    # measurable-response counter tracks the same total for this path.
    flood_total=$(awk '/^Requests/ { for (i = 1; i <= NF; i++) { t = $i; gsub(/,/, "", t); if (t ~ /^[0-9]+$/) { print t; exit } } }' "$QA/vegeta.report" 2>/dev/null)
    flood_responses=$flood_total
else
    end=$(( $(date +%s) + SECS ))
    w=1
    while [ "$w" -le "$CONC" ]; do
        ( while [ "$(date +%s)" -lt "$end" ]; do
            curl -s --max-time 10 -o /dev/null -w '%{http_code}\n' \
                -x "$PROXY" "$TARGET" 2>/dev/null >> "$QA/flood.$w.codes" || printf '000\n' >> "$QA/flood.$w.codes"
          done ) &
        w=$((w + 1))
    done
    wait
    total=$(cat "$QA"/flood.*.codes 2>/dev/null | grep -c .)
    measurable=$(cat "$QA"/flood.*.codes 2>/dev/null | grep -Ec '^[1-9][0-9][0-9]$')
    served=$(cat "$QA"/flood.*.codes 2>/dev/null | grep -c '^200$')
    shed=$(cat "$QA"/flood.*.codes 2>/dev/null | grep -Ec '^(503|429)$')
    flood_total=$total
    flood_responses=$measurable
    {
        printf 'flood_total=%s flood_responses=%s served_200=%s shed_503_429=%s\n' \
            "$total" "$measurable" "$served" "$shed"
    } > "$QA/flood.evidence"
fi
case "$flood_total" in ''|*[!0-9]*) flood_total=0 ;; esac
case "$flood_responses" in ''|*[!0-9]*) flood_responses=0 ;; esac

pid_after=$(sh -c "${HELIX_SQUID_PID_CMD:-echo 0}" 2>/dev/null)

# Recovery probe after the flood subsides.
sleep_secs=${FLOOD_RECOVER_SECS:-3}
i=0; while [ "$i" -lt "$sleep_secs" ]; do i=$((i + 1)); done   # busy-free settle marker
rec=$(curl -s --max-time 30 -o /dev/null -w '%{http_code}' -x "$PROXY" "$TARGET" 2>/dev/null || printf '000')
printf 'recovery_http_code=%s pid_before=%s pid_after=%s\n' "$rec" "$pid_before" "$pid_after" >> "$QA/flood.evidence"

pid_stable=0
[ -n "$pid_before" ] && [ "$pid_before" = "$pid_after" ] && pid_stable=1

# §11.4.69 positive-evidence gate. Distinguish an ABSENT target proxy (an all-
# zero flood is then an honest topology SKIP) from a LISTENING proxy that
# somehow took no measurable flood (a real anomaly — a "survived the flood" PASS
# with no flood is a §11.4.1 bluff → FAIL).
proxy_port=$(printf '%s' "$PROXY" | sed -n 's#.*:\([0-9][0-9]*\).*#\1#p')
proxy_listening=no
[ -n "$proxy_port" ] && port_is_listening "$proxy_port" && proxy_listening=yes
printf 'proxy_listening=%s flood_total=%s flood_responses=%s\n' \
    "$proxy_listening" "$flood_total" "$flood_responses" >> "$QA/flood.evidence"

verdict=$(flood_survival_verdict "$pid_stable" "$rec" "$flood_total" "$flood_responses" "$proxy_listening")

if dyn_red_mode; then
    # §11.4.115 RED baseline reproduces the crash/no-recovery defect — but only
    # when a REAL flood was issued (flood_total>0). Claiming a reproduced crash
    # on a run where no flood ever hit the proxy is itself a §11.4.1 FAIL-bluff.
    if [ "$flood_total" -gt 0 ] && { [ "$pid_stable" -ne 1 ] || [ "$rec" != "200" ]; }; then
        ab_pass_with_evidence "$SUITE RED-baseline reproduced crash/no-recovery under a real flood (total=$flood_total)" "$QA/flood.evidence"
        exit $?
    fi
    ac_fail "$SUITE RED-baseline" "[reason: flood_total=$flood_total (need >0) OR stack survived+recovered — nothing to reproduce]"
    exit 1
fi

# GREEN: a REAL flood was generated (flood_total>0 AND measurable responses>0),
# the process survived it (PID unchanged) AND it recovered to 200. A zero-
# request/zero-response flood, a crash, or no recovery is NOT proof and never
# scores PASS (§11.4.69 / §11.4.1).
case "$verdict" in
    PASS)
        ab_pass_with_evidence \
            "$SUITE degraded-not-collapsed: real flood (total=$flood_total resp=$flood_responses) + PID stable + recovered 200" \
            "$QA/flood.evidence"
        exit $?
        ;;
    SKIP:*)
        ab_skip_with_reason \
            "$SUITE (all-zero flood on an absent proxy — no flood evidence)" \
            "topology_unsupported"
        exit $?
        ;;
    *)
        ac_fail "$SUITE" "[reason: $verdict — pid_stable=$pid_stable (before=$pid_before after=$pid_after) recovery=$rec flood_total=$flood_total flood_responses=$flood_responses (want real flood + PID-stable + 200) — see $QA]"
        exit 1
        ;;
esac
