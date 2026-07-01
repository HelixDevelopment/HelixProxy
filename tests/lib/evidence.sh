#!/usr/bin/env bash
# =============================================================================
# evidence.sh — Helix Proxy data-plane anti-bluff evidence helpers
# -----------------------------------------------------------------------------
# Purpose:      Sourceable library of DATA-PLANE evidence helpers for the
#               VPN-aware proxy extension. Every helper returns 0 (PASS) only
#               when it can cite CAPTURED data-plane evidence that the
#               user-visible behaviour really works. Control-plane / config /
#               "absence-of-error" signals are NEVER accepted as proof
#               (Constitution §11.4 / §11.4.69 / §11.4.107; design §13-§14;
#               research docs/research/mvp/findings/C_antibluff_live_evidence.md).
# Usage:        . tests/lib/evidence.sh   (source it; do not execute)
#               assert_egress_ip "$PROXY_URL" "$EXPECTED_EXIT" "$HOST_REAL_IP"
# Inputs:       Captured artefacts (wg transfer snapshots, Squid access.log,
#               503 body + PID pair, tcpdump capture / /proc/net/dev snapshots)
#               and, for the live probes, real curl through the proxy.
# Outputs:      One structured verdict line per call on stdout:
#                 PASS: <desc> [evidence: <path-or-detail>]
#                 FAIL: <desc> [reason: <why>]
#                 SKIP: <desc> [reason: <closed-set-reason>]
#               Return code: 0 = PASS / valid-SKIP, 1 = FAIL, 2 = invalid SKIP.
# Side-effects: The live probes (assert_egress_ip / assert_graceful_503) run
#               curl through the proxy in real use. UNIT-TEST SEAMS (below) let
#               the bundled self-tests feed captured fixtures with NO network —
#               those seams are for the §11.4.27 unit layer ONLY; real runs use
#               live curl.
# Dependencies: POSIX sh, awk, grep, tr, curl (live probes only).
# Cross-refs:   design §13/§14; research report C; §11.4.68 (sink-unreachable =>
#               exit-2 OPERATOR-BLOCKED, never fail-open SKIP-as-PASS).
# Shell:        POSIX-clean — parses under `sh -n` AND `bash -n` (§11.4.67).
#               No bash-only constructs ([[ ]], <<<, arrays, >( ), ${v^^}).
#
# UNIT-TEST SEAMS (documented; honour §11.4.27 — stubs only in the unit layer):
#   EVIDENCE_OBSERVED_IP_FILE   assert_egress_ip reads the observed egress IP
#                               from this file instead of live curl.
#   EVIDENCE_503_CODE_OVERRIDE  assert_graceful_503 uses this HTTP code instead
#                               of live curl.
#   EVIDENCE_503_BODY_FILE      assert_graceful_503 reads the response body from
#                               this file instead of live curl.
#   EVIDENCE_503_BODY_MARKER    branded-text marker the 503 body must contain
#                               (default: "tunnel"; matched case-insensitively).
#   EVIDENCE_LEAK_IFACE         real-uplink iface name for the /proc/net/dev
#                               no-leak delta path (default: eth0).
#   EVIDENCE_IP_ECHO_URL        IP-echo endpoint for live egress probe
#                               (default: https://icanhazip.com).
#   EVIDENCE_CURL_TIMEOUT       curl --max-time for live probes (default: 15).
# =============================================================================

# ----------------------------------------------------------------------------
# Internal helpers (prefix _evidence_) — not part of the public contract.
# ----------------------------------------------------------------------------

# Emit a structured verdict line on stdout.
_evidence_emit() {
    # $1 = verdict word (PASS/FAIL/SKIP)  $2 = desc  $3 = tail
    printf '%s: %s %s\n' "$1" "$2" "$3"
}

# Read the first whitespace-delimited token of the first non-empty line of a
# file, stripping CR. Used to extract a captured egress IP.
_evidence_first_token() {
    tr -d '\r' < "$1" 2>/dev/null | awk 'NF { print $1; exit }'
}

# Sum WireGuard rx (col) and tx across all peer lines of a `wg show <if>
# transfer` snapshot. Handles both the per-iface 3-column form
# (<peer> <rx> <tx>) and the `wg show all transfer` 4-column form
# (<iface> <peer> <rx> <tx>); whitespace FS handles tab- or space-separated.
# Prints "<rx_sum> <tx_sum>".
_evidence_wg_sums() {
    # $1 = file  $2 = iface (used to filter the 4-column "all" form)
    awk -v want="$2" '
        { n = NF }
        n == 3 { rx += $2; tx += $3; next }
        n >= 4 { if ($1 == want) { rx += $3; tx += $4 } ; next }
        END { printf "%d %d\n", rx + 0, tx + 0 }
    ' "$1" 2>/dev/null
}

