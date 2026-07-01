#!/usr/bin/env bash
# =============================================================================
# metrics_scrape_test.sh — live Prometheus /metrics scrape proof for the control-API
# -----------------------------------------------------------------------------
# Purpose:      §11.4.115 RED_MODE-polarity guard for the control-API's Prometheus
#               /metrics endpoint (control-plane/cmd/api → the separate plaintext
#               listener enabled by CONTROL_API_METRICS_ADDR, wired by
#               docker-compose.observability.yml as service `proxy-api`).
#                 * RED_MODE=1 reproduces the "metrics not exposed" defect: it
#                   asserts the scrape FAILS against the un-wired / un-booted state
#                   (no valid Prometheus exposition). Provable NOW, before boot.
#                 * RED_MODE=0 (default) is the standing GREEN guard the conductor
#                   runs AFTER booting proxy-api: it scrapes /metrics and asserts
#                   REAL Prometheus exposition CONTENT — a known helix_proxy_ metric
#                   name present, `# HELP`/`# TYPE` lines present, the acl-decisions
#                   counter parseable — AND attempts the counter-increment-after-a-
#                   proxied-request proof. Anti-bluff: it asserts scraped metric
#                   CONTENT, NEVER merely HTTP 200 (§11.4 / §11.4.69 / §11.4.107).
# Live proof:   The conductor OWNS the live boot + scrape (§11.4.119 single owner).
#               This script performs NO `up`/boot; it only scrapes an endpoint the
#               conductor has already declared up (HELIX_OBSERVABILITY_STACK=1).
#               With defaults + nothing booted it emits an honest SKIP, never a
#               fake PASS and never a §11.4.1 bluff-FAIL.
# Usage:        GOMAXPROCS=2 nice -n 19 ionice -c 3 \
#                   bash tests/observability/metrics_scrape_test.sh
#               (the script self-re-execs under nice/ionice when available so the
#                §12.6 / resource cap holds regardless of caller.)
# Env (inputs):
#   RED_MODE                     0 = GREEN guard (default), 1 = RED reproduction.
#   HELIX_METRICS_URL            full scrape URL (default http://127.0.0.1:59090/metrics —
#                                METRICS_PORT=59090 per .env.example + prometheus.yml).
#   HELIX_OBSERVABILITY_STACK    set to 1 (by the conductor, post-boot) to declare
#                                proxy-api up. Unset ⇒ GREEN SKIPs (service not booted).
#   HELIX_PROXY_URL              HTTP proxy for the proxied-request step
#                                (default http://127.0.0.1:53128 — HTTP_PROXY_PORT).
#   HELIX_METRICS_PROBE_TARGET   URL fetched through the proxy to drive a decision
#                                (default http://target-a.internal/).
#   HELIX_METRICS_BYTEPATH_WIRED set to 1 ONCE the byte-path→api counter increment
#                                lands (metrics.go:14-17 says it is P5/P10-pending):
#                                then a flat counter after a proxied request is a
#                                HARD FAIL. Unset/0 ⇒ a flat counter is an honest
#                                feature_disabled_by_config SKIP for that sub-proof
#                                (the /metrics-exposed feature still PASSes on the
#                                exposition-content evidence).
#   HELIX_METRICS_EVIDENCE_DIR   evidence dir override (default
#                                qa-results/observability/metrics_scrape/<run-id>).
#   HELIX_PROBE_TIMEOUT          curl --max-time for probes (default 10).
# Outputs:      Structured verdict lines (PASS/FAIL/SKIP) from tests/lib/evidence.sh;
#               captured scrape artefacts under the evidence dir. Return code:
#               0 = PASS / valid-SKIP, 1 = FAIL, 2 = invalid-SKIP.
# Side-effects: Read-only scrape + (GREEN) one proxied curl. Creates a gitignored
#               qa-results/ evidence dir. NEVER boots/starts/stops containers.
# Dependencies: POSIX sh, awk, grep, curl. Sources tests/lib/evidence.sh.
# Resources:    GOMAXPROCS=2 + nice -n 19 + ionice -c 3 (self-applied when present).
# Cross-refs:   §11.4.115 (RED-baseline polarity) / §11.4.107 (liveness content) /
#               §11.4.69 (positive evidence) / §11.4.119 (single live-boot owner) /
#               §11.4.6 (no-guessing) / §11.4.108 (runtime signature). Metric names
#               control-plane/internal/api/metrics.go:35-37; listener wiring
#               control-plane/internal/api/server.go:110-158 + cmd/api/main.go:93.
# Shell:        POSIX-clean — parses under `sh -n` AND `bash -n` (§11.4.67). No
#               bash-only constructs ([[ ]], <<<, arrays, >( ), ${v^^}).
# =============================================================================

