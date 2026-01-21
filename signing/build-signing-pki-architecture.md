# Build Signing Infrastructure and PKI Architecture

> **Document scope:** This document describes the *target architecture* for build signing and PKI, and separately documents the *current operational implementation* during the transition phase.

## Purpose and scope

This document describes the **PKI architecture and signing workflow** used for:

- UEFI Secure Boot signing
- SLSA Level 3 build artifact signing (binaries and provenance)

The design focuses on:
- hardware-backed key protection
- use of ephemeral signing certificates
- isolation of trust domains
- controlled access to signing keys located in a secured lab environment

This document is intended for **audit and security review purposes**.

---


---

## Current operational implementation (transition phase)

At the time of writing, the system is operating in a **controlled test-stage configuration** while the ephemeral certificate architecture is being finalized and validated.

The purpose of this section is to **explicitly document the current state**, while the remainder of the document describes the **target architecture**.

### GhafCA namespace keys (intermediate CAs)

The GhafCA namespace contains long-lived intermediate keys used to anchor operational trust domains:

| Key ID | Type | Purpose |
|------|------|---------|
| GhafSALSAIntermRSA3072 | RSA 3072 | Legacy / test SLSA hierarchy |
| **GhafSLSAIntermEC256** | EC P-256 | **Current SLSA intermediate CA** |
| GhafUEFIIntermRSA2048 | RSA 2048 | UEFI signing hierarchy |
| GhafUEFIPK | RSA | UEFI Platform Key |

The **GhafSLSAIntermEC256** key is signed by the offline Root CA stored in YubiHSM and serves as the trust anchor for SLSA-related signing.

---

### GhafInfraSigning namespace (current signing keys)

In the current test-stage setup, the following long-lived keys are used for SLSA signing:

| Key ID | Type | Usage |
|------|------|-------|
| **GhafInfraSignECP256** | EC P-256 | Binary signing |
| **GhafInfraSignProv** | Curve25519 | Provenance / attestation signing |
| GhafTSAKey | RSA | RFC 3161 timestamping |

These keys are:

- non-exportable
- protected by netHSM policy
- restricted to their respective signing purposes

Both `GhafInfraSignECP256` and `GhafInfraSignProv` are signed by the **GhafSLSAIntermEC256** intermediate CA, which chains to the offline Root CA.

---

### Certificate samples

#### CAs

