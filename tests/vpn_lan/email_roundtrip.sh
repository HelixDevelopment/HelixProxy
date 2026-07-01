#!/usr/bin/env sh
###############################################################################
# email_roundtrip.sh — VPN-LAN email round-trip + open-relay guard test
#                       (PLAN.md §5 Phase 4 · §4.3 open-relay guard · §6)
#
# Purpose:
#   Prove that mainstream email protocols exposed on the VPN-internal network
#   are reachable + usable through helix_proxy, with REAL captured content and
#   NO bluff (§11.4.69 / §11.4.107). Four checks:
#     T4.1  IMAPS  (993)  LOGIN + LIST -> assert a real mailbox listing returns.
#     T4.2  SMTP submission (465 implicit-TLS / 587 STARTTLS) authenticated send
#           -> assert the message is 250-accepted (queued).
#     T4.3  POP3S  (995)  retrieve -> assert the just-sent message (round-trip
#           token) is really retrieved.
#     T4.4  OPEN-RELAY NEGATIVE TEST (MANDATORY, §4.3): an UNAUTHENTICATED relay
#           to an EXTERNAL domain MUST be REFUSED. A captured refusal (4xx/5xx)
#           is the PASS; a captured acceptance (2xx of the external RCPT) is a
#           FAIL — helix_proxy must NEVER be an open relay / spam conduit.
#
#   The bridge-DOWN path is the one that runs autonomously NOW: bridge_require
#   is called FIRST; when the svord bridge is down/misconfigured every check
#   honestly SKIPs (§11.4.3) and the script exits 0 — NEVER a fake PASS.
#   Absence of the mail server (bridge up, server unreachable) ⇒ honest SKIP,
#   never a metadata-only / absence-of-error PASS (§11.4.69, no fail-open-skip).
#
# Usage:
#   tests/vpn_lan/email_roundtrip.sh
#   # Reads the svord bridge contract + mail config from the environment
#   # (source your gitignored .env first, e.g.
#   #   set -a; . ./.env; set +a; tests/vpn_lan/email_roundtrip.sh ).
#   # Bridge-up runs the live round-trips; bridge-down SKIPs + exits 0.
#
# Inputs (environment):
#   svord bridge contract (PLAN.md §3, via tests/lib/svord_bridge.sh):
#     HELIX_SVORD_DIR HELIX_BRIDGE_CONNECT HELIX_BRIDGE_DISCONNECT
#     HELIX_BRIDGE_HEALTH HELIX_BRIDGE_SUBNET HELIX_BRIDGE_HOST
#   mail config (decoupled §11.4.28 — all optional, honest-SKIP when unset):
#     HELIX_MAIL_HOST              mail server host (default: HELIX_BRIDGE_HOST)
#     HELIX_MAIL_IMAPS_PORT        default 993   (implicit TLS, RFC 8314)
#     HELIX_MAIL_POP3S_PORT        default 995   (implicit TLS, RFC 8314)
#     HELIX_MAIL_SUBMISSION_PORT   default 465   (implicit TLS, RFC 8314)
#     HELIX_MAIL_SUBMISSION_TLS    implicit|starttls   (default implicit)
#     HELIX_MAIL_RELAY_PROBE_PORT  default = submission port
#     HELIX_MAIL_RELAY_PROBE_TLS   implicit|starttls   (default = submission TLS)
#     HELIX_MAIL_EXTERNAL_RELAY_DOMAIN  external domain for the §4.3 negative
#                                       relay test (default example.com)
#     HELIX_MAIL_USER HELIX_MAIL_PASS   account credentials (NEVER logged/argv)
#     HELIX_MAIL_FROM HELIX_MAIL_TO     envelope from/to (default: HELIX_MAIL_USER)
#     HELIX_MAIL_TIMEOUT           per-dialog timeout secs (default 20)
#     HELIX_MAIL_PROBE_TIMEOUT     TCP-connect probe timeout secs (default 6)
#     EMAIL_ROUNDTRIP_EVIDENCE_DIR override the evidence dir (default
#                                  qa-results/vpn_lan/phase4/<UTC-ts>)
#     SVORD_BRIDGE_LIB / HELIX_REPO_ROOT  test overrides.
#
#   Implicit-TLS ports (993/995/465, RFC 8314) are PREFERRED over
#   plaintext-upgradable STARTTLS ports where the choice exists (PLAN §4.4).
#
# Outputs:
#   One structured verdict line per check on stdout (mirrored into
#   <evidence-dir>/verdicts.txt):
#     PASS: <desc> [evidence: <path>]     (PASS requires real captured content)
#     SKIP: <desc> [reason: <closed-set>] (honest §11.4.3 / §11.4.69 reason)
#     FAIL: <desc> [reason: <why>]        (a real product defect)
#   A <evidence-dir>/MANIFEST.md summarises config (NO credentials) + verdicts.
#   Exit code: 0 = bridge-down SKIP, or bridge-up with zero FAIL (PASS/SKIP);
#              1 = at least one FAIL (e.g. helix_proxy accepted an open relay).
#
# Side-effects:
#   Read-only against the bridge project + remote hosts (invocation-only,
#   §11.4.122): probes TCP reachability, runs client-side IMAPS/POP3S/SMTP
#   dialogs, and (bridge-up, creds present) sends ONE self-addressed round-trip
#   probe message to the configured account. Modifies NOTHING on svord_toolkit,
#   any remote host, or the base proxy config. Writes evidence only under the
#   evidence dir. Credentials travel via the in-process shell builtin `printf`
#   into the TLS dialog's stdin — never on an external process argv, never in
#   the captured evidence (evidence = server responses only), never logged
#   (§11.4.10). Operators wanting swaks instead may use a ~/.swaksrc config;
#   this script uses the dependency-light openssl+SMTP dialog the plan permits.
#
# Dependencies:
#   POSIX sh; tests/lib/svord_bridge.sh; openssl (TLS dialogs); base64 (SMTP
#   AUTH LOGIN); nc or openssl (TCP-connect probe); coreutils date; timeout
#   (optional, hang-guard). A genuinely-absent client tool ⇒ honest SKIP
#   (topology_unsupported), never a FAIL-bluff (§11.4.1).
#
# Cross-references:
#   docs/design/vpn_lan_access/PLAN.md §4.3 (open-relay guard) + §5 Phase 4 + §6
#   tests/lib/svord_bridge.sh          (bridge contract library sourced below)
#   tests/lib/evidence.sh              (§11.4.69 ab_pass_with_evidence pattern)
#   scripts/svord_doctor.sh            (sibling preflight doctor)
#   constitution §11.4.1 / §11.4.3 / §11.4.6 / §11.4.10 / §11.4.28 / §11.4.69 /
#               §11.4.107 / §11.4.122
#
# Shell:
#   POSIX-clean — parses under `sh -n` (§11.4.67). No bash-only constructs
#   ([[ ]], <<<, arrays, >( ), ${v^^}, `local`). `set -u`-safe throughout.
###############################################################################

