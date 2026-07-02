#!/usr/bin/env bash
###############################################################################
# hermetic_ftp_run.sh — H2.ftp: run the operator-gated FTP protocol test
#   AUTONOMOUSLY over the hermetic kernel-WireGuard tunnel.
#   (docs/design/vpn_lan_access/hermetic_wg_test_harness.md — H2.x)
#
# Purpose:
#   Promote the FTP leg of tests/vpn_lan/ftp_sftp_webdav.sh (§11.4.52): stand up
#   the H0-full WireGuard tunnel between two unprivileged netns, run a REAL,
#   pure-python-stdlib FTP server in netns B bound to the WG-only overlay
#   10.10.0.2:2121, point the bridge contract (tests/lib/svord_bridge.sh) at it,
#   then run the UNMODIFIED ftp_sftp_webdav.sh INSIDE netns A. Its own
#   `bridge_require` gate flips SKIP->UP and the FTP leg produces a REAL PASS on a
#   real passive directory LISTING over the encrypted tunnel, with captured
#   evidence — no operator, no podman, no live VPN server. The harness ADDITIONALLY
#   proves the byte-transfer half itself (§11.4.107(9)): it RETRs a fresh nonce file
#   by exact name over the tunnel and asserts the bytes equal the known payload
#   (the promoted test's own fetch is best-effort + ungated, so the "+fetch" claim
#   is earned by this harness self-check, not by the test). The real svord/Mullvad
#   run stays the §11.4.3 real-topology confirmation.
#
#   The FTP server is pure python3 stdlib (no pyftpdlib / vsftpd) so it needs zero
#   host installs (§11.4.122). It answers the exact command set curl --ftp-pasv
#   drives: USER/PASS(anonymous)/SYST/TYPE/PWD/CWD/SIZE/EPSV/PASV/LIST/RETR/QUIT.
#   EPSV/PASV advertise the overlay addr 10.10.0.2 so curl's data channel
#   traverses the tunnel (§11.4.111 resolve-by-reachable-addr, not 127.0.0.1).
#
# Usage:
#   tests/vpn_lan/hermetic_ftp_run.sh              # PASS / SKIP / FAIL
#   FT_MUT=empty tests/vpn_lan/hermetic_ftp_run.sh # §1.1 golden-bad: server serves
#     an EMPTY listing => the real test cannot list => it SKIPs (never PASS). The
#     harness PASSes ONLY when it confirms that suppression — proving a real PASS
#     requires a real non-empty listing (plus, on the normal path, the harness's
#     own content-verified RETR), not a rubber-stamp.
#   (internal) hermetic_ftp_run.sh --inner
#
# Outputs:
#   One PASS/SKIP/FAIL line. Evidence:
#   qa-results/vpn_lan/hermetic_ftp/<UTC-ts>_<pass|mut>_<pid>/run.evidence
#   (the promoted test also writes its own qa-results/vpn_lan/phase3/... evidence).
#
# Preflight / honest SKIP (§11.4.3): kernel `wireguard` module, unshare/nsenter/ip/
#   wg/python3/curl/timeout, unprivileged userns, process headroom (§12) — else
#   SKIP, never a fake PASS.
#
# Side-effects:
#   ONE throwaway user+net+mount namespace (unshare -Urnm); the tunnel + FTP server
#   + the promoted test all live inside it and die with unshare (§11.4.14). Nothing
#   on the host network touched/visible (§11.4.174). WG keys mode-0600 in-namespace,
#   never logged (§11.4.10). FTP is anonymous — no credentials anywhere.
#
# Dependencies: bash, unshare+nsenter, iproute2 ip (wireguard link type), wg, host
#   `wireguard` kernel module, python3 (stdlib only), curl, timeout.
#
# Cross-references:
#   tests/vpn_lan/hermetic_bridge_run.sh (the H2 template + H0-full tunnel)
#   tests/vpn_lan/ftp_sftp_webdav.sh     (the promoted protocol test — FTP leg)
#   tests/lib/svord_bridge.sh            (bridge contract; HELIX_BRIDGE_MODE=hermetic)
#   docs/design/vpn_lan_access/hermetic_wg_test_harness.md (H2.x)
#   constitution §11.4.3 / §11.4.6 / §11.4.10 / §11.4.52 / §11.4.107 / §11.4.111 / §11.4.174 / §12
###############################################################################
set -u
export PATH="$PATH:/usr/sbin:/sbin"

