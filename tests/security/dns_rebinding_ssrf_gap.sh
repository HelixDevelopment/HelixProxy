#!/usr/bin/env sh
###############################################################################
# dns_rebinding_ssrf_gap.sh — DNS-rebinding / TOCTOU SSRF gap demonstration
#                             (survey #1 rec: smokescreen post-DNS IP re-check)
#
# Purpose:
#   Demonstrate — AUTONOMOUSLY, with NO live VPN, NO live proxy, NO real socket,
#   and NO mutation of the running data-plane — that our current static SSRF
#   floor (Squid host/dest ACL + Dante first-match SOCKS ACL) does NOT cover the
#   DNS-rebinding / TOCTOU sub-class of SSRF, and that the survey's #1
#   recommendation (Stripe smokescreen: a post-DNS resolved-IP re-check) closes
#   it. This is a POLICY-LOGIC test in the exact anti-bluff style of the sibling
#   tests/vpn_lan/ssrf_carveout_teeth.sh — it exercises the DECISION LOGIC of two
#   egress policies against a modelled two-phase DNS resolve; it NEVER performs a
#   real SSRF and NEVER touches anything real.
#
#   The gap (FACT, §11.4.6 — grounded in docs/research/vpn_lan_opensource_survey_
#   20260701/SURVEY.md §4 + OWASP SSRF Case-1): a hostname resolves to a PUBLIC IP
#   at ACL-check time (passing any static host/dest allowlist) and then RE-resolves
#   to an INTERNAL IP (169.254.169.254 metadata / 127.0.0.1 loopback / 10.x
#   RFC1918) at connect time. An allowlist that matches only on the requested
#   HOST / DEST (never re-validating the ACTUAL connect-time resolved IP) permits
#   the connection — the proxy then dials the internal connect-time IP => SSRF.
#   Our Squid `http_access` + Dante `socks pass/block` rules match on host/dest,
#   so they do NOT re-check the connect-time IP. That is the TOCTOU window this
#   test makes concrete.
#
#   It ships a tiny two-policy egress evaluator + a modelled DNS-rebinding
#   scenario set and asserts:
#     T1  GAP (RED evidence)   : the HOSTNAME-ONLY policy (models our static
#         host/dest ACL) PERMITS every rebinding target whose connect-time IP is
#         internal (metadata / loopback / RFC1918). This is the RED evidence the
#         gap is real — the static ACL would forward to an internal IP. A
#         non-allowlisted host is still correctly DENIED (the ACL is not merely
#         broken; the gap is specifically the rebinding TOCTOU).
#     T2  FIX (fix proven)     : the RESOLVED-IP-RECHECK policy (models
#         smokescreen: re-validate the ACTUAL connect-time IP against the
#         internal/metadata deny floor after DNS) DENIES every rebinding target,
#         while a benign stable-public host still PERMITS (no over-block) and a
#         non-allowlisted host is DENIED.
#
#   §1.1 paired mutation (REBIND_MUT=1): weaken the recheck so it re-validates
#   the CHECK-TIME IP (the wrong one, public) instead of the connect-time IP —
#   the exact TOCTOU regression. The rebinding targets then slip through, the
#   "fix blocks" teeth FAIL, and the run exits 1. A teeth test whose fix
#   assertion passes regardless of the recheck is a bluff gate (§11.4.107(10));
#   this mode proves the T2 teeth genuinely depend on the connect-time re-check.
#
#   Honest boundary (§11.4.6): this demonstrates a gap in POLICY LOGIC and proves
#   the fix logic. It is NOT a claim that helix_proxy is currently exploited — no
#   real request is issued. Actually INCORPORATING smokescreen onto the live
#   HTTP-CONNECT egress path is a separate, operator-gated step (§11.4.122); the
#   design lives in docs/design/security/dns_rebinding_ssrf.md. smokescreen
#   covers only the HTTP(S) CONNECT path — the L3-routed protocols stay governed
#   by the Dante first-match ACL + a host firewall.
#
# Usage:
#   tests/security/dns_rebinding_ssrf_gap.sh              # normal — must exit 0
#   REBIND_MUT=1 tests/security/dns_rebinding_ssrf_gap.sh # mutation — must exit 1
#
# Inputs (environment):
#   REBIND_MUT  when 1, run the §1.1 weakened-recheck mutation; the fix teeth
#               MUST then FAIL (exit 1). Any other value = normal mode.
#
# Outputs:
#   Diagnostic lines + one verdict token per check (PASS / FAIL / SKIP:<reason>).
#   Exit 0 iff, in normal mode, the gap was demonstrated (T1) AND the fix was
#   proven (T2). Exit 1 in mutation mode iff the weakened recheck was caught
#   (the fix teeth correctly FAILED). Captured evidence under
#   qa-results/security/dns_rebinding/<UTC-ts>/.
#
# Side-effects:
#   Writes evidence + a scratch temp dir only; removes temp on every exit
#   (§11.4.14). NEVER opens a socket to any address, NEVER resolves a real name,
#   NEVER edits any config, NEVER (re)starts/kills a proxy, NEVER runs
#   pkill/kill, NEVER touches the data-plane :34128/:34080 (§11.4.174).
#
# Dependencies:
#   POSIX sh + awk (integer arithmetic for CIDR matching). No network, no root,
#   no live proxy. Parses under both `sh -n` and `bash -n` (§11.4.67).
#
# Cross-references:
#   docs/design/security/dns_rebinding_ssrf.md                (the design + gap FACT)
#   docs/research/vpn_lan_opensource_survey_20260701/SURVEY.md §4 (smokescreen rec #1)
#   tests/vpn_lan/ssrf_carveout_teeth.sh   (sibling anti-bluff evaluator + style)
#   config/dante/sockd.conf + config/squid/squid.conf  (the static floor, READ-ONLY)
#   constitution §11.4.1 / §11.4.6 / §11.4.68 / §11.4.69 / §11.4.107(10) /
#                §11.4.122 / §11.4.133 / §11.4.150 / §11.4.174 / §1.1
###############################################################################

