#!/usr/bin/env bash

## SPDX-FileCopyrightText: 2022-2024 TII (SSRC) and the Ghaf contributors
## SPDX-License-Identifier: Apache-2.0

######################################################################################
# This script is expecting AZURE_CLI_ACCESS_TOKEN to be set
# Otherwise (or in case of Azure VM) it will request it based on current az login info
######################################################################################
set -eo pipefail

log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*"
}

err_report() {
    log "[!] Error on line $1"
    exit 1
}
trap 'err_report $LINENO' ERR

if ! declare -F uefisign_find_efi_partition >/dev/null; then
    SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
    # shellcheck disable=SC1091
    # shellcheck source=uefi-raw-image-lib.sh
    source "$SCRIPT_DIR/uefi-raw-image-lib.sh"
fi

# Input and constants
if [[ $# -eq 2 && -n "${UEFISIGN_AZURE_CERT:-}" ]]; then
    set -- "$UEFISIGN_AZURE_CERT" "$@"
fi

if [[ $# -ne 3 ]]; then
    log "[!] Usage: $0 <certificate> <disk-image.zst> <subdir>"
    log "[!] Please make sure AZURE_CLI_ACCESS_TOKEN variable is set before running."
    log "[!] ... or az login first."
    exit 1
fi

SUBDIR="$3"
DISK_IMAGE_ZST="$2"
CERT="$1"
KEY="vault:ghaf-secureboot-testkv:uefi-signing-key"
ZSTD_IMAGE="ghaf_0.0.1.raw.zst"

if [ -z "${AZURE_CLI_ACCESS_TOKEN:-}" ]; then
    log "[DEBUG] querying Azure metadata server for access token..."
    AZURE_CLI_ACCESS_TOKEN=$(curl -s \
        'http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https://vault.azure.net' \
        -H "Metadata: true" | jq -r .access_token)
    export AZURE_CLI_ACCESS_TOKEN
fi

log "[DEBUG] cert: $1"
log "[DEBUG] image: $2"
log "[DEBUG] $# args remaining"

case "$DISK_IMAGE_ZST" in
*.iso)
    input_type="iso"
    log "ISO Image detected"
    log "PWD: $PWD"
    exec uefisign-azure-iso "$2"
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

TMPWDIR="$(mktemp -d --suffix .uefisign-azure)"
EFI_IMAGE="$TMPWDIR/efi-partition.img"
SIGNED_EFI="$TMPWDIR/BOOTX64.EFI.signed"
BOOT_EFI="$TMPWDIR/BOOTX64.EFI"

on_exit() {
    log "[DEBUG] Cleanup (TMPWDIR:$TMPWDIR)"
    rm -fr "$TMPWDIR"
}
trap on_exit EXIT

# Ensure required tools are available
for cmd in zstd dd mcopy sbsign; do
    if ! command -v "$cmd" &>/dev/null; then
        log "[!] Required tool '$cmd' not found in PATH"
        exit 1
    fi
done

log "[*] Locating EFI partition offset and size..."
read -r EFI_START SECTORS < <(uefisign_find_efi_partition "$DISK_IMAGE_ZST" "$input_type" "$TMPWDIR/partition-prefix.img")
EFI_OFFSET=$((EFI_START * 512))
EFI_SIZE=$((SECTORS * 512))
log "[*] EFI offset: $EFI_OFFSET, size: $EFI_SIZE bytes"

log "[*] Extracting EFI partition to $EFI_IMAGE..."
uefisign_extract_raw_range_to_file "$DISK_IMAGE_ZST" "$input_type" "$EFI_OFFSET" "$EFI_SIZE" "$EFI_IMAGE"

log "[*] Extracting BOOTX64.EFI..."
if ! mcopy -i "$EFI_IMAGE" ::EFI/BOOT/BOOTX64.EFI "$BOOT_EFI"; then
    log "[!] Failed to extract BOOTX64.EFI from EFI image"
    exit 1
fi

log "[*] Signing BOOTX64.EFI..."

log "[DEBUG] Running: sbsign with params --key $KEY --cert $CERT --output $SIGNED_EFI"
sbsign --engine e_akv --keyform engine --key "$KEY" --cert "$CERT" --output "$SIGNED_EFI" "$BOOT_EFI" 2>&1 | tee /tmp/sbsign.log
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

if [[ "$input_type" == "zst" ]]; then
    SIGNED_ZST="signed_$ZSTD_IMAGE"
    log "[*] Streaming signed image to $SUBDIR/$SIGNED_ZST..."
    uefisign_write_signed_raw_image "$DISK_IMAGE_ZST" "$input_type" "$EFI_IMAGE" "$EFI_OFFSET" "$EFI_SIZE" "$SUBDIR/$SIGNED_ZST" zst
fi

log "[+] EFI Signing Success!"
