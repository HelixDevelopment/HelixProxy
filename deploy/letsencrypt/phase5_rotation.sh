#!/usr/bin/env bash
# =============================================================================
# phase5_rotation.sh — LET'S ENCRYPT PHASE 5: renewal / rotation proof
# =============================================================================
# Purpose:
#   Prove — repeatably, with captured evidence — that Caddy RENEWS its cert via
#   the ACME renewal path (a genuine rotation to a NEW serial), and that the
#   renewal SWAP (old leaf -> new leaf) is ZERO-DOWNTIME. Builds on the proven
#   Phase-3 issuance (phase3_hermetic_issue.sh) then forces exactly one renewal.
#
# Why the storage-surgery trigger (FACT, docs/research/caddy_2110_ari_refetch_*):
#   Pebble serves ARI; certmagic v0.21.3 renews a cert when its cached ARI
#   `_selectedTime` is in the past, but caches ARI persistently (cert issuer_data,
#   Retry-After 6h) and re-fetches ONLY when NeedsRefresh() (Retry-After elapsed) —
#   neither `POST /load` NOR a Caddy >=2.11.0 bump forces a re-fetch (source-proven
#   NO-GO). The deterministic hermetic trigger is therefore: rewrite the cert's
#   cached ARI window (issuer_data.renewal_info.suggestedWindow + _selectedTime) to
#   the PAST in storage, then RESTART Caddy so it re-loads that past window from
#   storage -> the next maintenance tick renews via the ARI-window path. In
#   PRODUCTION this trigger is unnecessary — Caddy renews on its own schedule when
#   the cert genuinely nears expiry (zero-downtime). The restart here is TEST
#   SCAFFOLDING; the RENEWAL SWAP it induces is what this test measures for
#   zero-downtime (availability is probed AFTER the restart, across the swap).
#
# Usage:   bash deploy/letsencrypt/phase5_rotation.sh
#          KEEP_UP=1 bash deploy/letsencrypt/phase5_rotation.sh
#          CADDY_HTTPS_PORT=9443 CADDY_HTTP_PORT=9080 bash ...
#
# Outputs: qa-results/letsencrypt/phase5_rotation/<run-id>/{serials.txt,
#   swap_availability.txt,renew_log.txt,s2_analyzer_verdicts.txt,served_leaf_{1,2}.pem}
#   Exit 0 = PASS (rotation to a new serial + 0 dropped during the swap + analyzer
#   verifies S2), 1 = FAIL, 2 = OPERATOR-BLOCKED / precondition unmet.
#
# Side-effects: boots the hermetic stack (rootless podman-compose); tears down on
#   exit unless KEEP_UP=1. Never touches the base proxy stack or operator resources.
#
# Cross-references: phase3_hermetic_issue.sh · tests/letsencrypt/cert_analyzer.sh
#   · docs/research/caddy_2110_ari_refetch_20260701/ · Constitution §11.4.98/.107.
# =============================================================================

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "${SCRIPT_DIR}/../.." && pwd)
cd "${SCRIPT_DIR}"

CADDY_IMAGE="${CADDY_IMAGE:-localhost/helix_proxy/caddy-challtestsrv:2.8.4}"
TEST_HOSTNAME="${TEST_HOSTNAME:-proxy.hermetic.test}"
CAPS="nice -n 19 ionice -c 3"
RUNID=$(date -u +%Y%m%dT%H%M%SZ)
EVID="${REPO_ROOT}/qa-results/letsencrypt/phase5_rotation/${RUNID}"
mkdir -p "${EVID}"
HTTPS_PORT="${CADDY_HTTPS_PORT:-9443}"
META="/data/caddy/certificates/pebble-14000-dir/${TEST_HOSTNAME}/${TEST_HOSTNAME}.json"

