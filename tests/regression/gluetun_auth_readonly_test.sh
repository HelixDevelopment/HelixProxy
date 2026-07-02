#!/bin/sh
#######################################################################
# §11.4.135 regression guard — gluetun control-server auth grants
# ONLY read-only status routes, NEVER a mutating / VPN-control route.
#
# Purpose:
#   gluetun v3.40 made ALL control-API routes private (401 without auth).
#   config/gluetun/auth-config.toml (TRACKED) re-opens ONLY read-only status
#   routes unauthenticated on the pod-internal control port so healthd (the
#   vpn-health-publisher) + the compose healthcheck can poll GET /v1/vpn/status
#   & friends. It grants `auth = "none"` — so its route allowlist is the ONLY
#   thing standing between an unauthenticated pod-internal caller and the
#   control API. If a mutating / config / VPN-control route ever leaks into a
#   [[roles]] `routes = [...]` grant (a copy-paste, a "just add settings",
#   an upstream example), that unauthenticated caller could:
#     - CHANGE VPN state (/v1/vpn/start|stop, /v1/openvpn/...) — a §11.4.133
#       target-safety regression (silently drop or re-route the tunnel), OR
#     - READ SECRETS (/v1/openvpn/settings returns credentials; a settings GET
#       leaks the private key/creds) — a §11.4.10 leak.
#   A "the auth file exists" check misses this entirely (§11.4.108 SOURCE gap).
#   This guard fails-closed on ANY such grant.
#
#   PURE static TOML parse — NO toml library, NO container, NO network, NO live
#   stack. Portable sh (grep/sed/awk); runs identically under sh AND bash
#   (§11.4.67). §11.4.10-safe: parses route strings only; no secret is read.
#
# What it actually does (the SAME parser + validator drives BOTH polarities —
# GREEN vs the real tracked config, RED vs a synthesized mutating-grant fixture
# — so the read-only assertion's teeth are proven, not assumed §11.4.107(10)):
#   extract_routes <toml>   -> emits every quoted token inside every
#                              `routes = [ ... ]` array (single- OR multi-line),
#                              one normalized "<METHOD> <path>" per line.
#   validate_readonly_routes <toml>  returns 0 iff:
#     - >=1 route was parsed (proves the parser bit on a real config — a
#       parse-of-nothing on a present file is a regression, not a vacuous PASS),
#     - EVERY parsed route is an EXACT member of the READ-ONLY allowlist, AND
#     - NO parsed route matches ANY mutating/control denylist pattern.
#
#   READ-ONLY allowlist (GET status/read routes only — each changes nothing and
#   leaks no secret; the real config grants the first three):
#       GET /v1/publicip/ip      GET /v1/vpn/status
#       GET /v1/openvpn/status   GET /v1/wireguard/status
#   MUTATING / control denylist (substring match — rejects any of):
#       "PUT "  "DELETE "  "POST "  "PATCH "   (any non-GET method)
#       /v1/vpn/start   /v1/vpn/stop           (VPN state control)
#       /v1/openvpn/settings                   (config write / secret read)
#       /v1/dns/        /v1/updater/           (dns + updater control planes)
#   Both checks apply (belt-and-suspenders): allowlist-exact-membership already
#   rejects a mutating route (it is not a GET status read), and the denylist
#   independently rejects the mutating shapes — either alone catches the defect.
#
# §11.4.115 polarity switch (RED_MODE):
#   RED_MODE=0 (default GREEN guard): validate the REAL tracked
#     config/gluetun/auth-config.toml -> PASS iff it grants ONLY read-only
#     routes; FAIL if the file is absent (a TRACKED file's absence breaks healthd
#     — a real regression, not a topology SKIP) or grants anything mutating.
#   RED_MODE=1 (reproduce): synthesize a throwaway config granting a MUTATING
#     route (PUT /v1/openvpn/settings + /v1/vpn/stop) and run the SAME validator
#     -> PASS iff the validator REJECTS it (defect reproduced; the read-only
#     check has teeth). A RED that cannot reproduce is a §11.4.7 finding — it
#     would prove the GREEN assertion is a tautology. RED NEVER mutates the real
#     file (throwaway temp fixture, removed on exit).
#
# Usage:
#   tests/regression/gluetun_auth_readonly_test.sh            # GREEN guard
#   RED_MODE=1 tests/regression/gluetun_auth_readonly_test.sh # reproduce defect
#
# Inputs:   RED_MODE (env, default 0). No CLI args.
# Outputs:  [PASS]/[FAIL] line on stdout + evidence under
#           qa-results/regression/gluetun_auth_readonly/.
#           Exit 0=PASS, 1=FAIL.
# Side-effects: writes one evidence file; RED writes one temp fixture (removed
#               on exit). No container/network access; never touches the real
#               config except to READ it in GREEN.
# Dependencies: sh (POSIX), grep, awk, sed, mktemp.
# Cross-references:
#   - Guarded config: config/gluetun/auth-config.toml (tracked).
#   - Sibling guards: tests/regression/mullvad_egress_config_test.sh,
#     tests/regression/vpn_failclosed_reason_test.sh.
# Shell: POSIX-clean (sh -n + bash -n, §11.4.67).
#######################################################################
set -eu

