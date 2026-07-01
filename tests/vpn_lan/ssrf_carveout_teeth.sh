#!/usr/bin/env sh
###############################################################################
# ssrf_carveout_teeth.sh — VPN-LAN Phase 1 SSRF-allowlist carve-out teeth
#                          (PLAN.md §4 reconciliation + §5 Phase 1, §11 line 177)
#
# Purpose:
#   Prove — AUTONOMOUSLY, with NO live VPN and NO mutation of the running
#   data-plane — that the Dante SOCKS SSRF *floor* (the `4626f05` block rules)
#   CANNOT be collapsed by the narrow VPN-subnet carve-out that Phase 1 needs.
#
#   The problem (PLAN.md §4): to reach a VPN-internal host (in 10.0.0.0/8) the
#   shipped floor's `socks block { to: 10.0.0.0/8 }` must be carved. Dante is
#   first-match-wins, so the correct, MINIMAL fix is a single-host
#   `socks pass { to: <HOST>/32 }` inserted ABOVE the 10/8 block — never a
#   widening of the block itself. If done wrong (carve the whole /8, or drop a
#   metadata/loopback block) the SSRF floor collapses (§11.4.120 fix-breaks-
#   its-own-gate; OWASP SSRF Case-1). This test is the teeth that catch that.
#
#   It ships a tiny first-match-wins Dante-rule evaluator and asserts, against
#   BOTH the live shipped floor and a *candidate* narrow-carve-out config
#   rendered into a scratch file:
#     T1  Live floor teeth : 169.254.169.254 / 127.0.0.1 / 10.x / 172.16.x /
#         192.168.x are ALL blocked; a public IP passes. (read-only audit)
#     T2  Carve-out teeth  : with `pass to <HOST>/32` above the 10/8 block —
#         the carve HOST passes, but metadata + loopback + a DIFFERENT 10.x +
#         other RFC1918 are STILL blocked. The carve is narrow + floor-preserving.
#     T3  Ordering teeth   : a carve-out placed BELOW the 10/8 block does NOT
#         take effect (first-match-wins) — the HOST stays blocked. Proves order
#         is load-bearing.
#
#   §1.1 paired mutation (SSRF_MUT=1): render a BAD candidate (carve = whole
#   10.0.0.0/8, OR drop the 169.254 metadata block) and assert the teeth FAIL
#   on it. A teeth test that passes its own golden-bad fixture is a bluff gate
#   (§11.4.107(10)) — this mode proves it is not.
#
#   Honest boundary (§11.4.6): this proves the carve-out LOGIC is floor-safe.
#   APPLYING the carve-out to the live `config/dante/sockd.conf` is a separate
#   step, GATED on the svord bridge being up (opening 10/8 before the VPN
#   routes would be an SSRF regression §11.4.101/§11.4.133) AND operator-gated.
#   This test NEVER edits the live config and NEVER starts/kills a proxy.
#
# Usage:
#   tests/vpn_lan/ssrf_carveout_teeth.sh            # normal — teeth must PASS
#   SSRF_MUT=1 tests/vpn_lan/ssrf_carveout_teeth.sh # mutation — teeth must FAIL
#   Optional: HELIX_BRIDGE_HOST=10.6.100.221 (carve host; a documented default
#             is used when unset — this is a LOGIC test, not a live probe).
#             SOCKD_CONF=/path/to/sockd.conf (audit target override).
#
# Inputs (environment):
#   HELIX_BRIDGE_HOST  the single VPN host to carve out (default 10.6.100.221,
#                      the recon-derived svord host — used only as a LOGIC input).
#   SOCKD_CONF         path to the live Dante config to audit (default
#                      config/dante/sockd.conf).
#   SSRF_MUT           when 1, run the golden-bad mutation and invert the verdict.
#
# Outputs:
#   Diagnostic lines + one verdict token per check (PASS / FAIL / SKIP:<reason>).
#   Exit 0 iff all teeth held (or, under SSRF_MUT=1, iff the teeth correctly
#   FAILED the bad fixture); exit 1 on a real teeth failure.
#   Captured evidence under qa-results/vpn_lan/phase1/<UTC-ts>/.
#
# Side-effects:
#   READ-ONLY on the live config. Writes candidate configs + evidence under a
#   private temp dir + qa-results only. Removes temp on every exit (§11.4.14).
#   NEVER edits config/dante/sockd.conf, NEVER (re)starts/kills any proxy,
#   NEVER runs pkill/kill, NEVER touches the data-plane :53128/:51080.
#
# Dependencies:
#   POSIX sh + awk (integer arithmetic for CIDR matching). No network, no root.
#
# Cross-references:
#   docs/design/vpn_lan_access/PLAN.md §4 (SSRF reconciliation) + §5 Phase 1
#   config/dante/sockd.conf              (the live SSRF floor audited here)
#   tests/security/proxy_acl_security.sh (S4 SOCKS-SSRF live sibling)
#   constitution §11.4.1 / §11.4.6 / §11.4.68 / §11.4.101 / §11.4.107(10) /
#                §11.4.119 / §11.4.120 / §11.4.133 / §1.1
###############################################################################