log() { printf '[phase5 %s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }
serial_now() { echo | openssl s_client -connect "127.0.0.1:${HTTPS_PORT}" -servername "${TEST_HOSTNAME}" 2>/dev/null | openssl x509 -noout -serial 2>/dev/null | cut -d= -f2; }
leaf_now() { echo | openssl s_client -connect "127.0.0.1:${HTTPS_PORT}" -servername "${TEST_HOSTNAME}" 2>/dev/null | openssl x509 2>/dev/null; }

cleanup() {
	_rc=$?
	if [ "${KEEP_UP:-0}" = "1" ]; then log "KEEP_UP=1 — leaving stack up"; else
		log "tearing down"; podman-compose -f compose.hermetic.yml down -v >/dev/null 2>&1 || true
	fi
	exit "${_rc}"
}
trap cleanup EXIT INT TERM

# ---- 1. Issue S1 via the proven Phase-3 path (admin on for the reload) --------
command -v jq >/dev/null 2>&1 || { log "OPERATOR-BLOCKED: jq required"; exit 2; }
podman image exists "${CADDY_IMAGE}" 2>/dev/null || { log "OPERATOR-BLOCKED: image ${CADDY_IMAGE} missing — run ./build.sh"; exit 2; }
log "issuing S1 via phase3_hermetic_issue.sh"
KEEP_UP=1 CADDY_ADMIN=0.0.0.0:2019 CADDY_HTTPS_PORT="${HTTPS_PORT}" CADDY_HTTP_PORT="${CADDY_HTTP_PORT:-9080}" \
	bash "${SCRIPT_DIR}/phase3_hermetic_issue.sh" >"${EVID}/phase3_issue.log" 2>&1 \
	|| { log "FAIL: phase3 issuance failed (see ${EVID}/phase3_issue.log)"; exit 1; }
S1=$(serial_now); leaf_now >"${EVID}/served_leaf_1.pem"
[ -n "${S1}" ] || { log "FAIL: no S1 served"; exit 1; }
log "S1=${S1}"

# ---- 2. Storage surgery: rewrite the cached ARI window to the PAST ------------
# PHASE5_NO_SURGERY=1 SKIPS this — the deterministic renewal trigger is absent, so
# the restart below must NOT renew. The §11.4.135 guard's RED_MODE sets this and
# asserts the run FAILs at "no rotation", proving the surgery IS what triggers the
# renewal (not the restart alone).
if [ "${PHASE5_NO_SURGERY:-0}" = "1" ]; then
	log "PHASE5_NO_SURGERY=1 — skipping the ARI-window surgery (expect NO renewal)"
else
	log "rewriting cached ARI window (_selectedTime + suggestedWindow) to the past"
	podman exec letsencrypt-caddy sh -c "cat ${META}" >"${EVID}/issuer_data_before.json" 2>/dev/null \
		|| { log "FAIL: cannot read cert storage"; exit 1; }
	jq '.issuer_data.renewal_info.suggestedWindow.start="2026-01-01T00:00:00Z"
	  | .issuer_data.renewal_info.suggestedWindow.end="2026-01-01T01:00:00Z"
	  | .issuer_data.renewal_info._selectedTime="2026-01-01T00:30:00Z"' \
		"${EVID}/issuer_data_before.json" >"${EVID}/issuer_data_after.json"
	podman cp "${EVID}/issuer_data_after.json" letsencrypt-caddy:"${META}"
fi

# ---- 3. Restart Caddy so it re-loads the past window from storage -------------
log "restarting caddy (re-loads the past ARI window -> triggers renewal)"
podman restart letsencrypt-caddy >/dev/null 2>&1

# ---- 4. Wait for caddy to serve S1 again, THEN probe the SWAP for zero-downtime
log "waiting for caddy to serve again (post-restart), then measuring the renewal swap"
for _ in $(seq 1 30); do [ -n "$(serial_now)" ] && break; sleep 1; done
ok=0; fails=0; S2="${S1}"; when=""
for i in $(seq 1 60); do
	code=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 2 --resolve "${TEST_HOSTNAME}:${HTTPS_PORT}:127.0.0.1" "https://${TEST_HOSTNAME}:${HTTPS_PORT}/health" 2>/dev/null)
	[ "${code}" = "200" ] && ok=$((ok+1)) || fails=$((fails+1))
	cur=$(serial_now)
	if [ -n "${cur}" ] && [ "${cur}" != "${S1}" ]; then S2="${cur}"; when="t=${i}s"; break; fi
	sleep 1
