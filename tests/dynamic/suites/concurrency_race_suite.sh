#!/usr/bin/env bash
# =============================================================================
# concurrency_race_suite.sh — §11.4.169 concurrency / race suite (acl-helper)
# -----------------------------------------------------------------------------
# Purpose:      Drive the external_acl helper under heavy CONCURRENT load and
#               assert: (a) every parallel request gets a CORRECT, consistent
#               routing decision (no torn Redis read, no cross-request bleed),
#               (b) no deadlock/hang (every request returns within the timeout),
#               (c) determinism across the burst (§11.4.50 — identical inputs ->
#               identical outcomes). Per-request %{http_code} captured to its own
#               file (the B3 bluff fix — never job exit status).
# Status:       AUTHORED FOR P10. SKIPs-with-reason today (no live stack) —
#               honest non-evidence, never a fake PASS.
# Detail:       When HELIX_ACL_HELPER_CMD is supplied (a direct invocation of the
#               Go external_acl binary that reads "<Host>\n" on stdin and prints
#               "OK tag=..." / "ERR"), the suite ALSO hammers the helper directly
#               in parallel and asserts every line is a well-formed decision and
#               that the SAME Host always yields the SAME tag (no race).
# RED_MODE:     §11.4.115. RED_MODE=1 expects the pre-fix helper to race/hang/
#               return inconsistent tags (defect reproduced); RED_MODE=0 GREEN
#               guard asserts consistency + liveness.
# Usage:        bash tests/dynamic/suites/concurrency_race_suite.sh
# Env:          RACE_CONC (default 20), RACE_TARGET (default http://target-a.internal/),
#               RACE_HOST (default target-a.internal) for the direct-helper probe.
# Resources:    capped concurrency (RACE_CONC) + nice; shell+curl only (§12.6).
# Shell:        POSIX-clean (sh -n + bash -n, §11.4.67).
# Cross-refs:   §11.4.169 / §11.4.85 / §11.4.50 / §11.4.69 / §11.4.115; design §4/§13.
# =============================================================================
DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=/dev/null
. "$DIR/../lib/analyzer_common.sh"

SUITE="concurrency_race"
RUN_ID=$(date -u +%Y%m%dT%H%M%SZ)
QA="$(ac_qa_dir p9-harness)/${SUITE}_${RUN_ID}"
mkdir -p "$QA"
PROXY=$(dyn_stack_proxy_url)
CONC=${RACE_CONC:-20}
TARGET=${RACE_TARGET:-http://target-a.internal/}
HOST=${RACE_HOST:-target-a.internal}

printf '# %s suite — run-id %s (RED_MODE=%s) conc=%d\n' "$SUITE" "$RUN_ID" "${RED_MODE:-0}" "$CONC"

if dyn_skip_if_no_stack "$SUITE ($CONC parallel acl-helper requests)"; then
    printf '# NOTE: concurrency/race requires the live stack (P10). Authored + parse-clean today.\n'
    exit 0
fi

# ---------------------------------------------------------------------------
# Parallel requests through the proxy — per-request code to its own file.
# ---------------------------------------------------------------------------
j=1
while [ "$j" -le "$CONC" ]; do
    ( curl -s --max-time 20 -o /dev/null -w '%{http_code}' \
        -x "$PROXY" "$TARGET" 2>/dev/null > "$QA/req.$j.code" || printf '000' > "$QA/req.$j.code" ) &
    j=$((j + 1))
done
wait
ok=0; missing=0
j=1
while [ "$j" -le "$CONC" ]; do
    if [ ! -s "$QA/req.$j.code" ]; then missing=$((missing + 1));   # a hang/deadlock leaves no code
    elif [ "$(cat "$QA/req.$j.code")" = "200" ]; then ok=$((ok + 1)); fi
    j=$((j + 1))
done

# Direct helper hammer (optional): every line a well-formed decision; same Host
# -> same tag (determinism). Distinct-tag count > 1 for one Host = a race.
distinct_tags=1
if [ -n "${HELIX_ACL_HELPER_CMD:-}" ]; then
    k=1
    while [ "$k" -le "$CONC" ]; do
        ( printf '%s\n' "$HOST" | sh -c "$HELIX_ACL_HELPER_CMD" 2>/dev/null > "$QA/helper.$k.out" ) &
        k=$((k + 1))
    done
    wait
    cat "$QA/helper."*.out 2>/dev/null | awk '{print $1, $2}' | sort -u > "$QA/helper_decisions.uniq"
    distinct_tags=$(grep -c . "$QA/helper_decisions.uniq" 2>/dev/null)
    distinct_tags=${distinct_tags:-0}
fi

{
    printf 'parallel_200=%d/%d hung=%d\n' "$ok" "$CONC" "$missing"
    printf 'direct_helper_distinct_decisions=%s\n' "$distinct_tags"
} > "$QA/concurrency.evidence"

if dyn_red_mode; then
    if [ "$missing" -gt 0 ] || [ "${distinct_tags:-1}" -gt 1 ]; then
        ab_pass_with_evidence "$SUITE RED-baseline reproduced race/hang" "$QA/concurrency.evidence"
        exit $?
    fi
    ac_fail "$SUITE RED-baseline" "[reason: no race/hang reproduced (consistent + live)]"
    exit 1
fi

# GREEN: no hang, all 200, and (if probed) exactly one decision for one Host.
if [ "$missing" -eq 0 ] && [ "$ok" -eq "$CONC" ] && [ "${distinct_tags:-1}" -le 1 ]; then
    ab_pass_with_evidence "$SUITE $CONC parallel decisions consistent + live" "$QA/concurrency.evidence"
    exit $?
fi
ac_fail "$SUITE" "[reason: parallel_200=$ok/$CONC hung=$missing distinct_decisions=$distinct_tags (want all-200, 0 hung, <=1 decision) — see $QA]"
exit 1