```
[alextserepov@nethsm-gateway:~/nethsm/ca2]$ openssl x509 -in Ghaf-RootCA-EC.pem -text -noout 
Certificate:
    Data:
        Version: 3 (0x2)
        Serial Number:
            52:c6:50:53:17:e1:81:5e:f2:a2:9f:86:5b:f0:c5:72:ee:de:47:21
        Signature Algorithm: ecdsa-with-SHA256
        Issuer: C=FI, O=Ghaf, CN=Ghaf Root CA EC
        Validity
            Not Before: Nov 14 10:48:10 2025 GMT
            Not After : Nov  9 10:48:10 2045 GMT
        Subject: C=FI, O=Ghaf, CN=Ghaf Root CA EC
        Subject Public Key Info:
            Public Key Algorithm: id-ecPublicKey
                Public-Key: (256 bit)
                pub:
                    04:ef:38:eb:66:fc:61:da:02:ae:1c:e9:1c:52:4c:
                    f6:b0:96:61:ce:5e:c5:30:d6:f3:b9:ac:74:e9:fa:
                    60:b9:fd:ab:14:36:00:84:a0:2a:0b:21:00:04:4b:
                    13:be:84:3b:7d:1b:76:28:06:63:08:7f:9c:bc:96:
                    81:f9:b9:1c:2a
                ASN1 OID: prime256v1
                NIST CURVE: P-256
        X509v3 extensions:
            X509v3 Basic Constraints: critical
                CA:TRUE
            X509v3 Key Usage: critical
                Certificate Sign, CRL Sign
            X509v3 Subject Key Identifier: 
                96:D9:24:3C:4C:45:89:9A:BC:64:81:08:66:2D:91:39:24:14:8C:D0
            X509v3 Authority Key Identifier: 
                96:D9:24:3C:4C:45:89:9A:BC:64:81:08:66:2D:91:39:24:14:8C:D0
    Signature Algorithm: ecdsa-with-SHA256
    Signature Value:
        30:45:02:21:00:96:54:76:bb:83:41:29:4f:e5:d6:a1:15:02:
        fa:71:c6:7e:19:11:c8:81:43:e1:e4:75:8e:cc:10:b4:59:e0:
        9f:02:20:34:8e:67:a8:4c:c7:ac:4c:b5:f7:dd:78:45:bb:c5:
        1d:02:04:65:0a:d6:39:70:5d:0c:0b:17:fb:c3:f5:24:25

[alextserepov@nethsm-gateway:~/nethsm/ca2]$ openssl x509 -in GhafSLSAIntermEC256.pem -text -noout 
Certificate:
    Data:
        Version: 3 (0x2)
        Serial Number: 1 (0x1)
        Signature Algorithm: ecdsa-with-SHA256
        Issuer: C=FI, O=Ghaf, CN=Ghaf Root CA EC
        Validity
            Not Before: Dec  1 21:56:44 2025 GMT
            Not After : Nov 29 21:56:44 2035 GMT
        Subject: CN=Ghaf, C=FI, L=Tampere, ST=Tampere, O=Ghaf, emailAddress=aleksandr.tserepov-savolainen@unikie.com
        Subject Public Key Info:
            Public Key Algorithm: id-ecPublicKey
                Public-Key: (256 bit)
                pub:
                    04:66:e6:41:e0:2d:17:6d:7c:4c:10:4b:c1:6c:2f:
                    6a:eb:b4:c2:50:b4:17:f5:56:7b:75:1e:18:0e:61:
                    81:6b:a5:2d:4b:cb:78:f0:cd:b9:88:a2:9f:3b:96:
                    97:fe:6d:d6:4f:4c:ad:ea:2a:44:d2:e2:20:55:d0:
                    34:6f:5d:0b:62
                ASN1 OID: prime256v1
                NIST CURVE: P-256
        X509v3 extensions:
            X509v3 Subject Key Identifier: 
                7F:10:E1:6D:A6:9A:DC:11:36:91:28:A5:BE:31:04:DF:D3:A0:64:CA
            X509v3 Authority Key Identifier: 
                96:D9:24:3C:4C:45:89:9A:BC:64:81:08:66:2D:91:39:24:14:8C:D0
    Signature Algorithm: ecdsa-with-SHA256
    Signature Value:
        30:45:02:20:5c:4c:16:14:7f:d4:a6:46:c0:79:14:bc:c9:f3:
        07:6f:1a:8f:65:a6:5f:c9:03:e3:e2:ca:97:f8:ff:93:cc:ef:
        02:21:00:b2:4e:7a:4b:a9:c0:b7:d3:81:89:8f:20:ad:66:99:
        9d:73:3a:fa:6f:8b:8d:68:71:48:8b:f0:c1:67:29:ac:8b

```

#### Long lived leaf

```
[alextserepov@nethsm-gateway:~/nethsm/ca2]$ openssl x509 -in leaf.pem -text -noout
Certificate:
    Data:
        Version: 3 (0x2)
        Serial Number:
            61:6f:74:29:4a:3d:ab:f7:e3:78:b1:97:d5:c9:bd:82:31:22:5a:79
        Signature Algorithm: ecdsa-with-SHA256
        Issuer: CN=Ghaf, C=FI, L=Tampere, ST=Tampere, O=Ghaf, emailAddress=aleksandr.tserepov-savolainen@unikie.com
        Validity
            Not Before: Dec  2 09:30:56 2025 GMT
            Not After : Dec  2 09:30:56 2026 GMT
        Subject: CN=Ghaf, C=FI, L=Tampere, ST=Tampere, O=Ghaf, emailAddress=aleksandr.tserepov-savolainen@unikie.com
        Subject Public Key Info:
            Public Key Algorithm: id-ecPublicKey
                Public-Key: (256 bit)
                pub:
                    04:d7:e8:21:83:c1:25:a1:bb:31:d2:37:c7:a0:65:
                    b1:b3:1c:87:80:8f:7f:9c:fd:7f:e9:ff:9e:9d:44:
                    5d:20:70:6a:d4:b3:9f:db:28:09:4a:15:27:d8:c6:
                    62:9a:e0:71:8d:c6:d1:56:10:6f:7b:50:63:e9:fd:
                    14:2e:6f:12:78
                ASN1 OID: prime256v1
                NIST CURVE: P-256
        X509v3 extensions:
            X509v3 Subject Key Identifier: 
                74:83:E2:12:78:07:4D:CF:9A:41:82:10:96:87:4E:E7:96:CA:26:EE
            X509v3 Authority Key Identifier: 
                7F:10:E1:6D:A6:9A:DC:11:36:91:28:A5:BE:31:04:DF:D3:A0:64:CA
    Signature Algorithm: ecdsa-with-SHA256
    Signature Value:
        30:46:02:21:00:bc:3e:57:ee:fb:ea:de:4e:27:ea:72:65:39:
        f3:28:c8:db:64:51:b5:4c:32:ca:31:de:83:a5:3e:94:71:17:
        b0:02:21:00:d9:35:27:20:2a:67:f4:89:5d:ec:ca:9d:ff:c6:
        c5:35:7e:cc:08:02:63:59:36:44:80:59:a2:4c:eb:b7:8c:bd
```

