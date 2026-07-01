#!/usr/bin/env bash
# =============================================================================
# gen_test_mtls.sh — hermetic self-signed mTLS test-cert + pg-password generator
#                    for the control-API observability boot (task #56 enablement)
# -----------------------------------------------------------------------------
# Purpose:      Generate — with openssl, fully offline, no network — the four
#               material files the control-API needs to START so the conductor can
#               boot `proxy-api` (docker-compose.observability.yml) and prove the
#               plaintext Prometheus /metrics scrape live (tests/observability/
#               metrics_scrape_test.sh). The control-API is FAIL-CLOSED: it will
#               NOT start (and therefore the plaintext /metrics listener never
#               binds) unless buildTLSConfig loads all three mTLS materials
#               successfully — control-plane/internal/api/tls.go:26-43 requires
#               CONTROL_API_TLS_CERT + CONTROL_API_TLS_KEY + CONTROL_API_TLS_CLIENT_CA,
#               and control-plane/internal/api/server.go:169-178 calls
#               buildTLSConfig FIRST, then startMetricsListener. These are
#               DISPOSABLE TEST materials for a hermetic self-boot ONLY — never
#               operator/production keys.
#
#               Files generated (into a GITIGNORED dir, §11.4.10/§11.4.30):
#                 ca.key          test CA private key (signs server + client leafs)
#                 ca.crt          test CA cert           -> secret helixproxy_api_client_ca
#                 server.key      server leaf key        -> secret helixproxy_api_key
#                 server.crt      server leaf cert       -> secret helixproxy_api_cert
#                 client.key      client leaf key        (for an mTLS client probe)
#                 client.crt      client leaf cert       (signed by ca.crt)
#                 pg_password.txt random Postgres pw     -> secret helixproxy_pg_password
#
# Usage:        GOMAXPROCS=2 nice -n 19 ionice -c 3 \
#                   bash tests/observability/gen_test_mtls.sh [--force] [--print-secrets-only]
#               (self-re-execs under nice/ionice when present so the §12.6 host
#                resource cap holds regardless of the caller.)
#                 --force               regenerate even if the material already exists.
#                 --print-secrets-only  skip generation; only print the 4
#                                       `podman secret create` commands (for the
#                                       already-generated material). Fails if absent.
#               Idempotent: with no flag and complete existing material it prints
#               the secret commands and exits 0 WITHOUT regenerating (stable certs
#               across re-runs so a booted api is not invalidated).
#
# Inputs (env): MTLS_DIR      output dir (default: <script-dir>/.mtls — GITIGNORED).
#               SERVER_SANS   override server-cert SAN list (default matches the
#                             container network alias + loopback:
#                             "DNS:proxy-control-plane,DNS:localhost,IP:127.0.0.1,IP:::1").
#               SERVER_CN     server-cert CN (default helix-control-plane — matches
#                             control-plane/internal/api/harness_test.go:139).
#               CLIENT_CN     client-cert CN / audit actor (default admin@helix —
#                             matches harness_test.go:142).
#               CERT_DAYS     leaf validity in days (default 825).
#
# Outputs:      The 7 files above under MTLS_DIR (0600 files, 0700 dir); to STDOUT,
#               the EXACT 4 `podman secret create <name> <file>` commands the
#               conductor runs. NEVER prints key bytes or the pg password VALUE
#               (only file PATHS) — §11.4.10.
#
# Side-effects: Creates/populates the gitignored MTLS_DIR. Does NOT create podman
#               secrets, does NOT boot/run any container, does NOT touch the
#               network, does NOT git-add. Pure local file generation.
#
# Dependencies: bash, openssl (>=1.1; tested on OpenSSL 3.5). POSIX coreutils.
#
# Cross-refs:   control-plane/internal/api/tls.go:25-56 (buildTLSConfig fail-closed;
#               all three paths required, RequireAndVerifyClientCert),
#               control-plane/internal/api/api.go:26-32 (Config env mapping),
#               control-plane/internal/api/server.go:133-158,169-178 (metrics
#               listener starts AFTER buildTLSConfig succeeds),
#               control-plane/internal/api/harness_test.go:138-143 (SAN/CN
#               convention this generator mirrors),
#               docker-compose.observability.yml:63-71,116-130 (secret NAMES),
#               tests/observability/metrics_scrape_test.sh (the live scrape guard).
#               §11.4.10 (credentials never tracked/printed) / §11.4.18 (this doc
#               block + docs/scripts/gen_test_mtls.md) / §11.4.30 (.gitignore) /
#               §11.4.6 (facts, not guesses) / §12.6 (resource cap).
# Last verified: 2026-07-01
# =============================================================================
set -eu

