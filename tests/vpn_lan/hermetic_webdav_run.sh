#!/usr/bin/env bash
###############################################################################
# hermetic_webdav_run.sh — promote the WebDAV leg of ftp_sftp_webdav.sh (T3.3)
#   to run AUTONOMOUSLY over the hermetic kernel-WireGuard tunnel — no operator,
#   no podman, no Squid, no Mullvad, no live VPN.
#   (docs/design/vpn_lan_access/hermetic_wg_test_harness.md — H2 family)
#
# Purpose:
#   Prove the hermetic harness PROMOTES the operator-gated WebDAV protocol leg
#   (§11.4.52). Inside one `unshare -Urnm` it: (1) stands up the H0-full
#   kernel-WireGuard tunnel between two unprivileged netns (veth 10.9.0.x underlay
#   + real WG overlay 10.10.0.x); (2) runs TWO pure-python3-stdlib servers — a
#   WebDAV origin in netns B bound to the WG-only overlay 10.10.0.2:8080 that
#   answers `PROPFIND /dav/ Depth:0` with HTTP 207 Multi-Status + a valid non-empty
#   <D:multistatus> body, and a forward proxy in netns A on 127.0.0.1:3128 that
#   relays the client's absolute-URI PROPFIND to the origin over the tunnel and
#   streams the response back verbatim (the stand-in for the real Squid);
#   (3) points the bridge contract (tests/lib/svord_bridge.sh) at that origin and
#   proxy; (4) runs the UNMODIFIED tests/vpn_lan/ftp_sftp_webdav.sh INSIDE netns A,
#   where its own `bridge_require` gate flips from honest-SKIP to UP and its WebDAV
#   leg produces a REAL 207 PASS with captured evidence. The real svord/Mullvad run
#   stays the §11.4.3 real-topology confirmation.
#
# Usage:
#   tests/vpn_lan/hermetic_webdav_run.sh                  # PASS / SKIP / FAIL
#   WEBDAV_MUT=bad207 tests/vpn_lan/hermetic_webdav_run.sh # §1.1 golden-bad: the
#     origin answers HTTP 200 (NOT 207) for PROPFIND => the UNMODIFIED test MUST
#     fire its fail-closed branch (^FAIL:.*WebDAV, exit != 0), proving the 207
#     assertion is genuinely exercised, not a rubber-stamp (§11.4.68/§11.4.107(10)).
#   (internal) hermetic_webdav_run.sh --inner
#
# Outputs:
#   One PASS/SKIP/FAIL line. Evidence:
#   qa-results/vpn_lan/hermetic_webdav/<UTC-ts>_<pass|mut>_<pid>/run.evidence
#     + selffetch.propfind.xml (the harness's own round-trip cross-check)
#     + ftp_sftp_webdav.stdout (the promoted test's captured stdout;
#       it also writes its own qa-results/vpn_lan/phase3/... evidence).
#
# Preflight / honest SKIP (§11.4.3): tools unshare/nsenter/ip/wg/python3/curl/
#   timeout, host `wireguard` kernel module, unprivileged userns, `unshare -Urnm`,
#   process headroom (§12) — else SKIP, never a fake PASS.
#
# Side-effects:
#   ONE throwaway user+net+mount namespace (unshare -Urnm); the tunnel + both
#   python servers + the promoted test all live inside it and die with unshare
#   (§11.4.14). Nothing on the host network touched/visible (§11.4.174). WG keys
#   mode-0600 in-namespace, never logged (§11.4.10). WebDAV needs no credentials.
#
# Dependencies: bash, unshare+nsenter, iproute2 ip (wireguard link type), wg, host
#   `wireguard` kernel module, python3 (stdlib only — http.server + socketserver),
#   curl, timeout. NO installed package/daemon (§11.4.122).
#
# Cross-references:
#   tests/vpn_lan/hermetic_wg_roundtrip.sh  (the H0-full tunnel this reuses)
#   tests/vpn_lan/hermetic_bridge_run.sh    (sibling promotion — chromecast eureka)
#   tests/vpn_lan/ftp_sftp_webdav.sh        (the promoted protocol test, UNMODIFIED)
#   tests/lib/svord_bridge.sh               (bridge contract library)
#   docs/scripts/hermetic_webdav_run.md     (companion guide, §11.4.18)
#   constitution §11.4.3 / §11.4.6 / §11.4.10 / §11.4.52 / §11.4.68 / §11.4.107 /
#     §11.4.122 / §11.4.174 / §12
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
    EV="${HW_EV_DIR:?}/run.evidence"; mkdir -p "${HW_EV_DIR}"; : >"$EV"
    _root="${HW_ROOT:?}"
    log(){ printf '%s\n' "$*" | tee -a "$EV"; }
    fail(){ log "HW_FAIL: $*"; exit 1; }
    WG=$(command -v wg 2>/dev/null || echo /usr/sbin/wg)

    # ---- WG tunnel (as H0-full: veth underlay + real kernel WireGuard) --------
    ip link set lo up 2>>"$EV" || fail "lo up"
    ip link add veth0 type veth peer name veth1 2>>"$EV" || fail "veth add"
    MARK=$(mktemp -u); unshare -n bash -c "touch '$MARK'; exec sleep 90" & HOLDER=$!
    KDIR=$(mktemp -d); SRVDIR=$(mktemp -d); PYDIR=$(mktemp -d)
    cleanup(){
        kill "$HOLDER" 2>/dev/null
        [ -n "${ORIGIN:-}" ] && kill "$ORIGIN" 2>/dev/null
        [ -n "${PROXY:-}" ] && kill "$PROXY" 2>/dev/null
        [ -n "${SNIFF_PID:-}" ] && kill "$SNIFF_PID" 2>/dev/null
        rm -rf "$KDIR" "$SRVDIR" "$PYDIR" "$MARK" "${SNIFFDIR:-}" 2>/dev/null; true
    }
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

    # ---- pure-python3-stdlib WebDAV origin (netns B) --------------------------
    # Answers PROPFIND /dav/ Depth:0 with 207 Multi-Status + a valid non-empty
    # <D:multistatus> body (a plain GET too). WEBDAV_MUT=bad207 => HTTP 200 instead
    # of 207 (golden-bad §1.1) so the UNMODIFIED test fail-closes on the 207 assert.
    cat >"$PYDIR/origin.py" <<'ORIGIN_PY'