done
podman logs letsencrypt-caddy 2>&1 | grep -iE 'needs renewal|renewing|renewed' >"${EVID}/renew_log.txt" 2>/dev/null || true
leaf_now >"${EVID}/served_leaf_2.pem"
{ echo "S1=${S1}"; echo "S2=${S2}"; echo "renewed_at=${when}"; echo "swap_availability ok=${ok} fails=${fails}"; } | tee "${EVID}/serials.txt" >"${EVID}/swap_availability.txt"

# ---- 5. Verdict: rotation + zero-downtime swap + analyzer verifies S2 ---------
if [ "${S2}" = "${S1}" ]; then log "FAIL: no rotation (serial unchanged) — see ${EVID}"; exit 1; fi
if [ "${fails}" -ne 0 ]; then log "FAIL: ${fails} dropped requests during the renewal swap (not zero-downtime)"; exit 1; fi
# analyzer over S2 vs this run's Pebble CA
curl -sk "https://127.0.0.1:15000/intermediates/0" -o "${EVID}/pebble_int0.pem" 2>/dev/null
curl -sk "https://127.0.0.1:15000/roots/0"         -o "${EVID}/pebble_root0.pem" 2>/dev/null
cat "${EVID}/pebble_int0.pem" "${EVID}/pebble_root0.pem" >"${EVID}/pebble_ca_bundle.pem"
# shellcheck source=/dev/null
. "${REPO_ROOT}/tests/letsencrypt/cert_analyzer.sh"
V_EXP=FAIL; V_SAN=FAIL; V_CHAIN=FAIL
cert_not_expired    "${EVID}/served_leaf_2.pem"                     && V_EXP=PASS
cert_san_matches    "${EVID}/served_leaf_2.pem" "${TEST_HOSTNAME}"  && V_SAN=PASS
cert_chain_roots_in "${EVID}/served_leaf_2.pem" "${EVID}/pebble_ca_bundle.pem" && V_CHAIN=PASS
NB1=$(openssl x509 -in "${EVID}/served_leaf_1.pem" -noout -startdate 2>/dev/null | cut -d= -f2)
NB2=$(openssl x509 -in "${EVID}/served_leaf_2.pem" -noout -startdate 2>/dev/null | cut -d= -f2)
{
	echo "rotation:            S1=${S1} -> S2=${S2} (${when})"
	echo "swap_zero_downtime:  ok=${ok} fails=${fails}"
	echo "S1_notBefore:        ${NB1}"
	echo "S2_notBefore:        ${NB2}"
	echo "cert_not_expired:    ${V_EXP}"
	echo "cert_san_matches:    ${V_SAN}"
	echo "cert_chain_roots_in: ${V_CHAIN} (S2 -> THIS-RUN Pebble CA)"
} | tee "${EVID}/s2_analyzer_verdicts.txt"
if [ "${V_EXP}" = PASS ] && [ "${V_SAN}" = PASS ] && [ "${V_CHAIN}" = PASS ]; then
	log "PASS — renewal rotation S1->S2 with 0 dropped during the swap; analyzer verifies S2. Evidence: ${EVID}"
	command -v ab_pass_with_evidence >/dev/null 2>&1 && ab_pass_with_evidence "LE Phase-5 renewal/rotation (zero-downtime swap)" "${EVID}/s2_analyzer_verdicts.txt" || true
	exit 0
fi
log "FAIL — analyzer did not verify S2 (see ${EVID})"
exit 1