# Extract the transmit-packets counter (post-colon field 10) for a given
# interface from a single /proc/net/dev snapshot on stdin. Prints an integer
# (0 if the iface is absent).
_evidence_procdev_tx_packets() {
    # $1 = iface
    awk -v ifc="$1" '
        {
            line = $0
            sub(/^[ \t]+/, "", line)
            tag = ifc ":"
            if (substr(line, 1, length(tag)) == tag) {
                sub(/^[^:]*:[ \t]*/, "", line)
                split(line, a, /[ \t]+/)
                print a[10] + 0
                found = 1
                exit
            }
        }
        END { if (!found) print 0 }
    '
}

# Public, documented single-snapshot parser: print post-colon field <idx> for
# <iface> from /proc/net/dev file <file>. Field 1 = rx bytes, 2 = rx packets,
# 9 = tx bytes, 10 = tx packets. (Unit-tested directly against the fixture.)
procdev_field() {
    # $1 = file  $2 = iface  $3 = post-colon field index
    awk -v ifc="$2" -v idx="$3" '
        {
            line = $0
            sub(/^[ \t]+/, "", line)
            tag = ifc ":"
            if (substr(line, 1, length(tag)) == tag) {
                sub(/^[^:]*:[ \t]*/, "", line)
                split(line, a, /[ \t]+/)
                print a[idx] + 0
                exit
            }
        }
    ' "$1" 2>/dev/null
}

# Fetch the egress IP seen THROUGH the proxy. Real use = live curl; unit tests
# set EVIDENCE_OBSERVED_IP_FILE to feed a captured value with no network.
_evidence_egress_ip() {
    # $1 = proxy_url
    if [ -n "${EVIDENCE_OBSERVED_IP_FILE:-}" ]; then
        _evidence_first_token "$EVIDENCE_OBSERVED_IP_FILE"
        return 0
    fi
    curl -s --max-time "${EVIDENCE_CURL_TIMEOUT:-15}" \
        -x "$1" "${EVIDENCE_IP_ECHO_URL:-https://icanhazip.com}" 2>/dev/null \
        | tr -d '\r' | awk 'NF { print $1; exit }'
}

# ----------------------------------------------------------------------------
# §11.4.69 canonical PASS / SKIP helper contracts.
# ----------------------------------------------------------------------------

# ab_pass_with_evidence <desc> <evidence_path>
# PASS only if the cited evidence artefact EXISTS and is NON-EMPTY. A PASS with
# no captured evidence is a §11.4 PASS-bluff and is refused (return 1).
ab_pass_with_evidence() {
    desc=$1
    evidence=$2
    if [ -z "$evidence" ]; then
        _evidence_emit FAIL "$desc" "[reason: no evidence path supplied]"
        return 1
    fi
    if [ ! -s "$evidence" ]; then
        _evidence_emit FAIL "$desc" "[reason: evidence missing or empty: $evidence]"
        return 1
    fi
    _evidence_emit PASS "$desc" "[evidence: $evidence]"
    return 0
}

# ab_skip_with_reason <desc> <closed-set-reason>
# Honest SKIP for a genuinely-absent precondition. The reason MUST be drawn from
# the §11.4.69 closed set; an arbitrary reason is itself a bluff (return 2).
# A valid SKIP returns 0 (neither PASS nor FAIL — honest non-evidence).
ab_skip_with_reason() {
    desc=$1
    reason=$2
    case "$reason" in
        geo_restricted|operator_attended|hardware_not_present|topology_unsupported|network_unreachable_external|feature_disabled_by_config)
            _evidence_emit SKIP "$desc" "[reason: $reason]"
            return 0
            ;;
        *)
            _evidence_emit FAIL "$desc" "[reason: invalid skip reason '$reason' — not in §11.4.69 closed set]"
            return 2
            ;;
    esac
}

# ----------------------------------------------------------------------------
# Through-proxy connectivity verdict (client-side functional checks).
# ----------------------------------------------------------------------------

# _code_in <code> <space-separated-list>
# 0 iff <code> is a WHOLE token of the list (never a substring).
_code_in() {
    _ci_code=$1
    for _ci_t in $2; do
        [ "$_ci_code" = "$_ci_t" ] && return 0
    done
    return 1
}

