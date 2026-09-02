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
SIGNED_BOOTLOADER="$TMPWDIR/BOOT.EFI.signed"
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

efi_arch_from_systemd_boot() {
  case "${1,,}" in
    systemd-bootaa64.efi)
      printf '%s\n' "aa64"
      ;;
    systemd-bootx64.efi)
      printf '%s\n' "x64"
      ;;
    systemd-bootia32.efi)
      printf '%s\n' "ia32"
      ;;
    systemd-bootarm.efi)
      printf '%s\n' "arm"
      ;;
    *)
      log "[!] Cannot determine EFI architecture from: $1"
      return 1
      ;;
  esac
}

check_stub_arch() {
  local stub="$1"
  local arch="$2"
  local desc

  desc="$(file -b "$stub")"

  log "[DEBUG] EFI stub: $stub"
  log "[DEBUG] EFI stub type: $desc"

  case "$arch" in
    aa64)
      [[ "$desc" == *ARM64* || "$desc" == *Aarch64* ]]
      ;;
    x64)
      [[ "$desc" == *x86-64* ]]
      ;;
    *)
      return 0
      ;;
  esac
}

extract_sparse_raw_range() {
  local input="$1"
  local input_type="$2"
  local skip_bytes="$3"
  local count_bytes="$4"
  local output="$5"

  local statuses input_rc dd_rc

  rm -f -- "$output"

  set +e
  set +o pipefail

  uefisign_raw_input "$input" "$input_type" |
    dd \
      of="$output" \
      bs="$UEFISIGN_STREAM_BS" \
      iflag=fullblock,skip_bytes,count_bytes \
      skip="$skip_bytes" \
      count="$count_bytes" \
      conv=sparse \
      status=none

  statuses=("${PIPESTATUS[@]}")

  set -o pipefail
  set -e

  input_rc="${statuses[0]}"
  dd_rc="${statuses[1]}"

  if (( dd_rc != 0 )); then
    log "[!] Failed to extract root filesystem"
    return 1
  fi

  # dd stops after count_bytes, therefore zstd commonly gets SIGPIPE.
  if (( input_rc != 0 && input_rc != 141 )); then
    log "[!] Failed while reading compressed RAW image"
    return 1
  fi

  local actual_size
  actual_size="$(stat -c%s "$output")"

  if (( actual_size != count_bytes )); then
    log "[!] Root partition extraction size mismatch:"
    log "[!] expected $count_bytes, got $actual_size"
    return 1
  fi
}

find_linux_root_partition() {
  local prefix="$1"

  #
  # fdisk can read the partition table from the prefix that
  # uefisign_find_efi_partition() already extracted.
  #
  # Prefer a normal Linux filesystem partition. On the Orin SD image this is
  # MBR type 83, partition 2.
  #
  fdisk -l \
    -o Start,Sectors,Id,Type \
    "$prefix" 2>/dev/null |
    awk '
      NR == 1 { next }

      $3 == "83" {
        print $1, $2
        exit
      }

      /Linux filesystem/ {
        print $1, $2
        exit
      }
    '
}

