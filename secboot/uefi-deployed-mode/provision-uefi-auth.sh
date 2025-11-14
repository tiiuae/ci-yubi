#!/usr/bin/env bash
set -euo pipefail

# ==========================================================
# provision-secboot-all.sh
#
# End-to-end UEFI Secure Boot provisioning:
#  - Detect/optionally create PK/KEK/DB keys in a PKCS#11 token
#  - Generate CSRs and issue certificates (PK self-signed, KEK by PK, db by KEK)
#  - Create ESLs and AUTH blobs (AUTH signed via OpenSSL+ENGINE to avoid efitools ENGINE segfaults)
#
# Requirements:
#   - pkcs11-tool (for keygen/detect), p11tool (optional export)
#   - openssl + libengine-pkcs11-openssl
#   - efitools: cert-to-efi-sig-list, sign-efi-sig-list
#   - uuidgen
#
# You MUST have the token initialized already (PIN works).
# ==========================================================

# --- defaults ---
MODULE="/usr/lib/softhsm/libsofthsm2.so"   # --module
TOKEN_LABEL="UEFIKeys"                      # --token-label
PIN=""                                      # --pin  (required)
SLOT=""                                     # --slot (optional; auto-detect by token label)
OUT="out"                                   # --out
KEY_TYPE="rsa:4096"                         # --key-type (e.g., rsa:4096 | ec:prime256v1)
ENGINE_CONF="${OPENSSL_CONF:-}"             # --engine-conf
RSA_PSS=0                                   # --rsa-pss => PSS for issuer signatures
VERBOSE=0

# labels/ids
PK_LABEL="PKKey";   PK_ID="01"; PK_CN="Platform Key";           PK_DAYS="3650"
KEK_LABEL="KEKKey"; KEK_ID="02"; KEK_CN="Key Exchange Key";      KEK_DAYS="3650"
DB_LABEL="DBKey";   DB_ID="03";  DB_CN="Database Key";           DB_DAYS="3650"

# helpers
need(){ command -v "$1" >/dev/null 2>&1 || { echo "ERROR: missing tool: $1" >&2; exit 1; }; }
log(){  echo "[$(date -u +'%H:%M:%S')]" "$@"; }
vlog(){ [[ $VERBOSE -eq 1 ]] && echo "  • $*"; }
die(){  echo "ERROR: $*" >&2; exit 1; }

timestamp(){ date -u +"%Y-%m-%dT%H:%M:%S"; }
guid(){ uuidgen; }

ensure_env(){
  [[ -n "$ENGINE_CONF" ]] && export OPENSSL_CONF="$ENGINE_CONF"
}

# parse args
while [[ $# -gt 0 ]]; do
  case "$1" in
    --module) MODULE="$2"; shift 2 ;;
    --token-label) TOKEN_LABEL="$2"; shift 2 ;;
    --pin) PIN="$2"; shift 2 ;;
    --slot) SLOT="$2"; shift 2 ;;
    --out|--out-dir) OUT="$2"; shift 2 ;;
    --key-type) KEY_TYPE="$2"; shift 2 ;;
    --engine-conf) ENGINE_CONF="$2"; shift 2 ;;
    --rsa-pss) RSA_PSS=1; shift ;;
    --pk-label) PK_LABEL="$2"; shift 2 ;;
    --kek-label) KEK_LABEL="$2"; shift 2 ;;
    --db-label) DB_LABEL="$2"; shift 2 ;;
    --pk-id) PK_ID="$2"; shift 2 ;;
    --kek-id) KEK_ID="$2"; shift 2 ;;
    --db-id) DB_ID="$2"; shift 2 ;;
    --pk-cn) PK_CN="$2"; shift 2 ;;
    --kek-cn) KEK_CN="$2"; shift 2 ;;
    --db-cn) DB_CN="$2"; shift 2 ;;
    --pk-days) PK_DAYS="$2"; shift 2 ;;
    --kek-days) KEK_DAYS="$2"; shift 2 ;;
    --db-days) DB_DAYS="$2"; shift 2 ;;
    -v|--verbose) VERBOSE=1; shift ;;
    -h|--help)
      cat <<EOF
Usage:
  $0 --pin <USER_PIN> [--module $MODULE] [--token-label $TOKEN_LABEL] [--slot <id>] \\
     [--out out] [--key-type "$KEY_TYPE"] [--engine-conf /etc/ssl/openssl-engine.cnf] [--rsa-pss] [-v]

  Labels/IDs (override as needed):
     --pk-label PKKey --pk-id 01 --pk-cn "Platform Key" --pk-days 3650
     --kek-label KEKKey --kek-id 02 --kek-cn "Key Exchange Key" --kek-days 3650
     --db-label DBKey --db-id 03 --db-cn "Database Key" --db-days 3650

This will:
  - Detect or create PK/KEK/DB keys on the token (via pkcs11-tool)
  - Create CSRs & certs (PK self-signed; KEK by PK; db by KEK)
  - Produce ESL + AUTH files for PK, KEK, db in <out>.