# proxy_conn_verdict <proxy_code> <direct_code> <expected_codes> <port_listening>
# PURE classifier (no network) for a through-proxy connectivity check. It closes
# BOTH failure modes at once:
#   - §11.4.1 false-FAIL: a third-party / local-internet outage must NOT FAIL a
#     healthy proxy — it SKIPs (network_unreachable_external).
#   - §11.4.68 fail-OPEN: a genuinely broken proxy must NOT be masked as a SKIP —
#     when the site IS reachable directly but the proxy cannot fetch it, that is a
#     real defect and FAILs.
# Decision (first match wins), printing exactly one of PASS | FAIL | SKIP:<reason>:
#   proxy_code in expected                       -> PASS
#   proxy miss, direct_code in expected          -> FAIL
#        (the SAME URL is reachable DIRECTLY, so the network + site are proven up
#         and the proxy is at fault — whether its port is misconfigured-but-listening
#         OR the process crashed / never bound the port. This out-ranks the port
#         probe so a DEAD proxy on a working host can never fail-open to SKIP §11.4.68.)
#   proxy miss, direct miss, port listening      -> SKIP:network_unreachable_external
#        (proxy is up but neither it nor a direct fetch reach the site — the site /
#         internet is down, not the proxy's fault; §11.4.3.)
#   proxy miss, direct miss, port NOT listening  -> SKIP:topology_unsupported
#        (proxy absent AND no positive network signal to substantiate a FAIL — an
#         honest topology SKIP, never a fabricated PASS and never an unprovable FAIL.)
# NOTE (§11.4.68, reviewer catch): the port-listening probe MUST NOT out-rank a
# positive direct-reachability signal. There is no config flag under which the
# proxy is legitimately absent for verify-proxy.sh / final-verify.sh, so "nothing
# listening + site reachable directly" means the proxy crashed — a real defect —
# NOT a topology absence. Hence direct-in-expected FAILs first, and the port probe
# only distinguishes the two ambiguous SKIP reasons (both already non-FAIL).
# <expected_codes> is a space-separated list of acceptable HTTP codes for BOTH the
# proxied and the direct probe of the SAME URL (e.g. "204" or "200 301 302").
proxy_conn_verdict() {
    _pcv_proxy=$1
    _pcv_direct=$2
    _pcv_expected=$3
    _pcv_listening=$4
    if _code_in "$_pcv_proxy" "$_pcv_expected"; then
        printf 'PASS\n'; return 0
    fi
    if _code_in "$_pcv_direct" "$_pcv_expected"; then
        printf 'FAIL\n'; return 0
    fi
    if [ "$_pcv_listening" = "yes" ]; then
        printf 'SKIP:network_unreachable_external\n'; return 0
    fi
    printf 'SKIP:topology_unsupported\n'; return 0
}

# port_is_listening <port>
# 0 iff something is LISTENing on <port> locally. Live host-stack check (ss, else
# netstat) — used to distinguish "proxy absent" (SKIP:topology_unsupported) from
# "proxy broken" (FAIL) for proxy_conn_verdict. NOT pure (inspects the network
# stack); the pure decision lives in proxy_conn_verdict, which IS self-tested.
port_is_listening() {
    _pil_port=$1
    if command -v ss >/dev/null 2>&1; then
        ss -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]$_pil_port\$"
        return $?
    fi
    if command -v netstat >/dev/null 2>&1; then
        netstat -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]$_pil_port\$"
        return $?
    fi
    return 1
}

# ----------------------------------------------------------------------------
# Data-plane evidence probes.
# ----------------------------------------------------------------------------

# wg_transfer_delta <iface> <before_file> <after_file>
# Parse two `wg show <if> transfer` snapshots; compute rx/tx byte deltas.
# PASS only if the tx delta > 0 (the decisive WireGuard data-plane signal —
# research §1a) AND rx delta > 0. A recent handshake with flat counters
# (Δ == 0) is control-plane-green / data-plane-dead and FAILS.
wg_transfer_delta() {
    iface=$1
    before=$2
    after=$3
    if [ ! -f "$before" ] || [ ! -f "$after" ]; then
        _evidence_emit FAIL "wg_transfer_delta($iface)" "[reason: snapshot file missing]"
        return 1
    fi
    set -- $(_evidence_wg_sums "$before" "$iface")
    rxb=${1:-0}; txb=${2:-0}
    set -- $(_evidence_wg_sums "$after" "$iface")
    rxa=${1:-0}; txa=${2:-0}
    drx=$((rxa - rxb))
    dtx=$((txa - txb))
    detail="iface=$iface Δrx=$drx Δtx=$dtx"
    if [ "$dtx" -gt 0 ] && [ "$drx" -gt 0 ]; then
        _evidence_emit PASS "wg_transfer_delta" "[evidence: $detail]"
        return 0
    fi
    _evidence_emit FAIL "wg_transfer_delta" "[reason: $detail (tx delta must be > 0)]"
    return 1
}

