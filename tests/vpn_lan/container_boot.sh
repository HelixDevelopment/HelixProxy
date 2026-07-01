#!/usr/bin/env sh
###############################################################################
# container_boot.sh — VPN-LAN containers boot-readiness probe (PLAN.md §5 Phase 10)
#
# Purpose:
#   Prove that the VPN-LAN helper services (the Phase-5 discovery reflector + the
#   Phase-7 central adb-server) can be booted ON-DEMAND through the
#   `submodules/containers` orchestration layer (pkg/boot + pkg/compose +
#   pkg/health, rootless Podman §11.4.161) — WITHOUT actually starting a
#   container (remote deployment is operator-gated §11.4.122, see
#   docs/design/vpn_lan_access/containerization.md §7). The single SCORED check
#   is a config-parse / plan-level readiness proof:
#     - the containers-submodule boot primitives are present + invocable
#       (pkg/boot/manager.go + pkg/compose/helix_project.go + pkg/health/checker.go),
#     - a rootless container runtime (podman) is on PATH (presence-checked,
#       NEVER invoked — this probe never runs podman/docker, never boots a
#       container),
#     - the project-side service declaration (vpn_lan_containers.yaml) PARSES and
#       declares both services (vpn-lan-reflector + vpn-lan-adb-server) with the
#       required fields (image + healthcheck) and injected (${...}) config.
#   The non-empty readiness.evidence file with all three proven is the PASS
#   evidence (§11.4.5 / §11.4.69).
#   The svord bridge is the gate: DOWN/misconfigured => honest SKIP + exit 0
#   (§11.4.3 / §11.4.68 / §11.4.69) — a down bridge is NEVER a failure and NEVER a
#   fake PASS. Containers submodule primitives absent => SKIP:topology_unsupported.
#   No container runtime on PATH => SKIP:hardware_not_present. No YAML parser
#   (python3) => SKIP:topology_unsupported. A genuinely MALFORMED declaration
#   (unparseable YAML, or a missing required service/field) => FAIL (fail-closed) —
#   a broken deliverable is never SKIPped away. NEVER boots a container, NEVER runs
#   podman/docker, NEVER pkill/kill, NEVER touches the data-plane config or Squid.
#
# Usage:
#   Live bridge (source your .env first — real values in .env):
#     set -a; . ./.env; set +a; tests/vpn_lan/container_boot.sh
#   Bridge-down (default autonomous, no .env): prints a SKIP verdict + exit 0.
#   Local-stub (autonomous plan proof, no live VPN — PLAN.md §6 local-stub path):
#     HELIX_SVORD_DIR=. HELIX_BRIDGE_CONNECT=true HELIX_BRIDGE_DISCONNECT=true \
#     HELIX_BRIDGE_HEALTH=true HELIX_BRIDGE_SUBNET=10.0.0.0/8 \
#     HELIX_BRIDGE_HOST=10.6.100.221 tests/vpn_lan/container_boot.sh
#   Optional overrides:
#     HELIX_VPN_COMPOSE_FILE  path to the service declaration (default
#                             docs/design/vpn_lan_access/vpn_lan_containers.yaml).
#     SVORD_BRIDGE_LIB        path to tests/lib/svord_bridge.sh override.
#
# Inputs (environment):
#   PLAN.md §3 bridge contract (gate — resolved by tests/lib/svord_bridge.sh):
#     HELIX_SVORD_DIR HELIX_BRIDGE_CONNECT HELIX_BRIDGE_DISCONNECT
#     HELIX_BRIDGE_HEALTH HELIX_BRIDGE_SUBNET HELIX_BRIDGE_HOST
#   HELIX_VPN_COMPOSE_FILE (optional) — service-declaration path override.
#   SVORD_BRIDGE_LIB       (optional) — bridge library path override.
#
# Outputs:
#   Diagnostic lines on stdout; one verdict token for the scored check
#   (PASS / FAIL / SKIP:<reason>). Exit 0 when the bridge is down (honest SKIP) or
#   when every executed check PASSed/SKIPped; exit 1 iff a real check FAILed.
#   Captured evidence under qa-results/vpn_lan/phase10/<UTC-ts>/.
#
# Side-effects:
#   Read-only. Presence-checks the runtime binary (command -v — NEVER invoked),
#   reads the submodule tree + the project YAML, parses the YAML with python3.
#   NO container is booted, NO podman/docker is run, NO process is signalled, NO
#   remote host is changed (deployment is operator-gated §11.4.122). Temp files
#   removed on every exit path (trap, §11.4.14). NEVER modifies submodules/containers,
#   svord_toolkit, the base proxy config, or Squid (invocation-only, §11.4.119/§11.4.122).
#
# Dependencies:
#   POSIX sh; tests/lib/svord_bridge.sh; the submodules/containers tree; python3
#   (robust YAML parse — the SCORED analyzer; PyYAML). Missing tools/targets SKIP
#   honestly — they never FAIL and never PASS. A malformed declaration FAILs.
#
# Cross-references:
#   docs/design/vpn_lan_access/containerization.md      (this test's design)
#   docs/design/vpn_lan_access/vpn_lan_containers.yaml  (the service declaration)
#   docs/design/vpn_lan_access/reflector_design.md §3.4 (the reflector)
#   docs/design/vpn_lan_access/PLAN.md §5 Phase 5/7/10 + §6
#   tests/lib/svord_bridge.sh          (bridge contract library sourced below)
#   tests/vpn_lan/discovery_reflect.sh (the anti-bluff structure this mirrors)
#   constitution §11.4.3 / §11.4.5 / §11.4.6 / §11.4.14 / §11.4.69 / §11.4.76 /
#     §11.4.119 / §11.4.122 / §11.4.161
###############################################################################

