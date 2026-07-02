#!/bin/sh
#######################################################################
# §11.4.135 regression guard — BUGFIX-PORTS-34XXX
# Host-exposed proxy ports re-prefixed to the operator-mandated 34XXX scheme.
#
# Purpose:
#   Prove the canonical BEHAVIOR files carry the 34XXX ports and that NO old
#   5XXXX proxy port ever leaks back into the behavior scope. The operator
#   mandated the collision-free re-prefix:
#       HTTP proxy (Squid)   53128 -> 34128
#       SOCKS5   (Dante)     51080 -> 34080
#       Admin / Control-API  58080 -> 34088
#       Metrics  (Prometheus)59090 -> 34090
#   A stray 5XXXX in a config/compose/source/test file would silently bind or
#   probe the OLD port — the service would come up on a port nothing routes to
#   (a §11.4.108 SOURCE/ARTIFACT mismatch that a grep-of-one-file misses).
#
# What it actually does (NOT a fixed-pathspec grep — §11.4.120-hardened to a
# TREE-WIDE old-port scan that excludes only the historical-doc surface, AND
# asserts the positive presence of each new port on its owning canonical file,
# i.e. proves the re-prefix is BOTH complete AND landed):
#   GREEN — (a) ZERO occurrence of any old 5XXXX proxy port across the ENTIRE
#           tracked tree MINUS the doc surface (docs/**, *.md, *.pdf,
#           *README.html) — so a leak re-introduced in ANY new/unlisted
#           behavior path is caught, not just an enumerated dir set; AND (b)
#           each new port is present on its canonical anchor (squid.conf:34128,
#           sockd.conf:34080, .env.example:{34128,34080,34088,34090},
#           docker-compose admin :34088, prometheus.yml:34090, control-plane
#           DefaultProxy:34128).
#   RED   — synthesizes a faithful PRE-FIX fixture that plants a :53128 leak in
#           a NEW behavior path (services/other/leak.html) the OLD fixed pathspec
#           never scanned, plus a docs/ SQL-comment ref that MUST stay excluded,
#           then runs the SAME scanner: asserts it DETECTS the new-path leak
#           (gap closed) WITHOUT flagging the doc ref (no false-FAIL). A RED that
#           cannot reproduce, or that flags the doc ref, is itself a §11.4.7 /
#           §11.4.120 finding.
#
#   Self-contained + deterministic: uses `git grep` over the tracked tree +
#   a throwaway temp fixture; never touches the data plane or any container.
#
# §11.4.115 polarity switch (RED_MODE):
#   RED_MODE=0 (default GREEN guard) — PASS iff zero old-port leaks AND every
#              new-port anchor present.
#   RED_MODE=1 (reproduce) — PASS iff the old-port scanner flags a re-introduced
#              5XXXX port (regression genuinely caught).
#
# Usage:
#   tests/regression/port_prefix_34xxx_test.sh            # GREEN guard
#   RED_MODE=1 tests/regression/port_prefix_34xxx_test.sh # reproduce
#
# Inputs:   RED_MODE (env, default 0). No CLI args.
# Outputs:  PASS/FAIL verdict on stdout + an evidence file under
#           qa-results/regression/port_prefix_34xxx/. Exit 0 = PASS, 1 = FAIL.
# Side-effects: writes one temp fixture (removed on exit) + one evidence file.
#               No container/network access.
# Dependencies: git, grep, mktemp.
# Cross-references:
#   - Fix: .env.example / config/squid|dante|prometheus / docker-compose*.yml /
#     control-plane PAC + control-API defaults / runtime scripts / helixqa banks.
#   - Sibling guards: tests/regression/port_topology_aware_test.sh,
#     tests/regression/comprehensive_admin_topology_test.sh.
#######################################################################
set -eu

RED_MODE="${RED_MODE:-0}"
REPO_ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
EVID_DIR="$REPO_ROOT/qa-results/regression/port_prefix_34xxx"
mkdir -p "$EVID_DIR"
EVID_FILE="$EVID_DIR/port_prefix_34xxx.$$.txt"

# Old 5XXXX proxy ports that MUST NOT reappear in the behavior scope.
OLD_PORTS_RE='\b(53128|51080|58080|59090)\b'

