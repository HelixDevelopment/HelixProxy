#!/usr/bin/env bash
# =============================================================================
# le_phase3_issuance_challenge.sh — Let's Encrypt hermetic DNS-01 issuance Challenge
# -----------------------------------------------------------------------------
# Purpose:      Prove — with captured physical evidence — that the custom Caddy
#               image obtains a REAL TLS certificate via the ACME DNS-01
#               challenge against a LOCAL Pebble ACME server, fully offline, and
#               that the project's cert-analyzer verifies it. It does so by
#               invoking the conductor-authored re-runnable proof
#               deploy/letsencrypt/phase3_hermetic_issue.sh (exit 0 = a real
#               cert issued + all analyzer verdicts PASS; 1 = product defect;
#               2 = OPERATOR-BLOCKED / precondition unmet). On a phase3 PASS the
#               Challenge independently RE-READS the analyzer's OWN captured
#               verdict file (cert_analyzer_verdicts.txt) and asserts it carries
#               `cert_chain_roots_in: PASS` AND `cert_san_matches: PASS` — the
#               anti-bluff cross-check (§11.4.116: a PASS must be corroborated by
#               its captured evidence, never taken on the runner's word). Every
#               PASS cites that captured verdict file via ab_pass_with_evidence
#               (§11.4.69/§11.4.2/§11.4.5/§11.4.107).
# Usage:        bash challenges/scripts/le_phase3_issuance_challenge.sh
#               CHALLENGE_EVIDENCE_DIR=<dir> bash .../le_phase3_issuance_challenge.sh
#               (The CONDUCTOR runs this — it boots the hermetic Pebble+Caddy
#                stack via phase3, and only the conductor may boot containers,
#                §11.4.119 single-resource-owner. This script AUTHORS the proof;
#                it does not itself claim ownership of the container resource.)
# Inputs:       Preconditions checked before any boot (§11.4.6 verify-not-assume):
#                 - the built image localhost/helix_proxy/caddy-challtestsrv:2.8.4
#                   exists (podman image exists);
#                 - podman-compose is on PATH.
#               Env: CADDY_IMAGE (default localhost/helix_proxy/caddy-challtestsrv:2.8.4),
#                    CHALLENGE_EVIDENCE_DIR (default qa-results/challenges/<ts>),
#                    plus everything phase3 honours (KEEP_UP, CADDY_HTTPS_PORT,
#                    CADDY_HTTP_PORT, TEST_HOSTNAME) passed straight through.
# Outputs:      A per-run Challenge evidence dir <evdir>/le_phase3/ containing
#               phase3_stdout.log (captured phase3 output) + a verdict line, and
#               a PASS that cites phase3's own cert_analyzer_verdicts.txt.
#               Exit: 0 = PASS (real cert issued + analyzer verdicts corroborated),
#               1 = FAIL (real product defect — phase3 FAILed, or claimed PASS but
#               the captured verdicts do not corroborate), 3 = SKIP (honest
#               non-applicable: image not built / podman-compose absent /
#               phase3 OPERATOR-BLOCKED — §11.4.3, NEVER a fake pass).
# Side-effects: Invokes deploy/letsencrypt/phase3_hermetic_issue.sh, which boots
#               the rootless hermetic Pebble+challtestsrv+CoreDNS+Caddy stack on
#               HIGH loopback ports and tears it down on exit (unless KEEP_UP=1).
#               This Challenge never itself touches a container — it delegates
#               the boot to phase3. Creates the evidence dir + log under
#               qa-results/. Never touches the base proxy stack or any operator
#               resource.
# Dependencies: bash; tests/lib/evidence.sh (sourced — ab_pass_with_evidence /
#               ab_skip_with_reason); deploy/letsencrypt/phase3_hermetic_issue.sh;
#               podman + podman-compose + the built Caddy image (checked as
#               preconditions); nice/ionice (optional host-safety caps).
# Cross-refs:   Constitution §11.4.27 (Challenges), §11.4.69 (sink-side positive
#               evidence), §11.4.116 (verdict corroborated by its evidence),
#               §11.4.107 (real captured evidence), §11.4.3 (honest SKIP), §11.4.1
#               (script-crash / unexpected rc = FAIL), §11.4.119 (conductor owns
#               the container resource), §12.6/§12.9 (host resource caps);
#               deploy/letsencrypt/phase3_hermetic_issue.sh;
#               tests/letsencrypt/cert_analyzer.sh; docs/scripts/le_phase3_issuance_challenge.md.
# Shell:        POSIX-clean body — parses under `sh -n` AND `bash -n` (§11.4.67).
#               No bash-only constructs ([[ ]], <<<, arrays, ${v^^}, >( )).
# =============================================================================