# --- §12.6 resource cap: re-exec under nice/ionice once (idempotent guard) ----
if [ "${_GEN_MTLS_RENICED:-}" != "1" ]; then
    export _GEN_MTLS_RENICED=1
    export GOMAXPROCS="${GOMAXPROCS:-2}"
    _self="$0"
    if command -v nice >/dev/null 2>&1 && command -v ionice >/dev/null 2>&1; then
        exec nice -n 19 ionice -c 3 bash "$_self" "$@"
    elif command -v nice >/dev/null 2>&1; then
        exec nice -n 19 bash "$_self" "$@"
    fi
fi

# --- locate self + defaults ---------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MTLS_DIR="${MTLS_DIR:-$SCRIPT_DIR/.mtls}"
SERVER_CN="${SERVER_CN:-helix-control-plane}"
CLIENT_CN="${CLIENT_CN:-admin@helix}"
SERVER_SANS="${SERVER_SANS:-DNS:proxy-control-plane,DNS:localhost,IP:127.0.0.1,IP:::1}"
CERT_DAYS="${CERT_DAYS:-825}"

FORCE=0
PRINT_ONLY=0
for arg in "$@"; do
    case "$arg" in
        --force) FORCE=1 ;;
        --print-secrets-only) PRINT_ONLY=1 ;;
        -h|--help)
            grep -E '^# ' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            printf 'gen_test_mtls: unknown argument %q (try --help)\n' "$arg" >&2
            exit 2
            ;;
    esac
done

CA_KEY="$MTLS_DIR/ca.key"
CA_CRT="$MTLS_DIR/ca.crt"
SRV_KEY="$MTLS_DIR/server.key"
SRV_CRT="$MTLS_DIR/server.crt"
CLI_KEY="$MTLS_DIR/client.key"
CLI_CRT="$MTLS_DIR/client.crt"
PG_PW="$MTLS_DIR/pg_password.txt"

# The 4 secret NAMES are FIXED by docker-compose.observability.yml:63-71 — do not
# rename without updating that overlay (§11.4.6, one source of truth).
SECRET_CERT="helixproxy_api_cert"
SECRET_KEY="helixproxy_api_key"
SECRET_CLIENT_CA="helixproxy_api_client_ca"
SECRET_PG_PW="helixproxy_pg_password"

print_secret_commands() {
    # NEVER echoes key/password bytes — only file PATHS (§11.4.10). The `-` form is
    # avoided so nothing is piped through the log; podman reads the file directly.
    cat <<EOF
# --- Podman secret create commands (run BEFORE booting proxy-api; §11.4.161 rootless) ---
# Server cert / key + client CA (mTLS fail-closed inputs, tls.go:26-43):
podman secret create $SECRET_CERT      $SRV_CRT
podman secret create $SECRET_KEY       $SRV_KEY
podman secret create $SECRET_CLIENT_CA $CA_CRT
# Postgres password (DSN assembled at runtime, observability compose:137-138):
podman secret create $SECRET_PG_PW     $PG_PW
# (If a secret already exists: 'podman secret rm <name>' first, then re-create.)
EOF
}

material_complete() {
    [ -s "$CA_CRT" ] && [ -s "$SRV_CRT" ] && [ -s "$SRV_KEY" ] && \
        [ -s "$CA_KEY" ] && [ -s "$CLI_CRT" ] && [ -s "$CLI_KEY" ] && [ -s "$PG_PW" ]
}

if [ "$PRINT_ONLY" = "1" ]; then
    if material_complete; then
        print_secret_commands
        exit 0
    fi
    printf 'gen_test_mtls: --print-secrets-only but material is missing under %s (run without the flag first)\n' "$MTLS_DIR" >&2
    exit 1
