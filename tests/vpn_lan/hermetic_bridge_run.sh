#!/usr/bin/env bash
###############################################################################
# hermetic_bridge_run.sh — H2: run a REAL operator-gated VPN-LAN protocol test
#   AUTONOMOUSLY over the hermetic kernel-WireGuard tunnel (HELIX_BRIDGE_MODE=hermetic).
#   (docs/design/vpn_lan_access/hermetic_wg_test_harness.md — H2)
#
# Purpose:
#   Prove the hermetic harness actually PROMOTES an operator-gated protocol test
#   (§11.4.52): it stands up the H0-full WireGuard tunnel between two unprivileged
#   netns, runs a REAL peer service in netns B (bound to the WG-only overlay
#   10.10.0.2), points the bridge contract (tests/lib/svord_bridge.sh) at that peer
#   via HELIX_BRIDGE_MODE=hermetic, then runs the UNMODIFIED protocol test INSIDE
#   netns A. The test's own `bridge_require` gate flips from honest-SKIP to UP and
#   it produces a REAL PASS with captured evidence — no operator, no podman, no
#   Mullvad. The real svord/Mullvad run stays the §11.4.3 real-topology confirmation.
#
#   First promotion: chromecast_dial.sh T6.2 (eureka_info control leg) — a peer
#   HTTP eureka_info JSON served at 10.10.0.2:8008/setup/eureka_info; the test GETs
#   it over the tunnel and asserts a real device `name`. The pattern generalises to
#   the other protocols (each needs its own unprivileged peer server in H2.x).
#
# Usage:
#   tests/vpn_lan/hermetic_bridge_run.sh              # PASS / SKIP / FAIL
#   H2_MUT=badeureka tests/vpn_lan/hermetic_bridge_run.sh  # §1.1 golden-bad: the peer
#     serves a 200 body WITHOUT a `name` field => the REAL test must FAIL (proving
#     the promotion exercises the genuine assertion, not a rubber-stamp).
#   (internal) hermetic_bridge_run.sh --inner
#
# Outputs:
#   One PASS/SKIP/FAIL line. Evidence:
#   qa-results/vpn_lan/hermetic_bridge/<UTC-ts>_<pass|mut>_<pid>/run.evidence
#   (the promoted test also writes its own qa-results/vpn_lan/phase6/... evidence).
#
# Preflight / honest SKIP (§11.4.3): kernel `wireguard` module, unshare/nsenter/ip/
#   wg/python3/curl, unprivileged userns, process headroom (§12) — else SKIP, never fake.
#
# Side-effects:
#   ONE throwaway user+net+mount namespace (unshare -Urnm); the tunnel + peer server
#   + the promoted test all live inside it and die with unshare (§11.4.14). Nothing
#   on the host network touched/visible (§11.4.174). WG keys mode-0600 in-namespace,
#   never logged (§11.4.10).
#
# Dependencies: bash, unshare+nsenter, iproute2 ip (wireguard link type), wg, host
#   `wireguard` kernel module, python3, curl, jq (chromecast_dial.sh uses jq/grep).
#
# Cross-references:
#   tests/vpn_lan/hermetic_wg_roundtrip.sh (the H0-full tunnel this reuses)
#   tests/vpn_lan/chromecast_dial.sh        (the promoted protocol test)
#   tests/lib/svord_bridge.sh               (bridge contract; HELIX_BRIDGE_MODE=hermetic)
#   docs/design/vpn_lan_access/hermetic_wg_test_harness.md (H2)
#   constitution §11.4.3 / §11.4.6 / §11.4.10 / §11.4.52 / §11.4.107 / §11.4.174 / §12
###############################################################################
set -u
export PATH="$PATH:/usr/sbin:/sbin"