Prereqs:
  pkcs11-tool, openssl, efitools (cert-to-efi-sig-list, sign-efi-sig-list), uuidgen
  OpenSSL engine config should point MODULE_PATH to your PKCS#11 module (or pass --engine-conf).
EOF
      exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
done

[[ -n "$PIN" ]] || die "--pin is required"

# prereqs
need pkcs11-tool
need openssl
need uuidgen
need cert-to-efi-sig-list
need sign-efi-sig-list

ensure_env
mkdir -p "$OUT"

# ---- slot detection (by token label) if not provided ----
if [[ -z "$SLOT" ]]; then
  vlog "Detecting slot for token label '$TOKEN_LABEL' ..."
  SLOT_HEX=$(
    pkcs11-tool --module "$MODULE" -L | awk -v want="$TOKEN_LABEL" '
      BEGIN { slothex="" }
      /^Slot [0-9]+/ {
        # Example: "Slot 0 (0x25fd72dd): SoftHSM slot ID 0x25fd72dd"
        # Extract the "(0x...)" part
        match($0, /\(0x[0-9A-Fa-f]+\)/)
        if (RSTART) {
          sh = substr($0, RSTART+1, RLENGTH-2) # 0x25fd72dd
        } else {
          sh = ""
        }
      }
      /token label[[:space:]]*:/ {
        # Field after the colon is the label value (trim leading space)
        lbl = $0; sub(/^.*:[[:space:]]*/, "", lbl)
        if (lbl == want && sh != "") { print sh; exit }
      }
    '
  )
  if [[ -z "$SLOT_HEX" ]]; then
    die "Could not find slot for token label '$TOKEN_LABEL'"
  fi
  SLOT="$SLOT_HEX"
  log "Using slot: $SLOT"
else
  log "Using provided slot: $SLOT"
fi

# ---- key presence check / creation ----
have_key(){
  local label="$1" id="$2"
  # List private keys on token filter by label or id
  pkcs11-tool --module "$MODULE" --slot "$SLOT" -p "$PIN" -O --type privkey 2>/dev/null \
    | grep -qE "(label:\ *$label|ID:\ *$id)"
}

create_key(){
  local label="$1" id="$2"
  log "Creating keypair label='$label' id='$id' type='$KEY_TYPE'"
  pkcs11-tool --module "$MODULE" -p "$PIN" --slot "$SLOT" \
    --keypairgen --key-type "$KEY_TYPE" --label "$label" --id "$id"
}

for pair in "PK:$PK_LABEL:$PK_ID" "KEK:$KEK_LABEL:$KEK_ID" "DB:$DB_LABEL:$DB_ID"; do
  IFS=: read ROLE LBL ID <<<"$pair"
  if have_key "$LBL" "$ID"; then
    log "$ROLE: key exists (label=$LBL id=$ID) — skipping keygen"
  else
    create_key "$LBL" "$ID"
  fi
done

# ---- URIs (we can use label or id; labels are clearer) ----
PK_URI="pkcs11:token=${TOKEN_LABEL};object=${PK_LABEL};type=private;pin-value=${PIN}"
KEK_URI="pkcs11:token=${TOKEN_LABEL};object=${KEK_LABEL};type=private;pin-value=${PIN}"
DB_URI="pkcs11:token=${TOKEN_LABEL};object=${DB_LABEL};type=private;pin-value=${PIN}"

# ---- helpers for cert issuance & AUTH path ----
md_flag_for_cert(){
  # For Ed25519/Ed448 issuer cert, do NOT add -sha256
  local crt="$1"
  local alg
  alg=$(openssl x509 -noout -text -in "$crt" | awk -F: '/Public Key Algorithm/ {print $2; exit}' | tr -d ' ')
  case "${alg^^}" in *ED25519*|*ED448*) echo "" ;; *) echo "-md sha256" ;; esac
}

pss_sigopts(){
  [[ $RSA_PSS -eq 1 ]] && echo "-sigopt rsa_padding_mode:pss -sigopt rsa_pss_saltlen:-1" || echo ""
}

gen_csr(){
  local uri="$1" cn="$2" out="$3"
  log "CSR: $out  (CN=$cn)"
  openssl req -new -sha256 \
    -engine pkcs11 -keyform engine \
    -key "$uri" \
    -subj "/CN=$cn/" \
    -out "$out"
}

self_sign(){
  local csr="$1" uri="$2" days="$3" out="$4"
  log "Self-sign: $out  (days=$days)"
  openssl x509 -req -days "$days" -sha256 \
    -in "$csr" \
    -engine pkcs11 -keyform engine \
    -signkey "$uri" \
    -out "$out"
}

