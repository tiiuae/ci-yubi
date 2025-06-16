#!/usr/bin/env bash
set -euo pipefail

DISK_IMAGE_ZST="$1"
DISK_IMAGE="disk.raw"
EFI_IMAGE="efi-partition.img"
SIGNED_EFI="BOOTX64.EFI.signed"
CERT="uefi-signing-cert.pem"
KEY="vault:ghaf-secureboot-testkv:uefi-signing-key"

REPO="harbor.ppclabz.net/ghaf-secboot/ghaf-uefi"
TAG="signed"
ZSTD_IMAGE="ghaf_0.0.1.raw.zst"

oras login harbor.ppclabz.net -u "$ORAS_USERNAME" -p "$ORAS_PASSWORD"

rm -rf $DISK_IMAGE $SIGNED_EFI BOOTX64.EFI

echo "[*] Decompressing image..."
zstd -d "$DISK_IMAGE_ZST" -o "$DISK_IMAGE"
chmod 666 "$DISK_IMAGE"

echo "[*] Locating EFI partition offset and size..."
read EFI_START SECTORS <<<$(fdisk -l "$DISK_IMAGE" | awk '$0 ~ /EFI System/ { print $2, $4 }')
if [[ -z "$EFI_START" || -z "$SECTORS" ]]; then
  echo "[!] Could not determine EFI partition info"
  exit 1
fi

EFI_OFFSET=$((EFI_START * 512))
EFI_SIZE=$((SECTORS * 512))
echo "[*] EFI offset: $EFI_OFFSET, size: $EFI_SIZE bytes"

echo "[*] Extracting EFI partition..."
dd if="$DISK_IMAGE" of="$EFI_IMAGE" bs=512 skip="$EFI_START" count="$SECTORS" status=none

echo "[*] Extracting BOOTX64.EFI..."
mcopy -i "$EFI_IMAGE" ::EFI/BOOT/BOOTX64.EFI BOOTX64.EFI

echo "[*] Signing BOOTX64.EFI..."
/bin/sbsign --engine e_akv --keyform engine --key "$KEY" --cert "$CERT" --output "$SIGNED_EFI" BOOTX64.EFI

echo "[*] Inserting signed BOOTX64.EFI into EFI image..."
mcopy -o -i "$EFI_IMAGE" "$SIGNED_EFI" ::EFI/BOOT/BOOTX64.EFI

echo "[*] Writing EFI partition back to disk image..."
dd if="$EFI_IMAGE" of="$DISK_IMAGE" bs=512 seek="$EFI_START" conv=notrunc status=none

echo "[+] Signed image is in $DISK_IMAGE"

# Define repo details

echo "[*] Recompressing image to signed_$ZSTD_IMAGE..."
zstd -f disk.raw -o "signed_$ZSTD_IMAGE"

echo "[*] Pushing image to OCI registry using oras..."
oras push "$REPO:$TAG" "$ZSTD_IMAGE:application/octet-stream"

echo "[+] Done. Image uploaded as $REPO:$TAG"
