#!/usr/bin/env bash
# =============================================================================
# proxy_concurrency_test.sh — §11.4.169 CONCURRENCY / ATOMICITY suite (no cross-talk)
# -----------------------------------------------------------------------------
# Purpose:      Prove the LIVE proxy data plane is SAFE under genuinely-
#               SIMULTANEOUS callers (the §1 "always consider concurrent callers"
#               concern) with NO cross-talk — no response served to the wrong
#               client, no truncation, no corruption. It launches a HIGH number
#               of clients (default 40) released AT ONCE by a start barrier,
#               MIXING the HTTP forward proxy (localhost:53128) AND the SOCKS5
#               proxy (localhost:51080) round-robin, each fetching a DISTINCT
#               identifiable resource: a per-client unique token echoed back in
#               the response body. Cross-talk is then mechanically detectable —
#               every client MUST receive ITS OWN token and NO OTHER client's
#               token. PASS only when every simultaneous client got its own
#               correct, complete, distinct response (§11.4.69 captured
#               per-client evidence). A foreign token / truncation / corruption
#               is a hard FAIL (§11.4.68 — never fail-open). Deadlock-guarded
#               (--max-time). This is DISTINCT from tests/stress/
#               proxy_forward_stress.sh, which drives sequential load + a same-URL
#               HTTPS-CONNECT burst on ONE transport and checks only HTTP codes —
#               it does NOT test simultaneity across transports nor cross-talk.
# Usage:        bash tests/concurrency/proxy_concurrency_test.sh
#               # host-safety caps (conductor SHOULD ALSO wrap; the script
#               # additionally self-renices best-effort):
#               GOMAXPROCS=2 nice -n 19 ionice -c 3 \
#                   bash tests/concurrency/proxy_concurrency_test.sh
#               CONC_CLIENTS=40 bash tests/concurrency/proxy_concurrency_test.sh
# Inputs:       Live curl through http://localhost:53128 (forward) AND
#               socks5h://localhost:51080 (SOCKS5) — READ-ONLY client use.
#               Env: HTTP_PROXY_URL (default http://localhost:53128),
#                    HTTP_PROXY_PORT (default 53128),
#                    SOCKS_PROXY_URL (default socks5h://localhost:51080),
#                    SOCKS_PROXY_PORT (default 51080),
#                    CONC_CLIENTS (default 40; clamped 2..80 for §12.6 safety),
#                    CONC_ECHO_URL_TEMPLATE
#                       (default https://postman-echo.com/get?htok=__TOKEN__ —
#                        MUST reflect the __TOKEN__ substring back in the body;
#                        a self-hosted echo is the ideal target under heavy load),
#                    CONC_EXPECT (default "200"),
#                    CONC_ENDPOINT_LIMIT_CODES (default "429 500 502 503 504"),
#                    CURL_MAX_TIME (default 20),
#                    CONC_BARRIER_ARM_SECS (default 1 — settle time before release),
#                    CONC_EVIDENCE_DIR
#                       (default qa-results/concurrency/proxy_concurrency_<ts>).
# Outputs:      Per-client body/code/proxy/token files, a clients.tsv (idx / proxy
#               / code / class / seen-tokens), a concurrency.evidence summary, and
#               one structured PASS/FAIL/SKIP verdict.
#               Exit: 0 = PASS, 1 = FAIL (cross-talk / corruption / proxy dropped a
#               concurrent request while the echo is reachable directly), 3 = SKIP
#               (honest non-applicable: no proxy listening, OR the echo oracle is
#               unreachable directly / saturated by our own load — §11.4.3 /
#               §11.4.1, never a fake pass).
# Side-effects: Live curl only. NEVER stops/starts/restarts/reconfigures any
#               container and NEVER touches operator resources (wg0-mullvad,
#               lava-*, whoami:58080). Creates the evidence dir under qa-results/
#               (gitignored). `trap` cleanup reaps OUR worker PIDs + removes the
#               scratch dir on every exit path (§11.4.14).
# Dependencies: bash, curl, awk, sed, sort, grep, tr, date; tests/lib/evidence.sh.
# Resources:    shell + curl only; simultaneous curls bounded by CONC_CLIENTS
#               (clamped ≤ 80), each lightweight — well under the §12.6 60%
#               host-memory ceiling. Self-renices to 19 / ionice idle best-effort
#               + exports GOMAXPROCS=2; conductor SHOULD ALSO wrap.
# Cross-refs:   §11.4.169 (test-type coverage — concurrency/atomicity) / §1
#               (concurrent callers must be safe) / §11.4.69 (captured per-client
#               evidence) / §11.4.68 (no fail-open — cross-talk/drop is FAIL) /
#               §11.4.1 (no false-FAIL on a third-party echo outage) / §11.4.50
#               (deterministic) / §11.4.107; evidence.sh port_is_listening /
#               _code_in / ab_pass_with_evidence / ab_skip_with_reason. Distinct
#               from tests/stress/proxy_forward_stress.sh (sequential+same-URL burst).
# Shell:        POSIX-clean body — parses under `sh -n` AND `bash -n` (§11.4.67).
#               No bash-only constructs ([[ ]], <<<, arrays, >( ), ${v^^}).
# =============================================================================

