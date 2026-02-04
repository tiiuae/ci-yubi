#!/usr/bin/env bash
set -euo pipefail

# --- Config (adjust as needed) ---
: "${P11MODULE:?Set P11MODULE to the netHSM PKCS#11 module path, e.g. /nix/store/.../libnethsm_pkcs11.so}"
TOKEN_LABEL="${TOKEN_LABEL:-NetHSM}"

ROOT_LABEL="${ROOT_LABEL:-ghaf-root-ca}"
INT_LABEL="${INT_LABEL:-ghaf-intermediate-ca}"

ROOT_SUBJ="${ROOT_SUBJ:-/C=FI/O=Ghaf/CN=Ghaf Root CA}"
INT_SUBJ="${INT_SUBJ:-/C=FI/O=Ghaf/CN=Ghaf Intermediate CA}"

ROOT_DAYS="${ROOT_DAYS:-7300}"   # 20 years
INT_DAYS="${INT_DAYS:-3650}"     # 10 years

ROOT_EXT="${ROOT_EXT:-root.ext}"
INT_EXT="${INT_EXT:-intermediate.ext}"

OUTDIR="${OUTDIR:-pki-out}"
mkdir -p "$OUTDIR"

ROOT_CSR="$OUTDIR/root-ca.csr"
ROOT_CERT="$OUTDIR/root-ca.pem"

INT_CSR="$OUTDIR/intermediate-ca.csr"
INT_CERT="$OUTDIR/intermediate-ca.pem"

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

echo
echo "[+] Done."
echo "    Root CA cert:         $ROOT_CERT"
echo "    Intermediate CA cert: $INT_CERT"
echo "    Root CSR:             $ROOT_CSR"
echo "    Intermediate CSR:     $INT_CSR"
echo "    Serial file:          $OUTDIR/*.srl (created by -CAcreateserial)"
