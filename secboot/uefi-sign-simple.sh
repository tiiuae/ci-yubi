#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2022-2024 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

CERT="$1"
PKEY="$2"
DISK_IMAGE="$3"
OUTDIR="${4%/}"

RECOMPRESS=0
IMG_NAME="$(basename "$DISK_IMAGE")"
TMPDIR="$(mktemp -d)"

cleanup() {
  rm -fr "$TMPDIR"
}
trap cleanup EXIT

if [[ "$PKEY" == pkcs11:* ]]; then
  PKEY_PROV="provider:pkcs11"
fi
if [[ "$CERT" == pkcs11:* ]]; then
  CERT_PROV="provider:pkcs11"
fi

decompress_image() {
  case "$1" in
  *.zst)
    IMG_NAME=${IMG_NAME%.*}
    RECOMPRESS=1
    echo "Decompressing zst archive"
    zstd -d "$1" -o "$TMPDIR/$IMG_NAME"
    ;;
  *.img | *.raw)
    cp "$1" "$TMPDIR/$IMG_NAME"
    ;;
  *)
    echo "Unknown input file format!" >&2
    exit 1
    ;;
  esac
  DISK_IMAGE="$TMPDIR/$IMG_NAME"
}

get_esp_offset() {
  ESP_GUID="C12A7328-F81F-11D2-BA4B-00A0C93EC93B" # well known
  # aarch64 orin images have type="b" on the esp
  ESP_START=$(sfdisk --json "$DISK_IMAGE" | jq -r ".partitiontable.partitions[] | select(.type==\"b\" or .type==\"$ESP_GUID\") | .start")
  if [[ -z "$ESP_START" ]]; then
    echo "Unable to automatically detect ESP partition offset!" >&2
    exit 1
  fi
  echo $(("$ESP_START" * 512))
}

sign_file() {
  echo "Signing $(basename "$1")"
  systemd-sbsign sign \
    --private-key-source "${PKEY_PROV:-file}" \
    --private-key "$PKEY" \
    --certificate-source "${CERT_PROV:-file}" \
    --certificate "$CERT" \
    --output "$1" "$1"
}

decompress_image "$DISK_IMAGE"
ESP_OFFSET="$(get_esp_offset)"

# copy the bootloader
BOOTLOADER="$(mdir -i "$DISK_IMAGE@@$ESP_OFFSET" ::/EFI/BOOT/ | awk '/BOOTAA64|BOOTX64/ {print $1; exit}').EFI"
mcopy -i "$DISK_IMAGE@@$ESP_OFFSET" "::/EFI/BOOT/$BOOTLOADER" "$TMPDIR/"

# find and copy the kernel image
mcopy -i "$DISK_IMAGE@@$ESP_OFFSET" "::/loader/entries/*.conf" "$TMPDIR/loader.conf"
KERNEL_PATH="$(awk '/^linux[[:space:]]/{print $2; exit}' "$TMPDIR/loader.conf")"
if [[ -z "$KERNEL_PATH" ]]; then
  echo "Unable to find kernel path from loader conf!" >&2
  exit 1
fi
mcopy -i "$DISK_IMAGE@@$ESP_OFFSET" "::$KERNEL_PATH" "$TMPDIR/"
KERNEL_NAME="$(basename "$KERNEL_PATH")"

# sign both
sign_file "$TMPDIR/$KERNEL_NAME"
sign_file "$TMPDIR/$BOOTLOADER"

# copy signed files into the image and overwrite the existing files
mcopy -o -i "$DISK_IMAGE@@$ESP_OFFSET" "$TMPDIR/$KERNEL_NAME" "::$(dirname "$KERNEL_PATH")/"
mcopy -o -i "$DISK_IMAGE@@$ESP_OFFSET" "$TMPDIR/$BOOTLOADER" "::/EFI/BOOT/"

# move signed file to outdir, recompressing if it was originally compressed
if [[ "$RECOMPRESS" == 1 ]]; then
  echo "Recompressing signed image to zst archive"
  zstd -f "$DISK_IMAGE" -o "$DISK_IMAGE.zst"
  mv "$DISK_IMAGE.zst" "$OUTDIR/signed_$IMG_NAME.zst"
  echo "Wrote signed image to $OUTDIR/signed_$IMG_NAME.zst"
else
  mv "$DISK_IMAGE" "$OUTDIR/signed_$IMG_NAME"
  echo "Wrote signed image to $OUTDIR/signed_$IMG_NAME"
fi
