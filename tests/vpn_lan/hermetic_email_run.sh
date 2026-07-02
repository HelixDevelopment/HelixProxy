#!/usr/bin/env bash
###############################################################################
# hermetic_email_run.sh — H2.email: run the operator-gated email protocol test
#   AUTONOMOUSLY over the hermetic kernel-WireGuard tunnel — no operator, no
#   podman, no Mullvad, no live VPN, ZERO host installs (§11.4.122).
#   (docs/design/vpn_lan_access/hermetic_wg_test_harness.md — H2.x family)
#
# Purpose:
#   Promote tests/vpn_lan/email_roundtrip.sh (§11.4.52). Inside one `unshare
#   -Urnm` it: (1) stands up the H0-full kernel-WireGuard tunnel between two
#   unprivileged netns (veth 10.9.0.x underlay + real WG overlay 10.10.0.x);
#   (2) runs ONE pure-python3-stdlib TLS mail peer in netns B bound to the
#   WG-only overlay 10.10.0.2 — implicit-TLS SMTP submission (465), POP3S (995),
#   IMAPS (993) sharing an in-memory mailbox (userns maps uid->root => the
#   privileged binds succeed; if a privileged bind fails at runtime it falls back
#   to high ports 14650/19950/19930 and publishes the ACTUAL bound ports — detect,
#   never guess §11.4.6); (3) points the bridge contract (tests/lib/svord_bridge.sh)
#   + HELIX_MAIL_* at that peer; (4) runs the UNMODIFIED email_roundtrip.sh INSIDE
#   netns A, where its own `bridge_require` gate flips SKIP->UP and its four legs
#   (T4.1 IMAPS LIST, T4.2 SMTP submission, T4.3 POP3S send->retrieve round-trip,
#   T4.4 open-relay refusal) produce REAL PASSes with captured evidence over the
#   encrypted tunnel. The real svord/Mullvad run stays the §11.4.3 real-topology
#   confirmation.
#
#   The mail server is pure python3 stdlib (no aiosmtpd / dovecot / postfix) so it
#   needs zero host installs (§11.4.122). It answers the EXACT client dialog
#   email_roundtrip.sh drives (openssl s_client -quiet -crlf + base64 AUTH LOGIN).
#   CRITICAL — it sends a TLS close_notify (tls.unwrap() BEFORE close()) so
#   `openssl s_client` exits 0: the UNMODIFIED test's `tcp_open` probe (nc absent
#   => openssl fallback) hinges on that exit code; a bare close() => "unexpected
#   eof while reading" => openssl exit 1 => the leg would silently SKIP instead of
#   PASS. This gotcha is unique to the email leg (FTP/WebDAV drive curl).
#
# Usage:
#   tests/vpn_lan/hermetic_email_run.sh                    # PASS / SKIP / FAIL
#   MAIL_MUT=openrelay tests/vpn_lan/hermetic_email_run.sh # §1.1 golden-bad: the
#     peer ACCEPTS the unauth external RCPT (250) => the UNMODIFIED test's T4.4
#     open-relay guard MUST fire its fail-closed branch (^FAIL:.*open_relay, exit
#     != 0), proving the §4.3 guard is genuinely exercised (§11.4.68/§11.4.107(10)).
#   MAIL_MUT=droptoken tests/vpn_lan/hermetic_email_run.sh # §1.1 golden-bad: the
#     peer stores the message WITHOUT the round-trip token => T4.3 POP3S retrieve
#     MUST fail-closed (^FAIL:.*roundtrip, exit != 0), proving the send->retrieve
#     assertion is genuinely exercised, not a rubber-stamp.
#   (internal) hermetic_email_run.sh --inner
#
# Outputs:
#   One PASS/SKIP/FAIL line. Evidence:
#   qa-results/vpn_lan/hermetic_email/<UTC-ts>_<pass|mut_*>_<pid>/run.evidence
#     + selffetch.smtp.txt / selffetch.pop3.txt / selffetch.relay.txt
#       (the harness's own round-trip / mutation cross-check, server responses only)
#     + email_roundtrip.stdout (the promoted test's captured stdout; it also
#       writes its own qa-results/vpn_lan/phase4/... evidence).
#
# Preflight / honest SKIP (§11.4.3): tools unshare/nsenter/ip/curl/python3/timeout/
#   wg/openssl/base64, host `wireguard` kernel module, unprivileged userns,
#   `unshare -Urnm`, process headroom (§12) — else SKIP, never a fake PASS.
#
# Side-effects:
#   ONE throwaway user+net+mount namespace (unshare -Urnm); the tunnel + mail peer
#   + the promoted test all live inside it and die with unshare (§11.4.14). Nothing
#   on the host network touched/visible (§11.4.174). WG keys + a throwaway
#   self-signed cert/key are mode-0600 `mktemp` in-namespace, never logged
#   (§11.4.10). The mail account password is a fresh per-run random, passed via env
#   (never argv) and NEVER logged; captured evidence holds server responses only.
#
# Dependencies: bash, unshare+nsenter, iproute2 ip (wireguard link type), wg, host
#   `wireguard` kernel module, python3 (stdlib only — ssl+socket+threading),
#   openssl, base64, curl, timeout. NO installed package/daemon (§11.4.122).
#
# Cross-references:
#   tests/vpn_lan/hermetic_ftp_run.sh    (the sibling H2.x FTP promotion)
#   tests/vpn_lan/hermetic_webdav_run.sh (the sibling H2.x WebDAV promotion)
#   tests/vpn_lan/email_roundtrip.sh     (the promoted protocol test, UNMODIFIED)
#   tests/lib/svord_bridge.sh            (bridge contract library)
#   docs/scripts/hermetic_email_run.md   (companion guide, §11.4.18)
#   constitution §11.4.3 / §11.4.6 / §11.4.10 / §11.4.52 / §11.4.68 / §11.4.69 /
#     §11.4.107 / §11.4.111 / §11.4.122 / §11.4.174 / §12
###############################################################################
set -u
export PATH="$PATH:/usr/sbin:/sbin"