# --- resource cap: self-re-exec under nice/ionice when available (§12.6) ------
if [ "${HELIX_METRICS_NICED:-0}" != "1" ]; then
    HELIX_METRICS_NICED=1
    export HELIX_METRICS_NICED
    GOMAXPROCS=2
    export GOMAXPROCS
    _ms_nice=""
    _ms_ionice=""
    command -v nice >/dev/null 2>&1 && _ms_nice="nice -n 19"
    command -v ionice >/dev/null 2>&1 && _ms_ionice="ionice -c 3"
    if [ -n "$_ms_nice$_ms_ionice" ] && [ -x "$0" ]; then
        # shellcheck disable=SC2086
        exec $_ms_nice $_ms_ionice "$0" "$@"
    fi
fi

set -u

# --- locate repo root + source the canonical evidence helper ------------------
MS_DIR=$(cd "$(dirname "$0")" 2>/dev/null && pwd)
MS_REPO_ROOT=$(cd "$MS_DIR/../.." 2>/dev/null && pwd)   # tests/observability -> repo root
MS_EVIDENCE_LIB="$MS_REPO_ROOT/tests/lib/evidence.sh"
if [ ! -f "$MS_EVIDENCE_LIB" ]; then
    printf 'FAIL: metrics_scrape [reason: canonical evidence helper not found at %s]\n' "$MS_EVIDENCE_LIB"
    exit 1
fi
# shellcheck source=/dev/null
. "$MS_EVIDENCE_LIB"

