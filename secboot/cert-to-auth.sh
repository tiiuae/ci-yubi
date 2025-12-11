#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Generate esl and auth files for secure boot.

Options:
  --pk PATH        Path to the PK x509 certificate
  --kek PATH       Path to the KEK x509 certificate
  --db PATH        Path to the db x509 certificate
  --pk-uri URI     PKCS11 URI of the PK private key. Signs PK and KEK.
  --kek-uri URI    PKCS11 URI of the KEK private key. Signs db
  --out PATH       Where the resulting files will be written. Defaults to current working directory.
EOF
  exit 0
}

PK_URI=""
KEK_URI=""
PK=""
KEK=""
DB=""
OUT="$(pwd)"

while [[ $# -gt 0 ]]; do
  case "$1" in
  --pk)
    PK="$2"
    shift 2
    ;;
  --kek)
    KEK="$2"
    shift 2
    ;;
  --db)
    DB="$2"
    shift 2
    ;;
  --pk-uri)
    PK_URI="$2"
    shift 2
    ;;
  --kek-uri)
    KEK_URI="$2"
    shift 2
    ;;
  --out)
    OUT="$2"
    shift 2
    ;;
  -h | --help) usage ;;
  *)
    echo "Unknown option: $1"
    exit 1
    ;;
  esac
done

if [[ -z "$PK" ]] || [[ -z "$KEK" ]] || [[ -z "$DB" ]] || [[ -z "$PK_URI" ]] || [[ -z "$KEK_URI" ]]; then
  usage
fi

openssl engine -t -c pkcs11 >/dev/null || {
  echo "OpenSSL pkcs11 engine not available"
  exit 1
}

cert-to-efi-sig-list "$PK" "$OUT/PK.esl"
sign-efi-sig-list -e pkcs11 -c "$PK" -k "$PK_URI" PK "$OUT/PK.esl" "$OUT/PK.auth"

cert-to-efi-sig-list "$KEK" "$OUT/KEK.esl"
sign-efi-sig-list -e pkcs11 -c "$PK" -k "$PK_URI" -a KEK "$OUT/KEK.esl" "$OUT/KEK.auth"

cert-to-efi-sig-list "$DB" "$OUT/db.esl"
sign-efi-sig-list -e pkcs11 -c "$KEK" -k "$KEK_URI" -a db "$OUT/db.esl" "$OUT/db.auth"
