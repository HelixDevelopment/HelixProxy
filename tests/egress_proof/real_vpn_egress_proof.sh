#!/usr/bin/env bash
# =============================================================================
# real_vpn_egress_proof.sh — CREDS-DROP-READY real-VPN-egress functional proof
#                            (workable item #54 — the POSITIVE egress half).
# -----------------------------------------------------------------------------
# Purpose:
#   The dynamic proxy's FAIL-CLOSED security half is ALREADY PROVEN (tunnel-down
#   -> branded 503, no leak) by the committed integration test
#   control-plane/cmd/healthd/healthd_integration_test.go
#   (TestIntegration_HealthdWritesDownAgainstRealGluetun, assertion at :174-176:
#   a REAL gluetun with a FAKE WireGuard config -> EMPTY egress -> healthd writes
#   DOWN). What that test CANNOT prove — by design — is the POSITIVE real-egress
#   path: with REAL operator-provisioned gluetun WireGuard credentials the stack
#   routes a real packet OUT through the tunnel and the egress public IP observed
#   THROUGH the proxy equals the tunnel exit AND differs from the host's own IP
#   (design §15 / research §15 — THE hardest-to-fake routing proof, the named
#   `host_ip == proxy_ip` PASS-with-no-VPN bluff this refuses).
#
#   Real WireGuard key material is OPERATOR-PROVISIONED (§11.4.21 / §11.4.52) and
#   is NEVER fabricated, invented, or committed (§11.4.10). This harness therefore
#   has two honest outcomes:
#     * creds ABSENT  -> SKIP-with-reason `operator_attended` (§11.4.52 / §11.4.3):
#                        the functional-egress proof is creds-gated, cleanly
#                        skipped, exit 0 — NOT a fake pass.
#     * creds PRESENT -> boot the sanctioned `./start --dynamic` stack, wait for
#                        tunnel UP, capture POSITIVE sink-side egress evidence
#                        (egress-via-proxy != host AND == tunnel exit) via the
#                        committed, self-tested tests/lib/evidence.sh:assert_egress_ip,
#                        write the artefacts under qa-results/issue54/, tear the
#                        stack down cleanly (./stop), PASS on captured evidence.
#
# Usage:
#   tests/egress_proof/real_vpn_egress_proof.sh          # auto-detect creds
#   PROXY_PORT=53128 tests/egress_proof/real_vpn_egress_proof.sh
#
# Inputs (all optional — the creds path is only taken when the 5 WireGuard vars
#         are present in the environment OR in the gitignored ./.env):
#   WIREGUARD_PRIVATE_KEY  WIREGUARD_PUBLIC_KEY  WIREGUARD_ADDRESSES
#   WIREGUARD_ENDPOINT_IP  WIREGUARD_ENDPOINT_PORT   (operator-provisioned; the
#     EXACT gluetun var names the `dynamic` overlay reads — docker-compose.dynamic.yml
#     :149-153 / .env.example :177-182. NEVER printed by this script, §11.4.10.)
#   EXPECTED_EXIT_IP  (optional) the tunnel's known exit public IP; if unset it is
#     derived at runtime from gluetun's own /v1/publicip/ip control endpoint.
#   PROXY_PORT        (default 53128 — HTTP_PROXY_PORT the dynamic squid binds).
#   GLUETUN_CTRL_PORT (default 8000 — gluetun control-API port inside the netns).
#   IP_ECHO_URL       (default https://icanhazip.com — the sink IP-echo service).
#   BOOT_TIMEOUT      (default 180 — seconds to wait for the tunnel to come UP).
#
# Outputs:
#   One structured verdict line on stdout (PASS:/SKIP:/FAIL: via evidence.sh) +
#   captured artefacts under qa-results/issue54/ (gitignored raw corpus, §11.4.30):
#     verdict.txt            — machine-readable run record (verdict + reason + env).
#     egress_via_proxy.ip    — egress IP seen THROUGH the proxy (creds path only).
#     host_public.ip         — host's own public IP, fetched directly (creds path).
#     expected_exit.ip       — the tunnel's expected exit IP (creds path only).
#   Exit code: 0 = PASS or honest SKIP; 1 = FAIL (real defect); 3 = data-plane
#              contended (another owner holds :PROXY_PORT / a proxy-* container —
#              §11.4.174; the stack is NOT booted, nothing is touched).
#
# Side-effects (creds path ONLY):
#   Boots + tears down the OWN dynamic stack via the sanctioned `./start --dynamic`
#   / `./stop` orchestrators (rootless podman, §11.4.161 — NEVER raw podman run).
#   Leaves the system quiescent on every exit path (trap cleanup, §11.4.14).
#   NEVER touches operator resources wg0-mullvad / lava-* / :58080 (§11.4.174) —
#   it only ever inspects :PROXY_PORT and the proxy-squid / proxy-gluetun names
#   the dynamic overlay itself creates, and refuses (exit 3) rather than disturb a
#   pre-existing owner.
#
# Anti-bluff posture:
#   §11.4.52 operator-attended (creds are operator-provided; absence => honest SKIP,
#   never a synthetic pass) · §11.4.3 SKIP-with-reason · §11.4.69 sink-side positive
#   evidence (egress IP echoed by an EXTERNAL service, not a config/metadata read) ·
#   §11.4.107(§15) egress != host is the decisive routing oracle · §11.4.98 fully
#   re-runnable, no manual step after start · §11.4.10 no secret ever printed/logged.
#
# Dependencies: POSIX sh, awk, grep, curl, ss (or netstat); podman (creds path);
#   the sanctioned ./start + ./stop orchestrators; tests/lib/evidence.sh.
# Shell: POSIX-clean — parses under `sh -n` AND `bash -n` (§11.4.67). No bash-only
#   constructs ([[ ]], <<<, arrays, process substitution, ${v^^}).
# Cross-references:
#   - Fail-closed proof (security half): control-plane/cmd/healthd/healthd_integration_test.go:134,174.
#   - Decisive assertion:                tests/lib/evidence.sh:assert_egress_ip (:213).
#   - Orchestrator:                      ./start --dynamic (start:118-124) / ./stop.
#   - Overlay + cred vars:               docker-compose.dynamic.yml:127-167 / .env.example:173-182.
#   - Companion doc:                     docs/scripts/real_vpn_egress_proof.md (§11.4.18).
#   - Operator runbook:                  docs/DYNAMIC_VPN_EGRESS_PROOF.md.
# =============================================================================
set -eu

