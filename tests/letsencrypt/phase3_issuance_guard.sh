#!/bin/sh
#######################################################################
# §11.4.135 standing regression guard — Let's Encrypt Phase-3 hermetic
# DNS-01 issuance (task #59). §11.4.115 RED_MODE polarity.
#
# Purpose:
#   Prove — as a STANDING guard that BLOCKS the release tag on failure
#   (§11.4.40) — that the hermetic ACME stack still obtains a REAL TLS
#   certificate via DNS-01 against a LOCAL Pebble, AND that the exact
#   design-gap regression the CoreDNS authoritative-SOA front fixes
#   (2026-07-01) stays fixed. certmagic's DNS-01 flow determines the DNS
#   zone via an SOA walk BEFORE it presents the TXT; challtestsrv answers
#   NOTIMP to SOA (no authoritative mode), which BLOCKED issuance
#   ("could not determine zone ... NOTIMP"). CoreDNS was inserted as an
#   authoritative SOA front for hermetic.test; Caddy's ACME_RESOLVERS was
#   pointed at coredns:53. If a future change reverts ACME_RESOLVERS back
#   to challtestsrv:8053 (or drops CoreDNS), issuance silently breaks —
#   this guard catches that.
#
# Contract of the artifact under guard
#   (deploy/letsencrypt/phase3_hermetic_issue.sh, conductor-run):
#     exit 0 = REAL cert issued + cert-analyzer verified (evidence at
#              qa-results/letsencrypt/phase3_issuance/<run-id>/
#              cert_analyzer_verdicts.txt with every verdict PASS);
#     exit 1 = product defect (no cert / a verdict did not PASS);
#     exit 2 = OPERATOR-BLOCKED / precondition unmet (image or
#              podman-compose absent, no free port).
#
# What it does (drives the REAL phase3 — NOT a grep, NOT a re-implementation):
#   GREEN (RED_MODE=0) — run phase3 with the SHIPPED compose defaults
#         (ACME_RESOLVERS => coredns:53). PASS iff phase3 exits 0 AND its
#         produced cert_analyzer_verdicts.txt contains both
#         `cert_chain_roots_in: PASS` (leaf cryptographically chains to
#         THIS RUN's Pebble CA) AND `cert_san_matches: PASS` (SAN covers
#         the test hostname). If the built Caddy image / podman-compose is
#         ABSENT, emit an HONEST §11.4.3 topology SKIP (exit 2) — NEVER a
#         fake pass. A phase3 exit 2 (precondition unmet) is likewise SKIP.
#   RED   (RED_MODE=1) — run phase3 with a DELIBERATELY BROKEN resolver
#         (ACME_RESOLVERS=challtestsrv:8053, bypassing CoreDNS so
#         certmagic's SOA walk hits challtestsrv NOTIMP => no zone => no
#         cert). PASS iff phase3 FAILS (exit non-0, non-2) — proving the
#         guard catches the regression the CoreDNS SOA-front fixes. A RED
#         run where phase3 still succeeds is a §11.4.7 finding (guard FAIL).
#         Topology absent => SKIP (cannot reproduce without the stack).
#
# §11.4.115 polarity switch (RED_MODE):
#   RED_MODE=0 (default GREEN guard) — PASS iff phase3 issues + verifies.
#   RED_MODE=1 (reproduce)           — PASS iff broken-resolver issuance FAILS.
#
# RED injection mechanism (NO change to deploy/ required — see NOTE below):
#   compose.hermetic.yml declares `- ACME_RESOLVERS=${ACME_RESOLVERS:-coredns:53}`
#   and phase3 NEITHER forces NOR unsets ACME_RESOLVERS. Exporting
#   ACME_RESOLVERS=challtestsrv:8053 into phase3's environment therefore
#   propagates through phase3 -> podman-compose -> the compose ${..:-} default
#   -> Caddy, pointing certmagic's zone-determination resolver directly at
#   challtestsrv (which answers NOTIMP to SOA) and bypassing the CoreDNS
#   authoritative front — reproducing the exact pre-fix bug. GREEN unsets any
#   inherited ACME_RESOLVERS so the shipped coredns:53 default applies
#   deterministically (§11.4.50). CoreDNS still boots in RED; it is simply not
#   queried by Caddy — a faithful reproduction of the design gap.
#
#   NOTE (contingent phase3 one-liner — DOCUMENTED, NOT applied here; the
#   conductor owns deploy/ + run-tests.sh edits): as of phase3 HEAD 2026-07-01
#   NO change is needed. IF a future phase3 hardening pins or unsets
#   ACME_RESOLVERS (e.g. adds `unset ACME_RESOLVERS` or `export
#   ACME_RESOLVERS=coredns:53`) it would defeat this RED injection; the
#   conductor should then, right after phase3's `export CADDY_IMAGE ...` line
#   (~line 101), honour an externally-supplied value instead of forcing it:
#       export ACME_RESOLVERS="${ACME_RESOLVERS:-coredns:53}"
#   so the guard can still inject the broken resolver.
#
# Suite wiring (conductor owns tests/run-tests.sh — NOT edited here):
#   This guard mirrors the sibling §11.4.135 guards' 0=PASS / 1=FAIL
#   convention, PLUS a third code 2=SKIP (this guard boots containers and is
#   §11.4.119 conductor-only, unlike the hermetic siblings that never skip).
#   The run-tests.sh test_regression_guards() wiring should treat exit 2 as a
#   §11.4.3 SKIP (test_result "..." "SKIP"), exit 0 as PASS, exit 1 as FAIL —
#   for BOTH the GREEN and the RED_MODE=1 invocation.
#
# Usage (conductor-run — DO NOT run during background authoring, §11.4.119):
#   tests/letsencrypt/phase3_issuance_guard.sh            # GREEN standing guard
#   RED_MODE=1 tests/letsencrypt/phase3_issuance_guard.sh # reproduce the regression
#
# Inputs:   RED_MODE (env, default 0). CADDY_IMAGE (env, default matches phase3).
#           No CLI args. Honours phase3's own env knobs (CADDY_HTTPS_PORT, etc.).
# Outputs:  PASS/FAIL/SKIP verdict on stdout + evidence under
#           qa-results/regression/phase3_issuance_guard/. Exit 0=PASS, 1=FAIL,
#           2=SKIP (topology absent / precondition unmet — §11.4.3).
# Side-effects: in GREEN/RED it INVOKES phase3, which boots + tears down the
#           hermetic podman-compose stack (rootless, §11.4.161) and self-cleans
#           on exit (§11.4.14). This guard itself boots nothing and writes only
#           its own evidence file. Capped GOMAXPROCS=2 nice -n 19 ionice -c 3
#           (§ resource-limits) around the phase3 invocation.
# Dependencies: sh; the artifact deploy/letsencrypt/phase3_hermetic_issue.sh;
#           (only to actually run, conductor-side) podman + podman-compose +
#           the built image localhost/helix_proxy/caddy-challtestsrv:2.8.4.
#           Optionally sources tests/lib/evidence.sh for §11.4.69 emit helpers.
# Cross-references:
#   - Under guard: deploy/letsencrypt/phase3_hermetic_issue.sh (issuance),
#     deploy/letsencrypt/compose.hermetic.yml (ACME_RESOLVERS default),
#     deploy/letsencrypt/coredns/Corefile (SOA front), Caddyfile.
#   - Verdicts producer: tests/letsencrypt/cert_analyzer.sh.
#   - Sibling guards (style + RED_MODE convention matched):
#     tests/regression/cert_analyzer_selfvalidation_test.sh,
#     tests/regression/assert_egress_ip_host_unknown_test.sh.
#   - Root-cause research: docs/research/letsencrypt_hermetic_20260701/.
#   - Companion doc: docs/scripts/phase3_issuance_guard.md (§11.4.18).
#   - Constitution §11.4.107 (real-evidence) · §11.4.108 · §11.4.115 · §11.4.135
#     · §11.4.3 (SKIP-with-reason) · §11.4.119 (single-owner) · §11.4.50.
#######################################################################
set -eu

