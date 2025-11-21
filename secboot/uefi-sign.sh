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

if [[ $# -ne 4 ]]; then
  log "[!] Usage: $0 <certificate> <private-key> <disk-image.zst> <out-dir>"
  exit 1
fi

CERT="$1"
PKEY="$2"
DISK_IMAGE_ZST="$3"
OUTDIR="$4"

TMPWDIR="$(mktemp -d --suffix .uefisign)"
DISK_IMAGE="$TMPWDIR/disk.raw"
EFI_IMAGE="$TMPWDIR/efi-partition.img"
SIGNED_EFI="$TMPWDIR/BOOTX64.EFI.signed"
SIGNED_ZST="$OUTDIR/signed_ghaf_0.0.1.raw.zst"

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

if [[ "$input_type" == "zst" ]]; then
  log "[*] Decompressing image: $DISK_IMAGE_ZST -> $DISK_IMAGE"
  zstd -d "$DISK_IMAGE_ZST" -o "$DISK_IMAGE"
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

# Copy all loader entries from ESP to TMPWDIR
# (ignore errors if globs don't match)
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
  INITRD_REL[i]="$(fat_path "${INITRD_REL[i]}")"
done

# exact kernel cmdline (contains systemConfig= and init=)
sed -n 's/^options[[:space:]]\+//p' "$entry_file" >"$TMPWDIR/cmdline"
if [[ ! -s "$TMPWDIR/cmdline" ]]; then
  log "[!] No 'options' line in loader entry"
  exit 1
fi
log "[DEBUG] kernel cmdline: $(cat "$TMPWDIR/cmdline")"

# Kernel: copy from the ESP path referenced by the entry (not a wildcard)
mcopy -o -i "$EFI_IMAGE" "::${LINUX_REL}" "$TMPWDIR/bzImage.efi"

# Initrds: copy each one to a local file and collect --initrd args
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
  --output "$TMPWDIR/BOOTX64.EFI.uki"

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
  --output "$SIGNED_EFI" "$TMPWDIR/BOOTX64.EFI.uki"

UKI_DST_REL="/EFI/nixos/uki-signed.efi"
log "[*] Placing signed UKI at ${UKI_DST_REL} in the ESP..."
mcopy -o -i "$EFI_IMAGE" "$SIGNED_EFI" "::${UKI_DST_REL}"

# Re-write loader entry: linux → UKI, remove initrd lines (keep options)
awk -v new="${UKI_DST_REL}" '
  BEGIN{done=0}
  /^linux[[:space:]]/ && !done { print "linux " new; done=1; next }
  /^initrd[[:space:]]/ { next }
  { print }
' "$entry_file" >"$TMPWDIR/tmp_entry"

log "[*] Updating loader entry to boot the UKI..."
mcopy -o -i "$EFI_IMAGE" "$TMPWDIR/tmp_entry" "::/loader/entries/$(basename "$entry_file")"

# Also refresh fallback BOOTX64.EFI for good measure
log "[*] Updating fallback EFI/BOOT/BOOTX64.EFI ..."
mcopy -o -i "$EFI_IMAGE" "$SIGNED_EFI" ::/EFI/BOOT/BOOTX64.EFI

log "[*] Writing updated EFI partition back to disk image..."
dd if="$EFI_IMAGE" of="$DISK_IMAGE" bs=512 seek="$EFI_START" conv=notrunc status=none

log "[+] Signed image updated in $DISK_IMAGE"

mkdir -p "$OUTDIR"
if [[ "$input_type" == "zst" ]]; then
  log "[*] Recompressing signed image to $SIGNED_ZST..."
  zstd -f "$DISK_IMAGE" -o "$SIGNED_ZST"
fi

log "[+] EFI Signing Success!"
