#!/usr/bin/env bash
# =============================================================================
# phase3_hermetic_issue.sh — LET'S ENCRYPT PHASE 3: hermetic DNS-01 issuance
# =============================================================================
# Purpose:
#   Prove — repeatably, from a clean slate, with captured physical evidence —
#   that the custom Caddy image obtains a REAL TLS certificate via the ACME
#   DNS-01 challenge against a LOCAL Pebble ACME server, fully offline, and that
#   the project's cert-analyzer verifies the issued cert (validity + SAN + that
#   the served leaf cryptographically chains to THIS RUN's Pebble CA). No bluff:
#   Pebble runs with PEBBLE_VA_ALWAYS_VALID=0 (a genuine DNS-01 validation), and
#   the PASS is gated on the analyzer verdicts over the leaf Caddy actually served.
#
# Why CoreDNS is in the stack (design-gap fix, 2026-07-01):
#   certmagic's DNS-01 flow determines the DNS zone via an SOA walk BEFORE it
#   presents the TXT. challtestsrv answers NOTIMP to SOA (no authoritative mode),
#   which blocked issuance ("could not determine zone ... NOTIMP"). CoreDNS is
#   inserted as an authoritative SOA front for hermetic.test: its `template`
#   plugin answers the SOA (in the ANSWER section, owner = the zone apex, so
#   certmagic accepts hermetic.test as the zone) and falls through (`forward`) to
#   challtestsrv for the dynamic _acme-challenge TXT. CoreDNS `forward` needs an
#   IP (not a name), so this script rewrites ./coredns/Corefile with challtestsrv's
#   live pod IP before starting CoreDNS. Caddy's ACME_RESOLVERS points at
#   coredns:53 (name-resolved); Pebble queries challtestsrv:8053 directly (it does
#   no SOA walk). Root-cause + upstream refs: docs/research/letsencrypt_hermetic_*/
#   and docs/research/certmagic_chain_panic_20260701/ (the boot ordering here also
#   avoids certmagic bug #354 — Pebble is healthy BEFORE Caddy, /data is fresh).
#
# Usage:
#   bash deploy/letsencrypt/phase3_hermetic_issue.sh
#   KEEP_UP=1 bash deploy/letsencrypt/phase3_hermetic_issue.sh   # leave stack up (Phase-5)
#   CADDY_HTTPS_PORT=9443 CADDY_HTTP_PORT=9080 bash ...          # override ports
#
# Inputs (env, optional):
#   CADDY_HTTPS_PORT / CADDY_HTTP_PORT  host ports (auto-picks a free pair if unset
#                                       or if the default is busy)
#   KEEP_UP=1   do NOT tear the stack down on exit (for Phase-5 rotation testing)
#   TEST_HOSTNAME  cert subject (default proxy.hermetic.test)
#
# Outputs:
#   qa-results/letsencrypt/phase3_issuance/<run-id>/{served_leaf.pem,
#   pebble_ca_bundle.pem,served_leaf_summary.txt,cert_analyzer_verdicts.txt,
#   caddy_issuance.log}. Exit 0 = PASS (real cert issued + all verdicts PASS),
#   1 = FAIL (product defect), 2 = OPERATOR-BLOCKED / precondition unmet.
#
# Side-effects:
#   Boots the hermetic Pebble+challtestsrv+CoreDNS+Caddy stack via podman-compose
#   (rootless, §11.4.161) — HIGH ports only, loopback-bound (§ security M1). Tears
#   it down on exit unless KEEP_UP=1. Never touches the base proxy stack or any
#   operator resource.
#
# Dependencies: podman + podman-compose (rootless); openssl; curl; the built image
#   localhost/helix_proxy/caddy-challtestsrv:<ver> (run ./build.sh first);
#   tests/letsencrypt/cert_analyzer.sh; ghcr.io/letsencrypt/pebble{,-challtestsrv}
#   + docker.io/coredns/coredns (pulled on first run).
#
# Cross-references: build.sh · compose.hermetic.yml · Caddyfile · coredns/Corefile
#   · tests/letsencrypt/cert_analyzer.sh · docs/design/letsencrypt/Status.md
#   · Constitution §11.4.98 (re-runnable) · §11.4.107 (real-evidence) · §11.4.108.
# =============================================================================

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "${SCRIPT_DIR}/../.." && pwd)
cd "${SCRIPT_DIR}"

