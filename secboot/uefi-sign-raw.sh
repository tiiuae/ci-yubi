#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2022-2024 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail
set -E # make ERR traps fire in functions/subshells

log() { echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*"; }

err_report() {
  log "[!] Error on line $1: '$BASH_COMMAND'"
  exit 1
}
trap 'err_report $LINENO' ERR

if ! declare -F uefisign_find_efi_partition >/dev/null; then
  SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
  # shellcheck disable=SC1091
  # shellcheck source=uefi-raw-image-lib.sh
  source "$SCRIPT_DIR/uefi-raw-image-lib.sh"
fi

if [[ $# -ne 4 ]]; then
  log "[!] Usage: $0 <certificate> <private-key> <disk-image.zst> <out-dir>"
  exit 1
fi

CERT="$1"
PKEY="$2"
DISK_IMAGE_ZST="$3"
OUTDIR="$4"

TMPWDIR="$(mktemp -d --suffix .uefisign)"
EFI_IMAGE="$TMPWDIR/efi-partition.img"
SIGNED_BOOTLOADER="$TMPWDIR/BOOTX64.EFI.signed"
SIGNED_UKI="$TMPWDIR/slot.efi.signed"
SIGNED_ZST="$OUTDIR/signed_$(basename "$DISK_IMAGE_ZST")"

on_exit() {
  log "[DEBUG] Cleanup (TMPWDIR:$TMPWDIR)"
  rm -fr "$TMPWDIR"
}
trap on_exit EXIT

log "[DEBUG] Start (TMPWDIR:$TMPWDIR)"
log "[DEBUG] cert: $CERT"
log "[DEBUG] key : $PKEY"

case "$DISK_IMAGE_ZST" in
*.zst)
  input_type="zst"
  log "ZST'ed Image detected"
  ;;
*)
  log "Unsupported input file: $DISK_IMAGE_ZST" >&2
  exit 1
  ;;
esac

fat_path() {
  local p="${1//\\//}"
  [[ "${p:0:1}" == "/" ]] || p="/$p"
  printf '%s' "$p"
}

log "[*] Locating EFI partition offset and size..."
read -r EFI_START SECTORS < <(uefisign_find_efi_partition "$DISK_IMAGE_ZST" "$input_type" "$TMPWDIR/partition-prefix.img")
EFI_OFFSET=$((EFI_START * 512))
EFI_SIZE=$((SECTORS * 512))
log "[*] EFI offset: $EFI_OFFSET, size: $EFI_SIZE bytes"

log "[*] Extracting EFI partition to $EFI_IMAGE..."
uefisign_extract_raw_range_to_file "$DISK_IMAGE_ZST" "$input_type" "$EFI_OFFSET" "$EFI_SIZE" "$EFI_IMAGE"

BOOTLOADER="/EFI/systemd/systemd-bootx64.efi"
if ! mdir -i "$EFI_IMAGE" ::/EFI/systemd/ | awk '/systemd-bootx64\.efi/ {found=1} END{exit found?0:1}' >/dev/null 2>&1; then
  log "[!] Could not find systemd-boot in EFI/systemd/systemd-bootx64.efi"
  exit 1
fi
log "[*] Using systemd bootloader: $BOOTLOADER"
mcopy -i "$EFI_IMAGE" "::$BOOTLOADER" "$TMPWDIR/systemd-bootx64.efi"

# Copy loader entries from the ESP.
mcopy -n -i "$EFI_IMAGE" ::/loader/entries/*.conf "$TMPWDIR"/ 2>/dev/null || true

entry_file="$(
  find "$TMPWDIR" -maxdepth 1 -type f -name '*.conf' -print |
    LC_ALL=C sort |
    tail -n 1 || true
)"

if [[ -z "${entry_file:-}" ]]; then
  log "[!] No loader entry found in ESP (/loader/entries/*.conf)"
  exit 1
fi
log "[*] Using loader entry: $(basename "$entry_file")"

entry_base="$(basename "$entry_file" .conf)"
UKI_DST_REL="/EFI/Linux/${entry_base}.efi"
UKI_BASENAME="$(basename "$UKI_DST_REL")"

EFI_REL="$(awk '/^efi[[:space:]]/{print $2; exit}' "$entry_file" || true)"
if [[ -n "${EFI_REL:-}" ]]; then
  EFI_REL="$(fat_path "$EFI_REL")"
  mcopy -o -i "$EFI_IMAGE" "::${EFI_REL}" "$TMPWDIR/$UKI_BASENAME"
  if [[ "$EFI_REL" != "$UKI_DST_REL" ]]; then
    mrm -i "$EFI_IMAGE" "::${EFI_REL}" 2>/dev/null || true
    awk -v new="${UKI_DST_REL}" '
      BEGIN{done=0}
      /^efi[[:space:]]/ && !done { print "efi " new; done=1; next }
      { print }
    ' "$entry_file" >"$TMPWDIR/tmp_entry"
    mcopy -o -i "$EFI_IMAGE" "$TMPWDIR/tmp_entry" "::/loader/entries/$(basename "$entry_file")"
  fi
else
  LINUX_REL="$(awk '/^linux[[:space:]]/{print $2; exit}' "$entry_file" || true)"
  if [[ -z "${LINUX_REL:-}" ]]; then
    log "[!] No 'linux' or 'efi' line in loader entry"
    exit 1
  fi
  LINUX_REL="$(fat_path "$LINUX_REL")"

  mapfile -t INITRD_REL < <(awk '
    /^initrd[[:space:]]/ {
      for (i=2;i<=NF;i++) print $i
    }' "$entry_file")
  for i in "${!INITRD_REL[@]}"; do
    INITRD_REL[i]="$(fat_path "${INITRD_REL[i]}")"
  done

  sed -n 's/^options[[:space:]]\+//p' "$entry_file" >"$TMPWDIR/cmdline"
  if [[ ! -s "$TMPWDIR/cmdline" ]]; then
    log "[!] No 'options' line in loader entry"
    exit 1
  fi
  log "[DEBUG] kernel cmdline: $(cat "$TMPWDIR/cmdline")"

  mcopy -o -i "$EFI_IMAGE" "::${LINUX_REL}" "$TMPWDIR/bzImage.efi"

  INITRD_ARGS=()
  if [[ "${#INITRD_REL[@]}" -gt 0 ]]; then
    for r in "${INITRD_REL[@]}"; do
      base="$(basename "$r")"
      mcopy -o -i "$EFI_IMAGE" "::${r}" "$TMPWDIR/$base"
      INITRD_ARGS+=(--initrd "$TMPWDIR/$base")
    done
  else
    log "[*] No initrd lines in loader entry (OK for UKI if cmdline is complete)"
  fi

  log "[*] Building UKI with original cmdline from loader entry..."
  ukify build \
    --linux "$TMPWDIR/bzImage.efi" \
    "${INITRD_ARGS[@]}" \
    --cmdline "@$TMPWDIR/cmdline" \
    --output "$TMPWDIR/$UKI_BASENAME"

  awk -v new="${UKI_DST_REL}" '
    BEGIN{done=0}
    /^linux[[:space:]]/ && !done { print "efi " new; done=1; next }
    /^initrd[[:space:]]/ { next }
    { print }
  ' "$entry_file" >"$TMPWDIR/tmp_entry"

  log "[*] Updating loader entry to boot the UKI..."
  mcopy -o -i "$EFI_IMAGE" "$TMPWDIR/tmp_entry" "::/loader/entries/$(basename "$entry_file")"
fi

# defaults
PKEY_PROV="file"
CERT_PROV="file"

if [[ "$PKEY" == pkcs11:* ]]; then
  PKEY_PROV="provider:pkcs11"
  log "[*] Interpreted private key as pkcs11 url"
fi

if [[ "$CERT" == pkcs11:* ]]; then
  CERT_PROV="provider:pkcs11"
  log "[*] Interpreted certificate as pkcs11 url"
fi

log "[*] Signing the UKI image ..."
systemd-sbsign sign \
  --private-key-source "$PKEY_PROV" \
  --private-key "$PKEY" \
  --certificate-source "$CERT_PROV" \
  --certificate "$CERT" \
  --output "$SIGNED_UKI" "$TMPWDIR/$UKI_BASENAME"

log "[*] Placing signed UKI at ${UKI_DST_REL} in the ESP..."
mcopy -o -i "$EFI_IMAGE" "$SIGNED_UKI" "::${UKI_DST_REL}"

log "[*] Signing systemd-boot ..."
systemd-sbsign sign \
  --private-key-source "$PKEY_PROV" \
  --private-key "$PKEY" \
  --certificate-source "$CERT_PROV" \
  --certificate "$CERT" \
  --output "$SIGNED_BOOTLOADER" "$TMPWDIR/systemd-bootx64.efi"

log "[*] Updating EFI/systemd/systemd-bootx64.efi ..."
mcopy -o -i "$EFI_IMAGE" "$SIGNED_BOOTLOADER" "::$BOOTLOADER"

log "[*] Updating fallback EFI/BOOT/BOOTX64.EFI ..."
mcopy -o -i "$EFI_IMAGE" "$SIGNED_BOOTLOADER" "::/EFI/BOOT/BOOTX64.EFI"

mkdir -p "$OUTDIR"
log "[*] Streaming signed image to $SIGNED_ZST..."
uefisign_write_signed_raw_image "$DISK_IMAGE_ZST" "$input_type" "$EFI_IMAGE" "$EFI_OFFSET" "$EFI_SIZE" "$SIGNED_ZST" zst

log "[+] EFI Signing Success!"