if [ "${1:-}" = "--inner" ]; then
    EV="${HE_EV_DIR:?}/run.evidence"; mkdir -p "${HE_EV_DIR}"; : >"$EV"
    _root="${HE_ROOT:?}"
    log(){ printf '%s\n' "$*" | tee -a "$EV"; }
    fail(){ log "HE_FAIL: $*"; exit 1; }
    WG=$(command -v wg 2>/dev/null || echo /usr/sbin/wg)
    SRV=""

    # ---- WG tunnel (as H0-full: veth underlay + real kernel WireGuard) --------
    ip link set lo up 2>>"$EV" || fail "lo up"
    ip link add veth0 type veth peer name veth1 2>>"$EV" || fail "veth add"
    MARK=$(mktemp -u); unshare -n bash -c "touch '$MARK'; exec sleep 90" & HOLDER=$!
    KDIR=$(mktemp -d); SRVDIR=$(mktemp -d); PYDIR=$(mktemp -d)
    cleanup(){
        kill "$HOLDER" 2>/dev/null
        [ -n "${SRV:-}" ] && kill "$SRV" 2>/dev/null
        rm -rf "$KDIR" "$SRVDIR" "$PYDIR" "$MARK" 2>/dev/null; true
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

    # ---- throwaway self-signed cert (mode 0600, NEVER a real key/cert, §11.4.10) --
    CERT="$PYDIR/cert.pem"; KEY="$PYDIR/key.pem"
    openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
        -keyout "$KEY" -out "$CERT" -subj "/CN=10.10.0.2" >/dev/null 2>>"$EV" \
        || fail "self-signed cert generation failed"
    chmod 600 "$KEY" "$CERT"

    # ---- throwaway mail account (fresh per-run password, NEVER logged, §11.4.10) --
    MAIL_USER=helix
    MAIL_PASS=$(head -c 18 /dev/urandom 2>/dev/null | base64 2>/dev/null | tr -dc 'A-Za-z0-9' | cut -c1-20)
    [ -n "$MAIL_PASS" ] || MAIL_PASS="hlx${RANDOM}${RANDOM}${RANDOM}"

    # ---- pure-python3-stdlib implicit-TLS SMTP + POP3S + IMAPS mail peer -------
    # ssl.SSLContext(PROTOCOL_TLS_SERVER)+load_cert_chain wrapping each listener,
    # one shared in-memory mailbox, hand-rolled line-oriented handlers (smtpd/
    # asyncore were removed in py3.12). Binds MAIL_BIND (the WG-only overlay);
    # tries the privileged RFC-8314 ports first, falls back to high ports, and
    # PUBLISHES the ACTUAL bound ports to MAIL_PORTS_FILE (detect, don't guess).
    # MAIL_MUT=openrelay => accept the unauth external RCPT (golden-bad, T4.4).
    # MAIL_MUT=droptoken => store the message WITHOUT the token (golden-bad, T4.3).
    # shutdown() sends TLS close_notify (unwrap BEFORE close) so `openssl s_client`
    # exits 0 => the UNMODIFIED test's tcp_open probe passes (not a SKIP).
    cat >"$PYDIR/mailsrv.py" <<'MAILSRV_PY'
#!/usr/bin/env python3
import os, ssl, socket, threading, base64, sys, time

CERT = os.environ["MAIL_CERT"]; KEY = os.environ["MAIL_KEY"]
BIND = os.environ.get("MAIL_BIND", "10.10.0.2")
USER = os.environ["MAIL_USER"]; PASS = os.environ["MAIL_PASS"]
MUT  = os.environ.get("MAIL_MUT", "0")
PORTS_FILE = os.environ["MAIL_PORTS_FILE"]

SMTP_WANT = int(os.environ.get("MAIL_SMTP_PORT", "465"))
POP3_WANT = int(os.environ.get("MAIL_POP3_PORT", "995"))
IMAP_WANT = int(os.environ.get("MAIL_IMAP_PORT", "993"))
SMTP_FB   = int(os.environ.get("MAIL_SMTP_FALLBACK", "14650"))
POP3_FB   = int(os.environ.get("MAIL_POP3_FALLBACK", "19950"))
IMAP_FB   = int(os.environ.get("MAIL_IMAP_FALLBACK", "19930"))

# golden-bad(droptoken): a fixed, token-free stored message so the promoted test's
# POP3S RETR can never contain the sent round-trip token => T4.3 fails-closed.
DROPPED = (b"Subject: hermetic golden-bad (round-trip token dropped)\r\n"
           b"\r\n(this message intentionally carries NO round-trip token)\r\n")

MAILBOX = []
LOCK = threading.Lock()

def tls_ctx():
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(certfile=CERT, keyfile=KEY)
    return ctx

def bind_listen(want, fb):
    last = None
    for port in (want, fb):
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        try:
            s.bind((BIND, port)); s.listen(16)
            return s, port
        except OSError as e:
            last = e
            try: s.close()
            except Exception: pass
    raise SystemExit("bind failed on %s (%d/%d): %s" % (BIND, want, fb, last))

def shutdown(tls):
    # TLS close_notify BEFORE close so `openssl s_client` exits 0. The UNMODIFIED
    # email_roundtrip.sh tcp_open probe is `printf 'QUIT\n' | openssl s_client
    # -quiet ... && return 0` (nc absent), so the leg's reachability hinges on this
    # exit code; a bare close() => "unexpected eof while reading" => openssl exit 1
    # => the leg would SKIP network_unreachable_external instead of PASS.
    try: tls.unwrap()
    except Exception: pass
    try: tls.close()
    except Exception: pass

def readline(f):
    return f.readline()

def smtp_dialog(tls):
    f = tls.makefile("rb")
    def send(s): tls.sendall(s.encode())
    send("220 helix-hermetic-smtp ESMTP ready\r\n")
    authed = False; state = "cmd"; rcpts = []; databuf = []
    while True:
        line = readline(f)
        if not line: break
        if state == "data":
            if line in (b".\r\n", b".\n"):
                raw = DROPPED if MUT == "droptoken" else b"".join(databuf)
                with LOCK: MAILBOX.append(raw)
                databuf = []; state = "cmd"
                send("250 2.0.0 OK: queued\r\n"); continue
            if line.startswith(b".."): line = line[1:]   # RFC 5321 dot-unstuffing
            databuf.append(line); continue
        try: cmd = line.decode("latin-1").rstrip("\r\n")
        except Exception: cmd = ""
        up = cmd.upper()
        if up.startswith("EHLO") or up.startswith("HELO"):
            send("250-helix-hermetic-smtp greets you\r\n")
            send("250-AUTH LOGIN\r\n")
            send("250 OK\r\n")
        elif up.startswith("AUTH LOGIN"):
            send("334 " + base64.b64encode(b"Username:").decode() + "\r\n")
            u = readline(f).strip()
            send("334 " + base64.b64encode(b"Password:").decode() + "\r\n")
            p = readline(f).strip()
            try: du = base64.b64decode(u).decode(); dp = base64.b64decode(p).decode()
            except Exception: du = dp = None
            if du == USER and dp == PASS:
                authed = True; send("235 2.7.0 Authentication successful\r\n")
            else:
                send("535 5.7.8 Authentication credentials invalid\r\n")
        elif up.startswith("MAIL FROM"):
            # submission requires AUTH (RFC 6409); an unauth relay attempt is
            # refused UNLESS the golden-bad open-relay knob is set.
            if not authed and MUT != "openrelay":
                send("530 5.7.0 Authentication required\r\n"); continue
            rcpts = []; send("250 2.1.0 OK\r\n")
        elif up.startswith("RCPT TO"):
            if not authed and MUT != "openrelay":
                send("530 5.7.0 Authentication required\r\n"); continue
            is_external = ("@" in cmd) and ("localhost" not in cmd.lower()) and (USER not in cmd)
            if is_external and MUT != "openrelay":
                send("550 5.7.1 Relay access denied\r\n")   # not an open relay
            else:
                rcpts.append(cmd); send("250 2.1.5 OK\r\n")
        elif up.startswith("DATA"):
            if not authed or not rcpts:
                send("503 5.5.1 need AUTH + RCPT first\r\n"); continue
            send("354 End data with <CR><LF>.<CR><LF>\r\n"); state = "data"; databuf = []
        elif up.startswith("RSET"):
            rcpts = []; send("250 2.0.0 OK\r\n")
        elif up.startswith("NOOP"):
            send("250 2.0.0 OK\r\n")
        elif up.startswith("QUIT"):
            send("221 2.0.0 Bye\r\n"); break
        else:
            send("250 2.0.0 OK\r\n")

def pop3_dialog(tls):
    f = tls.makefile("rb")
    def send(s): tls.sendall(s.encode())
    send("+OK helix-hermetic-pop3 ready\r\n")
    while True:
        line = readline(f)
        if not line: break
        try: cmd = line.decode("latin-1").rstrip("\r\n")
        except Exception: cmd = ""
        up = cmd.upper()
        if up.startswith("USER"):
            send("+OK user accepted\r\n")
        elif up.startswith("PASS"):
            supplied = cmd[5:] if len(cmd) > 5 else ""
            if supplied == PASS: send("+OK logged in\r\n")
            else: send("-ERR invalid password\r\n")
        elif up.startswith("STAT"):
            with LOCK:
                n = len(MAILBOX); size = sum(len(m) for m in MAILBOX)
            send("+OK %d %d\r\n" % (n, size))
        elif up.startswith("LIST"):
            with LOCK: msgs = list(MAILBOX)
            send("+OK %d messages\r\n" % len(msgs))
            for i, m in enumerate(msgs, 1): send("%d %d\r\n" % (i, len(m)))
            send(".\r\n")
        elif up.startswith("RETR"):
            try: idx = int(cmd.split()[1])
            except Exception: idx = 0
            with LOCK: msgs = list(MAILBOX)
            if 1 <= idx <= len(msgs):
                m = msgs[idx - 1]
                send("+OK %d octets\r\n" % len(m))
                tls.sendall(m.replace(b"\r\n.", b"\r\n.."))   # byte-stuffing
                send("\r\n.\r\n")
            else:
                send("-ERR no such message\r\n")
        elif up.startswith("DELE"):
            send("+OK marked deleted\r\n")
        elif up.startswith("QUIT"):
            send("+OK bye\r\n"); break
        else:
            send("+OK\r\n")

def imap_dialog(tls):
    f = tls.makefile("rb")
    def send(s): tls.sendall(s.encode())
    send("* OK [CAPABILITY IMAP4rev1] helix-hermetic-imap ready\r\n")
    while True:
        line = readline(f)
        if not line: break
        try: cmd = line.decode("latin-1").rstrip("\r\n")
        except Exception: cmd = ""
        parts = cmd.split(" ", 2)
        tag = parts[0] if parts else "*"
        verb = parts[1].upper() if len(parts) > 1 else ""
        if verb == "LOGIN":
            send("%s OK LOGIN completed\r\n" % tag)
        elif verb == "LIST":
            send('* LIST (\\HasNoChildren) "/" "INBOX"\r\n')
            send('* LIST (\\HasNoChildren) "/" "Sent"\r\n')
            send("%s OK LIST completed\r\n" % tag)
        elif verb == "LOGOUT":
            send("* BYE logging out\r\n")
            send("%s OK LOGOUT completed\r\n" % tag); break
        elif verb == "CAPABILITY":
            send("* CAPABILITY IMAP4rev1\r\n")
            send("%s OK CAPABILITY completed\r\n" % tag)
        elif verb == "" and tag.upper() == "QUIT":
            # The UNMODIFIED test's tcp_open probe sends a BARE "QUIT" (not IMAP's
            # "tag LOGOUT"). `openssl s_client -quiet` implies -ign_eof, so it never
            # closes on stdin EOF — the SERVER must close first. If we treated bare
            # QUIT as an unknown tagged command and kept the connection open, the
            # probe would hang to `timeout` => exit != 0 => the IMAPS leg SKIPs.
            # Close cleanly so close_notify reaches openssl => it exits 0 => probe OK.
            send("* BYE\r\n"); break
        else:
            send("%s OK\r\n" % tag)

def wrap_handler(fn):
    def run(tls):
        try: fn(tls)
        except Exception: pass
        shutdown(tls)
    return run

def accept_loop(raw, handler):
    ctx = tls_ctx()
    while True:
        try: conn, _ = raw.accept()
        except OSError: continue
        try: conn.settimeout(25)
        except Exception: pass
        try:
            tls = ctx.wrap_socket(conn, server_side=True)
        except Exception:
            try: conn.close()
            except Exception: pass
            continue
        threading.Thread(target=handler, args=(tls,), daemon=True).start()

smtp_s, smtp_p = bind_listen(SMTP_WANT, SMTP_FB)
pop3_s, pop3_p = bind_listen(POP3_WANT, POP3_FB)
imap_s, imap_p = bind_listen(IMAP_WANT, IMAP_FB)
# publish the ACTUAL bound ports atomically (write temp + rename) so the harness
# reads a complete file only once every socket is bound + listening.
_tmp = PORTS_FILE + ".tmp"
with open(_tmp, "w") as fh:
    fh.write("SMTP=%d\nPOP3=%d\nIMAP=%d\n" % (smtp_p, pop3_p, imap_p))
os.rename(_tmp, PORTS_FILE)
threading.Thread(target=accept_loop, args=(smtp_s, wrap_handler(smtp_dialog)), daemon=True).start()
threading.Thread(target=accept_loop, args=(pop3_s, wrap_handler(pop3_dialog)), daemon=True).start()
threading.Thread(target=accept_loop, args=(imap_s, wrap_handler(imap_dialog)), daemon=True).start()
sys.stderr.write("servers-up smtp=%d pop3=%d imap=%d\n" % (smtp_p, pop3_p, imap_p)); sys.stderr.flush()
while True:
    time.sleep(1)
MAILSRV_PY

    PORTS_FILE="$PYDIR/ports.env"
    # self-bounded server (timeout inside the netns, direct parent of python) so an
    # outer-SIGKILL orphan self-terminates — no indefinite linger (§12; -k 2 90
    # outlives the holder 90s sleep budget). Credentials/cert paths travel via env
    # (never argv, §11.4.10).
    MAIL_CERT="$CERT" MAIL_KEY="$KEY" MAIL_BIND=10.10.0.2 \
    MAIL_USER="$MAIL_USER" MAIL_PASS="$MAIL_PASS" MAIL_MUT="${MAIL_MUT:-0}" \
    MAIL_PORTS_FILE="$PORTS_FILE" \
        nsenter -t "$HOLDER" -n timeout -k 2 90 python3 "$PYDIR/mailsrv.py" >/dev/null 2>&1 &
    SRV=$!

    # wait for the peer to publish its ACTUAL bound ports (privileged or fallback)
    for _ in $(seq 1 80); do [ -s "$PORTS_FILE" ] && break; sleep 0.1; done
    [ -s "$PORTS_FILE" ] || fail "mail peer never published its bound ports (bind/keygen failed?)"
    SUB_PORT=$(awk -F= '/^SMTP=/{print $2}' "$PORTS_FILE"); SUB_PORT=${SUB_PORT:-465}
    POP_PORT=$(awk -F= '/^POP3=/{print $2}' "$PORTS_FILE"); POP_PORT=${POP_PORT:-995}
    IMAP_PORT=$(awk -F= '/^IMAP=/{print $2}' "$PORTS_FILE"); IMAP_PORT=${IMAP_PORT:-993}

    # reachability over the tunnel (a successful connect to 10.10.0.2 proves wg0
    # traversal — the overlay is bound ONLY on wg0, §11.4.111).
    UP=0
    for _ in $(seq 1 80); do
        if python3 -c 'import socket,sys; s=socket.socket(); s.settimeout(0.4); sys.exit(0 if s.connect_ex(("10.10.0.2",'"$SUB_PORT"'))==0 else 1)' 2>/dev/null; then UP=1; break; fi
        sleep 0.25
    done
    [ "$UP" = 1 ] || fail "mail peer never reachable over the tunnel (10.10.0.2:$SUB_PORT)"
    HS=$("$WG" show wg0 latest-handshakes 2>/dev/null | awk '{print $2}' | head -1); HS=${HS:-0}
    log "tunnel up: wg handshake=$HS; mail peer @10.10.0.2 (netns B) SMTP=$SUB_PORT POP3S=$POP_PORT IMAPS=$IMAP_PORT ready"

    # ---- self-fetch / mutation cross-check helpers (openssl over the tunnel) ---
    MAIL_TIMEOUT=20
    U64=$(printf '%s' "$MAIL_USER" | base64 2>/dev/null | tr -d '\r\n')
    P64=$(printf '%s' "$MAIL_PASS" | base64 2>/dev/null | tr -d '\r\n')
    tls_channel(){ timeout "$MAIL_TIMEOUT" openssl s_client -connect "10.10.0.2:$1" -quiet -crlf 2>/dev/null; }
    final_reply_codes(){ awk '/^[0-9][0-9][0-9] /{print substr($0,1,3)}'; }
    nth_line(){ sed -n "${1}p"; }
    # smtp_submit <port> <token>: authenticated submission of a token-carrying msg.
    # Credentials reach openssl via the in-process printf's stdin — never argv, and
    # -quiet never echoes stdin => captured evidence holds server responses ONLY.
    smtp_submit(){
        { printf 'EHLO helix-hermetic.selffetch\n'
          printf 'AUTH LOGIN\n'; printf '%s\n' "$U64"; printf '%s\n' "$P64"
          printf 'MAIL FROM:<%s>\n' "$MAIL_USER"
          printf 'RCPT TO:<%s>\n' "$MAIL_USER"
          printf 'DATA\n'
          printf 'Subject: hermetic self-fetch %s\n' "$2"
          printf 'From: <%s>\n' "$MAIL_USER"
          printf 'To: <%s>\n' "$MAIL_USER"
          printf '\n'
          printf 'hermetic self-fetch probe token=%s\n' "$2"
          printf '.\n'
          printf 'QUIT\n'
        } | tls_channel "$1"
    }
    # pop_retr_latest <port>: STAT to learn the count, RETR the latest message.
    pop_retr_latest(){
        _st=$(printf 'USER %s\nPASS %s\nSTAT\nQUIT\n' "$MAIL_USER" "$MAIL_PASS" | tls_channel "$1")
        _c=$(printf '%s\n' "$_st" | awk '/^\+OK[ \t]+[0-9]+/{print $2; exit}'); _c=${_c:-0}
        [ "$_c" -gt 0 ] 2>/dev/null || { printf ''; return; }
        printf 'USER %s\nPASS %s\nRETR %s\nQUIT\n' "$MAIL_USER" "$MAIL_PASS" "$_c" | tls_channel "$1"
    }

    # §11.4.107 not-stale + anti-bluff cross-check BEFORE the promoted test:
    #   normal    -> a genuine authenticated SMTP-submit -> POP3S-RETR round-trip of
    #                THIS run's fresh nonce over the encrypted tunnel MUST succeed.
    #   droptoken -> the SAME round-trip MUST be BROKEN (nonce NOT retrieved) — proves
    #                the mutation is genuinely applied over the tunnel.
    #   openrelay -> an unauth external RCPT MUST be ACCEPTED (2xx) over the tunnel —
    #                proves the mutation is genuinely applied over the tunnel.
    # De-couples the eventual verdict from the downstream grep string and forbids a
    # stale/wrong peer.
    SELF_NONCE="hermetic-mail-$$-${RANDOM}-$(date -u +%H%M%S 2>/dev/null || echo x)"
    SELF_SMTP_EV="${HE_EV_DIR}/selffetch.smtp.txt"
    SELF_POP_EV="${HE_EV_DIR}/selffetch.pop3.txt"
    SELF_RELAY_EV="${HE_EV_DIR}/selffetch.relay.txt"
    if [ "${MAIL_MUT:-0}" = openrelay ]; then
        { printf 'EHLO helix-relay-probe.invalid\n'
          printf 'MAIL FROM:<relay-probe@helix-proxy.invalid>\n'
          printf 'RCPT TO:<open-relay-canary@%s>\n' "example.com"
          printf 'RSET\n'; printf 'QUIT\n'
        } | tls_channel "$SUB_PORT" > "$SELF_RELAY_EV" 2>>"$EV"
        _rc=$(final_reply_codes < "$SELF_RELAY_EV")
        _mailc=$(printf '%s\n' "$_rc" | nth_line 3); _rcptc=$(printf '%s\n' "$_rc" | nth_line 4)
        log "self open-relay probe (MUT=openrelay): mail_code=$_mailc rcpt_code=$_rcptc"
        case "$_rcptc" in
            2*) log "MUT: unauth external RCPT ACCEPTED ($_rcptc) over the tunnel — open-relay mutation is live; the UNMODIFIED test's T4.4 must FAIL-closed (§11.4.68)";;
            *)  fail "golden-bad(openrelay) self-probe did NOT get a 2xx external RCPT (got '$_rcptc') — mutation not applied over the tunnel";;
        esac
    elif [ "${MAIL_MUT:-0}" = droptoken ]; then
        smtp_submit "$SUB_PORT" "$SELF_NONCE" > "$SELF_SMTP_EV" 2>>"$EV"
        grep -q '^235 ' "$SELF_SMTP_EV" || fail "self-fetch SMTP AUTH LOGIN did not return 235 over the tunnel"
        pop_retr_latest "$POP_PORT" > "$SELF_POP_EV" 2>>"$EV"
        if grep -Fq "$SELF_NONCE" "$SELF_POP_EV"; then
            fail "golden-bad(droptoken) self-fetch unexpectedly round-tripped the nonce — mutation not applied over the tunnel"
        fi
        log "MUT: self-fetch nonce NOT retrieved over POP3S (droptoken mutation live) — the UNMODIFIED test's T4.3 round-trip must FAIL-closed (§11.4.68)"
    else
        smtp_submit "$SUB_PORT" "$SELF_NONCE" > "$SELF_SMTP_EV" 2>>"$EV"
        grep -q '^235 ' "$SELF_SMTP_EV" || fail "self-fetch SMTP AUTH LOGIN did not return 235 over the tunnel (auth path broken)"
        pop_retr_latest "$POP_PORT" > "$SELF_POP_EV" 2>>"$EV"
        grep -Fq "$SELF_NONCE" "$SELF_POP_EV" || fail "self-fetch: sent nonce '$SELF_NONCE' NOT retrieved over POP3S over the tunnel (round-trip broken / stale peer)"
        log "self-fetch OK: authenticated SMTP submit (235) -> POP3S RETR byte round-trip of this run's fresh nonce over the tunnel (§11.4.107 not-stale)"
    fi

    # ---- bridge contract + HELIX_MAIL_* => hermetic peer; run the REAL test ----
    export HELIX_BRIDGE_MODE=hermetic
    export HELIX_SVORD_DIR="$SRVDIR"
    export HELIX_BRIDGE_CONNECT='true'
    export HELIX_BRIDGE_DISCONNECT='true'
    # honest health probe: a REAL TCP connect of the peer over the tunnel.
    export HELIX_BRIDGE_HEALTH='python3 -c "import socket,sys; s=socket.socket(); s.settimeout(1); sys.exit(0 if s.connect_ex((\"10.10.0.2\",'"$SUB_PORT"'))==0 else 1)"'
    export HELIX_BRIDGE_SUBNET='10.10.0.0/24'
    export HELIX_BRIDGE_HOST='10.10.0.2'
    export HELIX_MAIL_HOST='10.10.0.2'
    export HELIX_MAIL_IMAPS_PORT="$IMAP_PORT"
    export HELIX_MAIL_POP3S_PORT="$POP_PORT"
    export HELIX_MAIL_SUBMISSION_PORT="$SUB_PORT"
    export HELIX_MAIL_SUBMISSION_TLS='implicit'
    export HELIX_MAIL_RELAY_PROBE_PORT="$SUB_PORT"
    export HELIX_MAIL_RELAY_PROBE_TLS='implicit'
    export HELIX_MAIL_EXTERNAL_RELAY_DOMAIN='example.com'
    export HELIX_MAIL_USER="$MAIL_USER"
    export HELIX_MAIL_PASS="$MAIL_PASS"
    # FROM/TO deliberately unset — the promoted test defaults them to USER.
    # Determinism (§11.4.50): scrub the HELIX_MAIL_* we do NOT set + test overrides
    # so a leftover ambient-shell export cannot perturb the promoted test (a
    # false-negative guard only — it can never manufacture a bluff PASS).
    unset HELIX_MAIL_FROM HELIX_MAIL_TO HELIX_MAIL_TIMEOUT HELIX_MAIL_PROBE_TIMEOUT \
          EMAIL_ROUNDTRIP_EVIDENCE_DIR SVORD_BRIDGE_LIB HELIX_REPO_ROOT 2>/dev/null || true

    TEST="$_root/tests/vpn_lan/email_roundtrip.sh"
    [ -f "$TEST" ] || fail "promoted test missing: $TEST"
    # Coupling contract (de-brittle §11.4.6): this harness greps the promoted test's
    # verdict lines for the four scored-leg description tokens. Verify each still
    # exists so a future rename fails with a clear diagnostic HERE, not as a silent
    # grep miss downstream.
    for _tok in imaps_login_list smtp_submission_send pop3s_retrieve_roundtrip open_relay_refused; do
        grep -q "$_tok" "$TEST" || fail "promoted test no longer references '$_tok' — coupling contract broke; update this harness"
    done
    _t_out="${HE_EV_DIR}/email_roundtrip.stdout"
    _trc=0; bash "$TEST" >"$_t_out" 2>&1 || _trc=$?
    { printf '\n--- promoted email_roundtrip.sh (exit=%s) ---\n' "$_trc"; cat "$_t_out"; } >>"$EV"

    if [ "${MAIL_MUT:-0}" = droptoken ]; then
        # peer stored a token-free message => T4.3 POP3S round-trip must fail-closed.
        if [ "$_trc" != 0 ] && grep -Eq '^FAIL:.*roundtrip' "$_t_out"; then
            log "HE_MUT_OK: the promoted email_roundtrip.sh POP3S send->retrieve leg FAILED fail-closed when the peer stored the message WITHOUT the token (the round-trip assertion is genuinely exercised, not a rubber-stamp; §11.4.107(10)/§11.4.68)"; exit 0
        fi
        fail "golden-bad(droptoken) did not FAIL the real POP3S round-trip assertion (exit=$_trc) — promotion may be a rubber-stamp"
    fi
    if [ "${MAIL_MUT:-0}" = openrelay ]; then
        # peer accepted the unauth external RCPT => T4.4 open-relay guard must fail-closed.
        if [ "$_trc" != 0 ] && grep -Eq '^FAIL:.*open_relay' "$_t_out"; then
            log "HE_MUT_OK: the promoted email_roundtrip.sh open-relay guard FAILED fail-closed when the peer accepted an unauth external RCPT (the §4.3 guard is genuinely exercised, not a rubber-stamp; §11.4.107(10)/§11.4.68)"; exit 0
        fi
        fail "golden-bad(openrelay) did not FAIL the real open-relay guard (exit=$_trc) — promotion may be a rubber-stamp"
    fi

    # normal: the real test must produce genuine PASSes for the round-trip AND the
    # open-relay legs, with zero FAIL and exit 0. (Requiring the specific scored-leg
    # PASSes forbids a SKIP-only run from satisfying the gate; the bridge PASS is
    # emitted to /dev/null by the test so ^PASS: lines are real scored legs only.)
    if [ "$_trc" = 0 ] \
       && grep -Eq '^PASS:.*imaps_login_list' "$_t_out" \
       && grep -Eq '^PASS:.*smtp_submission_send' "$_t_out" \
       && grep -Eq '^PASS:.*pop3s_retrieve_roundtrip' "$_t_out" \
       && grep -Eq '^PASS:.*open_relay_refused' "$_t_out" \
       && ! grep -Eq '^FAIL:' "$_t_out"; then
        log "HE_PASS: the UNMODIFIED email_roundtrip.sh ran AUTONOMOUSLY over the hermetic WireGuard tunnel against a pure-stdlib TLS mail peer — real IMAPS LIST + authenticated SMTP submission + POP3S send->retrieve round-trip + open-relay refusal, no operator/Mullvad (bridge_require flipped SKIP->UP; §11.4.52 promotion)"
        exit 0
    fi
    fail "promoted email_roundtrip.sh did not produce a clean autonomous PASS (exit=$_trc; expected ^PASS: roundtrip + open_relay + zero ^FAIL:)"
