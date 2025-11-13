# Manual key creation

## Build SoftHSM Docker image

```
docker build --network=host --build-arg TOKEN_LABEL=UEFI-Token --build-arg SO_PIN=3537363231383830 --build-arg USER_PIN=123456 -t softhsm-secboot:latest .
[+] Building 19.4s (12/12) FINISHED                                                       docker:default
 => [internal] load build definition from Dockerfile                                                0.0s
 => => transferring dockerfile: 5.24kB                                                              0.0s
 => [internal] load metadata for docker.io/library/ubuntu:24.04                                     0.7s
 => [internal] load .dockerignore                                                                   0.0s
 => => transferring context: 2B                                                                     0.0s
 => CACHED [1/6] FROM docker.io/library/ubuntu:24.04@sha256:66460d557b25769b102175144d538d88219c07  0.0s
 => CACHED [internal] preparing inline document                                                     0.0s
 => CACHED [internal] preparing inline document                                                     0.0s
 => [2/6] RUN echo 'Acquire::ForceIPv4 "true";' > /etc/apt/apt.conf.d/99force-ipv4  && apt-get up  17.7s
 => [3/6] RUN mkdir -p /var/lib/softhsm/tokens && chown -R root:root /var/lib/softhsm               0.2s 
 => [4/6] ADD --chown=root:root <<EOF /etc/ssl/openssl-pkcs11.cnf                                   0.1s 
 => [5/6] ADD --chown=root:root <<EOF /usr/local/bin/init-softhsm.sh                                0.1s 
 => [6/6] RUN chmod +x /usr/local/bin/init-softhsm.sh                                               0.2s 
 => exporting to image                                                                              0.4s 
 => => exporting layers                                                                             0.3s 
 => => writing image sha256:6597afdcb1a63999fe6a2ce46ce3994fee933de507599a53c896c8362a841271        0.0s
 => => naming to docker.io/library/softhsm-secboot:latest                                           0.0s
```

## Start Docker container

```
docker run --network=host --rm -it softhsm-secboot:^Ctest /bin/bash
```

## Extra packages

pkcs11-provider
gnutls-bin

## Extra config

```
export OPENSSL_CONF="/root/test/openssl-pkcs11.cnf"

cat openssl-pkcs11.cnf

openssl_conf = openssl_init

[openssl_init]
providers = provider_sect

[provider_sect]
pkcs11 = pkcs11_sect

[pkcs11_sect]
module = /usr/lib/x86_64-linux-gnu/ossl-modules/pkcs11.so
pkcs11-module-path = /usr/lib/softhsm/libsofthsm2.so
activate = 1
```

## Verify openssl provider works

```
root@nixos:~/test# openssl list --providers
Providers:
  pkcs11
    name: PKCS#11 Provider
    version: 3.0.13
    status: active
```

## Init token

```
softhsm2-util --init-token --slot 0 --label "UEFIKeys" --so-pin 1234 --pin 7654321
The token has been initialized and is reassigned to slot 2002816003
root@48368ba71415:/# softhsm2-util --show-slots
Available slots:
Slot 1538261010
    Slot info:
        Description:      SoftHSM slot ID 0x77608c03                                      
        Manufacturer ID:  SoftHSM project                 
        Hardware version: 2.6
        Firmware version: 2.6
        Token present:    yes
    Token info:
        Manufacturer ID:  SoftHSM project                 
        Model:            SoftHSM v2      
        Hardware version: 2.6
        Firmware version: 2.6
        Serial number:    4918308f77608c03
        Initialized:      yes
        User PIN init.:   yes
        Label:            UEFIKeys                        
Slot 1
    Slot info:
        Description:      SoftHSM slot ID 0x1                                             
        Manufacturer ID:  SoftHSM project                 
        Hardware version: 2.6
        Firmware version: 2.6
        Token present:    yes
    Token info:
        Manufacturer ID:  SoftHSM project                 
        Model:            SoftHSM v2      
        Hardware version: 2.6
        Firmware version: 2.6
        Serial number:                    
        Initialized:      no
        User PIN init.:   no
        Label:                                            
```

## Create PK Key

```
pkcs11-tool --module /usr/lib/softhsm/libsofthsm2.so -p 7654321 --slot 1538261010 --keypairgen --key-type rsa:4096 --label "PKKey" --id 01
Key pair generated:
Private Key Object; RSA 
  label:      PKKey
  ID:         01
  Usage:      decrypt, sign, signRecover, unwrap
  Access:     sensitive, always sensitive, never extractable, local
Public Key Object; RSA 4096 bits
  label:      PKKey
  ID:         01
  Usage:      encrypt, verify, verifyRecover, wrap
  Access:     local
```

## Create KEK Key

```
pkcs11-tool --module /usr/lib/softhsm/libsofthsm2.so -p 7654321 --slot 1538261010 --keypairgen --key-type rsa:4096 --label "KEKKey" --id 02
Key pair generated:
Private Key Object; RSA 
  label:      KEKKey
  ID:         02
  Usage:      decrypt, sign, signRecover, unwrap
  Access:     sensitive, always sensitive, never extractable, local
Public Key Object; RSA 4096 bits
  label:      KEKKey
  ID:         02
  Usage:      encrypt, verify, verifyRecover, wrap
  Access:     local
```

## Create DB Key