# The tracked behavior scope = the WHOLE tree MINUS the historical-doc surface.
scan_old_ports() {
    # Args: $1 = git-tracked root to scan. Prints matching path:line:content;
    # exits 0 regardless (caller inspects the captured output, not the rc).
    #
    # §11.4.120 HARDENING (was a FIXED pathspec allowlist): the old allowlist
    # scanned only an enumerated dir set + services/admin/index.html, so a leak
    # re-introduced in ANY unlisted/NEW path (e.g. services/other/leak.html, a
    # new top-level behavior dir, a behavior *.conf/*.yml/*.sql/*.mermaid OUTSIDE
    # docs/) was git-visible but UNSCANNED — the GREEN zero-leak assertion would
    # silently miss it. This is now a TREE-WIDE scan that excludes ONLY the
    # historical-doc surface (another agent owns docs; docs/ legitimately carries
    # pre-migration 5XXXX port references — the audit confirmed the only
    # tree-wide hits are docs/**  [incl. docs/design/vpn_lan_access/schema.sql
    # SQL-comment + docs/diagrams/*.mermaid] and top-level/config *.md).
    #
    # Exclusions are PATH-based git pathspec magic, NOT a content-regex filter:
    #   docs            — whole doc subtree (its .md/.html/.pdf/.sql/.mermaid)
    #   *.md            — markdown is always doc, never behavior (CHANGELOG.md,
    #                     config/**/DNS_LEAK_TEST.md, squid-exporter.md, README.md)
    #   *.pdf           — rendered doc siblings
    #   *README.html    — rendered README doc at any depth (e.g. the
    #                     config/security/README.html the old filter named)
    #   this guard file — it embeds the 5XXXX regex + mapping in its own source.
    # Path-based (not a `grep -vE '\.md:'` on the joined line) so a ".md:" that
    # happens to appear inside a BEHAVIOR file's CONTENT can never drop a real
    # leak. NOTE: services/admin/index.html + any non-README behavior *.html +
    # any *.sql/*.mermaid OUTSIDE docs/ STAY in scope (leak vectors per the
    # finding); only the doc surface above is removed.
    git -C "$1" grep -nE "$OLD_PORTS_RE" -- \
        '.' \
        ':(exclude)docs' \
        ':(exclude)*.md' \
        ':(exclude)*.pdf' \
        ':(exclude)*README.html' \
        ':(exclude)tests/regression/port_prefix_34xxx_test.sh' \
        2>/dev/null \
        || true
}

verdict=FAIL
exit_code=1

if [ "$RED_MODE" = "1" ]; then
    # Faithful PRE-FIX replica that ALSO exercises the §11.4.120 hardening: the
    # throwaway tree plants a 5XXXX leak in services/other/leak.html — a NEW
    # behavior path the OLD fixed-pathspec allowlist NEVER scanned (proving the
    # gap the tree-wide scan closes) — AND a docs/ SQL-comment 5XXXX ref that
    # MUST stay excluded (proving the doc-exclusion does not false-FAIL).
    FIX_DIR="$(mktemp -d)"
    trap 'rm -rf "$FIX_DIR"' EXIT INT TERM
    mkdir -p "$FIX_DIR/services/other" "$FIX_DIR/config/squid" \
             "$FIX_DIR/docs/design/vpn_lan_access"
    printf 'http_port 0.0.0.0:34128\n' > "$FIX_DIR/config/squid/squid.conf"   # clean anchor
    printf '<html>admin panel :53128</html>\n' > "$FIX_DIR/services/other/leak.html"  # NEW-path leak
    printf -- '-- legacy: squid bound :53128 pre-migration\n' \
        > "$FIX_DIR/docs/design/vpn_lan_access/schema.sql"                    # doc — must NOT flag
    ( cd "$FIX_DIR" && git init -q && git add -A && git -c user.email=g@g -c user.name=g commit -qm x ) >/dev/null 2>&1
    red_hits="$(scan_old_ports "$FIX_DIR")"
    red_n="$(printf '%s' "$red_hits" | grep -c . || true)"
    red_doc_leak="$(printf '%s' "$red_hits" | grep -c 'schema\.sql' || true)"
    if [ "$red_n" -gt 0 ] && [ "$red_doc_leak" -eq 0 ]; then
        verdict=PASS; exit_code=0
        msg="RED reproduced: tree-wide scanner DETECTS a 5XXXX leak in a NEW behavior path (services/other/leak.html, $red_n hit) that the old fixed pathspec MISSED, AND leaves the docs/ SQL-comment ref excluded — genuine detector + no doc false-FAIL"
    elif [ "$red_doc_leak" -ne 0 ]; then
        msg="RED doc-exclusion BROKEN: scanner flagged the docs/ schema.sql ref — the guard would false-FAIL on legitimate history (§11.4.120 weakening/false-FAIL)"
    else
        msg="RED could-not-reproduce: scanner missed a planted NEW-path :53128 leak — finding per §11.4.7 (GREEN zero-leak would be a bluff)"
    fi
    scan_report="$red_hits"