fi

# ---------------------------------------------------------------------------
# OUTER: preflight (honest SKIP §11.4.3 / §12) then re-exec under unshare -Urnm.
# ---------------------------------------------------------------------------
SCRIPT_LABEL='hermetic_email_run'
_sd=$(cd "$(dirname "$0")" && pwd); _root=$(cd "$_sd/../.." && pwd)
MAIL_MUT="${MAIL_MUT:-0}"
_skip(){ printf 'SKIP: %s [%s]\n' "$SCRIPT_LABEL" "$1"; exit 0; }
for _t in unshare nsenter ip python3 curl timeout wg openssl base64; do command -v "$_t" >/dev/null 2>&1 || _skip "tool absent: $_t"; done
[ -d /sys/module/wireguard ] || _skip "host 'wireguard' kernel module not loaded"
[ -f "$_root/tests/vpn_lan/email_roundtrip.sh" ] || _skip "promoted test absent"
[ -f "$_root/tests/lib/svord_bridge.sh" ] || _skip "bridge contract library absent"
if [ -r /proc/sys/kernel/unprivileged_userns_clone ] && [ "$(cat /proc/sys/kernel/unprivileged_userns_clone)" = 0 ]; then _skip "unprivileged userns disabled"; fi
unshare -Urnm true 2>/dev/null || _skip "unshare -Urnm failed (unprivileged user+net+mount ns unavailable)"
_softu=$(ulimit -u 2>/dev/null || echo 0); _inuse=$(ps --no-headers -u "$(id -u)" 2>/dev/null | wc -l | tr -d ' ')
if [ "${_softu}" != unlimited ] && [ "${_softu:-0}" -gt 0 ] 2>/dev/null && [ "$(( _softu - _inuse ))" -lt 64 ] 2>/dev/null; then _skip "process headroom too low (§12)"; fi
case "$MAIL_MUT" in 0|openrelay|droptoken) : ;; *) _skip "unknown MAIL_MUT='$MAIL_MUT' (expected openrelay|droptoken)";; esac