#!/usr/bin/env python3
import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

BIND  = os.environ.get("ORIGIN_BIND", "10.10.0.2")
PORT  = int(os.environ.get("ORIGIN_PORT", "8080"))
MUT   = os.environ.get("WEBDAV_MUT", "")
NONCE = os.environ.get("ORIGIN_NONCE", "nonce")

MULTISTATUS = (
    '<?xml version="1.0" encoding="utf-8"?>\n'
    '<D:multistatus xmlns:D="DAV:">\n'
    '  <D:response>\n'
    '    <D:href>/dav/</D:href>\n'
    '    <D:propstat>\n'
    '      <D:prop>\n'
    '        <D:displayname>dav</D:displayname>\n'
    '        <D:resourcetype><D:collection/></D:resourcetype>\n'
    '        <D:getetag>"helix-' + NONCE + '"</D:getetag>\n'
    '      </D:prop>\n'
    '      <D:status>HTTP/1.1 200 OK</D:status>\n'
    '    </D:propstat>\n'
    '  </D:response>\n'
    '  <D:response>\n'
    '    <D:href>/dav/hello.txt</D:href>\n'
    '    <D:propstat>\n'
    '      <D:prop>\n'
    '        <D:displayname>hello.txt</D:displayname>\n'
    '        <D:resourcetype/>\n'
    '        <D:getcontentlength>20</D:getcontentlength>\n'
    '        <D:getetag>"helix-' + NONCE + '-1"</D:getetag>\n'
    '      </D:prop>\n'
    '      <D:status>HTTP/1.1 200 OK</D:status>\n'
    '    </D:propstat>\n'
    '  </D:response>\n'
    '</D:multistatus>\n'
).encode("utf-8")