REPO_ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
EVID_DIR="$REPO_ROOT/qa-results/issue54"
mkdir -p "$EVID_DIR"
VERDICT_FILE="$EVID_DIR/verdict.txt"

# The committed, self-tested §11.4.69 evidence helpers (ab_skip_with_reason /
# ab_pass_with_evidence / assert_egress_ip). Sourced, never re-implemented.
# shellcheck source=/dev/null
. "$REPO_ROOT/tests/lib/evidence.sh"

PROXY_PORT="${PROXY_PORT:-${HTTP_PROXY_PORT:-53128}}"
PROXY_URL="http://127.0.0.1:$PROXY_PORT"
GLUETUN_CTRL_PORT="${GLUETUN_CTRL_PORT:-${GLUETUN_CONTROL_PORT:-8000}}"
IP_ECHO_URL="${IP_ECHO_URL:-${EVIDENCE_IP_ECHO_URL:-https://icanhazip.com}}"
BOOT_TIMEOUT="${BOOT_TIMEOUT:-180}"
CURL_TIMEOUT="${EVIDENCE_CURL_TIMEOUT:-15}"

# The 5 gluetun WireGuard vars the `dynamic` overlay reads (exact names).
WG_VARS="WIREGUARD_PRIVATE_KEY WIREGUARD_PUBLIC_KEY WIREGUARD_ADDRESSES WIREGUARD_ENDPOINT_IP WIREGUARD_ENDPOINT_PORT"

BOOTED=0
RUNTIME=""

# --- structured run record (never contains secret VALUES, §11.4.10) -----------
_record() {
    # $1 = verdict word  $2 = reason/detail
    {
        echo "issue #54 — real-VPN-egress functional proof"
        echo "timestamp_utc: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo "verdict: $1"
        echo "reason: $2"
        echo "proxy_url: $PROXY_URL"
        echo "creds_present: $CREDS_PRESENT"
        echo "fail_closed_proof: control-plane/cmd/healthd/healthd_integration_test.go:134,174 (PROVEN separately)"
    } > "$VERDICT_FILE"
}

