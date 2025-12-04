# Minimal Ubuntu base, no GUI
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive \
    SOFTHSM2_CONF=/etc/softhsm/softhsm2.conf

RUN echo 'Acquire::ForceIPv4 "true";' > /etc/apt/apt.conf.d/99force-ipv4 \
 && apt-get update -o Acquire::Retries=5 \
 && apt-get install -y --no-install-recommends \
    softhsm2 opensc p11-kit libp11-3 openssl \
    sbsigntool efitools jq curl ca-certificates \
    libengine-pkcs11-openssl \
    uuid-runtime \
    xorriso mtools dosfstools gawk sed coreutils systemd-ukify squashfs-tools zstd binutils systemd-boot fdisk \
    git automake build-essential binutils-dev \
    pkg-config autoconf automake libtool m4 libssl-dev libssl3 gnu-efi uuid-dev help2man \
 && rm -rf /var/lib/apt/lists/*

RUN mkdir -p /root/inst
RUN cd /root/inst && git clone https://github.com/tiiuae/sbsigntools.git
WORKDIR /root/inst/sbsigntools
RUN ./autogen.sh
RUN ./configure
RUN make
RUN cp /root/inst/sbsigntools/src/sbsign /root/sbsign


# Ensure token directory exists (Ubuntu defaults to this path)
RUN mkdir -p /var/lib/softhsm/tokens && chown -R root:root /var/lib/softhsm

# Provide an OpenSSL engine/provider config for PKCS#11 usage.
# You can use it with: `openssl ... -config /etc/ssl/openssl-pkcs11.cnf`
# or by exporting OPENSSL_CONF=/etc/ssl/openssl-pkcs11.cnf (not set by default).
# Engine is kept for compatibility with efitools

ADD --chown=root:root <<'EOF' /etc/ssl/openssl-pkcs11.cnf
openssl_conf = openssl_init

[openssl_init]
# Load legacy + default providers to keep older commands happy, then set pkcs11 engine.
providers = provider_sect
engines = engine_sect

[provider_sect]
default = default_sect
legacy = legacy_sect

[default_sect]
activate = 1

[legacy_sect]
activate = 1

[engine_sect]
pkcs11 = pkcs11_sect

[pkcs11_sect]
# Ubuntu default path for SoftHSM's PKCS#11 module:
#   /usr/lib/softhsm/libsofthsm2.so
dynamic_path = /usr/lib/x86_64-linux-gnu/engines-3/pkcs11.so
INIT = 0
MODULE_PATH = /usr/lib/softhsm/libsofthsm2.so
EOF

# --- Defaults (override with build args or env at runtime) ---
#   TOKEN_LABEL   : Token label
#   SO_PIN        : Security Officer PIN (init/reinit)
#   USER_PIN      : User PIN (for normal operations)
ARG TOKEN_LABEL=UEFIKeys
ARG SO_PIN=3537363231383830
ARG USER_PIN=123456

ENV TOKEN_LABEL=${TOKEN_LABEL} \
    SO_PIN=${SO_PIN} \
    USER_PIN=${USER_PIN}

# Bootstrap script:
#  - Initializes a SoftHSM token if none exists
#  - Generates RSA-3072, P-256 EC, and (best effort) Ed25519 keypairs
#  - Exports public keys to /opt/keys (for convenience)
ADD --chown=root:root <<'EOF' /usr/local/bin/init-softhsm.sh
#!/usr/bin/env bash
set -euo pipefail

echo "[init] Using SOFTHSM2_CONF=${SOFTHSM2_CONF}"
echo "[init] Token dir: /var/lib/softhsm/tokens"
mkdir -p /var/lib/softhsm/tokens
chmod 700 /var/lib/softhsm/tokens

# Check if an initialized token already exists
if softhsm2-util --show-slots | grep -q "Token label .*${TOKEN_LABEL}"; then
  echo "[init] Token '${TOKEN_LABEL}' already initialized. Skipping init."
else
  echo "[init] Initializing token '${TOKEN_LABEL}' ..."
  softhsm2-util --init-token --free --label "${TOKEN_LABEL}" --so-pin "${SO_PIN}" --pin "${USER_PIN}"
fi

# Capture slot for our token
SLOT=$(softhsm2-util --show-slots | awk -v lbl="${TOKEN_LABEL}" '
  $0 ~ "Slot " { slot=$2 }
  $0 ~ "Token label" && $0 ~ lbl { print slot }')

if [[ -z "${SLOT:-}" ]]; then
  echo "[init] ERROR: Could not find slot for token '${TOKEN_LABEL}'." >&2
  exit 1
fi
echo "[init] Using slot ${SLOT} for token '${TOKEN_LABEL}'"

# Directory to drop public keys/certs for convenience
mkdir -p /opt/keys

# Common pkcs11-tool base args
BASE_PKCS11="pkcs11-tool --module /usr/lib/softhsm/libsofthsm2.so --slot ${SLOT} --pin ${USER_PIN}"

# Generate keys only if they don't exist (match by id/label)
gen_if_missing () {
  local id="$1" type="$2" label="$3"
  if ${BASE_PKCS11} -O --type pubkey | grep -q "ID: ${id}"; then
    echo "[init] Key id=${id} (${label}) already exists. Skipping."
    return 0
  fi
  echo "[init] Generating ${type} id=${id} label='${label}' ..."
  ${BASE_PKCS11} --keypairgen --key-type "${type}" --label "${label}" --id "${id}"
  # Export pubkey for convenience
  ${BASE_PKCS11} -r --type pubkey --id "${id}" > "/opt/keys/${label}.pub" || true
}

# RSA-3072
gen_if_missing 01 "rsa:3072" "rsa-3072"

# EC P-256
gen_if_missing 02 "EC:prime256v1" "ec-p256"

# Ed25519 (if supported by your distro build; ignore failure)
if ${BASE_PKCS11} --keypairgen --key-type EC:edwards25519 --label "ed25519" --id 03 2>/tmp/ed.err; then
  echo "[init] Generated ed25519 key (id=03)."
  ${BASE_PKCS11} -r --type pubkey --id 03 > /opt/keys/ed25519.pub || true
else
  echo "[init] Skipping ed25519 generation (support not available)."
fi

# Show resulting objects
echo "[init] Token objects:"
${BASE_PKCS11} -O || true

echo "[init] Done."
EOF
RUN chmod +x /usr/local/bin/init-softhsm.sh

# Make token storage a volume so keys survive container restarts
VOLUME ["/var/lib/softhsm/tokens", "/opt/keys"]

COPY ghaf_sign_iso.sh /root/
COPY signme_offline.sh /root/

COPY provision-uefi-auth.sh /root/
COPY openssl-engine.cnf /root/
COPY demo.sh /root
ENV OPENSSL_CONF=/root/openssl-engine.cnf
RUN chmod +x /root/provision-uefi-auth.sh
RUN chmod +x /root/demo.sh
RUN chmod +x /root/ghaf_sign_iso.sh
WORKDIR /root

# Run the initializer at container start, then drop to a shell (override CMD in CI as needed)
CMD ["/bin/bash", "-lc", "/usr/local/bin/init-softhsm.sh && echo 'Container ready. Use pkcs11-tool/openssl as needed.' && exec bash"]
