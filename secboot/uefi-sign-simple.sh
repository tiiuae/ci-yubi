#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2022-2024 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

if ! declare -F uefisign_find_efi_partition >/dev/null; then
  SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
  # shellcheck disable=SC1091
  # shellcheck source=uefi-raw-image-lib.sh
  source "$SCRIPT_DIR/uefi-raw-image-lib.sh"
fi

CERT="$1"
PKEY="$2"
DISK_IMAGE_INPUT="$3"
OUTDIR="${4%/}"

RECOMPRESS=0
IMG_NAME="$(basename "$DISK_IMAGE_INPUT")"
TMPDIR="$(mktemp -d)"
EFI_IMAGE="$TMPDIR/efi-partition.img"

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

detect_image() {
  case "$1" in
  *.zst)
    IMG_NAME=${IMG_NAME%.*}
    RECOMPRESS=1
    input_type="zst"
    ;;
  *.img | *.raw)
    input_type="raw"
    ;;
  *)
    echo "Unknown input file format!" >&2
    exit 1
    ;;
  esac
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

detect_image "$DISK_IMAGE_INPUT"

read -r ESP_START SECTORS < <(uefisign_find_efi_partition "$DISK_IMAGE_INPUT" "$input_type" "$TMPDIR/partition-prefix.img")
ESP_OFFSET=$((ESP_START * 512))
ESP_SIZE=$((SECTORS * 512))
echo "EFI offset: $ESP_OFFSET, size: $ESP_SIZE bytes"

uefisign_extract_raw_range_to_file "$DISK_IMAGE_INPUT" "$input_type" "$ESP_OFFSET" "$ESP_SIZE" "$EFI_IMAGE"

# copy the bootloader
BOOTLOADER="$(mdir -i "$EFI_IMAGE" ::/EFI/BOOT/ | awk '/BOOTAA64|BOOTX64/ {print $1; exit}').EFI"
mcopy -i "$EFI_IMAGE" "::/EFI/BOOT/$BOOTLOADER" "$TMPDIR/"

# find and copy the kernel image
mcopy -i "$EFI_IMAGE" "::/loader/entries/*.conf" "$TMPDIR/loader.conf"
KERNEL_PATH="$(awk '/^linux[[:space:]]/{print $2; exit}' "$TMPDIR/loader.conf")"
if [[ -z "$KERNEL_PATH" ]]; then
  echo "Unable to find kernel path from loader conf!" >&2
  exit 1
fi
mcopy -i "$EFI_IMAGE" "::$KERNEL_PATH" "$TMPDIR/"
KERNEL_NAME="$(basename "$KERNEL_PATH")"

# sign both
sign_file "$TMPDIR/$KERNEL_NAME"
sign_file "$TMPDIR/$BOOTLOADER"

# copy signed files into the image and overwrite the existing files
mcopy -o -i "$EFI_IMAGE" "$TMPDIR/$KERNEL_NAME" "::$(dirname "$KERNEL_PATH")/"
mcopy -o -i "$EFI_IMAGE" "$TMPDIR/$BOOTLOADER" "::/EFI/BOOT/"

# move signed file to outdir, recompressing if it was originally compressed
if [[ "$RECOMPRESS" == 1 ]]; then
  echo "Streaming signed image to zst archive"
  uefisign_write_signed_raw_image "$DISK_IMAGE_INPUT" "$input_type" "$EFI_IMAGE" "$ESP_OFFSET" "$ESP_SIZE" "$OUTDIR/signed_$IMG_NAME.zst" zst
  echo "Wrote signed image to $OUTDIR/signed_$IMG_NAME.zst"
else
  uefisign_write_signed_raw_image "$DISK_IMAGE_INPUT" "$input_type" "$EFI_IMAGE" "$ESP_OFFSET" "$ESP_SIZE" "$OUTDIR/signed_$IMG_NAME" raw
  echo "Wrote signed image to $OUTDIR/signed_$IMG_NAME"
fi