extract_target_stub_from_image() {
  local arch="$1"
  local output="$2"

  local root_start
  local root_sectors
  local root_offset
  local root_size
  local root_image
  local stub_name
  local candidate
  local source_path
  local debugfs_err

  stub_name="linux${arch}.efi.stub"
  root_image="$TMPWDIR/root-partition.img"
  debugfs_err="$TMPWDIR/debugfs-stub.err"

  log "[*] Target EFI stub is not available on signing host."
  log "[*] Looking for $stub_name inside target image..."

  read -r root_start root_sectors < <(
    find_linux_root_partition "$TMPWDIR/partition-prefix.img"
  )

  if [[ -z "${root_start:-}" || -z "${root_sectors:-}" ]]; then
    log "[!] Could not locate Linux root partition"
    return 1
  fi

  root_offset=$((root_start * 512))
  root_size=$((root_sectors * 512))

  log "[*] Root partition:"
  log "[*]   start:   $root_start"
  log "[*]   sectors: $root_sectors"
  log "[*]   offset:  $root_offset"
  log "[*]   size:    $root_size"
  log "[*] Temporarily extracting root partition (sparse)..."

  extract_sparse_raw_range \
    "$DISK_IMAGE_ZST" \
    "$input_type" \
    "$root_offset" \
    "$root_size" \
    "$root_image"

  #
  # Find systemd outputs in /nix/store.
  #
  mapfile -t SYSTEMD_CANDIDATES < <(
    debugfs -R 'ls -l /nix/store' "$root_image" 2>/dev/null |
      awk '{print $NF}' |
      grep -E '^[a-z0-9]{32}-systemd-[0-9]' ||
      true
  )

  if [[ "${#SYSTEMD_CANDIDATES[@]}" -eq 0 ]]; then
    log "[!] No systemd package found in target /nix/store"
    return 1
  fi

  for candidate in "${SYSTEMD_CANDIDATES[@]}"; do
    source_path="/nix/store/${candidate}/lib/systemd/boot/efi/${stub_name}"

    rm -f -- "$output" "$debugfs_err"

    log "[DEBUG] Trying EFI stub:"
    log "[DEBUG]   $source_path"

    #
    # Do not trust debugfs's exit status alone. It may return success even when
    # the requested path does not exist. Try the dump directly, then verify that
    # a non-empty output file was actually created.
    #
    debugfs \
      -R "dump $source_path $output" \
      "$root_image" \
      >/dev/null 2>"$debugfs_err" || true

    if [[ ! -s "$output" ]]; then
      log "[DEBUG] Stub not present in this systemd output"

      if [[ -s "$debugfs_err" ]]; then
        while IFS= read -r line; do
          log "[DEBUG] debugfs: $line"
        done <"$debugfs_err"
      fi

      continue
    fi

    log "[*] Extracted target EFI stub:"
    log "[*]   $source_path"

    if ! check_stub_arch "$output" "$arch"; then
      log "[!] Extracted stub has wrong architecture"
      rm -f -- "$output"
      continue
    fi

    #
    # We no longer need the large temporary root filesystem image.
    #
    rm -f -- "$root_image" "$debugfs_err"

    return 0
  done

  rm -f -- "$debugfs_err"

  log "[!] Could not find $stub_name in target image"
  return 1
}

find_efi_stub() {
  local arch="$1"
  local output="$2"

  local ukify
  local ukify_real
  local ukify_root
  local host_stub

  ukify="$(command -v ukify)"
  ukify_real="$(readlink -f "$ukify")"
  ukify_root="${ukify_real%%/bin/*}"

  host_stub="$ukify_root/lib/systemd/boot/efi/linux${arch}.efi.stub"

  if [[ -f "$host_stub" ]]; then
    if check_stub_arch "$host_stub" "$arch"; then
      log "[*] Using EFI stub from signing environment:"
      log "[*]   $host_stub"

      EFI_STUB="$host_stub"
      return 0
    fi
  fi

  extract_target_stub_from_image "$arch" "$output"

  EFI_STUB="$output"
}

log "[*] Locating EFI partition offset and size..."
read -r EFI_START SECTORS < <(uefisign_find_efi_partition "$DISK_IMAGE_ZST" "$input_type" "$TMPWDIR/partition-prefix.img")
EFI_OFFSET=$((EFI_START * 512))
EFI_SIZE=$((SECTORS * 512))
log "[*] EFI offset: $EFI_OFFSET, size: $EFI_SIZE bytes"

log "[*] Extracting EFI partition to $EFI_IMAGE..."
uefisign_extract_raw_range_to_file "$DISK_IMAGE_ZST" "$input_type" "$EFI_OFFSET" "$EFI_SIZE" "$EFI_IMAGE"

SYSTEMD_BOOT_NAME="$(
  mdir -i "$EFI_IMAGE" ::/EFI/systemd/ |
    awk '
      {
        for (i = 1; i <= NF; i++) {
          if (tolower($i) ~ /^systemd-boot[a-z0-9.-]*\.efi$/) {
            name = $i
          }
        }
      }
      END {
        if (name != "") {
          print name
          exit 0
        }
        exit 1
      }
    '
)" || die "Could not find systemd-boot in EFI/systemd/"

