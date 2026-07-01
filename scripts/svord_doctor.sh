#!/usr/bin/env sh
###############################################################################
# svord_doctor.sh — VPN-LAN svord bridge preflight doctor (PLAN.md §5, Phase 0)
#
# Purpose:
#   Deterministically decide whether the env-var svord bridge contract
#   (PLAN.md §3) is UP, DOWN (operator-blocked), or MISCONFIGURED — and emit a
#   single machine-parseable verdict line. Every downstream VPN-LAN test runs
#   this first; a DOWN/MISCONFIGURED verdict means those tests honestly SKIP
#   (§11.4.3), NEVER a fake PASS. The doctor never fakes UP: UP requires the
#   authoritative health probe to succeed AND the remote host to be reachable.
#
# Usage:
#   scripts/svord_doctor.sh
#   # Reads the contract from the environment (source your .env first, e.g.
#   # `set -a; . ./.env; set +a; scripts/svord_doctor.sh`).
#   # Optional override for testing: SVORD_BRIDGE_LIB=/path/to/svord_bridge.sh
#
# Inputs (environment — PLAN.md §3 contract):
#   HELIX_SVORD_DIR, HELIX_BRIDGE_CONNECT, HELIX_BRIDGE_DISCONNECT,
#   HELIX_BRIDGE_HEALTH, HELIX_BRIDGE_SUBNET, HELIX_BRIDGE_HOST
#   SVORD_BRIDGE_LIB (optional) — path to tests/lib/svord_bridge.sh override.
#
# Outputs:
#   Diagnostic lines prefixed `svord-doctor:` on stdout, then exactly ONE final
#   verdict line matching `^BRIDGE: `:
#     BRIDGE: UP                                   (exit 0)
#     BRIDGE: SKIP:network_unreachable_external    (exit 2 — down/blocked)
#     BRIDGE: SKIP:host_probe_unavailable          (exit 2 — cannot confirm)
#     BRIDGE: MISCONFIGURED:<reason>               (exit 3 — bad contract)
#   Exit codes: 0 == up, 2 == down/operator-blocked, 3 == misconfigured.
#
# Side-effects:
#   Runs HELIX_BRIDGE_HEALTH (operator-supplied) and one ping/nc smoke probe to
#   HELIX_BRIDGE_HOST. Performs NO writes; modifies NOTHING on the bridge
#   project or any remote host (invocation-only, §11.4.122).
#
# Dependencies:
#   POSIX sh; tests/lib/svord_bridge.sh; `ping` (preferred) or `nc` for the
#   host smoke probe.
#
# Cross-references:
#   docs/design/vpn_lan_access/PLAN.md §3 + §5 Phase 0
#   tests/lib/svord_bridge.sh          (contract library sourced below)
#   docs/scripts/svord_doctor.md       (companion doc, §11.4.18)
#   constitution §11.4.3 / §11.4.28 / §11.4.68 / §11.4.69
###############################################################################

set -u

# ---- resolve + source the bridge contract library ---------------------------
_sd_script_dir=$(cd "$(dirname "$0")" && pwd)
_sd_repo_root=$(cd "$_sd_script_dir/.." && pwd)
SVORD_BRIDGE_LIB="${SVORD_BRIDGE_LIB:-$_sd_repo_root/tests/lib/svord_bridge.sh}"

log() { printf 'svord-doctor: %s\n' "$1"; }
verdict() { printf 'BRIDGE: %s\n' "$1"; }

if [ ! -f "$SVORD_BRIDGE_LIB" ]; then
    log "bridge library not found: $SVORD_BRIDGE_LIB"
    verdict 'MISCONFIGURED:bridge_lib_missing'
    exit 3
fi
# shellcheck disable=SC1090
. "$SVORD_BRIDGE_LIB"

# ---- helper: first whitespace token of a command string ---------------------
# (word-splitting is intentional; guarded for set -u via ${1:-}).
hook_first_token() {
    # shellcheck disable=SC2086
    set -- $1
    printf '%s\n' "${1:-}"
}

