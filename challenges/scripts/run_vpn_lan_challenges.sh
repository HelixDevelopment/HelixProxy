#!/usr/bin/env bash
# =============================================================================
# run_vpn_lan_challenges.sh — VPN-LAN service-access Challenge-bank runner
# -----------------------------------------------------------------------------
# Purpose:      Exercise the helix_proxy VPN-LAN feature (PLAN.md §5 Phase 11)
#               end-to-end as an operator would: run the svord bridge preflight
#               doctor (scripts/svord_doctor.sh) and then, per protocol, invoke
#               the corresponding tests/vpn_lan/*.sh round-trip test. Tally
#               PASS/FAIL/SKIP and write a summary + per-item logs under
#               qa-results/vpn_lan/challenges/<run-ts>/. When the svord bridge is
#               DOWN/misconfigured (the path that runs NOW — no live VPN, no
#               secrets), the doctor SKIPs and EVERY protocol test honestly SKIPs
#               (§11.4.3 / §11.4.68 / §11.4.69) — a down bridge is NEVER a FAIL
#               and NEVER a fake PASS. Exits non-zero ONLY on a real FAIL (a
#               genuine round-trip failure or a §11.4.1 script crash); an honest
#               SKIP is NOT a failure.
# Usage:        bash challenges/scripts/run_vpn_lan_challenges.sh
#               # Bridge-up (operator): source your gitignored .env first so the
#               # §3 contract resolves, e.g.
#               #   set -a; . ./.env; set +a; \
#               #   bash challenges/scripts/run_vpn_lan_challenges.sh
# Inputs:       scripts/svord_doctor.sh (preflight) + the sibling protocol tests
#               under tests/vpn_lan/ (smb_nfs_roundtrip.sh, ftp_sftp_webdav.sh,
#               email_roundtrip.sh, and — when authored — chromecast_dial.sh /
#               adb_over_vpn.sh). The PLAN.md §3 bridge contract is read from the
#               environment by those scripts; this runner passes it through
#               untouched and hardcodes NO svord path (§11.4.28).
# Outputs:      qa-results/vpn_lan/challenges/<run-ts>/summary.txt (tally),
#               qa-results/vpn_lan/challenges/<run-ts>/<name>.log   (per-item stdout).
#               Final `RESULT: OK` line iff zero FAILs (SKIPs are OK); Exit:
#               0 = no FAIL (all PASS/SKIP), 1 = >=1 real FAIL.
# Side-effects: Runs each item under `GOMAXPROCS=2 nice -n 19 ionice -c 3`
#               (host-safety §12.6/§12.9; caps degrade gracefully if a tool is
#               absent). Invocation-only: never modifies svord_toolkit or any
#               remote host (§11.4.122); the protocol tests do their own §11.4.14
#               cleanup on every exit path.
# Dependencies: bash; scripts/svord_doctor.sh; tests/lib/svord_bridge.sh; the
#               tests/vpn_lan/*.sh protocol scripts; nice/ionice (optional).
# Cross-refs:   docs/design/vpn_lan_access/PLAN.md §5 Phase 11 + §6 (evidence
#               strategy); Constitution §11.4.27 (Challenges), §11.4.3 (honest
#               SKIP), §11.4.69 (no fail-open-skip), §11.4.1 (crash=FAIL),
#               §12.6/§12.9 (host resource caps), §11.4.89 (bounded execution).
# Shell:        POSIX-clean body — parses under `sh -n` AND `bash -n` (§11.4.67).
# =============================================================================

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
find_repo_root() {
    d=$1
    while [ "$d" != "/" ]; do
        if [ -f "$d/tests/lib/svord_bridge.sh" ]; then
            printf '%s\n' "$d"; return 0
        fi
        d=$(dirname "$d")
    done
    return 1
}
REPO_ROOT=$(find_repo_root "$SCRIPT_DIR" || true)
if [ -z "${REPO_ROOT:-}" ]; then
    echo "FAIL: cannot locate tests/lib/svord_bridge.sh from $SCRIPT_DIR" >&2
    exit 1
fi

RUN_TS=$(date -u +%Y%m%dT%H%M%SZ)
RUN_DIR="$REPO_ROOT/qa-results/vpn_lan/challenges/$RUN_TS"
SUMMARY="$RUN_DIR/summary.txt"
mkdir -p "$RUN_DIR"

# --- Host-safety resource caps (degrade gracefully if a tool is absent) -----
GOMAXPROCS=2
export GOMAXPROCS

