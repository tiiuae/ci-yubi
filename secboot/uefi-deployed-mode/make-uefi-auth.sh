#!/usr/bin/env bash
set -euo pipefail

# ===============================================================
# make-uefi-auth.sh
#
# Create UEFI Secure Boot ESL + AUTH blobs using OpenSSL + pkcs11 ENGINE.
# Avoids calling the ENGINE from sign-efi-sig-list by signing the TBS bundle
# with OpenSSL cms, then injecting it via `sign-efi-sig-list -i`.
#
# Requirements:
#   - openssl (OpenSSL 3)
#   - libengine-pkcs11-openssl installed
#   - cert-to-efi-sig-list, sign-efi-sig-list (from efitools)
#   - uuidgen
#   - pkcs11 engine configured via OPENSSL_CONF to point to your PKCS#11 module
#     (e.g. SoftHSM at /usr/lib/softhsm/libsofthsm2.so)
#
# Optional: If your engine config isn't global, pass --engine-conf /path/to/openssl-engine.cnf
# ===============================================================

# Defaults
OUT_DIR="."
TIMESTAMP=""       # if empty -> generated as UTC without 'Z'
OWNER_GUID=""      # if empty -> generated
ENGINE_CONF="${OPENSSL_CONF:-}"  # inherit if set
RSA_PSS=0          # off by default; set with --rsa-pss
VERBOSE=0

_usage() {
  cat <<'USAGE'
Usage:

 Single variable mode:
   make-uefi-auth.sh --var PK \
     --cert pk.crt \
     --uri  "pkcs11:token=UEFIKeys;object=PKKey;type=private;pin-value=7654321" \
     [--out outdir] [--timestamp 'YYYY-MM-DDTHH:MM:SS'] [--owner-guid UUID] \
     [--engine-conf /etc/ssl/openssl-engine.cnf] [--rsa-pss] [-v]

 Batch mode (config file):
   make-uefi-auth.sh --config sbvars.conf [--out outdir] [--engine-conf ...] [-v]

 Where sbvars.conf is a simple KEY=VALUE file with:
   pk.cert=pk.crt
   pk.uri=pkcs11:token=...PKKey...
   kek.cert=kek.crt
   kek.uri=pkcs11:token=...KEKKey...
   db.cert=db.crt
   db.uri=pkcs11:token=...DBKey...

Outputs:
  <outdir>/<var>.esl  and  <outdir>/<var>.auth  (var ∈ {PK, KEK, db})

Notes:
  - Timestamp must be strictly increasing vs firmware's stored variable timestamp.
    If omitted, we use current UTC (no trailing 'Z'), e.g. 2025-11-09T14:22:05
  - If OWNER GUID is omitted, a new uuid is generated per variable.
  - For Ed25519/Ed448 keys, we automatically omit -md sha256.
  - For RSA-PSS keys, add --rsa-pss to set padding/salt options.
  - Ensure your OpenSSL engine config points MODULE_PATH to your PKCS#11 module.
    You can pass it via --engine-conf, or set OPENSSL_CONF in the environment.

Examples:
  Single:
    ./make-uefi-auth.sh --var PK --cert pk.crt \
      --uri "pkcs11:token=UEFI;object=PKKey;type=private;pin-value=123456" \
      --out out

  Batch:
    cat > sbvars.conf <<EOF
    pk.cert=pk.crt
    pk.uri=pkcs11:token=UEFI;object=PKKey;type=private;pin-value=123456
    kek.cert=kek.crt
    kek.uri=pkcs11:token=UEFI;object=KEKKey;type=private;pin-value=123456
    db.cert=db.crt
    db.uri=pkcs11:token=UEFI;object=DBKey;type=private;pin-value=123456
    EOF
    ./make-uefi-auth.sh --config sbvars.conf --out out
USAGE
}

log() { echo "[$(date -u +'%H:%M:%S')]" "$@"; }
vlog() { [[ $VERBOSE -eq 1 ]] && echo "  • $*"; }

need() {
  command -v "$1" >/dev/null 2>&1 || { echo "ERROR: missing tool: $1" >&2; exit 1; }
}

# Detect if certificate is EdDSA to omit -md
detect_md_opts() {
  local cert="$1"
  local alg
  alg=$(openssl x509 -noout -text -in "$cert" | awk -F: '/Public Key Algorithm/ {print $2; exit}' | tr -d ' ')
  case "${alg^^}" in
    *ED25519*|*ED448*) echo "" ;;
    *) echo "-md sha256" ;;
  esac
}

# Build openssl cms sign command-line options for RSA-PSS if requested
rsa_pss_opts() {
  if [[ $RSA_PSS -eq 1 ]]; then
    echo "-sigopt rsa_padding_mode:pss -sigopt rsa_pss_saltlen:-1"
  else
    echo ""
  fi
}