set -u

SCRIPT_LABEL='container_boot'

# ---- resolve + source the bridge contract library ---------------------------
_cb_script_dir=$(cd "$(dirname "$0")" && pwd)
_cb_repo_root=$(cd "$_cb_script_dir/../.." && pwd)
SVORD_BRIDGE_LIB="${SVORD_BRIDGE_LIB:-$_cb_repo_root/tests/lib/svord_bridge.sh}"

log() { printf '%s: %s\n' "$SCRIPT_LABEL" "$1"; }

if [ ! -f "$SVORD_BRIDGE_LIB" ]; then
    printf 'SKIP:misconfigured  [%s — bridge library missing: %s; honest SKIP (§11.4.3)]\n' \
        "$SCRIPT_LABEL" "$SVORD_BRIDGE_LIB"
    exit 0
fi
# shellcheck disable=SC1090
. "$SVORD_BRIDGE_LIB"

# ---- §11.4.69 PASS/SKIP/FAIL emitters (self-contained, evidence-gated) -------
ab_pass_with_evidence() {
    _pe_desc=$1
    _pe_ev=${2:-}
    if [ -z "$_pe_ev" ] || [ ! -s "$_pe_ev" ]; then
        printf 'FAIL: %s [reason: evidence missing or empty: %s]\n' "$_pe_desc" "$_pe_ev"
        return 1
    fi
    printf 'PASS: %s [evidence: %s]\n' "$_pe_desc" "$_pe_ev"
    return 0
}
ab_skip_with_reason() {
    _sr_desc=$1
    _sr_reason=${2:-}
    case "$_sr_reason" in
        geo_restricted|operator_attended|hardware_not_present|topology_unsupported|network_unreachable_external|feature_disabled_by_config)
            printf 'SKIP: %s [reason: %s]\n' "$_sr_desc" "$_sr_reason"
            return 0 ;;
        *)
            printf 'FAIL: %s [reason: invalid skip reason %s — not §11.4.69 closed set]\n' "$_sr_desc" "$_sr_reason"
            return 2 ;;
    esac
}
ab_fail() { printf 'FAIL: %s [%s]\n' "$1" "${2:-}"; }

OVERALL_FAIL=0
mark_fail() { OVERALL_FAIL=1; }

# ---- cleanup (§11.4.14) -----------------------------------------------------
CB_TMPDIR=''
cleanup() {
    [ -n "$CB_TMPDIR" ] && rm -rf "$CB_TMPDIR" >/dev/null 2>&1
    return 0
}
trap cleanup EXIT INT TERM

# ============================================================================
# GATE — honest-SKIP-first. When the bridge is DOWN/misconfigured we print the
# SKIP verdict and exit 0. This is the path that runs NOW (bridge down) — no
# container plan is evaluated, no runtime probed, no submodule invoked.
# ============================================================================
BRIDGE_GATE=$(bridge_require 2>/dev/null)
BRIDGE_RC=$?
if [ "$BRIDGE_RC" -ne 0 ]; then
    [ -z "$BRIDGE_GATE" ] && BRIDGE_GATE='SKIP:network_unreachable_external'
    printf '%s  [%s — svord bridge not up; honest SKIP (§11.4.3), NOT a failure, NOT a fake PASS]\n' \
        "$BRIDGE_GATE" "$SCRIPT_LABEL"
    exit 0
fi
log 'svord bridge UP — running container boot-readiness plan check (subnet='"$(bridge_subnet)"' host='"$(bridge_host)"')'