# ---------------------------------------------------------------------------
# _emit_an_py — SINGLE SOURCE of the §11.4.107 underlay-sniff frame analyzer (cloned
# VERBATIM from the WG substrate hermetic_wg_roundtrip.sh — task #65 fan-out; NOT a
# divergent re-implementation, §11.4.107(10)). Emitted both by the inner sniff
# differential (fed a real veth0 capture) and by the guarded `--selftest-analyzer`
# mode below (fed crafted frames). One definition => the unit self-test exercises the
# SAME parser the harness uses (no drift, no bluff §11.4.107(10)).
# ---------------------------------------------------------------------------
_emit_an_py(){
cat <<'PY'
import sys, struct

def scan_frames(raw, e, network, nonce, lport):
    off = 24; ct = False; pt = False; pkts = 0; blob = bytearray()
    while off + 16 <= len(raw):
        _, _, incl, _ = struct.unpack(e + "IIII", raw[off:off+16]); off += 16
        if off + incl > len(raw):
            break
        fr = raw[off:off+incl]; off += incl; pkts += 1; blob += fr
        p = 14 if network == 1 else 0        # skip Ethernet header for LINKTYPE_ETHERNET
        if network == 1 and fr[12:14] != b"\x08\x00":  # Ethernet II ethertype MUST be IPv4 (0x0800); VLAN(0x8100)/ARP/IPv6 shift the L3 offset -> skip (never misparse)
            continue
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
    return pkts, ct, pt

if len(sys.argv) > 1 and sys.argv[1] == "--selftest":
    # §11.4.107(10) self-validated analyzer — crafted-frame unit tests proving the Ethernet
    # ethertype guard. Feeds the SAME scan_frames() the sniff differential uses (never a copy).
    lport = 51820
    def rec(fr):
        return struct.pack("<IIII", 0, 0, len(fr), len(fr)) + fr
    def pcap(*frames):
        b = struct.pack("<IHHiIII", 0xa1b2c3d4, 2, 4, 0, 0, 65535, 1)  # LINKTYPE_ETHERNET, as cap.py
        for fr in frames:
            b += rec(fr)
        return b
    def eth(ethertype):                       # 14-byte Ethernet II header: dst(6)+src(6)+ethertype(2)
        return b"\x00\x11\x22\x33\x44\x55" + b"\x66\x77\x88\x99\xaa\xbb" + struct.pack(">H", ethertype)
    # ONE identical L3 body: IPv4(proto=17 UDP) + UDP(dport=51820) + WG type-4 marker.
    ip = bytes([0x45, 0, 0, 0, 0, 0, 0, 0, 64, 17, 0, 0]) + b"\x0a\x09\x00\x01" + b"\x0a\x09\x00\x02"
    udp = struct.pack(">HHHH", 12345, lport, 0, 0)
    l3 = ip + udp + b"\x04\x00\x00\x00"       # a fully WG-detectable structure at the L3 offset
    tn = b"SELFTEST-NONCE-3f9a"
    # (a) VLAN-tagged frame (ethertype 0x8100) with the SAME l3 right after the 14B Ethernet
    #     header: WITHOUT the guard, parsing at offset 14 WOULD flag ct; WITH the guard it MUST
    #     be skipped (ct absent). Since (a) and (b) share the identical l3, the ONLY variable is
    #     the ethertype -> the guard is provably load-bearing, not a tautology.
    _, ct_vlan, _ = scan_frames(pcap(eth(0x8100) + l3), "<", 1, tn, lport)
    # (b) plain IPv4 frame (ethertype 0x0800), same l3 + the run nonce trailing: the happy path
    #     MUST still detect ct AND still scan the nonce (pt) — the guard must not break it.
    _, ct_ip, pt_ip = scan_frames(pcap(eth(0x0800) + l3 + tn), "<", 1, tn, lport)
    ok = (not ct_vlan) and ct_ip and pt_ip
    sys.stderr.write("AN-SELFTEST: vlan_ct=%s ipv4_ct=%s ipv4_nonce=%s\n" % (
        "present" if ct_vlan else "absent",
        "present" if ct_ip else "absent",
        "present" if pt_ip else "absent"))
    if ok:
        print("AN-SELFTEST-OK: VLAN(0x8100) frame skipped by ethertype guard (ct=absent); "
              "IPv4(0x0800) WG frame still detected (ct=present) + nonce scanned (pt=present)")
        sys.exit(0)
    print("AN-SELFTEST-FAIL: ethertype-guard assertions not met "
          "(vlan_ct MUST be absent; ipv4_ct + ipv4_nonce MUST be present)")
    sys.exit(1)

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
pkts, ct, pt = scan_frames(raw, e, network, nonce, lport)
sys.stderr.write("SNIFF: packets=%d ciphertext(0x04 :%d)=%s plaintext_nonce=%s\n" % (
    pkts, lport, "present" if ct else "absent", "present" if pt else "absent"))
if pt:
    sys.exit(2)   # plaintext leaked -> the "plaintext absent" assertion FAILS
if not ct:
    sys.exit(3)   # no WG data on the underlay
sys.exit(0)
PY
}