```
pkcs11-tool --module /usr/lib/softhsm/libsofthsm2.so -p 7654321 --slot 1538261010 --keypairgen --key-type rsa:4096 --label "DBKey" --id 03
Key pair generated:
Private Key Object; RSA 
  label:      DBKey
  ID:         03
  Usage:      decrypt, sign, signRecover, unwrap
  Access:     sensitive, always sensitive, never extractable, local
Public Key Object; RSA 4096 bits
  label:      DBKey
  ID:         03
  Usage:      encrypt, verify, verifyRecover, wrap
  Access:     local
```

## Export public keys

```
p11tool --provider=/usr/lib/softhsm/libsofthsm2.so --export "pkcs11:token=UEFIKeys;object=PKKey;type=public" --outfile pk-pub.pem
p11tool --provider=/usr/lib/softhsm/libsofthsm2.so --export "pkcs11:token=UEFIKeys;object=KEKKey;type=public" --outfile kek-pub.pem
p11tool --provider=/usr/lib/softhsm/libsofthsm2.so --export "pkcs11:token=UEFIKeys;object=DBKey;type=public" --outfile db-pub.pem
```

---> This should produce the following files:

db-pub.pem  kek-pub.pem  pk-pub.pem


## Generate and sign certificates

### PK

```
openssl req -new -provider default -provider pkcs11 -key "pkcs11:token=UEFIKeys;object=PKKey;type=private;login-type=user;pin-value=7654321" -subj "/CN=Platform Key/" -out pk.csr

openssl-pkcs11.cnf  pk-pub.pem  pk.csr
root@nixos:~/test# openssl x509 -req -days 3650 -in pk.csr --signkey "pkcs11:token=UEFIKeys;object=PKKey;type=private;login-type=user;pin-value=7654321" -provider pkcs11 -provider default -out pk.crt
Certificate request self-signature ok
subject=CN = Platform Key
```

### KEK

```
openssl req -new -sha256 \
  -engine pkcs11 -keyform engine \
  -key "pkcs11:token=UEFIKeys;object=KEKKey;type=private;pin-value=7654321" \
  -subj "/CN=Key Exchange Key/" \
  -out kek.csr
Engine "pkcs11" set.

openssl x509 -req -days 3650 -sha256   -in kek.csr   -CA pk.crt   -CAkeyform engine -engine pkcs11   -CAkey "pkcs11:token=UEFIKeys;object=PKKey;type=private;pin-value=7654321" -out kek.crt   -CAcreateserial
Engine "pkcs11" set.
Certificate request self-signature ok
subject=CN = Key Exchange Key
```

### DB

```
openssl req -new -sha256 -engine pkcs11 -keyform engine -key "pkcs11:token=UEFIKeys;object=DBKey;type=private;pin-value=7654321" -subj "/CN=Database Key/" -out db.csr

openssl x509 -req -days 3650 -sha256 -in db.csr -CA kek.crt -CAkeyform engine -engine pkcs11 -CAkey "pkcs11:token=UEFIKeys;object=KEKKey;type=private;pin-value=7654321" -out db.crt -CAcreateserial

ls *.crt
db.crt  kek.crt  pk.crt
```

## Convert X509 to ESL

```
OWNER_GUID=$(uuidgen)
echo $OWNER_GUID
cert-to-efi-sig-list -g "$OWNER_GUID" pk.crt pk.esl
cert-to-efi-sig-list -g "$OWNER_GUID" kek.crt kek.esl
cert-to-efi-sig-list -g "$OWNER_GUID" db.crt db.esl

ls *.esl
db.esl  kek.esl  pk.esl
```

## Create signed AUTH files

### PK

```
TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
sign-efi-sig-list -o -t "$TS" -g "$OWNER_GUID" PK pk.esl pk.tbs

openssl cms -sign -binary -outform PEM -md sha256 -signer pk.crt -engine pkcs11 -keyform engine -inkey "pkcs11:token=UEFIKeys;object=PKKey;type=private;pin-value=7654321" -in pk.tbs -out pk.sig

sign-efi-sig-list -i pk.sig -t "$TS" -g "$OWNER_GUID" PK pk.esl pk.auth
```

### KEK

```
TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

sign-efi-sig-list -o -t "$TS" -g "$OWNER_GUID" KEK kek.esl kek.tbs

openssl cms -sign -binary -outform PEM -md sha256 -signer pk.crt -engine pkcs11 -keyform engine -inkey "pkcs11:token=UEFIKeys;object=PKKey;type=private;pin-value=7654321" -in kek.tbs -out kek.sig

sign-efi-sig-list -i kek.sig -t "$TS" -g "$OWNER_GUID" KEK kek.esl kek.auth
```

### DB

```
TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

sign-efi-sig-list -o -t "$TS" -g "$OWNER_GUID" db db.esl db.tbs

openssl cms -sign -binary -outform PEM -md sha256 -signer kek.crt -engine pkcs11 -keyform engine -inkey "pkcs11:token=UEFIKeys;object=KEKKey;type=private;pin-value=7654321" -in db.tbs -out db.sig

sign-efi-sig-list -i db.sig -t "$TS" -g "$OWNER_GUID" db db.esl db.auth
```

## Provision UEFI

You can now proceed with provisioning your UEFI environment using these signed artifacts.
