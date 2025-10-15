#!/usr/bin/env bash
# sign_iso_installer_only.sh
#
# Purpose: Replace the ISO’s ESP fallback loader with a signed UKI so the
#          installer boots under Secure Boot. Does NOT touch the RAW image.
#
# Usage:   ./sign_iso_installer_only.sh <db.crt> <db.key> <ghaf.iso> <out-dir>
#
# Requires: xorriso, mtools (mtype mdir mmd mcopy mkfs.vfat), ukify, sbsign,
#           awk, sed, tr, stat

set -euo pipefail
log(){ printf "[%(%F %T)T] %s\n" -1 "$*"; }
die(){ log "[!] $*"; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1 || die "Missing tool: $1"; }

[[ $# -eq 4 ]] || die "Usage: $0 <db.crt> <db.key> <ghaf.iso> <out-dir>"
CERT="$1"; PKEY="$2"; ISO="$3"; OUTDIR="$4"

for b in xorriso mtype mdir mmd mcopy mkfs.vfat awk sed tr stat ukify sbsign; do need "$b"; done

WORKDIR="$(mktemp -d)"
cleanup(){ chmod -R u+rwX "$WORKDIR" 2>/dev/null || true; rm -rf "$WORKDIR" 2>/dev/null || true; }
trap cleanup EXIT

export MTOOLSRC=/dev/null
export MTOOLS_SKIP_CHECK=1

fat_path(){  # normalize GRUB-ish/ESP path → /abs/path
  local p="${1//\\//}"
  p="${p%\"}"; p="${p#\"}"; p="${p%\'}"; p="${p#\'}"
  [[ -n "$p" && "${p:0:1}" == "/" ]] || p="/$p"
  p="${p//\/\//\/}"
  printf '%s' "$p"
}

esp_free_bytes(){ mdir -i "$1" :: 2>/dev/null | awk '/bytes free/ {gsub(/,/, "", $1); print $1; exit}'; }

grow_esp_if_needed(){ # enlarge FAT image if too small to fit $need bytes more
  local img="$1" need="$2"
  local free cur new tmp newimg
  free=$(esp_free_bytes "$img"); free=${free:-0}
  (( free >= need )) && return 0

  cur=$(stat -c%s "$img")
  # Add headroom: exactly the delta + 64MiB, but at least double current size
  local add=$(( need > free ? need - free : 0 ))
  new=$(( cur + add + 64*1024*1024 ))
  (( new < cur*2 )) && new=$(( cur*2 ))

  log "[*] ESP too small (free=${free}B need~=${need}B). Rebuilding to ${new} bytes…"
  tmp="$(mktemp -d)"
  # Dump current ESP contents to a temp dir (best-effort)
  mcopy -s -n -i "$img" ::/* "$tmp"/ 2>/dev/null || true

  newimg="${img}.new"
  truncate -s "$new" "$newimg"
  mkfs.vfat -F32 -n EFI "$newimg" >/dev/null

  # Copy files back if any
  if find "$tmp" -mindepth 1 -print -quit >/dev/null 2>&1; then
    mcopy -s -n -i "$newimg" "$tmp"/* :: >/dev/null
  fi

  mv -f "$newimg" "$img"
  rm -rf "$tmp"
}

parse_grub_menuentry(){     # prints: KERNEL \n INITRDS \n OPTS from the first menuentry
  awk '
    BEGIN{inblk=0; got=0}
    /^[[:space:]]*menuentry[ \t]/{ if (!got){ inblk=1; kp=""; opts=""; init=""; next } }
    inblk && /(linuxefi|linux)[ \t]/{
      line=$0; sub(/^[^ \t]+[ \t]+/,"",line);
      n=split(line,f,/[ \t]+/); kp=f[1];
      opts=""; for(i=2;i<=n;i++){ if(f[i]!="") opts=opts (opts?" ":"") f[i] }
      next
    }
    inblk && /(initrdefi|initrd)[ \t]/{ line=$0; sub(/^[^ \t]+[ \t]+/,"",line);
      init = init ? init" "line : line; next }
    inblk && /^[[:space:]]*}/{ print kp; print init; print opts; got=1; exit }
    END{ exit got?0:1 }
  ' "$1"
}

# -------------------- Extract ISO --------------------
log "[*] Workdir: $WORKDIR"
log "[*] Extracting ISO filesystem from: $ISO"
xorriso -osirrox on -indev "$ISO" -extract / "$WORKDIR/iso_root" >/dev/null
chown -R "$(id -u)":"$(id -g)" "$WORKDIR/iso_root" || true

# ISO label (we’ll force root=LABEL=<this>)
ISO_LABEL="$(xorriso -indev "$ISO" -pvd_info 2>/dev/null | sed -n 's/^Volume id[[:space:]]*:[[:space:]]*//p' | head -n1)"
[[ -z "${ISO_LABEL:-}" ]] && ISO_LABEL="ghaf"

# Grab ESP image
[[ -f "$WORKDIR/iso_root/boot/efi.img" ]] || die "ESP not found at /boot/efi.img in ISO"
cp "$WORKDIR/iso_root/boot/efi.img" "$WORKDIR/esp.img"; chmod +w "$WORKDIR/esp.img"

# Find a GRUB config to parse
SRC_CFG=""
if [[ -f "$WORKDIR/iso_root/boot/grub/grub.cfg" ]]; then
  SRC_CFG="$WORKDIR/iso_root/boot/grub/grub.cfg"
else
  SRC_CFG="$WORKDIR/grub.esp.cfg"
  mtype -i "$WORKDIR/esp.img" ::/EFI/BOOT/grub.cfg | tr -d '\r' > "$SRC_CFG" || true
fi
[[ -s "$SRC_CFG" ]] || die "No GRUB config found (neither /boot/grub/grub.cfg nor ESP one)"

log "[*] Parsing: $SRC_CFG"
set +e
IFS=$'\n' read -r KPATH INITRDS OPTS < <(parse_grub_menuentry "$SRC_CFG")
rc=$?
set -e
if [[ $rc -ne 0 || -z "${KPATH:-}" || "$KPATH" = "/" ]]; then
  # Fallback: first linux/initrd lines
  KPATH="$(sed -n 's/^[[:space:]]*linux\(efi\)\{0,1\}[[:space:]]\+//p' "$SRC_CFG" | head -n1 | awk '{print $1}')"
  OPTS="$(sed -n 's/^[[:space:]]*linux\(efi\)\{0,1\}[[:space:]]\+//p' "$SRC_CFG" | head -n1 | cut -d" " -f2-)"
  INITRDS="$(sed -n 's/^[[:space:]]*initrd\(efi\)\{0,1\}[[:space:]]\+//p' "$SRC_CFG" | head -n1)"
fi
[[ -n "${KPATH:-}" ]] || die "Could not find linux line in GRUB config"

KPATH="$(fat_path "$KPATH")"

# ---- Build a self-sufficient cmdline for UKI
# drop ${isoboot}, strip any prior root=, add label root + fstype, normalize spaces
OPTS="${OPTS:-}"
OPTS="$(printf '%s' "$OPTS" | sed -E 's/\$\{?isoboot\}?//g')"
OPTS="$(printf '%s' "$OPTS" | sed -E 's/(^|[[:space:]])root=[^[:space:]]+//g')"
OPTS="$(printf '%s root=/dev/disk/by-label/%s rootfstype=iso9660' "$OPTS" "$ISO_LABEL")"
OPTS="$(printf '%s' "$OPTS" | sed -E 's/[[:space:]]+/ /g; s/^[ ]+|[ ]+$//g')"

log "[*] Kernel: $KPATH"
log "[*] Initrd(s): ${INITRDS:-<none>}"
log "[*] UKI cmdline (final): $OPTS"

[[ -f "$WORKDIR/iso_root$KPATH" ]] || die "Kernel not found in ISO at $KPATH"
cp "$WORKDIR/iso_root$KPATH" "$WORKDIR/bzImage.efi"

INITRD_ARGS=()
if [[ -n "${INITRDS:-}" ]]; then
  read -r -a arr <<<"$INITRDS"
  for r in "${arr[@]}"; do
    r="$(fat_path "$r")"
    [[ -f "$WORKDIR/iso_root$r" ]] || die "initrd not found: $r"
    base="$(basename "$r")"
    cp "$WORKDIR/iso_root$r" "$WORKDIR/$base"
    INITRD_ARGS+=( --initrd "$WORKDIR/$base" )
  done
fi
printf '%s\n' "$OPTS" > "$WORKDIR/cmdline.txt"

# -------------------- Build & sign UKI --------------------
log "[*] Building UKI…"
ukify build \
  --linux "$WORKDIR/bzImage.efi" \
  "${INITRD_ARGS[@]}" \
  --cmdline @"$WORKDIR/cmdline.txt" \
  --output "$WORKDIR/BOOTX64.EFI"

log "[*] Signing UKI…"
sbsign --key "$PKEY" --cert "$CERT" \
  --output "$WORKDIR/BOOTX64.EFI.signed" "$WORKDIR/BOOTX64.EFI"

# -------------------- Replace fallback loader on ESP --------------------
NEED=$(( $(stat -c%s "$WORKDIR/BOOTX64.EFI.signed") + 2*1024*1024 ))
grow_esp_if_needed "$WORKDIR/esp.img" "$NEED"

log "[*] Installing signed UKI as \\EFI\\BOOT\\BOOTX64.EFI (no GRUB)…"
# mcopy will create directories if they are missing when used with proper target
# but ensure path exists:
mmd -i "$WORKDIR/esp.img" ::/EFI || true
mmd -i "$WORKDIR/esp.img" ::/EFI/BOOT || true
timeout 30s mcopy -o -i "$WORKDIR/esp.img" "$WORKDIR/BOOTX64.EFI.signed" ::/EFI/BOOT/BOOTX64.EFI

# -------------------- Put ESP back & rebuild ISO --------------------
chmod +w "$WORKDIR/iso_root/boot/efi.img" 2>/dev/null || true
cp "$WORKDIR/esp.img" "$WORKDIR/iso_root/boot/efi.img"

FINAL_ISO="signed-$(basename "${ISO%.iso}").iso"
log "[*] Rebuilding ISO (label: $ISO_LABEL)…"
xorriso -as mkisofs \
  -iso-level 3 \
  -V "$ISO_LABEL" \
  -c isolinux/boot.cat \
  -b isolinux/isolinux.bin -no-emul-boot -boot-load-size 4 -boot-info-table \
  -eltorito-alt-boot \
  -e boot/efi.img -no-emul-boot -isohybrid-gpt-basdat \
  -o "$FINAL_ISO" "$WORKDIR/iso_root" >/dev/null

mkdir -p "$OUTDIR"
mv -f "$FINAL_ISO" "$OUTDIR/"
log "[+] Done: $OUTDIR/$FINAL_ISO"
