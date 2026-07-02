#!/usr/bin/env bash
###############################################################################
# hermetic_wg_roundtrip.sh — H0-FULL: a REAL kernel-WireGuard tunnel between two
#   unprivileged network namespaces, round-trip proven OVER the encrypted tunnel.
#   (docs/design/vpn_lan_access/hermetic_wg_test_harness.md — H0 full)
#
# Purpose:
#   Upgrade the H0 veth PoC (hermetic_netns_poc.sh) to the real thing: two netns
#   joined by a **kernel WireGuard tunnel** (wg0 overlay 10.10.0.0/24) carried
#   over a veth underlay (10.9.0.0/24). A real HTTP payload is served in the peer
#   netns bound to the WG-ONLY overlay address 10.10.0.2 — reachable ONLY through
#   the tunnel — fetched from the other side and sha256-verified, with the
#   WireGuard handshake + non-zero transfer counters confirmed on both ends.
#   Fully UNPRIVILEGED (unshare -Ur => root-in-userns; the host `wireguard` kernel
#   module + /usr/sbin/wg), NO build, NO podman, NO Mullvad, NO package install.
#
#   This is the substrate the operator-gated protocol tests run on autonomously
#   (§11.4.52): swap the real svord bridge for this loopback WG peer via
#   HELIX_BRIDGE_MODE=hermetic (H2). It exercises the SAME L3-over-WireGuard shape
#   as the production bridge — the identical routing/proxy code path.
#
# Usage:
#   tests/vpn_lan/hermetic_wg_roundtrip.sh              # PASS / SKIP / FAIL
#   WG_MUT=badkey tests/vpn_lan/hermetic_wg_roundtrip.sh  # §1.1 golden-bad: a WRONG
#     peer public key MUST break the handshake => no round-trip => the run FAILs,
#     proving the WireGuard CRYPTO gates the traffic (not the veth underlay).
#   (internal) hermetic_wg_roundtrip.sh --inner
#
# Outputs:
#   One PASS/SKIP/FAIL line. Exit 0 == PASS or honest SKIP; 1 == FAIL. Under
#   WG_MUT=badkey the outer wrapper PASSes iff the tunnel round-trip FAILED for
#   the handshake reason (teeth load-bearing §11.4.107(10)). Evidence:
#   qa-results/vpn_lan/hermetic_wg/<UTC-ts>_<pass|mut>_<pid>/roundtrip.evidence
#
# Preflight / honest SKIP (§11.4.3 — never a fake PASS):
#   SKIP when the host lacks the `wireguard` kernel module, `wg`, unshare/nsenter/
#   ip/python3/sha256sum, when unprivileged userns is disabled, or when process
#   headroom is too low (§12 host-safety).
#
# Side-effects:
#   ONE throwaway user+net+mount namespace via `unshare -Urnm`; two wg0 ifaces +
#   a veth pair + a python http.server all live inside it and are torn down when
#   unshare exits (§11.4.14). NOTHING on the host network is touched or visible
#   (§11.4.174-safe). Private WG keys live in mode-0600 mktemp files inside the
#   namespace, removed on exit; NEVER logged (§11.4.10).
#
# Dependencies: bash, util-linux unshare + nsenter, iproute2 ip (+ wireguard link
#   type), wireguard-tools `wg`, host `wireguard` kernel module, python3, sha256sum.
#
# Cross-references:
#   tests/vpn_lan/hermetic_netns_poc.sh (the veth substrate this builds on)
#   docs/design/vpn_lan_access/hermetic_wg_test_harness.md
#   constitution §11.4.3 / §11.4.6 / §11.4.10 / §11.4.50 / §11.4.52 / §11.4.107 / §11.4.174 / §12
###############################################################################
set -u
export PATH="$PATH:/usr/sbin:/sbin"

