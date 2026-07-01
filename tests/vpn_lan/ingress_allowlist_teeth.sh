#!/usr/bin/env sh
###############################################################################
# ingress_allowlist_teeth.sh — VPN-LAN Phase 12 ingress-allowlist teeth
#                              (PLAN.md §4 item 6 + §5 Phase 12;
#                               bidirectional_exposure.md §3)
#
# Purpose:
#   Prove — AUTONOMOUSLY, with NO live VPN, NO listening socket, and NO mutation
#   of the running data-plane — that the INGRESS exposure allowlist is
#   DEFAULT-DENY and NARROW: only an exact (VPN-host, proxy-service-port) pair is
#   permitted inbound, and everything else (a different host, a different port,
#   anything unlisted) is DENIED. This is the ingress MIRROR of the egress SSRF
#   floor proven by tests/vpn_lan/ssrf_carveout_teeth.sh.
#
#   The problem (bidirectional_exposure.md §1/§3): Direction 2 (a VPN host
#   initiating a NEW connection INTO an exposed proxy-side service — FTP-active
#   data connect, NFS lock/SM_NOTIFY callback, Cast status callback, an RTP
#   stream, any PORT-based callback) is a fresh inbound flow that rides no prior
#   outbound state. It is a NEW attack surface. The ONLY safe posture is
#   default-DENY + a narrow explicit allowlist granted per exact
#   (service-port, VPN-host) pair — never host-wide, never port-wide, never
#   "expose everything." This test is the teeth that catch a drift to permissive.
#
#   It ships a tiny first-match-wins ingress-allowlist evaluator (the ingress
#   twin of the Dante-rule evaluator in ssrf_carveout_teeth.sh) and asserts,
#   against a GOOD policy rendered into a scratch file (default-deny + ONE exact
#   allow pair):
#     T1  Default-deny  : a fully non-allowlisted (host,port) is DENIED.
#     T2  Exact permit  : the exact allowlisted (host,port) is PERMITTED.
#     T3  Host-narrow   : a DIFFERENT host on the same port is DENIED
#                         (incl. a /32 neighbour of the allowed host — proves the
#                          grant is a single /32, not a wider net).
#     T4  Port-narrow   : the SAME host on a DIFFERENT port is DENIED.
#
#   §1.1 paired mutation (INGRESS_MUT=1): render GOLDEN-BAD policies (allow-all /
#   default-permit, host-wide, port-wide) and assert the SAME teeth FAIL them —
#   i.e. the deny-expecting teeth are wrongly answered "permit" by the bad
#   policy, so the teeth CATCH the golden-bad. A teeth test that PASSes its own
#   golden-bad fixture is a bluff gate (§11.4.107(10)); this mode proves it is
#   not. Per the Phase-12 contract, INGRESS_MUT=1 EXITS 1 (rc=1) when the teeth
#   correctly caught every golden-bad — rc=1 IS the expected mutation verdict.
#
#   Honest boundary (§11.4.6): this proves the ingress-allowlist LOGIC is
#   default-deny + narrow. GRANTING a LIVE ingress pair (opening a real
#   proxy-side port to a real VPN host) needs the return-route on BOTH sides
#   (WireGuard AllowedIPs on both peers / a ppp0 reverse route the svord bridge
#   owns) + pinned callback ports + remote-side & proxy-side config — all
#   operator-gated (§11.4.122/§11.4.133). A live bidirectional capability is
#   "done" only when its runtime signature verifies BOTH directions with captured
#   evidence on a genuinely-up bridge (§11.4.108). This test NEVER opens a
#   listening socket, NEVER edits any live config, NEVER runs pkill/kill, and
#   NEVER touches the data-plane :53128/:51080.
#
# Usage:
#   tests/vpn_lan/ingress_allowlist_teeth.sh             # normal — teeth PASS, rc=0
#   INGRESS_MUT=1 tests/vpn_lan/ingress_allowlist_teeth.sh  # mutation — teeth
#                                                          # catch golden-bad, rc=1
#   Optional: HELIX_BRIDGE_HOST=10.6.100.221 (the allowlisted inbound VPN host;
#             a documented default is used when unset — this is a LOGIC test,
#             not a live probe). INGRESS_PORT=2049 (a representative exposed
#             proxy-side service port — LOGIC input only). HELIX_BRIDGE_SUBNET=
#             10.0.0.0/8 (for the host-wide golden-bad).
#
# Inputs (environment):
#   HELIX_BRIDGE_HOST    the single VPN host allowed to reach in (default
#                        10.6.100.221 — used only as a LOGIC input).
#   INGRESS_PORT         the exposed proxy-side service port to allowlist
#                        (default 2049 — illustrative LOGIC input, not a probe).
#   HELIX_BRIDGE_SUBNET  the reachable remote subnet (default 10.0.0.0/8 — used
#                        only to render the host-wide golden-bad).
#   INGRESS_MUT          when 1, run the golden-bad mutation; rc=1 when the teeth
#                        correctly caught every golden-bad (the expected verdict).
#
# Outputs:
#   Diagnostic lines + one verdict token per check (PASS / FAIL / SKIP:<reason>).
#   Normal: exit 0 iff all teeth held. Mutation: exit 1 iff the teeth caught
#   every golden-bad (the expected verdict); exit 2 if a golden-bad slipped
#   through (the teeth are a bluff gate — a real, loud failure, rc != 1).
#   Captured evidence under qa-results/vpn_lan/phase12/<UTC-ts>/.
#
# Side-effects:
#   Writes candidate policies + evidence under a private temp dir + qa-results
#   only. Removes temp on every exit (§11.4.14). NEVER edits any live config,
#   NEVER opens a listening socket, NEVER (re)starts/kills any proxy, NEVER runs
#   pkill/kill, NEVER touches the data-plane :53128/:51080.
#
# Dependencies:
#   POSIX sh + awk (integer arithmetic for CIDR matching). No network, no root,
#   no listener.
#
# Cross-references:
#   docs/design/vpn_lan_access/bidirectional_exposure.md  (§1 return-route,
#                                                          §3 ingress surface)
#   docs/design/vpn_lan_access/PLAN.md   §4 item 6 + §5 Phase 12
#   tests/vpn_lan/ssrf_carveout_teeth.sh (the EGRESS mirror this MIRRORS)
#   config/dante/sockd.conf              (the egress SSRF floor — READ-ONLY here,
#                                         in fact NOT read; kept git-clean)
#   constitution §11.4.1 / §11.4.6 / §11.4.68 / §11.4.101 / §11.4.107(10) /
#                §11.4.108 / §11.4.119 / §11.4.120 / §11.4.122 / §11.4.133 / §1.1
###############################################################################

