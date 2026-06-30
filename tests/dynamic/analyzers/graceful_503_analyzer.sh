#!/usr/bin/env bash
# =============================================================================
# graceful_503_analyzer.sh — signal 2: branded 503 + Squid PID UNCHANGED
# -----------------------------------------------------------------------------
# Signal:       graceful degradation (§11.4.69 network_connectivity; design
#               §10/§13 graceful_503; research §4; §11.4.108 runtime-signature).
# Oracle:       When the target tunnel is DOWN, Squid must return an intentional,
#               BRANDED 503 (ERR_TUNNEL_DOWN body) AND keep the SAME PID across
#               the request (it did NOT crash/restart). Delegates the decision to
#               the COMMITTED, self-tested evidence.sh:assert_graceful_503 via its
#               documented unit-test seams (EVIDENCE_503_CODE_OVERRIDE +
#               EVIDENCE_503_BODY_FILE), feeding a captured probe manifest.
# golden-good:  http_code=503, branded body, pid_before == pid_after -> PASS.
# golden-BAD:   pid changed (crash) OR http_code=200 (leak) -> MUST FAIL.
# Manifest:     key=val text file (one per line):
#                 http_code=503
#                 body_file=503_body.html      (resolved relative to manifest dir)
#                 pid_before=12345
#                 pid_after=12345
#                 marker=tunnel                (optional branded-text marker)
# Usage:        graceful_503_analyzer.sh analyze <manifest-file>
#               graceful_503_analyzer.sh --selftest        (default action)
# Output:       PASS:/FAIL: verdict; rc 0 = PASS, 1 = FAIL.
# Anti-bluff:   a 503 from a CRASHED proxy is not graceful — the PID-unchanged
#               check is the §11.4.108 runtime-signature that distinguishes them.
# Shell:        POSIX-clean (sh -n + bash -n, §11.4.67).
# Cross-refs:   §11.4.69 / §11.4.107 / §11.4.108 / §11.4.115; tests/lib/evidence.sh.
# =============================================================================
_ANZ_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=/dev/null
. "$_ANZ_DIR/../lib/analyzer_common.sh"
_FIX="$_ANZ_DIR/fixtures/graceful_503"

# _g503_manifest_get <manifest> <key>
_g503_manifest_get() {
    awk -F= -v k="$2" '$1 == k { sub(/^[^=]*=/, ""); print; exit }' "$1" 2>/dev/null
}

# analyze_graceful_503 <manifest-file>
analyze_graceful_503() {
    manifest=$1
    if [ -z "$manifest" ] || [ ! -f "$manifest" ]; then
        ac_fail "graceful_503" "[reason: probe manifest missing: ${manifest:-<none>}]"
        return 1
    fi
    if [ "$AC_EVIDENCE_AVAILABLE" != "1" ]; then
        ac_fail "graceful_503" "[reason: committed tests/lib/evidence.sh not found — cannot delegate]"
        return 1
    fi
    mdir=$(cd "$(dirname "$manifest")" && pwd)
    code=$(_g503_manifest_get "$manifest" http_code)
    body=$(_g503_manifest_get "$manifest" body_file)
    pidb=$(_g503_manifest_get "$manifest" pid_before)
    pida=$(_g503_manifest_get "$manifest" pid_after)
    marker=$(_g503_manifest_get "$manifest" marker)
    # Resolve the body file relative to the manifest dir if not absolute.
    case "$body" in
        /*) : ;;
        *)  body="$mdir/$body" ;;
    esac
    # Drive the canonical oracle through its unit-test seams (no network).
    EVIDENCE_503_CODE_OVERRIDE=$code \
    EVIDENCE_503_BODY_FILE=$body \
    EVIDENCE_503_BODY_MARKER=${marker:-tunnel} \
        assert_graceful_503 "$(dyn_stack_proxy_url)" "http://blocked.example" "$pidb" "$pida"
}

_selftest_graceful_503() {
    ac_selftest_reset
    printf '# graceful_503_analyzer self-test\n'
    ac_expect 0 "golden-good: 503 + branded body + PID unchanged -> PASS" \
        -- analyze_graceful_503 "$_FIX/golden_good.manifest"
    ac_expect 1 "golden-BAD: PID changed (proxy crashed) -> FAIL" \
        -- analyze_graceful_503 "$_FIX/golden_bad_pidchanged.manifest"
    ac_expect 1 "golden-BAD: HTTP 200 leaked (not 503) -> FAIL" \
        -- analyze_graceful_503 "$_FIX/golden_bad_200.manifest"
    ac_expect 1 "golden-BAD: blank 503 body (not branded) -> FAIL" \
        -- analyze_graceful_503 "$_FIX/golden_bad_blankbody.manifest"
    ac_expect 1 "negative: missing manifest -> FAIL" \
        -- analyze_graceful_503 "$_FIX/does_not_exist.manifest"
    ac_selftest_summary "graceful_503_analyzer"
}

case "${1:-}" in
    analyze) shift; analyze_graceful_503 "$@" ;;
    --selftest|selftest|"") _selftest_graceful_503 ;;
    *) analyze_graceful_503 "$@" ;;
esac