RED_MODE="${RED_MODE:-0}"
REPO_ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
PHASE3="$REPO_ROOT/deploy/letsencrypt/phase3_hermetic_issue.sh"
# Must match phase3's default so the presence pre-check reflects what phase3 runs.
CADDY_IMAGE="${CADDY_IMAGE:-localhost/helix_proxy/caddy-challtestsrv:2.8.4}"
# Where phase3 writes its per-run cert_analyzer_verdicts.txt (contract).
P3_EVID_ROOT="$REPO_ROOT/qa-results/letsencrypt/phase3_issuance"

EVID_DIR="$REPO_ROOT/qa-results/regression/phase3_issuance_guard"
mkdir -p "$EVID_DIR"
EVID_FILE="$EVID_DIR/phase3_issuance_guard.$$.txt"
P3_LOG="$EVID_DIR/phase3_run.$$.log"

# §11.4.69 emit helpers when available (mirrors phase3's optional-helper use);
# never a hard dependency — the verdict logic below stands on its own.
if [ -f "$REPO_ROOT/tests/lib/evidence.sh" ]; then
    # shellcheck source=/dev/null
    . "$REPO_ROOT/tests/lib/evidence.sh" 2>/dev/null || true
fi

# Resource caps (§ resource-limits): only the tools that exist, so a missing
# ionice never turns this into a §11.4.1 script-internal FAIL-bluff.
CAPS=""
command -v nice   >/dev/null 2>&1 && CAPS="nice -n 19"
command -v ionice >/dev/null 2>&1 && CAPS="$CAPS ionice -c 3"