class DAV(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def _drain(self):
        n = int(self.headers.get("Content-Length", 0) or 0)
        if n > 0:
            self.rfile.read(n)

    def do_PROPFIND(self):
        self._drain()
        if MUT == "bad207":
            self.send_response(200)                 # golden-bad: WRONG status
        else:
            self.send_response(207, "Multi-Status")
        self.send_header("Content-Type", 'application/xml; charset="utf-8"')
        self.send_header("Content-Length", str(len(MULTISTATUS)))
        self.send_header("DAV", "1,2")
        self.end_headers()
        self.wfile.write(MULTISTATUS)

    def do_OPTIONS(self):
        self._drain()
        self.send_response(200)
        self.send_header("Allow", "OPTIONS, GET, PROPFIND")
        self.send_header("DAV", "1,2")
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_GET(self):
        self._drain()
        body = b"helix webdav origin\n"
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a):
        pass

ThreadingHTTPServer((BIND, PORT), DAV).serve_forever()
ORIGIN_PY

    # ---- pure-python3-stdlib forward proxy (netns A) --------------------------
    # curl -x sends the method + ABSOLUTE URI ("PROPFIND http://10.10.0.2:8080/dav/
    # HTTP/1.1"). The proxy parses it, opens a TCP conn to the origin over the WG
    # tunnel, relays the request in origin-form ("PROPFIND /dav/ ...") + headers +
    # body (Content-Length forwarded by length), forces upstream Connection: close,
    # and streams the response back verbatim (status line + headers + body).
    cat >"$PYDIR/proxy.py" <<'PROXY_PY'
#!/usr/bin/env python3
import os, socket, socketserver
from urllib.parse import urlsplit

BIND = os.environ.get("PROXY_BIND", "127.0.0.1")
PORT = int(os.environ.get("PROXY_PORT", "3128"))

def _read_head(sock):
    buf = b""
    while b"\r\n\r\n" not in buf:
        chunk = sock.recv(4096)
        if not chunk:
            break
        buf += chunk
        if len(buf) > 65536:
            break
    return buf

class Proxy(socketserver.BaseRequestHandler):
    def handle(self):
        c = self.request
        c.settimeout(20)
        try:
            head = _read_head(c)
        except OSError:
            return
        if not head or b"\r\n\r\n" not in head:
            return
        raw_head, _, rest = head.partition(b"\r\n\r\n")
        lines = raw_head.split(b"\r\n")
        try:
            method, uri, version = lines[0].decode("latin-1").split(" ", 2)
        except ValueError:
            return
        u = urlsplit(uri)
        host = u.hostname
        port = u.port or 80
        path = u.path or "/"
        if u.query:
            path += "?" + u.query
        if not host:
            return
        # Forward all request headers except hop-by-hop/proxy ones; note body len.
        clen = 0
        fwd = []
        for h in lines[1:]:
            low = h.split(b":", 1)[0].strip().lower()
            if low in (b"proxy-connection", b"connection"):
                continue
            if low == b"content-length":
                try:
                    clen = int(h.split(b":", 1)[1].strip())
                except ValueError:
                    clen = 0
            fwd.append(h)
        # Read the (possibly empty) request body by Content-Length.
        body = rest
        while clen > 0 and len(body) < clen:
            chunk = c.recv(4096)
            if not chunk:
                break
            body += chunk
        body = body[:clen] if clen > 0 else b""
        # Build the origin-form request.
        req = (method + " " + path + " " + version + "\r\n").encode("latin-1")
        req += b"\r\n".join(fwd)
        if fwd:
            req += b"\r\n"
        req += b"Connection: close\r\n\r\n" + body
        try:
            up = socket.create_connection((host, port), timeout=15)
        except OSError:
            c.sendall(b"HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\n"
                      b"Connection: close\r\n\r\n")
            return
        try:
            up.settimeout(20)
            up.sendall(req)
            # Stream the response back verbatim; upstream Connection: close (and
            # any Content-Length within these bytes) delimits the body.
            while True:
                chunk = up.recv(65536)
                if not chunk:
                    break
                c.sendall(chunk)
        except OSError:
            pass
        finally:
            up.close()