# ---------------------------------------------------------------------------
# INNER: runs inside `unshare -Urnm` (uid 0-in-userns). Builds the veth underlay,
# the two-ended WireGuard tunnel, serves + fetches over the tunnel, verifies.
# ---------------------------------------------------------------------------
if [ "${1:-}" = "--inner" ]; then
    EV="${WG_EV_DIR:?}/roundtrip.evidence"; mkdir -p "${WG_EV_DIR}"; : >"$EV"
    log(){ printf '%s\n' "$*" | tee -a "$EV"; }
    fail(){ log "WG_FAIL: $*"; exit 1; }
    WG=$(command -v wg 2>/dev/null || echo /usr/sbin/wg)

    log "== uid inside userns: $(id -u) (0 == root-in-userns); wg: $WG =="
    ip link set lo up 2>>"$EV" || fail "lo up (outer)"
    ip link add veth0 type veth peer name veth1 2>>"$EV" || fail "veth add"

    # Peer netns = a held child; marker touched from inside its swapped netns.
    MARK=$(mktemp -u)
    unshare -n bash -c "touch '$MARK'; exec sleep 60" &
    HOLDER=$!
    KDIR=$(mktemp -d)
    cleanup(){ kill "$HOLDER" 2>/dev/null; [ -n "${SRV:-}" ] && kill "$SRV" 2>/dev/null; [ -n "${SNIFF_PID:-}" ] && kill "$SNIFF_PID" 2>/dev/null; rm -rf "$KDIR" "$MARK" "${SNIFFDIR:-}" 2>/dev/null; true; }
    trap cleanup EXIT INT TERM
    for _ in $(seq 1 50); do [ -e "$MARK" ] && break; sleep 0.1; done
    [ -e "$MARK" ] || fail "holder netns not ready"
    rm -f "$MARK" 2>/dev/null || true
    [ -e "/proc/$HOLDER/ns/net" ] || fail "holder pid gone"

    # --- veth underlay (carries the encrypted WG UDP) ---
    ip link set veth1 netns "$HOLDER" 2>>"$EV" || fail "move veth1"
    ip addr add 10.9.0.1/24 dev veth0 2>>"$EV" || fail "underlay addr A"
    ip link set veth0 up 2>>"$EV" || fail "veth0 up"
    nsenter -t "$HOLDER" -n ip link set lo up 2>>"$EV" || fail "peer lo up"
    nsenter -t "$HOLDER" -n ip addr add 10.9.0.2/24 dev veth1 2>>"$EV" || fail "underlay addr B"
    nsenter -t "$HOLDER" -n ip link set veth1 up 2>>"$EV" || fail "veth1 up"

    # --- WireGuard keypairs (mode-0600 files, never logged §11.4.10) ---
    umask 077
    "$WG" genkey > "$KDIR/a.key" 2>>"$EV" || fail "wg genkey A (wg unusable in userns?)"
    "$WG" pubkey < "$KDIR/a.key" > "$KDIR/a.pub" 2>>"$EV" || fail "wg pubkey A"
    "$WG" genkey > "$KDIR/b.key" 2>>"$EV" || fail "wg genkey B"
    "$WG" pubkey < "$KDIR/b.key" > "$KDIR/b.pub" 2>>"$EV" || fail "wg pubkey B"
    PUB_A=$(cat "$KDIR/a.pub"); PUB_B=$(cat "$KDIR/b.pub")
    # §11.4.107(10) golden-bad: give A a WRONG peer key so the handshake can never
    # complete — if the round-trip still worked, traffic would be leaking over the
    # veth underlay in the clear (a bluff). A wrong key MUST break it.
    PEER_FOR_A="$PUB_B"
    if [ "${WG_MUT:-0}" = badkey ]; then
        "$WG" genkey > "$KDIR/x.key" 2>>"$EV"; PEER_FOR_A=$("$WG" pubkey < "$KDIR/x.key")
        log "MUT: A's peer key set to a WRONG pubkey — handshake must fail, round-trip must break"
    fi

    # --- wg0 in netns A (current) ---
    ip link add wg0 type wireguard 2>>"$EV" || fail "wg0 add A (kernel wireguard module?)"
    "$WG" set wg0 private-key "$KDIR/a.key" listen-port 51820 \
        peer "$PEER_FOR_A" endpoint 10.9.0.2:51820 allowed-ips 10.10.0.2/32 persistent-keepalive 5 2>>"$EV" || fail "wg set A"
    ip addr add 10.10.0.1/24 dev wg0 2>>"$EV" || fail "wg0 addr A"
    ip link set wg0 up 2>>"$EV" || fail "wg0 up A"

    # --- wg0 in netns B (peer) ---
    nsenter -t "$HOLDER" -n ip link add wg0 type wireguard 2>>"$EV" || fail "wg0 add B"
    nsenter -t "$HOLDER" -n "$WG" set wg0 private-key "$KDIR/b.key" listen-port 51820 \
        peer "$PUB_A" endpoint 10.9.0.1:51820 allowed-ips 10.10.0.1/32 persistent-keepalive 5 2>>"$EV" || fail "wg set B"
    nsenter -t "$HOLDER" -n ip addr add 10.10.0.2/24 dev wg0 2>>"$EV" || fail "wg0 addr B"
    nsenter -t "$HOLDER" -n ip link set wg0 up 2>>"$EV" || fail "wg0 up B"

    # --- real HTTP payload served on the WG-ONLY overlay addr 10.10.0.2 ---
    SRVDIR=$(mktemp -d)
    NONCE="hermetic-wg-proof-$$-${RANDOM}"
    printf '%s\n' "$NONCE" > "$SRVDIR/payload.txt"
    SHA_SRC=$(sha256sum "$SRVDIR/payload.txt" | cut -d' ' -f1)
    # self-bounded server (timeout inside the netns) so an outer-SIGKILL orphan
    # self-terminates — no indefinite linger (review MEDIUM host-safety).
    ( cd "$SRVDIR" && exec nsenter -t "$HOLDER" -n timeout -k 2 60 python3 -m http.server 8080 --bind 10.10.0.2 ) >/dev/null 2>&1 &
    SRV=$!

    # poll the tunnel address from netns A (triggers the handshake)
    UP=0
    for _ in $(seq 1 40); do
        if python3 -c 'import socket,sys; s=socket.socket(); s.settimeout(0.4); sys.exit(0 if s.connect_ex(("10.10.0.2",8080))==0 else 1)' 2>/dev/null; then UP=1; break; fi
        sleep 0.25
    done

    HS=$("$WG" show wg0 latest-handshakes 2>/dev/null | awk '{print $2}' | head -1); HS=${HS:-0}
    RX=$("$WG" show wg0 transfer 2>/dev/null | awk '{print $2}' | head -1); RX=${RX:-0}
    TX=$("$WG" show wg0 transfer 2>/dev/null | awk '{print $3}' | head -1); TX=${TX:-0}
    log "wg show wg0: latest-handshake=$HS  rx=$RX  tx=$TX  (peer count=$("$WG" show wg0 peers 2>/dev/null | wc -l))"

    if [ "$UP" != 1 ]; then
        log "tunnel round-trip did NOT establish (handshake=$HS) — expected under WG_MUT=badkey"
        fail "no connect over 10.10.0.2:8080 (WG handshake incomplete)"
    fi

    # === §11.4.107 underlay-sniff differential — start a BOUNDED capture on the
    # CLIENT underlay veth (veth0, 10.9.0.x — carries the ENCRYPTED WG UDP), NOT
    # wg0. AF_PACKET SOCK_RAW needs CAP_NET_RAW, held by this `unshare -Urnm`
    # root-in-userns for its OWN netns's veth only (§11.4.174 — never a host iface).
    # After the positive fetch we assert on the captured underlay bytes: (a) a
    # WireGuard type-4 data message (0x04 00 00 00) to the WG listen port is present
    # (the tunnel really carried traffic on the wire) AND (b) the per-run plaintext
    # NONCE is ABSENT (the payload was encrypted, not leaked). Bounded window +
    # byte cap (§12.6); reaped in the trap. Honest SKIP if AF_PACKET+tcpdump both
    # unavailable (§11.4.3) — never a fake pass; the rest of the harness still runs.
    SNIFF_IFACE=veth0
    SNIFFDIR=$(mktemp -d)
    SNIFF_CAP="$SNIFFDIR/underlay.pcap"; SNIFF_READY="$SNIFFDIR/ready"
    SNIFF_WINDOW=3.5; SNIFF_CAPB=4194304
    SNIFF_ACTIVE=0; SNIFF_MODE=none; SNIFF_PID=""
    LPORT=$("$WG" show wg0 listen-port 2>/dev/null); LPORT=${LPORT:-51820}
    cat > "$SNIFFDIR/cap.py" <<'PY'
