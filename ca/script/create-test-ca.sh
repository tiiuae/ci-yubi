# SPDX-FileCopyrightText: 2022-2024 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0
# shellcheck shell=bash

#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Config (adjust as needed) ---
: "${P11MODULE:?Set P11MODULE to the netHSM PKCS#11 module path, e.g. /nix/store/.../libnethsm_pkcs11.so}"
TOKEN_LABEL="${TOKEN_LABEL:-NetHSM}"

ROOT_LABEL="${ROOT_LABEL:-ghaf-root-ca}"
INT_LABEL="${INT_LABEL:-ghaf-intermediate-ca}"
LEAF_BIN_LABEL="${LEAF_BIN_LABEL:-GhafInfraSignECP256}"
LEAF_PROV_LABEL="${LEAF_PROV_LABEL:-GhafInfraSignProv}"
LEAF_COSIGN_LABEL="${LEAF_COSIGN_LABEL:-GhafInfraSignCosign}"
UEFI_PK_LABEL="${UEFI_PK_LABEL:-PK}"
UEFI_KEK_LABEL="${UEFI_KEK_LABEL:-KEK}"
UEFI_DB_LABEL="${UEFI_DB_LABEL:-db}"

ROOT_SUBJ="${ROOT_SUBJ:-/C=FI/O=Ghaf/CN=Ghaf Root CA}"
INT_SUBJ="${INT_SUBJ:-/C=FI/O=Ghaf/CN=Ghaf Intermediate CA}"
LEAF_BIN_SUBJ="${LEAF_BIN_SUBJ:-/C=FI/ST=Tampere/L=Tampere/O=Ghaf/CN=Ghaf Infra Sign Binary}"
LEAF_PROV_SUBJ="${LEAF_PROV_SUBJ:-/C=FI/ST=Tampere/L=Tampere/O=Ghaf/CN=Ghaf Infra Sign Provenance}"
LEAF_COSIGN_SUBJ="${LEAF_COSIGN_SUBJ:-/C=FI/ST=Tampere/L=Tampere/O=Ghaf/CN=Ghaf Infra Sign Cosign}"

ROOT_DAYS="${ROOT_DAYS:-7300}"   # 20 years
INT_DAYS="${INT_DAYS:-3650}"     # 10 years
LEAF_DAYS="${LEAF_DAYS:-365}"    # 1 year
UEFI_DAYS="${UEFI_DAYS:-3650}"   # 10 years

ROOT_EXT="${ROOT_EXT:-root.ext}"
INT_EXT="${INT_EXT:-intermediate.ext}"
LEAF_EXT="${LEAF_EXT:-leaf.ext}"
UEFI_CONF="${UEFI_CONF:-$SCRIPT_DIR/conf}"
UEFI_KEY_TYPE="${UEFI_KEY_TYPE:-rsa:2048}"

OUTDIR="${OUTDIR:-pki-out}"
mkdir -p "$OUTDIR"

ROOT_CSR="$OUTDIR/root-ca.csr"
ROOT_CERT="$OUTDIR/root-ca.pem"

INT_CSR="$OUTDIR/intermediate-ca.csr"
INT_CERT="$OUTDIR/intermediate-ca.pem"

LEAF_BIN_CSR="$OUTDIR/GhafInfraSignECP256.csr"
LEAF_BIN_CERT="$OUTDIR/GhafInfraSignECP256.pem"

LEAF_PROV_CSR="$OUTDIR/GhafInfraSignProv.csr"
LEAF_PROV_CERT="$OUTDIR/GhafInfraSignProv.pem"

LEAF_COSIGN_CSR="$OUTDIR/GhafInfraSignCosign.csr"
LEAF_COSIGN_CERT="$OUTDIR/GhafInfraSignCosign.pem"

UEFI_OUT_DIR="${UEFI_OUT_DIR:-$OUTDIR/uefi/keys}"
UEFI_PK_DIR="$UEFI_OUT_DIR/PK"
UEFI_KEK_DIR="$UEFI_OUT_DIR/KEK"
UEFI_DB_DIR="$UEFI_OUT_DIR/db"
mkdir -p "$UEFI_PK_DIR" "$UEFI_KEK_DIR" "$UEFI_DB_DIR"

