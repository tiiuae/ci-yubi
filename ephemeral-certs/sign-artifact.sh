#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2022-2024 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

DATA="${1:?usage: $0 <artifact>}"
: "${P11MODULE:?P11MODULE must point to the PKCS#11 module}"

LABEL="ghaf-test-leaf" # Leaf certificate label
TSA_URL="${TSA_URL:-https://freetsa.org/tsr}"
: "${TSA_CA:?TSA_CA must point to the TSA certificate/CA bundle}"
LEAF_CERT_OUT="${LEAF_CERT_OUT:-${LABEL}.pem}"

CSR_FILE="$(mktemp "${LABEL}.csr.XXXX")"
CRT_FILE="$(mktemp "${LABEL}.pem.XXXX")"

cleanup() {
	pkcs11-tool --module "$P11MODULE" --delete-object --type privkey --label "$LABEL" >/dev/null 2>&1 || true
	pkcs11-tool --module "$P11MODULE" --delete-object --type pubkey --label "$LABEL" >/dev/null 2>&1 || true
	rm -f "$CSR_FILE" "$CRT_FILE" "${LABEL}.srl"
}
trap cleanup EXIT

# Create keypair
pkcs11-tool --module "$P11MODULE" --keypairgen --key-type EC:prime256v1 --label "$LABEL"

# Create CSR
openssl req -new \
	-provider pkcs11 -provider default \
	-key "pkcs11:token=NetHSM;object=$LABEL" \
	-out "$CSR_FILE" \
	-subj "/C=FI/ST=Tampere/L=Tampere/O=Ghaf/CN=Ghaf Infra Sign ED25519"

# Sign CSR with a short-lived certificate (allow small clock skew)
START=$(date -u -d "-1 minute" +"%Y%m%d%H%M%SZ")
END=$(date -u -d "+10 minutes" +"%Y%m%d%H%M%SZ")

openssl x509 -req \
	-in "$CSR_FILE" \
	-CA testRoot.pem \
	-CAkey "pkcs11:token=NetHSM;object=testRoot;type=private" \
	-CAcreateserial \
	-out "$CRT_FILE" \
	-not_before "$START" \
	-not_after "$END" \
	-sha256 \
	-provider pkcs11 \
	-provider default

# Persist leaf certificate to a predictable location for downstream verification
cp "$CRT_FILE" "$LEAF_CERT_OUT"

# List objects
echo "---------------------------------------------------------------------"
pkcs11-tool --module "$P11MODULE" \
	--list-objects
echo "---------------------------------------------------------------------"

# Sign data
openssl pkeyutl -sign -rawin \
	-provider pkcs11 -provider default \
	-inkey "pkcs11:token=NetHSM;object=$LABEL;type=private" \
	-in "$DATA" \
	-out "$DATA.sig"

# Timestamp signature (nonce, pinned TSA CA, timeout, and curl failure on HTTP errors)
openssl ts -query \
	-data "$DATA.sig" \
	-sha512 \
	-cert \
	-out "$DATA.sig.tsq"

curl -H "Content-Type: application/timestamp-query" \
	--data-binary @"$DATA.sig.tsq" \
	--fail --show-error --max-time 15 \
	--cacert "$TSA_CA" \
	"$TSA_URL" >"$DATA.sig.tsr"

# Delete keypair
pkcs11-tool --module "$P11MODULE" \
	--delete-object \
	--type privkey \
	--label "$LABEL"