else
    # GREEN: (a) zero old-port leaks across the real tracked behavior scope.
    leaks="$(scan_old_ports "$REPO_ROOT")"
    n_leaks="$(printf '%s' "$leaks" | grep -c . || true)"

    # (b) each new port present on its canonical anchor.
    anchors_ok=yes
    anchor_detail=""
    check_anchor() { # $1 file  $2 fixed-grep-pattern  $3 label
        if git -C "$REPO_ROOT" grep -qF "$2" -- "$1"; then
            anchor_detail="${anchor_detail}OK  $3\n"
        else
            anchors_ok=no
            anchor_detail="${anchor_detail}MISS $3 (expected '$2' in $1)\n"
        fi
    }
    check_anchor 'config/squid/squid.conf'              'http_port 0.0.0.0:34128'          'squid http_port 34128'
    check_anchor 'config/dante/sockd.conf'              'port = 34080'                     'dante internal 34080'
    check_anchor '.env.example'                         'HTTP_PROXY_PORT=34128'            'env HTTP_PROXY_PORT 34128'
    check_anchor '.env.example'                         'SOCKS_PROXY_PORT=34080'           'env SOCKS_PROXY_PORT 34080'
    check_anchor '.env.example'                         'PROXY_ADMIN_PORT=34088'           'env PROXY_ADMIN_PORT 34088'
    check_anchor '.env.example'                         'CONTROL_API_ADDR=:34088'          'env CONTROL_API_ADDR :34088'
    check_anchor '.env.example'                         'METRICS_PORT=34090'               'env METRICS_PORT 34090'
    check_anchor 'docker-compose.yml'                   '"-port", "34088"'                 'compose admin -port 34088'
    check_anchor 'config/prometheus/prometheus.yml'     'proxy-control-plane:34090'        'prometheus scrape 34090'
    check_anchor 'control-plane/internal/pac/generate.go' 'PROXY proxy-squid:34128'        'PAC DefaultProxy 34128'
    check_anchor 'control-plane/cmd/api/main.go'        'CONTROL_API_ADDR", ":34088"'      'control-API default :34088'

    if [ "$n_leaks" -eq 0 ] && [ "$anchors_ok" = yes ]; then
        verdict=PASS; exit_code=0
        msg="GREEN: zero old 5XXXX proxy-port leaks in behavior scope AND every 34XXX anchor present"
    elif [ "$n_leaks" -ne 0 ]; then
        msg="REGRESSION: $n_leaks old 5XXXX proxy-port leak(s) re-appeared in behavior scope — see scan_report"
    else
        msg="REGRESSION: a 34XXX new-port anchor is missing — the re-prefix is incomplete (see anchors)"
    fi
    scan_report="$leaks"
fi

{
    echo "BUGFIX-PORTS-34XXX regression guard — §11.4.135 + §11.4.115 (host-port re-prefix)"
    echo "timestamp_utc: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "RED_MODE: $RED_MODE"
    echo "mapping: 53128->34128  51080->34080  58080->34088  59090->34090"
    echo "verdict: $verdict"
    echo "detail: $msg"
    if [ "$RED_MODE" != "1" ]; then
        echo "--- anchors ---"
        printf '%b' "${anchor_detail:-}"
    fi
    echo "--- old-port scan output (empty on GREEN, one planted hit on RED) ---"
    printf '%s\n' "${scan_report:-}"
} >"$EVID_FILE"

echo "[$verdict] BUGFIX-PORTS-34XXX host-port re-prefix (RED_MODE=$RED_MODE): $msg"
echo "evidence: $EVID_FILE"
exit "$exit_code"