CAPS=""
if command -v nice >/dev/null 2>&1;   then CAPS="nice -n 19"; fi
if command -v ionice >/dev/null 2>&1; then CAPS="$CAPS ionice -c 3"; fi

DOCTOR="$REPO_ROOT/scripts/svord_doctor.sh"

# Protocol test scripts, in dependency order. Each entry is "LABEL|relpath".
# smb_nfs covers SMB/CIFS/NMB + NFS; ftp_sftp_webdav covers FTP/FTPS + SFTP +
# WebDAV; email covers IMAP(S)/SMTP-submission/POP3(S). chromecast_dial (Phase 6)
# and adb_over_vpn (Phase 7) are listed but honestly SKIP when their script is
# not yet authored — an unbuilt protocol test is SKIP, never a fake PASS and
# never a FAIL (§11.4.3 / §11.4.6).
PROTOCOL_ITEMS="\
SMB_NFS|tests/vpn_lan/smb_nfs_roundtrip.sh
FTP_SFTP_WEBDAV|tests/vpn_lan/ftp_sftp_webdav.sh
EMAIL|tests/vpn_lan/email_roundtrip.sh
CHROMECAST_DIAL|tests/vpn_lan/chromecast_dial.sh
ADB_OVER_VPN|tests/vpn_lan/adb_over_vpn.sh"

N_PASS=0; N_FAIL=0; N_SKIP=0
RESULT_LINES=""

{
    printf '=== helix_proxy VPN-LAN Challenge bank — run %s ===\n' "$RUN_TS"
    printf 'repo=%s\n' "$REPO_ROOT"
    printf 'caps=GOMAXPROCS=%s %s\n' "$GOMAXPROCS" "$CAPS"
    printf 'run_dir=%s\n\n' "$RUN_DIR"
} | tee "$SUMMARY"

# --- 1. svord bridge preflight doctor (VLA-BRIDGE-PREFLIGHT) ------------------
# Doctor exit codes: 0 = UP, 2 = SKIP (down/host-probe), 3 = MISCONFIGURED
# (contract unset — the autonomous NOW state, no .env). Only an unexpected exit
# code is a crash-FAIL (§11.4.1); down/misconfigured are honest SKIPs (§11.4.3).
name="VLA-BRIDGE-PREFLIGHT"
log="$RUN_DIR/$name.log"
echo "--- running $name (scripts/svord_doctor.sh) ---" | tee -a "$SUMMARY"
if [ ! -f "$DOCTOR" ]; then
    echo "--- $name: MISSING ($DOCTOR) -> FAIL ---" | tee -a "$SUMMARY"
    N_FAIL=$((N_FAIL + 1))
    RESULT_LINES="$RESULT_LINES\n$name  FAIL  (doctor script missing)"
else
    # shellcheck disable=SC2086
    $CAPS sh "$DOCTOR" > "$log" 2>&1
    rc=$?
    cat "$log"
    bridge=$(grep -E '^BRIDGE:' "$log" 2>/dev/null | tail -n1)
    [ -n "$bridge" ] || bridge="(no BRIDGE verdict line; rc=$rc)"
    case "$rc" in
        0) verdict="PASS"; N_PASS=$((N_PASS + 1)) ;;
        2|3) verdict="SKIP"; N_SKIP=$((N_SKIP + 1)) ;;
        *) verdict="FAIL"; N_FAIL=$((N_FAIL + 1)) ;;
    esac
    echo "--- $name -> $verdict (rc=$rc) $bridge ---" | tee -a "$SUMMARY"
    echo | tee -a "$SUMMARY"
    RESULT_LINES="$RESULT_LINES\n$name  $verdict  rc=$rc  $bridge"
fi