# ---------------------------------------------------------------------------
# --selftest-analyzer: §11.4.107(10) self-validated-analyzer gate. Materialize the SAME
# an.py the sniff differential uses and run its crafted-frame unit tests (VLAN-skip +
# IPv4 happy-path). Pure string parsing — needs no wireguard/unshare/root, safe anywhere.
# Guarded: NEVER part of the normal PASS/SKIP/FAIL flow.
# ---------------------------------------------------------------------------
if [ "${1:-}" = "--selftest-analyzer" ]; then
    _std=$(mktemp -d)
    _emit_an_py > "$_std/an.py"
    if python3 "$_std/an.py" --selftest; then _r=0; else _r=$?; fi
    rm -rf "$_std" 2>/dev/null || true
    exit "$_r"
fi

if [ "${1:-}" = "--inner" ]; then
    EV="${FT_EV_DIR:?}/run.evidence"; mkdir -p "${FT_EV_DIR}"; : >"$EV"
    _root="${FT_ROOT:?}"
    log(){ printf '%s\n' "$*" | tee -a "$EV"; }
    fail(){ log "FT_FAIL: $*"; exit 1; }
    WG=$(command -v wg 2>/dev/null || echo /usr/sbin/wg)

    # ---- WG tunnel (as hermetic_bridge_run.sh) ----
    ip link set lo up 2>>"$EV" || fail "lo up"
    ip link add veth0 type veth peer name veth1 2>>"$EV" || fail "veth add"
    MARK=$(mktemp -u); unshare -n bash -c "touch '$MARK'; exec sleep 90" & HOLDER=$!
    KDIR=$(mktemp -d); SRVDIR=$(mktemp -d); WORK=$(mktemp -d)
    cleanup(){ kill "$HOLDER" 2>/dev/null; [ -n "${SRV:-}" ] && kill "$SRV" 2>/dev/null; [ -n "${SNIFF_PID:-}" ] && kill "$SNIFF_PID" 2>/dev/null; rm -rf "$KDIR" "$SRVDIR" "$WORK" "$MARK" "${SNIFFDIR:-}" 2>/dev/null; true; }
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
    "$WG" genkey >"$KDIR/a.key" 2>>"$EV" || fail "wg genkey (userns?)"; "$WG" pubkey <"$KDIR/a.key" >"$KDIR/a.pub" 2>>"$EV" || fail "wg pubkey A"
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

    # ---- REAL pure-python FTP peer on the WG-only overlay 10.10.0.2:2121 ----
    NONCE="hermetic-ftp-$$-${RANDOM}"
    printf 'ftp-payload-%s\n' "$NONCE" > "$SRVDIR/$NONCE.txt"
    cat > "$WORK/ftpd.py" <<'PYEOF'
