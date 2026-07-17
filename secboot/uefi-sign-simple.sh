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

fat_path() {
  local path="${1//\\//}"
  [[ "${path:0:1}" == "/" ]] || path="/$path"
  printf '%s' "$path"
}

is_pe_binary() {
  file -b -- "$1" | grep -Eq '(^|[[:space:]])PE32(\+)?[[:space:]]|EFI application'
}

copy_from_esp() {
  local esp_path="$1"
  local local_path="$2"

  mcopy -i "$EFI_IMAGE" "::$esp_path" "$local_path"
}

copy_to_esp() {
  local local_path="$1"
  local esp_path="$2"

  mcopy -o -i "$EFI_IMAGE" "$local_path" "::$esp_path"
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
KERNEL_PATH="$(awk '/^linux[[:space:]]/{gsub(/\r$/, "", $2); print $2; exit}' "$TMPDIR/loader.conf")"
if [[ -z "$KERNEL_PATH" ]]; then
  echo "Unable to find kernel path from loader conf!" >&2
  exit 1
fi
KERNEL_PATH="$(fat_path "$KERNEL_PATH")"
copy_from_esp "$KERNEL_PATH" "$TMPDIR/"
KERNEL_NAME="$(basename "$KERNEL_PATH")"

# Find any initrds referenced by the loader entry. Plain cpio initrds are
# intentionally skipped later so existing ESP-side flows keep working.
mapfile -t INITRD_PATHS < <(awk '
  /^initrd[[:space:]]/ {
    for (i = 2; i <= NF; i++) {
      gsub(/\r$/, "", $i)
      print $i
    }
  }' "$TMPDIR/loader.conf")

# sign bootloader and kernel
sign_file "$TMPDIR/$KERNEL_NAME"
sign_file "$TMPDIR/$BOOTLOADER"

# copy signed files into the image and overwrite the existing files
copy_to_esp "$TMPDIR/$KERNEL_NAME" "$KERNEL_PATH"
mcopy -o -i "$EFI_IMAGE" "$TMPDIR/$BOOTLOADER" "::/EFI/BOOT/"

if [[ "${#INITRD_PATHS[@]}" -gt 0 ]]; then
  for index in "${!INITRD_PATHS[@]}"; do
    INITRD_PATHS[index]="$(fat_path "${INITRD_PATHS[index]}")"
    INITRD_NAME="$(basename "${INITRD_PATHS[index]}")"
    INITRD_LOCAL="$TMPDIR/initrd-$index-$INITRD_NAME"

    if ! copy_from_esp "${INITRD_PATHS[index]}" "$INITRD_LOCAL"; then
      echo "Skipping initrd $INITRD_NAME: not found in ESP"
      continue
    fi
    if is_pe_binary "$INITRD_LOCAL"; then
      sign_file "$INITRD_LOCAL"
      copy_to_esp "$INITRD_LOCAL" "${INITRD_PATHS[index]}"
    else
      echo "Skipping non-PE initrd $INITRD_NAME"
    fi
  done
fi

# move signed file to outdir, recompressing if it was originally compressed
if [[ "$RECOMPRESS" == 1 ]]; then
  echo "Streaming signed image to zst archive"
  uefisign_write_signed_raw_image "$DISK_IMAGE_INPUT" "$input_type" "$EFI_IMAGE" "$ESP_OFFSET" "$ESP_SIZE" "$OUTDIR/signed_$IMG_NAME.zst" zst
  echo "Wrote signed image to $OUTDIR/signed_$IMG_NAME.zst"
else
  uefisign_write_signed_raw_image "$DISK_IMAGE_INPUT" "$input_type" "$EFI_IMAGE" "$ESP_OFFSET" "$ESP_SIZE" "$OUTDIR/signed_$IMG_NAME" raw
  echo "Wrote signed image to $OUTDIR/signed_$IMG_NAME"
fi