verdict=FAIL
exit_code=1
msg=""

emit_and_exit() {
    # $1 verdict  $2 exit_code  $3 message
    {
        echo "LE Phase-3 hermetic DNS-01 issuance regression guard — §11.4.135/§11.4.115/§11.4.107"
        echo "timestamp_utc: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo "RED_MODE: $RED_MODE"
        echo "caddy_image: $CADDY_IMAGE"
        echo "phase3: $PHASE3"
        echo "phase3_log: $P3_LOG"
        echo "verdict: $1"
        echo "detail: $3"
    } > "$EVID_FILE"
    echo "[$1] le-phase3-issuance (RED_MODE=$RED_MODE): $3"
    echo "evidence: $EVID_FILE"
    exit "$2"
}

# ---- Preconditions (§11.4.3 honest topology SKIP, never a fake pass) ---------
if [ ! -f "$PHASE3" ]; then
    emit_and_exit SKIP 2 "phase3 artifact absent ($PHASE3) — topology_unsupported"
fi
if ! command -v podman-compose >/dev/null 2>&1 || ! command -v podman >/dev/null 2>&1; then
    if command -v ab_skip_with_reason >/dev/null 2>&1; then
        ab_skip_with_reason "LE Phase-3 hermetic issuance guard" topology_unsupported || true
    fi
    emit_and_exit SKIP 2 "podman/podman-compose not on PATH — topology_unsupported (§11.4.3)"
fi
if ! podman image exists "$CADDY_IMAGE" 2>/dev/null; then
    if command -v ab_skip_with_reason >/dev/null 2>&1; then
        ab_skip_with_reason "LE Phase-3 hermetic issuance guard" feature_disabled_by_config || true
    fi
    emit_and_exit SKIP 2 "built image $CADDY_IMAGE absent — run deploy/letsencrypt/build.sh first (topology absent, §11.4.3)"
fi

# Freshness marker so we only read THIS run's verdicts file (single-owner,
# §11.4.119), never a stale one from a previous run.
MARKER="$EVID_DIR/.start_marker.$$"
: > "$MARKER"

