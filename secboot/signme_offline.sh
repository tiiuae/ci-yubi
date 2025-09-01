#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2022-2024 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail
set -E  # make ERR traps fire in functions/subshells

log() { echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*"; }

err_report() {
  log "[!] Error on line $1"
  exit 1
}
trap 'err_report $LINENO' ERR

if [[ $# -ne 4 ]]; then
  log "[!] Usage: $0 <certificate> <private-key> <disk-image.zst|.iso> <out-dir>"
  exit 1
fi

CERT="$1"
PKEY="$2"
DISK_IMAGE_ZST="$3"
SUBDIR="$4"

DISK_IMAGE="disk.raw"
DISK_IMAGE_ISO="disk.iso"
EFI_IMAGE="efi-partition.img"
SIGNED_EFI="BOOTX64.EFI.signed"
ZSTD_IMAGE="ghaf_0.0.1.raw.zst"

cleanup() {
  log "[DEBUG] Cleanup"
  rm -f -- "bzImage.efi" "initrd.efi" "BOOTX64.EFI.uki"
  rm -f -- "${SIGNED_EFI:-}" "${EFI_IMAGE:-}" "${DISK_IMAGE:-}"
}
on_exit(){ rc=$?; cleanup; exit "$rc"; }
trap on_exit EXIT

log "[DEBUG] cert: $CERT"
log "[DEBUG] key : $PKEY"

case "$DISK_IMAGE_ZST" in
  *.iso)
    input_type="iso"
    log "ISO Image detected"
    log "PWD: $PWD"
    ./signiso.sh "$DISK_IMAGE_ZST"
    exit 0
    ;;
  *.zst)
    input_type="zst"
    log "ZST'ed Image detected"
    ;;
  *)
    log "Unsupported input file: $DISK_IMAGE_ZST" >&2
    exit 1
    ;;
esac

log "[*] Cleaning up any previous local artifacts..."
rm -f "$DISK_IMAGE" "$DISK_IMAGE_ISO" "BOOTX64.EFI.uki" "$SIGNED_EFI"

if [[ "$input_type" == "zst" ]]; then
  log "[*] Decompressing image: $DISK_IMAGE_ZST -> $DISK_IMAGE"
  zstd -d "$DISK_IMAGE_ZST" -o "$DISK_IMAGE"
else
  cp -f "$DISK_IMAGE_ZST" "$DISK_IMAGE_ISO"
  DISK_IMAGE=$DISK_IMAGE_ISO
fi
log "[*] Disk image: $DISK_IMAGE"
chmod 666 "$DISK_IMAGE" || true

log "[*] Locating EFI partition offset and size..."
read -r EFI_START SECTORS < <(fdisk -l "$DISK_IMAGE" | awk '$0 ~ /EFI / { print $2, $4 }')
if [[ -z "${EFI_START:-}" || -z "${SECTORS:-}" ]]; then
  log "[!] Could not determine EFI partition info from image"
  exit 1
fi
EFI_OFFSET=$((EFI_START * 512))
EFI_SIZE=$((SECTORS * 512))
log "[*] EFI offset: $EFI_OFFSET, size: $EFI_SIZE bytes"

log "[*] Extracting EFI partition to $EFI_IMAGE..."
dd if="$DISK_IMAGE" of="$EFI_IMAGE" bs=512 skip="$EFI_START" count="$SECTORS" status=none

fat_path() {
  # Convert backslashes to forward slashes, ensure leading slash
  local p="${1//\\//}"
  [[ "${p:0:1}" == "/" ]] || p="/$p"
  printf '%s' "$p"
}

TMPENT="$(mktemp -d)"
trap 'rm -rf "$TMPENT"; on_exit' EXIT

