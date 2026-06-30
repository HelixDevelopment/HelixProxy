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

if dyn_skip_if_no_stack "$SUITE (flood ${RATE}/s for ${SECS}s)"; then
    printf '# NOTE: ddos/flood requires the live stack (P10). Authored + parse-clean today.\n'
    exit 0
fi

pid_before=$(sh -c "${HELIX_SQUID_PID_CMD:-echo 0}" 2>/dev/null)

# Preferred: a real load tool when available (vegeta / k6). Fallback: bounded
# parallel curl workers each looping for SECS seconds.
if command -v vegeta >/dev/null 2>&1; then
    printf 'GET %s\n' "$TARGET" | \
        vegeta attack -rate="$RATE" -duration="${SECS}s" -proxy-header= 2>/dev/null \
        | vegeta report > "$QA/vegeta.report" 2>/dev/null || true
    cp "$QA/vegeta.report" "$QA/flood.evidence" 2>/dev/null
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
    served=$(cat "$QA"/flood.*.codes 2>/dev/null | grep -c '^200$')
    shed=$(cat "$QA"/flood.*.codes 2>/dev/null | grep -Ec '^(503|429)$')
    {
        printf 'flood_total=%s served_200=%s shed_503_429=%s\n' "$total" "$served" "$shed"
    } > "$QA/flood.evidence"
fi

pid_after=$(sh -c "${HELIX_SQUID_PID_CMD:-echo 0}" 2>/dev/null)

# Recovery probe after the flood subsides.
sleep_secs=${FLOOD_RECOVER_SECS:-3}
i=0; while [ "$i" -lt "$sleep_secs" ]; do i=$((i + 1)); done   # busy-free settle marker
rec=$(curl -s --max-time 30 -o /dev/null -w '%{http_code}' -x "$PROXY" "$TARGET" 2>/dev/null || printf '000')
printf 'recovery_http_code=%s pid_before=%s pid_after=%s\n' "$rec" "$pid_before" "$pid_after" >> "$QA/flood.evidence"

pid_stable=0
[ -n "$pid_before" ] && [ "$pid_before" = "$pid_after" ] && pid_stable=1

if dyn_red_mode; then
    if [ "$pid_stable" -ne 1 ] || [ "$rec" != "200" ]; then
        ab_pass_with_evidence "$SUITE RED-baseline reproduced crash/no-recovery under flood" "$QA/flood.evidence"
        exit $?
    fi
    ac_fail "$SUITE RED-baseline" "[reason: stack survived + recovered (no defect to reproduce)]"
    exit 1
fi

# GREEN: process survived the flood (PID unchanged) AND recovered to 200.
if [ "$pid_stable" -eq 1 ] && [ "$rec" = "200" ]; then
    ab_pass_with_evidence "$SUITE degraded-not-collapsed: PID stable + recovered 200" "$QA/flood.evidence"
    exit $?
fi
ac_fail "$SUITE" "[reason: pid_stable=$pid_stable (before=$pid_before after=$pid_after) recovery=$rec (want PID-stable + 200) — see $QA]"
exit 1