set -u

# ---- resolve repo root + source the bridge contract library -----------------
_er_script=$0
_er_dir=$(cd "$(dirname "$_er_script")" 2>/dev/null && pwd)
REPO_ROOT=${HELIX_REPO_ROOT:-$(cd "$_er_dir/../.." 2>/dev/null && pwd)}
SVORD_BRIDGE_LIB=${SVORD_BRIDGE_LIB:-$REPO_ROOT/tests/lib/svord_bridge.sh}

# ---- evidence dir (created on every run, §5 Phase 4 evidence layout) ---------
TS=$(date -u +%Y%m%dT%H%M%SZ 2>/dev/null || date +%s)
EVIDENCE_DIR=${EMAIL_ROUNDTRIP_EVIDENCE_DIR:-$REPO_ROOT/qa-results/vpn_lan/phase4/$TS}
mkdir -p "$EVIDENCE_DIR" 2>/dev/null || true
VERDICTS="$EVIDENCE_DIR/verdicts.txt"
: > "$VERDICTS" 2>/dev/null || true

FAILS=0

# ---- verdict emitters (stdout + verdicts.txt) -------------------------------
emit() {
    # $1 = verdict word  $2 = desc  $3 = tail
    printf '%s: %s %s\n' "$1" "$2" "$3"
    printf '%s: %s %s\n' "$1" "$2" "$3" >> "$VERDICTS" 2>/dev/null || true
}