import os, sys, socket, threading
BIND, PORT, ROOT = sys.argv[1], int(sys.argv[2]), sys.argv[3]
EMPTY = (len(sys.argv) > 4 and sys.argv[4] == 'empty')   # golden-bad: empty listing

def listing():
    if EMPTY:
        return b''
    out = []
    for n in sorted(os.listdir(ROOT)):
        p = os.path.join(ROOT, n)
        if os.path.isfile(p):
            out.append('-rw-r--r-- 1 owner group %d Jan 01 00:00 %s' % (os.path.getsize(p), n))
    if not out:
        return b''
    return ('\r\n'.join(out) + '\r\n').encode()

def handle(conn):
    conn.sendall(b'220 hermetic-ftpd ready\r\n')
    f = conn.makefile('rb')
    dsock = [None]
    def open_pasv():
        if dsock[0]:
            try: dsock[0].close()
            except Exception: pass
        s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        s.bind((BIND, 0)); s.listen(1); s.settimeout(15); dsock[0] = s
        return s.getsockname()[1]
    def data_accept():
        try:
            dc, _ = dsock[0].accept(); return dc
        except Exception:
            return None
    def close_data():
        try: dsock[0].close()
        except Exception: pass
        dsock[0] = None
    while True:
        line = f.readline()
        if not line: break
        try: cmd = line.decode('latin-1').strip()
        except Exception: cmd = ''
        up = cmd.upper()
        if up.startswith('USER'): conn.sendall(b'331 any user ok\r\n')
        elif up.startswith('PASS'): conn.sendall(b'230 logged in\r\n')
        elif up.startswith('SYST'): conn.sendall(b'215 UNIX Type: L8\r\n')
        elif up.startswith('TYPE'): conn.sendall(b'200 type set\r\n')
        elif up.startswith('PWD') or up.startswith('XPWD'): conn.sendall(b'257 "/" is cwd\r\n')
        elif up.startswith('CWD') or up.startswith('CDUP') or up.startswith('XCWD'): conn.sendall(b'250 cwd ok\r\n')
        elif up.startswith('FEAT'): conn.sendall(b'211-features\r\n EPSV\r\n PASV\r\n SIZE\r\n211 end\r\n')
        elif up.startswith('OPTS'): conn.sendall(b'200 ok\r\n')
        elif up.startswith('NOOP'): conn.sendall(b'200 noop\r\n')
        elif up.startswith('SIZE'):
            p = os.path.join(ROOT, os.path.basename(cmd[4:].strip()))
            conn.sendall(('213 %d\r\n' % os.path.getsize(p)).encode() if os.path.isfile(p) else b'550 no file\r\n')
        elif up.startswith('EPSV'):
            conn.sendall(('229 Entering Extended Passive Mode (|||%d|)\r\n' % open_pasv()).encode())
        elif up.startswith('PASV'):
            port = open_pasv(); h = BIND.split('.')
            conn.sendall(('227 Entering Passive Mode (%s,%s,%s,%s,%d,%d)\r\n'
                          % (h[0], h[1], h[2], h[3], port // 256, port % 256)).encode())
        elif up.startswith('LIST') or up.startswith('NLST') or up.startswith('MLSD'):
            if not dsock[0]: conn.sendall(b'425 use PASV first\r\n'); continue
            conn.sendall(b'150 opening data\r\n')
            dc = data_accept()
            if dc: dc.sendall(listing()); dc.close()
            close_data(); conn.sendall(b'226 transfer complete\r\n')
        elif up.startswith('RETR'):
            p = os.path.join(ROOT, os.path.basename(cmd[4:].strip().lstrip('/')))
            if not dsock[0] or not os.path.isfile(p): conn.sendall(b'550 not found\r\n'); continue
            conn.sendall(b'150 opening data\r\n')
            dc = data_accept()
            if dc:
                with open(p, 'rb') as fh: dc.sendall(fh.read())
                dc.close()
            close_data(); conn.sendall(b'226 transfer complete\r\n')
        elif up.startswith('QUIT'): conn.sendall(b'221 bye\r\n'); break
        else: conn.sendall(b'200 ok\r\n')
    try: conn.close()
    except Exception: pass

srv = socket.socket(); srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind((BIND, PORT)); srv.listen(5)
while True:
    c, _ = srv.accept()
    threading.Thread(target=handle, args=(c,), daemon=True).start()
PYEOF
    FTP_ARG=""
    if [ "${FT_MUT:-0}" = empty ]; then
        FTP_ARG=empty
        log "MUT: FTP server serves an EMPTY listing — the real test must NOT PASS (SKIP), teeth must fire (§11.4.107(10))"
    fi
    # self-bounded server (timeout inside the netns, direct parent of python) so an
    # outer-SIGKILL orphan self-terminates — no indefinite linger (§12; -k 2 90
    # outlives the holder 90s sleep budget).
    ( exec nsenter -t "$HOLDER" -n timeout -k 2 90 python3 "$WORK/ftpd.py" 10.10.0.2 2121 "$SRVDIR" $FTP_ARG ) >/dev/null 2>&1 &
    SRV=$!
    UP=0
    for _ in $(seq 1 40); do
        if python3 -c 'import socket,sys; s=socket.socket(); s.settimeout(0.4); sys.exit(0 if s.connect_ex(("10.10.0.2",2121))==0 else 1)' 2>/dev/null; then UP=1; break; fi
        sleep 0.25
    done
    [ "$UP" = 1 ] || fail "peer FTP control port never reachable over the tunnel (10.10.0.2:2121)"
    HS=$("$WG" show wg0 latest-handshakes 2>/dev/null | awk '{print $2}' | head -1); HS=${HS:-0}
    log "tunnel up: wg handshake=$HS; peer FTP served (anonymous, overlay 10.10.0.2:2121)"

    # === §11.4.107 underlay-sniff differential (task #65 fan-out from the WG substrate
    # hermetic_wg_roundtrip.sh:268-374). BEFORE the not-stale self-fetch (LIST + RETR)
    # below, start a BOUNDED capture on the CLIENT underlay veth (veth0, 10.9.0.x —
    # carries the ENCRYPTED WG UDP), NOT wg0. After the fetch we assert (a) a WireGuard
    # type-4 data message (0x04 00 00 00) to the WG listen port is present AND (b) this
    # run's fresh plaintext marker $NONCE (the LIST filename + the RETR body) is ABSENT
    # from the raw underlay bytes (the FTP cleartext rode encrypted, not leaked).
    # AF_PACKET SOCK_RAW needs CAP_NET_RAW, held by this `unshare -Urnm` root-in-userns
    # for its OWN netns's veth only (§11.4.174 — never a host iface). Bounded window +
    # byte cap (§12.6); reaped in the trap. Honest SKIP if AF_PACKET+tcpdump both
    # unavailable (§11.4.3). Runs on the NORMAL protocol path only, so the existing
    # FT_MUT=empty golden-bad is untouched.
    SNIFF_ACTIVE=0; SNIFF_MODE=none; SNIFF_PID=""; SNIFFDIR=""
    if [ "${FT_MUT:-0}" != empty ]; then
        SNIFF_IFACE=veth0
        SNIFFDIR=$(mktemp -d)
        SNIFF_CAP="$SNIFFDIR/underlay.pcap"; SNIFF_READY="$SNIFFDIR/ready"
        SNIFF_WINDOW=3.5; SNIFF_CAPB=4194304
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
        _emit_an_py > "$SNIFFDIR/an.py"    # §11.4.107 frame analyzer — single source (see _emit_an_py)
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
        # §11.4.107(10) golden-bad: SNIFF_MUT=plain transmits the SAME run marker in
        # CLEARTEXT on the underlay veth so the "plaintext absent" assertion MUST fail
        # (proving the assertion is load-bearing, not a tautology). NEVER runs in normal
        # mode; sent only when the capture is actually active. Port 9 (discard) — distinct
        # from this harness's §11.4.111 negative-control TCP :2121, so NEG-OK stays valid.
        if [ "$SNIFF_ACTIVE" = 1 ] && [ "${SNIFF_MUT:-0}" = plain ]; then
            python3 -c 'import socket,sys; s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM); [s.sendto(sys.argv[1].encode(),("10.9.0.2",9)) for _ in range(6)]' "$NONCE" 2>>"$EV" || true
            log "SNIFF_MUT=plain: emitted the run marker in CLEARTEXT on $SNIFF_IFACE (underlay) — plaintext-absent assertion MUST now FAIL"
        fi
    fi

    # §11.4.107 not-stale + anti-bluff cross-check: list the FTP dir OURSELVES over
    # the tunnel and confirm THIS run's fresh nonce file is present (normal) / the
    # listing is empty (golden-bad). Proves a real passive round-trip over the
    # encrypted overlay before the promoted test runs — de-couples the eventual PASS
    # from the downstream grep string and forbids a stale/wrong peer.
    SELF=$(curl --silent --show-error --ftp-pasv --connect-timeout 8 --max-time 20 "ftp://10.10.0.2:2121/" 2>>"$EV") || SELF=""
    if [ "${FT_MUT:-0}" = empty ]; then
        printf '%s' "$SELF" | grep -q "$NONCE" && fail "golden-bad self-fetch unexpectedly listed the nonce (empty mode broken)"
    else
        printf '%s' "$SELF" | grep -q "$NONCE" || fail "self-fetch FTP listing missing this run's nonce file (stale/broken peer over tunnel?)"
        # §11.4.107(9) content-verified byte fetch (full-reference oracle): RETR the
        # nonce file by its exact (CRLF-free, self-constructed) name over the tunnel and
        # assert the bytes equal the known payload. This is what genuinely EARNS the
        # "+fetch" claim — the promoted test's own fetch is best-effort + ungated (its
        # PASS is listing-only), so the harness proves the byte round-trip itself.
        SELF_BODY=$(curl --silent --show-error --ftp-pasv --connect-timeout 8 --max-time 20 "ftp://10.10.0.2:2121/$NONCE.txt" 2>>"$EV") || SELF_BODY=""
        [ "$SELF_BODY" = "ftp-payload-$NONCE" ] || fail "self-RETR of $NONCE.txt over the tunnel returned wrong/empty bytes — byte round-trip not proven (got: '${SELF_BODY}')"
        log "self-RETR OK: $NONCE.txt bytes matched the known payload over the tunnel (content-verified fetch, §11.4.107(9))"
    fi

    # --- §11.4.107 underlay-sniff differential: stop the capture (started above, before
    # the self-fetch) and run the two assertions on the captured underlay bytes ---
    if [ "$SNIFF_ACTIVE" = 1 ]; then
        [ "$SNIFF_MODE" = tcpdump ] && { sleep 0.4; kill -INT "$SNIFF_PID" 2>/dev/null || true; }
        wait "$SNIFF_PID" 2>/dev/null; SNIFF_PID=""
        _src=0
        python3 "$SNIFFDIR/an.py" "$SNIFF_CAP" "$NONCE" "$LPORT" 2>>"$EV" || _src=$?
        case "$_src" in
            0) log "SNIFF-OK: underlay $SNIFF_IFACE ($SNIFF_MODE): WG data (0x04) to :$LPORT present, plaintext marker absent (§11.4.107 non-leak). Boundary: proves non-leak on the LOCAL simulated underlay veth, NOT the live Mullvad WAN (§11.4.3/§11.4.6)." ;;
            2) fail "SNIFF: plaintext marker '$NONCE' appeared on the underlay $SNIFF_IFACE — FTP payload leaked in cleartext (§11.4.107)" ;;
            3) fail "SNIFF: no WireGuard type-4 data (0x04) datagram to :$LPORT captured on the underlay $SNIFF_IFACE — tunnel did not carry traffic on the wire" ;;
            *) fail "SNIFF: underlay-capture analyzer error (rc=$_src)" ;;
        esac
    fi

    # ---- bridge contract => hermetic FTP peer; run the REAL test in netns A ----
    export HELIX_BRIDGE_MODE=hermetic
    export HELIX_SVORD_DIR="$SRVDIR"
    export HELIX_BRIDGE_CONNECT='true'
    export HELIX_BRIDGE_DISCONNECT='true'
    # honest health probe: genuinely reachable over the tunnel (not a rubber-stamp)
    export HELIX_BRIDGE_HEALTH='python3 -c "import socket,sys; s=socket.socket(); s.settimeout(1); sys.exit(0 if s.connect_ex((\"10.10.0.2\",2121))==0 else 1)"'
    export HELIX_BRIDGE_SUBNET='10.10.0.0/24'
    export HELIX_BRIDGE_HOST='10.10.0.2'
    export HELIX_VPN_FTP_URL='ftp://10.10.0.2:2121/'
    # anonymous — HELIX_VPN_FTP_USER deliberately unset (no credentials, §11.4.10)
    # Determinism (§11.4.50, review nit): scrub any ambient-shell exports of the
    # SIBLING legs so they SKIP deterministically instead of attempting a (from-netns
    # unreachable) real connection that could flip _trc into a spurious FAIL (a false
    # NEGATIVE only — never a bluff PASS). Only the FTP leg stays configured.
    unset HELIX_VPN_FTP_USER HELIX_VPN_FTP_PASS HELIX_VPN_FTP_ACTIVE_CMD \
          HELIX_VPN_SFTP_HOST HELIX_VPN_SFTP_USER HELIX_VPN_SFTP_PORT \
          HELIX_VPN_SFTP_DIR HELIX_VPN_SFTP_KEY \
          HELIX_VPN_WEBDAV_URL HELIX_SQUID_PROXY 2>/dev/null || true

    TEST="$_root/tests/vpn_lan/ftp_sftp_webdav.sh"
    [ -f "$TEST" ] || fail "promoted test missing: $TEST"
    # Coupling contract (de-brittle §11.4.6): we assert on ftp_sftp_webdav.sh emitting
    # a `(PASS|SKIP): FTP passive ...` line — verify the token still exists so a
    # future rename fails clearly HERE, not as a silent grep miss downstream.
    grep -q 'FTP passive' "$TEST" || fail "promoted test no longer has the 'FTP passive' leg — coupling contract broke; update this harness"
    _t_out="${FT_EV_DIR}/ftp_sftp_webdav.stdout"
    _trc=0; bash "$TEST" >"$_t_out" 2>&1 || _trc=$?
    { printf '\n--- promoted ftp_sftp_webdav.sh (exit=%s) ---\n' "$_trc"; cat "$_t_out"; } >>"$EV"

    if [ "${FT_MUT:-0}" = empty ]; then
        # empty listing => the FTP leg cannot list => it SKIPs (never PASS).
        if ! grep -Eq '^PASS:.*FTP passive' "$_t_out" && grep -Eq '^SKIP:.*FTP passive' "$_t_out"; then
            log "FT_MUT_OK: with an EMPTY FTP listing the promoted test did NOT PASS (SKIPped) — a real PASS provably requires a real non-empty listing over the tunnel"; exit 0
        fi
        fail "golden-bad did not suppress the FTP PASS (exit=$_trc) — promotion may be a rubber-stamp"
    fi

    # normal: the real test must produce a genuine FTP PASS + exit 0
    if [ "$_trc" = 0 ] && grep -Eq '^PASS:.*FTP passive' "$_t_out"; then
        # §11.4.111 negative control (self-evidencing): the FTP peer binds the WG-only
        # overlay 10.10.0.2 ONLY, so the SAME passive connect aimed from netns A at the
        # UNDERLAY peer IP 10.9.0.2:2121 (veth-reachable, nothing listening) MUST fail.
        # A success would mean the FTP PASS was NOT gated by the tunnel.
        _neg=0
        curl --silent --show-error --ftp-pasv --connect-timeout 3 --max-time 6 "ftp://10.9.0.2:2121/" >/dev/null 2>&1 || _neg=$?
        [ "$_neg" != 0 ] || fail "NEG: underlay ftp://10.9.0.2:2121/ unexpectedly listed — FTP traffic is NOT tunnel-gated"
        log "NEG-OK: underlay ftp://10.9.0.2:2121/ refused/failed (rc=$_neg) — the FTP peer is overlay-only; the FTP PASS required the tunnel (§11.4.111)"
        log "FT_PASS: the UNMODIFIED ftp_sftp_webdav.sh FTP leg produced a REAL PASS over the hermetic WireGuard tunnel (bridge_require flipped SKIP->UP; §11.4.52 promotion)"
        exit 0
    fi
    fail "promoted test did not produce a real FTP PASS (exit=$_trc)"