TS=$(date -u +%Y%m%dT%H%M%SZ 2>/dev/null || date +%Y%m%dT%H%M%SZ)
if [ "$MAIL_MUT" = 0 ]; then _mode=pass; else _mode="mut_${MAIL_MUT}"; fi
export HE_EV_DIR="$_root/qa-results/vpn_lan/hermetic_email/${TS}_${_mode}_$$"
_rc=0
timeout 80 env HE_EV_DIR="$HE_EV_DIR" HE_ROOT="$_root" MAIL_MUT="$MAIL_MUT" \
    unshare -Urnm bash "$0" --inner >/dev/null 2>&1 || _rc=$?
_ev="$HE_EV_DIR/run.evidence"

if [ "$MAIL_MUT" = droptoken ]; then
    if [ "$_rc" = 0 ] && grep -q 'HE_MUT_OK' "$_ev" 2>/dev/null; then
        printf 'PASS: %s [§1.1 golden-bad(droptoken) — the real email_roundtrip.sh POP3S send->retrieve assertion FAILED fail-closed when the peer stored the message WITHOUT the token; the round-trip check is genuinely exercised, not a rubber-stamp; evidence: %s]\n' "$SCRIPT_LABEL" "$_ev"; exit 0
    fi
    printf 'FAIL: %s [golden-bad(droptoken) did not behave (rc=%s); evidence: %s]\n' "$SCRIPT_LABEL" "$_rc" "$_ev"; tail -5 "$_ev" 2>/dev/null; exit 1
