#!/usr/bin/env bash
set -euo pipefail
echo "---------------- [ Init Slot ] ------------------"
softhsm2-util --init-token --slot 0 --label "UEFIKeys" --so-pin 1234 --pin 7654321
echo "---------------- [ Provisioning HSM ] ------------------"
softhsm2-util --show-slots
./provision-uefi-auth.sh \
  --module /usr/lib/softhsm/libsofthsm2.so \
  --token-label UEFIKeys \
  --pin 7654321 \
  --out /root/out \
  -v
echo "---------------- [ Signing ] ------------------"
./ghaf_sign_iso.sh out/db.crt "pkcs11:token=UEFIKeys;object=DBKey;type=private;pin-value=7654321" out/ghaf.iso out/signed
