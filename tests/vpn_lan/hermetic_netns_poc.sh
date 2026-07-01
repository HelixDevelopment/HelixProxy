#!/usr/bin/env bash
###############################################################################
# hermetic_netns_poc.sh — H0 feasibility proof for the hermetic WireGuard test
#                         harness (docs/design/vpn_lan_access/hermetic_wg_test_harness.md)
#
# Purpose:
#   Prove — with real captured evidence, deterministically, and fully
#   UNPRIVILEGED — that the hermetic-namespace substrate underneath the planned
#   WireGuard test harness works on this host: two network namespaces joined by
#   an L3 link, a REAL HTTP service in the peer namespace, its payload fetched
#   from the other side and sha256-verified byte-for-byte. This is the
#   substrate on which H0-full swaps the plain veth for a userspace-WireGuard
#   tunnel (wireguard-go) and H1/H2 add the real SMB/FTP/WebDAV/DIAL services so
#   the operator-gated protocol tests can run autonomously (§11.4.52).
#
#   NOTE (honest scope, §11.4.6): this PoC uses a veth pair, NOT yet WireGuard.
#   It proves the netns + L3-round-trip + rootless feasibility — the exact shape
#   the WireGuard tunnel later occupies. It does NOT itself exercise WireGuard.
#
# Usage:
#   tests/vpn_lan/hermetic_netns_poc.sh          # PASS / SKIP / FAIL verdict
#   POC_MUT=1 tests/vpn_lan/hermetic_netns_poc.sh  # §1.1 golden-bad — must FAIL
#   (internal) hermetic_netns_poc.sh --inner     # the in-namespace body
#
# Outputs:
#   One PASS/SKIP/FAIL line. Exit 0 == PASS or honest SKIP; 1 == FAIL (or, under
#   POC_MUT=1, exit 1 is the REQUIRED result — the sha256 teeth caught the
#   tamper §11.4.107(10)). Evidence:
#   qa-results/vpn_lan/hermetic/<UTC-ts>/roundtrip.evidence
#
# Preflight / honest SKIP (§11.4.3 — never a fake PASS):
#   SKIP when the host disables unprivileged user namespaces, when unshare /
#   ip / nsenter / python3 are absent, or when process headroom is too low to
#   safely fork the (bounded, ~4-process) namespace set (§12 host-safety).
#
# Side-effects:
#   Creates ONE throwaway user+net+mount namespace via `unshare -Urnm`; every
#   process + interface it makes lives inside that namespace and is torn down
#   automatically when unshare exits (§11.4.14). NOTHING on the host network is
#   touched or visible (§11.4.174-safe by construction). No writes outside
#   qa-results + a private mktemp.
#
# Dependencies: bash, util-linux unshare + nsenter, iproute2 ip, python3,
#   sha256sum, /dev/net/tun (for the later WireGuard phase, not this PoC).
#
# Cross-references:
#   docs/design/vpn_lan_access/hermetic_wg_test_harness.md (the design)
#   tests/lib/svord_bridge.sh (HELIX_BRIDGE_MODE=hermetic integration, H2)
#   constitution §11.4.3 / §11.4.6 / §11.4.50 / §11.4.52 / §11.4.107 / §11.4.174 / §12
###############################################################################
set -u

