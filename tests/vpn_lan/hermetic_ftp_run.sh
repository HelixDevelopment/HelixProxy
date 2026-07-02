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
    cleanup(){ kill "$HOLDER" 2>/dev/null; [ -n "${SRV:-}" ] && kill "$SRV" 2>/dev/null; rm -rf "$KDIR" "$SRVDIR" "$WORK" "$MARK" 2>/dev/null; true; }
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
_skip(){ printf 'SKIP: %s [%s]\n' "$SCRIPT_LABEL" "$1"; exit 0; }
for _t in unshare nsenter ip python3 curl timeout wg; do command -v "$_t" >/dev/null 2>&1 || _skip "tool absent: $_t"; done
[ -d /sys/module/wireguard ] || _skip "host 'wireguard' kernel module not loaded"
[ -f "$_root/tests/vpn_lan/ftp_sftp_webdav.sh" ] || _skip "promoted test absent"
if [ -r /proc/sys/kernel/unprivileged_userns_clone ] && [ "$(cat /proc/sys/kernel/unprivileged_userns_clone)" = 0 ]; then _skip "unprivileged userns disabled"; fi
unshare -Urnm true 2>/dev/null || _skip "unshare -Urnm failed (unprivileged user+net+mount ns unavailable)"
_softu=$(ulimit -u 2>/dev/null || echo 0); _inuse=$(ps --no-headers -u "$(id -u)" 2>/dev/null | wc -l | tr -d ' ')
if [ "${_softu}" != unlimited ] && [ "${_softu:-0}" -gt 0 ] 2>/dev/null && [ "$(( _softu - _inuse ))" -lt 64 ] 2>/dev/null; then _skip "process headroom too low (§12)"; fi

TS=$(date -u +%Y%m%dT%H%M%SZ 2>/dev/null || date +%Y%m%dT%H%M%SZ)
if [ "$FT_MUT" = empty ]; then _mode=mut; else _mode=pass; fi
export FT_EV_DIR="$_root/qa-results/vpn_lan/hermetic_ftp/${TS}_${_mode}_$$"
_rc=0
FT_MUT="$FT_MUT" timeout 70 env FT_EV_DIR="$FT_EV_DIR" FT_ROOT="$_root" FT_MUT="$FT_MUT" \
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