import socket, sys, time, struct
ifn, outp, readyp, window, capb = sys.argv[1], sys.argv[2], sys.argv[3], float(sys.argv[4]), int(sys.argv[5])
try:
    s = socket.socket(socket.AF_PACKET, socket.SOCK_RAW, socket.htons(0x0003))  # ETH_P_ALL
    s.bind((ifn, 0))
except Exception as e:
    try:
        open(readyp + ".err", "w").write(repr(e))
    except Exception:
        pass
    sys.exit(1)
f = open(outp, "wb")
f.write(struct.pack("<IHHiIII", 0xa1b2c3d4, 2, 4, 0, 0, 65535, 1))  # pcap global hdr, LINKTYPE_ETHERNET
f.flush()
open(readyp, "w").close()  # signal ready only AFTER the header is on disk
s.settimeout(0.5)
deadline = time.time() + window
total = 0
while time.time() < deadline and total < capb:
    try:
        data = s.recv(65535)
    except socket.timeout:
        continue
    except OSError:
        break
    n = len(data); t = time.time()
    f.write(struct.pack("<IIII", int(t), int((t - int(t)) * 1000000), n, n))
    f.write(data)
    total += n + 16
f.flush(); f.close()
try:
    s.close()
except Exception:
    pass
PY
    cat > "$SNIFFDIR/an.py" <<'PY'
