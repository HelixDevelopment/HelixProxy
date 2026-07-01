#!/usr/bin/env sh
###############################################################################
# svord_bridge.sh — sourceable helix_proxy <-> VPN-LAN bridge contract library
#
# Purpose:
#   Resolve + validate the env-var bridge contract (PLAN.md §3) that decouples
#   helix_proxy from the sibling `svord_toolkit` VPN bridge (§11.4.28), and
#   expose small, anti-bluff primitives every VPN-LAN test uses to decide
#   up / down / operator-blocked. NO svord path is hardcoded here — everything
#   is read from the environment.
#
# Usage:
#   . "tests/lib/svord_bridge.sh"          # source it (POSIX sh or bash)
#   bridge_load   || echo "contract unset" # validate the 6 contract vars
#   bridge_up     && echo "vpn up"         # run HELIX_BRIDGE_HEALTH (0 == up)
#   bridge_require || exit $?              # echo SKIP-reason + return 2 if down
#   subnet=$(bridge_subnet)                # accessor: HELIX_BRIDGE_SUBNET
#   host=$(bridge_host)                    # accessor: HELIX_BRIDGE_HOST
#
# Inputs (environment — the PLAN.md §3 contract, real values live in .env):
#   HELIX_SVORD_DIR          path to the sibling bridge project
#   HELIX_BRIDGE_CONNECT     command that brings the VPN up
#   HELIX_BRIDGE_DISCONNECT  command that tears the VPN down
#   HELIX_BRIDGE_HEALTH      health probe (exit 0 == up) — authoritative signal
#   HELIX_BRIDGE_SUBNET      reachable remote subnet (CIDR)
#   HELIX_BRIDGE_HOST        known remote host for smoke reachability
#
# Outputs:
#   bridge_load     : return 0 when all 6 vars are set+non-empty, else 1
#                     (names of the unset vars printed to stderr).
#   bridge_up       : return 0 when HELIX_BRIDGE_HEALTH exits 0, else 1.
#   bridge_require  : return 0 when up; when down echoes the closed-set SKIP
#                     reason `network_unreachable_external` to stdout and
#                     returns 2 (OPERATOR-BLOCKED per §11.4.68 / §11.4.69);
#                     returns 3 (misconfigured) when the contract is unset.
#   bridge_subnet   : prints HELIX_BRIDGE_SUBNET (empty if unset).
#   bridge_host     : prints HELIX_BRIDGE_HOST   (empty if unset).
#
# Side-effects:
#   None persistent. bridge_up runs the operator-supplied HELIX_BRIDGE_HEALTH
#   command in a subshell. This library performs NO writes and NEVER modifies
#   the bridge project or any remote host (invocation-only, §11.4.122).
#
# Dependencies:
#   POSIX sh, and whatever HELIX_BRIDGE_HEALTH itself needs. The library is
#   `set -u`-safe (every expansion is defaulted) whether or not the caller has
#   `set -u` active; it deliberately does NOT toggle the caller's shell options.
#
# Cross-references:
#   docs/design/vpn_lan_access/PLAN.md §3 (contract) + §5 Phase 0
#   scripts/svord_doctor.sh                 (preflight consumer of this lib)
#   docs/scripts/svord_doctor.md            (companion doc, §11.4.18)
#   constitution §11.4.3 / §11.4.28 / §11.4.68 / §11.4.69
###############################################################################

# The closed-set of contract variable names (PLAN.md §3). Kept in one place so
# bridge_load and consumers agree on exactly what "the contract" is.
SVORD_BRIDGE_CONTRACT_VARS='HELIX_SVORD_DIR HELIX_BRIDGE_CONNECT HELIX_BRIDGE_DISCONNECT HELIX_BRIDGE_HEALTH HELIX_BRIDGE_SUBNET HELIX_BRIDGE_HOST'

# bridge_load — resolve + validate the contract. Returns 1 (and lists the
# offending names on stderr) when ANY contract var is unset or empty.
bridge_load() {
    _bl_missing=''
    for _bl_var in $SVORD_BRIDGE_CONTRACT_VARS; do
        # POSIX indirect expansion, set -u-safe via the :- default.
        eval "_bl_val=\${$_bl_var:-}"
        if [ -z "$_bl_val" ]; then
            _bl_missing="$_bl_missing $_bl_var"
        fi
    done
    if [ -n "$_bl_missing" ]; then
        echo "bridge_load: contract unset/empty:${_bl_missing}" >&2
        return 1
    fi
    return 0
}

# bridge_up — run the authoritative health probe. Exit 0 == VPN reachable.
# Returns 1 when the contract is unset OR the health probe exits non-zero.
bridge_up() {
    bridge_load || return 1
    # Run the operator-supplied health command. Using `sh -c` lets the value be
    # a full command line (e.g. "${HELIX_SVORD_DIR}/svord-ssh-health --quiet")
    # and re-expands any residual $VARS from the environment. Output suppressed;
    # only the exit status matters.
    sh -c "${HELIX_BRIDGE_HEALTH:-false}" >/dev/null 2>&1
}

# bridge_require — gate for downstream tests. Honest SKIP when down, never a
# fake PASS (§11.4.3 / §11.4.68 / §11.4.69).
#   up            -> return 0 (caller proceeds)
#   contract unset-> echo SKIP:misconfigured        + return 3
#   down          -> echo SKIP:network_unreachable_external + return 2
bridge_require() {
    if ! bridge_load; then
        echo 'SKIP:misconfigured'
        return 3
    fi
    if bridge_up; then
        return 0
    fi
    echo 'SKIP:network_unreachable_external'
    return 2
}

# bridge_subnet — accessor for the reachable remote subnet (CIDR). Empty when
# unset; the caller decides how to treat an empty value.
bridge_subnet() {
    printf '%s\n' "${HELIX_BRIDGE_SUBNET:-}"
}

# bridge_host — accessor for the smoke-reachability remote host. Empty when
# unset.
bridge_host() {
    printf '%s\n' "${HELIX_BRIDGE_HOST:-}"
}
