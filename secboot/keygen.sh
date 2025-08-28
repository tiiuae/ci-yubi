#!/usr/bin/env bash
set -euo pipefail

if [[ -n "${CI_YUBI_ROOT:-}" ]]; then
    ROOT="$CI_YUBI_ROOT/secboot"
else
    SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
    ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
fi

CONF="conf"

OUT_DIR="${OUT_DIR:-"${PWD}/keys"}"
mkdir -p "${OUT_DIR}"

# Create Keypair for PK (the root or top CA key)
openssl genrsa -out keys/pk.key 2048

# Create self-signed certificate for PK
openssl req -new -x509 -days 3650 -key "${OUT_DIR}/pk.key" -out "${OUT_DIR}/pk.crt" -config "${CONF}/create_PK_cert.ini"

# Create keypair for KEK (intermediate)
openssl genrsa -out "${OUT_DIR}/kek.key" 2048

# Create CSR for KEK
openssl req -new -key "${OUT_DIR}/kek.key" -out "${OUT_DIR}/kek.csr" -config "${CONF}/create_KEK_cert.ini"

# Sign KEK CSR with PK (acts as CA)
openssl x509 -req -in "${OUT_DIR}/kek.csr" -CA "${OUT_DIR}/pk.crt" -CAkey "${OUT_DIR}/pk.key" -CAcreateserial -out "${OUT_DIR}/kek.crt" -days 3650 -extfile "${CONF}/sign_KEK_csr.ini" -extensions v3_req

# Create keypair for DB (leaf)
openssl genrsa -out "${OUT_DIR}/db.key" 2048

# Create CSR for DB
openssl req -new -key "${OUT_DIR}/db.key" -out "${OUT_DIR}/db.csr" -config "${CONF}/create_DB_cert.ini"

# Sign DB CSR with KEK
openssl x509 -req -in keys/db.csr -CA "${OUT_DIR}/kek.crt" -CAkey "${OUT_DIR}/kek.key" -CAcreateserial -out "${OUT_DIR}/db.crt" -days 3650 -extfile "${CONF}/sign_DB_csr.ini" -extensions v3_req

openssl x509 -in "${OUT_DIR}/pk.crt"  -outform DER -out "${OUT_DIR}/pk.der"
openssl x509 -in "${OUT_DIR}/kek.crt" -outform DER -out "${OUT_DIR}/kek.der"
openssl x509 -in "${OUT_DIR}/db.crt"  -outform DER -out "${OUT_DIR}/db.der"