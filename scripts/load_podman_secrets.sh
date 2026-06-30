#!/usr/bin/env bash
#######################################################################
# load_podman_secrets.sh — Helix Proxy Podman-secret provisioning loader
#
# Purpose:
#   Idempotently create the named ROOTLESS Podman secrets the dynamic-routing
#   stack expects (Postgres password, control-API mTLS cert+key, VPN tunnel
#   key material, proxy htpasswd) FROM operator-provisioned, gitignored source
#   files. The OPERATOR runs this once after dropping the real secret material
#   into the gitignored secrets directory; the compose/control-plane then
#   references the secrets BY NAME only.
#
#   §11.4.10: this script contains NO secret values — only the mapping of
#   secret-NAME -> expected gitignored SOURCE-PATH. The secret NAMES default to
#   the *_SECRET values documented in .env.example (overridable via env).
#
# Usage:
#   scripts/load_podman_secrets.sh [--replace] [--dry-run]
#     --replace   recreate a secret that already exists (default: skip existing)
#     --dry-run   print the actions without creating/removing any secret
#
#   Env overrides (defaults match .env.example):
#     SECRETS_DIR                 dir holding gitignored source files (./secrets)
#     HTPASSWD_FILE               proxy htpasswd source        (./config/htpasswd)
#     PG_PASSWORD_SECRET          secret name (helixproxy_pg_password)
#     CONTROL_API_TLS_CERT_SECRET secret name (helixproxy_api_cert)
#     CONTROL_API_TLS_KEY_SECRET  secret name (helixproxy_api_key)
#     VPN_WG_KEY_SECRET           secret name (helixproxy_vpn_wg_key)
#     PROXY_HTPASSWD_SECRET       secret name (helixproxy_proxy_htpasswd)
#     CONTAINER_RUNTIME           podman|docker|auto (default podman; rootless)
#
# Inputs:
#   Gitignored source files under $SECRETS_DIR + $HTPASSWD_FILE (NOT in git;
#   see .gitignore: secrets are excluded, config/htpasswd is excluded).
#
# Outputs:
#   Rootless Podman secrets (user scope). Prints a per-secret created/exists/
#   skipped summary. NEVER prints a secret value.
#
# Side-effects:
#   Creates (and with --replace, removes+recreates) ONLY the helixproxy_* named
#   secrets listed above. Does NOT touch the operator's own containers, network
#   interfaces, or unrelated secrets (§11.4.174).
#
# Dependencies:
#   podman (rootless, §11.4.161). No root / sudo.
#
# Cross-references:
#   .env.example (*_SECRET names), config/security/README.md (secret model),
#   docs/superpowers/specs/2026-06-30-vpn-aware-proxy-extension-design.md §12.
#
# STATUS: DESIGN / loader only — live secret-injection + leak-free proof is P10
#   (§11.4.6). This script is parse-clean now; it is for the OPERATOR to run.
#######################################################################

set -eu

# ---- configuration (names default to .env.example; values never here) -------
SECRETS_DIR="${SECRETS_DIR:-./secrets}"
HTPASSWD_FILE="${HTPASSWD_FILE:-./config/htpasswd}"

PG_PASSWORD_SECRET="${PG_PASSWORD_SECRET:-helixproxy_pg_password}"
CONTROL_API_TLS_CERT_SECRET="${CONTROL_API_TLS_CERT_SECRET:-helixproxy_api_cert}"
CONTROL_API_TLS_KEY_SECRET="${CONTROL_API_TLS_KEY_SECRET:-helixproxy_api_key}"
VPN_WG_KEY_SECRET="${VPN_WG_KEY_SECRET:-helixproxy_vpn_wg_key}"
PROXY_HTPASSWD_SECRET="${PROXY_HTPASSWD_SECRET:-helixproxy_proxy_htpasswd}"

RUNTIME="${CONTAINER_RUNTIME:-podman}"
[ "$RUNTIME" = "auto" ] && RUNTIME="podman"

REPLACE=0
DRY_RUN=0

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [load-secrets] $1"; }