issue_cert(){
  local csr="$1" issuer_crt="$2" issuer_uri="$3" days="$4" out="$5"
  local md pss
  md="-sha256"; pss="$(pss_sigopts)"
  log "Issue: $out  (days=$days)"
  openssl x509 -req -days "$days" $md \
    -in "$csr" \
    -CA "$issuer_crt" -CAcreateserial \
    -CAkeyform engine -engine pkcs11 -CAkey "$issuer_uri" \
    $pss \
    -out "$out"
}

make_esl(){
  local crt="$1" out="$2" owner_guid="$3"
  cert-to-efi-sig-list -g "$owner_guid" "$crt" "$out"
}

make_tbs(){
  local var="$1" esl="$2" ts="$3" out="$4" owner_guid="$5"
  sign-efi-sig-list -o -t "$ts" -g "$owner_guid" "$var" "$esl" "$out"
}

cms_sign_tbs(){
  local tbs="$1" signer_crt="$2" signer_uri="$3" out_sig="$4"
  local md pss
  md="$(md_flag_for_cert "$signer_crt")"
  pss="$(pss_sigopts)"
  openssl cms -sign -binary -outform PEM $md $pss \
    -signer "$signer_crt" \
    -engine pkcs11 -keyform engine -inkey "$signer_uri" \
    -in "$tbs" -out "$out_sig"
}

make_auth(){
  local var="$1" esl="$2" ts="$3" sig_pem="$4" out="$5" owner_guid="$6"
  sign-efi-sig-list -i "$sig_pem" -t "$ts" -g "$owner_guid" "$var" "$esl" "$out"
}

# ---- build all three ----
build_var(){
  local VAR="$1" CN="$2" URI_SELF="$3" URI_ISSUER="$4" CRT_ISSUER="$5" DAYS="$6"

  local var_lc="${VAR,,}"
  local csr="$OUT/${var_lc}.csr"
  local crt="$OUT/${var_lc}.crt"
  local esl="$OUT/${var_lc}.esl"
  local tbs="$OUT/${var_lc}.tbs"
  local sig="$OUT/${var_lc}.sig"
  local auth="$OUT/${var_lc}.auth"
  local OWN=$(guid)
  local TS=$(timestamp)

  # CSR
  gen_csr "$URI_SELF" "$CN" "$csr"

  # CRT
  if [[ "$VAR" == "PK" ]]; then
    self_sign "$csr" "$URI_SELF" "$PK_DAYS" "$crt"
  elif [[ "$VAR" == "KEK" ]]; then
    [[ -f "$CRT_ISSUER" ]] || die "Missing issuer cert for KEK: $CRT_ISSUER"
    issue_cert "$csr" "$CRT_ISSUER" "$URI_ISSUER" "$KEK_DAYS" "$crt"
  else # db
    [[ -f "$CRT_ISSUER" ]] || die "Missing issuer cert for db: $CRT_ISSUER"
    issue_cert "$csr" "$CRT_ISSUER" "$URI_ISSUER" "$DB_DAYS" "$crt"
  fi

  # ESL
  make_esl "$crt" "$esl" "$OWN"

  # TBS
  make_tbs "$VAR" "$esl" "$TS" "$tbs" "$OWN"

  # Who signs AUTH?
  local AUTH_SIGN_CRT AUTH_SIGN_URI
  if [[ "$VAR" == "PK" ]]; then
    AUTH_SIGN_CRT="$crt"; AUTH_SIGN_URI="$URI_SELF"
  elif [[ "$VAR" == "KEK" ]]; then
    AUTH_SIGN_CRT="$OUT/pk.crt"; AUTH_SIGN_URI="$PK_URI"
  else
    AUTH_SIGN_CRT="$OUT/kek.crt"; AUTH_SIGN_URI="$KEK_URI"
  fi

  # SIG and AUTH
  cms_sign_tbs "$tbs" "$AUTH_SIGN_CRT" "$AUTH_SIGN_URI" "$sig"
  make_auth "$VAR" "$esl" "$TS" "$sig" "$auth" "$OWN"

  log "$VAR: ready → $crt  $esl  $auth"
}

# run
log "Module: $MODULE"
log "Token : $TOKEN_LABEL  (slot=$SLOT)"
log "Type  : $KEY_TYPE"
[[ -n "$ENGINE_CONF" ]] && log "Engine conf: $ENGINE_CONF"

# Ensure OpenSSL sees the engine (optional sanity)
openssl engine -t -c pkcs11 >/dev/null || die "OpenSSL pkcs11 engine not available"

# PK first
build_var "PK"  "$PK_CN"  "$PK_URI"  "$PK_URI"  ""               "$PK_DAYS"
# KEK (issuer = PK)
build_var "KEK" "$KEK_CN" "$KEK_URI" "$PK_URI"  "$OUT/pk.crt"    "$KEK_DAYS"
# db (issuer = KEK)  (efitools expects 'db' lowercase variable name)
build_var "db"  "$DB_CN"  "$DB_URI"  "$KEK_URI" "$OUT/kek.crt"   "$DB_DAYS"

log "All done. Files in: $OUT"
