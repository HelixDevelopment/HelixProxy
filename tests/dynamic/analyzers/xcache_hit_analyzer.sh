#!/usr/bin/env bash
# =============================================================================
# xcache_hit_analyzer.sh — signal 4: a real Squid cache HIT (X-Cache + TCP_HIT)
# -----------------------------------------------------------------------------
# Signal:       caching preserved under dynamic mode (§11.4.69 storage_read;
#               design §13 cache_hit; research §2).
# Oracle:       A 2nd request for a cacheable URL must produce a HIT. The
#               DECISIVE data-plane fact is the Squid access.log carrying a
#               URL-specific TCP_*HIT result code (a header alone is forgeable —
#               evidence.sh:240). Delegates that to the COMMITTED, self-tested
#               evidence.sh:assert_cache_hit, AND — when a captured response-
#               header dump is supplied — additionally requires it to corroborate
#               with `X-Cache: HIT` (defense in depth; a header that says MISS
#               while the log says HIT is contradictory evidence -> FAIL).
# golden-good:  access.log TCP_HIT for the URL + X-Cache: HIT header -> PASS.
# golden-BAD:   always-MISS log (+ X-Cache: MISS) -> MUST FAIL.
# Manifest:     key=val text file:
#                 access_log=access_hit.log     (resolved relative to manifest)
#                 url=http://cdn.example.com/static/app.css
#                 headers_file=headers_hit.txt  (optional corroboration)
# Usage:        xcache_hit_analyzer.sh analyze <manifest-file>
#               xcache_hit_analyzer.sh --selftest        (default action)
# Output:       PASS:/FAIL: verdict; rc 0 = PASS, 1 = FAIL.
# Anti-bluff:   timing-is-faster is NOT a cache fact (the named B2 bluff); a
#               result code in the access.log is the data-plane corroboration.
# Shell:        POSIX-clean (sh -n + bash -n, §11.4.67).
# Cross-refs:   §11.4.69 / §11.4.107 / §11.4.115; tests/lib/evidence.sh:240.
# =============================================================================
_ANZ_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=/dev/null
. "$_ANZ_DIR/../lib/analyzer_common.sh"
_FIX="$_ANZ_DIR/fixtures/xcache_hit"

_xc_manifest_get() {
    awk -F= -v k="$2" '$1 == k { sub(/^[^=]*=/, ""); print; exit }' "$1" 2>/dev/null
}

# analyze_xcache_hit <manifest-file>
analyze_xcache_hit() {
    manifest=$1
    if [ -z "$manifest" ] || [ ! -f "$manifest" ]; then
        ac_fail "xcache_hit" "[reason: manifest missing: ${manifest:-<none>}]"
        return 1
    fi
    if [ "$AC_EVIDENCE_AVAILABLE" != "1" ]; then
        ac_fail "xcache_hit" "[reason: committed tests/lib/evidence.sh not found — cannot delegate]"
        return 1
    fi
    mdir=$(cd "$(dirname "$manifest")" && pwd)
    log=$(_xc_manifest_get "$manifest" access_log)
    url=$(_xc_manifest_get "$manifest" url)
    hdr=$(_xc_manifest_get "$manifest" headers_file)
    case "$log" in /*) : ;; *) log="$mdir/$log" ;; esac

    # Decisive check: a URL-specific TCP_*HIT in the access.log.
    if ! assert_cache_hit "$log" "$url" >/dev/null 2>&1; then
        # Re-run to surface the canonical FAIL line, then return its rc.
        assert_cache_hit "$log" "$url"
        return 1
    fi

    # Optional corroboration: the captured X-Cache response header must be HIT.
    if [ -n "$hdr" ]; then
        case "$hdr" in /*) : ;; *) hdr="$mdir/$hdr" ;; esac
        if [ ! -f "$hdr" ]; then
            ac_fail "xcache_hit" "[reason: declared headers_file missing: $hdr]"
            return 1
        fi
        # Must contain an X-Cache header line whose value is a HIT.
        if ! grep -Eiq '^[[:space:]]*X-Cache:.*HIT' "$hdr" 2>/dev/null; then
            ac_fail "xcache_hit" "[reason: access.log shows TCP_HIT but X-Cache header is not HIT ($hdr) — contradictory evidence]"
            return 1
        fi
    fi

    ab_pass_with_evidence "xcache_hit ($url -> TCP_HIT + X-Cache:HIT)" "$log"
}

_selftest_xcache_hit() {
    ac_selftest_reset
    printf '# xcache_hit_analyzer self-test\n'
    ac_expect 0 "golden-good: TCP_HIT in log + X-Cache:HIT header -> PASS" \
        -- analyze_xcache_hit "$_FIX/golden_good.manifest"
    ac_expect 1 "golden-BAD: always-MISS log (+ X-Cache:MISS) -> FAIL" \
        -- analyze_xcache_hit "$_FIX/golden_bad_allmiss.manifest"
    ac_expect 1 "golden-BAD: log HIT but X-Cache header MISS (contradiction) -> FAIL" \
        -- analyze_xcache_hit "$_FIX/golden_bad_header_contradicts.manifest"
    ac_expect 1 "golden-BAD: url present but only MISS for that url -> FAIL" \
        -- analyze_xcache_hit "$_FIX/golden_bad_url_miss_only.manifest"
    ac_expect 1 "negative: missing manifest -> FAIL" \
        -- analyze_xcache_hit "$_FIX/does_not_exist.manifest"
    ac_selftest_summary "xcache_hit_analyzer"
}

case "${1:-}" in
    analyze) shift; analyze_xcache_hit "$@" ;;
    --selftest|selftest|"") _selftest_xcache_hit ;;
    *) analyze_xcache_hit "$@" ;;
esac