# ---------------------------------------------------------------------------
# INNER: runs inside `unshare -Urnm` (uid is 0-in-userns). Builds the two-netns
# L3 link, serves a real payload in the peer, fetches + verifies it.
# ---------------------------------------------------------------------------
if [ "${1:-}" = "--inner" ]; then
    EV="${POC_EV_DIR:?}/roundtrip.evidence"; mkdir -p "${POC_EV_DIR}"; : >"$EV"
    log(){ printf '%s\n' "$*" | tee -a "$EV"; }
    fail(){ log "POC_FAIL: $*"; exit 1; }

    log "== uid inside userns: $(id -u) (0 == root-in-userns) =="
    ip link set lo up 2>>"$EV" || fail "lo up (outer)"
    ip link add veth0 type veth peer name veth1 2>>"$EV" || fail "veth add (CAP_NET_ADMIN in userns)"

    # Peer netns = a held child in its own new netns. It touches a marker FROM
    # INSIDE its swapped netns, so the marker existing deterministically means
    # veth1 will land in the child netns, not the pre-swap parent (race fix).
    MARK=$(mktemp -u)
    unshare -n bash -c "touch '$MARK'; exec sleep 60" &
    HOLDER=$!
    cleanup(){ kill "$HOLDER" 2>/dev/null; [ -n "${SRV:-}" ] && kill "$SRV" 2>/dev/null; rm -f "$MARK" 2>/dev/null; true; }
    trap cleanup EXIT INT TERM
    for _ in $(seq 1 50); do [ -e "$MARK" ] && break; sleep 0.1; done
    [ -e "$MARK" ] || fail "holder netns not ready (marker never appeared)"
    rm -f "$MARK" 2>/dev/null || true
    [ -e "/proc/$HOLDER/ns/net" ] || fail "holder pid gone"

    ip link set veth1 netns "$HOLDER" 2>>"$EV" || fail "move veth1 into peer netns"
    ip addr add 10.9.0.1/24 dev veth0 2>>"$EV" || fail "addr veth0"
    ip link set veth0 up 2>>"$EV" || fail "veth0 up"
    nsenter -t "$HOLDER" -n ip link set lo up 2>>"$EV" || fail "peer lo up"
    nsenter -t "$HOLDER" -n ip addr add 10.9.0.2/24 dev veth1 2>>"$EV" || fail "peer addr"
    nsenter -t "$HOLDER" -n ip link set veth1 up 2>>"$EV" || fail "peer veth1 up"

    SRVDIR=$(mktemp -d)
    NONCE="hermetic-netns-proof-$$-${RANDOM}"
    printf '%s\n' "$NONCE" > "$SRVDIR/payload.txt"
    SHA_SRC=$(sha256sum "$SRVDIR/payload.txt" | cut -d' ' -f1)
    # §11.4.107(10) golden-bad: corrupt what the server serves AFTER fixing
    # SHA_SRC, so a load-bearing sha256 check MUST catch the mismatch.
    if [ "${POC_MUT:-0}" = 1 ]; then printf 'TAMPERED\n' >> "$SRVDIR/payload.txt"; log "MUT: payload tampered post-hash — teeth must FAIL"; fi
    ( cd "$SRVDIR" && exec nsenter -t "$HOLDER" -n python3 -m http.server 8080 --bind 10.9.0.2 ) >/dev/null 2>&1 &
    SRV=$!
    UP=0
    for _ in $(seq 1 30); do
        if python3 -c 'import socket,sys; s=socket.socket(); s.settimeout(0.3); sys.exit(0 if s.connect_ex(("10.9.0.2",8080))==0 else 1)' 2>/dev/null; then UP=1; break; fi
        sleep 0.2
    done
    [ "$UP" = 1 ] || fail "peer HTTP service never accepted on 10.9.0.2:8080"

    BODY=$(python3 -c 'import urllib.request; print(urllib.request.urlopen("http://10.9.0.2:8080/payload.txt", timeout=5).read().decode().rstrip("\n"))' 2>>"$EV") || fail "fetch across link"
    SHA_GOT=$(printf '%s\n' "$BODY" | sha256sum | cut -d' ' -f1)
    log "peer-served nonce : $NONCE"
    log "fetched body      : $BODY"
    log "sha256 source     : $SHA_SRC"
    log "sha256 fetched    : $SHA_GOT"
    rm -rf "$SRVDIR" 2>/dev/null || true
    { [ "$SHA_SRC" = "$SHA_GOT" ] && [ "$BODY" = "$NONCE" ]; } || fail "sha256/body mismatch (src=$SHA_SRC got=$SHA_GOT)"
    log "POC_PASS: real HTTP payload round-tripped across a 2-netns L3 link, sha256 verified, fully unprivileged"
    exit 0
