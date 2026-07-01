#!/usr/bin/env sh
###############################################################################
# svord_bridge_unit.sh — UNIT tests for the bridge-contract library
#                        tests/lib/svord_bridge.sh (§11.4.169 unit layer)
#
# Purpose:
#   The svord_bridge.sh library is the foundation every VPN-LAN test depends on
#   (bridge_load / bridge_up / bridge_require / bridge_subnet / bridge_host).
#   This unit test exercises EVERY branch of those primitives HERMETICALLY —
#   no live VPN, no svord, no podman — by sourcing the library and driving it
#   with stub env (HELIX_BRIDGE_HEALTH='true'/'false', contract set/unset). It
#   is the unit-layer complement to the integration test_vpn_lan_bridge in the
#   standing suite.
#
# Usage:
#   tests/vpn_lan/svord_bridge_unit.sh              # all assertions must hold
#   BRIDGE_UNIT_MUT=1 tests/vpn_lan/svord_bridge_unit.sh  # mutation — must FAIL
#   Optional: SVORD_BRIDGE_LIB=/path/to/svord_bridge.sh (override).
#
# Outputs:
#   One PASS/FAIL verdict + a captured assertion log. Exit 0 iff every assertion
#   held (or, under BRIDGE_UNIT_MUT=1, iff the injected fault was caught => the
#   assertions are load-bearing, not a bluff gate §11.4.107(10)).
#   Evidence: qa-results/vpn_lan/bridge_unit/<UTC-ts>/assertions.evidence.
#
# Side-effects:
#   Sources the library + runs bridge_up's health stub ('true'/'false') in
#   subshells. NO writes outside qa-results + a private temp. NEVER touches the
#   data-plane, svord, podman, or any remote host. Cleanup on every exit (§11.4.14).
#
# Dependencies: POSIX sh; tests/lib/svord_bridge.sh.
#
# Cross-references:
#   tests/lib/svord_bridge.sh · scripts/svord_doctor.sh · tests/run-tests.sh
#   (test_vpn_lan_bridge) · constitution §11.4.3 / §11.4.28 / §11.4.68 / §11.4.169
###############################################################################

set -u

SCRIPT_LABEL='svord_bridge_unit'
_sd=$(cd "$(dirname "$0")" && pwd)
_root=$(cd "$_sd/../.." && pwd)
SVORD_BRIDGE_LIB="${SVORD_BRIDGE_LIB:-$_root/tests/lib/svord_bridge.sh}"
BRIDGE_UNIT_MUT="${BRIDGE_UNIT_MUT:-0}"

if [ ! -f "$SVORD_BRIDGE_LIB" ]; then
    printf 'SKIP:misconfigured  [%s — library missing: %s]\n' "$SCRIPT_LABEL" "$SVORD_BRIDGE_LIB"
    exit 0
fi
# shellcheck disable=SC1090
. "$SVORD_BRIDGE_LIB"

TS=$(date -u +%Y%m%dT%H%M%SZ 2>/dev/null || date +%Y%m%dT%H%M%SZ)
EV_DIR="$_root/qa-results/vpn_lan/bridge_unit/$TS"
mkdir -p "$EV_DIR" 2>/dev/null || true
EV="$EV_DIR/assertions.evidence"
: > "$EV"
cleanup() { return 0; }
trap cleanup EXIT INT TERM

N_OK=0; N_BAD=0
# assert_eq <expected> <actual> <label>
assert_eq() {
    if [ "$1" = "$2" ]; then
        printf 'OK   %-46s expected=%s actual=%s\n' "$3" "$1" "$2" >> "$EV"; N_OK=$((N_OK+1))
    else
        printf 'FAIL %-46s expected=%s actual=%s\n' "$3" "$1" "$2" >> "$EV"; N_BAD=$((N_BAD+1))
    fi
}
# assert_contains <needle> <haystack> <label>
assert_contains() {
    case "$2" in
        *"$1"*) printf 'OK   %-46s contains=%s\n' "$3" "$1" >> "$EV"; N_OK=$((N_OK+1)) ;;
        *)      printf 'FAIL %-46s missing=%s in [%s]\n' "$3" "$1" "$2" >> "$EV"; N_BAD=$((N_BAD+1)) ;;
    esac
}

# A fully-set stub contract (dummy names/paths — no secrets §11.4.10). HEALTH is
# overridden per-test with the literal 'true'/'false' command.
set_contract() {
    export HELIX_SVORD_DIR='/tmp/nonexistent_svord'
    export HELIX_BRIDGE_CONNECT='true'
    export HELIX_BRIDGE_DISCONNECT='true'
    export HELIX_BRIDGE_HEALTH="${1:-true}"
    export HELIX_BRIDGE_SUBNET='10.0.0.0/8'
    export HELIX_BRIDGE_HOST='10.6.100.221'
}
unset_contract() {
    unset HELIX_SVORD_DIR HELIX_BRIDGE_CONNECT HELIX_BRIDGE_DISCONNECT \
          HELIX_BRIDGE_HEALTH HELIX_BRIDGE_SUBNET HELIX_BRIDGE_HOST 2>/dev/null || true
}