# --- Helper: PKCS#11 URIs ---
ROOT_KEY_URI="pkcs11:token=${TOKEN_LABEL};object=${ROOT_LABEL};type=private"
INT_KEY_URI="pkcs11:token=${TOKEN_LABEL};object=${INT_LABEL};type=private"
UEFI_PK_URI="pkcs11:token=${TOKEN_LABEL};object=${UEFI_PK_LABEL};type=private"
UEFI_KEK_URI="pkcs11:token=${TOKEN_LABEL};object=${UEFI_KEK_LABEL};type=private"
UEFI_DB_URI="pkcs11:token=${TOKEN_LABEL};object=${UEFI_DB_LABEL};type=private"

# --- 0) Sanity: show token slots (optional) ---
echo "[*] PKCS#11 module: $P11MODULE"
pkcs11-tool --module "$P11MODULE" -L >/dev/null

# --- 1) Root CA keypair in netHSM ---
echo "[*] Creating Root CA keypair in netHSM (label: $ROOT_LABEL)"
pkcs11-tool --module "$P11MODULE" \
  --keypairgen --key-type EC:prime256v1 \
  --label "$ROOT_LABEL"

# --- 2) Root CA CSR (key stays in netHSM) ---
echo "[*] Creating Root CA CSR -> $ROOT_CSR"
openssl req -new \
  -provider pkcs11 -provider default \
  -key "$ROOT_KEY_URI" \
  -subj "$ROOT_SUBJ" \
  -out "$ROOT_CSR"

# --- 3) Root CA self-signed certificate (signed by netHSM key) ---
echo "[*] Self-signing Root CA certificate -> $ROOT_CERT"
openssl x509 -req \
  -in "$ROOT_CSR" \
  -provider pkcs11 -provider default \
  -signkey "$ROOT_KEY_URI" \
  -days "$ROOT_DAYS" -sha256 \
  -extfile "$ROOT_EXT" \
  -out "$ROOT_CERT"

# --- 4) Intermediate CA keypair in netHSM ---
echo "[*] Creating Intermediate CA keypair in netHSM (label: $INT_LABEL)"
pkcs11-tool --module "$P11MODULE" \
  --keypairgen --key-type EC:prime256v1 \
  --label "$INT_LABEL"

# --- 5) Intermediate CA CSR (key stays in netHSM) ---
echo "[*] Creating Intermediate CA CSR -> $INT_CSR"
openssl req -new \
  -provider pkcs11 -provider default \
  -key "$INT_KEY_URI" \
  -subj "$INT_SUBJ" \
  -out "$INT_CSR"

# --- 6) Intermediate CA certificate signed by Root CA (root key in netHSM) ---
echo "[*] Signing Intermediate CA certificate with Root CA -> $INT_CERT"
openssl x509 -req \
  -in "$INT_CSR" \
  -provider pkcs11 -provider default \
  -CA "$ROOT_CERT" \
  -CAkey "$ROOT_KEY_URI" \
  -CAcreateserial \
  -days "$INT_DAYS" -sha256 \
  -extfile "$INT_EXT" \
  -out "$INT_CERT"

# --- 7) Leaf BIN & PROV keypairs
echo "[*] Creating Binary Leaf keypair in netHSM (label: $LEAF_BIN_LABEL)"
pkcs11-tool --module "$P11MODULE" \
  --keypairgen --key-type EC:prime256v1 \
  --label "$LEAF_BIN_LABEL"

echo "[*] Creating Provenance Leaf keypair in netHSM (label: $LEAF_PROV_LABEL)"
pkcs11-tool --module "$P11MODULE" \
  --keypairgen --key-type EC:ED25519 \
  --label "$LEAF_PROV_LABEL"


# --- 8) Leaf BIN & PROV CSR
echo "[*] Creating Binary Leaf CSR -> $LEAF_BIN_CSR"
openssl req -new \
	-provider pkcs11 -provider default \
	-key "pkcs11:token=${TOKEN_LABEL};object=$LEAF_BIN_LABEL" \
	-out "$LEAF_BIN_CSR" \
	-subj "$LEAF_BIN_SUBJ"