set -u

SCRIPT_LABEL='dns_rebinding_ssrf_gap'
_sc_dir=$(cd "$(dirname "$0")" && pwd)
_repo_root=$(cd "$_sc_dir/../.." && pwd)

REBIND_MUT="${REBIND_MUT:-0}"

log() { printf '%s: %s\n' "$SCRIPT_LABEL" "$1"; }

# ---- evidence + temp ---------------------------------------------------------
TS=$(date -u +%Y%m%dT%H%M%SZ 2>/dev/null || date +%Y%m%dT%H%M%SZ)
EV_ROOT="$_repo_root/qa-results/security/dns_rebinding/$TS"
mkdir -p "$EV_ROOT" 2>/dev/null || true
DR_TMP=$(mktemp -d 2>/dev/null || printf '%s' "${TMPDIR:-/tmp}/helix_dnsrebind_$$")
mkdir -p "$DR_TMP" 2>/dev/null || true
cleanup() { [ -n "${DR_TMP:-}" ] && rm -rf "$DR_TMP" >/dev/null 2>&1; return 0; }
trap cleanup EXIT INT TERM

# ---- self-contained evidence-gated emitters (§11.4.69) -----------------------
N_PASS=0; N_FAIL=0; N_SKIP=0
ab_pass_with_evidence() {
    _d=$1; _e=${2:-}
    if [ -z "$_e" ] || [ ! -s "$_e" ]; then
        printf 'FAIL: %s [reason: evidence missing/empty: %s]\n' "$_d" "$_e"; N_FAIL=$((N_FAIL+1)); return 1
    fi
    printf 'PASS: %s [evidence: %s]\n' "$_d" "$_e"; N_PASS=$((N_PASS+1)); return 0
}
ab_fail() { printf 'FAIL: %s [%s]\n' "$1" "${2:-}"; N_FAIL=$((N_FAIL+1)); }
ab_skip() { printf 'SKIP: %s [reason: %s]\n' "$1" "${2:-}"; N_SKIP=$((N_SKIP+1)); }