---
## CI signing implementation (current)

The following excerpt illustrates how signing is currently performed in the CI pipeline
during the **transition phase**.

This implementation reflects the **current operational use of long-lived, HSM-protected
signing keys**, while the ephemeral certificate model is under active development.

The snippet is **illustrative**; the canonical source of truth is the GitHub repository.

- **Pinned audit reference:**  
  https://github.com/tiiuae/ghaf-infra/blob/04a9a35f0fd741e967c3af052118f16307b7377d/hosts/hetzci/pipelines/modules/utils.groovy#L115-L164
- **Latest version:**  
  https://github.com/tiiuae/ghaf-infra/blob/main/hosts/hetzci/pipelines/modules/utils.groovy

```groovy
// Signing stages
// Skip signing stages in vm environment, where NetHSM is not available
if (env.CI_ENV != 'vm') {
  if (!it.no_image) {
    stage("Sign image ${shortname}") {
      def img_path = get_img_path(it.target, artifacts_local_dir)
      sh """
        mkdir -v -p "$(dirname "${artifacts_local_dir}/scs/${img_path}")"
      """
      lock('signing') {
        sh """
          openssl dgst -sha256 -sign \
            "pkcs11:token=NetHSM;object=GhafInfraSignECP256" \
            -out ${artifacts_local_dir}/scs/${img_path}.sig \
            ${artifacts_local_dir}/${img_path}
        """
      }
    }
  }

  stage("Sign provenance ${shortname}") {
    lock('signing') {
      sh """
        openssl pkeyutl -sign -rawin \
          -inkey "pkcs11:token=NetHSM;object=GhafInfraSignProv" \
          -out ${artifacts_local_dir}/scs/${it.target}/provenance.json.sig \
          -in ${artifacts_local_dir}/scs/${it.target}/provenance.json
      """
    }
  }

  if (it.get('uefisign', false) || it.get('uefisigniso', false)) {
    stage("Sign UEFI ${shortname}") {
      def diskPath = artifacts_local_dir + "/" + get_img_path(it.target, artifacts_local_dir)
      def outdir = run_cmd("dirname '${diskPath}' | sed 's/${it.target}/uefisigned\\/${it.target}/'")
      sh "mkdir -v -p ${outdir}"

      lock('signing') {
        sh "uefisign /etc/jenkins/keys/tempDBkey.pem 'pkcs11:token=NetHSM;object=tempDBkey' '${diskPath}' ${outdir}"
      }

      def keydir = "keys"
      def keysLocation = "${outdir}/${keydir}"
      sh """
        cp -r -L /etc/jenkins/keys/secboot ${keysLocation}
        chmod +w ${keysLocation}
        cp -L /etc/jenkins/enroll-secureboot-keys.sh ${keysLocation}/enroll.sh
        tar -cvf ${keysLocation}.tar -C ${outdir} ${keydir}
      """
    }
  }
}
```

---

### Transition to ephemeral certificates

The **ephemeral certificate model described in this document represents the target architecture**.

Current state:
- Long-lived SLSA signing keys are used temporarily
- Verification logic, trust pinning, and timestamping already follow the final design

Target state:
- Per-build ephemeral leaf certificates
- Short-lived, non-reusable signing keys
- Same Root CA and SLSA intermediate CA
- No change required for consumers or verifiers

The ephemeral certificate implementation is under active development and review:

- https://github.com/tiiuae/ci-yubi/pull/47

Once finalized, long-lived SLSA signing keys will be replaced by ephemeral per-build certificates without altering trust anchors or verification workflows.


## High-level PKI architecture

The Ghaf PKI follows a **two-tier HSM-backed model**.

### Root CA (offline)

- Stored exclusively in an **offline YubiHSM2**
- Never connected to any network
- Used only to sign intermediate CA CSRs during controlled ceremonies
- Acts as the ultimate trust anchor

### Operational PKI (online, lab environment)

- Hosted on **netHSM**
- Keys are non-exportable and protected by HSM policy
- Contains multiple isolated namespaces:
  - UEFI signing PKI
  - SLSA signing PKI
  - Ephemeral signing space

All operational signing is performed inside netHSM; private keys are never exposed outside HSM boundaries.

---

## SLSA signing PKI structure

Within the operational PKI, SLSA signing is isolated from all other use cases.

### SLSA Intermediate CA

- Signed by the GhafCA Namespace CA
- Lifetime: 5 years
- Issues only subordinate SLSA CAs
- Revocable if compromise is suspected

### Subordinate SLSA CAs

