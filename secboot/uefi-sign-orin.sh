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

if [[ $# != 4 ]]; then
  echo "Usage: uefisign-orin CERT KEY BUILD_DIR OUTPUT_DIR" >&2
  exit 1
fi
CERT="$1"
PKEY="$2"
BUILD_DIR="$3"
[[ -d "$BUILD_DIR" ]] || { echo "Input must be a build result directory" >&2; exit 1; }
BUILD_DIR=$(realpath "$BUILD_DIR")
OUTDIR="${4%/}"

PUBLISH_DIR=""
UKI=0
RECOMPRESS=0
TMPDIR="$(mktemp -d)"
EFI_IMAGE="$TMPDIR/efi-partition.img"

cleanup() {
  rm -fr "$TMPDIR"
  if [[ -n "$PUBLISH_DIR" ]]; then rm -rf "$OUTDIR"; fi
}
trap cleanup EXIT

mkdir -p "$OUTDIR"
[[ -z $(ls -A "$OUTDIR") ]] || { echo "Output directory must be empty" >&2; exit 1; }
PUBLISH_DIR=$(realpath "$OUTDIR")
OUTDIR=$(mktemp -d "${PUBLISH_DIR}.signing-XXXXXXXX")
shopt -s nullglob
images=("$BUILD_DIR"/*.{img,raw,img.zst,raw.zst} "$BUILD_DIR"/sd-image/*.{img,raw,img.zst,raw.zst})
[[ ${#images[@]} == 1 ]] || { echo "Expected exactly one disk image" >&2; exit 1; }
DISK_IMAGE=${images[0]}
for name in esp.offset esp.size root.offset root.size; do
  cp "$BUILD_DIR/$name" "$OUTDIR/$name"
done

IMG_NAME="$(basename "$DISK_IMAGE")"

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

detect_uki() {
  if mdir -i "$1" ::/EFI/LINUX/ 2>/dev/null | grep -qi 'nixos'; then
    UKI=1
  fi
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

sign_recovery() {
  local source="$BUILD_DIR/recovery" output="$OUTDIR/recovery"
  local cmdline flash_id
  local provider=()

  cmdline=$(cat "$source/cmdline")
  if [[ $cmdline =~ (^|[[:space:]])flash-id= ]]; then
    echo "Recovery input already contains flash-id" >&2
    exit 1
  fi
  if [[ "$PKEY" == pkcs11:* || "$CERT" == pkcs11:* ]]; then
    provider=(-provider default -provider pkcs11)
  fi

  mkdir "$output"
  openssl x509 "${provider[@]}" -in "$CERT" -out "$output/db.crt"
  cp "$source/Image" "$output/Image"
  chmod u+w "$output/Image"
  sign_file "$output/Image"
  sbverify --cert "$output/db.crt" "$output/Image"

  flash_id=$(uuidgen --random)
  mkbootimg --header_version 0 --pagesize 2048 \
    --kernel "$output/Image" --ramdisk "$source/initrd" \
    --board nvme-flash --cmdline "$cmdline flash-id=$flash_id" \
    --output "$output/boot.img"

  openssl cms -sign "${provider[@]}" -binary -signer "$output/db.crt" \
    -inkey "$PKEY" -in "$output/boot.img" \
    -outform DER -out "$output/boot.img.sig"
  openssl cms -verify -binary -inform DER -in "$output/boot.img.sig" \
    -content "$output/boot.img" -noverify -out /dev/null
  if [[ $(stat -c%s "$output/boot.img.sig") -gt 4096 ]]; then
    echo "Recovery CMS signature exceeds NVIDIA's 4096-byte slot" >&2
    exit 1
  fi
  truncate -s %4096 "$output/boot.img"
  cat "$output/boot.img.sig" >> "$output/boot.img"

  printf '%s\n' "$flash_id" > "$output/flash-id"
  rm "$output/Image" "$output/db.crt" "$output/boot.img.sig"
}

detect_image "$DISK_IMAGE"

read -r ESP_START SECTORS < <(uefisign_find_efi_partition "$DISK_IMAGE" "$input_type" "$TMPDIR/partition-prefix.img")
ESP_OFFSET=$((ESP_START * 512))
ESP_SIZE=$((SECTORS * 512))
echo "EFI offset: $ESP_OFFSET, size: $ESP_SIZE bytes"

uefisign_extract_raw_range_to_file "$DISK_IMAGE" "$input_type" "$ESP_OFFSET" "$ESP_SIZE" "$EFI_IMAGE"

detect_uki "$EFI_IMAGE"

# copy the bootloader
BOOTLOADER="$(mdir -i "$EFI_IMAGE" ::/EFI/BOOT/ | awk '/BOOTAA64|BOOTX64/ {print $1; exit}').EFI"
mcopy -i "$EFI_IMAGE" "::/EFI/BOOT/$BOOTLOADER" "$TMPDIR/"

if [[ "$UKI" == 0 ]]; then
  # find and copy the kernel image
  mcopy -i "$EFI_IMAGE" "::/loader/entries/*.conf" "$TMPDIR/loader.conf"
  KERNEL_PATH="$(awk '/^linux[[:space:]]/{print $2; exit}' "$TMPDIR/loader.conf")"
else
  KERNEL_PATH="/EFI/Linux/nixos.efi"
fi

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
  uefisign_write_signed_raw_image "$DISK_IMAGE" "$input_type" "$EFI_IMAGE" "$ESP_OFFSET" "$ESP_SIZE" "$OUTDIR/signed_$IMG_NAME.zst" zst
  echo "Wrote signed image to $OUTDIR/signed_$IMG_NAME.zst"
else
  uefisign_write_signed_raw_image "$DISK_IMAGE" "$input_type" "$EFI_IMAGE" "$ESP_OFFSET" "$ESP_SIZE" "$OUTDIR/signed_$IMG_NAME" raw
  echo "Wrote signed image to $OUTDIR/signed_$IMG_NAME"
fi

if [[ -d "$BUILD_DIR/recovery" ]]; then
  sign_recovery
fi
mv -T "$OUTDIR" "$PUBLISH_DIR"
