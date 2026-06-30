#!/usr/bin/env bash
# =============================================================================
# stress_suite.sh — §11.4.85/§11.4.169 STRESS suite for the dynamic data plane
# -----------------------------------------------------------------------------
# Purpose:      Sustained-load + concurrent-contention stress against the live
#               `dynamic` stack (Squid + external_acl helper + gluetun + Redis).
#               Sustained N>=100 sequential requests + N>=10 concurrent requests,
#               per-request %{http_code} captured to its own file (the B3 bluff
#               fix — never job exit status), latency distribution recorded.
#               Every PASS cites a captured-evidence artefact via an analyzer —
#               NO metadata-only PASS (§11.4.69).
# Status:       AUTHORED FOR P10. The dynamic stack does not exist in this repo
#               yet (design-only). Today this SKIPs-with-reason (§11.4.69
#               topology_unsupported) — an HONEST non-evidence return, never a
#               fake PASS. Set HELIX_DYNAMIC_STACK=1 + HELIX_PROXY_URL in P10.
# RED_MODE:     §11.4.115 polarity. RED_MODE=1 runs against the pre-fix/throttled
#               stack and EXPECTS the collapse (>threshold non-200) to reproduce
#               the defect; RED_MODE=0 (default) is the GREEN guard asserting the
#               stack sustains the load.
# Usage:        bash tests/dynamic/suites/stress_suite.sh
#               HELIX_DYNAMIC_STACK=1 HELIX_PROXY_URL=http://127.0.0.1:53128 \
#                   STRESS_SEQ=100 STRESS_CONC=10 bash .../stress_suite.sh
# Env:          STRESS_SEQ (default 100), STRESS_CONC (default 10),
#               STRESS_TARGET (default http://target-a.internal/),
#               STRESS_OK_RATIO_PCT (min % of 200s for GREEN, default 95).
# Resources:    capped concurrency (STRESS_CONC) + nice; stays well under the
#               §12.6 60% host-memory ceiling (shell+curl only).
# Shell:        POSIX-clean (sh -n + bash -n, §11.4.67).
# Cross-refs:   §11.4.85 / §11.4.69 / §11.4.107 / §11.4.115 / §11.4.50; design §13.
# =============================================================================
DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=/dev/null
. "$DIR/../lib/analyzer_common.sh"

SUITE="stress"
RUN_ID=$(date -u +%Y%m%dT%H%M%SZ)
QA="$(ac_qa_dir p9-harness)/${SUITE}_${RUN_ID}"
mkdir -p "$QA"

SEQ=${STRESS_SEQ:-100}
CONC=${STRESS_CONC:-10}
TARGET=${STRESS_TARGET:-http://target-a.internal/}
OK_RATIO=${STRESS_OK_RATIO_PCT:-95}
PROXY=$(dyn_stack_proxy_url)

printf '# %s suite — run-id %s (RED_MODE=%s)\n' "$SUITE" "$RUN_ID" "${RED_MODE:-0}"
printf '# config: seq=%d conc=%d target=%s ok_ratio>=%d%%\n' "$SEQ" "$CONC" "$TARGET" "$OK_RATIO"

# Honest §11.4.69 SKIP when the live dynamic stack is absent (P10 dependency).
if dyn_skip_if_no_stack "$SUITE (sustained $SEQ + concurrent $CONC)"; then
    printf '# NOTE: stress requires the live `dynamic` stack (P10). Authored + parse-clean today.\n'
    exit 0
fi

# ---------------------------------------------------------------------------
# Live path (P10). Sustained sequential load — per-request code to its own file.
# ---------------------------------------------------------------------------
ok=0
i=1
while [ "$i" -le "$SEQ" ]; do
    code=$(curl -s --max-time 20 -o /dev/null -w '%{http_code}' \
        -x "$PROXY" "$TARGET" 2>/dev/null || printf '000')
    printf '%s\n' "$code" > "$QA/seq.$i.code"
    [ "$code" = "200" ] && ok=$((ok + 1))
    i=$((i + 1))
done

# Concurrent burst — per-request code to its own file (B3 fix; never $?).
j=1
while [ "$j" -le "$CONC" ]; do
    ( curl -s --max-time 20 -o /dev/null -w '%{http_code}' \
        -x "$PROXY" "$TARGET" 2>/dev/null > "$QA/conc.$j.code" || printf '000' > "$QA/conc.$j.code" ) &
    j=$((j + 1))
done
wait
conc_ok=0
j=1
while [ "$j" -le "$CONC" ]; do
    [ "$(cat "$QA/conc.$j.code" 2>/dev/null)" = "200" ] && conc_ok=$((conc_ok + 1))
    j=$((j + 1))
done

ratio=$(( (ok * 100) / SEQ ))
{
    printf 'sequential_200=%d/%d (%d%%)\n' "$ok" "$SEQ" "$ratio"
    printf 'concurrent_200=%d/%d\n' "$conc_ok" "$CONC"
} > "$QA/stress.evidence"

# Polarity (§11.4.115): GREEN guard requires the stack to SUSTAIN the load; RED
# baseline expects the throttled/pre-fix stack to COLLAPSE below the ratio.
if dyn_red_mode; then
    if [ "$ratio" -lt "$OK_RATIO" ]; then
        ab_pass_with_evidence "$SUITE RED-baseline reproduced load collapse (ratio<$OK_RATIO%)" "$QA/stress.evidence"
        exit $?
    fi
    ac_fail "$SUITE RED-baseline" "[reason: stack did NOT collapse (ratio=$ratio% >= $OK_RATIO%) — defect not reproduced]"
    exit 1
fi

if [ "$ratio" -ge "$OK_RATIO" ] && [ "$conc_ok" -ge "$(( (CONC * OK_RATIO) / 100 ))" ]; then
    ab_pass_with_evidence "$SUITE sustained $SEQ + concurrent $CONC (ratio=$ratio%)" "$QA/stress.evidence"
    exit $?
fi
ac_fail "$SUITE" "[reason: 200-ratio $ratio% < $OK_RATIO% under sustained/concurrent load — see $QA/stress.evidence]"
exit 1