SYSTEMD_BOOT_PATH="/EFI/systemd/${SYSTEMD_BOOT_NAME}"
BOOTLOADER_BASENAME="BOOT${SYSTEMD_BOOT_NAME#systemd-boot}"
BOOTLOADER_BASENAME="${BOOTLOADER_BASENAME^^}"
log "[*] Using systemd bootloader: $SYSTEMD_BOOT_PATH"
mcopy -i "$EFI_IMAGE" "::$SYSTEMD_BOOT_PATH" "$TMPWDIR/systemd-boot.efi"

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
UKI_DST_REL="/EFI/nixos/${entry_base}.efi"
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
case "${SYSTEMD_BOOT_NAME,,}" in
  systemd-bootaa64.efi)
    EFI_ARCH=aa64
    ;;
  systemd-bootx64.efi)
    EFI_ARCH=x64
    ;;
  systemd-bootia32.efi)
    EFI_ARCH=ia32
    ;;
  systemd-bootarm.efi)
    EFI_ARCH=arm
    ;;
  *)
    log "[!] Unsupported EFI architecture: $SYSTEMD_BOOT_NAME"
    exit 1
    ;;
esac

log "[*] Target EFI architecture: $EFI_ARCH"

EFI_STUB=""

find_efi_stub \
  "$EFI_ARCH" \
  "$TMPWDIR/linux${EFI_ARCH}.efi.stub"

log "[*] Using EFI stub: $EFI_STUB"

ukify build \
  --efi-arch "$EFI_ARCH" \
  --stub "$EFI_STUB" \
  --linux "$TMPWDIR/bzImage.efi" \
  "${INITRD_ARGS[@]}" \
  --cmdline "@$TMPWDIR/cmdline" \
  --output "$TMPWDIR/$UKI_BASENAME"

log "[*] Checking generated UKI..."
file "$TMPWDIR/$UKI_BASENAME"

case "$EFI_ARCH" in
  aa64)
    file "$TMPWDIR/$UKI_BASENAME" | grep -Eq 'ARM64|Aarch64' || {
      log "[!] Generated UKI is not ARM64!"
      exit 1
    }
    ;;
  x64)
    file "$TMPWDIR/$UKI_BASENAME" | grep -q 'x86-64' || {
      log "[!] Generated UKI is not x86-64!"
      exit 1
    }
    ;;
esac

  awk -v new="${UKI_DST_REL}" '
    BEGIN{done=0}
    /^linux[[:space:]]/ && !done { print "efi " new; done=1; next }
    /^initrd[[:space:]]/ { next }
    { print }
  ' "$entry_file" >"$TMPWDIR/tmp_entry"

  log "[*] Updating loader entry to boot the UKI..."
  mcopy -o -i "$EFI_IMAGE" "$TMPWDIR/tmp_entry" "::/loader/entries/$(basename "$entry_file")"

  log "[*] Removing old kernel and initrd files..."
  mrm -i "$EFI_IMAGE" "::${LINUX_REL}" 2>/dev/null || true
  if [[ "${#INITRD_REL[@]}" -gt 0 ]]; then
    for r in "${INITRD_REL[@]}"; do
      mrm -i "$EFI_IMAGE" "::${r}" 2>/dev/null || true
    done
  fi
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
  --output "$SIGNED_BOOTLOADER" "$TMPWDIR/systemd-boot.efi"

log "[*] Updating EFI/systemd/${SYSTEMD_BOOT_NAME} ..."
mcopy -o -i "$EFI_IMAGE" "$SIGNED_BOOTLOADER" "::$SYSTEMD_BOOT_PATH"

log "[*] Updating fallback EFI/BOOT/${BOOTLOADER_BASENAME} ..."
mcopy -o -i "$EFI_IMAGE" "$SIGNED_BOOTLOADER" "::/EFI/BOOT/${BOOTLOADER_BASENAME}"

mkdir -p "$OUTDIR"
log "[*] Streaming signed image to $SIGNED_ZST..."
uefisign_write_signed_raw_image "$DISK_IMAGE_ZST" "$input_type" "$EFI_IMAGE" "$EFI_OFFSET" "$EFI_SIZE" "$SIGNED_ZST" zst

log "[+] EFI Signing Success!"