if [ "${1:-}" = "--inner" ]; then
    EV="${H2_EV_DIR:?}/run.evidence"; mkdir -p "${H2_EV_DIR}"; : >"$EV"
    _root="${H2_ROOT:?}"
    log(){ printf '%s\n' "$*" | tee -a "$EV"; }
    fail(){ log "H2_FAIL: $*"; exit 1; }
    WG=$(command -v wg 2>/dev/null || echo /usr/sbin/wg)

    # ---- WG tunnel (as H0-full) ----
    ip link set lo up 2>>"$EV" || fail "lo up"
    ip link add veth0 type veth peer name veth1 2>>"$EV" || fail "veth add"
    MARK=$(mktemp -u); unshare -n bash -c "touch '$MARK'; exec sleep 90" & HOLDER=$!
    KDIR=$(mktemp -d); SRVDIR=$(mktemp -d)
    cleanup(){ kill "$HOLDER" 2>/dev/null; [ -n "${SRV:-}" ] && kill "$SRV" 2>/dev/null; rm -rf "$KDIR" "$SRVDIR" "$MARK" 2>/dev/null; true; }
    trap cleanup EXIT INT TERM
    for _ in $(seq 1 50); do [ -e "$MARK" ] && break; sleep 0.1; done
    [ -e "$MARK" ] || fail "holder netns not ready"; rm -f "$MARK"
    [ -e "/proc/$HOLDER/ns/net" ] || fail "holder pid gone"
    ip link set veth1 netns "$HOLDER" 2>>"$EV" || fail "move veth1"
    ip addr add 10.9.0.1/24 dev veth0 2>>"$EV" || fail "addr veth0"; ip link set veth0 up 2>>"$EV" || fail "underlay A"
    nsenter -t "$HOLDER" -n ip link set lo up 2>>"$EV" || fail "peer lo up"
    nsenter -t "$HOLDER" -n ip addr add 10.9.0.2/24 dev veth1 2>>"$EV" || fail "peer addr veth1"
    nsenter -t "$HOLDER" -n ip link set veth1 up 2>>"$EV" || fail "underlay B"
    umask 077
    "$WG" genkey >"$KDIR/a.key" 2>>"$EV" || fail "wg genkey (userns?)"; "$WG" pubkey <"$KDIR/a.key" >"$KDIR/a.pub" || fail "wg pubkey A"
    "$WG" genkey >"$KDIR/b.key" 2>>"$EV" || fail "wg genkey B"; "$WG" pubkey <"$KDIR/b.key" >"$KDIR/b.pub" 2>>"$EV" || fail "wg pubkey B"
    PUB_A=$(cat "$KDIR/a.pub"); PUB_B=$(cat "$KDIR/b.pub")
    [ -n "$PUB_A" ] && [ -n "$PUB_B" ] || fail "empty WG pubkey (keygen failed)"
    ip link add wg0 type wireguard 2>>"$EV" || fail "wg0 add A (kernel module?)"
    "$WG" set wg0 private-key "$KDIR/a.key" listen-port 51820 peer "$PUB_B" endpoint 10.9.0.2:51820 allowed-ips 10.10.0.2/32 persistent-keepalive 5 2>>"$EV" || fail "wg set A"
    ip addr add 10.10.0.1/24 dev wg0 2>>"$EV" || fail "addr wg0 A"; ip link set wg0 up 2>>"$EV" || fail "wg0 up A"
    nsenter -t "$HOLDER" -n ip link add wg0 type wireguard 2>>"$EV" || fail "wg0 add B"
    nsenter -t "$HOLDER" -n "$WG" set wg0 private-key "$KDIR/b.key" listen-port 51820 peer "$PUB_A" endpoint 10.9.0.1:51820 allowed-ips 10.10.0.1/32 persistent-keepalive 5 2>>"$EV" || fail "wg set B"
    nsenter -t "$HOLDER" -n ip addr add 10.10.0.2/24 dev wg0 2>>"$EV" || fail "addr wg0 B"
    nsenter -t "$HOLDER" -n ip link set wg0 up 2>>"$EV" || fail "wg0 up B"

    # ---- REAL peer service: eureka_info JSON at 10.10.0.2:8008/setup/eureka_info ----
    DEV_NAME="HermeticCast-$$-${RANDOM}"
    mkdir -p "$SRVDIR/setup"
    if [ "${H2_MUT:-0}" = badeureka ]; then
        # golden-bad: 200 + JSON but NO `name` field => chromecast_dial.sh must FAIL.
        printf '{"ssdp_udn":"hermetic-%s","cast_build_revision":"1.0"}\n' "$$" > "$SRVDIR/setup/eureka_info"
        log "MUT: eureka_info served WITHOUT a name field — the real test must FAIL (fail-closed §11.4.68)"
    else
        printf '{"name":"%s","ssdp_udn":"hermetic-%s","cast_build_revision":"1.0","has_eureka":true}\n' "$DEV_NAME" "$$" > "$SRVDIR/setup/eureka_info"
    fi
    # self-bounded peer server (timeout inside the netns, direct parent of python)
    # so an outer-SIGKILL orphan self-terminates — no indefinite linger (review
    # MEDIUM host-safety; -k 2 90 outlives the holder's 90s sleep budget).
    ( cd "$SRVDIR" && exec nsenter -t "$HOLDER" -n timeout -k 2 90 python3 -m http.server 8008 --bind 10.10.0.2 ) >/dev/null 2>&1 &
    SRV=$!
    UP=0
    for _ in $(seq 1 40); do
        if python3 -c 'import socket,sys; s=socket.socket(); s.settimeout(0.4); sys.exit(0 if s.connect_ex(("10.10.0.2",8008))==0 else 1)' 2>/dev/null; then UP=1; break; fi
        sleep 0.25
    done
    [ "$UP" = 1 ] || fail "peer eureka service never reachable over the tunnel (10.10.0.2:8008)"
    HS=$("$WG" show wg0 latest-handshakes 2>/dev/null | awk '{print $2}' | head -1); HS=${HS:-0}
    log "tunnel up: wg handshake=$HS; peer eureka served (device name masked in test evidence)"

    # §11.4.107 not-stale + anti-bluff cross-check: fetch the eureka OURSELVES over
    # the tunnel from netns A and confirm it carries THIS run's fresh name nonce
    # (normal) / lacks a name (golden-bad). Proves the peer serves our data over the
    # encrypted overlay BEFORE the promoted test runs — de-couples the eventual PASS
    # from the downstream chromecast_dial grep string, and forbids a stale/wrong peer.
    SELF=$(python3 -c 'import urllib.request; print(urllib.request.urlopen("http://10.10.0.2:8008/setup/eureka_info", timeout=6).read().decode())' 2>>"$EV") || fail "self-fetch eureka over tunnel"
    if [ "${H2_MUT:-0}" = badeureka ]; then
        printf '%s' "$SELF" | grep -q '"name"' && fail "golden-bad self-fetch unexpectedly carries a name field"
    else
        printf '%s' "$SELF" | grep -q "\"name\": *\"$DEV_NAME\"" || fail "self-fetch eureka missing this run's fresh name nonce (stale/wrong peer over tunnel?)"
    fi

    # ---- bridge contract => hermetic peer; run the REAL protocol test in netns A ----
    export HELIX_BRIDGE_MODE=hermetic
    export HELIX_SVORD_DIR="$SRVDIR"
    export HELIX_BRIDGE_CONNECT='true'
    export HELIX_BRIDGE_DISCONNECT='true'
    # honest health probe: genuinely reachable over the tunnel (not a rubber-stamp)
    export HELIX_BRIDGE_HEALTH='python3 -c "import socket,sys; s=socket.socket(); s.settimeout(1); sys.exit(0 if s.connect_ex((\"10.10.0.2\",8008))==0 else 1)"'
    export HELIX_BRIDGE_SUBNET='10.10.0.0/24'
    export HELIX_BRIDGE_HOST='10.10.0.2'
    export HELIX_VPN_CAST_IP='10.10.0.2'
    export HELIX_VPN_CAST_EUREKA_PORT='8008'

    TEST="$_root/tests/vpn_lan/chromecast_dial.sh"
    [ -f "$TEST" ] || fail "promoted test missing: $TEST"
    # Coupling contract (review MEDIUM, de-brittle): this harness asserts on
    # chromecast_dial.sh emitting a line matching ^(PASS|FAIL):.*eureka_info. Verify
    # that token still exists in the promoted test so a future rename yields a clear
    # diagnostic HERE, not a silent grep miss downstream.
    grep -q 'eureka_info' "$TEST" || fail "promoted test no longer references 'eureka_info' — eureka coupling contract broke; update this harness"
    _t_out="${H2_EV_DIR}/chromecast_dial.stdout"
    _trc=0; bash "$TEST" >"$_t_out" 2>&1 || _trc=$?
    { printf '\n--- promoted chromecast_dial.sh (exit=%s) ---\n' "$_trc"; cat "$_t_out"; } >>"$EV"

    if [ "${H2_MUT:-0}" = badeureka ]; then
        # the real test MUST fail on the missing-name eureka (its T6.2 fail-closed path)
        if [ "$_trc" != 0 ] && grep -Eq '^FAIL:.*eureka_info' "$_t_out"; then
            log "H2_MUT_OK: the promoted test FAILED on the name-less eureka (assertion is genuinely exercised)"; exit 0
        fi
        fail "golden-bad did not FAIL the real eureka assertion (exit=$_trc) — promotion may be a rubber-stamp"
    fi

    # normal: the real test must produce a genuine eureka PASS + exit 0
    if [ "$_trc" = 0 ] && grep -Eq '^PASS:.*eureka_info' "$_t_out"; then
        # §11.4.111 negative control (self-evidencing): the eureka peer binds the
        # WG-only overlay 10.10.0.2 ONLY, so the SAME GET aimed from netns A at the
        # UNDERLAY peer IP 10.9.0.2:8008 (veth-reachable, nothing listening) MUST
        # fail. A success would mean the eureka PASS was NOT gated by the tunnel.
        _neg=0
        timeout 6 python3 -c 'import urllib.request; urllib.request.urlopen("http://10.9.0.2:8008/setup/eureka_info", timeout=3).read()' >/dev/null 2>&1 || _neg=$?
        [ "$_neg" != 0 ] || fail "NEG: underlay http://10.9.0.2:8008/setup/eureka_info unexpectedly answered — eureka traffic is NOT tunnel-gated"
        log "NEG-OK: underlay 10.9.0.2:8008 refused/failed (rc=$_neg) — the eureka peer is overlay-only; the eureka PASS required the tunnel (§11.4.111)"
        log "H2_PASS: the UNMODIFIED chromecast_dial.sh eureka control leg produced a REAL PASS over the hermetic WireGuard tunnel (bridge_require flipped SKIP->UP; §11.4.52 promotion)"
        exit 0
    fi
    fail "promoted test did not produce a real eureka PASS (exit=$_trc)"