# pass_ev <desc> <evidence_path> — PASS only when the cited artefact EXISTS and
# is NON-EMPTY (a PASS without captured content is a §11.4 PASS-bluff — refused).
pass_ev() {
    if [ -s "$2" ]; then
        emit PASS "$1" "[evidence: $2]"
    else
        emit FAIL "$1" "[reason: evidence missing or empty: $2]"
        FAILS=$((FAILS + 1))
    fi
}

# skip_ev <desc> <closed-set-reason> — honest §11.4.3 / §11.4.69 SKIP.
skip_ev() {
    case "$2" in
        geo_restricted|operator_attended|hardware_not_present|topology_unsupported|network_unreachable_external|feature_disabled_by_config)
            emit SKIP "$1" "[reason: $2]"
            ;;
        *)
            emit FAIL "$1" "[reason: invalid skip reason '$2' — not in §11.4.69 closed set]"
            FAILS=$((FAILS + 1))
            ;;
    esac
}

# fail_ev <desc> <why> — a real product defect (never a script-bug FAIL-bluff).
fail_ev() {
    emit FAIL "$1" "[reason: $2]"
    FAILS=$((FAILS + 1))
}

# ---- misconfigured bridge library => honest SKIP + exit 0 -------------------
if [ ! -f "$SVORD_BRIDGE_LIB" ]; then
    emit SKIP "email_roundtrip(bridge)" "[reason: bridge library missing: $SVORD_BRIDGE_LIB]"
    exit 0
fi
# shellcheck disable=SC1090
. "$SVORD_BRIDGE_LIB"

# ---- bridge_require FIRST (PLAN §6): down/misconfigured => SKIP + exit 0 -----
# bridge_require prints its own SKIP token and returns 0 (up) / 2 (down) /
# 3 (misconfigured). Bridge NOT up is the path that runs autonomously now.
BR_OUT=$(bridge_require)
BR_RC=$?
if [ "$BR_RC" -ne 0 ]; then
    # BR_OUT is 'SKIP:network_unreachable_external' (rc2) or 'SKIP:misconfigured' (rc3).
    _br_reason=${BR_OUT#SKIP:}
    case "$_br_reason" in
        network_unreachable_external)
            skip_ev "email_roundtrip(bridge)" network_unreachable_external
            ;;
        *)
            # Contract unset/misconfigured — honest SKIP (surface the raw token).
            emit SKIP "email_roundtrip(bridge)" "[reason: bridge_${_br_reason:-misconfigured}]"
            ;;
    esac
    {
        printf '# VPN-LAN Phase 4 — email round-trip: bridge DOWN (honest SKIP)\n\n'
        printf 'Timestamp (UTC): %s\n' "$TS"
        printf 'Bridge verdict : %s (rc %s)\n' "$BR_OUT" "$BR_RC"
        printf '\nEvery email check SKIPped honestly (§11.4.3) — NO fake PASS. Exit 0.\n'
    } > "$EVIDENCE_DIR/MANIFEST.md" 2>/dev/null || true
    exit 0
fi
emit PASS "email_roundtrip(bridge)" "[evidence: bridge UP — proceeding to live round-trips]" >/dev/null 2>&1
# (bridge-up is a precondition, not a scored check; note it without inflating PASS count.)
printf 'INFO: svord bridge reports UP — running live email round-trips\n'