set -u

SCRIPT_LABEL='ingress_allowlist_teeth'
_sc_dir=$(cd "$(dirname "$0")" && pwd)
_repo_root=$(cd "$_sc_dir/../.." && pwd)

ALLOW_HOST="${HELIX_BRIDGE_HOST:-10.6.100.221}"
ALLOW_PORT="${INGRESS_PORT:-2049}"
ALLOW_SUBNET="${HELIX_BRIDGE_SUBNET:-10.0.0.0/8}"
INGRESS_MUT="${INGRESS_MUT:-0}"

log() { printf '%s: %s\n' "$SCRIPT_LABEL" "$1"; }

# ---- evidence + temp ---------------------------------------------------------
TS=$(date -u +%Y%m%dT%H%M%SZ 2>/dev/null || date +%Y%m%dT%H%M%SZ)
EV_ROOT="$_repo_root/qa-results/vpn_lan/phase12/$TS"
mkdir -p "$EV_ROOT" 2>/dev/null || true
IN_TMP=$(mktemp -d 2>/dev/null || printf '%s' "${TMPDIR:-/tmp}/helix_ingress_$$")
mkdir -p "$IN_TMP" 2>/dev/null || true
cleanup() { [ -n "${IN_TMP:-}" ] && rm -rf "$IN_TMP" >/dev/null 2>&1; return 0; }
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

# ---- ip/cidr helpers (identical semantics to ssrf_carveout_teeth.sh) ---------
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
        if (pfx<=0) { exit 0 }                 # /0 matches everything
        div=2^(32-pfx)
        exit (int(ip/div)==int(base/div))?0:1
    }'
}

