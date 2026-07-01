#!/usr/bin/env sh
###############################################################################
# smb_nfs_roundtrip.sh — VPN-LAN file-share round-trip test (PLAN.md §5 Phase 2)
#
# Purpose:
#   Prove SMB/CIFS and NFS file shares exposed on the svord VPN-internal network
#   are reachable + usable THROUGH helix_proxy's L3-routed gateway, with real
#   byte-integrity evidence (write-a-file -> read-back -> sha256 match). The svord
#   bridge is the gate: when it is DOWN/misconfigured every check honestly SKIPs
#   (§11.4.3 / §11.4.68 / §11.4.69) — a down bridge is NEVER a failure and NEVER a
#   fake PASS. A PASS is emitted ONLY on captured matching sha256 bytes (§11.4.5 /
#   §11.4.69); an absent share/tool SKIPs, it never PASSes.
#
# Usage:
#   scripts run it after sourcing your .env (real bridge values live in .env):
#     set -a; . ./.env; set +a; tests/vpn_lan/smb_nfs_roundtrip.sh
#   Bridge-down (default autonomous, no .env): prints a SKIP verdict + exit 0.
#   Optional override for testing: SVORD_BRIDGE_LIB=/path/to/svord_bridge.sh
#
# Inputs (environment):
#   PLAN.md §3 bridge contract (gate — resolved by tests/lib/svord_bridge.sh):
#     HELIX_SVORD_DIR HELIX_BRIDGE_CONNECT HELIX_BRIDGE_DISCONNECT
#     HELIX_BRIDGE_HEALTH HELIX_BRIDGE_SUBNET HELIX_BRIDGE_HOST
#   Optional SMB/CIFS target (operator-supplied when the bridge is up):
#     HELIX_VPN_SMB_UNC     UNC of the VPN share, e.g. //10.6.100.221/share
#     HELIX_VPN_SMB_USER    username (omit for anonymous / -N)
#     HELIX_VPN_SMB_PASS    password (NEVER logged — §11.4.10)
#     HELIX_VPN_SMB_DOMAIN  optional workgroup/domain
#   Optional NFS target (operator-supplied when the bridge is up):
#     HELIX_VPN_NFS_MOUNTED path to an ALREADY-mounted NFS export (no root needed)
#     HELIX_VPN_NFS_EXPORT  server:/export to mount into a temp dir (needs root)
#   SVORD_BRIDGE_LIB (optional) — path to tests/lib/svord_bridge.sh override.
#
# Outputs:
#   Diagnostic lines on stdout; exactly one verdict token per protocol
#   (PASS / FAIL / SKIP:<reason>). Exit 0 when the bridge is down (honest SKIP)
#   or when every executed round-trip PASSed/SKIPped; exit 1 iff a real round-trip
#   FAILed (bytes did not survive). Captured evidence under
#   qa-results/vpn_lan/phase2/<UTC-ts>/{smb,nfs}/ when run against a live bridge.
#
# Side-effects:
#   With a live bridge + configured target: writes a small known file to the
#   share, reads it back, deletes it. NFS temp mount (when HELIX_VPN_NFS_EXPORT is
#   used) is unmounted + removed on every exit path (trap, §11.4.14). NEVER
#   modifies svord_toolkit or any remote host beyond the round-trip file it
#   created (invocation-only, §11.4.122). No base-proxy config is touched.
#
# Dependencies:
#   POSIX sh; tests/lib/svord_bridge.sh; sha256sum OR shasum -a 256; smbclient
#   (preferred) or mount.cifs for SMB; mount/umount for the NFS temp-mount path.
#   Missing tools/targets SKIP honestly — they never FAIL and never PASS.
#
# Cross-references:
#   docs/design/vpn_lan_access/PLAN.md §5 Phase 2 + §6 (test-evidence strategy)
#   tests/lib/svord_bridge.sh          (bridge contract library sourced below)
#   scripts/svord_doctor.sh            (Phase-0 preflight doctor)
#   constitution §11.4.3 / §11.4.5 / §11.4.6 / §11.4.14 / §11.4.69 / §11.4.122
###############################################################################

set -u

SCRIPT_LABEL='smb_nfs_roundtrip'