# ---- mail config (decoupled §11.4.28; defaults documented above) ------------
MAIL_HOST=${HELIX_MAIL_HOST:-$(bridge_host)}
IMAPS_PORT=${HELIX_MAIL_IMAPS_PORT:-993}
POP3S_PORT=${HELIX_MAIL_POP3S_PORT:-995}
SUBMISSION_PORT=${HELIX_MAIL_SUBMISSION_PORT:-465}
SUBMISSION_TLS=${HELIX_MAIL_SUBMISSION_TLS:-implicit}
RELAY_PROBE_PORT=${HELIX_MAIL_RELAY_PROBE_PORT:-$SUBMISSION_PORT}
RELAY_PROBE_TLS=${HELIX_MAIL_RELAY_PROBE_TLS:-$SUBMISSION_TLS}
EXTERNAL_DOMAIN=${HELIX_MAIL_EXTERNAL_RELAY_DOMAIN:-example.com}
MAIL_USER=${HELIX_MAIL_USER:-}
MAIL_PASS=${HELIX_MAIL_PASS:-}
MAIL_FROM=${HELIX_MAIL_FROM:-$MAIL_USER}
MAIL_TO=${HELIX_MAIL_TO:-$MAIL_USER}
TO=${HELIX_MAIL_TIMEOUT:-20}
PROBE_TO=${HELIX_MAIL_PROBE_TIMEOUT:-6}

# round-trip token linking the T4.2 send to the T4.3 retrieve (empty until sent).
SENT_TOKEN=''

# ---- small helpers ----------------------------------------------------------
have() { command -v "$1" >/dev/null 2>&1; }

# run a command under a hang-guard timeout when `timeout` is available.
run_to() {
    if have timeout; then
        timeout "$TO" "$@"
    else
        "$@"
    fi
}

# tcp_open <host> <port> -> 0 reachable, 1 refused/unreachable, 2 no probe tool.
tcp_open() {
    if have nc; then
        nc -z -w "$PROBE_TO" "$1" "$2" >/dev/null 2>&1 && return 0
        return 1
    fi
    if have openssl; then
        # An implicit-TLS handshake doubles as a connect probe for 993/995/465.
        printf 'QUIT\n' | run_to openssl s_client -connect "$1:$2" -quiet >/dev/null 2>&1 && return 0
        return 1
    fi
    return 2
}

# tls_channel <host> <port> [starttls-proto] < dialog-on-stdin
#   Prints the SERVER's responses on stdout. The dialog we send (which may carry
#   credentials) goes to openssl's stdin via the in-process shell builtin printf
#   — it is NEVER echoed to stdout, so captured evidence holds server responses
#   ONLY (§11.4.10). `-crlf` lets callers send bare LF (openssl adds CR).
tls_channel() {
    if [ -n "${3:-}" ]; then
        run_to openssl s_client -connect "$1:$2" -starttls "$3" -quiet -crlf 2>/dev/null
    else
        run_to openssl s_client -connect "$1:$2" -quiet -crlf 2>/dev/null
    fi
}

# smtp_starttls_flag <tlsmode> -> echoes 'smtp' for starttls, '' for implicit.
smtp_starttls_flag() {
    if [ "$1" = starttls ]; then printf 'smtp'; else printf ''; fi
}

# final_reply_codes < smtp-transcript-on-stdin
#   Collapse an SMTP/ESMTP reply stream to the ordered list of FINAL reply codes
#   (one per reply; multiline `NNN-...` continuations are ignored, only the
#   `NNN <text>` final line counts). Robust to multiline EHLO/banners.
final_reply_codes() {
    awk '/^[0-9][0-9][0-9] /{print substr($0,1,3)}'
}

# nth_line <n> < text — print the n-th line (1-indexed), or empty.
nth_line() {
    sed -n "${1}p"
}