set -u

SCRIPT_LABEL='ssrf_carveout_teeth'
_sc_dir=$(cd "$(dirname "$0")" && pwd)
_repo_root=$(cd "$_sc_dir/../.." && pwd)

SOCKD_CONF="${SOCKD_CONF:-$_repo_root/config/dante/sockd.conf}"
CARVE_HOST="${HELIX_BRIDGE_HOST:-10.6.100.221}"
SSRF_MUT="${SSRF_MUT:-0}"

log() { printf '%s: %s\n' "$SCRIPT_LABEL" "$1"; }

# ---- evidence + temp ---------------------------------------------------------
TS=$(date -u +%Y%m%dT%H%M%SZ 2>/dev/null || date +%Y%m%dT%H%M%SZ)
EV_ROOT="$_repo_root/qa-results/vpn_lan/phase1/$TS"
mkdir -p "$EV_ROOT" 2>/dev/null || true
SC_TMP=$(mktemp -d 2>/dev/null || printf '%s' "${TMPDIR:-/tmp}/helix_ssrf_$$")
mkdir -p "$SC_TMP" 2>/dev/null || true
cleanup() { [ -n "${SC_TMP:-}" ] && rm -rf "$SC_TMP" >/dev/null 2>&1; return 0; }
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

# ---- ip/cidr first-match-wins Dante-rule evaluator ---------------------------
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
    # Membership by comparing the high (32-pfx) bits: shift both IP and base
    # right by (32-prefix) and compare. Equal high bits => same network.
    awk -v ip="$_ii" -v base="$_bi" -v pfx="$_pfx" 'BEGIN{
        if (pfx<=0) { exit 0 }                 # /0 matches everything
        div=2^(32-pfx)
        exit (int(ip/div)==int(base/div))?0:1
    }'
}
# eval_dest <config-file> <dest-ip> -> prints "block" or "pass" (first match wins).
# Parses lines of the shape: `socks block {` / `socks pass {` followed by a
# `to: <cidr-or-ip>` line before the closing brace. Returns the verdict of the
# first rule whose `to:` CIDR contains <dest-ip>. Default (no match) = "pass"
# (mirrors Dante: an unmatched CONNECT falls through — but our floor's final
# rule is an explicit `pass to 0.0.0.0/0`, so a match is always found).
eval_dest() {
    _cfg=$1; _dest=$2
    _verdict=''
    _cur=''
    while IFS= read -r _line; do
        case "$_line" in
            *socks*block*'{'*) _cur='block' ;;
            *socks*pass*'{'*)  _cur='pass'  ;;
            *to:*)
                if [ -n "$_cur" ]; then
                    _to=$(printf '%s' "$_line" | sed -n 's/.*to:[[:space:]]*\([0-9./]*\).*/\1/p')
                    if [ -n "$_to" ] && ip_in_cidr "$_dest" "$_to"; then
                        _verdict=$_cur; break
                    fi
                fi ;;
            *'}'*) _cur='' ;;
        esac
    done < "$_cfg"
    [ -z "$_verdict" ] && _verdict='pass'   # unmatched fall-through
    printf '%s' "$_verdict"
}