class TS(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True

TS((BIND, PORT), Proxy).serve_forever()
PROXY_PY

    printf 'helix webdav origin\n' > "$SRVDIR/hello.txt"
    NONCE="webdav-$$-${RANDOM}"

    # self-bounded servers (timeout inside/adjacent the netns, direct parent of
    # python) so an outer-SIGKILL orphan self-terminates — no indefinite linger
    # (review MEDIUM host-safety; -k 2 90 outlives the holder's 90s sleep budget).
    WEBDAV_MUT="${WEBDAV_MUT:-0}" ORIGIN_NONCE="$NONCE" ORIGIN_BIND=10.10.0.2 ORIGIN_PORT=8080 \
        nsenter -t "$HOLDER" -n timeout -k 2 90 python3 "$PYDIR/origin.py" >/dev/null 2>&1 &
    ORIGIN=$!
    PROXY_BIND=127.0.0.1 PROXY_PORT=3128 \
        timeout -k 2 90 python3 "$PYDIR/proxy.py" >/dev/null 2>&1 &
    PROXY=$!

    UP=0
    for _ in $(seq 1 40); do
        if python3 -c 'import socket,sys; s=socket.socket(); s.settimeout(0.4); sys.exit(0 if s.connect_ex(("10.10.0.2",8080))==0 else 1)' 2>/dev/null; then UP=1; break; fi
        sleep 0.25
    done
    [ "$UP" = 1 ] || fail "WebDAV origin never reachable over the tunnel (10.10.0.2:8080)"
    PUP=0
    for _ in $(seq 1 40); do
        if python3 -c 'import socket,sys; s=socket.socket(); s.settimeout(0.4); sys.exit(0 if s.connect_ex(("127.0.0.1",3128))==0 else 1)' 2>/dev/null; then PUP=1; break; fi
        sleep 0.25
    done
    [ "$PUP" = 1 ] || fail "forward proxy never came up (127.0.0.1:3128)"
    HS=$("$WG" show wg0 latest-handshakes 2>/dev/null | awk '{print $2}' | head -1); HS=${HS:-0}
    log "tunnel up: wg handshake=$HS; WebDAV origin @10.10.0.2:8080 (netns B) + forward proxy @127.0.0.1:3128 (netns A) ready"

    # === §11.4.107 underlay-sniff differential (task #65 fan-out from the WG substrate
    # hermetic_wg_roundtrip.sh:268-374). BEFORE the not-stale self-fetch below, start a
    # BOUNDED capture on the CLIENT underlay veth (veth0, 10.9.0.x — carries the ENCRYPTED
    # WG UDP), NOT wg0. Only the proxy->origin 10.10.0.2:8080 hop rides wg0/veth0
    # (client->proxy is loopback 127.0.0.1:3128, off the underlay). After the fetch we
    # assert (a) a WireGuard type-4 data message (0x04 00 00 00) to the WG listen port is
    # present AND (b) this run's fresh plaintext marker $NONCE (the 207-body etag) is
    # ABSENT from the raw underlay bytes (the 207 rode encrypted, not leaked). AF_PACKET
    # SOCK_RAW needs CAP_NET_RAW, held by this `unshare -Urnm` root-in-userns for its OWN
    # netns's veth only (§11.4.174 — never a host iface). Bounded window + byte cap
    # (§12.6); reaped in the trap. Honest SKIP if AF_PACKET+tcpdump both unavailable
    # (§11.4.3). Runs on the NORMAL protocol path only, so the WEBDAV_MUT=bad207 golden-
    # bad is untouched.
    SNIFF_ACTIVE=0; SNIFF_MODE=none; SNIFF_PID=""; SNIFFDIR=""
    if [ "${WEBDAV_MUT:-0}" != bad207 ]; then
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
        # from this harness's §11.4.111 negative-control TCP :8080, so NEG-OK stays valid.
        if [ "$SNIFF_ACTIVE" = 1 ] && [ "${SNIFF_MUT:-0}" = plain ]; then
            python3 -c 'import socket,sys; s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM); [s.sendto(sys.argv[1].encode(),("10.9.0.2",9)) for _ in range(6)]' "$NONCE" 2>>"$EV" || true
            log "SNIFF_MUT=plain: emitted the run marker in CLEARTEXT on $SNIFF_IFACE (underlay) — plaintext-absent assertion MUST now FAIL"
        fi
    fi

    # §11.4.107 not-stale + anti-bluff cross-check: PROPFIND OURSELVES through the
    # proxy over the tunnel and assert the real status (207 normal / not-207 golden-
    # bad). Proves a genuine encrypted round-trip of THIS run's data through the
    # proxy BEFORE the promoted test runs — de-couples the eventual PASS from the
    # downstream grep string, and forbids a stale/wrong origin.
    SELF_XML="${HW_EV_DIR}/selffetch.propfind.xml"
    SELF_CODE=$(curl --silent --show-error -x http://127.0.0.1:3128 \
        -X PROPFIND -H 'Depth: 0' -H 'Content-Type: application/xml' \
        --connect-timeout 10 --max-time 25 \
        -o "$SELF_XML" -w '%{http_code}' http://10.10.0.2:8080/dav/ 2>>"$EV") \
        || fail "self PROPFIND through proxy over tunnel failed to execute"
    log "self-fetch PROPFIND through proxy: http_status=$SELF_CODE body_bytes=$(wc -c <"$SELF_XML" 2>/dev/null | tr -d ' ')"
    if [ "${WEBDAV_MUT:-0}" = bad207 ]; then
        [ "$SELF_CODE" = 207 ] && fail "golden-bad self-fetch unexpectedly returned 207 (mutation not applied over the tunnel)"
        log "MUT: origin returned HTTP $SELF_CODE (not 207) for PROPFIND — the UNMODIFIED test must FAIL-closed (§11.4.68)"
    else
        [ "$SELF_CODE" = 207 ] || fail "self-fetch PROPFIND did not return 207 (got $SELF_CODE) over the tunnel through the proxy"
        [ -s "$SELF_XML" ] || fail "self-fetch 207 but empty body"
        grep -q 'multistatus' "$SELF_XML" || fail "self-fetch 207 body is not a DAV multistatus document"
        grep -q "$NONCE" "$SELF_XML" || fail "self-fetch multistatus missing this run's fresh nonce (stale/wrong origin over tunnel?)"
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
            2) fail "SNIFF: plaintext marker '$NONCE' appeared on the underlay $SNIFF_IFACE — WebDAV payload leaked in cleartext (§11.4.107)" ;;
            3) fail "SNIFF: no WireGuard type-4 data (0x04) datagram to :$LPORT captured on the underlay $SNIFF_IFACE — tunnel did not carry traffic on the wire" ;;
            *) fail "SNIFF: underlay-capture analyzer error (rc=$_src)" ;;
        esac
    fi

    # ---- bridge contract => hermetic origin/proxy; run the REAL test in netns A -
    export HELIX_BRIDGE_MODE=hermetic
    export HELIX_SVORD_DIR="$SRVDIR"
    export HELIX_BRIDGE_CONNECT='true'
    export HELIX_BRIDGE_DISCONNECT='true'
    # honest health probe: a REAL TCP connect of the origin over the tunnel.
    export HELIX_BRIDGE_HEALTH='python3 -c "import socket,sys; s=socket.socket(); s.settimeout(1); sys.exit(0 if s.connect_ex((\"10.10.0.2\",8080))==0 else 1)"'
    export HELIX_BRIDGE_SUBNET='10.10.0.0/24'
    export HELIX_BRIDGE_HOST='10.10.0.2'
    export HELIX_VPN_WEBDAV_URL='http://10.10.0.2:8080/dav/'
    export HELIX_SQUID_PROXY='http://127.0.0.1:3128'
    # Determinism (§11.4.50, review nit): scrub any ambient-shell exports of the
    # SIBLING legs (FTP/SFTP) so they SKIP deterministically instead of attempting a
    # (from-netns unreachable) real connection that could flip _trc into a spurious
    # FAIL (a false NEGATIVE only — never a bluff PASS). Only WebDAV stays configured.
    unset HELIX_VPN_FTP_URL HELIX_VPN_FTP_USER HELIX_VPN_FTP_PASS HELIX_VPN_FTP_ACTIVE_CMD \
          HELIX_VPN_SFTP_HOST HELIX_VPN_SFTP_USER HELIX_VPN_SFTP_PORT \
          HELIX_VPN_SFTP_DIR HELIX_VPN_SFTP_KEY 2>/dev/null || true

    TEST="$_root/tests/vpn_lan/ftp_sftp_webdav.sh"
    [ -f "$TEST" ] || fail "promoted test missing: $TEST"
    # Coupling contract (review MEDIUM, de-brittle): this harness asserts on
    # ftp_sftp_webdav.sh emitting a ^(PASS|FAIL):.*WebDAV line. Verify that token
    # still exists so a future rename yields a clear diagnostic HERE, not a silent
    # grep miss downstream.
    grep -q 'WebDAV' "$TEST" || fail "promoted test no longer references 'WebDAV' — WebDAV coupling contract broke; update this harness"
    _t_out="${HW_EV_DIR}/ftp_sftp_webdav.stdout"
    _trc=0; bash "$TEST" >"$_t_out" 2>&1 || _trc=$?
    { printf '\n--- promoted ftp_sftp_webdav.sh (exit=%s) ---\n' "$_trc"; cat "$_t_out"; } >>"$EV"

    if [ "${WEBDAV_MUT:-0}" = bad207 ]; then
        # the real test MUST fail-closed on the non-207 origin (its WebDAV branch).
        if [ "$_trc" != 0 ] && grep -Eq '^FAIL:.*WebDAV' "$_t_out"; then
            log "HW_MUT_OK: the promoted ftp_sftp_webdav.sh WebDAV leg FAILED fail-closed on the HTTP-200 origin (the 207 assertion is genuinely exercised, not a rubber-stamp)"; exit 0
        fi
        fail "golden-bad did not FAIL the real WebDAV 207 assertion (exit=$_trc) — promotion may be a rubber-stamp"
    fi

    # normal: the real test's WebDAV leg must produce a genuine 207 PASS + exit 0.
    if [ "$_trc" = 0 ] && grep -Eq '^PASS:.*WebDAV' "$_t_out"; then
        # §11.4.111 negative control (self-evidencing): the WebDAV origin binds the
        # WG-only overlay 10.10.0.2 ONLY, so the SAME PROPFIND aimed from netns A
        # DIRECTLY at the UNDERLAY origin IP 10.9.0.2:8080 (veth-reachable, nothing
        # listening — bypassing the proxy so the probe is a clean origin connect) MUST
        # fail. A success would mean the 207 PASS was NOT gated by the tunnel.
        _neg=0
        curl --silent --show-error -X PROPFIND -H 'Depth: 0' --connect-timeout 3 --max-time 6 http://10.9.0.2:8080/dav/ >/dev/null 2>&1 || _neg=$?
        [ "$_neg" != 0 ] || fail "NEG: underlay http://10.9.0.2:8080/dav/ unexpectedly answered — the WebDAV origin is NOT tunnel-gated"
        log "NEG-OK: underlay http://10.9.0.2:8080/dav/ refused/failed (rc=$_neg) — the WebDAV origin binds the overlay 10.10.0.2 ONLY; the 207 PASS required the tunnel (§11.4.111)"
        log "HW_PASS: the UNMODIFIED ftp_sftp_webdav.sh WebDAV leg produced a REAL 207 PASS over the hermetic WireGuard tunnel through a pure-stdlib forward proxy (bridge_require flipped SKIP->UP; §11.4.52 promotion)"
        exit 0
    fi
    fail "promoted test did not produce a real WebDAV 207 PASS (exit=$_trc)"