# --- clean teardown on every exit path (§11.4.14) -----------------------------
cleanup() {
    if [ "$BOOTED" = "1" ]; then
        echo "[cleanup] tearing down the dynamic stack via ./stop (leave quiescent)..."
        ( cd "$REPO_ROOT" && ./stop >/dev/null 2>&1 ) || \
            echo "[cleanup] WARN: ./stop returned non-zero — verify no orphan proxy-* containers"
    fi
}
trap cleanup EXIT INT TERM

# --- creds presence WITHOUT ever capturing/printing a secret value ------------
# Returns 0 iff <key> is set-nonempty in the environment OR present as a
# `KEY=<nonempty>` line in the gitignored ./.env. The value is inspected only via
# grep's exit status / a length test — it is NEVER echoed (§11.4.10).
_cred_present() {
    key="$1"
    eval "_v=\${$key:-}"
    if [ -n "${_v:-}" ]; then _v=""; return 0; fi
    _v=""
    if [ -f "$REPO_ROOT/.env" ] && grep -Eq "^[[:space:]]*$key=.+" "$REPO_ROOT/.env"; then
        return 0
    fi
    return 1
}

_all_creds_present() {
    for _k in $WG_VARS; do
        _cred_present "$_k" || return 1
    done
    return 0
}

# --- §11.4.174 ownership guard: refuse to boot onto a contended data plane -----
_port_in_use() {
    if command -v ss >/dev/null 2>&1; then
        ss -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]$PROXY_PORT\$"
        return $?
    fi
    if command -v netstat >/dev/null 2>&1; then
        netstat -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]$PROXY_PORT\$"
        return $?
    fi
    return 1
}

_proxy_container_running() {
    [ -n "$RUNTIME" ] || return 1
    "$RUNTIME" ps --format '{{.Names}}' 2>/dev/null \
        | grep -Eq '^(proxy-squid|proxy-gluetun)$'
}

# --- detect the container runtime (rootless podman preferred, §11.4.161) -------
_detect_runtime() {
    if command -v podman >/dev/null 2>&1; then RUNTIME="podman"; return 0; fi
    if command -v docker >/dev/null 2>&1; then RUNTIME="docker"; return 0; fi
    RUNTIME=""
    return 1
}

# =============================================================================
# MAIN
# =============================================================================
CREDS_PRESENT="no"

if ! _all_creds_present; then
    # ----------------------------------------------------------------- SKIP path
    CREDS_PRESENT="no"
    desc="issue#54 real-VPN-egress functional proof — operator creds required (§11.4.52)"
    _record "SKIP" "operator WireGuard creds (WIREGUARD_*) absent — functional-egress proof is creds-gated (§11.4.21/§11.4.52); security fail-closed half proven separately"
    # ab_skip_with_reason emits the structured SKIP line and returns 0 (honest
    # non-evidence, NOT a pass). `operator_attended` is the §11.4.69 closed-set
    # reason for a proof that requires operator-provided material.
    ab_skip_with_reason "$desc" operator_attended
    rc=$?
    echo "evidence: $VERDICT_FILE"
    echo "note: security half (tunnel-down -> DOWN, no leak) PROVEN by control-plane/cmd/healthd/healthd_integration_test.go:174"
    exit "$rc"
fi

# --------------------------------------------------------------- creds present
CREDS_PRESENT="yes"
echo "[info] operator WireGuard creds detected — attempting the real-egress PASS."

if ! _detect_runtime; then
    _record "SKIP" "no container runtime (podman/docker) on PATH"
    ab_skip_with_reason "issue#54 real-VPN-egress functional proof" hardware_not_present
    exit $?
fi

# §11.4.174 — never disturb a pre-existing owner of the data plane.
if _port_in_use; then
    _record "CONTENDED" "port $PROXY_PORT already in use by another owner — refusing to boot (§11.4.174)"
    echo "FAIL-SAFE: :$PROXY_PORT already bound — another process owns the data plane."
    echo "           NOT booting (§11.4.174). Free the port or run './stop' first."
    echo "evidence: $VERDICT_FILE"
    exit 3