echo "[*] Creating Provenance Leaf CSR -> $LEAF_PROV_CSR"
openssl req -new \
	-provider pkcs11 -provider default \
	-key "pkcs11:token=${TOKEN_LABEL};object=$LEAF_PROV_LABEL" \
	-out "$LEAF_PROV_CSR" \
	-subj "$LEAF_PROV_SUBJ"

# --- 9) Leaf BIN & PROV certificate signed by Intermediate CA (key in netHSM) ---
echo "[*] Signing Binary Leaf certificate with Intermediate CA -> $LEAF_BIN_CERT"
openssl x509 -req \
  -in "$LEAF_BIN_CSR" \
  -provider pkcs11 -provider default \
  -CA "$INT_CERT" \
  -CAkey "$INT_KEY_URI" \
  -CAcreateserial \
  -days "$LEAF_DAYS" -sha256 \
  -extfile "$LEAF_EXT" \
  -out "$LEAF_BIN_CERT"

echo "[*] Signing Provenance Leaf certificate with Intermediate CA -> $LEAF_PROV_CERT"
openssl x509 -req \
  -in "$LEAF_PROV_CSR" \
  -provider pkcs11 -provider default \
  -CA "$INT_CERT" \
  -CAkey "$INT_KEY_URI" \
  -CAcreateserial \
  -days "$LEAF_DAYS" -sha256 \
  -extfile "$LEAF_EXT" \
  -out "$LEAF_PROV_CERT"

# --- 10) Leaf certificate for cosign signed by Intermediate CA (key in netHSM) ---
echo "[*] Creating cosign Leaf keypair in netHSM (label: $LEAF_COSIGN_LABEL)"
pkcs11-tool --module "$P11MODULE" \
  --keypairgen --key-type EC:ED25519 \
  --label "$LEAF_COSIGN_LABEL"

echo "[*] Creating cosign Leaf CSR -> $LEAF_COSIGN_CSR"
openssl req -new \
	-provider pkcs11 -provider default \
        -key "pkcs11:token=${TOKEN_LABEL};object=$LEAF_COSIGN_LABEL" \
        -out "$LEAF_COSIGN_CSR" \
        -subj "$LEAF_COSIGN_SUBJ"

echo "[*] Signing cosign Leaf certificate with Intermediate CA -> $LEAF_COSIGN_CERT"
openssl x509 -req \
  -in "$LEAF_COSIGN_CSR" \
  -provider pkcs11 -provider default \
  -CA "$INT_CERT" \
  -CAkey "$INT_KEY_URI" \
  -CAcreateserial \
  -days "$LEAF_DAYS" -sha256 \
  -extfile "$LEAF_EXT" \
  -out "$LEAF_COSIGN_CERT"

# --- 11) UEFI Secure Boot keypairs and certificates in netHSM ---
echo "[*] Creating UEFI PK keypair in netHSM (label: $UEFI_PK_LABEL)"
pkcs11-tool --module "$P11MODULE" \
  --keypairgen --key-type "$UEFI_KEY_TYPE" \
  --label "$UEFI_PK_LABEL"

printf '%s\n' "$UEFI_PK_URI" > "$UEFI_PK_DIR/PK.uri"

echo "[*] Creating UEFI PK self-signed certificate -> $UEFI_PK_DIR/PK.pem"
openssl req -new -x509 -days "$UEFI_DAYS" \
  -provider pkcs11 -provider default \
  -key "$UEFI_PK_URI" \
  -out "$UEFI_PK_DIR/PK.pem" \
  -config "$UEFI_CONF/create_PK_cert.ini"

echo "[*] Creating UEFI KEK keypair in netHSM (label: $UEFI_KEK_LABEL)"
pkcs11-tool --module "$P11MODULE" \
  --keypairgen --key-type "$UEFI_KEY_TYPE" \
  --label "$UEFI_KEK_LABEL"

printf '%s\n' "$UEFI_KEK_URI" > "$UEFI_KEK_DIR/KEK.uri"