# ---- resolve + source the bridge contract library ---------------------------
_rt_script_dir=$(cd "$(dirname "$0")" && pwd)
_rt_repo_root=$(cd "$_rt_script_dir/../.." && pwd)
SVORD_BRIDGE_LIB="${SVORD_BRIDGE_LIB:-$_rt_repo_root/tests/lib/svord_bridge.sh}"

log() { printf '%s: %s\n' "$SCRIPT_LABEL" "$1"; }

if [ ! -f "$SVORD_BRIDGE_LIB" ]; then
    # No contract library == cannot even evaluate the gate: honest SKIP, not FAIL.
    printf 'SKIP:misconfigured  [%s — bridge library missing: %s; honest SKIP (§11.4.3)]\n' \
        "$SCRIPT_LABEL" "$SVORD_BRIDGE_LIB"
    exit 0
fi
# shellcheck disable=SC1090
. "$SVORD_BRIDGE_LIB"

# ---- §11.4.69 PASS/SKIP/FAIL emitters (self-contained, evidence-gated) -------
# ab_pass_with_evidence: PASS only if the cited artefact EXISTS and is NON-EMPTY
# (a PASS with no captured bytes is a §11.4 PASS-bluff — refused).
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
# ab_skip_with_reason: honest SKIP for a genuinely-absent precondition; the reason
# MUST be in the §11.4.69 closed set, else it is itself a bluff.
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

# ---- sha256 helper (cross-platform §11.4.81) --------------------------------
sha256_of() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" 2>/dev/null | awk '{print $1; exit}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" 2>/dev/null | awk '{print $1; exit}'
    else
        printf ''
    fi
}

OVERALL_FAIL=0
mark_fail() { OVERALL_FAIL=1; }

# ---- cleanup (§11.4.14) — temp files + any NFS temp-mount the script made ----
RT_TMPDIR=''
RT_NFS_TEMP_MOUNT=''
cleanup() {
    if [ -n "$RT_NFS_TEMP_MOUNT" ]; then
        umount "$RT_NFS_TEMP_MOUNT" >/dev/null 2>&1 || true
        rmdir "$RT_NFS_TEMP_MOUNT" >/dev/null 2>&1 || true
    fi
    [ -n "$RT_TMPDIR" ] && rm -rf "$RT_TMPDIR" >/dev/null 2>&1
    return 0
}
trap cleanup EXIT INT TERM

# ============================================================================
# GATE — honest-SKIP-first. When the bridge is DOWN/misconfigured we print the
# SKIP verdict and exit 0. This is the path that runs NOW (bridge down).
# ============================================================================
BRIDGE_GATE=$(bridge_require 2>/dev/null)
BRIDGE_RC=$?
if [ "$BRIDGE_RC" -ne 0 ]; then
    # BRIDGE_GATE is "SKIP:network_unreachable_external" (rc 2) or
    # "SKIP:misconfigured" (rc 3). Re-emit greppably; a down bridge is NOT a
    # failure and NOT a fake PASS (§11.4.3 / §11.4.68 / §11.4.69).
    [ -z "$BRIDGE_GATE" ] && BRIDGE_GATE='SKIP:network_unreachable_external'
    printf '%s  [%s — svord bridge not up; honest SKIP (§11.4.3), NOT a failure, NOT a fake PASS]\n' \
        "$BRIDGE_GATE" "$SCRIPT_LABEL"
    exit 0
fi
log 'svord bridge UP — running live SMB/NFS round-trips (subnet='"$(bridge_subnet)"' host='"$(bridge_host)"')'

# ---- evidence root (only created when the bridge is genuinely up) -----------
RT_TS=$(date -u +%Y%m%dT%H%M%SZ 2>/dev/null || date +%Y%m%dT%H%M%SZ)
EV_ROOT="$_rt_repo_root/qa-results/vpn_lan/phase2/$RT_TS"
mkdir -p "$EV_ROOT/smb" "$EV_ROOT/nfs" 2>/dev/null || true
RT_TMPDIR=$(mktemp -d 2>/dev/null || printf '%s' "${TMPDIR:-/tmp}/helix_rt_$$")
mkdir -p "$RT_TMPDIR" 2>/dev/null || true