# Copy all loader entries from ESP to TMPENT
# (ignore errors if globs don't match)
mcopy -n -i "$EFI_IMAGE" ::/loader/entries/*.conf "$TMPENT"/ 2>/dev/null || true
entry_file="$(ls -1 "$TMPENT"/*.conf 2>/dev/null | sort | tail -1 || true)"
if [[ -z "${entry_file:-}" ]]; then
  log "[!] No loader entry found in ESP (/loader/entries/*.conf)"
  exit 1
fi
log "[*] Using loader entry: $(basename "$entry_file")"

# linux path (relative to ESP)
LINUX_REL="$(awk '/^linux[[:space:]]/{print $2; exit}' "$entry_file" || true)"
if [[ -z "${LINUX_REL:-}" ]]; then
  log "[!] No 'linux' line in loader entry"
  exit 1
fi
LINUX_REL="$(fat_path "$LINUX_REL")"

# 0..N initrd paths (support multiple args per line)
mapfile -t INITRD_REL < <(awk '
  /^initrd[[:space:]]/ {
    for (i=2;i<=NF;i++) print $i
  }' "$entry_file")
for i in "${!INITRD_REL[@]}"; do
  INITRD_REL[$i]="$(fat_path "${INITRD_REL[$i]}")"
done

# exact kernel cmdline (contains systemConfig= and init=)
CMDLINE_FILE="$(mktemp)"
trap 'rm -rf "$TMPENT" "$CMDLINE_FILE"; on_exit' EXIT
sed -n 's/^options[[:space:]]\+//p' "$entry_file" > "$CMDLINE_FILE"
if [[ ! -s "$CMDLINE_FILE" ]]; then
  log "[!] No 'options' line in loader entry"
  exit 1
fi
log "[DEBUG] kernel cmdline: $(cat "$CMDLINE_FILE")"

# Kernel: copy from the ESP path referenced by the entry (not a wildcard)
mcopy -o -i "$EFI_IMAGE" "::${LINUX_REL}" bzImage.efi

# Initrds: copy each one to a local file and collect --initrd args
INITRD_ARGS=()
if [[ "${#INITRD_REL[@]}" -gt 0 ]]; then
  for r in "${INITRD_REL[@]}"; do
    base="$(basename "$r")"
    mcopy -o -i "$EFI_IMAGE" "::${r}" "$base"
    INITRD_ARGS+=( --initrd "$base" )
  done
else
  log "[*] No initrd lines in loader entry (OK for UKI if cmdline is complete)"
fi

log "[*] Building UKI with original cmdline from loader entry..."
ukify build \
  --linux bzImage.efi \
  "${INITRD_ARGS[@]}" \
  --cmdline "@$CMDLINE_FILE" \
  --output BOOTX64.EFI.uki

log "[*] Signing the UKI image ..."
nix run --accept-flake-config --option builders '' --option max-jobs 1 \
  github:tiiuae/sbsigntools -- \
  --keyform PEM --key "$PKEY" --cert "$CERT" \
  --output "$SIGNED_EFI" BOOTX64.EFI.uki

UKI_DST_REL="/EFI/nixos/uki-signed.efi"
log "[*] Placing signed UKI at ${UKI_DST_REL} in the ESP..."
mcopy -o -i "$EFI_IMAGE" "$SIGNED_EFI" "::${UKI_DST_REL}"

# Re-write loader entry: linux → UKI, remove initrd lines (keep options)
tmp_entry_edit="$(mktemp)"
awk -v new="${UKI_DST_REL}" '
  BEGIN{done=0}
  /^linux[[:space:]]/ && !done { print "linux " new; done=1; next }
  /^initrd[[:space:]]/ { next }
  { print }
' "$entry_file" > "$tmp_entry_edit"

log "[*] Updating loader entry to boot the UKI..."
mcopy -o -i "$EFI_IMAGE" "$tmp_entry_edit" "::/loader/entries/$(basename "$entry_file")"
rm -f "$tmp_entry_edit"

# Also refresh fallback BOOTX64.EFI for good measure
log "[*] Updating fallback EFI/BOOT/BOOTX64.EFI ..."
mcopy -o -i "$EFI_IMAGE" "$SIGNED_EFI" ::/EFI/BOOT/BOOTX64.EFI

log "[*] Writing updated EFI partition back to disk image..."
dd if="$EFI_IMAGE" of="$DISK_IMAGE" bs=512 seek="$EFI_START" conv=notrunc status=none

log "[+] Signed image updated in $DISK_IMAGE"

mkdir -p "$SUBDIR"
if [[ "$input_type" == "zst" ]]; then
  SIGNED_ZST="signed_$ZSTD_IMAGE"
  log "[*] Recompressing signed image to $SIGNED_ZST..."
  zstd -f "$DISK_IMAGE" -o "$SIGNED_ZST"
  log "[*] Move signed image to $SUBDIR"
  mv -f "$SIGNED_ZST" "$SUBDIR/"
else
  log "[*] Move signed ISO to $SUBDIR"
  mv -f "$DISK_IMAGE_ISO" "$SUBDIR/"
fi

log "[+] EFI Signing Success!"