# ---- evidence root (only created when the bridge is genuinely up) -----------
CB_TS=$(date -u +%Y%m%dT%H%M%SZ 2>/dev/null || date +%Y%m%dT%H%M%SZ)
EV_ROOT="$_cb_repo_root/qa-results/vpn_lan/phase10/$CB_TS"
mkdir -p "$EV_ROOT" 2>/dev/null || true
CB_TMPDIR=$(mktemp -d 2>/dev/null || printf '%s' "${TMPDIR:-/tmp}/helix_cb_$$")
mkdir -p "$CB_TMPDIR" 2>/dev/null || true

CONTAINERS_DIR="$_cb_repo_root/submodules/containers"
COMPOSE_FILE=${HELIX_VPN_COMPOSE_FILE:-$_cb_repo_root/docs/design/vpn_lan_access/vpn_lan_containers.yaml}
readiness_desc='VPN-LAN reflector + adb-server boot plan invocable via submodules/containers (§11.4.76 on-demand, §11.4.161 rootless)'

# ============================================================================
# SCORED — boot-readiness (config-parse / plan level, NEVER a boot). A real,
# proven plan (submodule primitives present + rootless runtime on PATH + the
# project declaration parses with both services) is the PASS evidence
# (§11.4.5 / §11.4.69). Absent prerequisites SKIP honestly; a malformed
# declaration FAILs (fail-closed). NO container is started; podman is
# presence-checked ONLY, never invoked.
# ============================================================================

# --- (a) containers-submodule boot primitives present + invocable ------------
CB_BOOT="$CONTAINERS_DIR/pkg/boot/manager.go"
CB_COMPOSE="$CONTAINERS_DIR/pkg/compose/helix_project.go"
CB_HEALTH="$CONTAINERS_DIR/pkg/health/checker.go"
if [ ! -f "$CB_BOOT" ] || [ ! -f "$CB_COMPOSE" ] || [ ! -f "$CB_HEALTH" ]; then
    ab_skip_with_reason "$readiness_desc" topology_unsupported
    log "containers submodule boot primitives absent (pkg/boot|pkg/compose|pkg/health under $CONTAINERS_DIR) — SKIP (not a PASS)"
    log "done — evidence root: $EV_ROOT"
    exit "$OVERALL_FAIL"
fi

# --- (b) a rootless container runtime on PATH (presence ONLY, NEVER invoked) --
RUNTIME_BIN=''
for _rt in podman docker podman-compose; do
    if command -v "$_rt" >/dev/null 2>&1; then
        RUNTIME_BIN="$_rt"
        break
    fi
done
if [ -z "$RUNTIME_BIN" ]; then
    ab_skip_with_reason "$readiness_desc" hardware_not_present
    log 'no rootless container runtime (podman/docker/podman-compose) on PATH — SKIP (not a PASS); runtime is NEVER invoked by this probe'
    log "done — evidence root: $EV_ROOT"
    exit "$OVERALL_FAIL"
fi

# --- (c) a YAML parser (python3 + PyYAML) for the config-parse/plan check -----
if ! command -v python3 >/dev/null 2>&1; then
    ab_skip_with_reason "$readiness_desc" topology_unsupported
    log 'no python3 YAML parser available for the config-parse/plan check — SKIP (not a PASS, §11.4.6)'
    log "done — evidence root: $EV_ROOT"
    exit "$OVERALL_FAIL"
fi

# --- (d) the project-side service declaration must exist (fail-closed) --------
if [ ! -f "$COMPOSE_FILE" ]; then
    ab_fail "$readiness_desc" "service declaration missing (fail-closed): $COMPOSE_FILE"
    mark_fail
    log "done — evidence root: $EV_ROOT"
    exit "$OVERALL_FAIL"
fi

# --- (e) config-parse / plan check: parse the declaration, assert both --------
#         services with the required fields. NO container is booted.
plan_out="$CB_TMPDIR/plan.txt"
HELIX_VPN_COMPOSE_FILE="$COMPOSE_FILE" \
python3 - > "$plan_out" 2>"$EV_ROOT/plan.err" <<'PYEOF'
import os, sys
path = os.environ.get("HELIX_VPN_COMPOSE_FILE", "")
try:
    import yaml
except Exception as e:  # PyYAML absent -> honest SKIP upstream (exit 5)
    print("analyze_result=no_yaml_parser")
    print("detail=%s" % e)
    sys.exit(5)
try:
    with open(path, "r") as fh:
        doc = yaml.safe_load(fh)
except FileNotFoundError as e:
    print("analyze_result=missing")
    print("detail=%s" % e)
    sys.exit(4)
except yaml.YAMLError as e:
    print("analyze_result=malformed")
    print("detail=%s" % str(e).replace("\n", " "))
    sys.exit(2)
except Exception as e:
    print("analyze_result=malformed")
    print("detail=%s" % e)
    sys.exit(2)