fi
if [ "$MAIL_MUT" = openrelay ]; then
    if [ "$_rc" = 0 ] && grep -q 'HE_MUT_OK' "$_ev" 2>/dev/null; then
        printf 'PASS: %s [§1.1 golden-bad(openrelay) — the real email_roundtrip.sh open-relay guard FAILED fail-closed when the peer accepted an unauth external RCPT; the §4.3 guard is genuinely exercised, not a rubber-stamp; evidence: %s]\n' "$SCRIPT_LABEL" "$_ev"; exit 0
    fi
    printf 'FAIL: %s [golden-bad(openrelay) did not behave (rc=%s); evidence: %s]\n' "$SCRIPT_LABEL" "$_rc" "$_ev"; tail -5 "$_ev" 2>/dev/null; exit 1
fi
if [ "$_rc" = 0 ] && grep -q 'HE_PASS' "$_ev" 2>/dev/null; then
    printf 'PASS: %s [unmodified email_roundtrip.sh promoted to AUTONOMOUS over the hermetic WireGuard tunnel — real IMAPS LIST + SMTP submission + POP3S send->retrieve round-trip + open-relay refusal against a pure-stdlib TLS mail peer, no operator/Mullvad (§11.4.52); evidence: %s]\n' "$SCRIPT_LABEL" "$_ev"; exit 0
fi
printf 'FAIL: %s [rc=%s; evidence: %s]\n' "$SCRIPT_LABEL" "$_rc" "$_ev"; tail -5 "$_ev" 2>/dev/null || true; exit 1
