#!/usr/bin/env bash
set -euo pipefail

# --- Config (adjust as needed) ---
: "${P11MODULE:?Set P11MODULE to the netHSM PKCS#11 module path, e.g. /nix/store/.../libnethsm_pkcs11.so}"
TOKEN_LABEL="${TOKEN_LABEL:-NetHSM}"

ROOT_LABEL="${ROOT_LABEL:-ghaf-root-ca}"
INT_LABEL="${INT_LABEL:-ghaf-intermediate-ca}"
LEAF_BIN_LABEL="${LEAF_BIN_LABEL:-GhafInfraSignECP256}"
LEAF_PROV_LABEL="${LEAF_PROV_LABEL:-GhafInfraSignProv}"
LEAF_COSIGN_LABEL="${LEAF_COSIGN_LABEL:-GhafInfraSignCosign}"

ROOT_SUBJ="${ROOT_SUBJ:-/C=FI/O=Ghaf/CN=Ghaf Root CA}"
INT_SUBJ="${INT_SUBJ:-/C=FI/O=Ghaf/CN=Ghaf Intermediate CA}"
LEAF_BIN_SUBJ="${LEAF_BIN_SUBJ:-/C=FI/ST=Tampere/L=Tampere/O=Ghaf/CN=Ghaf Infra Sign Binary}"
LEAF_PROV_SUBJ="${LEAF_PROV_SUBJ:-/C=FI/ST=Tampere/L=Tampere/O=Ghaf/CN=Ghaf Infra Sign Provenance}"
LEAF_COSIGN_SUBJ="${LEAF_COSIGN_SUBJ:-/C=FI/ST=Tampere/L=Tampere/O=Ghaf/CN=Ghaf Infra Sign Cosign}"

ROOT_DAYS="${ROOT_DAYS:-7300}"   # 20 years
INT_DAYS="${INT_DAYS:-3650}"     # 10 years
LEAF_DAYS="${LEAF_DAYS:-365}"    # 1 year

ROOT_EXT="${ROOT_EXT:-root.ext}"
INT_EXT="${INT_EXT:-intermediate.ext}"
LEAF_EXT="${LEAF_EXT:-leaf.ext}"

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

# --- Helper: PKCS#11 URIs ---
ROOT_KEY_URI="pkcs11:token=${TOKEN_LABEL};object=${ROOT_LABEL};type=private"
INT_KEY_URI="pkcs11:token=${TOKEN_LABEL};object=${INT_LABEL};type=private"

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
echo "[*] Creatin Binary Leaf CSR -> $LEAF_BIN_CSR"
openssl req -new \
	-provider pkcs11 -provider default \
	-key "pkcs11:token=NetHSM;object=$LEAF_BIN_LABEL" \
	-out "$LEAF_BIN_CSR" \
	-subj "$LEAF_BIN_SUBJ"

echo "[*] Creatin Provenance Leaf CSR -> $LEAF_PROV_CSR"
openssl req -new \
	-provider pkcs11 -provider default \
	-key "pkcs11:token=NetHSM;object=$LEAF_PROV_LABEL" \
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
echo "[*] Creating cosign Leaf keypair in netHSM (label: $LEAF_PROV_LABEL)"
pkcs11-tool --module "$P11MODULE" \
  --keypairgen --key-type EC:ED25519 \
  --label "$LEAF_COSIGN_LABEL"

echo "[*] Creatin cosign Leaf CSR -> $LEAF_PROV_CSR"
openssl req -new \
	-provider pkcs11 -provider default \
        -key "pkcs11:token=NetHSM;object=$LEAF_COSIGN_LABEL" \
        -out "$LEAF_COSIGN_CSR" \
        -subj "$LEAF_COSIGN_SUBJ"

echo "[*] Signing cosign Leaf certificate with Intermediate CA -> $LEAF_BIN_CERT"
openssl x509 -req \
  -in "$LEAF_COSIGN_CSR" \
  -provider pkcs11 -provider default \
  -CA "$INT_CERT" \
  -CAkey "$INT_KEY_URI" \
  -CAcreateserial \
  -days "$LEAF_DAYS" -sha256 \
  -extfile "$LEAF_EXT" \
  -out "$LEAF_COSIGN_CERT"

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
echo "    Serial file:          $OUTDIR/*.srl (created by -CAcreateserial)"
