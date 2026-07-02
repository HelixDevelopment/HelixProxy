#!/bin/sh
#######################################################################
# §11.4.135 regression guard — Mullvad WireGuard egress config shape
# (proven gluetun mullvad-native config must never silently regress).
#
# Purpose:
#   The operator provisioned + PROVED a working gluetun "mullvad-native"
#   WireGuard egress config in .env (gitignored §11.4.10). If that config
#   silently reverts to the .env.example placeholder shape (provider=custom,
#   empty WIREGUARD_PRIVATE_KEY, empty WIREGUARD_ADDRESSES) the `dynamic`
#   VPN stack would come up with NO valid tunnel — a §11.4.108 SOURCE/ARTIFACT
#   regression that a casual "the file exists" check misses. This guard proves
#   the .env carries the VALID mullvad-native WireGuard shape, and that
#   .env.example still documents the four vars a fresh checkout must fill in.
#
#   PURE-CONFIG + deterministic: reads config text only. NO container, NO
#   network, NO live stack. §11.4.10-safe — the WireGuard private key + the
#   WireGuard addresses are validated for SHAPE ONLY and are NEVER printed,
#   logged, or written to the evidence file (evidence records booleans only).
#
# What it actually does (the SAME validator drives BOTH polarities — GREEN vs
# the real .env, RED vs a synthesized broken fixture — so the validator's
# teeth are proven, not assumed §11.4.107(10)):
#   validate_mullvad_env <env-file>  returns 0 iff the file carries:
#     - VPN_SERVICE_PROVIDER=mullvad
#     - VPN_DEFAULT_TYPE=wireguard
#     - a non-empty base64-shaped WIREGUARD_PRIVATE_KEY (>=40 chars,
#       matches ^[A-Za-z0-9+/]{42,}=?$) — SHAPE checked, value NEVER printed
#     - a valid WIREGUARD_ADDRESSES CIDR (^[0-9.]+/[0-9]+$) — value NEVER printed
#
# §11.4.115 polarity switch (RED_MODE):
#   RED_MODE=0 (default GREEN guard):
#     * .env ABSENT   -> honest §11.4.3 SKIP (exit 2), fresh-checkout topology —
#                        the operator has not provisioned creds yet; NEVER a
#                        fake PASS.
#     * .env PRESENT  -> PASS (exit 0) iff validate_mullvad_env(.env) holds AND
#                        .env.example still documents all four vars; else FAIL.
#   RED_MODE=1 (reproduce): synthesize a BROKEN config (provider=custom, empty
#     key, empty addresses) in a throwaway temp file and run the SAME validator
#     -> PASS iff the validator REJECTS it (defect reproduced; the shape check
#     has teeth). A RED that cannot reproduce is a §11.4.7 finding — it would
#     prove the GREEN assertion is a tautology.
#
# Usage:
#   tests/regression/mullvad_egress_config_test.sh            # GREEN guard
#   RED_MODE=1 tests/regression/mullvad_egress_config_test.sh # reproduce defect
#
# Inputs:   RED_MODE (env, default 0). No CLI args.
# Outputs:  [PASS]/[SKIP]/[FAIL] line on stdout + evidence under
#           qa-results/regression/mullvad_egress_config/.
#           Exit 0=PASS, 1=FAIL, 2=SKIP (§11.4.3 topology). Secret values are
#           NEVER emitted to stdout or the evidence file (§11.4.10).
# Side-effects: writes one evidence file; RED writes one temp fixture (removed
#               on exit). No container/network access.
# Dependencies: sh (POSIX), grep, head, sed, tr, mktemp.
# Cross-references:
#   - Proven config: .env (gitignored §11.4.10) VPN_SERVICE_PROVIDER=mullvad +
#     WireGuard vars; documented placeholders in .env.example.
#   - Sibling guards: tests/regression/vpn_failclosed_reason_test.sh,
#     tests/regression/port_prefix_34xxx_test.sh.
# Shell: POSIX-clean (sh -n + bash -n, §11.4.67).
#######################################################################
set -eu

RED_MODE="${RED_MODE:-0}"
REPO_ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
ENV_FILE="$REPO_ROOT/.env"
EXAMPLE_FILE="$REPO_ROOT/.env.example"
EVID_DIR="$REPO_ROOT/qa-results/regression/mullvad_egress_config"
mkdir -p "$EVID_DIR"
EVID_FILE="$EVID_DIR/mullvad_egress_config.$$.txt"

# --- Extract one env value WITHOUT sourcing (sourcing could execute code) and
#     WITHOUT echoing it to any terminal. The value is emitted ONLY to a command
#     substitution the caller assigns to a local variable — never printed. ---
env_get() { # $1 = var name, $2 = file
    grep -E "^$1=" "$2" 2>/dev/null | head -n1 | sed -E "s/^$1=//" | tr -d '\r'
}