fi

# ---------------------------------------------------------------------------
# OUTER: preflight (honest SKIP §11.4.3 / §12) then re-exec under unshare -Urnm.
# ---------------------------------------------------------------------------
SCRIPT_LABEL='hermetic_bridge_run'
_sd=$(cd "$(dirname "$0")" && pwd); _root=$(cd "$_sd/../.." && pwd)
H2_MUT="${H2_MUT:-0}"
_skip(){ printf 'SKIP: %s [%s]\n' "$SCRIPT_LABEL" "$1"; exit 0; }
for _t in unshare nsenter ip python3 curl timeout wg; do command -v "$_t" >/dev/null 2>&1 || _skip "tool absent: $_t"; done
[ -d /sys/module/wireguard ] || _skip "host 'wireguard' kernel module not loaded"
[ -f "$_root/tests/vpn_lan/chromecast_dial.sh" ] || _skip "promoted test absent"
if [ -r /proc/sys/kernel/unprivileged_userns_clone ] && [ "$(cat /proc/sys/kernel/unprivileged_userns_clone)" = 0 ]; then _skip "unprivileged userns disabled"; fi
unshare -Urnm true 2>/dev/null || _skip "unshare -Urnm failed (unprivileged user+net+mount ns unavailable)"
_softu=$(ulimit -u 2>/dev/null || echo 0); _inuse=$(ps --no-headers -u "$(id -u)" 2>/dev/null | wc -l | tr -d ' ')
if [ "${_softu}" != unlimited ] && [ "${_softu:-0}" -gt 0 ] 2>/dev/null && [ "$(( _softu - _inuse ))" -lt 64 ] 2>/dev/null; then _skip "process headroom too low (§12)"; fi

