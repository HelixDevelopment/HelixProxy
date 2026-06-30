#!/usr/bin/env bash
# =============================================================================
# analyzer_common.sh — shared base for the dynamic data-plane anti-bluff analyzers
# -----------------------------------------------------------------------------
# Purpose:      Sourceable base library for every dynamic-mode data-plane
#               analyzer under tests/dynamic/analyzers/ and every suite under
#               tests/dynamic/suites/. It (1) sources the COMMITTED canonical
#               evidence helper tests/lib/evidence.sh READ-ONLY (never modifies
#               it — §11.4.58 file-lane), (2) provides verdict-emit + self-test
#               TAP helpers so each analyzer can prove it PASSes its golden-good
#               fixture AND FAILs its golden-bad fixture (the §11.4.107(10)
#               self-validated-analyzer discipline; an analyzer that passes its
#               own negation is a bluff gate), and (3) provides the live-stack
#               availability probe + honest SKIP that the P10 suites use so an
#               absent dynamic stack is a §11.4.69 SKIP-with-reason, NEVER a
#               fake PASS.
# Usage:        . tests/dynamic/lib/analyzer_common.sh   (source it; do not exec)
# Inputs:       Captured data-plane artefacts (tcpdump text, Squid access.log,
#               egress-IP capture, 503 body+PID pair, dns :53 capture, auth
#               probe codes). Real P10 runs feed live captures; the self-tests
#               feed the golden fixtures with NO network.
# Outputs:      Structured verdict lines on stdout:
#                 PASS: <desc> [evidence: <path-or-detail>]
#                 FAIL: <desc> [reason: <why>]
#                 SKIP: <desc> [reason: <closed-set-reason>]
#               TAP lines (ok/not ok) for the self-test harness.
# Side-effects: None at source time. The live-stack probe issues one short curl
#               ONLY when HELIX_DYNAMIC_STACK is set (the P10 path).
# Dependencies: POSIX sh, awk, grep, tr; curl (live-stack probe only).
# Cross-refs:   Constitution §11.4 / §11.4.69 / §11.4.107 / §11.4.115 / §1.1;
#               committed tests/lib/evidence.sh; design §13/§14.
# Shell:        POSIX-clean — parses under `sh -n` AND `bash -n` (§11.4.67).
#               No bash-only constructs ([[ ]], <<<, arrays, >( ), ${v^^}).
# =============================================================================

# ----------------------------------------------------------------------------
# Locate this library + the repo root + the committed evidence helper.
# ----------------------------------------------------------------------------
AC_LIB_DIR=$(cd "$(dirname "$0")" 2>/dev/null && pwd)
# When sourced from an analyzer in ../analyzers/ or a suite in ../suites/, $0 is
# the caller; resolve the dynamic-test root from this file's own location by
# falling back to a search if the caller path is unexpected.
if [ ! -f "$AC_LIB_DIR/analyzer_common.sh" ]; then
    # $0-based dir did not contain us (we were sourced); try common relatives.
    for _cand in \
        "$AC_LIB_DIR/lib" \
        "$AC_LIB_DIR/../lib" \
        "$AC_LIB_DIR/../../tests/dynamic/lib"; do
        if [ -f "$_cand/analyzer_common.sh" ]; then AC_LIB_DIR=$_cand; break; fi
    done
fi
AC_DYNAMIC_ROOT=$(cd "$AC_LIB_DIR/.." 2>/dev/null && pwd)         # tests/dynamic
AC_REPO_ROOT=$(cd "$AC_LIB_DIR/../../.." 2>/dev/null && pwd)      # repo root
AC_EVIDENCE_LIB="$AC_REPO_ROOT/tests/lib/evidence.sh"

# Source the COMMITTED canonical data-plane oracle library read-only. The
# dynamic analyzers delegate to its self-tested helpers (assert_egress_ip,
# assert_graceful_503, assert_cache_hit, assert_no_leak, wg_transfer_delta,
# ab_pass_with_evidence, ab_skip_with_reason) — reuse, never reimplement
# (§11.4.74). We NEVER modify it (§11.4.58 file-lane).
if [ -f "$AC_EVIDENCE_LIB" ]; then
    # shellcheck source=/dev/null
    . "$AC_EVIDENCE_LIB"
    AC_EVIDENCE_AVAILABLE=1
else
    AC_EVIDENCE_AVAILABLE=0
fi

# ----------------------------------------------------------------------------
# Verdict emitters (mirror evidence.sh's structured-line contract).
# ----------------------------------------------------------------------------
ac_pass() { printf 'PASS: %s %s\n' "$1" "${2:-}"; return 0; }
ac_fail() { printf 'FAIL: %s %s\n' "$1" "${2:-}"; return 1; }

# ----------------------------------------------------------------------------
# Self-test TAP harness — every analyzer proves golden-good PASS + golden-bad
# FAIL through these. AC_TESTS / AC_FAILS accumulate across the self-test.
# ----------------------------------------------------------------------------
AC_TESTS=0
AC_FAILS=0

ac_selftest_reset() { AC_TESTS=0; AC_FAILS=0; }