echo "[*] Creating UEFI KEK CSR -> $UEFI_KEK_DIR/KEK.csr"
openssl req -new \
  -provider pkcs11 -provider default \
  -key "$UEFI_KEK_URI" \
  -out "$UEFI_KEK_DIR/KEK.csr" \
  -config "$UEFI_CONF/create_KEK_cert.ini"

echo "[*] Signing UEFI KEK certificate with UEFI PK -> $UEFI_KEK_DIR/KEK.pem"
openssl x509 -req \
  -in "$UEFI_KEK_DIR/KEK.csr" \
  -provider pkcs11 -provider default \
  -CA "$UEFI_PK_DIR/PK.pem" \
  -CAkey "$UEFI_PK_URI" \
  -CAcreateserial \
  -out "$UEFI_KEK_DIR/KEK.pem" \
  -days "$UEFI_DAYS" \
  -extfile "$UEFI_CONF/sign_KEK_csr.ini" \
  -extensions v3_req

echo "[*] Creating UEFI db keypair in netHSM (label: $UEFI_DB_LABEL)"
pkcs11-tool --module "$P11MODULE" \
  --keypairgen --key-type "$UEFI_KEY_TYPE" \
  --label "$UEFI_DB_LABEL"

printf '%s\n' "$UEFI_DB_URI" > "$UEFI_DB_DIR/db.uri"

echo "[*] Creating UEFI db CSR -> $UEFI_DB_DIR/db.csr"
openssl req -new \
  -provider pkcs11 -provider default \
  -key "$UEFI_DB_URI" \
  -out "$UEFI_DB_DIR/db.csr" \
  -config "$UEFI_CONF/create_DB_cert.ini"

echo "[*] Signing UEFI db certificate with UEFI KEK -> $UEFI_DB_DIR/db.pem"
openssl x509 -req \
  -in "$UEFI_DB_DIR/db.csr" \
  -provider pkcs11 -provider default \
  -CA "$UEFI_KEK_DIR/KEK.pem" \
  -CAkey "$UEFI_KEK_URI" \
  -CAcreateserial \
  -out "$UEFI_DB_DIR/db.pem" \
  -days "$UEFI_DAYS" \
  -extfile "$UEFI_CONF/sign_DB_csr.ini" \
  -extensions v3_req

echo "[*] Exporting UEFI certificates as DER"
openssl x509 -in "$UEFI_PK_DIR/PK.pem" -outform DER -out "$UEFI_PK_DIR/PK.der"
openssl x509 -in "$UEFI_KEK_DIR/KEK.pem" -outform DER -out "$UEFI_KEK_DIR/KEK.der"
openssl x509 -in "$UEFI_DB_DIR/db.pem" -outform DER -out "$UEFI_DB_DIR/db.der"

echo
echo "[+] Done."
echo "    Root CA cert:         $ROOT_CERT"
echo "    Intermediate CA cert: $INT_CERT"
echo "    Binary Leaf cert:     $LEAF_BIN_CERT"
echo "    Provenance Leaf cert: $LEAF_PROV_CERT"
echo "    cosign Leaf cert:     $LEAF_COSIGN_CERT"
echo "    Root CSR:             $ROOT_CSR"
echo "    Intermediate CSR:     $INT_CSR"
echo "    Binary Leaf CSR:      $LEAF_BIN_CSR"
echo "    Provenance Leaf CSR:  $LEAF_PROV_CSR"
echo "    cosign Leaf CSR:      $LEAF_COSIGN_CSR"
echo "    UEFI PK cert:         $UEFI_PK_DIR/PK.pem"
echo "    UEFI KEK cert:        $UEFI_KEK_DIR/KEK.pem"
echo "    UEFI db cert:         $UEFI_DB_DIR/db.pem"
echo "    UEFI PK URI:          $UEFI_PK_DIR/PK.uri"
echo "    UEFI KEK URI:         $UEFI_KEK_DIR/KEK.uri"
echo "    UEFI db URI:          $UEFI_DB_DIR/db.uri"
echo "    Serial file:          $OUTDIR/*.srl (created by -CAcreateserial)"