CADDY_IMAGE="${CADDY_IMAGE:-localhost/helix_proxy/caddy-challtestsrv:2.8.4}"
TEST_HOSTNAME="${TEST_HOSTNAME:-proxy.hermetic.test}"
PEBBLE_IMAGE="${PEBBLE_IMAGE:-ghcr.io/letsencrypt/pebble:2.6.0}"
COMPOSE="podman-compose -f compose.hermetic.yml"
# §11.4.1/§11.4.3: bound every container boot so a rootless-podman networking
# failure (aardvark-dns/netavark unable to bind :53 on the netavark gateway —
# "Cannot assign requested address", seen when stale podman networks accumulate)
# becomes an HONEST SKIP, never an infinite suite hang and never a fake PASS.
BOOT_TIMEOUT="${LE_BOOT_TIMEOUT:-60}"
CAPS="nice -n 19 ionice -c 3"
RUNID=$(date -u +%Y%m%dT%H%M%SZ)
EVID="${REPO_ROOT}/qa-results/letsencrypt/phase3_issuance/${RUNID}"
mkdir -p "${EVID}"

log() { printf '[phase3 %s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }

port_free() { ! ss -ltn 2>/dev/null | grep -q ":$1 "; }
pick_port() { # echo first free port from the args
	for _p in "$@"; do port_free "$_p" && { echo "$_p"; return 0; }; done
	return 1
}

# ---- Preconditions (§11.4.6 — verify, do not assume) -------------------------
if ! command -v podman-compose >/dev/null 2>&1; then
	log "OPERATOR-BLOCKED: podman-compose not on PATH"; exit 2
fi
if ! podman image exists "${CADDY_IMAGE}" 2>/dev/null; then
	log "OPERATOR-BLOCKED: image ${CADDY_IMAGE} missing — run ./build.sh first"; exit 2
fi
if [ ! -f "${REPO_ROOT}/tests/letsencrypt/cert_analyzer.sh" ]; then
	log "OPERATOR-BLOCKED: cert_analyzer.sh missing"; exit 2
fi

CADDY_HTTPS_PORT="${CADDY_HTTPS_PORT:-$(pick_port 8443 9443 18443 28443 || echo '')}"
CADDY_HTTP_PORT="${CADDY_HTTP_PORT:-$(pick_port 8080 9080 18080 28080 || echo '')}"
if [ -z "${CADDY_HTTPS_PORT}" ] || [ -z "${CADDY_HTTP_PORT}" ]; then
	log "OPERATOR-BLOCKED: no free host port pair for caddy"; exit 2
fi
export CADDY_IMAGE CADDY_HTTPS_PORT CADDY_HTTP_PORT TEST_HOSTNAME
log "run ${RUNID} · caddy https=${CADDY_HTTPS_PORT} http=${CADDY_HTTP_PORT} · host=${TEST_HOSTNAME}"

# ---- Cleanup (§11.4.14) ------------------------------------------------------
cleanup() {
	_rc=$?
	if [ "${KEEP_UP:-0}" = "1" ]; then
		log "KEEP_UP=1 — leaving stack up for Phase-5"
	else
		log "tearing down hermetic stack"
		timeout 45 ${COMPOSE} down -v >/dev/null 2>&1 || true
	fi
	exit "${_rc}"
}
trap cleanup EXIT INT TERM

# compose_up_or_skip <service...> — boot with a timeout. A rootless-podman
# networking failure (aardvark-dns/netavark bind error) or a >BOOT_TIMEOUT hang
# is an HONEST SKIP (§11.4.3 infra/topology unsupported — exit 2 OPERATOR-BLOCKED,
# which the harness scores as SKIP), NEVER an infinite hang and NEVER a fake PASS.
compose_up_or_skip() {
	# Secure temp only — a predictable /tmp/<pid> fallback is a symlink-attack
	# vector (an attacker pre-creating that path would redirect our '>' write).
	_bl=$(mktemp 2>/dev/null) || _bl=""
	if [ -z "${_bl}" ]; then
		log "OPERATOR-BLOCKED: mktemp unavailable for boot log — honest SKIP §11.4.3"; exit 2
	fi
	# `|| _rc=$?` keeps set -e from aborting on the timeout's 124 before we can
	# classify it — the whole point is to convert that failure into a SKIP.
	_rc=0
	timeout "${BOOT_TIMEOUT}" ${CAPS} ${COMPOSE} up -d "$@" >"${_bl}" 2>&1 || _rc=$?
	if [ "${_rc}" = 124 ] || grep -qiE 'aardvark-dns|netavark|Cannot assign requested address|failed to bind udp listener|error from child process' "${_bl}" 2>/dev/null; then
		log "OPERATOR-BLOCKED: rootless podman could not boot [$*] — aardvark-dns/netavark networking failure or ${BOOT_TIMEOUT}s timeout (honest SKIP §11.4.3; see ${_bl})"
		exit 2
	fi
	rm -f "${_bl}" 2>/dev/null || true
	return 0
}

# ---- 0. clean slate ----------------------------------------------------------
log "clean teardown (fresh caddy /data — avoids certmagic #354)"
timeout 45 ${COMPOSE} down -v >/dev/null 2>&1 || true
podman rm -f le-coredns-test >/dev/null 2>&1 || true

# ---- 1. materialize Pebble's public minica (CA #1, trust anchor) -------------
log "materialize pebble.minica.pem"
mkdir -p pebble-ca
_cid=$(podman create "${PEBBLE_IMAGE}" 2>/dev/null)
podman cp "${_cid}:/test/certs/pebble.minica.pem" ./pebble-ca/pebble.minica.pem 2>/dev/null || true
podman rm "${_cid}" >/dev/null 2>&1 || true
openssl x509 -in pebble-ca/pebble.minica.pem -noout -subject >/dev/null 2>&1 \
	|| { log "FAIL: could not extract pebble.minica.pem"; exit 1; }

# ---- 2. boot pebble + challtestsrv, resolve challtestsrv IP ------------------
log "boot pebble + challtestsrv"
compose_up_or_skip pebble challtestsrv
_chip=""
for _i in $(seq 1 30); do
	_chip=$(podman inspect letsencrypt-challtestsrv \
		--format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' 2>/dev/null || true)
	[ -n "${_chip}" ] && break; sleep 1
done
[ -n "${_chip}" ] || { log "OPERATOR-BLOCKED: challtestsrv has no IP after boot (rootless networking) — honest SKIP §11.4.3"; exit 2; }
log "challtestsrv IP=${_chip}"

# ---- 3. write CoreDNS Corefile with the live forward IP + boot CoreDNS -------
log "write coredns/Corefile (SOA in ANSWER, forward TXT -> ${_chip}:8053)"
mkdir -p coredns
cat > coredns/Corefile <<COREFILE
# Generated by phase3_hermetic_issue.sh. Authoritative SOA front for
# hermetic.test so certmagic's DNS-01 zone-determination SOA-walk succeeds;
# forward everything else (the dynamic _acme-challenge TXT) to challtestsrv.
hermetic.test:53 {
    template IN SOA hermetic.test {
        answer "hermetic.test. 60 IN SOA ns.hermetic.test. admin.hermetic.test. 1 60 60 60 60"
        fallthrough
    }
    forward . ${_chip}:8053
    log
    errors
}
COREFILE
compose_up_or_skip coredns

# ---- 4. wait for the Pebble ACME directory (host gate) -----------------------
log "wait for pebble ACME directory"
_ok=0
for _i in $(seq 1 30); do
	curl -sk "https://127.0.0.1:14000/dir" >/dev/null 2>&1 && { _ok=1; break; }; sleep 1
done
[ "${_ok}" = "1" ] || { log "FAIL: pebble /dir not ready"; exit 1; }

# ---- 5. boot caddy (fresh) — issuance triggers on start ----------------------
log "boot caddy — real DNS-01 issuance begins"
compose_up_or_skip caddy

# ---- 6. poll for the served leaf with the expected SAN ----------------------
log "poll caddy :${CADDY_HTTPS_PORT} for the issued cert (up to 90s)"
_got=0
for _i in $(seq 1 45); do
	echo | openssl s_client -connect "127.0.0.1:${CADDY_HTTPS_PORT}" \
		-servername "${TEST_HOSTNAME}" 2>/dev/null \
		| openssl x509 -outform PEM > "${EVID}/served_leaf.pem" 2>/dev/null || true
	if openssl x509 -in "${EVID}/served_leaf.pem" -noout -ext subjectAltName 2>/dev/null \
		| grep -q "DNS:${TEST_HOSTNAME}"; then _got=1; break; fi
	sleep 2
done
podman logs letsencrypt-caddy > "${EVID}/caddy_issuance.log" 2>&1 || true
if [ "${_got}" != "1" ]; then
	log "FAIL: no cert with SAN ${TEST_HOSTNAME} served within timeout"
	grep -iE 'error|panic|zone|refused' "${EVID}/caddy_issuance.log" | tail -8 || true
	exit 1
fi
log "served leaf captured"

# ---- 7. fetch THIS RUN's Pebble issuance CA (regenerated every boot) ---------
curl -sk "https://127.0.0.1:15000/intermediates/0" -o "${EVID}/pebble_int0.pem" 2>/dev/null
curl -sk "https://127.0.0.1:15000/roots/0"         -o "${EVID}/pebble_root0.pem" 2>/dev/null
cat "${EVID}/pebble_int0.pem" "${EVID}/pebble_root0.pem" > "${EVID}/pebble_ca_bundle.pem"

openssl x509 -in "${EVID}/served_leaf.pem" -noout -issuer -dates -ext subjectAltName \
	> "${EVID}/served_leaf_summary.txt" 2>/dev/null || true

# ---- 8. cert-analyzer verdicts over the REAL issued cert (anti-bluff gate) ---
log "cert-analyzer verdicts"
# shellcheck source=/dev/null
. "${REPO_ROOT}/tests/letsencrypt/cert_analyzer.sh"
LEAF="${EVID}/served_leaf.pem"; CA="${EVID}/pebble_ca_bundle.pem"
V_EXP=FAIL; V_SAN=FAIL; V_NEG=FAIL; V_CHAIN=FAIL
cert_not_expired          "${LEAF}"                        && V_EXP=PASS
cert_san_matches          "${LEAF}" "${TEST_HOSTNAME}"     && V_SAN=PASS
cert_san_matches          "${LEAF}" evil.example.invalid   || V_NEG=PASS
cert_chain_roots_in       "${LEAF}" "${CA}"                && V_CHAIN=PASS
DAYS=$(cert_days_remaining "${LEAF}" 2>/dev/null || echo '?')
{
	echo "run:                 ${RUNID}"
	echo "hostname:            ${TEST_HOSTNAME}"
	echo "issuer:              $(openssl x509 -in "${LEAF}" -noout -issuer 2>/dev/null)"
	echo "cert_not_expired:    ${V_EXP}"
	echo "cert_days_remaining: ${DAYS}"
	echo "cert_san_matches:    ${V_SAN} (${TEST_HOSTNAME})"
	echo "cert_san_negative:   ${V_NEG} (must reject evil.example.invalid)"
	echo "cert_chain_roots_in: ${V_CHAIN} (leaf -> THIS-RUN Pebble CA)"
} | tee "${EVID}/cert_analyzer_verdicts.txt"

# ---- 9. verdict --------------------------------------------------------------
if [ "${V_EXP}" = PASS ] && [ "${V_SAN}" = PASS ] && [ "${V_NEG}" = PASS ] && [ "${V_CHAIN}" = PASS ]; then
	log "PASS — real hermetic DNS-01 cert issued + verified. Evidence: ${EVID}"
	# Prefer the project's evidence helper when available (§11.4.69).
	if command -v ab_pass_with_evidence >/dev/null 2>&1; then
		ab_pass_with_evidence "LE Phase-3 hermetic DNS-01 issuance" "${EVID}/cert_analyzer_verdicts.txt" || true
	fi
	exit 0
fi
log "FAIL — one or more cert-analyzer verdicts did not PASS (see ${EVID})"
exit 1