# Create ESL + AUTH for one variable
# args: VAR CERT URI
one_var() {
  local VAR="$1" CERT="$2" URI="$3"
  local var_lc out_esl out_tbs out_sig out_auth ts guid mdopts pssopts
  var_lc=$(echo "$VAR" | tr '[:upper:]' '[:lower:]')
  mkdir -p "$OUT_DIR"

  out_esl="$OUT_DIR/${var_lc}.esl"
  out_tbs="$OUT_DIR/${var_lc}.tbs"
  out_sig="$OUT_DIR/${var_lc}.sig"
  out_auth="$OUT_DIR/${var_lc}.auth"

  ts="${TIMESTAMP:-$(date -u +"%Y-%m-%dT%H:%M:%S")}"
  guid="${OWNER_GUID:-$(uuidgen)}"

  log "$VAR: owner GUID=$guid  timestamp=$ts"
  vlog "cert=$CERT"
  vlog "uri=$URI"
  vlog "out_dir=$OUT_DIR"

  # 1) ESL
  cert-to-efi-sig-list -g "$guid" "$CERT" "$out_esl"
  vlog "ESL -> $out_esl"

  # 2) To-be-signed bundle
  ./sign-efi-sig-list -o -t "$ts" -g "$guid" "$VAR" "$out_esl" "$out_tbs"
  vlog "TBS -> $out_tbs"

  # 3) CMS sign with OpenSSL ENGINE (PEM)
  mdopts=$(detect_md_opts "$CERT")
  pssopts=$(rsa_pss_opts)

  # Ensure engine config is visible to this process if provided
  if [[ -n "$ENGINE_CONF" ]]; then
    export OPENSSL_CONF="$ENGINE_CONF"
  fi

  openssl cms -sign -binary -outform PEM $mdopts $pssopts \
    -signer "$CERT" \
    -engine pkcs11 -keyform engine \
    -inkey "$URI" \
    -in "$out_tbs" -out "$out_sig"
  vlog "SIG -> $out_sig"

  # 4) Inject detached/attached signature to produce AUTH
  ./sign-efi-sig-list -i "$out_sig" -t "$ts" -g "$guid" "$VAR" "$out_esl" "$out_auth"
  log "$VAR: AUTH -> $out_auth"
}

# -------- arg parsing --------
VAR=""
CERT=""
URI=""
CONFIG=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --var) VAR="$2"; shift 2 ;;
    --cert) CERT="$2"; shift 2 ;;
    --uri) URI="$2"; shift 2 ;;
    --config) CONFIG="$2"; shift 2 ;;
    --out|--out-dir) OUT_DIR="$2"; shift 2 ;;
    --timestamp) TIMESTAMP="$2"; shift 2 ;;
    --owner-guid) OWNER_GUID="$2"; shift 2 ;;
    --engine-conf) ENGINE_CONF="$2"; shift 2 ;;
    --rsa-pss) RSA_PSS=1; shift ;;
    -v|--verbose) VERBOSE=1; shift ;;
    -h|--help) _usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; _usage; exit 2 ;;
  esac
done

# -------- checks --------
need openssl
need uuidgen
need cert-to-efi-sig-list
need sign-efi-sig-list

if [[ -n "$CONFIG" ]]; then
  # Batch mode
  [[ -f "$CONFIG" ]] || { echo "ERROR: config not found: $CONFIG" >&2; exit 1; }
  # shellcheck source=/dev/null
  set -o allexport; source "$CONFIG"; set +o allexport

  # Expect pk.*, kek.*, db.*
  for VARX in pk kek db; do
    CERTX="${VARX}.cert"
    URIX="${VARX}.uri"
    CERT_VAL="${!CERTX-}"
    URI_VAL="${!URIX-}"
    if [[ -n "$CERT_VAL" && -n "$URI_VAL" ]]; then
      one_var "$(echo "$VARX" | tr '[:lower:]' '[:upper:]')" "$CERT_VAL" "$URI_VAL"
    else
      log "Skipping $(echo "$VARX" | tr '[:lower:]' '[:upper:]') (missing $CERTX or $URIX in $CONFIG)"
    fi
  done
else
  # Single mode
  [[ -n "$VAR" && -n "$CERT" && -n "$URI" ]] || { echo "ERROR: need --var, --cert, --uri (or use --config)"; _usage; exit 2; }
  case "$VAR" in
    PK|KEK|db) : ;;  # accepted names as used by efitools (note: db is lowercase)
    *) echo "WARN: unusual var name '$VAR' (expected PK|KEK|db) — continuing..." ;;
  esac
  one_var "$VAR" "$CERT" "$URI"
fi
