#!/usr/bin/env sh
# =============================================================================
# build.sh — build the custom hermetic Caddy image (rootless Podman)
# =============================================================================
# Purpose:
#   Build the custom Caddy container image that embeds the local DNS-01 provider
#   module (dns.providers.challtestsrv) via xcaddy, so Caddy can solve ACME
#   DNS-01 against pebble-challtestsrv fully offline (ANALYSIS.md Option A). This
#   is the image referenced by compose.hermetic.yml's `caddy` service (CADDY_IMAGE).
#
# Usage:
#   ./build.sh                 # build with pinned defaults, rootless podman
#   CADDY_VERSION=2.8.4 ./build.sh
#   IMAGE_TAG=localhost/helix_proxy/caddy-challtestsrv:2.8.4 ./build.sh
#   DRY_RUN=1 ./build.sh       # print the build command, do not execute
#
# Inputs (env, all optional — pinned defaults per §11.4.6):
#   CADDY_VERSION  Caddy version xcaddy targets + base image tag   (default 2.8.4)
#   IMAGE_NAME     image repo (no tag)   (default localhost/helix_proxy/caddy-challtestsrv)
#   IMAGE_TAG      full image ref        (default ${IMAGE_NAME}:${CADDY_VERSION})
#   CONTAINER_ENGINE  podman|docker      (default podman — rootless, §11.4.161)
#   BUILD_MEMORY   host-safety RAM cap for the build container (e.g. 6g)  (§12.6)
#                  (uses --memory/--memory-swap; the `memory` controller IS
#                   delegated rootless. CPU is bounded separately by GOMAXPROCS=2
#                   in Dockerfile.caddy + host nice/ionice on the build process —
#                   `podman build` has no --cpus and --cpuset-cpus is undelegated
#                   rootless, so no CPU cgroup flag is used here.)
#   DRY_RUN        1 => print only, do not run the build
#
# Outputs:
#   A local image tagged ${IMAGE_TAG} AND ${IMAGE_NAME}:latest. Set compose
#   CADDY_IMAGE (or .env) to ${IMAGE_TAG} so the hermetic stack uses it.
#
# Side-effects:
#   Builds a container image in the LOCAL rootless image store. No push, no run,
#   no host-network change, no privileged operation. Does NOT boot anything.
#
# Dependencies:
#   - podman (rootless) on PATH (or docker via CONTAINER_ENGINE=docker)
#   - Dockerfile.caddy + caddy-challtestsrv-dns/ in THIS directory (build context)
#   - network access to pull caddy:${CADDY_VERSION}-builder / -alpine on first build
#
# Cross-references:
#   - Dockerfile.caddy         (the multi-stage build this script drives)
#   - caddy-challtestsrv-dns/  (the local module embedded via xcaddy --with)
#   - compose.hermetic.yml     (consumes the produced image as `caddy`)
#   - README.md "Conductor boot sequence" (where this runs in the ordered flow)
#   - Constitution §11.4.161 (rootless) · §11.4.173 (containerized build) · §11.4.6
#
# NOTE (§11.4.173): the containers submodule (pkg/crossbuild) is the sanctioned
# orchestrated build path. This script is the canonical *rootless-podman* recipe
# the conductor runs directly (or wraps through the submodule). It performs a
# plain image build only — no ad-hoc `podman run` of services (§11.4.76).
# =============================================================================

set -eu

# ---- Resolve this script's directory (build context = deploy/letsencrypt/) ----
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

CADDY_VERSION="${CADDY_VERSION:-2.8.4}"
IMAGE_NAME="${IMAGE_NAME:-localhost/helix_proxy/caddy-challtestsrv}"
IMAGE_TAG="${IMAGE_TAG:-${IMAGE_NAME}:${CADDY_VERSION}}"
CONTAINER_ENGINE="${CONTAINER_ENGINE:-podman}"
DOCKERFILE="${SCRIPT_DIR}/Dockerfile.caddy"

# ---- Pre-flight (§11.4.6 — verify, do not assume) ----------------------------
if ! command -v "${CONTAINER_ENGINE}" >/dev/null 2>&1; then
	echo "ERROR: container engine '${CONTAINER_ENGINE}' not found on PATH." >&2
	echo "       Install rootless podman, or set CONTAINER_ENGINE=docker." >&2
	exit 1
fi

if [ ! -f "${DOCKERFILE}" ]; then
	echo "ERROR: ${DOCKERFILE} not found." >&2
	exit 1
fi

if [ ! -d "${SCRIPT_DIR}/caddy-challtestsrv-dns" ]; then
	echo "ERROR: local module dir ${SCRIPT_DIR}/caddy-challtestsrv-dns missing." >&2
	exit 1
fi

echo "==> Building custom hermetic Caddy image"
echo "    engine        : ${CONTAINER_ENGINE}"
echo "    caddy version : ${CADDY_VERSION}"
echo "    image tag     : ${IMAGE_TAG}"
echo "    also tagged   : ${IMAGE_NAME}:latest"
echo "    context       : ${SCRIPT_DIR}"
echo "    dockerfile    : ${DOCKERFILE}"

# Optional host-safety resource caps (§12.6). When BUILD_CPUSET / BUILD_MEMORY
# are set, bound the build container's CPU + RAM so a heavy xcaddy Go compile
# cannot breach the host memory ceiling. Unset => engine default (unbounded).
CAP_ARGS=""
[ -n "${BUILD_MEMORY:-}" ] && CAP_ARGS="${CAP_ARGS} --memory ${BUILD_MEMORY} --memory-swap ${BUILD_MEMORY}"

# Rootless podman build. --build-arg pins the Caddy version into the Dockerfile.
# No --privileged, no --network=host. ${CAP_ARGS} intentionally word-splits into
# separate flags (only known safe tokens) — SC2086 disabled for that reason.
# shellcheck disable=SC2086
set -- "${CONTAINER_ENGINE}" build ${CAP_ARGS} \
	--build-arg "CADDY_VERSION=${CADDY_VERSION}" \
	--tag "${IMAGE_TAG}" \
	--tag "${IMAGE_NAME}:latest" \
	--file "${DOCKERFILE}" \
	"${SCRIPT_DIR}"

if [ "${DRY_RUN:-0}" = "1" ]; then
	echo "==> DRY_RUN=1 — build command (not executed):"
	echo "    $*"
	exit 0
fi

"$@"

echo "==> Built ${IMAGE_TAG}"
echo "==> Verifying the DNS-01 provider module is embedded..."
# Anti-bluff (§11.4.6): a successful build is not proof the module linked in.
# Confirm the module is listed by the produced binary.
"${CONTAINER_ENGINE}" run --rm --entrypoint caddy "${IMAGE_TAG}" list-modules \
	| grep -F 'dns.providers.challtestsrv' \
	&& echo "==> OK: dns.providers.challtestsrv present." \
	|| { echo "ERROR: dns.providers.challtestsrv NOT found in the built image." >&2; exit 1; }

echo "==> Done. Set compose CADDY_IMAGE=${IMAGE_TAG} for the hermetic stack."