set -u

SUITE="proxy_concurrency_test"

# --- Best-effort host-safety self-caps (conductor SHOULD ALSO wrap) ----------
export GOMAXPROCS=2
if command -v renice >/dev/null 2>&1; then renice 19 "$$" >/dev/null 2>&1 || true; fi
if command -v ionice >/dev/null 2>&1; then ionice -c 3 -p "$$" >/dev/null 2>&1 || true; fi

# --- Locate repo root (walk up to tests/lib/evidence.sh) --------------------
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
find_repo_root() {
    d=$1
    while [ "$d" != "/" ]; do
        if [ -f "$d/tests/lib/evidence.sh" ]; then
            printf '%s\n' "$d"; return 0
        fi
        d=$(dirname "$d")
    done
    return 1
}
REPO_ROOT=$(find_repo_root "$SCRIPT_DIR" || true)
if [ -z "${REPO_ROOT:-}" ]; then
    echo "FAIL: cannot locate tests/lib/evidence.sh from $SCRIPT_DIR" >&2
    exit 1
fi
# shellcheck source=/dev/null
. "$REPO_ROOT/tests/lib/evidence.sh"

# --- Config -----------------------------------------------------------------
HTTP_PROXY_URL=${HTTP_PROXY_URL:-http://localhost:53128}
HTTP_PROXY_PORT=${HTTP_PROXY_PORT:-53128}
SOCKS_PROXY_URL=${SOCKS_PROXY_URL:-socks5h://localhost:51080}
SOCKS_PROXY_PORT=${SOCKS_PROXY_PORT:-51080}
URL_TEMPLATE=${CONC_ECHO_URL_TEMPLATE:-https://postman-echo.com/get?htok=__TOKEN__}
EXPECT=${CONC_EXPECT:-200}
ENDPOINT_LIMIT_CODES=${CONC_ENDPOINT_LIMIT_CODES:-429 500 502 503 504}
MAX_TIME=${CURL_MAX_TIME:-20}
BARRIER_ARM_SECS=${CONC_BARRIER_ARM_SECS:-1}

# CONC_CLIENTS clamped to [2, 80] (§12.6 host-memory ceiling; a HIGH count that
# still leaves the host healthy). Non-numeric input falls back to the default.
CLIENTS=${CONC_CLIENTS:-40}
case "$CLIENTS" in
    *[!0-9]*|"") CLIENTS=40 ;;
esac
[ "$CLIENTS" -lt 2 ]  && CLIENTS=2
[ "$CLIENTS" -gt 80 ] && CLIENTS=80

# Barrier spin ceiling (×0.02s ≈ 30s) so a worker never blocks forever if the
# release marker never appears (deadlock guard on the barrier itself).
BARRIER_MAX_SPINS=1500

RUN_TS=$(date -u +%Y%m%dT%H%M%SZ)
# Digits-only nonce (safe to embed literally in a grep -E pattern): epoch + PID.
RUN_NONCE=$(date -u +%Y%m%d%H%M%S)$$

EVIDENCE_DIR=${CONC_EVIDENCE_DIR:-$REPO_ROOT/qa-results/concurrency/proxy_concurrency_$RUN_TS}
mkdir -p "$EVIDENCE_DIR"
SCRATCH="$EVIDENCE_DIR/scratch"
mkdir -p "$SCRATCH"
GO="$SCRATCH/GO"
BASE_BODY="$EVIDENCE_DIR/baseline_direct_body.txt"
CLIENTS_TSV="$EVIDENCE_DIR/clients.tsv"
EV="$EVIDENCE_DIR/concurrency.evidence"

# --- trap cleanup (§11.4.14): reap OUR workers + drop scratch ---------------
# Signals ONLY the specific worker PIDs this script spawned (never `kill 0`,
# which would signal the whole process group incl. the conductor). Workers are
# normally reaped by `wait`; this covers an INT/TERM mid-run. Evidence files
# under EVIDENCE_DIR are preserved; only the scratch dir is removed.
WORKER_PIDS=""
_conc_cleanup() {
    if [ -n "${WORKER_PIDS:-}" ]; then
        for _p in $WORKER_PIDS; do kill "$_p" 2>/dev/null || true; done
    fi
    rm -rf "$SCRATCH" 2>/dev/null || true
}
trap _conc_cleanup EXIT INT TERM

echo "=== $SUITE — run $RUN_TS ==="
echo "http=$HTTP_PROXY_URL  socks=$SOCKS_PROXY_URL  clients=$CLIENTS  echo=$URL_TEMPLATE"
echo "evidence=$EVIDENCE_DIR"

{
    printf '=== %s concurrency — run %s ===\n' "$SUITE" "$RUN_TS"
    printf 'http_proxy_url=%s http_port=%s\n' "$HTTP_PROXY_URL" "$HTTP_PROXY_PORT"
    printf 'socks_proxy_url=%s socks_port=%s\n' "$SOCKS_PROXY_URL" "$SOCKS_PROXY_PORT"
    printf 'echo_template=%s expected_codes=%s max_time=%ss\n' "$URL_TEMPLATE" "$EXPECT" "$MAX_TIME"
    printf 'clients=%d run_nonce=%s\n' "$CLIENTS" "$RUN_NONCE"
} > "$EV"

# --- Determine which proxies are listening + build the active proxy list -----
# Each spec is "<label>@<curl -x url>" (no spaces) so `set --` word-splits it.
PROXY_LIST=""
http_listen=no
socks_listen=no
if port_is_listening "$HTTP_PROXY_PORT"; then
    http_listen=yes
    PROXY_LIST="$PROXY_LIST http@$HTTP_PROXY_URL"
fi
if port_is_listening "$SOCKS_PROXY_PORT"; then
    socks_listen=yes
    PROXY_LIST="$PROXY_LIST socks5@$SOCKS_PROXY_URL"
fi
# shellcheck disable=SC2086
set -- $PROXY_LIST
PROXY_COUNT=$#
mixed=no
[ "$http_listen" = "yes" ] && [ "$socks_listen" = "yes" ] && mixed=yes

# --- Baseline oracle probe (DIRECT, no proxy) -------------------------------
# Sentinel token C0 (no client uses index 0). The echo endpoint MUST reflect the
# token back in the body DIRECTLY, else the cross-talk oracle cannot be
# established and the whole run is an honest outage SKIP (never a fake pass and
# never a false-FAIL of a healthy proxy on a third-party echo outage).
SENT="HPCXT_${RUN_NONCE}_C0_END"
sent_url=$(printf '%s' "$URL_TEMPLATE" | sed "s/__TOKEN__/$SENT/g")
: > "$BASE_BODY"
base_code=$(curl -sS --max-time "$MAX_TIME" -o "$BASE_BODY" -w '%{http_code}' "$sent_url" 2>/dev/null || printf '000')
baseline_ok=no
if _code_in "$base_code" "$EXPECT" && grep -qF "$SENT" "$BASE_BODY" 2>/dev/null; then
    baseline_ok=yes
fi

{
    printf '\n--- preflight ---\n'
    printf 'http_%s_listening=%s socks_%s_listening=%s active_proxies=%d mixed=%s\n' \
        "$HTTP_PROXY_PORT" "$http_listen" "$SOCKS_PROXY_PORT" "$socks_listen" "$PROXY_COUNT" "$mixed"
    printf 'baseline_direct_code=%s baseline_oracle_ok=%s (sentinel echoed back directly)\n' "$base_code" "$baseline_ok"
} >> "$EV"

# --- Pre-run SKIP gates (honest, before launching any load) -----------------
if [ "$baseline_ok" = "no" ]; then
    if [ "$PROXY_COUNT" -eq 0 ]; then
        printf 'OVERALL=SKIP:topology_unsupported\n' >> "$EV"
        echo "OVERALL=SKIP:topology_unsupported (no proxy listening AND echo oracle unreachable directly)"
        ab_skip_with_reason "$SUITE (no proxy on :$HTTP_PROXY_PORT/:$SOCKS_PROXY_PORT and echo oracle unreachable)" "topology_unsupported"
        exit 3
    fi
    printf 'OVERALL=SKIP:network_unreachable_external\n' >> "$EV"
    echo "OVERALL=SKIP:network_unreachable_external (echo oracle unreachable DIRECTLY — cannot establish cross-talk test)"
    ab_skip_with_reason "$SUITE (echo endpoint unreachable directly — cross-talk oracle unavailable; not a proxy defect)" "network_unreachable_external"
    exit 3
fi
if [ "$PROXY_COUNT" -eq 0 ]; then
    printf 'OVERALL=SKIP:topology_unsupported\n' >> "$EV"
    echo "OVERALL=SKIP:topology_unsupported (echo reachable but no proxy listening on :$HTTP_PROXY_PORT/:$SOCKS_PROXY_PORT)"
    ab_skip_with_reason "$SUITE (no proxy listening on :$HTTP_PROXY_PORT/:$SOCKS_PROXY_PORT)" "topology_unsupported"
    exit 3
fi

# --- Worker: barrier-wait, then ONE distinct fetch through its proxy ---------
# Writes each result to its OWN files (never relies on a background exit code —
# the B3 anti-bluff pattern). A hung fetch cannot exceed --max-time (deadlock
# guard) and reports 000.
launch_worker() {
    lw_idx=$1
    lw_tok=$2
    lw_plabel=$3
    lw_purl=$4
    lw_url=$(printf '%s' "$URL_TEMPLATE" | sed "s/__TOKEN__/$lw_tok/g")
    lw_spins=0
    while [ ! -f "$GO" ]; do
        lw_spins=$((lw_spins + 1))
        if [ "$lw_spins" -ge "$BARRIER_MAX_SPINS" ]; then break; fi
        sleep 0.02 2>/dev/null || sleep 1
    done
    lw_body="$SCRATCH/client.$lw_idx.body"
    lw_code=$(curl -sS --max-time "$MAX_TIME" -o "$lw_body" -w '%{http_code}' \
        -x "$lw_purl" "$lw_url" 2>/dev/null || printf '000')
    printf '%s\n' "$lw_code"   > "$SCRATCH/client.$lw_idx.code"
    printf '%s\n' "$lw_plabel" > "$SCRATCH/client.$lw_idx.proxy"
    printf '%s\n' "$lw_tok"    > "$SCRATCH/client.$lw_idx.token"
}

# --- Spawn all workers (each parked on the barrier), then release AT ONCE -----
i=1
while [ "$i" -le "$CLIENTS" ]; do
    # shellcheck disable=SC2086
    set -- $PROXY_LIST
    off=$(( (i - 1) % PROXY_COUNT ))
    shift "$off"
    spec=$1
    plabel=${spec%%@*}
    purl=${spec#*@}
    tok="HPCXT_${RUN_NONCE}_C${i}_END"
    launch_worker "$i" "$tok" "$plabel" "$purl" &
    WORKER_PIDS="$WORKER_PIDS $!"
    i=$((i + 1))
done

echo "spawned $CLIENTS workers on the barrier; releasing simultaneously..."
sleep "$BARRIER_ARM_SECS" 2>/dev/null || sleep 1   # let every worker reach the barrier
: > "$GO"                                           # release all at once
wait

# --- Collect + classify each client (main thread; no background-exit reliance) --
# Per client i: extract every "HPCXT_<nonce>_C<num>_END" token present in its
# body. Correct = the ONLY num present is i AND the HTTP code is expected.
#   foreign num present   -> CROSSTALK   (a response served to the WRONG client)
#   own token + good code  -> OK
#   endpoint-limit code    -> ENDPOINT_LIMIT (echo saturated by our load, 3rd party)
#   otherwise (000 / 2xx-but-token-missing-or-truncated / bad code) -> PROXY_DROP
ok=0
crosstalk=0
proxy_drop=0
endpoint_limit=0
http_ok=0
socks_ok=0
{
    printf 'idx\tproxy\tcode\tclass\tseen_tokens\n'
} > "$CLIENTS_TSV"

i=1
while [ "$i" -le "$CLIENTS" ]; do
    c_code=$(cat "$SCRATCH/client.$i.code" 2>/dev/null)
    c_code=${c_code:-000}
    c_proxy=$(cat "$SCRATCH/client.$i.proxy" 2>/dev/null)
    c_proxy=${c_proxy:-unknown}
    c_body="$SCRATCH/client.$i.body"

    seen=$(grep -oE "HPCXT_${RUN_NONCE}_C[0-9]+_END" "$c_body" 2>/dev/null \
        | sed -E 's/.*_C([0-9]+)_END/\1/' | sort -un | tr '\n' ' ')
    seen=$(printf '%s' "$seen" | sed 's/  */ /g; s/^ //; s/ *$//')

    has_own=no
    foreign=no
    for num in $seen; do
        if [ "$num" = "$i" ]; then
            has_own=yes
        else
            foreign=yes
        fi
    done

    if [ "$foreign" = "yes" ]; then
        cls=CROSSTALK
        crosstalk=$((crosstalk + 1))
    elif [ "$has_own" = "yes" ] && _code_in "$c_code" "$EXPECT"; then
        cls=OK
        ok=$((ok + 1))
        [ "$c_proxy" = "http" ]   && http_ok=$((http_ok + 1))
        [ "$c_proxy" = "socks5" ] && socks_ok=$((socks_ok + 1))
    elif _code_in "$c_code" "$ENDPOINT_LIMIT_CODES"; then
        cls=ENDPOINT_LIMIT
        endpoint_limit=$((endpoint_limit + 1))
    else
        cls=PROXY_DROP
        proxy_drop=$((proxy_drop + 1))
    fi

    printf '%s\t%s\t%s\t%s\t%s\n' "$i" "$c_proxy" "$c_code" "$cls" "${seen:-none}" >> "$CLIENTS_TSV"
    i=$((i + 1))
done

{
    printf '\n--- concurrent result (%d simultaneous clients) ---\n' "$CLIENTS"
    printf 'ok=%d crosstalk=%d proxy_drop=%d endpoint_limit=%d\n' \
        "$ok" "$crosstalk" "$proxy_drop" "$endpoint_limit"
    printf 'per_transport_ok: http=%d socks5=%d (mixed=%s)\n' "$http_ok" "$socks_ok" "$mixed"
    printf 'clients_tsv=%s baseline_body=%s\n' "$CLIENTS_TSV" "$BASE_BODY"
} >> "$EV"

echo
echo "ok=$ok/$CLIENTS crosstalk=$crosstalk proxy_drop=$proxy_drop endpoint_limit=$endpoint_limit (http_ok=$http_ok socks_ok=$socks_ok)"

# --- Verdict ----------------------------------------------------------------
# CROSSTALK is the decisive data-plane defect: a response reached the WRONG
# client (or a foreign token corrupted a body) -> hard FAIL, always (§11.4.68),
# regardless of endpoint health.
if [ "$crosstalk" -gt 0 ]; then
    printf 'OVERALL=FAIL:crosstalk\n' >> "$EV"
    echo "OVERALL=FAIL (cross-talk: $crosstalk client(s) received a FOREIGN client's token — response served to the wrong client / corruption)"
    _evidence_emit FAIL "$SUITE" "[reason: $crosstalk/$CLIENTS concurrent clients received a foreign token (cross-talk/corruption) — data-plane defect; see $CLIENTS_TSV]"
    exit 1
fi
if [ "$ok" -eq "$CLIENTS" ]; then
    printf 'OVERALL=PASS\n' >> "$EV"
    echo "OVERALL=PASS (all $CLIENTS simultaneous clients received their OWN correct distinct response, no cross-talk)"
    ab_pass_with_evidence "$SUITE: $CLIENTS simultaneous mixed HTTP+SOCKS5 clients each got its OWN correct distinct token, zero cross-talk (mixed=$mixed http_ok=$http_ok socks_ok=$socks_ok)" "$CLIENTS_TSV"
    exit 0
fi
# No cross-talk, not all OK. A proxy-side drop/corruption while the echo is
# reachable DIRECTLY is a real proxy defect (§11.4.68 — listening-but-dropping
# never fail-opens to SKIP).
if [ "$proxy_drop" -gt 0 ]; then
    printf 'OVERALL=FAIL:proxy_drop\n' >> "$EV"
    echo "OVERALL=FAIL (proxy dropped/garbled $proxy_drop concurrent request(s) while the echo oracle is reachable directly — real proxy defect)"
    _evidence_emit FAIL "$SUITE" "[reason: $proxy_drop/$CLIENTS concurrent proxied requests dropped/garbled (000/missing-token/bad-code) while baseline direct echo OK — proxy defect under concurrency; see $CLIENTS_TSV]"
    exit 1
fi
# Only endpoint-limit shortfalls remain: the third-party echo saturated under
# our own concurrent load. That is NOT a proxy defect -> honest outage SKIP
# (§11.4.1 no false-FAIL). Point a self-hosted echo via CONC_ECHO_URL_TEMPLATE
# to make this a clean PASS/FAIL.
printf 'OVERALL=SKIP:network_unreachable_external\n' >> "$EV"
echo "OVERALL=SKIP:network_unreachable_external (echo endpoint rate-limited/saturated under concurrent load — third-party limit, not a proxy defect; use a self-hosted echo)"
ab_skip_with_reason "$SUITE (echo endpoint saturated under concurrent load — $endpoint_limit endpoint-limit responses; not a proxy defect)" "network_unreachable_external"
exit 3