# ac_expect <expected-rc> <desc> -- <command...>
# Runs the command, captures its rc, emits a TAP ok/not-ok line. A "not ok"
# also prints the captured verdict on a "# verdict:" line for forensics.
ac_expect() {
    _exp=$1
    _desc=$2
    shift 2
    if [ "$1" = "--" ]; then shift; fi
    _out=$("$@" 2>&1)
    _rc=$?
    AC_TESTS=$((AC_TESTS + 1))
    if [ "$_rc" = "$_exp" ]; then
        printf 'ok %d - %s (rc=%d)\n' "$AC_TESTS" "$_desc" "$_rc"
    else
        printf 'not ok %d - %s (got rc=%d, want %s)\n' "$AC_TESTS" "$_desc" "$_rc" "$_exp"
        printf '# verdict: %s\n' "$_out"
        AC_FAILS=$((AC_FAILS + 1))
    fi
}

# ac_selftest_summary <analyzer-name>
# Emits the TAP plan + a RESULT line; returns 0 iff every assertion passed.
ac_selftest_summary() {
    printf '1..%d\n' "$AC_TESTS"
    printf '# %s: tests=%d passed=%d failed=%d\n' \
        "$1" "$AC_TESTS" "$((AC_TESTS - AC_FAILS))" "$AC_FAILS"
    if [ "$AC_FAILS" -eq 0 ]; then
        printf '# RESULT: %s self-validated — golden-good PASS AND golden-bad FAIL\n' "$1"
        return 0
    fi
    printf '# RESULT: %s SELF-TEST FAILED (%d) — analyzer is a bluff gate, do not ship\n' \
        "$1" "$AC_FAILS"
    return 1
}

# ----------------------------------------------------------------------------
# Live dynamic-stack availability — used by the P10 suites so an absent stack
# is an honest §11.4.69 SKIP (return 0, honest non-evidence), NEVER a fake PASS.
# ----------------------------------------------------------------------------
# dyn_stack_proxy_url — the HTTP proxy URL the suites drive (default Squid port).
dyn_stack_proxy_url() { printf '%s' "${HELIX_PROXY_URL:-http://127.0.0.1:53128}"; }

# dyn_live_stack_available — 0 if the operator has declared + the proxy answers.
# The dynamic stack does not exist in this repo yet (design-only); P10 sets
# HELIX_DYNAMIC_STACK=1 once the `dynamic` compose profile is up.
dyn_live_stack_available() {
    if [ "${HELIX_DYNAMIC_STACK:-0}" != "1" ]; then
        return 1
    fi
    _url=$(dyn_stack_proxy_url)
    # A single short reachability probe (CONNECT capability check).
    if command -v curl >/dev/null 2>&1; then
        if curl -s --max-time "${HELIX_PROBE_TIMEOUT:-5}" -o /dev/null \
            -x "$_url" "http://127.0.0.1/" 2>/dev/null; then
            return 0
        fi
        # Proxy declared up but unreachable — not available.
        return 1
    fi
    return 1
}

# dyn_skip_if_no_stack <suite-desc>
# Emits an honest §11.4.69 SKIP and returns 0 (valid SKIP — honest non-evidence)
# when the live dynamic stack is absent. Reason classification:
#   topology_unsupported  — HELIX_DYNAMIC_STACK not declared (stack not deployed)
#   network_unreachable_external — declared but the proxy did not answer
# Caller pattern:  dyn_skip_if_no_stack "stress" && return 0
dyn_skip_if_no_stack() {
    _desc=$1
    if dyn_live_stack_available; then
        return 1   # stack IS available — caller proceeds to the real probes
    fi
    if [ "${HELIX_DYNAMIC_STACK:-0}" != "1" ]; then
        ab_skip_with_reason "$_desc (dynamic stack not deployed — P10)" "topology_unsupported"
    else
        ab_skip_with_reason "$_desc (dynamic proxy declared but unreachable)" "network_unreachable_external"
    fi
    return 0
}

# ac_qa_dir <sub> — resolve + create a gitignored qa-results dir for evidence.
ac_qa_dir() {
    _d="$AC_REPO_ROOT/qa-results/${1:-p9-harness}"
    mkdir -p "$_d" 2>/dev/null
    printf '%s' "$_d"
}

# dyn_analyzers_dir — absolute path to the analyzers directory.
dyn_analyzers_dir() { printf '%s' "$AC_DYNAMIC_ROOT/analyzers"; }

# dyn_run_analyzer <analyzer-basename> <args...>
# Invoke an analyzer as a SUBPROCESS (fully decoupled — no positional-param
# leakage into the analyzer's source-time dispatch). Returns the analyzer's rc
# (0 PASS / 1 FAIL) and forwards its verdict line. Suites cite an analyzer
# verdict as their captured-evidence proof — NEVER a metadata-only PASS.
dyn_run_analyzer() {
    _an=$1
    shift
    sh "$(dyn_analyzers_dir)/$_an" analyze "$@"
}

# dyn_red_mode — 1 when running the §11.4.115 RED-baseline polarity (reproduce
# the defect on the pre-fix/broken artifact), 0 for the standing GREEN guard.
dyn_red_mode() { [ "${RED_MODE:-0}" = "1" ]; }