TS=$(date -u +%Y%m%dT%H%M%SZ 2>/dev/null || date +%Y%m%dT%H%M%SZ)
if [ "$H2_MUT" = badeureka ]; then _mode=mut; else _mode=pass; fi
export H2_EV_DIR="$_root/qa-results/vpn_lan/hermetic_bridge/${TS}_${_mode}_$$"
_rc=0
H2_MUT="$H2_MUT" timeout 70 env H2_EV_DIR="$H2_EV_DIR" H2_ROOT="$_root" H2_MUT="$H2_MUT" \
    unshare -Urnm bash "$0" --inner >/dev/null 2>&1 || _rc=$?
_ev="$H2_EV_DIR/run.evidence"

if [ "$H2_MUT" = badeureka ]; then
    if [ "$_rc" = 0 ] && grep -q 'H2_MUT_OK' "$_ev" 2>/dev/null; then
        printf 'PASS: %s [§1.1 golden-bad — the real chromecast_dial.sh eureka assertion FAILED on a name-less body; promotion is genuine, not a rubber-stamp; evidence: %s]\n' "$SCRIPT_LABEL" "$_ev"; exit 0
    fi
    printf 'FAIL: %s [golden-bad did not behave (rc=%s); evidence: %s]\n' "$SCRIPT_LABEL" "$_rc" "$_ev"; tail -5 "$_ev" 2>/dev/null; exit 1
fi
if [ "$_rc" = 0 ] && grep -q 'H2_PASS' "$_ev" 2>/dev/null; then
    printf 'PASS: %s [unmodified chromecast_dial.sh promoted to AUTONOMOUS over the hermetic WireGuard tunnel — real eureka PASS, no operator/podman/Mullvad (§11.4.52); evidence: %s]\n' "$SCRIPT_LABEL" "$_ev"; exit 0
fi
printf 'FAIL: %s [rc=%s; evidence: %s]\n' "$SCRIPT_LABEL" "$_rc" "$_ev"; tail -5 "$_ev" 2>/dev/null || true; exit 1
