#!/usr/bin/env bash
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
if [[ $# -ne 3 ]]; then
    log "[!] Usage: $0 <certificate> <disk-image.zst> <subdir>"
    exit 1
fi

SUBDIR="$3"
DISK_IMAGE_ZST="$2"
DISK_IMAGE="disk.raw"
DISK_IMAGE_ISO="disk.iso"
EFI_IMAGE="efi-partition.img"
SIGNED_EFI="BOOTX64.EFI.signed"
CERT="$1"
KEY="vault:ghaf-secureboot-testkv:uefi-signing-key"
REPO="harbor.ppclabz.net/ghaf-secboot/ghaf-uefi"
TAG="signed"
ZSTD_IMAGE="ghaf_0.0.1.raw.zst"

export AZURE_CLI_ACCESS_TOKEN=$(curl -s \
  'http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https://vault.azure.net' \
  -H "Metadata: true" | jq -r .access_token)


log "[DEBUG] cert: $1"
log "[DEBUG] image: $2"
log "[DEBUG] $# args remaining"

case "$DISK_IMAGE_ZST" in
    *.iso)
	input_type="iso"
	log "ISO Image detected"
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

# Ensure required tools are available
for cmd in zstd fdisk dd mcopy sbsign; do
    if ! command -v "$cmd" &>/dev/null; then
        log "[!] Required tool '$cmd' not found in PATH"
        exit 1
    fi
done

# Jenkins global credentials / Jenkins secrets are used for now
# TODO: Consider more secure approach
#if [[ -z "${ORAS_USERNAME:-}" || -z "${ORAS_PASSWORD:-}" ]]; then
#    log "[!] ORAS_USERNAME and ORAS_PASSWORD must be set"
#    exit 1
#fi

log "[*] Cleaning up any previous artifacts..."
rm -f "$DISK_IMAGE" "$EFI_IMAGE" "$SIGNED_EFI" BOOTX64.EFI

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

log "[*] Extracting BOOTX64.EFI..."
if ! mcopy -i "$EFI_IMAGE" ::EFI/BOOT/BOOTX64.EFI BOOTX64.EFI; then
    log "[!] Failed to extract BOOTX64.EFI from EFI image"
    exit 1
fi

log "[*] Signing BOOTX64.EFI..."

log "[DEBUG] Running: sbsign --engine e_akv --keyform engine --key \"$KEY\" --cert \"$CERT\" --output \"$SIGNED_EFI\" BOOTX64.EFI"
sbsign --engine e_akv --keyform engine --key "$KEY" --cert "$CERT" --output "$SIGNED_EFI" BOOTX64.EFI 2>&1 | tee /tmp/sbsign.log
ret=$?
if [[ $ret -ne 0 ]]; then
    log "[!] sbsign failed (exit code $ret)"
    cat /tmp/sbsign.log
    exit $ret
fi

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


#log "[*] Logging into OCI registry..."
#oras login harbor.ppclabz.net -u "$ORAS_USERNAME" -p "$ORAS_PASSWORD"

#log "[*] Pushing $SIGNED_ZST to OCI registry as $REPO:$TAG..."
#oras push "$REPO:$TAG" "$SIGNED_ZST:application/octet-stream"

#log "[+] Success! Image uploaded as $REPO:$TAG"
log "[+] EFI Signing Success!"