# ===========================================================================
# T4.1 — IMAPS LOGIN + LIST (993, implicit TLS)
# ===========================================================================
test_imaps() {
    _desc="imaps_login_list(${MAIL_HOST}:${IMAPS_PORT})"
    _ev="$EVIDENCE_DIR/t4_1_imaps_list.txt"
    if [ -z "$MAIL_HOST" ]; then skip_ev "$_desc" operator_attended; return; fi
    if [ -z "$MAIL_USER" ] || [ -z "$MAIL_PASS" ]; then skip_ev "$_desc" operator_attended; return; fi
    if ! have openssl; then skip_ev "$_desc" topology_unsupported; return; fi
    tcp_open "$MAIL_HOST" "$IMAPS_PORT"; _rc=$?
    if [ "$_rc" -eq 1 ]; then skip_ev "$_desc" network_unreachable_external; return; fi
    if [ "$_rc" -eq 2 ]; then skip_ev "$_desc" topology_unsupported; return; fi

    # LOGIN + LIST every mailbox; capture the server responses only.
    printf 'a1 LOGIN "%s" "%s"\na2 LIST "" "*"\na3 LOGOUT\n' \
        "$MAIL_USER" "$MAIL_PASS" \
        | tls_channel "$MAIL_HOST" "$IMAPS_PORT" > "$_ev" 2>/dev/null

    if grep -Eq '^\* LIST ' "$_ev" 2>/dev/null; then
        # Real mailbox listing returned (untagged * LIST responses) => real content.
        pass_ev "$_desc" "$_ev"
        return
    fi
    if grep -Eq '^a1 (NO|BAD)' "$_ev" 2>/dev/null; then
        fail_ev "$_desc" "IMAP LOGIN rejected (a1 NO/BAD) — credentials/account defect"
        return
    fi
    fail_ev "$_desc" "no mailbox LIST content returned (see $_ev)"
}

# ===========================================================================
# T4.2 — SMTP submission authenticated send (465 implicit / 587 STARTTLS)
#         Sends ONE self-addressed round-trip probe carrying a unique token.
# ===========================================================================
test_smtp_send() {
    _desc="smtp_submission_send(${MAIL_HOST}:${SUBMISSION_PORT}/${SUBMISSION_TLS})"
    _ev="$EVIDENCE_DIR/t4_2_smtp_send.txt"
    if [ -z "$MAIL_HOST" ]; then skip_ev "$_desc" operator_attended; return; fi
    if [ -z "$MAIL_USER" ] || [ -z "$MAIL_PASS" ]; then skip_ev "$_desc" operator_attended; return; fi
    if [ -z "$MAIL_FROM" ] || [ -z "$MAIL_TO" ]; then skip_ev "$_desc" operator_attended; return; fi
    if ! have openssl || ! have base64; then skip_ev "$_desc" topology_unsupported; return; fi
    tcp_open "$MAIL_HOST" "$SUBMISSION_PORT"; _rc=$?
    if [ "$_rc" -eq 1 ]; then skip_ev "$_desc" network_unreachable_external; return; fi
    if [ "$_rc" -eq 2 ]; then skip_ev "$_desc" topology_unsupported; return; fi

    # Unique round-trip token (used again by T4.3 POP3S retrieve).
    _tok="helixproxy-vpnlan-p4-${TS}-$$"
    # AUTH LOGIN base64 blobs. The user/pass reach base64 via the in-process
    # shell builtin printf's stdin — never an external argv (§11.4.10).
    _u64=$(printf '%s' "$MAIL_USER" | base64 2>/dev/null | tr -d '\r\n')
    _p64=$(printf '%s' "$MAIL_PASS" | base64 2>/dev/null | tr -d '\r\n')
    if [ -z "$_u64" ] || [ -z "$_p64" ]; then skip_ev "$_desc" topology_unsupported; return; fi

    _sf=$(smtp_starttls_flag "$SUBMISSION_TLS")
    {
        printf 'EHLO helix-proxy-vpnlan.test\n'
        printf 'AUTH LOGIN\n'
        printf '%s\n' "$_u64"
        printf '%s\n' "$_p64"
        printf 'MAIL FROM:<%s>\n' "$MAIL_FROM"
        printf 'RCPT TO:<%s>\n' "$MAIL_TO"
        printf 'DATA\n'
        printf 'Subject: helix_proxy vpn-lan phase4 roundtrip %s\n' "$_tok"
        printf 'From: <%s>\n' "$MAIL_FROM"
        printf 'To: <%s>\n' "$MAIL_TO"
        printf '\n'
        printf 'helix_proxy vpn-lan email round-trip probe token=%s\n' "$_tok"
        printf '.\n'
        printf 'QUIT\n'
    } | tls_channel "$MAIL_HOST" "$SUBMISSION_PORT" "$_sf" > "$_ev" 2>/dev/null

    # Decide by the response to end-of-DATA (the message-acceptance reply): the
    # last final code is QUIT's 221; the one before it is the '.'-response.
    _codes=$(final_reply_codes < "$_ev")
    _n=$(printf '%s\n' "$_codes" | grep -c . 2>/dev/null)
    _n=${_n:-0}
    if [ "$_n" -lt 2 ]; then
        skip_ev "$_desc" network_unreachable_external
        return
    fi
    _last=$(printf '%s\n' "$_codes" | nth_line "$_n")
    if [ "$_last" = 221 ] && [ "$_n" -ge 2 ]; then
        _accept=$(printf '%s\n' "$_codes" | nth_line "$((_n - 1))")
    else
        _accept=$_last
    fi
    case "$_accept" in
        2*)
            SENT_TOKEN=$_tok
            pass_ev "$_desc" "$_ev"
            ;;
        *)
            fail_ev "$_desc" "message not 250-accepted (end-of-DATA reply code $_accept; see $_ev)"
            ;;
    esac
}