fi
if _proxy_container_running; then
    _record "CONTENDED" "a proxy-squid/proxy-gluetun container is already running — refusing to boot (§11.4.174)"
    echo "FAIL-SAFE: a proxy-* container is already up. Run './stop' first (§11.4.174)."
    echo "evidence: $VERDICT_FILE"
    exit 3
fi

# Boot the sanctioned dynamic stack (rootless podman via ./start, §11.4.161).
echo "[info] booting the dynamic control-plane: ./start --dynamic ..."
( cd "$REPO_ROOT" && ./start --dynamic )
BOOTED=1

# Wait for the tunnel to come UP: gluetun reports a non-empty public IP on its
# control API once WireGuard has a real egress. Poll inside the container netns.
echo "[info] waiting up to ${BOOT_TIMEOUT}s for the tunnel to come UP..."
tunnel_ip=""
deadline=$(( $(date +%s) + BOOT_TIMEOUT ))
while [ "$(date +%s)" -lt "$deadline" ]; do
    tunnel_ip="$("$RUNTIME" exec proxy-gluetun wget -q -O - \
        "http://127.0.0.1:$GLUETUN_CTRL_PORT/v1/publicip/ip" 2>/dev/null \
        | awk -F'"' '/public_ip/ { for (i=1;i<=NF;i++) if ($i ~ /^[0-9]+\./) { print $i; exit } }')"
    if [ -n "$tunnel_ip" ]; then
        break
    fi
    sleep 5
done

if [ -z "$tunnel_ip" ]; then
    _record "FAIL" "tunnel did not report a public IP within ${BOOT_TIMEOUT}s (gluetun never reached UP)"
    echo "FAIL: tunnel never came UP — gluetun reported no public IP (check operator creds/endpoint)."
    echo "evidence: $VERDICT_FILE"
    exit 1
fi

# Expected exit IP: operator-supplied, else the tunnel's own reported public IP.
EXPECTED_EXIT="${EXPECTED_EXIT_IP:-$tunnel_ip}"
printf '%s\n' "$EXPECTED_EXIT" > "$EVID_DIR/expected_exit.ip"

# POSITIVE sink-side evidence (§11.4.69): egress IP THROUGH the proxy + host's
# own public IP fetched DIRECTLY (bypassing the proxy).
echo "[info] capturing egress-via-proxy + host public IP from the sink echo service..."
curl -s --max-time "$CURL_TIMEOUT" -x "$PROXY_URL" "$IP_ECHO_URL" 2>/dev/null \
    | tr -d '\r' | awk 'NF { print $1; exit }' > "$EVID_DIR/egress_via_proxy.ip" || true
curl -s --max-time "$CURL_TIMEOUT" "$IP_ECHO_URL" 2>/dev/null \
    | tr -d '\r' | awk 'NF { print $1; exit }' > "$EVID_DIR/host_public.ip" || true

HOST_PUBLIC="$(awk 'NF { print $1; exit }' "$EVID_DIR/host_public.ip" 2>/dev/null || true)"

# Delegate the decisive verdict to the committed, self-tested assertion (design
# §15 bluff-catcher): egress == expected exit AND egress != host.
verdict_line="$(EVIDENCE_OBSERVED_IP_FILE="$EVID_DIR/egress_via_proxy.ip" \
    assert_egress_ip "$PROXY_URL" "$EXPECTED_EXIT" "$HOST_PUBLIC")" && rc=0 || rc=$?
echo "$verdict_line"

if [ "$rc" = "0" ]; then
    _record "PASS" "egress-via-proxy == tunnel exit $EXPECTED_EXIT AND != host $HOST_PUBLIC (real VPN routing proven)"
    ab_pass_with_evidence \
        "issue#54 real-VPN-egress functional proof (egress != host, == tunnel exit)" \
        "$EVID_DIR/egress_via_proxy.ip"
    rc=$?
else
    _record "FAIL" "$verdict_line"
fi

echo "evidence-dir: $EVID_DIR"
exit "$rc"