fi

# ---------------------------------------------------------------------------
# OUTER: preflight (honest SKIP §11.4.3 / §12) then re-exec under unshare -Urnm.
# ---------------------------------------------------------------------------
SCRIPT_LABEL='hermetic_ftp_run'
_sd=$(cd "$(dirname "$0")" && pwd); _root=$(cd "$_sd/../.." && pwd)
FT_MUT="${FT_MUT:-0}"
SNIFF_MUT="${SNIFF_MUT:-0}"
_skip(){ printf 'SKIP: %s [%s]\n' "$SCRIPT_LABEL" "$1"; exit 0; }
for _t in unshare nsenter ip python3 curl timeout wg; do command -v "$_t" >/dev/null 2>&1 || _skip "tool absent: $_t"; done
[ -d /sys/module/wireguard ] || _skip "host 'wireguard' kernel module not loaded"
[ -f "$_root/tests/vpn_lan/ftp_sftp_webdav.sh" ] || _skip "promoted test absent"
if [ -r /proc/sys/kernel/unprivileged_userns_clone ] && [ "$(cat /proc/sys/kernel/unprivileged_userns_clone)" = 0 ]; then _skip "unprivileged userns disabled"; fi
unshare -Urnm true 2>/dev/null || _skip "unshare -Urnm failed (unprivileged user+net+mount ns unavailable)"
_softu=$(ulimit -u 2>/dev/null || echo 0); _inuse=$(ps --no-headers -u "$(id -u)" 2>/dev/null | wc -l | tr -d ' ')
if [ "${_softu}" != unlimited ] && [ "${_softu:-0}" -gt 0 ] 2>/dev/null && [ "$(( _softu - _inuse ))" -lt 64 ] 2>/dev/null; then _skip "process headroom too low (§12)"; fi

