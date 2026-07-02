#!/bin/sh
#######################################################################
# §11.4.135 regression guard — chaos_suite C1 no-leak arg-shape + empty-capture
# (task #73; dynamic-audit ac3f1c89; §11.4.107(10) / §11.4.6 / §11.4.120).
#
# Purpose:
#   Prove chaos_suite.sh's C1 no-leak sub-signal can NEVER vacuously PASS while a
#   REAL leak is present. Two DEMONSTRATED bluffs this guards against:
#
#   F-A (arg SHAPE): the pre-fix call site passed the full URL $TARGET
#       (http://target-a.internal/) to no_leak_analyzer. The analyzer's raw-text
#       branch counts leak packets via `grep -c -- " IP .*$target"`, but a tcpdump
#       line NEVER carries a scheme-prefixed URL — so the count was always 0 and a
#       real leak passed as "no leak". Fix: chaos_target_leak_key() strips
#       scheme/path/port (and resolves the host to an IP) so the analyzer greps the
#       host/IP a tcpdump line actually carries.
#
#   F-B (absence-as-evidence): the pre-fix `leak_rc=0; [ -n "$cap" ] && {...}` left
#       leak_rc=0 when the uplink capture was empty/absent — so C1 reported a
#       no-leak PASS with ZERO evidence. Fix: chaos_leak_signal() returns rc 2
#       (UNEVALUATED) for an empty/absent capture, which the suite turns into an
#       honest §11.4.69 SKIP — never a no-leak PASS.
#
# What it actually does (drives the REAL analyzer + the REAL fix functions — no
# divergent copy, §11.4.107(10)); hermetic, no live stack, no network:
#   - REAL analyzer: sh tests/dynamic/analyzers/no_leak_analyzer.sh analyze ...
#   - REAL fix logic: chaos_target_leak_key / chaos_leak_signal, obtained by
#     sourcing chaos_suite.sh with CHAOS_SOURCE_ONLY=1 (functions only, no body).
#
# §11.4.115 polarity switch (RED_MODE):
#   RED_MODE=1 (reproduce) — PASS iff the DEFECT reproduces:
#       * F-A: the REAL analyzer, given the URL as the key on a leaked capture,
#              returns rc 0 (vacuous PASS — the leak is MISSED); AND
#       * F-B: the faithful pre-fix replica leaves leak_rc=0 for an empty capture.
#   RED_MODE=0 (default GREEN guard) — PASS iff the FIX holds:
#       * chaos_target_leak_key strips a URL to its bare host/IP;
#       * chaos_leak_signal(leaked, URL) -> rc 1 (LEAK CAUGHT via the resolved key);
#       * chaos_leak_signal(clean,  URL) -> rc 0 (real no-leak, no false-FAIL);
#       * chaos_leak_signal(empty,  URL) -> rc 2 (UNEVALUATED, never a silent PASS).
#
# Usage:
#   tests/regression/chaos_no_leak_argshape_test.sh            # GREEN guard
#   RED_MODE=1 tests/regression/chaos_no_leak_argshape_test.sh # reproduce defect
#
# Inputs:   RED_MODE (env, default 0). No CLI args.
# Outputs:  [PASS]/[FAIL] line on stdout + evidence under
#           qa-results/regression/chaos_no_leak_argshape/. Exit 0=PASS, 1=FAIL.
# Dependencies: sh (POSIX), grep, awk, mktemp.
# Cross-references:
#   - Fix: tests/dynamic/suites/chaos_suite.sh chaos_target_leak_key() +
#     chaos_leak_signal() + the C1 body (F-A arg-shape + F-B unevaluated SKIP).
#   - Real analyzer under test: tests/dynamic/analyzers/no_leak_analyzer.sh.
# Shell: POSIX-clean (sh -n + bash -n, §11.4.67).
#######################################################################
set -eu

RED_MODE="${RED_MODE:-0}"
REPO_ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
ANALYZER="$REPO_ROOT/tests/dynamic/analyzers/no_leak_analyzer.sh"
EVID_DIR="$REPO_ROOT/qa-results/regression/chaos_no_leak_argshape"
mkdir -p "$EVID_DIR"
EVID_FILE="$EVID_DIR/chaos_no_leak_argshape.$$.txt"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT INT TERM

TARGET_IP="93.184.216.34"
TARGET_URL="http://$TARGET_IP/"

# Synthetic REAL-uplink captures (raw tcpdump text -> the analyzer's target-filter
# branch). LEAKED = one packet to the target; CLEAN = only unrelated-host chatter.
LEAKED="$WORK/leaked.cap"
CLEAN="$WORK/clean.cap"
printf '13:50:00.000001 IP 192.168.1.50.40000 > 192.168.1.1.53: 1+ A? ntp.pool.org. (30)\n' >"$LEAKED"
printf '13:50:02.500004 IP 192.168.1.50.51234 > %s.443: Flags [S], seq 9001, win 64240, length 0\n' "$TARGET_IP" >>"$LEAKED"
printf '13:50:00.000001 IP 192.168.1.50.40000 > 192.168.1.1.53: 1+ A? ntp.pool.org. (30)\n' >"$CLEAN"
printf '13:50:01.000003 IP 192.168.1.50.22 > 192.168.1.10.51999: Flags [P.], length 120\n' >>"$CLEAN"