# --- 2. per-protocol round-trip tests ----------------------------------------
# The tests/vpn_lan/*.sh scripts exit 0 = no FAIL (all-PASS OR all-SKIP, e.g.
# bridge down) and exit 1 = a real round-trip FAILed. A single script can cover
# several protocols and emit a mix of PASS:/SKIP:/FAIL: tokens, so the verdict
# is derived from BOTH the exit code AND the emitted tokens:
#   rc != 0  OR  any '^FAIL:' line      -> FAIL
#   else any '^PASS:' line              -> PASS (real round-trip evidence)
#   else                                -> SKIP (bridge down / tool/target absent)
printf '%s\n' "$PROTOCOL_ITEMS" | while IFS='|' read -r label rel; do
    [ -n "$label" ] || continue
    path="$REPO_ROOT/$rel"
    name="VLA-$label"
    log="$RUN_DIR/$name.log"
    echo "--- running $name ($rel) ---" | tee -a "$SUMMARY"

    if [ ! -f "$path" ]; then
        # Not-yet-authored protocol test (e.g. Phase 6 Cast / Phase 7 ADB):
        # honest SKIP, never a FAIL and never a fake PASS (§11.4.3 / §11.4.6).
        {
            printf 'SKIP: %s [reason: feature_disabled_by_config — test script not yet authored: %s]\n' \
                "$name" "$rel"
        } | tee "$log"
        echo "--- $name -> SKIP (rc=n/a) test-not-present ---" | tee -a "$SUMMARY"
        echo | tee -a "$SUMMARY"
        printf 'SKIP  %s  (test script not present: %s)\n' "$name" "$rel" >> "$RUN_DIR/.tally"
        continue
    fi

    # shellcheck disable=SC2086
    $CAPS sh "$path" > "$log" 2>&1
    rc=$?
    cat "$log"

    n_fail=$(grep -c '^FAIL:' "$log" 2>/dev/null || true)
    n_pass=$(grep -c '^PASS:' "$log" 2>/dev/null || true)
    n_skip=$(grep -c '^SKIP' "$log" 2>/dev/null || true)
    [ -n "$n_fail" ] || n_fail=0
    [ -n "$n_pass" ] || n_pass=0
    [ -n "$n_skip" ] || n_skip=0

    if [ "$rc" -ne 0 ] || [ "$n_fail" -gt 0 ]; then
        verdict="FAIL"
    elif [ "$n_pass" -gt 0 ]; then
        verdict="PASS"
    else
        verdict="SKIP"
    fi
    last=$(grep -E '^(PASS|FAIL|SKIP)' "$log" 2>/dev/null | tail -n1)
    [ -n "$last" ] || last="(no PASS/FAIL/SKIP token; rc=$rc)"
    echo "--- $name -> $verdict (rc=$rc  P=$n_pass S=$n_skip F=$n_fail) $last ---" | tee -a "$SUMMARY"
    echo | tee -a "$SUMMARY"
    printf '%s  %s  rc=%s  (P=%s S=%s F=%s)  %s\n' \
        "$verdict" "$name" "$rc" "$n_pass" "$n_skip" "$n_fail" "$last" >> "$RUN_DIR/.tally"
done

# Fold the subshell-produced .tally into the counters (the `while` above runs in
# a pipeline subshell, so its N_* increments do not survive — re-tally here from
# the durable .tally file, the single source of truth for the protocol rows).
if [ -f "$RUN_DIR/.tally" ]; then
    while IFS= read -r tline; do
        case "$tline" in
            PASS\ *) N_PASS=$((N_PASS + 1)); RESULT_LINES="$RESULT_LINES\n$tline" ;;
            FAIL\ *) N_FAIL=$((N_FAIL + 1)); RESULT_LINES="$RESULT_LINES\n$tline" ;;
            SKIP\ *) N_SKIP=$((N_SKIP + 1)); RESULT_LINES="$RESULT_LINES\n$tline" ;;
        esac
    done < "$RUN_DIR/.tally"
    rm -f "$RUN_DIR/.tally"
fi

TOTAL=$((N_PASS + N_FAIL + N_SKIP))
{
    printf '=== TALLY (%s) ===\n' "$RUN_TS"
    printf 'total=%d  PASS=%d  FAIL=%d  SKIP=%d\n' "$TOTAL" "$N_PASS" "$N_FAIL" "$N_SKIP"
    # shellcheck disable=SC2059
    printf "$RESULT_LINES\n"
    printf '\nrun_dir=%s\n' "$RUN_DIR"
    if [ "$N_FAIL" -gt 0 ]; then
        printf 'RESULT: FAIL (%d real VPN-LAN defect(s))\n' "$N_FAIL"
    else
        printf 'RESULT: OK (no FAIL; PASS=%d SKIP=%d — SKIPs are honest non-applicable per §11.4.3; a down svord bridge is never a fake PASS)\n' \
            "$N_PASS" "$N_SKIP"
    fi
} | tee -a "$SUMMARY"

echo
echo "summary: $SUMMARY"

[ "$N_FAIL" -eq 0 ] || exit 1
exit 0