# ---- first-match-wins ingress-allowlist evaluator ----------------------------
# eval_ingress <policy-file> <src-ip> <dst-port> -> prints "permit" or "deny".
# Policy is DEFAULT-DENY: only an `ingress allow { from: <cidr> to-port: <p> }`
# block whose CIDR contains <src-ip> AND whose to-port equals <dst-port> (or the
# wildcard `any`/`*`) permits the flow. First match wins; no match => deny.
eval_ingress() {
    _cfg=$1; _src=$2; _port=$3
    _verdict=''
    _cur=''; _from=''; _toport=''
    while IFS= read -r _line; do
        case "$_line" in
            *ingress*allow*'{'*) _cur='allow'; _from=''; _toport='' ;;
            *from:*)
                if [ -n "$_cur" ]; then
                    _from=$(printf '%s' "$_line" | sed -n 's/.*from:[[:space:]]*\([0-9./]*\).*/\1/p')
                    # to-port may share the line with from:
                    _tp=$(printf '%s' "$_line" | sed -n 's/.*to-port:[[:space:]]*\([0-9a-z*]*\).*/\1/p')
                    [ -n "$_tp" ] && _toport=$_tp
                fi ;;
            *to-port:*)
                if [ -n "$_cur" ] && [ -z "$_toport" ]; then
                    _toport=$(printf '%s' "$_line" | sed -n 's/.*to-port:[[:space:]]*\([0-9a-z*]*\).*/\1/p')
                fi ;;
            *'}'*)
                if [ -n "$_cur" ] && [ -n "$_from" ] && [ -n "$_toport" ]; then
                    if ip_in_cidr "$_src" "$_from"; then
                        if [ "$_toport" = any ] || [ "$_toport" = '*' ] || [ "$_toport" = "$_port" ]; then
                            _verdict='permit'; break
                        fi
                    fi
                fi
                _cur=''; _from=''; _toport='' ;;
        esac
    done < "$_cfg"
    [ -z "$_verdict" ] && _verdict='deny'   # DEFAULT-DENY (no catch-all permit)
    printf '%s' "$_verdict"
}

# ---- candidate policy renderers ----------------------------------------------
# render_good <out>: DEFAULT-DENY + ONE exact (host/32, port) allow pair.
render_good() {
    { printf '# ingress allowlist — DEFAULT-DENY; only exact (from-host, to-port) pairs permitted.\n'
      printf 'ingress allow {\n    from: %s/32 to-port: %s\n}\n' "$ALLOW_HOST" "$ALLOW_PORT"; } > "$1"
}
# render_bad_allowall <out>: GOLDEN-BAD — catch-all allow (default-permit).
render_bad_allowall() {
    { printf '# GOLDEN-BAD: allow-all / default-permit (must be REJECTED by the teeth)\n'
      printf 'ingress allow {\n    from: 0.0.0.0/0 to-port: any\n}\n'; } > "$1"
}
# render_bad_hostwide <out>: GOLDEN-BAD — the whole subnet may reach the port.
render_bad_hostwide() {
    { printf '# GOLDEN-BAD: host-wide (whole subnet may reach the port — not per-/32)\n'
      printf 'ingress allow {\n    from: %s to-port: %s\n}\n' "$ALLOW_SUBNET" "$ALLOW_PORT"; } > "$1"
}
# render_bad_portwide <out>: GOLDEN-BAD — the allowed host may reach ANY port.
render_bad_portwide() {
    { printf '# GOLDEN-BAD: port-wide (allowed host may reach ANY service port)\n'
      printf 'ingress allow {\n    from: %s/32 to-port: any\n}\n' "$ALLOW_HOST"; } > "$1"
}

# assert_deny <cfg> <ip> <port> <ev> <label> — verdict MUST be deny
assert_deny() {
    _c=$1; _ip=$2; _pt=$3; _ev=$4; _lbl=$5
    _v=$(eval_ingress "$_c" "$_ip" "$_pt")
    printf '%-22s (%-15s :%-5s) => %s (expect deny)\n' "$_lbl" "$_ip" "$_pt" "$_v" >> "$_ev"
    [ "$_v" = deny ]
}
# assert_permit <cfg> <ip> <port> <ev> <label> — verdict MUST be permit
assert_permit() {
    _c=$1; _ip=$2; _pt=$3; _ev=$4; _lbl=$5
    _v=$(eval_ingress "$_c" "$_ip" "$_pt")
    printf '%-22s (%-15s :%-5s) => %s (expect permit)\n' "$_lbl" "$_ip" "$_pt" "$_v" >> "$_ev"
    [ "$_v" = permit ]
}

# The allowlisted pair + the non-allowlisted canaries.
OTHER_HOST='10.99.88.77'       # a DIFFERENT VPN host (in 10/8, still not allowed)
NEIGHBOUR_HOST='10.6.100.222'  # a /32 NEIGHBOUR of the allowed host (must stay denied)
OTHER_PORT='22'                # a DIFFERENT proxy-side port (not allowlisted)