fi

# ---------------------------------------------------------------------------
# OUTER: preflight (honest SKIP §11.4.3 / §12) then re-exec under unshare -Urnm.
# ---------------------------------------------------------------------------
SCRIPT_LABEL='hermetic_webdav_run'
_sd=$(cd "$(dirname "$0")" && pwd); _root=$(cd "$_sd/../.." && pwd)
WEBDAV_MUT="${WEBDAV_MUT:-0}"
SNIFF_MUT="${SNIFF_MUT:-0}"
_skip(){ printf 'SKIP: %s [%s]\n' "$SCRIPT_LABEL" "$1"; exit 0; }
for _t in unshare nsenter ip python3 curl timeout wg; do command -v "$_t" >/dev/null 2>&1 || _skip "tool absent: $_t"; done
[ -d /sys/module/wireguard ] || _skip "host 'wireguard' kernel module not loaded"
[ -f "$_root/tests/vpn_lan/ftp_sftp_webdav.sh" ] || _skip "promoted test absent"
[ -f "$_root/tests/lib/svord_bridge.sh" ] || _skip "bridge contract library absent"
if [ -r /proc/sys/kernel/unprivileged_userns_clone ] && [ "$(cat /proc/sys/kernel/unprivileged_userns_clone)" = 0 ]; then _skip "unprivileged userns disabled"; fi
unshare -Urnm true 2>/dev/null || _skip "unshare -Urnm failed (unprivileged user+net+mount ns unavailable)"
_softu=$(ulimit -u 2>/dev/null || echo 0); _inuse=$(ps --no-headers -u "$(id -u)" 2>/dev/null | wc -l | tr -d ' ')
if [ "${_softu}" != unlimited ] && [ "${_softu:-0}" -gt 0 ] 2>/dev/null && [ "$(( _softu - _inuse ))" -lt 64 ] 2>/dev/null; then _skip "process headroom too low (§12)"; fi