# ===========================================================================
# T4.3 — POP3S retrieve round-trip (995): retrieve the T4.2 message + verify
#         its unique token (a true send->retrieve round-trip, §11.4.69).
# ===========================================================================
test_pop3s() {
    _desc="pop3s_retrieve_roundtrip(${MAIL_HOST}:${POP3S_PORT})"
    _ev="$EVIDENCE_DIR/t4_3_pop3s_message.txt"
    if [ -z "$MAIL_HOST" ]; then skip_ev "$_desc" operator_attended; return; fi
    if [ -z "$MAIL_USER" ] || [ -z "$MAIL_PASS" ]; then skip_ev "$_desc" operator_attended; return; fi
    if ! have openssl; then skip_ev "$_desc" topology_unsupported; return; fi
    if [ -z "$SENT_TOKEN" ]; then
        # The round-trip needs the T4.2 submission leg to have succeeded.
        skip_ev "$_desc" operator_attended
        return
    fi
    tcp_open "$MAIL_HOST" "$POP3S_PORT"; _rc=$?
    if [ "$_rc" -eq 1 ]; then skip_ev "$_desc" network_unreachable_external; return; fi
    if [ "$_rc" -eq 2 ]; then skip_ev "$_desc" topology_unsupported; return; fi

    _attempt=0
    while [ "$_attempt" -lt 4 ]; do
        _attempt=$((_attempt + 1))
        # STAT to learn the message count (creds via in-process printf stdin).
        _stat=$(printf 'USER %s\nPASS %s\nSTAT\nQUIT\n' "$MAIL_USER" "$MAIL_PASS" \
            | tls_channel "$MAIL_HOST" "$POP3S_PORT" 2>/dev/null)
        _count=$(printf '%s\n' "$_stat" | awk '/^\+OK[ \t]+[0-9]+/{print $2; exit}')
        _count=${_count:-0}
        if [ "$_count" -gt 0 ] 2>/dev/null; then
            # Retrieve the latest message; its body/headers are real content.
            printf 'USER %s\nPASS %s\nRETR %s\nQUIT\n' "$MAIL_USER" "$MAIL_PASS" "$_count" \
                | tls_channel "$MAIL_HOST" "$POP3S_PORT" > "$_ev" 2>/dev/null
            if grep -Fq "$SENT_TOKEN" "$_ev" 2>/dev/null; then
                pass_ev "$_desc" "$_ev"
                return
            fi
        fi
        [ "$_attempt" -lt 4 ] && sleep 3
    done

    # Server reachable + we sent a message, but it never came back within the
    # retry window: a real round-trip defect (delivery/retrieval), NOT a SKIP.
    fail_ev "$_desc" "sent token '$SENT_TOKEN' not retrieved via POP3S after retries (see $_ev)"
}