# --- config -------------------------------------------------------------------
RED_MODE=${RED_MODE:-0}
METRICS_URL=${HELIX_METRICS_URL:-http://127.0.0.1:59090/metrics}
PROXY_URL=${HELIX_PROXY_URL:-http://127.0.0.1:53128}
PROBE_TARGET=${HELIX_METRICS_PROBE_TARGET:-http://target-a.internal/}
BYTEPATH_WIRED=${HELIX_METRICS_BYTEPATH_WIRED:-0}
PROBE_TIMEOUT=${HELIX_PROBE_TIMEOUT:-10}
RUN_ID=$(date -u +%Y%m%dT%H%M%SZ)
QA=${HELIX_METRICS_EVIDENCE_DIR:-$MS_REPO_ROOT/qa-results/observability/metrics_scrape/$RUN_ID}
mkdir -p "$QA" 2>/dev/null

# Metric names — MUST match control-plane/internal/api/metrics.go:35-37.
M_VPN_UP="helix_proxy_vpn_up"
M_ACL="helix_proxy_acl_decisions_total"
M_TUNNEL_DOWN="helix_proxy_tunnel_down_responses_total"

printf '# metrics_scrape — run-id %s (RED_MODE=%s) url=%s bytepath_wired=%s\n' \
    "$RUN_ID" "$RED_MODE" "$METRICS_URL" "$BYTEPATH_WIRED"

# scrape_metrics <out-body-file> <out-code-file>
# Curl the /metrics endpoint; write body to $1, the HTTP status code to $2.
# A transport failure yields code 000 + an empty body (never a fabricated 200).
scrape_metrics() {
    _sm_body=$1
    _sm_codef=$2
    # curl's -w always prints the code (000 on a transport failure); no `|| printf`
    # fallback (that would DOUBLE the token, e.g. 000000). Normalise an empty value
    # (ancient curl) to 000.
    : > "$_sm_body"
    _sm_code=$(curl -s --max-time "$PROBE_TIMEOUT" -o "$_sm_body" -w '%{http_code}' \
        "$METRICS_URL" 2>/dev/null)
    [ -n "$_sm_code" ] || _sm_code=000
    printf '%s' "$_sm_code" > "$_sm_codef"
}

# acl_counter_sum <body-file>
# Sum every `helix_proxy_acl_decisions_total{...} <N>` sample line (both decision
# series) → a single integer. Non-sample/# lines are ignored. Empty ⇒ 0.
acl_counter_sum() {
    awk -v m="$M_ACL" '
        $0 ~ ("^" m "\\{") { v = $NF; if (v ~ /^[0-9]+([.][0-9]+)?$/) s += v }
        END { printf "%d", s + 0 }
    ' "$1" 2>/dev/null
}

# valid_exposition <body-file> <code>
# 0 iff the response is genuine Prometheus exposition of THIS app's metrics:
# HTTP 200 + a `# HELP`/`# TYPE` pair + a real helix_proxy_ metric name. This is
# the CONTENT gate (§11.4.107) — a bare 200 with an empty/foreign body is NOT it.
valid_exposition() {
    _ve_body=$1
    _ve_code=$2
    [ "$_ve_code" = "200" ] || return 1
    [ -s "$_ve_body" ] || return 1
    grep -q '^# HELP ' "$_ve_body" || return 1
    grep -q '^# TYPE ' "$_ve_body" || return 1
    grep -q "$M_ACL" "$_ve_body" || return 1
    return 0
}

BODY="$QA/scrape_1.prom"
CODE_F="$QA/scrape_1.code"
scrape_metrics "$BODY" "$CODE_F"
CODE=$(cat "$CODE_F" 2>/dev/null)

# =============================================================================
# RED_MODE=1 — reproduce the "metrics not exposed" defect (§11.4.115 baseline).
# =============================================================================
if [ "$RED_MODE" = "1" ]; then
    {
        printf '# RED baseline — scrape of %s\n' "$METRICS_URL"
        printf 'http_code=%s\n' "$CODE"
        printf '# body (first 20 lines):\n'
        head -n 20 "$BODY" 2>/dev/null
    } > "$QA/red_baseline.txt"
    if valid_exposition "$BODY" "$CODE"; then
        # The endpoint IS serving real exposition — there is no "not exposed"
        # defect to reproduce. Refusing to fake a reproduction (§11.4.1).
        printf 'FAIL: metrics_scrape RED-baseline [reason: /metrics already serves valid exposition (code=%s) — nothing to reproduce; boot state is NOT the un-wired defect]\n' "$CODE"
        exit 1
    fi
    ab_pass_with_evidence \
        "metrics_scrape RED-baseline reproduced 'metrics not exposed' (code=$CODE, no valid helix_proxy_ exposition)" \
        "$QA/red_baseline.txt"
    exit $?
fi

# =============================================================================
# RED_MODE=0 — standing GREEN guard (run by the conductor AFTER booting proxy-api).
# =============================================================================

# Availability gate: the conductor declares the stack up via HELIX_OBSERVABILITY_STACK=1.
# Undeclared ⇒ authored-not-booted → honest topology SKIP (never a fake PASS). The
# live boot + scrape is the conductor's (§11.4.119).
if [ "${HELIX_OBSERVABILITY_STACK:-0}" != "1" ]; then
    ab_skip_with_reason \
        "metrics_scrape (proxy-api not declared booted — conductor owns the live scrape §11.4.119)" \
        "topology_unsupported"
    exit $?
fi

# Declared up: the scrape MUST yield real exposition CONTENT — else the metrics-
# not-exposed defect is live (this is the whole point of the guard) → FAIL.
if ! valid_exposition "$BODY" "$CODE"; then
    {
        printf '# GREEN guard — declared up but scrape lacks valid exposition\n'
        printf 'http_code=%s url=%s\n' "$CODE" "$METRICS_URL"
        head -n 20 "$BODY" 2>/dev/null
    } > "$QA/green_missing_exposition.txt"
    printf 'FAIL: metrics_scrape [reason: HELIX_OBSERVABILITY_STACK=1 but /metrics (code=%s) has no valid helix_proxy_ exposition — metrics NOT exposed; see %s]\n' \
        "$CODE" "$QA/green_missing_exposition.txt"
    exit 1
fi

# Hard content assertions on the known metrics (§11.4.107 — content, not 200).
MISSING=""
grep -q "$M_ACL" "$BODY"          || MISSING="$MISSING $M_ACL"
grep -q "$M_TUNNEL_DOWN" "$BODY"  || MISSING="$MISSING $M_TUNNEL_DOWN"
grep -q "^# HELP $M_ACL " "$BODY" || MISSING="$MISSING #HELP:$M_ACL"
grep -q "^# TYPE $M_ACL counter" "$BODY" || MISSING="$MISSING #TYPE:$M_ACL"
if [ -n "$MISSING" ]; then
    printf 'FAIL: metrics_scrape [reason: exposition present but missing required content:%s — see %s]\n' \
        "$MISSING" "$BODY"
    exit 1
fi
# vpn_up is a per-profile gauge: present only when >=1 profile exists. Record its
# presence honestly (§11.4.6) — absence-with-no-profiles is NOT a failure.
VPN_UP_NOTE="absent (no profiles, expected)"
grep -q "$M_VPN_UP" "$BODY" && VPN_UP_NOTE="present"

BASELINE=$(acl_counter_sum "$BODY")

# --- counter-increment-after-a-proxied-request sub-proof ----------------------
# Drive ONE real proxied request, re-scrape, compute the acl-decisions delta.
INCREMENT_VERDICT="unknown"
INCREMENT_DETAIL=""
PROXY_CODE=$(curl -s --max-time "$PROBE_TIMEOUT" -o /dev/null -w '%{http_code}' \
    -x "$PROXY_URL" "$PROBE_TARGET" 2>/dev/null)
[ -n "$PROXY_CODE" ] || PROXY_CODE=000
BODY2="$QA/scrape_2.prom"
CODE2_F="$QA/scrape_2.code"
scrape_metrics "$BODY2" "$CODE2_F"
CODE2=$(cat "$CODE2_F" 2>/dev/null)
AFTER=$(acl_counter_sum "$BODY2")
DELTA=$((AFTER - BASELINE))

{
    printf '# counter-increment sub-proof (%s)\n' "$M_ACL"
    printf 'proxied_request: curl -x %s %s -> http_code=%s\n' "$PROXY_URL" "$PROBE_TARGET" "$PROXY_CODE"
    printf 're-scrape http_code=%s\n' "$CODE2"
    printf 'acl_decisions_total baseline=%s after=%s delta=%s\n' "$BASELINE" "$AFTER" "$DELTA"
    printf 'bytepath_wired=%s\n' "$BYTEPATH_WIRED"
} > "$QA/increment.txt"

if [ "$DELTA" -gt 0 ] && [ "$CODE2" = "200" ]; then
    INCREMENT_VERDICT="pass"
    INCREMENT_DETAIL="delta=$DELTA (>0) after a proxied request"
elif [ "$BYTEPATH_WIRED" = "1" ]; then
    # The conductor declared the byte-path→api increment WIRED, yet the counter is
    # flat — a real regression → FAIL (never masked as a SKIP).
    INCREMENT_VERDICT="fail"
    INCREMENT_DETAIL="HELIX_METRICS_BYTEPATH_WIRED=1 but delta=$DELTA (proxy_code=$PROXY_CODE re-scrape_code=$CODE2)"
elif [ "$PROXY_CODE" = "000" ]; then
    # Could not drive a proxied request at all (proxy unreachable) — the increment
    # half is unverifiable this run; the exposition-content proof still stands.
    INCREMENT_VERDICT="skip"
    INCREMENT_DETAIL="proxy $PROXY_URL unreachable (code 000)"
else
    # Counter flat AND byte-path→api increment not declared wired: honest gap —
    # metrics.go:14-17 states the counters are driven by the byte path only at P5/P10.
    INCREMENT_VERDICT="skip"
    INCREMENT_DETAIL="counter flat; byte-path->api increment is P5/P10-pending (metrics.go:14-17)"
fi

printf '# vpn_up=%s | acl-counter baseline=%s after=%s delta=%s | increment=%s (%s)\n' \
    "$VPN_UP_NOTE" "$BASELINE" "$AFTER" "$DELTA" "$INCREMENT_VERDICT" "$INCREMENT_DETAIL"

# The metrics-exposed feature under test PASSes on the exposition-content evidence.
# The increment sub-proof is PASS-or-honest-SKIP today, and a HARD FAIL once the
# byte-path wiring is declared but the counter stays flat.
case "$INCREMENT_VERDICT" in
    fail)
        printf 'FAIL: metrics_scrape counter-increment [reason: %s — see %s]\n' \
            "$INCREMENT_DETAIL" "$QA/increment.txt"
        exit 1
        ;;
    pass)
        ab_pass_with_evidence \
            "metrics_scrape: real exposition (# HELP/# TYPE + $M_ACL + $M_TUNNEL_DOWN) AND counter incremented ($INCREMENT_DETAIL)" \
            "$QA/increment.txt"
        exit $?
        ;;
    *)
        # Exposition-content PASS (the feature works); increment sub-proof honestly
        # deferred. Emit the content PASS (cited to the scrape) THEN the honest SKIP.
        ab_pass_with_evidence \
            "metrics_scrape: real Prometheus exposition content (# HELP/# TYPE + $M_ACL + $M_TUNNEL_DOWN present, vpn_up $VPN_UP_NOTE)" \
            "$BODY" || exit $?
        ab_skip_with_reason \
            "metrics_scrape counter-increment ($INCREMENT_DETAIL)" \
            "feature_disabled_by_config"
        exit $?
        ;;
esac