Two logically separated hierarchies:
- **Binary Signing CA**
- **Provenance Signing CA**

These CAs are used exclusively to issue **ephemeral leaf certificates** for CI builds.

---

## Ephemeral certificate model

### Key and certificate lifecycle

- For each build, a **new key pair is generated inside netHSM**
- The key is used to sign:
  - build binaries
  - SLSA provenance / attestations
- The private key:
  - is non-exportable
  - exists only for the duration of the build
  - is deleted immediately after signing (with short audit retention)

### Certificate characteristics

Ephemeral leaf certificates are constrained by:
- Extended Key Usage: *code signing only*
- Certificate Policy OIDs specific to SLSA build signing
- Embedded metadata:
  - build ID
  - CI pipeline identifier
  - Git commit or tag
  - builder identity

Certificate lifetime is limited to **per-build or maximum 24 hours**.

---

## Signing infrastructure topology

### Physical and network separation

- **netHSM and YubiHSM are located in a secured lab environment**, behind a firewall
- CI environments do **not** have direct network access to the lab
- Access to signing services is mediated via:
  - **Nebula VPN tunnel**
  - TLS-protected PKCS#11 proxy connections

This ensures:
- signing keys are never exposed to CI hosts
- access to HSMs is restricted to authenticated, encrypted channels

---

## PKCS#11 proxy-based signing flow

### Diagram

![Build signing infrastructure diagram](https://raw.githubusercontent.com/joinemm/ghaf-infra/5c917b80ce5137fa54eed6af7af0cc705cfcd73c/docs/nethsm-setup.png)

Source: https://github.com/joinemm/ghaf-infra/blob/5c917b80ce5137fa54eed6af7af0cc705cfcd73c/docs/nethsm-setup.png

### Components involved

#### CI environment

- Uses:
  - `systemd-sbsign` for UEFI signing
  - `OpenSSL 3.x` for SLSA artifact signing
- Uses OpenSSL PKCS#11 provider (`pkcs11.so`)
- Connects to `libpkcs11proxy.so`

#### Lab / NUC environment

- Hosts a PKCS#11 proxy daemon
- Acts as a netHSM gateway
- Runs a customized `pkcs11-proxy`
- Translates PKCS#11 operations into netHSM API calls

#### HSMs

- **netHSM** – network HSM for operational CAs and ephemeral keys
- **YubiHSM2** – USB-attached HSM for offline Root CA operations

---

## Signing workflow (step-by-step)

1. CI invokes `systemd-sbsign` or `OpenSSL 3.x`
2. OpenSSL routes signing operations via the PKCS#11 provider
3. PKCS#11 calls are forwarded over a TLS-protected PKCS#11 proxy
4. Transport occurs via a **Nebula tunnel**
5. The lab gateway routes requests:
   - to `libnethsm` for netHSM operations
   - to `libyubihsm` and `yubihsm-connector` for YubiHSM operations
6. Signing occurs inside the HSM
7. Only cryptographic results are returned to CI

Private keys never leave the lab environment.

---

## Timestamping and long-term verification

- All SLSA signatures are timestamped using an **RFC 3161 Time-Stamping Authority**
- Verification enforces:
  - valid signature
  - valid certificate chain
  - required certificate policy constraints
  - timestamp existence
  - timestamp within ephemeral certificate validity window

This enables long-term verification without long-lived signing keys.

---

## Trust distribution and verification

- Trust anchors (SLSA Intermediate CA certificates) are **not distributed via artifact servers**
- They are:
  - stored in a dedicated Git repository
  - consumed via **Nix flakes**
  - pinned by commit hash in `flake.lock`
  - installed locally on verifier systems

Verification explicitly checks that ephemeral certificates chain to the locally pinned trust anchor.

---

## Security properties and audit considerations

This design ensures:

- CI systems never hold signing keys
- All keys are hardware-protected and non-exportable
- Signing access is network-isolated and authenticated
- Trust anchors are pinned independently of artifact distribution
- Compromise blast radius is limited by ephemeral keys
- Revocation is handled at CA level if required

---

## Link collection

- Signing implementation (CI pipeline utility): https://github.com/tiiuae/ghaf-infra/blob/531928ebc7145fa5182b479f0c0acd6121deaba9/hosts/hetzci/pipelines/modules/utils.groovy#L119-L152
- Ephemeral certificates implementation and review: https://github.com/tiiuae/ci-yubi/pull/47/
- Signature verification script: https://github.com/tiiuae/ghaf-infra/blob/main/scripts/verify-signature.sh

- Nitrokey NetHSM: https://www.nitrokey.com/products/nethsm
- YubHSM2: https://www.yubico.com/products/hardware-security-module/

---