# ===========================================================================
# T4.4 — OPEN-RELAY NEGATIVE TEST (MANDATORY, §4.3)
#   An UNAUTHENTICATED relay to an EXTERNAL domain MUST be REFUSED.
#     captured 4xx/5xx refusal of the external RCPT (or MAIL) -> PASS
#     captured 2xx acceptance of the external RCPT           -> FAIL (open relay!)
#     probe could not complete (server absent/incomplete)    -> honest SKIP
#   Absence of a mail server MUST NOT fake-PASS this guard (§11.4.69).
# ===========================================================================
test_open_relay() {
    _desc="open_relay_refused(${MAIL_HOST}:${RELAY_PROBE_PORT}->@${EXTERNAL_DOMAIN})"
    _ev="$EVIDENCE_DIR/t4_4_open_relay_probe.txt"
    if [ -z "$MAIL_HOST" ]; then skip_ev "$_desc" operator_attended; return; fi
    if ! have openssl; then skip_ev "$_desc" topology_unsupported; return; fi
    tcp_open "$MAIL_HOST" "$RELAY_PROBE_PORT"; _rc=$?
    if [ "$_rc" -eq 1 ]; then skip_ev "$_desc" network_unreachable_external; return; fi
    if [ "$_rc" -eq 2 ]; then skip_ev "$_desc" topology_unsupported; return; fi

    # Unauthenticated relay attempt to an EXTERNAL recipient. NO AUTH by design;
    # synthetic .invalid sender; RSET aborts the transaction; no DATA is sent.
    _sf=$(smtp_starttls_flag "$RELAY_PROBE_TLS")
    {
        printf 'EHLO helix-relay-probe.invalid\n'
        printf 'MAIL FROM:<relay-probe@helix-proxy.invalid>\n'
        printf 'RCPT TO:<open-relay-canary@%s>\n' "$EXTERNAL_DOMAIN"
        printf 'RSET\n'
        printf 'QUIT\n'
    } | tls_channel "$MAIL_HOST" "$RELAY_PROBE_PORT" "$_sf" > "$_ev" 2>/dev/null

    _codes=$(final_reply_codes < "$_ev")
    _n=$(printf '%s\n' "$_codes" | grep -c . 2>/dev/null)
    _n=${_n:-0}
    # Ordered final replies: 1=banner 2=EHLO 3=MAIL-FROM 4=RCPT-TO ...
    if [ "$_n" -lt 3 ]; then
        # Dialog did not even reach the MAIL-FROM reply — probe incomplete.
        skip_ev "$_desc" network_unreachable_external
        return
    fi
    _mail_code=$(printf '%s\n' "$_codes" | nth_line 3)
    _rcpt_code=$(printf '%s\n' "$_codes" | nth_line 4)

    # Server refused the sender outright (e.g. auth required at MAIL) => refused.
    case "$_mail_code" in
        5*|4*)
            pass_ev "$_desc" "$_ev"
            return
            ;;
    esac
    # MAIL accepted: the RCPT-to-external outcome is decisive.
    if [ -z "$_rcpt_code" ] || [ "$_n" -lt 4 ]; then
        # Never captured the external-RCPT reply — cannot prove refusal; SKIP
        # (an absent/incomplete probe MUST NOT fake-PASS the open-relay guard).
        skip_ev "$_desc" network_unreachable_external
        return
    fi
    case "$_rcpt_code" in
        2*)
            # External RCPT ACCEPTED without auth => helix_proxy is an OPEN RELAY.
            fail_ev "$_desc" "OPEN RELAY — unauthenticated external RCPT accepted (code $_rcpt_code; see $_ev)"
            ;;
        *)
            # 4xx/5xx refusal of the external RCPT => the guard holds. PASS.
            pass_ev "$_desc" "$_ev"
            ;;
    esac
}