# ---- candidate config renderers ----------------------------------------------
# Extract just the `socks ...{ ... }` rule blocks from the live floor (the
# authoritative ordered rule list) into a normalized scratch file.
extract_floor() {
    awk '
      /socks[ \t]+(block|pass)[ \t]*\{/ {inblk=1}
      inblk {print}
      /\}/ && inblk {inblk=0}
    ' "$SOCKD_CONF" > "$1"
}
# render_good <out>: floor with a narrow single-host carve `pass to HOST/32`
# inserted ABOVE the `to: 10.0.0.0/8` block (correct first-match-wins placement).
render_good() {
    _out=$1
    # Emit the carve `pass` FIRST (top of list => highest precedence), then the
    # full floor. First-match-wins => HOST passes; every other block still
    # applies to every other destination (the floor is preserved).
    {
        printf 'socks pass {\n    from: 0.0.0.0/0 to: %s/32\n}\n' "$CARVE_HOST"
        cat "$SC_TMP/floor.conf"
    } > "$_out"
}
# render_below <out>: WRONG placement — carve AFTER the whole floor (below the
# 10/8 block). First-match-wins => the 10/8 block wins => HOST stays blocked.
render_below() {
    _out=$1
    { cat "$SC_TMP/floor.conf"; printf 'socks pass {\n    from: 0.0.0.0/0 to: %s/32\n}\n' "$CARVE_HOST"; } > "$_out"
}
# render_bad_wide <out>: golden-bad — carve the WHOLE /8 (collapses the 10/8 floor).
render_bad_wide() {
    _out=$1
    { printf 'socks pass {\n    from: 0.0.0.0/0 to: 10.0.0.0/8\n}\n'; cat "$SC_TMP/floor.conf"; } > "$_out"
}
# render_bad_nometa <out>: golden-bad — floor with the 169.254 metadata block dropped.
render_bad_nometa() {
    _out=$1
    awk 'BEGIN{skip=0}
      /socks[ \t]+block[ \t]*\{/ {buf=$0; getline nx; if (nx ~ /169\.254/){skip=1} else {print buf; print nx; next}}
      skip==1 && /\}/ {skip=0; next}
      skip==1 {next}
      {print}
    ' "$SC_TMP/floor.conf" > "$_out"
}

# assert_blocked <cfg> <ip> <ev> <label>  — verdict MUST be block
assert_blocked() {
    _c=$1; _ip=$2; _ev=$3; _lbl=$4
    _v=$(eval_dest "$_c" "$_ip")
    printf '%-22s to %-16s => %s (expect block)\n' "$_lbl" "$_ip" "$_v" >> "$_ev"
    [ "$_v" = block ]
}
# assert_passed <cfg> <ip> <ev> <label>  — verdict MUST be pass
assert_passed() {
    _c=$1; _ip=$2; _ev=$3; _lbl=$4
    _v=$(eval_dest "$_c" "$_ip")
    printf '%-22s to %-16s => %s (expect pass)\n' "$_lbl" "$_ip" "$_v" >> "$_ev"
    [ "$_v" = pass ]
}

# ============================================================================
# PRE: the live floor must exist + be non-empty (else honest SKIP, never PASS).
# ============================================================================
if [ ! -s "$SOCKD_CONF" ]; then
    ab_skip "SSRF floor audit ($SOCKD_CONF absent/empty)" topology_unsupported
    printf '%s: done (skipped) — pass=%s fail=%s skip=%s\n' "$SCRIPT_LABEL" "$N_PASS" "$N_FAIL" "$N_SKIP"
    exit 0
fi
extract_floor "$SC_TMP/floor.conf"
if [ ! -s "$SC_TMP/floor.conf" ]; then
    ab_skip "SSRF floor parse (no socks rules found in $SOCKD_CONF)" topology_unsupported
    printf '%s: done (skipped) — pass=%s fail=%s skip=%s\n' "$SCRIPT_LABEL" "$N_PASS" "$N_FAIL" "$N_SKIP"
    exit 0
