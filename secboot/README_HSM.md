# UEFI Secure Boot Key Generation using SoftHSM2 and OpenSSL 3.x (PKCS#11 Provider)

This guide describes how to:

- Set up SoftHSM2 as a local HSM.
- Create Platform Key (PK), Key Exchange Key (KEK), and Database Key (db) inside the HSM.
- Configure OpenSSL 3 to use the PKCS#11 provider.
- Generate and sign X.509 certificates with the correct trust hierarchy (PK  →  KEK  →  db)


Export certificates for UEFI (ESL/AUTH).

## 1. Install Required Packages
sudo apt update
sudo apt install softhsm2 opensc p11-kit gnutls-bin openssl efitools uuid-runtime

## 2. Initialize SoftHSM Token
softhsm2-util --init-token --slot 0 --label "UEFIKeys" --so-pin 1234 --pin 7654321


Verify:

softhsm2-util --show-slots


You should see a slot with the label UEFIKeys.

## 3. Generate Keys Inside HSM

Each key pair is generated inside SoftHSM and never leaves it.

pkcs11-tool --module /usr/lib/softhsm/libsofthsm2.so -p 7654321 --slot 0 --keypairgen --key-type rsa:4096 --label "PK-key"  --id 01
pkcs11-tool --module /usr/lib/softhsm/libsofthsm2.so -p 7654321 --slot 0 --keypairgen --key-type rsa:4096 --label "KEK-key" --id 02
pkcs11-tool --module /usr/lib/softhsm/libsofthsm2.so -p 7654321 --slot 0 --keypairgen --key-type rsa:4096 --label "DB-key"  --id 03


List keys:

p11tool --provider=/usr/lib/softhsm/libsofthsm2.so --list-all


You should see objects PK-key, KEK-key, and DB-key.

## 4. Export Public Keys

p11tool --provider=/usr/lib/softhsm/libsofthsm2.so \
  --export "pkcs11:token=UEFIKeys;object=PK-key;type=public"  --outfile=pk-pub.pem
p11tool --provider=/usr/lib/softhsm/libsofthsm2.so \
  --export "pkcs11:token=UEFIKeys;object=KEK-key;type=public" --outfile=kek-pub.pem
p11tool --provider=/usr/lib/softhsm/libsofthsm2.so \
  --export "pkcs11:token=UEFIKeys;object=DB-key;type=public"  --outfile=db-pub.pem

## 5. Configure OpenSSL PKCS#11 Provider

Create a minimal working provider config:

cat > openssl-pkcs11.cnf <<'EOF'
openssl_conf = openssl_init

[openssl_init]
providers = provider_sect

[provider_sect]
default = default_sect
pkcs11  = pkcs11_sect

[default_sect]
activate = 1

[pkcs11_sect]
activate = 1
# Correct key is module_path (not "module")
module_path = /usr/lib/softhsm/libsofthsm2.so
# Optional niceties:
# login_type = user
# pin = 7654321
# init_args = verbose=1
EOF

export OPENSSL_CONF="$PWD/openssl-pkcs11.cnf"
export OPENSSL_MODULES="/usr/lib/x86_64-linux-gnu/ossl-modules"

openssl list -providers


Expected output:

Providers:
  default
    name: OpenSSL Default Provider
    status: active
  pkcs11
    name: PKCS#11 Provider
    status: active

## 6. Generate and Sign Certificates in Proper Hierarchy

### 6.1 Platform Key (PK) — self-signed

openssl req -new -provider pkcs11 -provider default \
  -key "pkcs11:token=UEFIKeys;id=%01;type=private;login-type=user;pin-value=7654321" \
  -subj "/CN=Platform Key/" -out pk.csr

openssl x509 -req -days 3650 -in pk.csr \
  -signkey "pkcs11:token=UEFIKeys;id=%01;type=private;login-type=user;pin-value=7654321" \
  -provider pkcs11 -provider default -out pk.crt

6.2 Key Exchange Key (KEK) — signed by PK
openssl req -new -provider pkcs11 -provider default \
  -key "pkcs11:token=UEFIKeys;id=%02;type=private;login-type=user;pin-value=7654321" \
  -subj "/CN=Key Exchange Key/" -out kek.csr

openssl x509 -req -days 3650 -in kek.csr -CA pk.crt -CAkeyform engine \
  -CAkey "pkcs11:token=UEFIKeys;id=%01;type=private;login-type=user;pin-value=7654321" \
  -provider pkcs11 -provider default -out kek.crt -CAcreateserial

6.3 Database Key (db) — signed by KEK
openssl req -new -provider pkcs11 -provider default \
  -key "pkcs11:token=UEFIKeys;id=%03;type=private;login-type=user;pin-value=7654321" \
  -subj "/CN=Database Key/" -out db.csr

openssl x509 -req -days 3650 -in db.csr -CA kek.crt -CAkeyform engine \
  -CAkey "pkcs11:token=UEFIKeys;id=%02;type=private;login-type=user;pin-value=7654321" \
  -provider pkcs11 -provider default -out db.crt -CAcreateserial


Resulting trust chain:

PK.crt  →  KEK.crt  →  DB.crt

## 7. Convert Certificates for UEFI (ESL & AUTH)

### 7.1 Convert X.509 → ESL
cert-to-efi-sig-list pk.crt pk.esl
cert-to-efi-sig-list kek.crt kek.esl
cert-to-efi-sig-list db.crt db.esl

### 7.2 Create Signed AUTH files (using PKCS#11 URIs)
# PK.auth — PK signs PK.esl (self-signed AUTH)
sign-efi-sig-list \
  -c pk.crt \
  -k "pkcs11:token=UEFIKeys;id=%01;type=private;login-type=user;pin-value=7654321" \
  PK pk.esl pk.auth

# KEK.auth — PK signs KEK.esl
sign-efi-sig-list \
  -c pk.crt \
  -k "pkcs11:token=UEFIKeys;id=%01;type=private;login-type=user;pin-value=7654321" \
  KEK kek.esl kek.auth

# db.auth — KEK signs db.esl
sign-efi-sig-list \
  -c kek.crt \
  -k "pkcs11:token=UEFIKeys;id=%02;type=private;login-type=user;pin-value=7654321" \
  db db.esl db.auth