TS=$(date -u +%Y%m%dT%H%M%SZ 2>/dev/null || date +%Y%m%dT%H%M%SZ)
if [ "$WEBDAV_MUT" = bad207 ] || [ "$SNIFF_MUT" = plain ]; then _mode=mut; else _mode=pass; fi
export HW_EV_DIR="$_root/qa-results/vpn_lan/hermetic_webdav/${TS}_${_mode}_$$"
_rc=0
timeout 80 env HW_EV_DIR="$HW_EV_DIR" HW_ROOT="$_root" WEBDAV_MUT="$WEBDAV_MUT" SNIFF_MUT="$SNIFF_MUT" \
    unshare -Urnm bash "$0" --inner >/dev/null 2>&1 || _rc=$?
_ev="$HW_EV_DIR/run.evidence"

if [ "$WEBDAV_MUT" = bad207 ]; then
    if [ "$_rc" = 0 ] && grep -q 'HW_MUT_OK' "$_ev" 2>/dev/null; then
        printf 'PASS: %s [§1.1 golden-bad — the real ftp_sftp_webdav.sh WebDAV assertion FAILED fail-closed on a non-207 origin; the 207 check is genuinely exercised, not a rubber-stamp; evidence: %s]\n' "$SCRIPT_LABEL" "$_ev"; exit 0
    fi
    printf 'FAIL: %s [golden-bad did not behave (rc=%s); evidence: %s]\n' "$SCRIPT_LABEL" "$_rc" "$_ev"; tail -5 "$_ev" 2>/dev/null; exit 1
fi
if [ "$_rc" = 0 ] && grep -q 'HW_PASS' "$_ev" 2>/dev/null; then
    printf 'PASS: %s [unmodified ftp_sftp_webdav.sh WebDAV leg promoted to AUTONOMOUS over the hermetic WireGuard tunnel — real 207 PASS through a pure-stdlib forward proxy, no operator/Squid/Mullvad (§11.4.52); evidence: %s]\n' "$SCRIPT_LABEL" "$_ev"; exit 0
fi
printf 'FAIL: %s [rc=%s; evidence: %s]\n' "$SCRIPT_LABEL" "$_rc" "$_ev"; tail -5 "$_ev" 2>/dev/null || true; exit 1