usage() {
    sed -n '2,40p' "$0"
    exit "${1:-0}"
}

# ---- arg parsing -------------------------------------------------------------
while [ "$#" -gt 0 ]; do
    case "$1" in
        --replace) REPLACE=1 ;;
        --dry-run) DRY_RUN=1 ;;
        -h|--help) usage 0 ;;
        *) log "ERROR: unknown argument: $1"; usage 1 ;;
    esac
    shift
done

# ---- preflight ---------------------------------------------------------------
if ! command -v "$RUNTIME" >/dev/null 2>&1; then
    log "ERROR: container runtime '$RUNTIME' not found on PATH."
    exit 2
fi

# Refuse rootful execution — rootless only (§11.4.161).
if [ "$(id -u)" = "0" ]; then
    log "ERROR: refusing to run as root — Podman secrets MUST be rootless (§11.4.161)."
    exit 2
fi

secret_exists() {
    # name
    "$RUNTIME" secret exists "$1" >/dev/null 2>&1 && return 0
    # fallback for runtimes without `secret exists`
    "$RUNTIME" secret inspect "$1" >/dev/null 2>&1
}

# process_secret <secret-name> <source-path> <description>
process_secret() {
    name="$1"
    src="$2"
    desc="$3"

    if [ ! -f "$src" ]; then
        log "SKIP   $name  <- $src  (source MISSING — provision it, then re-run) [$desc]"
        MISSING=$((MISSING + 1))
        return 0
    fi

    # §11.4.10: warn (do not fail) on over-permissive source perms; never print contents.
    perms="$(stat -c '%a' "$src" 2>/dev/null || echo '???')"
    case "$perms" in
        600|400|640|440) : ;;
        *) log "WARN   $name  source $src perms=$perms — recommend chmod 600 (§11.4.10)." ;;
    esac

    if secret_exists "$name"; then
        if [ "$REPLACE" -eq 1 ]; then
            if [ "$DRY_RUN" -eq 1 ]; then
                log "DRYRUN $name  would REPLACE from $src"
            else
                "$RUNTIME" secret rm "$name" >/dev/null
                "$RUNTIME" secret create "$name" "$src" >/dev/null
                log "REPLACE $name <- $src  [$desc]"
                CREATED=$((CREATED + 1))
            fi
        else
            log "EXISTS $name  (kept; pass --replace to recreate) [$desc]"
            KEPT=$((KEPT + 1))
        fi
        return 0
    fi

    if [ "$DRY_RUN" -eq 1 ]; then
        log "DRYRUN $name  would CREATE from $src"
    else
        "$RUNTIME" secret create "$name" "$src" >/dev/null
        log "CREATE $name <- $src  [$desc]"
        CREATED=$((CREATED + 1))
    fi
}

# ---- the secret-name -> gitignored-source mapping (NO values) ----------------
CREATED=0
KEPT=0
MISSING=0

log "runtime=$RUNTIME  rootless uid=$(id -u)  secrets_dir=$SECRETS_DIR  replace=$REPLACE  dry_run=$DRY_RUN"

process_secret "$PG_PASSWORD_SECRET"          "$SECRETS_DIR/pg_password"   "Postgres control-plane password"
process_secret "$CONTROL_API_TLS_CERT_SECRET" "$SECRETS_DIR/api_cert.pem"  "control-API mTLS certificate"
process_secret "$CONTROL_API_TLS_KEY_SECRET"  "$SECRETS_DIR/api_key.pem"   "control-API mTLS private key"
process_secret "$VPN_WG_KEY_SECRET"           "$SECRETS_DIR/vpn_wg_key"    "WireGuard tunnel private key"
process_secret "$PROXY_HTPASSWD_SECRET"       "$HTPASSWD_FILE"             "Squid per-user htpasswd (hashes)"

log "summary: created/replaced=$CREATED  kept=$KEPT  missing-source=$MISSING"

if [ "$MISSING" -gt 0 ]; then
    log "NOTE: $MISSING source file(s) absent — provision them under $SECRETS_DIR (or HTPASSWD_FILE) and re-run."
    exit 3
fi

exit 0