TS=$(date -u +%Y%m%dT%H%M%SZ 2>/dev/null || date +%Y%m%dT%H%M%SZ)
if [ "$FT_MUT" = empty ] || [ "$SNIFF_MUT" = plain ]; then _mode=mut; else _mode=pass; fi
export FT_EV_DIR="$_root/qa-results/vpn_lan/hermetic_ftp/${TS}_${_mode}_$$"
_rc=0
FT_MUT="$FT_MUT" timeout 70 env FT_EV_DIR="$FT_EV_DIR" FT_ROOT="$_root" FT_MUT="$FT_MUT" SNIFF_MUT="$SNIFF_MUT" \
    unshare -Urnm bash "$0" --inner >/dev/null 2>&1 || _rc=$?
_ev="$FT_EV_DIR/run.evidence"

if [ "$FT_MUT" = empty ]; then
    if [ "$_rc" = 0 ] && grep -q 'FT_MUT_OK' "$_ev" 2>/dev/null; then
        printf 'PASS: %s [§1.1 golden-bad — an empty FTP listing suppressed the real PASS (test SKIPped); promotion is genuine, not a rubber-stamp; evidence: %s]\n' "$SCRIPT_LABEL" "$_ev"; exit 0
    fi
    printf 'FAIL: %s [golden-bad did not behave (rc=%s); evidence: %s]\n' "$SCRIPT_LABEL" "$_rc" "$_ev"; tail -5 "$_ev" 2>/dev/null; exit 1
fi
if [ "$_rc" = 0 ] && grep -q 'FT_PASS' "$_ev" 2>/dev/null; then
    printf 'PASS: %s [unmodified ftp_sftp_webdav.sh FTP leg promoted to AUTONOMOUS over the hermetic WireGuard tunnel — real passive listing (promoted test) + content-verified byte fetch (harness self-RETR), no operator/podman/VPN (§11.4.52); evidence: %s]\n' "$SCRIPT_LABEL" "$_ev"; exit 0
fi
printf 'FAIL: %s [rc=%s; evidence: %s]\n' "$SCRIPT_LABEL" "$_rc" "$_ev"; tail -5 "$_ev" 2>/dev/null || true; exit 1