# ---- ip/cidr helpers (mirror ssrf_carveout_teeth.sh) -------------------------
# ip_to_int a.b.c.d -> 32-bit integer (via awk for portable arithmetic).
ip_to_int() {
    printf '%s' "$1" | awk -F. 'NF==4 {print ($1*16777216)+($2*65536)+($3*256)+$4}'
}
# ip_in_cidr <ip> <base/prefix> -> exit 0 if ip is within the CIDR, else 1.
ip_in_cidr() {
    _ip=$1; _cidr=$2
    _base=${_cidr%/*}; _pfx=${_cidr#*/}
    case "$_cidr" in */*) : ;; *) _pfx=32 ;; esac
    _ii=$(ip_to_int "$_ip"); _bi=$(ip_to_int "$_base")
    [ -n "$_ii" ] && [ -n "$_bi" ] || return 1
    awk -v ip="$_ii" -v base="$_bi" -v pfx="$_pfx" 'BEGIN{
        if (pfx<=0) { exit 0 }
        div=2^(32-pfx)
        exit (int(ip/div)==int(base/div))?0:1
    }'
}

# ---- internal/metadata deny floor -------------------------------------------
# The set of destinations a VPN-egress proxy must NEVER be steered to. Mirrors
# the shipped Dante floor (config/dante/sockd.conf: 127/8, 169.254/16, 10/8,
# 172.16/12, 192.168/16) plus 0.0.0.0/8 (this-host) and 100.64.0.0/10 (CGNAT).
# This is the deny-list a smokescreen-style recheck re-validates the CONNECT-TIME
# resolved IP against, AFTER DNS.
DENY_FLOOR='0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8 169.254.0.0/16 172.16.0.0/12 192.168.0.0/16'

# is_internal_ip <ip> -> exit 0 if the ip falls inside the deny floor.
is_internal_ip() {
    _ip=$1
    for _cidr in $DENY_FLOOR; do
        if ip_in_cidr "$_ip" "$_cidr"; then return 0; fi
    done
    return 1
}

# ---- the two egress policies (the thing under test) --------------------------
# policy_hostname_only <host_allowed:yes|no> <connect_ip> -> prints permit|deny
#   Models our CURRENT static floor: the decision is made on the requested
#   host / dest ONLY; the ACTUAL connect-time resolved IP is NEVER re-validated.
#   (Squid `http_access allow`/`deny` + Dante `socks pass/block to:` match on the
#   requested destination, not the post-DNS connect-time IP.) => TOCTOU-blind.
policy_hostname_only() {
    _ha=$1
    if [ "$_ha" = yes ]; then printf permit; else printf deny; fi
}

# policy_resolved_recheck <host_allowed> <connect_ip> -> prints permit|deny
#   Models Stripe smokescreen: the host gate AND a POST-DNS re-validation of the
#   ACTUAL connect-time resolved IP against the internal/metadata deny floor.
policy_resolved_recheck() {
    _ha=$1; _cip=$2
    if [ "$_ha" != yes ]; then printf deny; return; fi
    if is_internal_ip "$_cip"; then printf deny; else printf permit; fi
}

# policy_weak_recheck <host_allowed> <check_ip> <connect_ip> -> prints permit|deny
#   §1.1 MUTATION target: the recheck is weakened to re-validate the CHECK-TIME
#   IP (the wrong, public one) instead of the connect-time IP — the exact TOCTOU
#   regression a smokescreen-style guard must not have. It lets a rebinding
#   target (check-time public, connect-time internal) straight through.
policy_weak_recheck() {
    _ha=$1; _chk=$2
    if [ "$_ha" != yes ]; then printf deny; return; fi
    if is_internal_ip "$_chk"; then printf deny; else printf permit; fi
}

# assert_verdict <actual> <expected> <ev> <label> -> exit 0 iff actual==expected
assert_verdict() {
    _act=$1; _exp=$2; _ev=$3; _lbl=$4
    printf '%-26s => %-6s (expect %s)\n' "$_lbl" "$_act" "$_exp" >> "$_ev"
    [ "$_act" = "$_exp" ]
}

# ---- modelled DNS-rebinding scenario set -------------------------------------
# Each scenario is a modelled two-phase DNS resolve of ONE requested host:
#   check_ip   = what the name resolves to at ACL-CHECK time  (looks fine)
#   connect_ip = what the name RE-resolves to at CONNECT time (the real target)
# host_allowed models the requested host passing the static host/dest allowlist.
#
#   name                host_allowed  check_ip        connect_ip
#   benign_public       yes           93.184.216.34   93.184.216.34   (stable public control)
#   rebind_metadata     yes           1.2.3.4         169.254.169.254 (rebind -> cloud metadata)
#   rebind_loopback     yes           1.2.3.4         127.0.0.1       (rebind -> loopback)
#   rebind_rfc1918      yes           1.2.3.4         10.6.100.221    (rebind -> VPN-internal 10.x)
#   disallowed_host     no            5.6.7.8         5.6.7.8         (not on allowlist control)
PUB_STABLE='93.184.216.34'
CHK_PUBLIC='1.2.3.4'
REB_META='169.254.169.254'
REB_LOOP='127.0.0.1'
REB_1918='10.6.100.221'
DIS_PUBLIC='5.6.7.8'

# ============================================================================
# REBIND_MUT=1 — §1.1 MUTATION: weaken the recheck; the fix teeth MUST FAIL.
# ============================================================================
if [ "$REBIND_MUT" = 1 ]; then
    log 'REBIND_MUT=1 — weakened recheck re-validates the CHECK-TIME ip; the fix teeth MUST FAIL (else bluff gate)'
    mut_ev="$EV_ROOT/mutation.evidence"
    { printf '=== §1.1 mutation: weakened recheck (validates check-time ip, not connect-time ip) ===\n'
      printf 'timestamp_utc : %s\n' "$TS"
      printf 'expectation   : the T2 fix assertion (rebind target must be DENIED) FAILS because the\n'
      printf '                weakened recheck permits it — proving the fix teeth depend on the\n'
      printf '                connect-time re-check and are not a tautology (rc must be 1).\n\n'; } >> "$mut_ev"
    slipped=0; total=0
    # Re-run the T2 "must DENY" fix assertion, but against the WEAKENED recheck.
    for _row in "rebind_metadata $CHK_PUBLIC $REB_META" \
                "rebind_loopback $CHK_PUBLIC $REB_LOOP" \
                "rebind_rfc1918  $CHK_PUBLIC $REB_1918"; do
        # shellcheck disable=SC2086
        set -- $_row; _nm=$1; _chk=$2; _cip=$3
        total=$((total+1))
        _v=$(policy_weak_recheck yes "$_chk" "$_cip")
        printf 'weak_recheck %-16s check_ip=%-9s connect_ip=%-15s => %s (a real fix DENIES)\n' \
            "$_nm" "$_chk" "$_cip" "$_v" >> "$mut_ev"
        if [ "$_v" = permit ]; then
            slipped=$((slipped+1))
        fi
    done
    printf '\nrebinding targets slipped through the weakened recheck: %s of %s\n' "$slipped" "$total" >> "$mut_ev"
    if [ "$slipped" = "$total" ] && [ "$total" -gt 0 ]; then
        # The weakened recheck let EVERY rebind target through => the fix teeth
        # correctly detect the regression. Emit an explicit FAIL so rc=1.
        ab_fail "T2 fix teeth (mutation): weakened recheck permits all $total rebinding targets" \
            "connect-time re-check is load-bearing — teeth caught the weakening; see $mut_ev"
    else
        # The weakened recheck still blocked something => the teeth would NOT
        # have caught this regression => the T2 gate would be a bluff. Flag it.
        ab_pass_with_evidence "UNEXPECTED: weakened recheck still blocked $((total-slipped))/$total (teeth would miss the regression)" "$mut_ev"
    fi
    printf '%s: done (mutation) — pass=%s fail=%s skip=%s\n' "$SCRIPT_LABEL" "$N_PASS" "$N_FAIL" "$N_SKIP"
    # Mutation success == the fix teeth FAILED (N_FAIL>0) => exit 1 as required.
    [ "$N_FAIL" -gt 0 ] && exit 1 || exit 0
fi

# ============================================================================
# T1 — GAP (RED evidence): the hostname-only policy PERMITS every rebinding
#      target whose connect-time IP is internal. A non-allowlisted host is still
#      DENIED. This is the RED proof the static host/dest ACL misses the TOCTOU.
# ============================================================================
t1_ev="$EV_ROOT/t1_gap_hostname_only.evidence"
{ printf '=== T1: GAP — hostname-only policy (models static host/dest ACL) misses connect-time internal IP ===\n'
  printf 'timestamp_utc : %s\n' "$TS"
  printf 'deny_floor    : %s\n' "$DENY_FLOOR"
  printf 'model         : name resolves PUBLIC at check time, INTERNAL at connect time (DNS rebinding / TOCTOU)\n\n'
  printf 'NOTE: a check-time-IP-validating ACL would ALSO permit these — its check-time\n'
  printf '      resolved IP (%s) is public; only re-checking the CONNECT-time IP catches it.\n\n' "$CHK_PUBLIC"; } > "$t1_ev"
t1_ok=1
# rebinding targets: hostname-only PERMITS (the gap).
assert_verdict "$(policy_hostname_only yes "$REB_META")" permit "$t1_ev" 'rebind_metadata(connect=169.254.169.254)' || t1_ok=0
assert_verdict "$(policy_hostname_only yes "$REB_LOOP")" permit "$t1_ev" 'rebind_loopback(connect=127.0.0.1)'      || t1_ok=0
assert_verdict "$(policy_hostname_only yes "$REB_1918")" permit "$t1_ev" 'rebind_rfc1918(connect=10.6.100.221)'   || t1_ok=0
# control: a non-allowlisted host is still DENIED (the ACL is not merely broken).
assert_verdict "$(policy_hostname_only no  "$DIS_PUBLIC")" deny "$t1_ev" 'disallowed_host(not-on-allowlist)'      || t1_ok=0
{ printf '\nINTERPRETATION: every rebinding target was PERMITTED by the hostname-only policy —\n'
  printf 'the proxy would then dial the INTERNAL connect-time IP. This is the SSRF gap our\n'
  printf 'static Squid/Dante host/dest ACL does not cover (survey §4 / OWASP SSRF Case-1).\n'; } >> "$t1_ev"
if [ "$t1_ok" = 1 ]; then
    ab_pass_with_evidence "T1 GAP demonstrated: hostname-only policy permits all rebinding targets to internal IPs" "$t1_ev"
else
    ab_fail "T1 gap-demonstration" "hostname-only policy did not permit a rebinding target as modelled — see $t1_ev"
fi

# ============================================================================
# T2 — FIX (fix proven): the resolved-IP-recheck policy DENIES every rebinding
#      target, PERMITS a stable public host (no over-block), DENIES a
#      non-allowlisted host.
# ============================================================================
t2_ev="$EV_ROOT/t2_fix_resolved_recheck.evidence"
{ printf '=== T2: FIX — resolved-IP recheck (models smokescreen post-DNS re-validation) blocks the rebinding class ===\n'
  printf 'timestamp_utc : %s\n' "$TS"
  printf 'deny_floor    : %s\n\n' "$DENY_FLOOR"; } > "$t2_ev"
t2_ok=1
# rebinding targets: resolved-IP recheck DENIES (the fix).
assert_verdict "$(policy_resolved_recheck yes "$REB_META")" deny "$t2_ev" 'rebind_metadata(connect=169.254.169.254)' || t2_ok=0
assert_verdict "$(policy_resolved_recheck yes "$REB_LOOP")" deny "$t2_ev" 'rebind_loopback(connect=127.0.0.1)'       || t2_ok=0
assert_verdict "$(policy_resolved_recheck yes "$REB_1918")" deny "$t2_ev" 'rebind_rfc1918(connect=10.6.100.221)'    || t2_ok=0
# control: a stable public host still PERMITS (the recheck does not over-block legit egress).
assert_verdict "$(policy_resolved_recheck yes "$PUB_STABLE")" permit "$t2_ev" 'benign_public(connect=93.184.216.34)' || t2_ok=0
# control: a non-allowlisted host is DENIED.
assert_verdict "$(policy_resolved_recheck no  "$DIS_PUBLIC")" deny "$t2_ev" 'disallowed_host(not-on-allowlist)'     || t2_ok=0
{ printf '\nINTERPRETATION: the post-DNS resolved-IP recheck DENIED every rebinding target\n'
  printf '(connect-time IP internal) while still PERMITTING the stable public host — closing\n'
  printf 'the TOCTOU gap without over-blocking legitimate egress (survey §4 rec #1: smokescreen).\n'; } >> "$t2_ev"
if [ "$t2_ok" = 1 ]; then
    ab_pass_with_evidence "T2 FIX proven: resolved-IP recheck blocks all rebinding targets, permits benign public" "$t2_ev"
else
    ab_fail "T2 fix-proof" "resolved-IP recheck failed to block a rebinding target or over-blocked a benign host — see $t2_ev"
fi

log "done — evidence root: $EV_ROOT"
printf '%s: pass=%s fail=%s skip=%s\n' "$SCRIPT_LABEL" "$N_PASS" "$N_FAIL" "$N_SKIP"
[ "$N_FAIL" -eq 0 ] && exit 0 || exit 1