# run_phase3 <resolver-override|""> : invoke phase3 capped; return its exit code
# in $rc (NEVER aborts this guard — protected by || rc=$?). "" => GREEN, unset
# any inherited ACME_RESOLVERS so the compose coredns:53 default applies.
rc=0
run_phase3() {
    _rp_res="${1:-}"
    if [ -n "$_rp_res" ]; then
        # RED — inject the broken resolver into phase3's environment.
        ACME_RESOLVERS="$_rp_res" GOMAXPROCS=2 $CAPS bash "$PHASE3" > "$P3_LOG" 2>&1 && rc=0 || rc=$?
    else
        # GREEN — shipped defaults; strip any inherited override (§11.4.50).
        ( unset ACME_RESOLVERS; GOMAXPROCS=2 $CAPS bash "$PHASE3" ) > "$P3_LOG" 2>&1 && rc=0 || rc=$?
    fi
}

# newest cert_analyzer_verdicts.txt produced AFTER our start marker.
latest_verdicts() {
    find "$P3_EVID_ROOT" -name cert_analyzer_verdicts.txt -newer "$MARKER" 2>/dev/null \
        | sort | tail -1
}

if [ "$RED_MODE" = "1" ]; then
    # -------------------------------------------------------------------------
    # RED — broken resolver: certmagic SOA walk hits challtestsrv NOTIMP =>
    # cannot determine zone => no cert. Assert phase3 FAILS (non-0, non-2).
    # -------------------------------------------------------------------------
    run_phase3 "challtestsrv:8053"
    rm -f "$MARKER"
    if [ "$rc" = "2" ]; then
        emit_and_exit SKIP 2 "phase3 precondition unmet (exit 2) — cannot reproduce without the stack (§11.4.3)"
    elif [ "$rc" != "0" ]; then
        verdict=PASS; exit_code=0
        msg="RED reproduced: broken resolver ACME_RESOLVERS=challtestsrv:8053 bypassed CoreDNS -> certmagic SOA walk NOTIMP -> phase3 FAILED (exit $rc) — the guard catches the CoreDNS-SOA-front regression"
        emit_and_exit "$verdict" "$exit_code" "$msg"
    else
        verdict=FAIL; exit_code=1
        msg="RED could-not-reproduce: phase3 STILL succeeded (exit 0) with the broken resolver — the regression is not caught (finding per §11.4.7); see $P3_LOG"
        emit_and_exit "$verdict" "$exit_code" "$msg"
    fi
else
    # -------------------------------------------------------------------------
    # GREEN — shipped defaults. PASS iff phase3 exit 0 AND both required
    # verdicts PASS in the produced cert_analyzer_verdicts.txt.
    # -------------------------------------------------------------------------
    run_phase3 ""
    _v="$(latest_verdicts)"
    rm -f "$MARKER"
    if [ "$rc" = "2" ]; then
        emit_and_exit SKIP 2 "phase3 precondition unmet (exit 2 — image/podman-compose/port) — topology absent (§11.4.3)"
    elif [ "$rc" != "0" ]; then
        emit_and_exit FAIL 1 "phase3 FAILED (exit $rc) — no real cert issued/verified; see $P3_LOG and ${_v:-<no verdicts file>}"
    elif [ -z "$_v" ] || [ ! -s "$_v" ]; then
        emit_and_exit FAIL 1 "phase3 exited 0 but produced NO cert_analyzer_verdicts.txt (§11.4.107 missing-evidence bluff); see $P3_LOG"
    elif grep -Eq '^cert_chain_roots_in:[[:space:]]+PASS' "$_v" \
      && grep -Eq '^cert_san_matches:[[:space:]]+PASS' "$_v"; then
        verdict=PASS; exit_code=0
        msg="GREEN: real hermetic DNS-01 cert issued + verified — cert_chain_roots_in:PASS (leaf -> THIS-RUN Pebble CA) AND cert_san_matches:PASS; evidence: $_v"
        # Prefer the project's evidence helper (§11.4.69) when available.
        if command -v ab_pass_with_evidence >/dev/null 2>&1; then
            ab_pass_with_evidence "LE Phase-3 hermetic DNS-01 issuance" "$_v" || true
        fi
        emit_and_exit "$verdict" "$exit_code" "$msg"
    else
        emit_and_exit FAIL 1 "phase3 exited 0 but cert_analyzer_verdicts.txt lacks cert_chain_roots_in:PASS and/or cert_san_matches:PASS — issuance not genuinely verified (§11.4.107); see $_v"
    fi
fi
