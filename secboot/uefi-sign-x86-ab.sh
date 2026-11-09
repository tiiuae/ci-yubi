#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0
set -euo pipefail

usage() {
  echo "Usage: uefi-sign-x86-ab --key-dir DIR --private-key PKCS11_URI --input IMAGE_DIR --output DIR" >&2
  echo "--input must be a trusted, immutable Nix build output, including esp.sha256." >&2
  exit 2
}

key_dir="" private_key="" input="" output=""
while (($#)); do
  case "$1" in
  --key-dir)
    key_dir="${2:-}"
    shift 2
    ;;
  --private-key)
    private_key="${2:-}"
    shift 2
    ;;
  --input)
    input="${2:-}"
    shift 2
    ;;
  --output)
    output="${2:-}"
    shift 2
    ;;
  *) usage ;;
  esac
done
[[ -n $key_dir && -n $private_key && -n $input && -n $output ]] || usage
command -v cmp >/dev/null || {
  echo "cmp (diffutils) is required to verify the ESP inventory" >&2
  exit 1
}
[[ $private_key == pkcs11:* ]] || {
  echo "--private-key must be a PKCS#11 URI" >&2
  exit 2
}
input=$(realpath -e -- "$input")
[[ $input == /nix/store/* && -d $input ]] || {
  echo "--input must resolve to a Nix store directory" >&2
  exit 1
}
for required in public-trust.json ghaf-image.raw.zst esp.sha256; do
  file=$(realpath -e -- "$input/$required") || {
    echo "Missing $input/$required" >&2
    exit 1
  }
  [[ $file == /nix/store/* && -f $file && -s $file ]] || {
    echo "$input/$required must resolve to a nonempty file in the Nix store" >&2
    exit 1
  }
done
for required in db.crt PK.crt KEK.crt update.pub PK.auth KEK.auth db.auth; do
  [[ -s $key_dir/$required ]] || {
    echo "Missing $key_dir/$required" >&2
    exit 1
  }
done
verify_enrollment_script="${UEFI_VERIFY_ENROLLMENT:-$(dirname -- "${BASH_SOURCE[0]}")/verify-enrollment.py}"
python3 "$verify_enrollment_script" "$key_dir"
for public_file in PK.crt KEK.crt db.crt update.pub; do
  expected=$(jq -er --arg name "$public_file" '.publicTrustDigests[$name]' "$input/public-trust.json")
  actual=$(sha256sum "$key_dir/$public_file")
  actual=${actual%% *}
  [[ $actual == "$expected" ]] || {
    echo "Public trust mismatch for $public_file; rebuild with a secure-ab-build-config exported from this exact key directory" >&2
    exit 1
  }
done
[[ ! -e $output ]] || {
  echo "Refusing to overwrite $output" >&2
  exit 1
}

work=$(mktemp -d)
staging=""
cleanup() {
  rm -rf "$work"
  [[ -z $staging ]] || rm -rf "$staging"
}
trap cleanup EXIT
# Do not inherit mtools' current directory from ~/.mcwd or a caller's MCWD.
export MCWD="$work/mcwd"

zstd -d "$input/ghaf-image.raw.zst" -o "$work/ghaf-image.raw"
chmod u+w "$work/ghaf-image.raw"
esp_offset=$(
  sfdisk --json "$work/ghaf-image.raw" |
    jq -er '.partitiontable | .sectorsize as $sector |
      [.partitions[] | select((.type | ascii_downcase) == "c12a7328-f81f-11d2-ba4b-00a0c93ec93b")] |
      if length == 1 then .[0].start * $sector else error("Expected exactly one ESP") end'
)
esp_image="$work/ghaf-image.raw@@$esp_offset"
mkdir "$work/esp"
mcopy -s -i "$esp_image" '::/*' "$work/esp/"
(
  cd "$work/esp"
  find . -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum
) >"$work/esp.sha256"
cmp -s "$input/esp.sha256" "$work/esp.sha256" || {
  echo "ESP file inventory mismatch; refusing to sign modified or unlisted files" >&2
  exit 1
}

if (cd "$work/esp" && find . -mindepth 3 -maxdepth 3 -type f \
  -ipath './loader/entries/*.conf' -print -quit) | grep -q .; then
  echo "Type-1 boot entries remain in loader/entries; refusing an image whose initrd/cmdline are not UKI-bound" >&2
  exit 1
fi

sign_one() {
  local file=$1 signed="$work/signed.efi"
  systemd-sbsign sign \
    --private-key-source provider:pkcs11 \
    --private-key "$private_key" \
    --certificate-source file \
    --certificate "$key_dir/db.crt" \
    --output "$signed" "$file"
  sbverify --cert "$key_dir/db.crt" "$signed" >/dev/null
  mcopy -o -i "$esp_image" "$signed" "::/${file#"$work/esp/"}"
  rm -f "$signed"
}

for loader in \
  "$work/esp/EFI/systemd/systemd-bootx64.efi" \
  "$work/esp/EFI/BOOT/BOOTX64.EFI"; do
  [[ -f $loader ]] || {
    echo "Missing required x86 EFI loader: ${loader#"$work/esp/"}" >&2
    exit 1
  }
  sign_one "$loader"
done

mapfile -d '' ukis < <(find "$work/esp/EFI/Linux" -maxdepth 1 -type f -iname '*.efi' -print0 2>/dev/null)
((${#ukis[@]} > 0)) || {
  echo "No Type-2 UKI found under EFI/Linux; refusing an incomplete Secure Boot image" >&2
  exit 1
}
for uki in "${ukis[@]}"; do
  sign_one "$uki"
done

sync -f "$work/ghaf-image.raw"

output_parent=$(dirname -- "$output")
output_name=$(basename -- "$output")
staging=$(mktemp -d "$output_parent/.${output_name}.staging.XXXXXX")
bmaptool create "$work/ghaf-image.raw" -o "$staging/ghaf-image.bmap"
zstd -T0 --compress "$work/ghaf-image.raw" -o "$staging/ghaf-image.raw.zst"
install -m 0644 \
  "$key_dir/PK.crt" \
  "$key_dir/KEK.crt" \
  "$key_dir/PK.auth" \
  "$key_dir/KEK.auth" \
  "$key_dir/db.auth" \
  "$key_dir/db.crt" \
  "$staging/"
install -m 0644 "$input/public-trust.json" "$staging/"
mv -T --update=none-fail -- "$staging" "$output"
staging=""
echo "Signed x86 A/B image and matching enrollment payload written to $output"
