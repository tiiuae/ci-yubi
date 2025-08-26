#!/usr/bin/env bash

## SPDX-FileCopyrightText: 2022-2024 TII (SSRC) and the Ghaf contributors
## SPDX-License-Identifier: Apache-2.0

set -euo pipefail


log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*"
}

err_report() {
    log "[!] Error on line $1"
    exit 1
}
trap 'err_report $LINENO' ERR

# Input and constants
if [[ $# -ne 4 ]]; then
    log "[!] Usage: $0 <certificate> <private-key> <disk-image.zst> <subdir>"
    exit 1
fi

SUBDIR="$4"
DISK_IMAGE_ZST="$3"
DISK_IMAGE="disk.raw"
DISK_IMAGE_ISO="disk.iso"
EFI_IMAGE="efi-partition.img"
SIGNED_EFI="BOOTX64.EFI.signed"
CERT="$1"
PKEY="$2"
ZSTD_IMAGE="ghaf_0.0.1.raw.zst"

log "[DEBUG] cert: $1"
log "[DEBUG] image: $2"
log "[DEBUG] $# args remaining"

case "$DISK_IMAGE_ZST" in
    *.iso)
	input_type="iso"
	log "ISO Image detected"
	log "PWD: $PWD"
	./signiso.sh $2
	exit 0
	;;
    *.zst)
	input_type="zst"
	log "ZST'ed Image detected"
	;;
    *)
	log "Unsupported input file: $1" >&2
	exit 1
	;;
esac

log "[*] Cleaning up any previous artifacts..."
rm -f "$DISK_IMAGE" "$EFI_IMAGE" "$SIGNED_EFI" BOOTX64.EFI
rm -rf "$SIGNED_EFI"
rm -rf "initrd.efi"
rm -rf "bzImage.efi"
rm -rf "BOOTX64.EFI.uki"

if [[ "$input_type" == "zst" ]]; then
    log "[*] Decompressing image: $DISK_IMAGE_ZST -> $DISK_IMAGE"
    zstd -d "$DISK_IMAGE_ZST" -o "$DISK_IMAGE"
else
    cp $DISK_IMAGE_ZST $DISK_IMAGE_ISO
    DISK_IMAGE=$DISK_IMAGE_ISO
fi
log "[*] Disk image: $DISK_IMAGE"
chmod 666 "$DISK_IMAGE"

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

log "[*] Extracting EFIs..."
if ! mcopy -i "$EFI_IMAGE" ::EFI/nixos/*initrd.efi initrd.efi; then
    log "[!] Failed to extract initrd.efi from EFI image"
    exit 1
fi
if ! mcopy -i "$EFI_IMAGE" ::EFI/nixos/*bzImage.efi bzImage.efi; then
    log "[!] Failed to extract bzImage.efi from EFI image"
    exit 1
fi

log "[*] Creating BOOTX64.EFI..."

#log "[DEBUG] Running: sbsign with params --key $KEY --cert $CERT --output $SIGNED_EFI"
#sbsign --engine e_akv --keyform engine --key "$KEY" --cert "$CERT" --output "$SIGNED_EFI" BOOTX64.EFI 2>&1 | tee /tmp/sbsign.log


# Build and sign the image (offline keypair/x509):
ukify build   \
--linux bzImage.efi   \
--initrd initrd.efi   \
--cmdline "intel_iommu=on,sm_on iommu=pt module_blacklist=i915,xe,snd_pcm acpi_backlight=vendor acpi_osi=linux vfio-pci.ids=8086:51f1,8086:a7a1,8086:519d,8086:51ca,8086:51a3,8086:51a4 console=tty0 root=fstab resume=/dev/disk/by-partlabel/disk-disk1-swap loglevel=4 audit=1"   \
--os-release /etc/os-release   \
--uname 6.13.3   \
--output BOOTX64.EFI.uki


ret=$?
if [[ $ret -ne 0 ]]; then
    log "[!] ukify failed (exit code $ret)"
    cat /tmp/sbsign.log
    exit $ret
fi

log "[*] Signing the UKI image ..."
nix run github:tiiuae/sbsigntools -- --keyform PEM --key keys/db.key --cert keys/db.crt --output "$SIGNED_EFI" BOOTX64.EFI.uki

log "[*] Inserting signed BOOTX64.EFI back into EFI image..."
if ! mcopy -o -i "$EFI_IMAGE" "$SIGNED_EFI" ::EFI/BOOT/BOOTX64.EFI; then
    log "[!] Failed to insert signed BOOTX64.EFI"
    exit 1
fi

log "[*] Writing updated EFI partition back to disk image..."
dd if="$EFI_IMAGE" of="$DISK_IMAGE" bs=512 seek="$EFI_START" conv=notrunc status=none

log "[+] Signed image is ready in $DISK_IMAGE"

if [[ "$input_type" == "zst" ]]; then
    SIGNED_ZST="signed_$ZSTD_IMAGE"
    log "[*] Recompressing signed image to $SIGNED_ZST..."
    zstd -f "$DISK_IMAGE" -o "$SIGNED_ZST"
    log "[*] Move signed image to $SUBDIR"
    mkdir -p $SUBDIR
    mv $SIGNED_ZST $SUBDIR
else
    log "[*] Move signed image to $SUBDIR"
    mkdir -p $SUBDIR
    mv $DISK_IMAGE_ISO $SUBDIR
fi


log "[+] EFI Signing Success!"