log "ingress allowlist: allow (host=$ALLOW_HOST/32, port=$ALLOW_PORT); subnet=$ALLOW_SUBNET"

if [ "$INGRESS_MUT" = 1 ]; then
    # ---------------- §1.1 MUTATION MODE: teeth MUST catch golden-bad --------
    log 'INGRESS_MUT=1 — golden-bad policies; the teeth MUST catch them (rc=1 = expected verdict)'
    mut_ev="$EV_ROOT/mutation.evidence"
    { printf '=== §1.1 mutation: ingress teeth must CATCH golden-bad policies ===\n'
      printf 'timestamp_utc : %s\n' "$TS"
      printf 'expected      : rc=1 (every golden-bad caught => teeth are not a bluff gate)\n'; } > "$mut_ev"
    caught=0; total=0

    # bad #1: allow-all — a fully non-allowlisted (host,port) must (wrongly) PERMIT
    #         => the default-deny teeth CATCH it.
    render_bad_allowall "$IN_TMP/bad_allowall.conf"; total=$((total+1))
    if assert_deny "$IN_TMP/bad_allowall.conf" "$OTHER_HOST" "$OTHER_PORT" "$mut_ev" 'allow-all/default-deny'; then
        printf 'GOLDEN-BAD-1 NOT CAUGHT: allow-all still denied a non-allowlisted pair (unexpected)\n' >> "$mut_ev"
    else
        printf 'GOLDEN-BAD-1 CAUGHT: allow-all PERMITTED %s:%s (default-deny broken) — teeth detect it\n' "$OTHER_HOST" "$OTHER_PORT" >> "$mut_ev"; caught=$((caught+1))
    fi

    # bad #2: host-wide — a DIFFERENT host on the allowed port must (wrongly) PERMIT
    #         => the host-narrowness teeth CATCH it.
    render_bad_hostwide "$IN_TMP/bad_hostwide.conf"; total=$((total+1))
    if assert_deny "$IN_TMP/bad_hostwide.conf" "$OTHER_HOST" "$ALLOW_PORT" "$mut_ev" 'host-wide/host-narrow'; then
        printf 'GOLDEN-BAD-2 NOT CAUGHT: host-wide still denied a different host (unexpected)\n' >> "$mut_ev"
    else
        printf 'GOLDEN-BAD-2 CAUGHT: host-wide PERMITTED %s:%s (host-narrowness broken) — teeth detect it\n' "$OTHER_HOST" "$ALLOW_PORT" >> "$mut_ev"; caught=$((caught+1))
    fi

    # bad #3: port-wide — the allowed host on a DIFFERENT port must (wrongly) PERMIT
    #         => the port-narrowness teeth CATCH it.
    render_bad_portwide "$IN_TMP/bad_portwide.conf"; total=$((total+1))
    if assert_deny "$IN_TMP/bad_portwide.conf" "$ALLOW_HOST" "$OTHER_PORT" "$mut_ev" 'port-wide/port-narrow'; then
        printf 'GOLDEN-BAD-3 NOT CAUGHT: port-wide still denied a different port (unexpected)\n' >> "$mut_ev"
    else
        printf 'GOLDEN-BAD-3 CAUGHT: port-wide PERMITTED %s:%s (port-narrowness broken) — teeth detect it\n' "$ALLOW_HOST" "$OTHER_PORT" >> "$mut_ev"; caught=$((caught+1))
    fi

    printf 'caught %s of %s golden-bad policies\n' "$caught" "$total" >> "$mut_ev"
    log "mutation: caught $caught/$total golden-bad policies (evidence: $mut_ev)"
    if [ "$caught" = "$total" ] && [ "$total" -gt 0 ]; then
        log 'INGRESS_MUT=1 — teeth caught every golden-bad; rc=1 is the EXPECTED verdict (not a bluff gate)'
        printf '%s: done (mutation) — caught=%s/%s => rc=1 (expected)\n' "$SCRIPT_LABEL" "$caught" "$total"
        exit 1
    fi
    log 'INGRESS_MUT=1 — a golden-bad SLIPPED THROUGH: the teeth are a BLUFF GATE (real failure)'
    printf '%s: done (mutation) — caught=%s/%s => rc=2 (bluff-gate failure)\n' "$SCRIPT_LABEL" "$caught" "$total"
    exit 2
fi

# ============================================================================
# NORMAL MODE — the GOOD policy: default-deny + one exact allow pair.
# ============================================================================
render_good "$IN_TMP/good.conf"