# ===========================================================================
# T4.5 — REVERSE LEG: DOCUMENTED N/A (§11.4.6). Per bidirectional_exposure.md §2,
# email submission (SMTP 465/587) and retrieval (IMAPS 993 / POP3S 995) are ALL
# client->server: the client initiates every connection and the server only ever
# REPLIES on that same connection (stateful return traffic, §1.2). There is NO
# host-initiated server->client callback INTO the proxy side for this protocol
# class — so there is NO reverse leg to provision and NONE to fabricate. This is
# recorded as an HONEST N/A (§11.4.6), NOT a bogus both-way test. The forward
# (client->server) direction is asserted by T4.2 (SMTP submission 250-accept) +
# T4.1/T4.3 (IMAPS/POP3S retrieval). Server-to-server MX relay is a DIFFERENT hop
# between mail servers, outside the proxy-side ingress surface; the open-relay
# guard T4.4 already covers its abuse. Emitted as an honest SKIP (never PASS,
# never FAIL) so it does not inflate the PASS count.
# ===========================================================================
test_reverse_leg_na() {
    _desc='email_reverse_leg(client->server only — no host-initiated callback: N/A §11.4.6)'
    _ev="$EVIDENCE_DIR/t4_5_reverse_leg_na.txt"
    {
        printf 'check         : %s\n' "$_desc"
        printf 'timestamp_utc : %s\n' "$TS"
        printf 'verdict       : N/A (documented, §11.4.6) — recorded as an honest SKIP\n'
        printf 'reason        : SMTP submission + IMAPS/POP3S retrieval are client->server;\n'
        printf '                the server replies ride the SAME connection (stateful return, §1.2).\n'
        printf 'reverse_leg   : NONE — no host-initiated server->client callback into the proxy side.\n'
        printf 'forward_proof : asserted by T4.2 (submission 250-accept) + T4.1/T4.3 (retrieval).\n'
        printf 'note          : server-to-server MX relay is a different hop; abuse covered by T4.4.\n'
    } > "$_ev" 2>/dev/null
    skip_ev "$_desc" topology_unsupported
}

# ---- run the four checks + the documented reverse-leg N/A --------------------
test_imaps
test_smtp_send
test_pop3s
test_open_relay
test_reverse_leg_na

# ---- manifest (config only — NEVER credentials, §11.4.10) -------------------
{
    printf '# VPN-LAN Phase 4 — email round-trip + open-relay guard: evidence\n\n'
    printf 'Feature      : VPN-LAN email (PLAN.md §5 Phase 4 · §4.3 open-relay guard)\n'
    printf 'Timestamp UTC: %s\n' "$TS"
    printf 'Bridge       : UP\n'
    printf 'Mail host    : %s\n' "$MAIL_HOST"
    printf 'IMAPS port   : %s (implicit TLS, RFC 8314)\n' "$IMAPS_PORT"
    printf 'POP3S port   : %s (implicit TLS, RFC 8314)\n' "$POP3S_PORT"
    printf 'Submission   : %s / %s\n' "$SUBMISSION_PORT" "$SUBMISSION_TLS"
    printf 'Relay probe  : %s / %s -> @%s\n' "$RELAY_PROBE_PORT" "$RELAY_PROBE_TLS" "$EXTERNAL_DOMAIN"
    if [ -n "$MAIL_USER" ]; then printf 'Credentials  : provided (values NOT logged, §11.4.10)\n'; else printf 'Credentials  : absent (auth checks SKIP operator_attended)\n'; fi
    printf '\n## Verdicts\n\n'
    if [ -s "$VERDICTS" ]; then cat "$VERDICTS"; else printf '(none)\n'; fi
    printf '\nOpen-relay guard (§4.3): a captured 4xx/5xx refusal of the unauthenticated\n'
    printf 'external RCPT is the PASS; a 2xx acceptance is a FAIL; an incomplete probe\n'
    printf 'SKIPs — absence of a mail server never fake-PASSes the guard (§11.4.69).\n'
} > "$EVIDENCE_DIR/MANIFEST.md" 2>/dev/null || true

# ---- exit code: FAIL is decisive (e.g. an accepted open relay) --------------
if [ "$FAILS" -gt 0 ]; then
    printf 'RESULT: %s FAIL(s) — see %s\n' "$FAILS" "$EVIDENCE_DIR"
    exit 1
fi
printf 'RESULT: no FAIL (PASS/SKIP only) — evidence: %s\n' "$EVIDENCE_DIR"
exit 0