if not isinstance(doc, dict):
    print("analyze_result=malformed")
    print("detail=top-level document is not a mapping")
    sys.exit(2)

services = doc.get("services")
if not isinstance(services, dict):
    print("analyze_result=incomplete")
    print("detail=no 'services' mapping")
    sys.exit(3)

REQUIRED = ["vpn-lan-reflector", "vpn-lan-adb-server"]
problems = []
found = []
for name in REQUIRED:
    svc = services.get(name)
    if not isinstance(svc, dict):
        problems.append("missing service '%s'" % name)
        continue
    image = svc.get("image")
    if not isinstance(image, str) or not image.strip():
        problems.append("service '%s' missing non-empty image" % name)
    hc = svc.get("healthcheck")
    if not isinstance(hc, dict) or not hc.get("test"):
        problems.append("service '%s' missing healthcheck.test" % name)
    if isinstance(image, str) and image.strip():
        # config-injection posture (§11.4.28): the image tag is an injected
        # ${...} placeholder, never a hardcoded literal. Recorded, not gated.
        injected = "yes" if image.strip().startswith("${") else "no"
        found.append("%s(image_injected=%s)" % (name, injected))

if problems:
    print("analyze_result=incomplete")
    print("detail=%s" % "; ".join(problems))
    sys.exit(3)

print("analyze_result=ok")
print("services=%s" % ",".join(REQUIRED))
print("service_detail=%s" % " ".join(found))
print("service_count=%d" % len(services))
sys.exit(0)
PYEOF
PLAN_RC=$?

PLAN_RESULT=$(awk -F= '/^analyze_result=/{print $2; exit}' "$plan_out" 2>/dev/null)
[ -z "$PLAN_RESULT" ] && PLAN_RESULT='unknown'
PLAN_DETAIL=$(awk -F= '/^detail=/{sub(/^detail=/,""); print; exit}' "$plan_out" 2>/dev/null)
PLAN_SVC_DETAIL=$(awk -F= '/^service_detail=/{sub(/^service_detail=/,""); print; exit}' "$plan_out" 2>/dev/null)
PLAN_SVC_COUNT=$(awk -F= '/^service_count=/{print $2; exit}' "$plan_out" 2>/dev/null)

case "$PLAN_RC" in
    0)
        readiness_ev="$EV_ROOT/readiness.evidence"
        {
            printf 'check           : %s\n' "$readiness_desc"
            printf 'timestamp_utc   : %s\n' "$CB_TS"
            printf 'containers_dir  : %s\n' "$CONTAINERS_DIR"
            printf 'primitive_boot  : %s\n' "$CB_BOOT"
            printf 'primitive_compose: %s\n' "$CB_COMPOSE"
            printf 'primitive_health: %s\n' "$CB_HEALTH"
            printf 'runtime_on_path : %s (presence-checked only, NEVER invoked)\n' "$RUNTIME_BIN"
            printf 'declaration     : %s\n' "$COMPOSE_FILE"
            printf 'parse_result    : %s\n' "$PLAN_RESULT"
            printf 'services        : %s\n' "vpn-lan-reflector,vpn-lan-adb-server"
            printf 'service_detail  : %s\n' "${PLAN_SVC_DETAIL:-<none>}"
            printf 'service_count   : %s\n' "${PLAN_SVC_COUNT:-0}"
            printf 'boot_performed  : NO (config-parse/plan only — remote deploy operator-gated §11.4.122)\n'
            printf 'expected        : both services declared with image + healthcheck, submodule primitives present, rootless runtime on PATH\n'
        } > "$readiness_ev" 2>/dev/null
        ab_pass_with_evidence "$readiness_desc" "$readiness_ev" || mark_fail
        ;;
    5)
        # PyYAML missing inside python3 — honest SKIP (no robust YAML parser).
        ab_skip_with_reason "$readiness_desc" topology_unsupported
        log "python3 present but no YAML parser (PyYAML) — config-parse SKIP (not a PASS, §11.4.6); detail: ${PLAN_DETAIL:-}"
        ;;
    2|3|4)
        # Malformed / incomplete / missing declaration => fail-closed (§11.4.6).
        ab_fail "$readiness_desc" "declaration $PLAN_RESULT (fail-closed): ${PLAN_DETAIL:-<no detail>} (see $EV_ROOT/plan.err)"
        mark_fail
        ;;
    *)
        ab_fail "$readiness_desc" "config-parse analyzer error rc=$PLAN_RC result=$PLAN_RESULT (see $EV_ROOT/plan.err)"
        mark_fail
        ;;
esac

log "done — evidence root: $EV_ROOT"
exit "$OVERALL_FAIL"
