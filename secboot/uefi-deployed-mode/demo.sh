#!/usr/bin/env bash
set -euo pipefail

softhsm2-util --init-token --slot 0 --label "UEFIKeys" --so-pin 1234 --pin 7654321
softhsm2-util --show-slots
./provision-uefi-auth.sh \
  --module /usr/lib/softhsm/libsofthsm2.so \
  --token-label UEFIKeys \
  --pin 7654321 \
  --out /root/out \
  -v
