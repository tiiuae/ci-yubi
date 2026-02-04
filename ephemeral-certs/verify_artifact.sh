#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2022-2024 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

# Example usage:
# ./verify_artifact.sh test test.sig test.sig.tsr ghaf-test-leaf.pem cacert.pem ca/pki-out/root-ca.pem ca/pki-out/intermediate-ca.pem

ARTIFACT="${1:?usage: $0 ARTIFACT SIG TSR LEAF TSA_CA TRUST_ANCHOR [CHAIN]}"
SIG="${2:?}"
TSR="${3:?}"
LEAF="${4:?}"
TSA_CA="${5:?}"
TRUST_ANCHOR="${6:?}" # pinned root or (preferably) pinned intermediate
CHAIN="${7:-}"        # optional: intermediates between leaf and trust anchor

# 0) Verify leaf certificate chains to the pinned trust anchor
# If TRUST_ANCHOR is a root, CHAIN should contain intermediates.
# If TRUST_ANCHOR is the intermediate that signed the leaf, CHAIN can be empty.

# Extract timestamp time as epoch seconds (example uses openssl output parsing)
TSR_TIME_STR="$(openssl ts -reply -in "$TSR" -text | awk -F': ' '/Time stamp:/{print $2; exit}')"
TSR_EPOCH="$(date -u -d "$TSR_TIME_STR" +%s)"

echo "Step 0 - verify leaf cert chains pinning to trust anchor attime: $TSR_EPOCH"

if [[ -n "$CHAIN" ]]; then
	openssl verify -purpose any -CAfile "$TRUST_ANCHOR" -untrusted "$CHAIN" -attime "$TSR_EPOCH" "$LEAF" >/dev/null
else
	openssl verify -purpose any -CAfile "$TRUST_ANCHOR" -attime "$TSR_EPOCH" "$LEAF" >/dev/null
fi

# Enforce leaf constraints
# Require Code Signing EKU
openssl x509 -in "$LEAF" -noout -text | grep -q "Extended Key Usage" && \
   openssl x509 -in "$LEAF" -noout -text | grep -q "Code Signing"

echo "Step 1 - Verify artifact signature using leaf's pubkey"
# 1) Verify artifact signature using leaf public key
openssl x509 -in "$LEAF" -pubkey -noout > leaf.pub.pem

openssl dgst -sha256 -verify leaf.pub.pem -signature "$SIG" "$ARTIFACT"

echo "Step 2 - Verify TSR"
# 2) Verify TSR cryptographically (timestamp token signs the SIG)
openssl ts -verify \
	-in "$TSR" \
	-data "$SIG" \
	-CAfile "$TSA_CA" \
	>/dev/null

echo "Step 3 - Extract timestamp"
# 3) Extract timestamp time (RFC3161 genTime)
TS_TIME_STR=$(
	openssl ts -reply -in "$TSR" -text 2>/dev/null |
		awk -F': ' '/^Time stamp: /{print $2; exit}'
)
if [[ -z "${TS_TIME_STR}" ]]; then
	echo "ERROR: could not extract Time stamp from TSR" >&2
	exit 2
fi

# Convert to epoch (UTC)
TS_EPOCH=$(date -u -d "$TS_TIME_STR" +%s)

# Extract leaf validity
NB_STR=$(openssl x509 -in "$LEAF" -noout -startdate | cut -d= -f2-)
NA_STR=$(openssl x509 -in "$LEAF" -noout -enddate | cut -d= -f2-)
NB_EPOCH=$(date -u -d "$NB_STR" +%s)
NA_EPOCH=$(date -u -d "$NA_STR" +%s)

echo "TS:  $TS_TIME_STR"
echo "CRT: NB: $NB_STR NA: $NA_STR"

# Compare
if ((TS_EPOCH < NB_EPOCH)); then
	echo "FAIL: timestamp is before leaf notBefore"
	exit 3
fi
if ((TS_EPOCH > NA_EPOCH)); then
	echo "FAIL: timestamp is after leaf notAfter"
	exit 4
fi

echo "OK: signature valid; leaf chains to pinned trust anchor; TSR valid and within leaf validity window"
