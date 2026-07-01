#!/bin/sh
# =============================================================================
# phase5_rotation_guard.sh — §11.4.135 standing guard for LE Phase-5 renewal
# =============================================================================
# Purpose:
#   Wrap deploy/letsencrypt/phase5_rotation.sh with a §11.4.115 RED_MODE polarity.
#   GREEN (RED_MODE=0): a real renewal rotation (S1->S2, new serial) happens with
#   0 dropped requests across the swap and cert-analyzer verifies S2 -> PASS.
#   RED (RED_MODE=1): the same run with PHASE5_NO_SURGERY=1 (the deterministic ARI
#   trigger removed) MUST NOT renew -> phase5 exits non-0 -> the guard PASSes,
#   proving the ARI-window surgery is what triggers the renewal (not the restart).
#
# Boots the hermetic stack (conductor-owned, §11.4.119) — 3-way exit:
#   0 = PASS, 2 = topology SKIP (built image / podman-compose absent, §11.4.3),
#   else FAIL. Registered in tests/run-tests.sh test_regression_guards().
#
# Usage:  sh tests/letsencrypt/phase5_rotation_guard.sh
#         RED_MODE=1 sh tests/letsencrypt/phase5_rotation_guard.sh
# Caps:   GOMAXPROCS=2 nice -n 19 ionice -c 3 (self-applied around phase5).
# =============================================================================
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "${SCRIPT_DIR}/../.." && pwd)
PHASE5="${REPO_ROOT}/deploy/letsencrypt/phase5_rotation.sh"
IMG="${CADDY_IMAGE:-localhost/helix_proxy/caddy-challtestsrv:2.8.4}"

# ---- topology preconditions (§11.4.3 honest SKIP, never a fake pass) ----------
if ! command -v podman-compose >/dev/null 2>&1 || ! command -v podman >/dev/null 2>&1; then
	echo "[SKIP] phase5-rotation guard: podman/podman-compose absent (§11.4.3)"; exit 2
fi
if ! podman image exists "${IMG}" 2>/dev/null; then
	echo "[SKIP] phase5-rotation guard: image ${IMG} not built (run deploy/letsencrypt/build.sh) (§11.4.3)"; exit 2
fi
if [ ! -x "${PHASE5}" ]; then
	echo "[SKIP] phase5-rotation guard: ${PHASE5} missing (§11.4.3)"; exit 2
fi

CAP="nice -n 19 ionice -c 3"
export GOMAXPROCS=2

if [ "${RED_MODE:-0}" = "1" ]; then
	# RED: remove the ARI-window surgery -> renewal MUST NOT fire -> phase5 non-0.
	if PHASE5_NO_SURGERY=1 ${CAP} sh "${PHASE5}" >/dev/null 2>&1; then
		echo "[FAIL] phase5-rotation RED: renewal happened WITHOUT the ARI surgery — §11.4.7"; exit 1
	fi
	echo "[PASS] phase5-rotation RED reproduces: no surgery => no renewal (the surgery is the trigger)"; exit 0
fi

# GREEN: a real renewal rotation with a zero-downtime swap + analyzer-verified S2.
if ${CAP} sh "${PHASE5}" >/dev/null 2>&1; then
	echo "[PASS] phase5-rotation GREEN: real renewal S1->S2, 0 dropped across the swap, analyzer verifies S2"; exit 0
fi
echo "[FAIL] phase5-rotation GREEN: run: bash deploy/letsencrypt/phase5_rotation.sh"; exit 1