fi
log "audited live floor: $SOCKD_CONF ($(grep -c 'socks' "$SC_TMP/floor.conf" 2>/dev/null | tr -d ' ') socks tokens); carve host=$CARVE_HOST"

# The must-block canaries (metadata, loopback, RFC1918) + a public control.
META='169.254.169.254'; LOOPB='127.0.0.1'; PUB='8.8.8.8'
OTHER10='10.99.88.77'; RFC172='172.16.5.5'; RFC192='192.168.9.9'

if [ "$SSRF_MUT" = 1 ]; then
    # ---------------- §1.1 MUTATION MODE: teeth MUST catch a bad fixture ------
    log 'SSRF_MUT=1 — golden-bad fixtures; the teeth MUST FAIL them (else bluff gate)'
    mut_ev="$EV_ROOT/mutation.evidence"
    { printf '=== §1.1 mutation: teeth must FAIL golden-bad candidates ===\n'
      printf 'timestamp_utc : %s\n' "$TS"; } > "$mut_ev"
    caught=0; total=0

    # bad #1: carve the whole /8 — a DIFFERENT 10.x must (wrongly) pass => floor collapsed.
    render_bad_wide "$SC_TMP/bad_wide.conf"; total=$((total+1))
    if assert_blocked "$SC_TMP/bad_wide.conf" "$OTHER10" "$mut_ev" 'bad_wide/other-10'; then
        printf 'GOLDEN-BAD-1 NOT CAUGHT: whole-/8 carve still blocked other 10.x (unexpected)\n' >> "$mut_ev"
    else
        printf 'GOLDEN-BAD-1 CAUGHT: whole-/8 carve let 10.99.88.77 through (floor collapsed) — teeth detect it\n' >> "$mut_ev"; caught=$((caught+1))
    fi
    # bad #2: metadata block dropped — 169.254.169.254 must (wrongly) pass.
    render_bad_nometa "$SC_TMP/bad_nometa.conf"; total=$((total+1))
    if assert_blocked "$SC_TMP/bad_nometa.conf" "$META" "$mut_ev" 'bad_nometa/metadata'; then
        printf 'GOLDEN-BAD-2 NOT CAUGHT: metadata still blocked despite dropped rule (unexpected)\n' >> "$mut_ev"
    else
        printf 'GOLDEN-BAD-2 CAUGHT: dropped-metadata candidate let 169.254.169.254 through — teeth detect it\n' >> "$mut_ev"; caught=$((caught+1))
    fi

    printf 'caught %s of %s golden-bad fixtures\n' "$caught" "$total" >> "$mut_ev"
    if [ "$caught" = "$total" ] && [ "$total" -gt 0 ]; then
        ab_pass_with_evidence "SSRF teeth catch all $total golden-bad fixtures (§1.1 mutation)" "$mut_ev"
    else
        ab_fail "SSRF teeth are a bluff gate" "only caught $caught/$total golden-bad fixtures — see $mut_ev"
    fi
    printf '%s: done (mutation) — pass=%s fail=%s skip=%s\n' "$SCRIPT_LABEL" "$N_PASS" "$N_FAIL" "$N_SKIP"
    [ "$N_FAIL" -eq 0 ] && exit 0 || exit 1
fi

# ============================================================================
# T1 — LIVE FLOOR TEETH (read-only audit): every internal canary blocked, public passes.
# ============================================================================
t1_ev="$EV_ROOT/t1_live_floor.evidence"
{ printf '=== T1: live SSRF floor teeth (%s) ===\n' "$SOCKD_CONF"
  printf 'timestamp_utc : %s\n' "$TS"; } > "$t1_ev"