RED_MODE="${RED_MODE:-0}"
REPO_ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
AUTH_FILE="$REPO_ROOT/config/gluetun/auth-config.toml"
EVID_DIR="$REPO_ROOT/qa-results/regression/gluetun_auth_readonly"
mkdir -p "$EVID_DIR"
EVID_FILE="$EVID_DIR/gluetun_auth_readonly.$$.txt"

# READ-ONLY allowlist — GET status/read routes only (space-separated set).
ALLOWLIST="GET /v1/publicip/ip
GET /v1/vpn/status
GET /v1/openvpn/status
GET /v1/wireguard/status"

# MUTATING / control denylist — substring patterns (newline-separated).
DENYLIST="PUT
DELETE
POST
PATCH
/v1/vpn/start
/v1/vpn/stop
/v1/openvpn/settings
/v1/dns/
/v1/updater/"

# --- Extract every route grant from every `routes = [ ... ]` array. Handles
#     single-line AND multi-line arrays. Emits one quoted token per line with
#     internal whitespace collapsed to a single space. NO toml library. ---
extract_routes() { # $1 = toml file
    awk '
        /routes[ \t]*=[ \t]*\[/ { inr = 1 }
        inr {
            line = $0
            while (match(line, /"[^"]*"/)) {
                tok = substr(line, RSTART + 1, RLENGTH - 2)
                gsub(/[ \t]+/, " ", tok)      # collapse internal whitespace
                sub(/^ /, "", tok); sub(/ $/, "", tok)
                if (tok != "") print tok
                line = substr(line, RSTART + RLENGTH)
            }
            if ($0 ~ /\]/) inr = 0
        }
    ' "$1" 2>/dev/null
}

# --- Single source of truth for "is this auth config read-only-only".
#     Drives BOTH GREEN (real file) and RED (mutating fixture). Populates the
#     V_* result counters for the evidence file (no secret is ever read). ---
V_total=0; V_bad=0
validate_readonly_routes() { # $1 = toml file
    _f="$1"
    V_total=0; V_bad=0
    _routes="$(extract_routes "$_f")"

    # iterate line-by-line (portable: `while read`)
    printf '%s\n' "$_routes" | {
        _t=0; _b=0
        while IFS= read -r _route; do
            [ -n "$_route" ] || continue
            _t=$((_t + 1))
            _route_bad=0

            # (1) method must be GET (any non-GET grant is a control route)
            case "$_route" in
                "GET "*) ;;
                *) _route_bad=1 ;;
            esac

            # (2) exact membership in the READ-ONLY allowlist
            _in_allow=0
            printf '%s\n' "$ALLOWLIST" | while IFS= read -r _a; do
                [ "$_route" = "$_a" ] && { echo ok; break; }
            done | grep -q ok && _in_allow=1
            [ "$_in_allow" = 1 ] || _route_bad=1

            # (3) must NOT match ANY mutating/control denylist pattern
            printf '%s\n' "$DENYLIST" | while IFS= read -r _d; do
                [ -n "$_d" ] || continue
                case "$_route" in
                    *"$_d"*) echo hit; break ;;
                esac
            done | grep -q hit && _route_bad=1

            [ "$_route_bad" = 1 ] && _b=$((_b + 1))
        done
        # export the counts across the subshell boundary via stdout
        echo "$_t $_b"
    } | {
        read -r _t _b
        V_total="$_t"; V_bad="$_b"
        # returncode carried out via the temp result file below
        printf '%s %s\n' "$V_total" "$V_bad" > "$EVID_DIR/.counts.$$"
    }

    read -r V_total V_bad < "$EVID_DIR/.counts.$$"
    rm -f "$EVID_DIR/.counts.$$"

    # read-only-only iff at least one route parsed AND zero bad routes
    if [ "$V_total" -ge 1 ] && [ "$V_bad" -eq 0 ]; then
        return 0
    fi
    return 1
}