import sys, struct
capp, nonce, lport = sys.argv[1], sys.argv[2].encode(), int(sys.argv[3])
try:
    raw = open(capp, "rb").read()
except Exception as e:
    sys.stderr.write("SNIFF-ERR read %r\n" % e); sys.exit(4)
if len(raw) < 24:
    sys.stderr.write("SNIFF-ERR short %d\n" % len(raw)); sys.exit(4)
m = raw[:4]
if m == b"\xd4\xc3\xb2\xa1":
    e = "<"
elif m == b"\xa1\xb2\xc3\xd4":
    e = ">"
else:
    sys.stderr.write("SNIFF-ERR magic %r\n" % m); sys.exit(4)
network = struct.unpack(e + "I", raw[20:24])[0]
off = 24; ct = False; pt = False; pkts = 0; blob = bytearray()
while off + 16 <= len(raw):
    _, _, incl, _ = struct.unpack(e + "IIII", raw[off:off+16]); off += 16
    if off + incl > len(raw):
        break
    fr = raw[off:off+incl]; off += incl; pkts += 1; blob += fr
    p = 14 if network == 1 else 0        # skip Ethernet header for LINKTYPE_ETHERNET
    if len(fr) < p + 20:
        continue
    vihl = fr[p]
    if (vihl >> 4) != 4:                 # IPv4 only
        continue
    ihl = (vihl & 0x0f) * 4
    if ihl < 20 or fr[p + 9] != 17:      # UDP only
        continue
    u = p + ihl
    if len(fr) < u + 8:
        continue
    sport = struct.unpack(">H", fr[u:u+2])[0]
    dport = struct.unpack(">H", fr[u+2:u+4])[0]
    pl = fr[u+8:]
    if (dport == lport or sport == lport) and pl[:4] == b"\x04\x00\x00\x00":
        ct = True                        # WireGuard type-4 transport-data message
if nonce in bytes(blob):
    pt = True