# Load the REAL fix functions (chaos_target_leak_key / chaos_leak_signal) + the
# analyzer_common helpers, exactly as the suite defines them — no divergent copy.
. "$REPO_ROOT/tests/dynamic/lib/analyzer_common.sh"
CHAOS_SOURCE_ONLY=1 . "$REPO_ROOT/tests/dynamic/suites/chaos_suite.sh"

# rc-capturing runner (set -e safe): _rc <label> <cmd...> ; sets GOT
_rc() { _lbl=$1; shift; GOT=0; "$@" >/dev/null 2>&1 || GOT=$?; }

verdict=FAIL
exit_code=1
{
    echo "chaos C1 no-leak arg-shape + empty-capture guard — §11.4.107(10)/§11.4.6/§11.4.120"
    echo "timestamp_utc: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "RED_MODE: $RED_MODE"
    echo "target_url: $TARGET_URL  target_ip: $TARGET_IP"
} >"$EVID_FILE"

if [ "$RED_MODE" = "1" ]; then
    # --- Reproduce the DEFECT through the REAL analyzer + the pre-fix replica. ---
    # F-A: URL passed AS the analyzer key on a leaked capture -> vacuous PASS (rc 0).
    _rc "fa" sh "$ANALYZER" analyze "$LEAKED" "$TARGET_URL"; fa_rc=$GOT
    # F-B: faithful pre-fix one-liner: empty cap leaves leak_rc=0 (no-leak assumed).
    _cap=""; fb_leak_rc=0; [ -n "$_cap" ] && fb_leak_rc=1
    {
        echo "F-A analyzer(URL, leaked) rc: $fa_rc  (defect: 0 = vacuous PASS, leak MISSED)"
        echo "F-B pre-fix empty-cap leak_rc: $fb_leak_rc  (defect: 0 = no-leak assumed)"
    } >>"$EVID_FILE"
    if [ "$fa_rc" -eq 0 ] && [ "$fb_leak_rc" -eq 0 ]; then
        verdict=PASS; exit_code=0
        msg="RED reproduced: URL-key -> vacuous no-leak PASS on a REAL leak (rc=$fa_rc) AND empty capture assumed no-leak (leak_rc=$fb_leak_rc)"
    else
        msg="RED could-not-reproduce: fa_rc=$fa_rc fb_leak_rc=$fb_leak_rc — §11.4.7 finding"
    fi
else
    # --- Assert the FIX holds through the REAL fix functions + REAL analyzer. ---
    key="$(chaos_target_leak_key "http://$TARGET_IP:8080/p?a=1")"     # strip proof
    _rc "leak"  chaos_leak_signal "$LEAKED" "$TARGET_URL"; leak_got=$GOT   # want 1
    _rc "clean" chaos_leak_signal "$CLEAN"  "$TARGET_URL"; clean_got=$GOT  # want 0
    _rc "empty" chaos_leak_signal ""        "$TARGET_URL"; empty_got=$GOT  # want 2
    {
        echo "chaos_target_leak_key(http://$TARGET_IP:8080/p?a=1) = $key  (want $TARGET_IP)"
        echo "chaos_leak_signal(leaked, URL) rc: $leak_got  (want 1 = LEAK CAUGHT)"
        echo "chaos_leak_signal(clean,  URL) rc: $clean_got (want 0 = real no-leak)"
        echo "chaos_leak_signal(empty,  URL) rc: $empty_got (want 2 = UNEVALUATED)"
    } >>"$EVID_FILE"
    if [ "$key" = "$TARGET_IP" ] && [ "$leak_got" -eq 1 ] \
        && [ "$clean_got" -eq 0 ] && [ "$empty_got" -eq 2 ]; then
        verdict=PASS; exit_code=0
        msg="GREEN: URL stripped to $key; leak CAUGHT (1); clean no-leak (0); empty UNEVALUATED (2) — no vacuous/absent PASS"
    else
        msg="REGRESSION: key=$key leak=$leak_got clean=$clean_got empty=$empty_got — a URL key or empty capture can still vacuously pass"
    fi
fi

echo "verdict: $verdict" >>"$EVID_FILE"
echo "detail: $msg" >>"$EVID_FILE"
echo "[$verdict] chaos-no-leak-argshape (RED_MODE=$RED_MODE): $msg"
echo "evidence: $EVID_FILE"
exit "$exit_code"