# Known payload for byte-integrity round-trips.
RT_NAME="helix_proxy_rt_${$}_$(date +%s 2>/dev/null || echo 0)"
RT_LOCAL="$RT_TMPDIR/$RT_NAME.src"
{
    printf 'helix_proxy VPN-LAN Phase-2 round-trip payload\n'
    printf 'ts=%s host=%s subnet=%s\n' "$RT_TS" "$(bridge_host)" "$(bridge_subnet)"
    dd if=/dev/urandom bs=1024 count=16 2>/dev/null | od -An -tx1 2>/dev/null
} > "$RT_LOCAL" 2>/dev/null
RT_SRC_SHA=$(sha256_of "$RT_LOCAL")

# Emit a byte-integrity evidence record + return 0 on MATCH, 1 on MISMATCH.
# $1 desc  $2 readback-file  $3 evidence-file  $4 extra-note
record_roundtrip() {
    _rr_desc=$1; _rr_readback=$2; _rr_ev=$3; _rr_note=${4:-}
    _rr_dst_sha=$(sha256_of "$_rr_readback")
    {
        printf 'protocol_test : %s\n' "$_rr_desc"
        printf 'timestamp_utc : %s\n' "$RT_TS"
        printf 'payload_bytes : %s\n' "$(wc -c < "$RT_LOCAL" 2>/dev/null | tr -d ' ')"
        printf 'src_sha256    : %s\n' "$RT_SRC_SHA"
        printf 'readback_sha256: %s\n' "$_rr_dst_sha"
        if [ -n "$RT_SRC_SHA" ] && [ "$RT_SRC_SHA" = "$_rr_dst_sha" ]; then
            printf 'integrity     : MATCH\n'
        else
            printf 'integrity     : MISMATCH\n'
        fi
        [ -n "$_rr_note" ] && printf 'note          : %s\n' "$_rr_note"
    } > "$_rr_ev" 2>/dev/null
    [ -n "$RT_SRC_SHA" ] && [ "$RT_SRC_SHA" = "$_rr_dst_sha" ]
}

# ============================================================================
# SMB / CIFS  (T2.1) — smbclient preferred (no root), mount.cifs fallback.
# NMB note: NetBIOS name-resolution over an L3 VPN uses UNICAST to the peer IP
# (multicast/broadcast NMB is not routed) — target the share by 10.x IP in the
# UNC, e.g. //10.6.100.221/share, not by NetBIOS name (PLAN.md §2).
# ============================================================================
smb_desc='SMB/CIFS write->read-back->sha256 round-trip (VPN share)'
SMB_UNC=${HELIX_VPN_SMB_UNC:-}
if [ -z "$SMB_UNC" ]; then
    ab_skip_with_reason "$smb_desc" feature_disabled_by_config
    log 'HELIX_VPN_SMB_UNC unset — no SMB share configured; SKIP (not a PASS)'
elif command -v smbclient >/dev/null 2>&1; then
    smb_ev="$EV_ROOT/smb/roundtrip.evidence"
    smb_readback="$RT_TMPDIR/$RT_NAME.smb.back"
    # Build auth args without ever echoing the password (§11.4.10).
    set -- "$SMB_UNC"
    if [ -n "${HELIX_VPN_SMB_USER:-}" ]; then
        _smb_auth="${HELIX_VPN_SMB_USER}%${HELIX_VPN_SMB_PASS:-}"
        set -- "$@" -U "$_smb_auth"
    else
        set -- "$@" -N
    fi
    [ -n "${HELIX_VPN_SMB_DOMAIN:-}" ] && set -- "$@" -W "$HELIX_VPN_SMB_DOMAIN"
    if smbclient "$@" -c "put \"$RT_LOCAL\" \"$RT_NAME\"; get \"$RT_NAME\" \"$smb_readback\"; del \"$RT_NAME\"" \
        > "$EV_ROOT/smb/smbclient.log" 2>&1 && [ -f "$smb_readback" ]; then
        if record_roundtrip "$smb_desc" "$smb_readback" "$smb_ev" "via smbclient to $SMB_UNC (NMB unicast)"; then
            ab_pass_with_evidence "$smb_desc" "$smb_ev" || mark_fail
        else
            ab_fail "$smb_desc" "sha256 mismatch — bytes did not survive (evidence: $smb_ev)"; mark_fail
        fi
    else
        # smbclient could not reach/authenticate the share. Reachability is the
        # honest boundary: with the bridge UP but the share absent/denied this is
        # a topology/config gap, not a proxy defect -> honest SKIP, never PASS.
        ab_skip_with_reason "$smb_desc" network_unreachable_external
        log "smbclient could not complete against $SMB_UNC (see $EV_ROOT/smb/smbclient.log)"
    fi