sys.stderr.write("SNIFF: packets=%d ciphertext(0x04 :%d)=%s plaintext_nonce=%s\n" % (
    pkts, lport, "present" if ct else "absent", "present" if pt else "absent"))
if pt:
    sys.exit(2)   # plaintext leaked -> the "plaintext absent" assertion FAILS
if not ct:
    sys.exit(3)   # no WG data on the underlay
sys.exit(0)
PY
    timeout -k 1 8 python3 "$SNIFFDIR/cap.py" "$SNIFF_IFACE" "$SNIFF_CAP" "$SNIFF_READY" "$SNIFF_WINDOW" "$SNIFF_CAPB" >/dev/null 2>>"$EV" &
    SNIFF_PID=$!
    for _ in $(seq 1 30); do
        [ -e "$SNIFF_READY" ] && { SNIFF_ACTIVE=1; SNIFF_MODE=afpacket; break; }
        [ -e "$SNIFF_READY.err" ] && break
        sleep 0.1
    done
    if [ "$SNIFF_ACTIVE" != 1 ]; then
        # AF_PACKET unavailable — reap it, then honest fallback / SKIP (§11.4.3).
        wait "$SNIFF_PID" 2>/dev/null; SNIFF_PID=""
        _aperr=$(head -c 200 "$SNIFF_READY.err" 2>/dev/null); _aperr=${_aperr:-unknown}
        if command -v tcpdump >/dev/null 2>&1; then
            timeout -k 1 8 tcpdump -i "$SNIFF_IFACE" -nn -s 0 -w "$SNIFF_CAP" udp >/dev/null 2>>"$EV" &
            SNIFF_PID=$!; sleep 1.2
            if kill -0 "$SNIFF_PID" 2>/dev/null || [ -s "$SNIFF_CAP" ]; then SNIFF_ACTIVE=1; SNIFF_MODE=tcpdump; fi
        fi
        if [ "$SNIFF_ACTIVE" != 1 ]; then
            [ -n "$SNIFF_PID" ] && kill "$SNIFF_PID" 2>/dev/null; SNIFF_PID=""
            _td=$(command -v tcpdump >/dev/null 2>&1 && echo present-but-failed || echo absent)
            log "SNIFF-SKIP: underlay capture unavailable (AF_PACKET: $_aperr; tcpdump: $_td) — sniff leg skipped (§11.4.3), rest of harness unaffected"
        fi
    fi
    # §11.4.107(10) golden-bad: SNIFF_MUT=plain transmits the SAME run NONCE in
    # CLEARTEXT on the underlay veth so the "plaintext absent" assertion MUST fail
    # (proving the assertion is load-bearing, not a tautology). NEVER runs in normal
    # mode; sent only when the capture is actually active. Port 9 (discard), a
    # distinct port from the §11.4.111 negative control's TCP :8080, so NEG-OK stays valid.
    if [ "$SNIFF_ACTIVE" = 1 ] && [ "${SNIFF_MUT:-0}" = plain ]; then
        python3 -c 'import socket,sys; s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM); [s.sendto(sys.argv[1].encode(),("10.9.0.2",9)) for _ in range(6)]' "$NONCE" 2>>"$EV" || true
        log "SNIFF_MUT=plain: emitted the run nonce in CLEARTEXT on $SNIFF_IFACE (underlay) — plaintext-absent assertion MUST now FAIL"
    fi

    BODY=$(python3 -c 'import urllib.request; print(urllib.request.urlopen("http://10.10.0.2:8080/payload.txt", timeout=8).read().decode().rstrip("\n"))' 2>>"$EV") || fail "fetch over tunnel"
    SHA_GOT=$(printf '%s\n' "$BODY" | sha256sum | cut -d' ' -f1)
    log "peer-served nonce (over WG): $NONCE"
    log "fetched body               : $BODY"
    log "sha256 source / fetched     : $SHA_SRC / $SHA_GOT"
    { [ "$SHA_SRC" = "$SHA_GOT" ] && [ "$BODY" = "$NONCE" ]; } || fail "sha256/body mismatch"
    { [ "$HS" != 0 ] && [ "$RX" -gt 0 ] 2>/dev/null && [ "$TX" -gt 0 ] 2>/dev/null; } || fail "WG handshake/transfer not confirmed (hs=$HS rx=$RX tx=$TX)"

    # --- §11.4.107 underlay-sniff differential: stop the capture (started before the
    # fetch) and run the two assertions on the captured underlay bytes ---
    if [ "$SNIFF_ACTIVE" = 1 ]; then
        [ "$SNIFF_MODE" = tcpdump ] && { sleep 0.4; kill -INT "$SNIFF_PID" 2>/dev/null || true; }
        wait "$SNIFF_PID" 2>/dev/null; SNIFF_PID=""
        _src=0
        python3 "$SNIFFDIR/an.py" "$SNIFF_CAP" "$NONCE" "$LPORT" 2>>"$EV" || _src=$?
        case "$_src" in
            0) log "SNIFF-OK: underlay $SNIFF_IFACE ($SNIFF_MODE): WG data (0x04) to :$LPORT present, plaintext nonce absent (§11.4.107 non-leak). Boundary: proves non-leak on the LOCAL simulated underlay veth, NOT the live Mullvad WAN (§11.4.3/§11.4.6)." ;;
            2) fail "SNIFF: plaintext nonce '$NONCE' appeared on the underlay $SNIFF_IFACE — payload leaked in cleartext (§11.4.107)" ;;
            3) fail "SNIFF: no WireGuard type-4 data (0x04) datagram to :$LPORT captured on the underlay $SNIFF_IFACE — tunnel did not carry traffic on the wire" ;;
            *) fail "SNIFF: underlay-capture analyzer error (rc=$_src)" ;;
        esac
    fi

    # §11.4.111 negative control (self-evidencing tunnel-gating): the payload server
    # binds the WG-only overlay 10.10.0.2 ONLY, so the SAME fetch aimed from netns A
    # at the UNDERLAY peer IP 10.9.0.2:8080 (reachable over the veth, nothing
    # listening there) MUST fail. A success would mean the payload was NOT gated by
    # the tunnel (a real defect) — fail-closed. This proves the positive fetch to
    # 10.10.0.2 could only have traversed wg0.
    _neg=0
    timeout 6 python3 -c 'import urllib.request; urllib.request.urlopen("http://10.9.0.2:8080/payload.txt", timeout=3).read()' >/dev/null 2>&1 || _neg=$?
    [ "$_neg" != 0 ] || fail "NEG: underlay http://10.9.0.2:8080/payload.txt unexpectedly served the payload — traffic is NOT tunnel-gated"
    log "NEG-OK: underlay 10.9.0.2:8080 fetch refused/failed (rc=$_neg) — the payload server is overlay-only; reaching it over 10.10.0.2 required the tunnel (§11.4.111)"
    # NOTE: SRVDIR cleanup is deferred to HERE (past the §11.4.111 negative control) on
    # purpose — if payload.txt is removed before the control, a reachable underlay would
    # 404 and the probe would fail regardless of tunnel-gating, making NEG-OK a tautology
    # (§11.4.107(10)). Keeping the file present at probe time makes the control load-bearing:
    # underlay-reachable ⇒ HTTP 200 ⇒ _neg=0 ⇒ fail; overlay-only ⇒ refused ⇒ _neg≠0 ⇒ NEG-OK.
    rm -rf "$SRVDIR" 2>/dev/null || true

    log "WG_PASS: real HTTP payload round-tripped over an encrypted kernel-WireGuard tunnel between 2 unprivileged netns, sha256 + handshake + transfer verified; underlay-sniff differential (§11.4.107) confirmed WG-ciphertext-present + plaintext-nonce-absent on the underlay (or honest SKIP)"
    exit 0