# --- The single source of truth for "is this a valid mullvad-native WG config".
#     Drives BOTH GREEN (real .env) and RED (broken fixture). Populates the
#     V_* result booleans (booleans only — NO secret values) for evidence.
#     The WIREGUARD_PRIVATE_KEY value is read into a LOCAL var, checked for
#     SHAPE, then scrubbed; it is NEVER printed/logged (§11.4.10). ---
V_provider=0; V_type=0; V_key=0; V_addr=0
validate_mullvad_env() { # $1 = env-file path
    _f="$1"
    _provider="$(env_get VPN_SERVICE_PROVIDER "$_f")"
    _vtype="$(env_get VPN_DEFAULT_TYPE "$_f")"
    _key="$(env_get WIREGUARD_PRIVATE_KEY "$_f")"
    _addrs="$(env_get WIREGUARD_ADDRESSES "$_f")"

    # strip one optional layer of surrounding quotes on the non-secret fields
    case "$_provider" in \"*\") _provider="${_provider#\"}"; _provider="${_provider%\"}";; esac
    case "$_vtype"    in \"*\") _vtype="${_vtype#\"}";       _vtype="${_vtype%\"}";;       esac

    V_provider=0; if [ "$_provider" = "mullvad" ]; then V_provider=1; fi
    V_type=0;     if [ "$_vtype" = "wireguard" ]; then V_type=1; fi

    # key SHAPE: non-empty, >=40 chars, base64-shaped. Value NEVER printed.
    V_key=0
    _keylen=${#_key}
    if [ "$_keylen" -ge 40 ]; then
        if printf '%s' "$_key" | grep -qE '^[A-Za-z0-9+/]{42,}=?$'; then
            V_key=1
        fi
    fi
    _key=""   # scrub the secret from memory as soon as the shape is known

    # addresses: valid CIDR. Value NEVER printed.
    V_addr=0
    if printf '%s' "$_addrs" | grep -qE '^[0-9.]+/[0-9]+$'; then
        V_addr=1
    fi
    _addrs=""

    if [ "$V_provider" = 1 ] && [ "$V_type" = 1 ] && [ "$V_key" = 1 ] && [ "$V_addr" = 1 ]; then
        return 0
    fi
    return 1
}

# --- .env.example must still DOCUMENT the four vars (names only) so a fresh
#     checkout knows what to provision. Checks presence, NOT values. ---
example_documents() {
    [ -f "$EXAMPLE_FILE" ] || return 1
    for _v in VPN_SERVICE_PROVIDER VPN_DEFAULT_TYPE WIREGUARD_PRIVATE_KEY WIREGUARD_ADDRESSES; do
        grep -qE "^$_v=" "$EXAMPLE_FILE" || return 1
    done
    return 0
}

verdict=FAIL
exit_code=1
{
    echo "Mullvad WireGuard egress config shape guard — §11.4.135/§11.4.115/§11.4.10"
    echo "timestamp_utc: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "RED_MODE: $RED_MODE"
    echo "legend: V_provider/V_type/V_key/V_addr are SHAPE booleans (1=ok); secret VALUES are never recorded (§11.4.10)"
} >"$EVID_FILE"

if [ "$RED_MODE" = "1" ]; then
    # --- Reproduce the DEFECT: a broken config (the .env.example placeholder
    #     shape) MUST be rejected by the SAME validator. ---
    FIX_FILE="$(mktemp)"
    trap 'rm -f "$FIX_FILE"' EXIT INT TERM
    {
        printf 'VPN_SERVICE_PROVIDER=custom\n'
        printf 'VPN_DEFAULT_TYPE=wireguard\n'
        printf 'WIREGUARD_PRIVATE_KEY=\n'
        printf 'WIREGUARD_ADDRESSES=\n'
    } >"$FIX_FILE"

    if validate_mullvad_env "$FIX_FILE"; then
        msg="RED could-not-reproduce: validator ACCEPTED a broken config (provider=custom, empty key, empty addrs) — §11.4.7 finding (GREEN would be a tautology)"
    else
        verdict=PASS; exit_code=0
        msg="RED reproduced: validator REJECTS a broken config (provider=custom, empty key, empty addrs) — the mullvad-native shape check has teeth"
    fi
    {
        echo "fixture (synthesized broken config): provider=custom, empty key, empty addrs"
        echo "fixture shape booleans: V_provider=$V_provider V_type=$V_type V_key=$V_key V_addr=$V_addr"
    } >>"$EVID_FILE"
else
    if [ ! -f "$ENV_FILE" ]; then
        verdict=SKIP; exit_code=2
        msg=".env absent — fresh-checkout topology (§11.4.3); operator has not provisioned the Mullvad WG creds yet, GREEN validation not applicable (NOT a fake PASS)"
        echo "env_present: no" >>"$EVID_FILE"
    else
        if validate_mullvad_env "$ENV_FILE"; then env_valid=1; else env_valid=0; fi
        if example_documents; then ex_ok=1; else ex_ok=0; fi
        {
            echo "env_present: yes"
            echo ".env shape booleans: V_provider=$V_provider V_type=$V_type V_key=$V_key V_addr=$V_addr"
            echo ".env.example documents all 4 vars: $([ "$ex_ok" = 1 ] && echo yes || echo no)"
        } >>"$EVID_FILE"

        if [ "$env_valid" = 1 ] && [ "$ex_ok" = 1 ]; then
            verdict=PASS; exit_code=0
            msg="GREEN: .env carries a valid gluetun mullvad-native WG config (provider=mullvad, type=wireguard, base64-shaped key, valid CIDR addrs) AND .env.example documents all 4 vars"
        elif [ "$ex_ok" != 1 ]; then
            msg="REGRESSION: .env.example no longer documents all 4 Mullvad/WG vars (fresh checkout would not know what to provision)"
        else
            msg="REGRESSION: .env Mullvad WG config invalid — provider_ok=$V_provider type_ok=$V_type key_shape_ok=$V_key addr_cidr_ok=$V_addr (secret values NEVER printed — §11.4.10)"
        fi
    fi
fi

{
    echo "verdict: $verdict"
    echo "detail: $msg"
} >>"$EVID_FILE"
echo "[$verdict] mullvad-egress-config (RED_MODE=$RED_MODE): $msg"
echo "evidence: $EVID_FILE"
exit "$exit_code"