fi

if [ "$FORCE" != "1" ] && material_complete; then
    printf '# gen_test_mtls: material already present under %s (idempotent; pass --force to regenerate)\n' "$MTLS_DIR" >&2
    print_secret_commands
    exit 0
fi

# --- generate -----------------------------------------------------------------
umask 077                     # every file 0600 by default (§11.4.10)
mkdir -p "$MTLS_DIR"
chmod 700 "$MTLS_DIR"         # parent dir 0700 (§11.4.10)

# openssl extension files (temp, inside the gitignored dir).
SRV_EXT="$MTLS_DIR/.server.ext"
CLI_EXT="$MTLS_DIR/.client.ext"
cleanup() { rm -f "$SRV_EXT" "$CLI_EXT" "$MTLS_DIR"/*.csr "$MTLS_DIR/ca.srl" 2>/dev/null || true; }
trap cleanup EXIT

cat > "$SRV_EXT" <<EOF
basicConstraints=CA:FALSE
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
subjectAltName=$SERVER_SANS
EOF

cat > "$CLI_EXT" <<EOF
basicConstraints=CA:FALSE
keyUsage=critical,digitalSignature
extendedKeyUsage=clientAuth
EOF

# 1) Test CA (self-signed, CA:TRUE, signs both leaves).
openssl ecparam -name prime256v1 -genkey -noout -out "$CA_KEY"
openssl req -new -x509 -key "$CA_KEY" -out "$CA_CRT" -days "$CERT_DAYS" \
    -subj "/CN=helix-proxy-test-ca" \
    -addext "basicConstraints=critical,CA:TRUE" \
    -addext "keyUsage=critical,keyCertSign,cRLSign,digitalSignature"

# 2) Server leaf (mTLS server cert; SANs cover the container alias + loopback).
openssl ecparam -name prime256v1 -genkey -noout -out "$SRV_KEY"
openssl req -new -key "$SRV_KEY" -out "$MTLS_DIR/server.csr" -subj "/CN=$SERVER_CN"
openssl x509 -req -in "$MTLS_DIR/server.csr" -CA "$CA_CRT" -CAkey "$CA_KEY" \
    -CAcreateserial -out "$SRV_CRT" -days "$CERT_DAYS" -extfile "$SRV_EXT"

# 3) Client leaf (mTLS peer signed by the SAME CA — this is what the api verifies
#    against helixproxy_api_client_ca; CN becomes the audit actor).
openssl ecparam -name prime256v1 -genkey -noout -out "$CLI_KEY"
openssl req -new -key "$CLI_KEY" -out "$MTLS_DIR/client.csr" -subj "/CN=$CLIENT_CN"
openssl x509 -req -in "$MTLS_DIR/client.csr" -CA "$CA_CRT" -CAkey "$CA_KEY" \
    -CAcreateserial -out "$CLI_CRT" -days "$CERT_DAYS" -extfile "$CLI_EXT"

# 4) Random, URL-safe Postgres password (hex = safe inside the DSN URL; the value
#    is NEVER printed — only the file path is surfaced, §11.4.10).
openssl rand -hex 24 > "$PG_PW"

chmod 600 "$CA_KEY" "$CA_CRT" "$SRV_KEY" "$SRV_CRT" "$CLI_KEY" "$CLI_CRT" "$PG_PW"

# --- verify (fail-closed: prove the material is what the api will load) --------
# Mirrors buildTLSConfig: server keypair loads, and the client cert verifies
# against the CA the api will use as its client-CA pool.
openssl x509 -in "$SRV_CRT" -noout >/dev/null
openssl x509 -in "$CLI_CRT" -noout >/dev/null
if ! openssl verify -CAfile "$CA_CRT" "$CLI_CRT" >/dev/null 2>&1; then
    printf 'gen_test_mtls: FATAL — client cert does not verify against ca.crt (regenerate)\n' >&2
    exit 1
fi

printf '# gen_test_mtls: OK — 7 files under %s (server CN=%s SANs=%s; client CN=%s)\n' \
    "$MTLS_DIR" "$SERVER_CN" "$SERVER_SANS" "$CLIENT_CN" >&2
print_secret_commands
