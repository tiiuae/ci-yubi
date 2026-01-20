#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2022-2024 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

ARTIFACT="${1:?usage: $0 <artifact> <signature> <tsr> <leaf_cert> <tsa_ca> <our_ca>}"
SIG="${2:?}"
TSR="${3:?}"
LEAF="${4:?}"
TSA_CA="${5:?}"
OUR_CA="${6:?}"

# Verify signature
openssl x509 -in "$LEAF" -pubkey -noout > "$LEAF.pub"
openssl pkeyutl -verify \
	-rawin -pubin \
	-inkey "$LEAF.pub" \
	-sigfile "$SIG" \
	-in "$ARTIFACT"

# Verify TSR (cryptographic)
openssl ts -verify \
  -in "$TSR" \
  -data "$SIG" \
  -CAfile "$TSA_CA" \
  >/dev/null

# Extract timestamp time (RFC3161 genTime)
TS_TIME_STR=$(
  openssl ts -reply -in "$TSR" -text 2>/dev/null \
  | awk -F': ' '/^Time stamp: /{print $2; exit}'
)

if [[ -z "${TS_TIME_STR}" ]]; then
  echo "ERROR: could not extract Time stamp from TSR" >&2
  exit 2
fi

# Convert to epoch (UTC).
TS_EPOCH=$(date -u -d "$TS_TIME_STR" +%s)

# Extract leaf validity
NB_STR=$(openssl x509 -in "$LEAF" -noout -startdate | cut -d= -f2-)
NA_STR=$(openssl x509 -in "$LEAF" -noout -enddate   | cut -d= -f2-)

NB_EPOCH=$(date -u -d "$NB_STR" +%s)
NA_EPOCH=$(date -u -d "$NA_STR" +%s)

echo "TS: $TS_TIME_STR"
echo "CRT: NB: $NB_STR NA: $NA_STR"

# Compare
if (( TS_EPOCH < NB_EPOCH )); then
  echo "FAIL: timestamp is before leaf notBefore"
  exit 3
fi

if (( TS_EPOCH > NA_EPOCH )); then
  echo "FAIL: timestamp is after leaf notAfter"
  exit 4
fi

echo "OK: timestamp is within leaf certificate validity window"