t1_ok=1
assert_blocked "$SC_TMP/floor.conf" "$META"   "$t1_ev" 'metadata'     || t1_ok=0
assert_blocked "$SC_TMP/floor.conf" "$LOOPB"  "$t1_ev" 'loopback'     || t1_ok=0
assert_blocked "$SC_TMP/floor.conf" "$OTHER10" "$t1_ev" 'rfc1918-10'  || t1_ok=0
assert_blocked "$SC_TMP/floor.conf" "$RFC172" "$t1_ev" 'rfc1918-172'  || t1_ok=0
assert_blocked "$SC_TMP/floor.conf" "$RFC192" "$t1_ev" 'rfc1918-192'  || t1_ok=0
assert_passed  "$SC_TMP/floor.conf" "$PUB"    "$t1_ev" 'public'       || t1_ok=0
if [ "$t1_ok" = 1 ]; then
    ab_pass_with_evidence "T1 live SSRF floor blocks metadata+loopback+all RFC1918, passes public" "$t1_ev"
else
    ab_fail "T1 live SSRF floor teeth" "a must-block canary was not blocked (or public was blocked) — see $t1_ev"
fi

# ============================================================================
# T2 — CARVE-OUT TEETH: narrow single-host carve above 10/8 block. HOST passes;
#      metadata + loopback + a DIFFERENT 10.x + other RFC1918 STILL blocked.
# ============================================================================
render_good "$SC_TMP/good.conf"
t2_ev="$EV_ROOT/t2_carveout.evidence"
{ printf '=== T2: narrow carve-out (pass to %s/32 above 10/8) is floor-preserving ===\n' "$CARVE_HOST"
  printf 'timestamp_utc : %s\n' "$TS"
  printf 'candidate_config:\n'; sed 's/^/  | /' "$SC_TMP/good.conf"; } > "$t2_ev"
t2_ok=1
assert_passed  "$SC_TMP/good.conf" "$CARVE_HOST" "$t2_ev" 'carve-host'      || t2_ok=0
assert_blocked "$SC_TMP/good.conf" "$META"       "$t2_ev" 'metadata-still'  || t2_ok=0
assert_blocked "$SC_TMP/good.conf" "$LOOPB"      "$t2_ev" 'loopback-still'  || t2_ok=0
assert_blocked "$SC_TMP/good.conf" "$OTHER10"    "$t2_ev" 'other-10-still'  || t2_ok=0
assert_blocked "$SC_TMP/good.conf" "$RFC172"     "$t2_ev" 'rfc172-still'    || t2_ok=0
assert_blocked "$SC_TMP/good.conf" "$RFC192"     "$t2_ev" 'rfc192-still'    || t2_ok=0
if [ "$t2_ok" = 1 ]; then
    ab_pass_with_evidence "T2 narrow carve-out passes only $CARVE_HOST; floor intact for all else" "$t2_ev"
else
    ab_fail "T2 carve-out teeth" "carve host not passed, or the floor leaked for a non-carve target — see $t2_ev"
fi

# ============================================================================
# T3 — ORDERING TEETH: same carve placed BELOW the 10/8 block does NOT take
#      effect (first-match-wins) — HOST stays blocked. Order is load-bearing.
# ============================================================================
render_below "$SC_TMP/below.conf"
t3_ev="$EV_ROOT/t3_ordering.evidence"
{ printf '=== T3: carve BELOW the 10/8 block is inert (first-match-wins) ===\n'
  printf 'timestamp_utc : %s\n' "$TS"; } > "$t3_ev"
if assert_blocked "$SC_TMP/below.conf" "$CARVE_HOST" "$t3_ev" 'carve-below/host'; then
    ab_pass_with_evidence "T3 carve placed below 10/8 is inert — HOST stays blocked (order matters)" "$t3_ev"
else
    ab_fail "T3 ordering teeth" "a carve below the 10/8 block wrongly took effect — see $t3_ev"
fi

log "done — evidence root: $EV_ROOT"
printf '%s: pass=%s fail=%s skip=%s\n' "$SCRIPT_LABEL" "$N_PASS" "$N_FAIL" "$N_SKIP"
[ "$N_FAIL" -eq 0 ] && exit 0 || exit 1