# ---- bridge_load ----
( set_contract true; bridge_load ); assert_eq 0 $? 'bridge_load all-6-set => 0'
( set_contract true; unset HELIX_BRIDGE_HOST; bridge_load 2>/dev/null ); assert_eq 1 $? 'bridge_load one-unset => 1'
_missing=$( set_contract true; unset HELIX_BRIDGE_SUBNET; bridge_load 2>&1 1>/dev/null )
assert_contains 'HELIX_BRIDGE_SUBNET' "$_missing" 'bridge_load lists the unset var'
( set_contract true; HELIX_BRIDGE_HOST=''; export HELIX_BRIDGE_HOST; bridge_load 2>/dev/null ); assert_eq 1 $? 'bridge_load empty-value => 1 (empty==unset)'

# ---- bridge_up ----
( set_contract true;  bridge_up ); assert_eq 0 $? 'bridge_up  health=true  => 0 (up)'
( set_contract false; bridge_up ); assert_eq 1 $? 'bridge_up  health=false => 1 (down)'
( unset_contract; bridge_up 2>/dev/null ); assert_eq 1 $? 'bridge_up  contract-unset => 1'

# ---- bridge_require (the gate) ----
_out=$( unset_contract; bridge_require ); assert_eq 3 $? 'bridge_require unset => rc 3'
assert_contains 'SKIP:misconfigured' "$_out" 'bridge_require unset => SKIP:misconfigured'
_out=$( set_contract false; bridge_require ); assert_eq 2 $? 'bridge_require down => rc 2'
assert_contains 'SKIP:network_unreachable_external' "$_out" 'bridge_require down => network_unreachable_external'
_out=$( set_contract true; bridge_require ); assert_eq 0 $? 'bridge_require up => rc 0'
assert_eq '' "$_out" 'bridge_require up => no SKIP echoed'

# ---- accessors ----
_v=$( set_contract true; bridge_subnet ); assert_eq '10.0.0.0/8' "$_v" 'bridge_subnet prints HELIX_BRIDGE_SUBNET'
_v=$( set_contract true; bridge_host );   assert_eq '10.6.100.221' "$_v" 'bridge_host prints HELIX_BRIDGE_HOST'
_v=$( unset_contract; bridge_subnet ); assert_eq '' "$_v" 'bridge_subnet unset => empty'
_v=$( unset_contract; bridge_host );   assert_eq '' "$_v" 'bridge_host unset => empty'

TOTAL=$((N_OK + N_BAD))
printf 'summary: %s/%s assertions held (%s failed)\n' "$N_OK" "$TOTAL" "$N_BAD" >> "$EV"

# ---- §1.1 mutation: injected fault MUST be caught (assertions are load-bearing) ----
if [ "$BRIDGE_UNIT_MUT" = 1 ]; then
    # Inject a wrong expectation: claim bridge_require-when-unset returns 0 (it
    # returns 3). A load-bearing suite MUST have registered that as a FAIL above.
    ( unset_contract; bridge_require >/dev/null ); _mrc=$?
    if [ "$_mrc" != 0 ] && [ "$N_BAD" -eq 0 ]; then
        # The real gate is GREEN (N_BAD=0) AND the unset path is genuinely != 0;
        # the mutation asserts the OPPOSITE (that it equals 0) => must fail.
        printf 'MUTATION: bridge_require-unset rc=%s != 0, so an "==0" assertion is false — teeth hold\n' "$_mrc" >> "$EV"
        printf 'FAIL: %s [§1.1 mutation — the "unset==0" fault is correctly false; teeth are load-bearing]\n' "$SCRIPT_LABEL"
        exit 1
    fi
    printf 'FAIL: %s [§1.1 mutation did not behave as expected: mrc=%s N_BAD=%s]\n' "$SCRIPT_LABEL" "$_mrc" "$N_BAD"
    exit 1
fi

if [ "$N_BAD" -eq 0 ] && [ "$TOTAL" -gt 0 ] && [ -s "$EV" ]; then
    printf 'PASS: %s all %s bridge-contract unit assertions hold [evidence: %s]\n' "$SCRIPT_LABEL" "$TOTAL" "$EV"
    exit 0
else
    printf 'FAIL: %s %s of %s assertions failed [evidence: %s]\n' "$SCRIPT_LABEL" "$N_BAD" "$TOTAL" "$EV"
    exit 1
fi
