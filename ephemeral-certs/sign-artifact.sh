#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2022-2024 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0

# This script is expecting $P11MODULE to be set

DATA="${1:?usage: $0 <artifact>}"

LABEL="ghaf-test-leaf" # Leaf certificate label
#DATA="p11nethsm.conf"  # Data to be signed / timestamped

# Create keypair
pkcs11-tool   --module  $P11MODULE  --keypairgen --key-type EC:prime256v1 --label "$LABEL"

# Create CSR
openssl req -new \
  -provider pkcs11 -provider default \
  -key "pkcs11:token=NetHSM;object=$LABEL" \
  -out "$LABEL.csr" \
  -subj "/C=FI/ST=Tampere/L=Tampere/O=Ghaf/CN=Ghaf Infra Sign ED25519"

# Sign CSR
START=$(date -u +"%Y%m%d%H%M%SZ")
END=$(date -u -d "+1 minute" +"%Y%m%d%H%M%SZ")

openssl x509 -req \
	-in "$LABEL.csr" \
	-CA testRoot.pem \
	-CAkey "pkcs11:token=NetHSM;object=testRoot;type=private" \
	-CAcreateserial \
	-out "$LABEL.pem" \
	-not_before "$START" \
	-not_after "$END" \
	-sha256 \
	-provider pkcs11 \
	-provider default

# List objects
echo "---------------------------------------------------------------------"
pkcs11-tool --module /nix/store/ki20py08nij2gmkds7bdmpf0wp07vky6-nethsm-pkcs11-2.0.0/lib/libnethsm_pkcs11.so \
	    --list-objects
echo "---------------------------------------------------------------------"

# Sign data
openssl pkeyutl -sign -rawin \
  -provider pkcs11 -provider default \
  -inkey "pkcs11:token=NetHSM;object=$LABEL;type=private" \
  -in  "$DATA" \
  -out "$DATA.sig"

# Timestamp signature
openssl ts -query \
	-data "$DATA.sig" \
	-no_nonce \
	-sha512 \
	-cert \
	-out "$DATA.sig.tsq"

curl -H "Content-Type: application/timestamp-query" --data-binary @"$DATA.sig.tsq" https://freetsa.org/tsr > "$DATA.sig.tsr"

# Delete keypair
pkcs11-tool --module /nix/store/ki20py08nij2gmkds7bdmpf0wp07vky6-nethsm-pkcs11-2.0.0/lib/libnethsm_pkcs11.so  \
	    --delete-object \
	    --type privkey \
	    --label "$LABEL"

