#!/usr/bin/env bash
# sign_ghaf_iso_all.sh
# Usage: ./sign_ghaf_iso_all.sh <db.crt> <db.key> <ghaf.iso> <out-dir>
# Requires: xorriso, mtools (mtype,mdir,mmd,mcopy,mkfs.vfat), ukify, nix,
#           squashfs-tools (unsquashfs/mksquashfs), zstd, awk, sed, strings, stat, tr

set -euo pipefail
log(){ printf "[%(%F %T)T] %s\n" -1 "$*"; }
die(){ log "[!] $*"; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1 || die "Missing tool: $1"; }

[[ $# -eq 4 ]] || die "Usage: $0 <db.crt> <db.key> <ghaf.iso> <out-dir>"
CERT="$1"; PKEY="$2"; ISO_IN="$3"; OUTDIR="$4"

for b in xorriso mtype mdir mmd mcopy mkfs.vfat awk sed tr stat ukify unsquashfs mksquashfs zstd strings; do need "$b"; done
need nix

WORK="$(mktemp -d)"
cleanup(){ chmod -R u+rwX "$WORK" >/dev/null 2>&1 || true; rm -rf "$WORK" >/dev/null 2>&1 || true; }
trap cleanup EXIT

export MTOOLSRC=/dev/null
export MTOOLS_SKIP_CHECK=1

fat_path(){ local p="${1//\\//}"; p="${p%\"}"; p="${p#\"}"; p="${p%\'}"; p="${p#\'}"; [[ "${p:0:1}" == "/" ]] || p="/$p"; p="${p//\/\//\/}"; printf '%s' "$p"; }
esp_free_bytes(){ mdir -i "$1" :: 2>/dev/null | awk '/bytes free/ {gsub(/,/, "", $1); print $1; exit}'; }
grow_esp_if_needed(){ # enlarge FAT file if not enough space
  local img="$1" need="$2" free cur new tmp newimg
  free=$(esp_free_bytes "$img"); free=${free:-0}
  (( free >= need )) && return 0
  cur=$(stat -c%s "$img")
  new=$(( cur + need + 64*1024*1024 )); (( new < cur*2 )) && new=$(( cur*2 ))
  log "[*] ESP too small (free=${free}B need~=${need}B). Rebuilding to ${new} bytes…"
  tmp="$(mktemp -d)"
  mcopy -s -n -i "$img" ::/* "$tmp"/ 2>/dev/null || true
  newimg="${img}.new"; truncate -s "$new" "$newimg"
  mkfs.vfat -F32 -n EFI "$newimg" >/dev/null
  if compgen -G "$tmp/*" >/dev/null; then mcopy -s -n -i "$newimg" "$tmp"/* :: >/dev/null; fi
  mv -f "$newimg" "$img"; rm -rf "$tmp"
}

parse_grub_menuentry(){ # prints: KERNEL \n INITRDS \n OPTS
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

find_raw_in_sqfs(){ # robust locate *.raw.zst inside squashfs
  local sqfs="$1" rel ec
  if command -v timeout >/dev/null 2>&1; then
    rel="$( set +e; timeout 60s unsquashfs -l "$sqfs" 2> "$WORK/unsq.err" | awk '$NF ~ /\.raw\.zst$/ {print $NF; exit}'; echo "EC=$?" )"
  else
    rel="$( set +e; unsquashfs -l "$sqfs" 2> "$WORK/unsq.err" | awk '$NF ~ /\.raw\.zst$/ {print $NF; exit}'; echo "EC=$?" )"
  fi
  ec="${rel##*EC=}"; rel="${rel%EC=*}"
  rel="${rel#./}"; rel="${rel#squashfs-root/}"
  printf '%s' "$rel"
}

# ---------- Extract ISO tree once ----------
log "[*] Extracting ISO: $ISO_IN"
xorriso -osirrox on -indev "$ISO_IN" -extract / "$WORK/iso_root" >/dev/null
chown -R "$(id -u)":"$(id -g)" "$WORK/iso_root" || true
chmod -R u+w "$WORK/iso_root" || true

# Preserve original label
ISO_LABEL="$(xorriso -indev "$ISO_IN" -pvd_info 2>/dev/null | sed -n 's/^Volume id[[:space:]]*:[[:space:]]*//p' | head -n1)"
[[ -z "${ISO_LABEL:-}" ]] && ISO_LABEL="ghaf"
log "[*] ISO label: $ISO_LABEL"

# ===== PHASE 1: Installer UKI =====
[[ -f "$WORK/iso_root/boot/efi.img" ]] || die "ESP not found at /boot/efi.img"
cp "$WORK/iso_root/boot/efi.img" "$WORK/esp.img"; chmod +w "$WORK/esp.img"

# Source GRUB config to discover kernel/initrd and options
SRC_CFG=""
if [[ -f "$WORK/iso_root/boot/grub/grub.cfg" ]]; then
  SRC_CFG="$WORK/iso_root/boot/grub/grub.cfg"
else
  SRC_CFG="$WORK/grub.esp.cfg"
  mtype -i "$WORK/esp.img" ::/EFI/BOOT/grub.cfg | tr -d '\r' > "$SRC_CFG" || true
fi
log "[*] Parsing GRUB config: $SRC_CFG"

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

# Build clean cmdline for UKI
OPTS="${OPTS:-}"
OPTS="$(printf '%s' "$OPTS" | sed -E 's/\$\{?isoboot\}?//g')"    # drop ${isoboot}
OPTS="$(printf '%s' "$OPTS" | sed -E 's/(^|[[:space:]])root=[^[:space:]]+//g')" # remove old root=
OPTS="$(printf '%s root=/dev/disk/by-label/%s rootfstype=iso9660' "$OPTS" "$ISO_LABEL")"
OPTS="$(printf '%s' "$OPTS" | sed -E 's/[[:space:]]+/ /g; s/^[ ]+|[ ]+$//g')"

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
    base="$(basename "$r")"; cp "$WORK/iso_root$r" "$WORK/$base"
    INITRD_ARGS+=( --initrd "$WORK/$base" )
  done
fi
printf '%s\n' "$OPTS" > "$WORK/cmdline.txt"

log "[*] Building installer UKI…"
ukify build --linux "$WORK/bzImage.efi" "${INITRD_ARGS[@]}" --cmdline @"$WORK/cmdline.txt" --output "$WORK/BOOTX64.EFI"

log "[*] Signing installer UKI…"
nix run --accept-flake-config --option builders '' --option max-jobs 1 \
  github:tiiuae/sbsigntools -- \
  --keyform PEM --key "$PKEY" --cert "$CERT" \
  --output "$WORK/BOOTX64.EFI.signed" "$WORK/BOOTX64.EFI"

NEED=$(( $(stat -c%s "$WORK/BOOTX64.EFI.signed") + 2*1024*1024 ))
grow_esp_if_needed "$WORK/esp.img" "$NEED"

log "[*] Installing UKI to \\EFI\\BOOT\\BOOTX64.EFI"
timeout 30s mcopy -o -i "$WORK/esp.img" "$WORK/BOOTX64.EFI.signed" ::/EFI/BOOT/BOOTX64.EFI

# Put ESP back into ISO tree
chmod +w "$WORK/iso_root/boot/efi.img" 2>/dev/null || true
cp "$WORK/esp.img" "$WORK/iso_root/boot/efi.img"

# ===== PHASE 2: Signed runtime RAW in nix-store.squashfs =====
[[ -f "$WORK/iso_root/nix-store.squashfs" ]] || die "nix-store.squashfs not found in ISO"
cp -f "$WORK/iso_root/nix-store.squashfs" "$WORK/store.squashfs"

log "[*] Locating *.raw.zst inside nix-store.squashfs…"
RAW_REL_PATH="$(find_raw_in_sqfs "$WORK/store.squashfs")"
[[ -n "$RAW_REL_PATH" ]] || die "No *.raw.zst found inside squashfs (see $WORK/unsq.err)"

log "[*] Extracting full store (this may take a bit)…"
unsquashfs -d "$WORK/store_root" "$WORK/store.squashfs" >/dev/null
chown -R "$(id -u)":"$(id -g)" "$WORK/store_root" || true
chmod -R u+rwX "$WORK/store_root" || true

RAW_IN="$WORK/store_root/$RAW_REL_PATH"
[[ -f "$RAW_IN" ]] || die "Expected path not found after extract: $RAW_IN"

EXPOSED_IN="$WORK/$(basename "$RAW_IN")"
cp -f "$RAW_IN" "$EXPOSED_IN"
log "[*] Exposed unsigned runtime image: $EXPOSED_IN"

# Call your existing raw signer (flake) to inject signed UKI into the runtime image
OUTDIR_RAW="$WORK/raw_out"; mkdir -p "$OUTDIR_RAW"
log "[*] Signing runtime raw.zst via ci-yubi#uefisign…"
nix run github:tiiuae/ci-yubi#uefisign "$CERT" "$PKEY" "$EXPOSED_IN" "$OUTDIR_RAW"

SIGNED_OUT="$(ls -1 "$OUTDIR_RAW"/*.raw.zst 2>/dev/null | head -n1 || true)"
[[ -n "$SIGNED_OUT" && -f "$SIGNED_OUT" ]] || die "uefisign did not produce a *.raw.zst in $OUTDIR_RAW"

log "[*] Replacing raw.zst inside store tree"
TARGET="$WORK/store_root/$RAW_REL_PATH"
chmod u+w "$(dirname "$TARGET")" || true
chmod u+w "$TARGET" 2>/dev/null || true
rm -f "$TARGET" || true
install -m 0644 -D "$SIGNED_OUT" "$TARGET"

# Mirror original squashfs compression
COMP="xz"; BLK=""
if unsquashfs -s "$WORK/store.squashfs" >/tmp/sqfs-info.$$ 2>/dev/null; then
  CLINE="$(sed -n 's/^Compression[[:space:]]\+//p' /tmp/sqfs-info.$$ | head -n1 || true)"
  BLINE="$(sed -n 's/^Block size[[:space:]]\+//p'     /tmp/sqfs-info.$$ | head -n1 || true)"
  [[ -n "$CLINE" ]] && COMP="$(echo "$CLINE" | awk '{print tolower($1)}')"
  [[ -n "$BLINE" ]] && BLK="$BLINE"
  rm -f /tmp/sqfs-info.$$
fi
log "[*] Rebuilding nix-store.squashfs (comp=$COMP ${BLK:+block=$BLK})"
SQFS_NEW="$WORK/nix-store.squashfs"
if [[ -n "$BLK" ]]; then
  mksquashfs "$WORK/store_root" "$SQFS_NEW" -noappend -comp "$COMP" -b "$BLK" >/dev/null
else
  mksquashfs "$WORK/store_root" "$SQFS_NEW" -noappend -comp "$COMP" >/dev/null
fi

cp -f "$SQFS_NEW" "$WORK/iso_root/nix-store.squashfs"

# ---------- Rebuild final ISO once ----------
FINAL_ISO="signed-$(basename "${ISO_IN%.iso}").iso"
log "[*] Rebuilding ISO (label: $ISO_LABEL)…"
xorriso -as mkisofs \
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