set -u

CHALLENGE_NAME="le_phase3_issuance"

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
CADDY_IMAGE=${CADDY_IMAGE:-localhost/helix_proxy/caddy-challtestsrv:2.8.4}
PHASE3="$REPO_ROOT/deploy/letsencrypt/phase3_hermetic_issue.sh"
RUN_TS=$(date -u +%Y%m%dT%H%M%SZ)
EVIDENCE_DIR=${CHALLENGE_EVIDENCE_DIR:-$REPO_ROOT/qa-results/challenges/$RUN_TS}
OUT_DIR="$EVIDENCE_DIR/le_phase3"
mkdir -p "$OUT_DIR"
PHASE3_LOG="$OUT_DIR/phase3_stdout.log"
: > "$PHASE3_LOG"

# --- Host-safety resource caps (degrade gracefully if a tool is absent) -----
# GOMAXPROCS bounds any Go tooling phase3 / the analyzer might spawn (§12.6).
GOMAXPROCS=2
export GOMAXPROCS
CAPS=""
if command -v nice   >/dev/null 2>&1; then CAPS="nice -n 19"; fi
if command -v ionice >/dev/null 2>&1; then CAPS="$CAPS ionice -c 3"; fi

echo "=== $CHALLENGE_NAME challenge ==="
echo "phase3=$PHASE3  evidence=$OUT_DIR"

# --- Preconditions (§11.4.6 verify-not-assume; §11.4.3 honest SKIP) ---------
# An absent build / runtime is a genuine topology gap, NOT a proxy defect: SKIP.
if [ ! -f "$PHASE3" ]; then
    echo "OVERALL=SKIP:topology_unsupported (phase3 proof script missing: $PHASE3)"
    ab_skip_with_reason "LE Phase-3 hermetic DNS-01 issuance (phase3 proof script absent)" "topology_unsupported"
    exit 3
fi
if ! command -v podman-compose >/dev/null 2>&1; then
    echo "OVERALL=SKIP:topology_unsupported (podman-compose not on PATH)"
    ab_skip_with_reason "LE Phase-3 hermetic DNS-01 issuance (podman-compose absent)" "topology_unsupported"
    exit 3
fi
if ! command -v podman >/dev/null 2>&1 || ! podman image exists "$CADDY_IMAGE" 2>/dev/null; then
    echo "OVERALL=SKIP:topology_unsupported (image $CADDY_IMAGE not built — run deploy/letsencrypt/build.sh first)"
    ab_skip_with_reason "LE Phase-3 hermetic DNS-01 issuance (built Caddy image $CADDY_IMAGE absent)" "topology_unsupported"
    exit 3
fi

# --- Invoke the conductor-authored re-runnable proof ------------------------
# phase3 boots the hermetic stack, drives a REAL DNS-01 issuance, and gates its
# own exit on the cert-analyzer verdicts. We redirect its stdout+stderr to the
# log and capture phase3's OWN exit code directly (no pipe — so the rc is
# phase3's, never a pipeline tail's; §11.4.1 crash=FAIL relies on the true rc).
echo "--- invoking phase3 (real hermetic DNS-01 issuance; this boots containers) ---"
# shellcheck disable=SC2086
$CAPS bash "$PHASE3" > "$PHASE3_LOG" 2>&1
phase3_rc=$?
cat "$PHASE3_LOG"

echo "--- phase3 exit code: ${phase3_rc} ---"

