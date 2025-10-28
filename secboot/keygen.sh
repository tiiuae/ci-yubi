#!/usr/bin/env bash
set -euo pipefail

# --- Check dependencies ---
if ! command -v openssl >/dev/null 2>&1; then
    cat >&2 <<EOF
Error: openssl not found in PATH.

Please install it with your package manager (e.g., apt, yum, brew).

Alternatively, if using nix, you can run this script inside a temporary nix-shell:
    nix-shell -p openssl --run "bash $0"
EOF
    exit 1
fi

if [[ -n "${CI_YUBI_ROOT:-}" ]]; then
    ROOT="$CI_YUBI_ROOT/secboot"
else
    SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
    ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
fi

TARGET="${1:-}"

CONF="${CONF:-${PWD}/conf}"

OUT_DIR="${OUT_DIR:-"${PWD}/${TARGET}/keys"}"

# Create subdirectories for expected hierarchy
PK_DIR="${OUT_DIR}/PK"
KEK_DIR="${OUT_DIR}/KEK"
DB_DIR="${OUT_DIR}/db"
mkdir -p "${PK_DIR}" "${KEK_DIR}" "${DB_DIR}"

# --- Platform Key (PK) ---
# Create Keypair for PK (the root or top CA key)
openssl genrsa -out "${PK_DIR}/PK.key" 2048
# Create self-signed certificate for PK
openssl req -new -x509 -days 3650 \
    -key "${PK_DIR}/PK.key" \
    -out "${PK_DIR}/PK.crt" \
    -config "${CONF}/create_PK_cert.ini"

# --- Key Exchange Key (KEK) ---
# Create keypair for KEK (intermediate)
openssl genrsa -out "${KEK_DIR}/KEK.key" 2048
# Create CSR for KEK
openssl req -new \
    -key "${KEK_DIR}/KEK.key" \
    -out "${KEK_DIR}/KEK.csr" \
    -config "${CONF}/create_KEK_cert.ini"
# Sign KEK CSR with PK (acts as CA)
openssl x509 -req \
    -in "${KEK_DIR}/KEK.csr" \
    -CA "${PK_DIR}/PK.crt" \
    -CAkey "${PK_DIR}/PK.key" \
    -CAcreateserial \
    -out "${KEK_DIR}/KEK.crt" \
    -days 3650 \
    -extfile "${CONF}/sign_KEK_csr.ini" \
    -extensions v3_req

# --- Signature Database (DB) ---
# Create keypair for DB (leaf)
openssl genrsa -out "${DB_DIR}/db.key" 2048
# Create CSR for DB
openssl req -new \
    -key "${DB_DIR}/db.key" \
    -out "${DB_DIR}/db.csr" \
    -config "${CONF}/create_DB_cert.ini"
# Sign DB CSR with KEK
openssl x509 -req \
    -in "${DB_DIR}/db.csr" \
    -CA "${KEK_DIR}/KEK.crt" \
    -CAkey "${KEK_DIR}/KEK.key" \
    -CAcreateserial \
    -out "${DB_DIR}/db.crt" \
    -days 3650 \
    -extfile "${CONF}/sign_DB_csr.ini" \
    -extensions v3_req

# --- Export DER ---
openssl x509 -in "${PK_DIR}/PK.crt" -outform DER -out "${PK_DIR}/PK.der"
openssl x509 -in "${KEK_DIR}/KEK.crt" -outform DER -out "${KEK_DIR}/KEK.der"
openssl x509 -in "${DB_DIR}/db.crt" -outform DER -out "${DB_DIR}/db.der"

# --- Export PEM ---
openssl x509 -in "${PK_DIR}/PK.crt" -outform PEM -out "${PK_DIR}/PK.pem"
openssl x509 -in "${KEK_DIR}/KEK.crt" -outform PEM -out "${KEK_DIR}/KEK.pem"
openssl x509 -in "${DB_DIR}/db.crt" -outform PEM -out "${DB_DIR}/db.pem"