# _evidence_ip_shaped <value>
# Returns 0 iff <value> is a syntactically-plausible, non-sentinel public host IP
# (IPv4 with 0-255 octets, or an IPv6 hex:colon form) — used to decide whether a
# host_real_ip value is TRUSTWORTHY enough to evaluate the egress!=host half of the
# §15 proof. Rejects "", "unknown", any non-IP garbage (a captive-portal / rate-limit
# HTML body a `curl -s` 200 can return), and the unspecified/loopback sentinels
# (0.0.0.0, 127.x, ::, ::1) which are never a real public host IP. Purely portable
# POSIX sh (case + grep) — no bash regex. (finding F7 F-1 hardening §11.4.68.)
_evidence_ip_shaped() {
    _eis=$1
    case "$_eis" in
        ""|unknown|0.0.0.0|127.*|::|::1) return 1 ;;
    esac
    # IPv4: four 1-3 digit octets, each validated 0-255.
    if printf '%s' "$_eis" | grep -Eq '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$'; then
        _eis_oldifs=$IFS; IFS=.
        # shellcheck disable=SC2086
        set -- $_eis
        IFS=$_eis_oldifs
        for _eis_o in "$@"; do
            { [ "$_eis_o" -ge 0 ] && [ "$_eis_o" -le 255 ]; } 2>/dev/null || return 1
        done
        return 0
    fi
    # IPv6: at least one ':' and only hex digits + colons (shape, not full RFC 4291).
    if printf '%s' "$_eis" | grep -Eq '^[0-9A-Fa-f:]+$' && [ "${_eis#*:}" != "$_eis" ]; then
        return 0
    fi
    return 1
}

# assert_egress_ip <proxy_url> <expected_exit_ip> <host_real_ip>
# THE decisive, hardest-to-fake proof (design §15 fix). The egress IP observed
# THROUGH the proxy must equal the expected VPN exit AND differ from the host's
# real IP. A 200 OK is NOT proof of routing; egress==host is the §15 bluff
# (`host_ip == proxy_ip` PASSing with NO VPN) and FAILS here.
# If <host_real_ip> is UNKNOWN or empty (the caller's `curl ifconfig.me ||
# echo "unknown"` / `|| true` fallback fired — the external IP-echo used to learn
# the host IP was unreachable) the egress!=host HALF of the proof is UNVERIFIABLE:
# a definitively-wrong exit still FAILs, but an otherwise-"good-looking" result
# returns exit-2 OPERATOR-BLOCKED — NEVER a fail-open PASS/SKIP-as-PASS
# (§11.4.68; design §15). See tests/regression/assert_egress_ip_host_unknown_test.sh.
assert_egress_ip() {
    proxy_url=$1
    expected_exit=$2
    host_real=$3
    observed=$(_evidence_egress_ip "$proxy_url")
    if [ -z "$observed" ]; then
        _evidence_emit FAIL "assert_egress_ip" "[reason: no egress IP observed through $proxy_url]"
        return 1
    fi
    # §11.4.68 fail-open guard (finding F7 + F-1 hardening). The proof has TWO
    # independent halves: egress==expected_exit AND egress!=host_real. When the host's
    # real IP is not a TRUSTWORTHY public IP — empty, the literal "unknown", or any
    # non-IP garbage a `curl -s` 200 can return (captive-portal / rate-limit HTML), or
    # an unspecified/loopback sentinel — the second half CANNOT be evaluated: comparing
    # egress against a non-IP value trivially satisfies "different", silently collapsing
    # that half so an egress==host (NO-VPN) case could fake-PASS. We must NEVER PASS on
    # the strength of an unverifiable half. A definitively-wrong exit is still a provable
    # defect and FAILs; otherwise this is host-IP-undeterminable => exit-2
    # OPERATOR-BLOCKED (§11.4.68 cross-ref), citing the §11.4.69 closed-set reason
    # network_unreachable_external so a rerun once the host public IP is known can
    # complete the proof. NOT a return-0 SKIP (that IS the fail-open §11.4.68 forbids).
    # F-1: validate host_real is IP-SHAPED rather than deny-listing two sentinels —
    # a non-IP host_real is exactly as unverifiable as an empty one.
    if ! _evidence_ip_shaped "$host_real"; then
        if [ "$observed" != "$expected_exit" ]; then
            _evidence_emit FAIL "assert_egress_ip" "[reason: egress IP $observed != expected exit $expected_exit (host real IP unknown/not-IP-shaped — wrong exit is a provable defect)]"
            return 1
        fi
        _evidence_emit OPERATOR-BLOCKED "assert_egress_ip" "[reason: host real IP unknown/empty/not-IP-shaped ('$host_real') — cannot prove egress!=host (§15/§11.4.68); egress==expected exit $expected_exit but the !=host half is UNVERIFIABLE; §11.4.69 reason network_unreachable_external — rerun once the host public IP is determinable]"
        return 2
    fi
    if [ "$observed" = "$host_real" ]; then
        _evidence_emit FAIL "assert_egress_ip" "[reason: egress IP $observed == host real IP — traffic NOT routed via VPN (§15 bluff)]"
        return 1
    fi
    if [ "$observed" != "$expected_exit" ]; then
        _evidence_emit FAIL "assert_egress_ip" "[reason: egress IP $observed != expected exit $expected_exit]"
        return 1
    fi
    _evidence_emit PASS "assert_egress_ip" "[evidence: egress=$observed == exit $expected_exit, != host $host_real]"
    return 0
}

