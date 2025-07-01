# UEFI SecureBoot for Lenovo X1 Carbon

## Objective
Enable a reproducible and secure boot process for Ghaf on a Lenovo X1 Carbon Gen11 using UEFI Secure Boot and a Unified Kernel Image (UKI).

## UEFI Secure Boot Overview
UEFI Secure Boot ensures that only digitally signed EFI binaries are allowed to execute during boot. This is enforced by the UEFI firmware using a set of keys stored in secure variables.

### Key Hierarchy in UEFI Secure Boot

| Key                    | Description        | Role                                           |
| ---------------------- | ------------------ | ---------------------------------------------- |
| PK (Platform Key)      | Root of Trust      | Authorizes updates to KEK                      |
| KEK (Key Exchange Key  | Intermediate Trust | Authorizes updates to db/dbx                   |
| DB (Allowed Signatures | Allowed binaries   | Contains certs/hashes of bootable EFI binaries |
| DBX (Revocation List)  | Deny list          | Revoked certs/hashes (blacklist)               |


### Secure Boot Modes

UEFI firmware can operate in two key modes:

#### Setup Mode

 - No PK is enrolled
 - All keys (PK, KEK, db, dbx) can be added or removed freely
 - Signature verification is not enforced
 - Used during initial provisioning or key enrollment.

#### User Mode

 - Entered automatically when PK is enrolled
 - Signature verification is strictly enforced
 - Only binaries signed by keys in db will run
 - Updates to KEK require signature by PK
 - Updates to db/dbx require signature by KEK

## Testing proposals

### Manual testing on Nix (offline)

The manual testing method relies on locally created keys and doesn't require netHSM or Azure KeyVault. All of the steps can be performed offline.

#### Create Key Hierarchy

`
#!/bin/bash
set -e

# Create Keypair for PK (the root or top CA key)
openssl genrsa -out pk.key 2048

# Create self-signed certificate for PK
openssl req -new -x509 -days 3650 -key pk.key -out pk.crt -config create_PK_cert.ini

# Create keypair for KEK (intermediate)
openssl genrsa -out kek.key 2048

# Create CSR for KEK
openssl req -new -key kek.key -out kek.csr -config create_KEK_cert.ini

# Sign KEK CSR with PK (acts as CA)
openssl x509 -req -in kek.csr -CA pk.crt -CAkey pk.key -CAcreateserial -out kek.crt -days 3650 -extfile sign_KEK_csr.ini -extensions v3_req

# Create keypair for DB (leaf)
openssl genrsa -out db.key 2048

# Create CSR for DB
openssl req -new -key db.key -out db.csr -config create_DB_cert.ini

# Sign DB CSR with KEK
openssl x509 -req -in db.csr -CA kek.crt -CAkey kek.key -CAcreateserial -out db.crt -days 3650 -extfile sign_DB_csr.ini -extensions v3_req
`

#### Convert certificates to DER format (required by UEFI)

`
openssl x509 -in pk.crt  -outform DER -out pk.der
openssl x509 -in kek.crt -outform DER -out kek.der
openssl x509 -in db.crt  -outform DER -out db.der
`

At this stage, you should have everything required to sign the image and enable secure boot on X1 Carbon laptop.


#### Signing the image

Signing the image involves several steps which differ slightly depending on the image type. Ghaf is offering both installer image (ISO) and RAW disk image as ZSTD archive (RAW.ZST).

##### Raw image signing

Assuming your image is named disk.raw.zst

Extract the raw image from zstd archive:

` zst -d disk.raw.zst -o disk.raw `

Find EFI partition offset, size and extract EFI partition

`
read -r EFI_START SECTORS < <(fdisk -l disk.raw | awk '$0 ~ /EFI / { print $2, $4 }')
EFI_OFFSET=$((EFI_START * 512))
EFI_SIZE=$((SECTORS * 512))
dd if=disk.raw of=efi-partition.img bs=512 skip="$EFI_START" count="$SECTORS" status=none
`

Extract BOOTX64.EFI

`
mcopy -i efi-partition.img ::EFI/BOOT/BOOTX64.EFI BOOTX64.EFI
`

Please note, that hardened images include UKI (Unified Kernel Image) by default. If you are willing to sign unhardened image, you would need to create UKI and replace BOOTX64.EFI on EFI partition with it. In case you are working with hardened image, please skip the following step:

TODO: Add a paragraph on bzImage and initrd extraction from the raw image!!!

`
ukify build   \
--linux ../gficvxrnx7h89ydhih3cry080174dw2q-linux-6.13.3-bzImage.efi   \
--initrd ../hr7djwyl44qm53hbrd91xa9s77hjbhxc-initrd-linux-6.13.3-initrd.efi   \
--cmdline "intel_iommu=on,sm_on iommu=pt module_blacklist=i915,xe,snd_pcm acpi_backlight=vendor acpi_osi=linux vfio-pci.ids=8086:51f1,8086:a7a1,8086:519d,8086:51ca,8086:51a3,8086:51a4 console=tty0 root=fstab resume=/dev/disk/by-partlabel/disk-disk1-swap loglevel=4 audit=1"   \
--os-release /etc/os-release   \
--uname 6.13.3 \
--signing-engine pkcs11 \
--secureboot-private-key "pkcs11:model=NetHSM;manufacturer=Nitrokey%20GmbH;serial=unknown;token=LocalHSM;id=%64%62;object=db;type=private"   \
--secureboot-certificate /mnt/test/ghaf-secboot/ca/config/db.crt   \
--output BOOTX64.EFI
`


Sign it with DB private key

`
nix run github:tiiuae/sbsigntools -- --keyform PEM --key db.key --cert db.crt --output signed.efi BOOTX64.EFI
`

Insert signed BOOTX64.EFI back into EFI image and update EFI partition on the disk image.

`
mcopy -o -i "$EFI_IMAGE" "$SIGNED_EFI" ::EFI/BOOT/BOOTX64.EFI
dd if=efi-partition.img of=disk.raw bs=512 seek="$EFI_START" conv=notrunc status=none
`

After this you should have an image with signed UKI in disk.raw.