fi

# ---------------------------------------------------------------------------
# OUTER: preflight (honest SKIP §11.4.3 / §12) then re-exec under unshare -Urnm.
# ---------------------------------------------------------------------------
SCRIPT_LABEL='hermetic_wg_roundtrip'
_sd=$(cd "$(dirname "$0")" && pwd); _root=$(cd "$_sd/../.." && pwd)
WG_MUT="${WG_MUT:-0}"
SNIFF_MUT="${SNIFF_MUT:-0}"
_skip(){ printf 'SKIP: %s [%s]\n' "$SCRIPT_LABEL" "$1"; exit 0; }

for _t in unshare nsenter ip python3 sha256sum timeout wg; do command -v "$_t" >/dev/null 2>&1 || _skip "tool absent: $_t"; done
[ -d /sys/module/wireguard ] || _skip "host 'wireguard' kernel module not loaded"
if [ -r /proc/sys/kernel/unprivileged_userns_clone ] && [ "$(cat /proc/sys/kernel/unprivileged_userns_clone)" = 0 ]; then
    _skip "unprivileged user namespaces disabled"
fi
unshare -Urnm true 2>/dev/null || _skip "unshare -Urnm failed (unprivileged user+net+mount ns unavailable)"
_softu=$(ulimit -u 2>/dev/null || echo 0); _inuse=$(ps --no-headers -u "$(id -u)" 2>/dev/null | wc -l | tr -d ' ')
if [ "${_softu}" != unlimited ] && [ "${_softu:-0}" -gt 0 ] 2>/dev/null && [ "$(( _softu - _inuse ))" -lt 64 ] 2>/dev/null; then
    _skip "process headroom too low (ulimit -u=${_softu}, in use=${_inuse}) — §12 host-safety"