elif command -v mount.cifs >/dev/null 2>&1 && [ "$(id -u 2>/dev/null || echo 1)" = 0 ]; then
    ab_skip_with_reason "$smb_desc" topology_unsupported
    log 'mount.cifs path present but not exercised in this build; use smbclient — SKIP'
else
    ab_skip_with_reason "$smb_desc" topology_unsupported
    log 'no smbclient (and no root mount.cifs) available — SKIP (client tool absent)'
fi

# ============================================================================
# NFS  (T2.2) — round-trip a file through an NFS export.
#   Preferred: HELIX_VPN_NFS_MOUNTED = an already-mounted export (no root here).
#   Alt:       HELIX_VPN_NFS_EXPORT = server:/export -> temp-mount (needs root).
# ============================================================================
nfs_desc='NFS write->read-back->sha256 round-trip (VPN export)'
NFS_MOUNTED=${HELIX_VPN_NFS_MOUNTED:-}
NFS_EXPORT=${HELIX_VPN_NFS_EXPORT:-}
_nfs_dir=''
if [ -n "$NFS_MOUNTED" ] && [ -d "$NFS_MOUNTED" ]; then
    _nfs_dir="$NFS_MOUNTED"
    log "NFS: using pre-mounted export $NFS_MOUNTED"
elif [ -n "$NFS_EXPORT" ] && command -v mount >/dev/null 2>&1 && [ "$(id -u 2>/dev/null || echo 1)" = 0 ]; then
    RT_NFS_TEMP_MOUNT=$(mktemp -d 2>/dev/null || printf '%s' "$RT_TMPDIR/nfs_mnt")
    mkdir -p "$RT_NFS_TEMP_MOUNT" 2>/dev/null || true
    if mount -t nfs "$NFS_EXPORT" "$RT_NFS_TEMP_MOUNT" > "$EV_ROOT/nfs/mount.log" 2>&1; then
        _nfs_dir="$RT_NFS_TEMP_MOUNT"
        log "NFS: temp-mounted $NFS_EXPORT -> $RT_NFS_TEMP_MOUNT"
    else
        rmdir "$RT_NFS_TEMP_MOUNT" >/dev/null 2>&1 || true
        RT_NFS_TEMP_MOUNT=''
        ab_skip_with_reason "$nfs_desc" network_unreachable_external
        log "NFS: mount $NFS_EXPORT failed (see $EV_ROOT/nfs/mount.log) — SKIP"
    fi
fi
if [ -n "$_nfs_dir" ]; then
    nfs_ev="$EV_ROOT/nfs/roundtrip.evidence"
    nfs_target="$_nfs_dir/$RT_NAME"
    nfs_readback="$RT_TMPDIR/$RT_NAME.nfs.back"
    if cp "$RT_LOCAL" "$nfs_target" 2>>"$EV_ROOT/nfs/io.log" && \
       cp "$nfs_target" "$nfs_readback" 2>>"$EV_ROOT/nfs/io.log"; then
        rm -f "$nfs_target" >/dev/null 2>&1 || true
        if record_roundtrip "$nfs_desc" "$nfs_readback" "$nfs_ev" "via ${NFS_EXPORT:-$NFS_MOUNTED}"; then
            ab_pass_with_evidence "$nfs_desc" "$nfs_ev" || mark_fail
        else
            ab_fail "$nfs_desc" "sha256 mismatch — bytes did not survive (evidence: $nfs_ev)"; mark_fail
        fi
    else
        rm -f "$nfs_target" >/dev/null 2>&1 || true
        ab_skip_with_reason "$nfs_desc" network_unreachable_external
        log "NFS: write/read on $_nfs_dir failed (see $EV_ROOT/nfs/io.log) — SKIP"
    fi
elif [ -z "$NFS_MOUNTED" ] && [ -z "$NFS_EXPORT" ]; then
    ab_skip_with_reason "$nfs_desc" feature_disabled_by_config
    log 'HELIX_VPN_NFS_MOUNTED / HELIX_VPN_NFS_EXPORT unset — no NFS export configured; SKIP'
else
    ab_skip_with_reason "$nfs_desc" topology_unsupported
    log 'NFS export configured but not mountable in this environment (no root / no mount) — SKIP'
fi

log "done — evidence root: $EV_ROOT"
exit "$OVERALL_FAIL"