# T1 — DEFAULT-DENY: a fully non-allowlisted (host,port) is DENIED.
t1_ev="$EV_ROOT/t1_default_deny.evidence"
{ printf '=== T1: default-deny — an unlisted (host,port) is denied ===\n'
  printf 'timestamp_utc : %s\n' "$TS"
  printf 'policy:\n'; sed 's/^/  | /' "$IN_TMP/good.conf"; } > "$t1_ev"
t1_ok=1
assert_deny "$IN_TMP/good.conf" "$OTHER_HOST" "$OTHER_PORT" "$t1_ev" 'unlisted-host+port' || t1_ok=0
assert_deny "$IN_TMP/good.conf" "$OTHER_HOST" "80"          "$t1_ev" 'unlisted-host'      || t1_ok=0
if [ "$t1_ok" = 1 ]; then
    ab_pass_with_evidence "T1 default-deny: unlisted inbound (host,port) is DENIED" "$t1_ev"
else
    ab_fail "T1 default-deny teeth" "an unlisted inbound pair was not denied — see $t1_ev"
fi

# T2 — EXACT PERMIT: the exact allowlisted (host,port) is PERMITTED.
t2_ev="$EV_ROOT/t2_exact_permit.evidence"
{ printf '=== T2: exact permit — the allowlisted (%s:%s) is permitted ===\n' "$ALLOW_HOST" "$ALLOW_PORT"
  printf 'timestamp_utc : %s\n' "$TS"; } > "$t2_ev"
if assert_permit "$IN_TMP/good.conf" "$ALLOW_HOST" "$ALLOW_PORT" "$t2_ev" 'allowlisted-pair'; then
    ab_pass_with_evidence "T2 exact permit: only the allowlisted ($ALLOW_HOST:$ALLOW_PORT) is PERMITTED" "$t2_ev"
else
    ab_fail "T2 exact-permit teeth" "the allowlisted pair was not permitted — see $t2_ev"
fi

# T3 — HOST-NARROW: a DIFFERENT host on the same port is DENIED (incl. a /32 neighbour).
t3_ev="$EV_ROOT/t3_host_narrow.evidence"
{ printf '=== T3: host-narrowness — a different host on port %s is denied ===\n' "$ALLOW_PORT"
  printf 'timestamp_utc : %s\n' "$TS"; } > "$t3_ev"
t3_ok=1
assert_deny "$IN_TMP/good.conf" "$OTHER_HOST"     "$ALLOW_PORT" "$t3_ev" 'different-host'    || t3_ok=0
assert_deny "$IN_TMP/good.conf" "$NEIGHBOUR_HOST" "$ALLOW_PORT" "$t3_ev" '/32-neighbour'     || t3_ok=0
if [ "$t3_ok" = 1 ]; then
    ab_pass_with_evidence "T3 host-narrow: only $ALLOW_HOST/32 permitted on $ALLOW_PORT; other hosts DENIED" "$t3_ev"
else
    ab_fail "T3 host-narrowness teeth" "a non-allowlisted host reached the allowed port — see $t3_ev"
fi

# T4 — PORT-NARROW: the SAME host on a DIFFERENT port is DENIED.
t4_ev="$EV_ROOT/t4_port_narrow.evidence"
{ printf '=== T4: port-narrowness — the allowed host on a different port is denied ===\n'
  printf 'timestamp_utc : %s\n' "$TS"; } > "$t4_ev"
t4_ok=1
assert_deny "$IN_TMP/good.conf" "$ALLOW_HOST" "$OTHER_PORT" "$t4_ev" 'allowed-host+other-port' || t4_ok=0
assert_deny "$IN_TMP/good.conf" "$ALLOW_HOST" "8080"        "$t4_ev" 'allowed-host+8080'       || t4_ok=0
if [ "$t4_ok" = 1 ]; then
    ab_pass_with_evidence "T4 port-narrow: $ALLOW_HOST permitted ONLY on $ALLOW_PORT; other ports DENIED" "$t4_ev"
else
    ab_fail "T4 port-narrowness teeth" "the allowed host reached a non-allowlisted port — see $t4_ev"
fi

log "done — evidence root: $EV_ROOT"
printf '%s: pass=%s fail=%s skip=%s\n' "$SCRIPT_LABEL" "$N_PASS" "$N_FAIL" "$N_SKIP"
[ "$N_FAIL" -eq 0 ] && exit 0 || exit 1