# ---- helper: is a host reachable? -------------------------------------------
# rc 0 = reachable, 1 = not reachable, 3 = no probe tool available (cannot tell).
host_reachable() {
    _hr_host="$1"
    if command -v ping >/dev/null 2>&1; then
        if ping -c1 -W1 "$_hr_host" >/dev/null 2>&1; then
            return 0
        fi
        # ping present but failed: try a TCP fallback before declaring down,
        # since ICMP may be filtered while TCP is open.
        if command -v nc >/dev/null 2>&1; then
            for _hr_port in 22 80 443 445; do
                if nc -z -w1 "$_hr_host" "$_hr_port" >/dev/null 2>&1; then
                    return 0
                fi
            done
        fi
        return 1
    fi
    if command -v nc >/dev/null 2>&1; then
        for _hr_port in 22 80 443 445; do
            if nc -z -w1 "$_hr_host" "$_hr_port" >/dev/null 2>&1; then
                return 0
            fi
        done
        return 1
    fi
    return 3
}

# ---- 1. contract resolvable? ------------------------------------------------
if ! bridge_load 2>/dev/null; then
    # Re-run without suppression so the operator sees which vars are unset.
    bridge_load >/dev/null 2>&1 || bridge_load 2>&1 | while IFS= read -r _sd_line; do
        log "$_sd_line"
    done
    log 'contract not resolvable from the environment (source your .env first)'
    verdict 'MISCONFIGURED:env_unset'
    exit 3
fi
log "contract resolved (subnet=$(bridge_subnet) host=$(bridge_host))"

# ---- 2. each hook path present + executable? --------------------------------
_sd_hook_bad=''
for _sd_hook in HELIX_BRIDGE_CONNECT HELIX_BRIDGE_DISCONNECT HELIX_BRIDGE_HEALTH; do
    eval "_sd_cmd=\${$_sd_hook:-}"
    _sd_path=$(hook_first_token "$_sd_cmd")
    if [ -z "$_sd_path" ]; then
        log "$_sd_hook: empty command"
        _sd_hook_bad="$_sd_hook_bad $_sd_hook"
        continue
    fi
    if [ ! -e "$_sd_path" ]; then
        log "$_sd_hook: hook path not found: $_sd_path"
        _sd_hook_bad="$_sd_hook_bad $_sd_hook"
        continue
    fi
    if [ ! -x "$_sd_path" ]; then
        log "$_sd_hook: hook path not executable: $_sd_path"
        _sd_hook_bad="$_sd_hook_bad $_sd_hook"
        continue
    fi
    log "$_sd_hook: OK ($_sd_path)"
done
if [ -n "$_sd_hook_bad" ]; then
    verdict "MISCONFIGURED:hook_not_executable:${_sd_hook_bad# }"
    exit 3
fi

# ---- 3. authoritative health probe (exit 0 == up)? --------------------------
if ! bridge_up; then
    log 'HELIX_BRIDGE_HEALTH reported the bridge DOWN (non-zero exit)'
    verdict 'SKIP:network_unreachable_external'
    exit 2
fi
log 'HELIX_BRIDGE_HEALTH: UP (exit 0)'

# ---- 4. remote host smoke reachability --------------------------------------
_sd_host=$(bridge_host)
host_reachable "$_sd_host"
_sd_hr=$?
if [ "$_sd_hr" -eq 1 ]; then
    log "HELIX_BRIDGE_HOST unreachable: $_sd_host"
    verdict 'SKIP:network_unreachable_external'
    exit 2
fi
if [ "$_sd_hr" -eq 3 ]; then
    log 'no host probe tool (ping/nc) available — cannot confirm reachability'
    verdict 'SKIP:host_probe_unavailable'
    exit 2
fi
log "HELIX_BRIDGE_HOST reachable: $_sd_host"

# ---- verdict: genuinely UP --------------------------------------------------
verdict 'UP'
exit 0
