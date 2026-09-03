#!/usr/bin/env bash
# sign_ghaf_iso_all.sh
# Usage: ./sign_ghaf_iso_all.sh <db.crt> <db.key> <ghaf.iso> <out-dir>
# Requires: xorriso, mtools (mtype,mdir,mmd,mcopy,mkfs.vfat), ukify,
#           awk, sed, stat, tr, systemd-sbsign, uefisignraw

set -euo pipefail

log() { printf "[%(%F %T)T] %s\n" -1 "$*"; }
die() {
  log "[!] $*"
  exit 1
}
is_needed() { command -v "$1" >/dev/null 2>&1 || die "Missing tool: $1"; }

[[ $# -eq 4 ]] || die "Usage: $0 <db.crt> <db.key> <ghaf.iso> <out-dir>"
CERT="$1"
PKEY="$2"
ISO_IN="$3"
OUTDIR="$4"

for b in xorriso mtype mdir mmd mcopy mkfs.vfat awk sed tr stat ukify systemd-sbsign uefisignraw bmaptool zstd dd; do
  is_needed "$b"
done

WORK="$(mktemp -d)"
cleanup() {
  chmod -R u+rwX "$WORK" >/dev/null 2>&1 || true
  rm -rf "$WORK" >/dev/null 2>&1 || true
}
trap cleanup EXIT

export MTOOLSRC=/dev/null
export MTOOLS_SKIP_CHECK=1

fat_path() {
  local p="${1//\\//}"
  p="${p%\"}"
  p="${p#\"}"
  p="${p%\'}"
  p="${p#\'}"
  [[ "${p:0:1}" == "/" ]] || p="/$p"
  p="${p//\/\//\/}"
  printf '%s' "$p"
}

regenerate_bmap() {
  local image_zst="$1"
  local bmap_out="$2"
  local raw_tmp="$WORK/bmap-source.raw"

  rm -f -- "$raw_tmp" "$bmap_out"

  log "[*] Decompressing signed RAW for bmap generation..."

  zstd \
    --decompress \
    --force \
    --sparse \
    -o "$raw_tmp" \
    -- "$image_zst"

  [[ -s "$raw_tmp" ]] ||
    die "Failed to materialize signed RAW for bmap generation"

  log "[*] Generating updated bmap..."

  bmaptool create \
    -o "$bmap_out" \
    "$raw_tmp"

  [[ -s "$bmap_out" ]] ||
    die "bmaptool did not produce a bmap"

  log "[*] Generated bmap:"
  log "[*]   $bmap_out"

  rm -f -- "$raw_tmp"
}

detect_boot_efi_name() {
  local img="$1" boot

  boot="$(
    mdir -i "$img" ::/EFI/BOOT/ 2>/dev/null |
      awk '
        tolower($1) ~ /^boot[a-z0-9]+$/ &&
        tolower($2) == "efi" {
          print $1
          found=1
        }
        END {
          exit !found
        }
      '
  )" || die "Could not determine EFI/BOOT fallback filename"

  printf '%s.EFI' "$boot"
}

esp_free_bytes() {
  mdir -i "$1" :: 2>/dev/null | awk '/bytes free/ {gsub(/,/, "", $1); print $1; exit}'
}

grow_esp_if_needed() { # enlarge FAT file if not enough space
  local img="$1" need_bytes="$2" free cur new tmp newimg
  free=$(esp_free_bytes "$img")
  free=${free:-0}
  ((free >= need_bytes)) && return 0
  cur=$(stat -c%s "$img")
  local add=$((need_bytes > free ? need_bytes - free : 0))
  new=$((cur + add + 64 * 1024 * 1024))
  ((new < cur * 2)) && new=$((cur * 2))
  log "[*] ESP too small (free=${free}B need=${need_bytes}B). Rebuilding to ${new} bytes…"
  tmp="$(mktemp -d)"
  mcopy -s -n -i "$img" ::/* "$tmp"/ 2>/dev/null || true
  newimg="${img}.new"
  truncate -s "$new" "$newimg"
  mkfs.vfat -F32 -n EFI "$newimg" >/dev/null
  # restore files only if anything was copied out (portable: no compgen)
  if [ -n "$(find "$tmp" -mindepth 1 -print -quit 2>/dev/null)" ]; then
    mcopy -s -n -i "$newimg" "$tmp"/* :: >/dev/null
  fi
  mv -f "$newimg" "$img"
  rm -rf "$tmp"
}

parse_grub_menuentry() { # prints: KERNEL \n INITRDS \n OPTS
  awk '
    BEGIN{inblk=0; got=0}
    /^[[:space:]]*menuentry[ \t]/{ if (!got){ inblk=1; kp=""; opts=""; init=""; next } }
    inblk && /(linuxefi|linux)[ \t]/{
      line=$0; sub(/^[^ \t]+[ \t]+/,"",line);
      n=split(line,f,/[ \t]+/); kp=f[1];
      opts=""; for(i=2;i<=n;i++){ if(f[i]!="") opts=opts (opts?" ":"") f[i] }
      next
    }
    inblk && /(initrdefi|initrd)[ \t]/{ line=$0; sub(/^[^ \t]+[ \t]+/,"",line); init = init ? init" "line : line; next }
    inblk && /^[[:space:]]*}/{ print kp; print init; print opts; got=1; exit }
    END{ exit got?0:1 }
  ' "$1"
}

# ---------- Extract ISO tree once ----------
log "[*] Extracting ISO: $ISO_IN"
xorriso -osirrox on -indev "$ISO_IN" -extract / "$WORK/iso_root" >/dev/null
chown -R "$(id -u)":"$(id -g)" "$WORK/iso_root" || true
chmod -R u+w "$WORK/iso_root" || true

# Preserve original label
ISO_LABEL="$(xorriso -indev "$ISO_IN" -pvd_info 2>&1 | awk -F"'" '/Volume id/ { print $2; exit }')"

[[ -n "$ISO_LABEL" ]] || {
  log "[!] Could not read ISO label from $ISO_IN"
  exit 1
}

log "[*] ISO label: $ISO_LABEL"

# ===== PHASE 1: Installer UKI =====
[[ -f "$WORK/iso_root/boot/efi.img" ]] || die "ESP not found at /boot/efi.img"
cp "$WORK/iso_root/boot/efi.img" "$WORK/esp.img"
chmod +w "$WORK/esp.img"
BOOT_EFI_NAME="$(detect_boot_efi_name "$WORK/esp.img")"

log "[*] BOOT_EFI_NAME: $BOOT_EFI_NAME"

# Source GRUB config to discover kernel/initrd and options
SRC_CFG=""
if [[ -f "$WORK/iso_root/boot/grub/grub.cfg" ]]; then
  SRC_CFG="$WORK/iso_root/boot/grub/grub.cfg"
else
  SRC_CFG="$WORK/grub.esp.cfg"
  mtype -i "$WORK/esp.img" ::/EFI/BOOT/grub.cfg | tr -d '\r' >"$SRC_CFG" || true
fi
log "[*] Parsing GRUB config: $SRC_CFG"

set +e
IFS=$'\n' read -r KPATH INITRDS OPTS < <(parse_grub_menuentry "$SRC_CFG")
rc=$?
set -e

if [[ $rc -ne 0 || -z "${KPATH:-}" || "$KPATH" = "/" ]]; then

KPATH="$(
  sed -n '
    s/^[[:space:]]*linux\(efi\)\{0,1\}[[:space:]]\+//
    t found
    b
    :found
    p
    q
  ' "$SRC_CFG" | awk '{print $1}'
)"

OPTS="$(
  sed -n '
    s/^[[:space:]]*linux\(efi\)\{0,1\}[[:space:]]\+//
    t found
    b
    :found
    p
    q
  ' "$SRC_CFG" | cut -d" " -f2-
)"

INITRDS="$(
  sed -n '
    s/^[[:space:]]*initrd\(efi\)\{0,1\}[[:space:]]\+//
    t found
    b
    :found
    p
    q
  ' "$SRC_CFG"
)"
fi

[[ -n "${KPATH:-}" ]] || die "Could not find linux line in GRUB config"
KPATH="$(fat_path "$KPATH")"

# Build clean cmdline for UKI
OPTS="${OPTS:-}"

log "[*] Installer kernel: $KPATH"
log "[*] Installer initrd(s): ${INITRDS:-<none>}"
log "[*] Installer UKI cmdline: $OPTS"

[[ -f "$WORK/iso_root$KPATH" ]] || die "Kernel not found in ISO at $KPATH"
cp "$WORK/iso_root$KPATH" "$WORK/bzImage.efi"

INITRD_ARGS=()
if [[ -n "${INITRDS:-}" ]]; then
  read -r -a arr <<<"$INITRDS"
  for r in "${arr[@]}"; do
    r="$(fat_path "$r")"
    [[ -f "$WORK/iso_root$r" ]] || die "initrd not found: $r"
    base="$(basename "$r")"
    cp "$WORK/iso_root$r" "$WORK/$base"
    INITRD_ARGS+=(--initrd "$WORK/$base")
  done
fi
printf '%s\n' "$OPTS" >"$WORK/cmdline.txt"

log "[*] Building installer UKI…"
ukify build --linux "$WORK/bzImage.efi" "${INITRD_ARGS[@]}" --cmdline @"$WORK/cmdline.txt" --output "$WORK/$BOOT_EFI_NAME"

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

log "[*] Signing installer UKI…"

systemd-sbsign sign \
  --private-key-source "$PKEY_PROV" \
  --private-key "$PKEY" \
  --certificate-source "$CERT_PROV" \
  --certificate "$CERT" \
  --output "$WORK/${BOOT_EFI_NAME}.signed" "$WORK/$BOOT_EFI_NAME"

NEED=$(($(stat -c%s "$WORK/${BOOT_EFI_NAME}.signed") + 2 * 1024 * 1024))
grow_esp_if_needed "$WORK/esp.img" "$NEED"

log "[*] Installing UKI to \\EFI\\BOOT\\${BOOT_EFI_NAME}"
timeout 30s mcopy -o -i "$WORK/esp.img" "$WORK/${BOOT_EFI_NAME}.signed" "::/EFI/BOOT/${BOOT_EFI_NAME}"

# Put ESP back into ISO tree
chmod +w "$WORK/iso_root/boot/efi.img" 2>/dev/null || true
cp "$WORK/esp.img" "$WORK/iso_root/boot/efi.img"

# ===== PHASE 2: Signed runtime RAW in ISO filesystem =====
# New layout: raw runtime image is on the ISO FS, not in nix-store.squashfs

# ===== PHASE 2: Signed runtime RAW in ISO filesystem =====

RAW_ISO_REL="/ghaf-image/ghaf-image.raw.zst"
BMAP_ISO_REL="/ghaf-image/ghaf-image.bmap"

RAW_ISO_PATH="$WORK/iso_root$RAW_ISO_REL"
BMAP_ISO_PATH="$WORK/iso_root$BMAP_ISO_REL"

[[ -f "$RAW_ISO_PATH" ]] ||
  die "Runtime raw image not found at $RAW_ISO_REL in ISO"

log "[*] Runtime raw image:"
log "[*]   $RAW_ISO_PATH"

if [[ -f "$BMAP_ISO_PATH" ]]; then
  log "[*] Runtime bmap detected:"
  log "[*]   $BMAP_ISO_PATH"
  HAVE_BMAP=true
else
  #
  # Keep compatibility with older Ghaf installers which did not include
  # a pre-generated bmap.
  #
  log "[*] No runtime bmap present; assuming older installer layout"
  HAVE_BMAP=false
fi

OUTDIR_RAW="$WORK/raw_out"
mkdir -p "$OUTDIR_RAW"

log "[*] Signing runtime raw.zst via ci-yubi#uefisignraw..."

#
# There is no need to make another copy of ghaf-image.raw.zst first.
# uefisignraw does not modify its input.
#
uefisignraw \
  "$CERT" \
  "$PKEY" \
  "$RAW_ISO_PATH" \
  "$OUTDIR_RAW"

# shellcheck disable=SC2012
SIGNED_OUT="$(
  ls -1 "$OUTDIR_RAW"/*.raw.zst 2>/dev/null |
    head -n1 ||
    true
)"

[[ -n "$SIGNED_OUT" && -f "$SIGNED_OUT" ]] ||
  die "uefisignraw did not produce a *.raw.zst in $OUTDIR_RAW"

#
# If the installer contains a bmap, regenerate it against the SIGNED image
# before rebuilding the ISO. Signing modifies the ESP, so the original bmap
# is no longer valid.
#
if $HAVE_BMAP; then
  SIGNED_BMAP="$WORK/ghaf-image.bmap"

  regenerate_bmap \
    "$SIGNED_OUT" \
    "$SIGNED_BMAP"
fi

#
# Replace runtime image.
#
log "[*] Replacing runtime raw image at $RAW_ISO_REL"

chmod u+w "$(dirname "$RAW_ISO_PATH")" || true
chmod u+w "$RAW_ISO_PATH" 2>/dev/null || true

rm -f -- "$RAW_ISO_PATH"

#
# raw_out and iso_root are underneath the same $WORK directory, so mv avoids
# keeping another multi-GB copy of the signed compressed image.
#
mv -f -- "$SIGNED_OUT" "$RAW_ISO_PATH"
chmod 0644 "$RAW_ISO_PATH"

#
# Replace its bmap as part of the same artifact pair.
#
if $HAVE_BMAP; then
  log "[*] Replacing runtime bmap at $BMAP_ISO_REL"

  chmod u+w "$BMAP_ISO_PATH" 2>/dev/null || true
  rm -f -- "$BMAP_ISO_PATH"

  install \
    -m 0644 \
    "$SIGNED_BMAP" \
    "$BMAP_ISO_PATH"
fi

# ---------- Rebuild final ISO once ----------
FINAL_ISO="signed_$(basename "${ISO_IN%.iso}").iso"
log "[*] Rebuilding ISO (label: $ISO_LABEL)…"
xorriso -as mkisofs \
  -R \
  -J -joliet-long \
  -iso-level 3 \
  -V "$ISO_LABEL" \
  -c isolinux/boot.cat \
  -b isolinux/isolinux.bin -no-emul-boot -boot-load-size 4 -boot-info-table \
  -eltorito-alt-boot \
  -e boot/efi.img -no-emul-boot -isohybrid-gpt-basdat \
  -o "$FINAL_ISO" "$WORK/iso_root" >/dev/null

mkdir -p "$OUTDIR"
mv -f "$FINAL_ISO" "$OUTDIR/"
log "[+] All done: $OUTDIR/$FINAL_ISO"
