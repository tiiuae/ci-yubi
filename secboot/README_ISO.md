# Ghaf ISO Image Signer

## The process

The script (ghaf_iso_sign.sh) takes an unsiged Ghaf Installer ISO image and Secure Boot Keypair and produces a new ISO that boots in Secure Boot mode and installs a disk image that also boots in Secure Boot mode using the same keys.

The script works in two phases in one run:

1. Installer phase (ISO ESP)
 - Builds an UKI (Unified Kernel Image) from the EFI partition in the ISO and embeds a safe kernel cmdline (root by ISO label, rootfstype=iso9660).
 - Signs the UKI with provided DB key.
 - Replaces \EFI\BOOT\BOOTX64.EFI in the ISO's EFI System Partition (ESP) with the signed UKI (no shim, no Microsoft keys).

2. Installed system phase (runtime RAW inside ISO)
 - Finds the compressed runtime disk image (*.raw.zst) embedded in the ISO (inside nix-store.squashfs).
 - Builds an UKI from the EFI partition in the RAW image inside ISO
 - Signs the runtime UKI with the same DB key, so the installed OS also boots in Secure Boot mode with the same keys.
 - Rebuilds the squashfs and the final ISO.

The above will result in one signed ISO that boots the installer securely and installs a securely bootable Ghaf OS. Both with the same Secure Boot keys.

## Inputs

 - DB certificate (PEM)
 - DB private key (PEM)
 - Unsigned Ghaf ISO

If needed, DB, KEK and PK keys/certificates can be generated with keygen.sh script

## Usage on Ubuntu

### Install Dependencies

`
sudo apt update
sudo apt install -y xorriso mtools squashfs-tools zstd binutils findutils systemd-ukify
sudo apt install systemd-boot-efi
`

Install sbsign, for example https://github.com/tiiuae/sbsigntools or the one provided by systemd.

## Clone the repo and run the script

`
git clone git@github.com:tiiuae/ci-yubi.git

cd ci-yubi/secboot

alias uefisign="$PWD/signme_offline.sh"
`

If the keys are in ./keys/ folder, then run:

`
./ghaf_sign_iso.sh ./keys/db.crt ./keys/db.key ghaf.iso out/
`

The above command line will store the image in out/ subfolder.

## Using the script with HSM (YubiHSM, NetHSM, etc)

It is possible to keep Secure Boot keys inside any PKCS11 enabled HSM and let the signing happen without the private key ever leaving the device.

### Requirements

 - HSM initialized and reachable (USB or network)
 - HSM pkcs11 library installed on the build host
 - A DB keypair created and stored on HSM
 - x509 certificate corresponding to DB keypair. Can be stored locally.
 - PKCS#11 URI (or token label/object ID) for the private key

### Usage

`
uefisigniso ./keys/db.crt 'pkcs11:token=GhafHSM;object=DB;type=private' ghaf.iso out/
`

This should produce the signed ISO using the key referenced by PKCS11 URI on the HSM.