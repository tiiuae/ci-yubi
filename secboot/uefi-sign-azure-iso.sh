#!/usr/bin/env bash
set -euo pipefail

# === CONFIG ===
ISO="$1"
SIGNED_UKI=BOOTX64.EFI.signed
FINAL_ISO=signed-ghaf.iso
CERT="uefi-signing-cert.pem"
KEY="vault:ghaf-secureboot-testkv:uefi-signing-key"
CMDLINE="root=LABEL=nixos-minimal-25.11-x86_64 boot.shell_on_fail nohibernate loglevel=4 lsm=landlock,yama,bpf"

# === TEMP DIR ===
WORKDIR=$(mktemp -d)
echo "[*] Workdir: $WORKDIR"

# === EXTRACT ISO ===
echo "[*] Extracting ISO filesystem... from $ISO"
xorriso -osirrox on -indev "$ISO" -extract / "$WORKDIR/iso_root"

echo "[*] Fixing ownership of ISO tree..."
chown -R "$(id -u):$(id -g)" "$WORKDIR/iso_root"

# === COLLECT FILES ===
echo "[*] Copy kernel, initrd, EFI image..."
cp "$WORKDIR/iso_root/boot/nix/store/"*/bzImage "$WORKDIR/kernel"
cp "$WORKDIR/iso_root/boot/nix/store/"*/initrd "$WORKDIR/initrd"
cp "$WORKDIR/iso_root/boot/efi.img" "$WORKDIR/efi.img"
chmod +w "$WORKDIR/efi.img"

# === BUILD UKI ===
echo "[*] Building UKI..."
ukify build \
    --linux "$WORKDIR/kernel" \
    --initrd "$WORKDIR/initrd" \
    --cmdline "$CMDLINE" \
    --os-release /etc/os-release \
    --output "$WORKDIR/BOOTX64.EFI"
echo "[*] UKI built."

# === SIGN UKI ===
echo "[*] Signing UKI..."
sbsign --engine e_akv --keyform engine --key "$KEY" --cert "$CERT" --output "$WORKDIR/$SIGNED_UKI" "$WORKDIR/BOOTX64.EFI" 2>&1 | tee /tmp/sbsign.log
ret=$?
if [[ $ret -ne 0 ]]; then
    log "[!] sbsign failed (exit code $ret)"
    cat /tmp/sbsign.log
    exit $ret
fi

echo "[*] UKI signed."

# === UPDATE EFI IMG ===
echo "[*] Updating EFI image..."
mcopy -o -i "$WORKDIR/efi.img" "$WORKDIR/$SIGNED_UKI" ::/EFI/BOOT/BOOTX64.EFI
echo "[*] EFI image updated."

# === UPDATE ISO TREE ===
echo "[*] Preparing final ISO tree..."
chmod +w "$WORKDIR/iso_root/boot/efi.img"
cp "$WORKDIR/efi.img" "$WORKDIR/iso_root/boot/efi.img"

# === REBUILD ISO ===
echo "[*] Rebuilding ISO..."
xorriso -as mkisofs \
    -iso-level 3 \
    -V 'nixos-minimal-25.11-x86_64' \
    -c isolinux/boot.cat \
    -b isolinux/isolinux.bin \
    -no-emul-boot -boot-load-size 4 -boot-info-table \
    -eltorito-alt-boot \
    -e boot/efi.img \
    -no-emul-boot -isohybrid-gpt-basdat \
    -o "$FINAL_ISO" "$WORKDIR/iso_root"

echo "[*] New signed ISO created: $FINAL_ISO"
echo "[*] All done."