fi

# ---------------------------------------------------------------------------
# OUTER: preflight (honest SKIP §11.4.3 / §12) then re-exec the body under
# `unshare -Urnm`, evaluate the verdict.
# ---------------------------------------------------------------------------
SCRIPT_LABEL='hermetic_netns_poc'
_sd=$(cd "$(dirname "$0")" && pwd); _root=$(cd "$_sd/../.." && pwd)
POC_MUT="${POC_MUT:-0}"

_skip(){ printf 'SKIP: %s [%s]\n' "$SCRIPT_LABEL" "$1"; exit 0; }
for _t in unshare nsenter ip python3 sha256sum; do command -v "$_t" >/dev/null 2>&1 || _skip "tool absent: $_t"; done
# unprivileged-userns kill switch (where the knob exists)
if [ -r /proc/sys/kernel/unprivileged_userns_clone ] && [ "$(cat /proc/sys/kernel/unprivileged_userns_clone)" = 0 ]; then
    _skip "unprivileged user namespaces disabled (kernel.unprivileged_userns_clone=0)"
fi
# does an unprivileged user+net namespace actually work here?
if ! unshare -Ur -n true 2>/dev/null; then _skip "unshare -Ur -n failed (unprivileged userns unavailable)"; fi
# §12 host-safety: refuse to add fork pressure to a starved host
_softu=$(ulimit -u 2>/dev/null || echo 0)
_nproc=$(ps --no-headers -u "$(id -u)" 2>/dev/null | wc -l | tr -d ' ')
if [ "${_softu}" != "unlimited" ] && [ "${_softu:-0}" -gt 0 ] 2>/dev/null && [ "$(( _softu - _nproc ))" -lt 64 ] 2>/dev/null; then
    _skip "process headroom too low (ulimit -u=${_softu}, in use=${_nproc}) — §12 host-safety"
fi

TS=$(date -u +%Y%m%dT%H%M%SZ 2>/dev/null || date +%Y%m%dT%H%M%SZ)
if [ "$POC_MUT" = 1 ]; then _mode=mut; else _mode=pass; fi
export POC_EV_DIR="$_root/qa-results/vpn_lan/hermetic/${TS}_${_mode}_$$"
_rc=0
POC_MUT="$POC_MUT" timeout 45 env POC_EV_DIR="$POC_EV_DIR" POC_MUT="$POC_MUT" \
    unshare -Urnm bash "$0" --inner >/dev/null 2>&1 || _rc=$?
_ev="$POC_EV_DIR/roundtrip.evidence"

if [ "$POC_MUT" = 1 ]; then
    # golden-bad: the ONLY acceptable outcome is a FAIL at the sha256 check.
    if [ "$_rc" != 0 ] && grep -q 'sha256/body mismatch' "$_ev" 2>/dev/null; then
        printf 'PASS: %s [§1.1 golden-bad — tamper caught by the sha256 teeth; load-bearing; evidence: %s]\n' "$SCRIPT_LABEL" "$_ev"; exit 0
    fi
    printf 'FAIL: %s [§1.1 mutation did NOT fail at the sha256 check (rc=%s) — teeth not proven]\n' "$SCRIPT_LABEL" "$_rc"; exit 1
fi

if [ "$_rc" = 0 ] && grep -q POC_PASS "$_ev" 2>/dev/null; then
    printf 'PASS: %s [hermetic 2-netns L3 round-trip, sha256-verified, unprivileged; evidence: %s]\n' "$SCRIPT_LABEL" "$_ev"; exit 0
fi
printf 'FAIL: %s [rc=%s; evidence: %s]\n' "$SCRIPT_LABEL" "$_rc" "$_ev"
tail -3 "$_ev" 2>/dev/null || true
exit 1