# assert_cache_hit <access_log> <url>
# A real cache HIT requires the Squid access.log to carry a TCP_*HIT result
# code FOR THIS URL (TCP_HIT / TCP_MEM_HIT / TCP_REFRESH_HIT / TCP_IMS_HIT). A
# config line or an X-Cache header alone is forgeable; the access.log result
# code is the data-plane corroboration (research §2). URL-specific: a MISS line
# for the same URL does NOT satisfy it.
assert_cache_hit() {
    access_log=$1
    url=$2
    if [ ! -f "$access_log" ]; then
        _evidence_emit FAIL "assert_cache_hit($url)" "[reason: access.log missing: $access_log]"
        return 1
    fi
    # Find lines whose request URL field equals <url> AND whose Squid result
    # code is a TCP_*HIT. awk guards the URL is a whole field (not a substring)
    # and the HIT token is the result-code field, not text inside the URL.
    hit_line=$(awk -v u="$url" '
        {
            code = ""; requrl = ""
            for (i = 1; i <= NF; i++) {
                if ($i ~ /^TCP_[A-Z_]*\/[0-9]+$/) code = $i
                if ($i == "GET" || $i == "HEAD" || $i == "POST" || $i == "CONNECT") requrl = $(i+1)
            }
            if (requrl == u && code ~ /^TCP_[A-Z_]*HIT\//) { print; exit }
        }' "$access_log")
    if [ -n "$hit_line" ]; then
        _evidence_emit PASS "assert_cache_hit" "[evidence: $url -> $(printf '%s' "$hit_line" | awk '{for(i=1;i<=NF;i++) if($i ~ /^TCP_/) print $i}')]"
        return 0
    fi
    _evidence_emit FAIL "assert_cache_hit" "[reason: no TCP_*HIT result code for $url in $access_log]"
    return 1
}

# assert_graceful_503 <proxy_url> <target> <pid_before> <pid_after>
# Graceful degradation = the proxy returns an intentional, branded 503 body
# AND keeps the SAME PID (it did NOT crash/restart). A blank-body 503, a 502, a
# hang, or a changed PID = FAIL (research §4; §11.4.108 runtime-signature).
# Real use fetches code+body via curl; unit tests use the EVIDENCE_503_* seams.
assert_graceful_503() {
    proxy_url=$1
    target=$2
    pid_before=$3
    pid_after=$4
    marker=${EVIDENCE_503_BODY_MARKER:-tunnel}

    # Obtain HTTP code + body (live curl, or unit-test seam).
    body_file=""
    cleanup_body=0
    if [ -n "${EVIDENCE_503_CODE_OVERRIDE:-}" ] || [ -n "${EVIDENCE_503_BODY_FILE:-}" ]; then
        code=${EVIDENCE_503_CODE_OVERRIDE:-000}
        body_file=${EVIDENCE_503_BODY_FILE:-/dev/null}
    else
        body_file=$(mktemp 2>/dev/null || printf '/tmp/evidence_503_body.%s' "$$")
        cleanup_body=1
        code=$(curl -s --max-time "${EVIDENCE_CURL_TIMEOUT:-15}" \
            -o "$body_file" -w '%{http_code}' \
            -x "$proxy_url" "$target" 2>/dev/null || printf '000')
    fi

    fail_reason=""
    if [ "$code" != "503" ]; then
        fail_reason="HTTP code $code != 503"
    elif [ ! -s "$body_file" ]; then
        fail_reason="503 body is blank (not an intentional branded body)"
    elif ! grep -qi "$marker" "$body_file" 2>/dev/null; then
        fail_reason="503 body missing branded marker '$marker'"
    elif [ -z "$pid_before" ] || [ -z "$pid_after" ]; then
        fail_reason="PID not captured (before='$pid_before' after='$pid_after')"
    elif [ "$pid_before" != "$pid_after" ]; then
        fail_reason="PID changed $pid_before -> $pid_after (proxy crashed/restarted, not graceful)"
    fi

    if [ "$cleanup_body" = "1" ]; then rm -f "$body_file" 2>/dev/null; fi

    if [ -z "$fail_reason" ]; then
        _evidence_emit PASS "assert_graceful_503" "[evidence: 503 + branded body + PID unchanged ($pid_before) for $target]"
        return 0
    fi
    _evidence_emit FAIL "assert_graceful_503" "[reason: $fail_reason]"
    return 1
}

# assert_no_leak <capture_file>
# Prove ZERO target packets escaped the REAL uplink while the tunnel was down
# (fail-closed kill switch — research §5). Accepts two artefact kinds:
#   (a) a tcpdump text capture filtered to the target on the real uplink —
#       PASS iff zero packets ("N packets captured" with N==0, or no IP lines).
#   (b) a two-snapshot /proc/net/dev delta (sections split on "=== AFTER") —
#       PASS iff the real-uplink iface (EVIDENCE_LEAK_IFACE, default eth0) tx
#       packet delta == 0 (host quiesced so the delta == target traffic).
# Testing leaks while the tunnel is UP proves nothing; this asserts fail-closed
# during the DOWN window.
assert_no_leak() {
    capture=$1
    if [ ! -f "$capture" ]; then
        _evidence_emit FAIL "assert_no_leak" "[reason: capture file missing: $capture]"
        return 1
    fi

    if grep -qi 'packets captured' "$capture" 2>/dev/null; then
        n=$(grep -i 'packets captured' "$capture" | awk '{print $1; exit}')
        n=${n:-0}
        if [ "$n" -eq 0 ] 2>/dev/null; then
            _evidence_emit PASS "assert_no_leak" "[evidence: tcpdump captured 0 target packets on real uplink ($capture)]"
            return 0
        fi
        _evidence_emit FAIL "assert_no_leak" "[reason: $n target packet(s) on real uplink — LEAK ($capture)]"
        return 1
    fi

    if grep -q '=== AFTER' "$capture" 2>/dev/null; then
        iface=${EVIDENCE_LEAK_IFACE:-eth0}
        before_tx=$(awk '/=== AFTER/ { exit } { print }' "$capture" | _evidence_procdev_tx_packets "$iface")
        after_tx=$(awk 'seen { print } /=== AFTER/ { seen = 1 }' "$capture" | _evidence_procdev_tx_packets "$iface")
        before_tx=${before_tx:-0}; after_tx=${after_tx:-0}
        delta=$((after_tx - before_tx))
        if [ "$delta" -eq 0 ]; then
            _evidence_emit PASS "assert_no_leak" "[evidence: $iface tx-packets delta == 0 during down window ($capture)]"
            return 0
        fi
        _evidence_emit FAIL "assert_no_leak" "[reason: $iface tx-packets delta $delta > 0 — LEAK on real uplink ($capture)]"
        return 1
    fi

    # Fallback: count IP packet lines in a raw text capture.
    n=$(grep -c ' IP ' "$capture" 2>/dev/null)
    n=${n:-0}
    if [ "$n" -eq 0 ] 2>/dev/null; then
        _evidence_emit PASS "assert_no_leak" "[evidence: zero IP packet lines on real uplink ($capture)]"
        return 0
    fi
    _evidence_emit FAIL "assert_no_leak" "[reason: $n IP packet line(s) — LEAK ($capture)]"
    return 1
}