fi

TS=$(date -u +%Y%m%dT%H%M%SZ 2>/dev/null || date +%Y%m%dT%H%M%SZ)
if [ "$WG_MUT" = badkey ] || [ "$SNIFF_MUT" = plain ]; then _mode=mut; else _mode=pass; fi
export WG_EV_DIR="$_root/qa-results/vpn_lan/hermetic_wg/${TS}_${_mode}_$$"
_rc=0
# outer bound sits a few seconds below the 60s holder-sleep / server self-timeout
# so the outer reaper fires FIRST in the pathological case, leaving the inner
# `timeout -k 2 60` self-bound as the belt-and-suspenders orphan guard (review nit).
WG_MUT="$WG_MUT" timeout 55 env WG_EV_DIR="$WG_EV_DIR" WG_MUT="$WG_MUT" SNIFF_MUT="$SNIFF_MUT" \
    unshare -Urnm bash "$0" --inner >/dev/null 2>&1 || _rc=$?
_ev="$WG_EV_DIR/roundtrip.evidence"

if [ "$WG_MUT" = badkey ]; then
    # golden-bad: the ONLY acceptable outcome is the tunnel round-trip FAILING
    # because the WG handshake could not complete (wrong peer key).
    if [ "$_rc" != 0 ] && grep -q 'WG handshake incomplete' "$_ev" 2>/dev/null; then
        printf 'PASS: %s [§1.1 golden-bad — wrong peer key broke the handshake => no round-trip; WG crypto is load-bearing; evidence: %s]\n' "$SCRIPT_LABEL" "$_ev"; exit 0
    fi
    printf 'FAIL: %s [§1.1 mutation did NOT fail at the handshake (rc=%s) — round-trip may be leaking over the underlay]\n' "$SCRIPT_LABEL" "$_rc"
    tail -4 "$_ev" 2>/dev/null || true; exit 1
fi

if [ "$_rc" = 0 ] && grep -q WG_PASS "$_ev" 2>/dev/null; then
    printf 'PASS: %s [encrypted kernel-WireGuard tunnel round-trip between 2 unprivileged netns, sha256+handshake+transfer verified; evidence: %s]\n' "$SCRIPT_LABEL" "$_ev"; exit 0
fi
printf 'FAIL: %s [rc=%s; evidence: %s]\n' "$SCRIPT_LABEL" "$_rc" "$_ev"
tail -4 "$_ev" 2>/dev/null || true
exit 1
