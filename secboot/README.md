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

### Manual testing on Nix (offline) - the easy way

#### Create Key Hierarchy

```
nix run github:tiiuae/ci-yubi#uefikeygen
```

This should create a subfolder 'keys' with all required keys and certificates, both in PEM and DER formats.

#### Sign the image

Assuming the db.key and db.crt are in keys subfolder and storing result in output/ subfolder is desired:

```
nix run github:tiiuae/ci-yubi#uefisign -- keys/db.crt keys/db.key disk1.raw.zst output
```

### Manual testing on Nix (offline) - the hard way

The manual testing method relies on locally created keys and doesn't require netHSM or Azure KeyVault. All of the steps can be performed offline.

#### Create Key Hierarchy

```sh
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
```

#### Convert certificates to DER format (required by UEFI)

```sh
openssl x509 -in pk.crt  -outform DER -out pk.der
openssl x509 -in kek.crt -outform DER -out kek.der
openssl x509 -in db.crt  -outform DER -out db.der
```

At this stage, you should have everything required to sign the image and enable secure boot on X1 Carbon laptop.


#### Signing the image

The raw-image signer now produces a `systemd-boot + UKI` chain.

For each loader entry it does one of two things:

- If the entry already uses `efi`, it signs the referenced UKI and keeps the entry stable.
- If the entry still uses `linux` + `initrd`, it builds a UKI, writes it to `/EFI/Linux/<entry>.efi`, and rewrites the entry to `efi /EFI/Linux/<entry>.efi`.

In both cases `EFI/BOOT/BOOTX64.EFI` remains the signed `systemd-boot` binary, not the kernel payload.

The resulting ESP layout looks like this:

```text
EFI/BOOT/BOOTX64.EFI
EFI/Linux/<entry>.efi
loader/entries/<entry>.conf
```

The entry file name stays stable so `bootctl list --json` keeps reporting the same `id`, which the updater can pass unchanged to `bootctl unlink`.

Please save your PK, KEK, and DB files in DER format on a FAT32-formatted USB drive. Then reboot your target test machine and press F1 during startup to enter the BIOS setup.

## Provisioning (Enrolling) Secure Boot Keys / Certificates

In BIOS:

Clean all the previous keys first:

Navigate to: Security -> Secure Boot
 -> Clear All Secure Boot Keys

Provision the new keys one by one:

Navigate to: Security -> Secure Boot -> Key Management
 -> Authorized Signature Database (DB) -> Enroll DB -> Choose your USB media from the list and click on db.der
 -> Key Exchange Key (KEK) -> Enroll KEK -> Choose your USB media from the list and click on kek.der
 -> Platform Key (PK) -> Enroll PK -> Choose your USB media from the list and click on pk.der

After PK is engrolled, the Secure Boot Mode should automatically set to User Mode.

Now you can enable Secure Boot:
Navigate to: Security -> Secure Boot and Enable it.

From this moment only the images signed with private key of DB keypair will boot.
Booting any other images should produce an error about signature issue.