# --- Map phase3 exit code -> Challenge verdict ------------------------------
# 2 = OPERATOR-BLOCKED / precondition unmet -> honest SKIP (§11.4.3), never FAIL.
if [ "${phase3_rc}" = "2" ]; then
    echo "OVERALL=SKIP:topology_unsupported (phase3 OPERATOR-BLOCKED — precondition unmet)"
    ab_skip_with_reason "LE Phase-3 hermetic DNS-01 issuance (phase3 precondition unmet, rc=2)" "topology_unsupported"
    exit 3
fi
# 1 (or any unexpected non-0/non-2 rc, §11.4.1) = real product defect -> FAIL.
if [ "${phase3_rc}" != "0" ]; then
    echo "OVERALL=FAIL (phase3 rc=${phase3_rc} — real issuance/verification defect; see $PHASE3_LOG)"
    grep -iE 'FAIL|error|panic|zone|refused' "$PHASE3_LOG" | tail -8 || true
    exit 1
fi

# --- phase3 PASS: independently RE-READ the analyzer's captured verdict ------
# (§11.4.116 — a PASS is only real if its captured evidence corroborates it.)
# Locate THIS run's evidence dir from phase3's own reported "Evidence: <dir>"
# line; fall back to the newest phase3_issuance run dir (conductor runs this
# serially — single-owner §11.4.119 — so newest is unambiguous).
VERDICTS=""
_evd=$(grep -oE 'Evidence: [^ ]+' "$PHASE3_LOG" 2>/dev/null | tail -n1 | awk '{print $2}')
if [ -n "${_evd:-}" ] && [ -f "${_evd}/cert_analyzer_verdicts.txt" ]; then
    VERDICTS="${_evd}/cert_analyzer_verdicts.txt"
else
    _base="$REPO_ROOT/qa-results/letsencrypt/phase3_issuance"
    if [ -d "$_base" ]; then
        _newest=$(ls -1dt "$_base"/*/ 2>/dev/null | head -n1)
        if [ -n "${_newest:-}" ] && [ -f "${_newest}cert_analyzer_verdicts.txt" ]; then
            VERDICTS="${_newest}cert_analyzer_verdicts.txt"
        fi
    fi
fi

if [ -z "${VERDICTS:-}" ] || [ ! -s "$VERDICTS" ]; then
    echo "OVERALL=FAIL (phase3 exited 0 but its cert_analyzer_verdicts.txt was not found/empty — uncorroborated PASS, §11.4.116)"
    exit 1
fi

# Assert the two decisive analyzer verdicts are PASS in phase3's OWN captured
# file. cert_chain_roots_in proves the served leaf cryptographically chains to
# THIS RUN's Pebble CA (a real issuance, not a static fixture); cert_san_matches
# proves the cert carries the requested hostname SAN.
_chain_ok=0; _san_ok=0
grep -Eq '^cert_chain_roots_in:[[:space:]]+PASS' "$VERDICTS" && _chain_ok=1
grep -Eq '^cert_san_matches:[[:space:]]+PASS'    "$VERDICTS" && _san_ok=1

{
    printf '=== %s challenge — run %s ===\n' "$CHALLENGE_NAME" "$RUN_TS"
    printf 'phase3_exit=%s\n' "${phase3_rc}"
    printf 'analyzer_verdicts_file=%s\n' "$VERDICTS"
    printf 'cert_chain_roots_in_PASS=%s  cert_san_matches_PASS=%s\n' "$_chain_ok" "$_san_ok"
    printf -- '--- captured analyzer verdicts (re-read, anti-bluff) ---\n'
    cat "$VERDICTS" 2>/dev/null | sed 's/^/  /'
} > "$OUT_DIR/verdict_crosscheck.txt"

if [ "$_chain_ok" = "1" ] && [ "$_san_ok" = "1" ]; then
    echo "OVERALL=PASS"
    ab_pass_with_evidence \
        "LE Phase-3 hermetic DNS-01 issuance: real cert issued + analyzer verified (chain-to-this-run-CA + SAN)" \
        "$VERDICTS"
    exit 0
fi

echo "OVERALL=FAIL (phase3 exited 0 but captured verdicts do not corroborate: cert_chain_roots_in PASS=$_chain_ok cert_san_matches PASS=$_san_ok — §11.4.116)"
exit 1