verdict=FAIL
exit_code=1
{
    echo "gluetun control-server auth read-only-only guard — §11.4.135/§11.4.115/§11.4.10"
    echo "timestamp_utc: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "RED_MODE: $RED_MODE"
    echo "allowlist (read-only GET status routes):"
    printf '  %s\n' "$ALLOWLIST"
    echo "denylist (mutating/control patterns): PUT DELETE POST PATCH /v1/vpn/start /v1/vpn/stop /v1/openvpn/settings /v1/dns/ /v1/updater/"
} >"$EVID_FILE"

if [ "$RED_MODE" = "1" ]; then
    # --- Reproduce the DEFECT: a config that grants a MUTATING route MUST be
    #     rejected by the SAME validator. Throwaway fixture; real file untouched. ---
    FIX_FILE="$(mktemp)"
    trap 'rm -f "$FIX_FILE"' EXIT INT TERM
    {
        printf '[[roles]]\n'
        printf 'name = "danger"\n'
        printf 'routes = ["GET /v1/vpn/status", "PUT /v1/openvpn/settings", "GET /v1/vpn/stop"]\n'
        printf 'auth = "none"\n'
    } >"$FIX_FILE"

    if validate_readonly_routes "$FIX_FILE"; then
        msg="RED could-not-reproduce: validator ACCEPTED a config granting a mutating route (PUT /v1/openvpn/settings + /v1/vpn/stop) — §11.4.7 finding (GREEN would be a tautology)"
    else
        verdict=PASS; exit_code=0
        msg="RED reproduced: validator REJECTS a config granting a mutating/control route (parsed=$V_total bad=$V_bad) — the read-only-only check has teeth"
    fi
    {
        echo "fixture (synthesized): routes = [GET /v1/vpn/status, PUT /v1/openvpn/settings, GET /v1/vpn/stop]"
        echo "fixture counts: parsed_routes=$V_total bad_routes=$V_bad"
    } >>"$EVID_FILE"
else
    if [ ! -f "$AUTH_FILE" ]; then
        msg="REGRESSION: config/gluetun/auth-config.toml ABSENT — the tracked gluetun auth config is missing; healthd would 401 on every poll (NOT a topology SKIP — this file is tracked)"
        echo "auth_config_present: no" >>"$EVID_FILE"
    else
        if validate_readonly_routes "$AUTH_FILE"; then rc=0; else rc=1; fi
        _granted="$(extract_routes "$AUTH_FILE" | sed 's/^/    /')"
        {
            echo "auth_config_present: yes"
            echo "parsed_routes=$V_total bad_routes=$V_bad"
            echo "granted routes:"
            printf '%s\n' "$_granted"
        } >>"$EVID_FILE"

        if [ "$rc" = 0 ]; then
            verdict=PASS; exit_code=0
            msg="GREEN: config/gluetun/auth-config.toml grants ONLY read-only status routes ($V_total granted, 0 mutating) — no unauthenticated control/config/secret surface"
        else
            msg="REGRESSION: config/gluetun/auth-config.toml grants a NON-read-only route ($V_total parsed, $V_bad outside the read-only allowlist / matching a mutating pattern) — an unauthenticated caller could change VPN state (§11.4.133) or read secrets (§11.4.10)"
        fi
    fi
fi

{
    echo "verdict: $verdict"
    echo "detail: $msg"
} >>"$EVID_FILE"
echo "[$verdict] gluetun-auth-readonly (RED_MODE=$RED_MODE): $msg"
echo "evidence: $EVID_FILE"
exit "$exit_code"
