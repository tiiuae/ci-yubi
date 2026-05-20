# SPDX-FileCopyrightText: 2022-2024 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0
# shellcheck shell=bash

# Helpers for updating an EFI System Partition inside a raw disk image without
# materializing the full raw image on disk.

UEFISIGN_SECTOR_SIZE="${UEFISIGN_SECTOR_SIZE:-512}"
UEFISIGN_STREAM_BS="${UEFISIGN_STREAM_BS:-4M}"
UEFISIGN_PARTITION_PREFIX_BYTES="${UEFISIGN_PARTITION_PREFIX_BYTES:-1048576}"
UEFISIGN_MAX_PARTITION_PREFIX_BYTES="${UEFISIGN_MAX_PARTITION_PREFIX_BYTES:-67108864}"

uefisign_log() {
  if declare -F log >/dev/null; then
    log "$@"
  else
    echo "$*"
  fi
}

uefisign_die() {
  uefisign_log "[!] $*" >&2
  exit 1
}

uefisign_raw_input() {
  local input="$1"
  local input_type="$2"

  case "$input_type" in
  zst)
    zstd -dc -- "$input"
    ;;
  raw)
    cat -- "$input"
    ;;
  *)
    uefisign_die "Unsupported raw input type: $input_type"
    ;;
  esac
}

uefisign_extract_raw_range_to_file() {
  local input="$1"
  local input_type="$2"
  local skip_bytes="$3"
  local count_bytes="$4"
  local output="$5"
  local statuses input_rc dd_rc actual_size

  if ((count_bytes < 0)); then
    uefisign_die "Invalid byte count: $count_bytes"
  fi

  rm -f -- "$output"
  if ((count_bytes == 0)); then
    : >"$output"
    return 0
  fi

  set +e
  set +o pipefail
  # zstd streams are not seekable here, so byte ranges are selected by
  # re-reading from the start and letting dd skip/count the raw bytes.
  uefisign_raw_input "$input" "$input_type" |
    dd of="$output" bs="$UEFISIGN_STREAM_BS" iflag=fullblock,skip_bytes,count_bytes skip="$skip_bytes" count="$count_bytes" status=none
  statuses=("${PIPESTATUS[@]}")
  set -o pipefail
  set -e

  input_rc="${statuses[0]}"
  dd_rc="${statuses[1]}"
  if ((dd_rc != 0)); then
    uefisign_die "Failed to extract byte range from raw image"
  fi
  # For bounded reads dd exits after count_bytes and may close the pipe before
  # zstd/cat finish writing. SIGPIPE is expected in that case.
  if ((input_rc != 0 && input_rc != 141)); then
    uefisign_die "Failed to read raw image stream"
  fi

  actual_size="$(stat -c%s -- "$output")"
  if ((actual_size != count_bytes)); then
    uefisign_die "Short read from raw image: expected $count_bytes bytes, got $actual_size"
  fi
}

uefisign_stream_raw_range() {
  local input="$1"
  local input_type="$2"
  local skip_bytes="$3"
  local count_bytes="${4:-}"
  local iflags statuses input_rc dd_rc

  if [[ -n "$count_bytes" && "$count_bytes" -eq 0 ]]; then
    return 0
  fi

  iflags="fullblock,skip_bytes"
  if [[ -n "$count_bytes" ]]; then
    iflags+=",count_bytes"
  fi

  set +e
  set +o pipefail
  if [[ -n "$count_bytes" ]]; then
    uefisign_raw_input "$input" "$input_type" |
      dd bs="$UEFISIGN_STREAM_BS" iflag="$iflags" skip="$skip_bytes" count="$count_bytes" status=none
  else
    uefisign_raw_input "$input" "$input_type" |
      dd bs="$UEFISIGN_STREAM_BS" iflag="$iflags" skip="$skip_bytes" status=none
  fi
  statuses=("${PIPESTATUS[@]}")
  set -o pipefail
  set -e

  input_rc="${statuses[0]}"
  dd_rc="${statuses[1]}"
  if ((dd_rc != 0)); then
    return "$dd_rc"
  fi
  if [[ -n "$count_bytes" ]]; then
    if ((input_rc != 0 && input_rc != 141)); then
      return "$input_rc"
    fi
  elif ((input_rc != 0)); then
    return "$input_rc"
  fi
}

uefisign_hex_at() {
  local file="$1"
  local offset="$2"
  local length="$3"

  od -An -v -j "$offset" -N "$length" -t x1 -- "$file" | tr -d ' \n'
}

uefisign_le_uint_at() {
  local file="$1"
  local offset="$2"
  local length="$3"
  local hex reversed
  local i

  hex="$(uefisign_hex_at "$file" "$offset" "$length")"
  if ((${#hex} != length * 2)); then
    uefisign_die "Could not read $length bytes at offset $offset"
  fi

  reversed=""
  for ((i = ${#hex} - 2; i >= 0; i -= 2)); do
    reversed+="${hex:i:2}"
  done

  printf '%s\n' "$((16#$reversed))"
}

uefisign_parse_mbr_esp() {
  local prefix="$1"
  local entry type start sectors
  local index pass

  # Prefer the official EFI MBR type, then fall back to FAT32 types used by
  # some legacy aarch64 images for their ESP.
  for pass in official fat32; do
    for index in 0 1 2 3; do
      entry=$((446 + index * 16))
      type="$(uefisign_hex_at "$prefix" $((entry + 4)) 1)"
      if [[ "$pass" == "official" && "$type" != "ef" ]]; then
        continue
      fi
      if [[ "$pass" == "fat32" && "$type" != "0b" && "$type" != "0c" ]]; then
        continue
      fi
      start="$(uefisign_le_uint_at "$prefix" $((entry + 8)) 4)"
      sectors="$(uefisign_le_uint_at "$prefix" $((entry + 12)) 4)"
      if ((start > 0 && sectors > 0)); then
        printf '%s %s\n' "$start" "$sectors"
        return 0
      fi
    done
  done

  return 1
}

uefisign_gpt_entries_end() {
  local prefix="$1"
  local entries_lba entry_count entry_size entries_offset entries_end

  entries_lba="$(uefisign_le_uint_at "$prefix" $((UEFISIGN_SECTOR_SIZE + 72)) 8)"
  entry_count="$(uefisign_le_uint_at "$prefix" $((UEFISIGN_SECTOR_SIZE + 80)) 4)"
  entry_size="$(uefisign_le_uint_at "$prefix" $((UEFISIGN_SECTOR_SIZE + 84)) 4)"

  if ((entries_lba < 2)); then
    uefisign_die "Invalid GPT partition entry LBA: $entries_lba"
  fi
  if ((entry_count < 1 || entry_count > 32768)); then
    uefisign_die "Invalid GPT partition entry count: $entry_count"
  fi
  if ((entry_size < 128 || entry_size > 4096)); then
    uefisign_die "Invalid GPT partition entry size: $entry_size"
  fi

  entries_offset=$((entries_lba * UEFISIGN_SECTOR_SIZE))
  entries_end=$((entries_offset + entry_count * entry_size))
  if ((entries_end > UEFISIGN_MAX_PARTITION_PREFIX_BYTES)); then
    uefisign_die "GPT partition table is unexpectedly large: $entries_end bytes"
  fi

  printf '%s\n' "$entries_end"
}

uefisign_parse_gpt_esp() {
  local prefix="$1"
  # GPT GUID fields are stored in mixed endian order. This is the on-disk byte
  # sequence for C12A7328-F81F-11D2-BA4B-00A0C93EC93B.
  local esp_guid="28732ac11ff8d211ba4b00a0c93ec93b"
  local entries_lba entry_count entry_size entries_offset entry_offset
  local type_guid first_lba last_lba sectors
  local index

  entries_lba="$(uefisign_le_uint_at "$prefix" $((UEFISIGN_SECTOR_SIZE + 72)) 8)"
  entry_count="$(uefisign_le_uint_at "$prefix" $((UEFISIGN_SECTOR_SIZE + 80)) 4)"
  entry_size="$(uefisign_le_uint_at "$prefix" $((UEFISIGN_SECTOR_SIZE + 84)) 4)"
  entries_offset=$((entries_lba * UEFISIGN_SECTOR_SIZE))

  for ((index = 0; index < entry_count; index++)); do
    entry_offset=$((entries_offset + index * entry_size))
    type_guid="$(uefisign_hex_at "$prefix" "$entry_offset" 16)"
    if [[ "$type_guid" == "$esp_guid" ]]; then
      first_lba="$(uefisign_le_uint_at "$prefix" $((entry_offset + 32)) 8)"
      last_lba="$(uefisign_le_uint_at "$prefix" $((entry_offset + 40)) 8)"
      if ((first_lba <= 0 || last_lba < first_lba)); then
        uefisign_die "Invalid EFI partition bounds in GPT"
      fi
      sectors=$((last_lba - first_lba + 1))
      printf '%s %s\n' "$first_lba" "$sectors"
      return 0
    fi
  done

  return 1
}

uefisign_find_efi_partition() {
  local input="$1"
  local input_type="$2"
  local prefix="$3"
  local signature gpt_signature entries_end prefix_size

  uefisign_extract_raw_range_to_file "$input" "$input_type" 0 "$UEFISIGN_PARTITION_PREFIX_BYTES" "$prefix"

  signature="$(uefisign_hex_at "$prefix" 510 2)"
  if [[ "$signature" != "55aa" ]]; then
    uefisign_die "Raw image does not have an MBR boot signature"
  fi

  gpt_signature="$(uefisign_hex_at "$prefix" "$UEFISIGN_SECTOR_SIZE" 8)"
  if [[ "$gpt_signature" == "4546492050415254" ]]; then
    entries_end="$(uefisign_gpt_entries_end "$prefix")"
    prefix_size="$(stat -c%s -- "$prefix")"
    # Most images fit in the default prefix, but GPT allows a larger partition
    # entry array. Pull exactly enough bytes if this image needs more.
    if ((entries_end > prefix_size)); then
      uefisign_extract_raw_range_to_file "$input" "$input_type" 0 "$entries_end" "$prefix"
    fi
    if ! uefisign_parse_gpt_esp "$prefix"; then
      uefisign_die "Could not determine EFI partition info from GPT"
    fi
    return 0
  fi

  if ! uefisign_parse_mbr_esp "$prefix"; then
    uefisign_die "Could not determine EFI partition info from MBR"
  fi
}

uefisign_write_signed_raw_image() {
  local input="$1"
  local input_type="$2"
  local efi_image="$3"
  local efi_offset="$4"
  local efi_size="$5"
  local output="$6"
  local output_type="$7"
  local after_efi output_tmp actual_efi_size output_dir

  actual_efi_size="$(stat -c%s -- "$efi_image")"
  if ((actual_efi_size != efi_size)); then
    uefisign_die "EFI image size changed: expected $efi_size bytes, got $actual_efi_size"
  fi

  output_dir="$(dirname -- "$output")"
  mkdir -p -- "$output_dir"
  output_tmp="${output}.tmp.$$"
  rm -f -- "$output_tmp"

  after_efi=$((efi_offset + efi_size))
  case "$output_type" in
  zst)
    # Recompose the raw image as a stream. This trades extra decompression CPU
    # for avoiding a full-size temporary disk.raw.
    {
      uefisign_stream_raw_range "$input" "$input_type" 0 "$efi_offset"
      cat -- "$efi_image"
      uefisign_stream_raw_range "$input" "$input_type" "$after_efi"
    } | zstd -f -o "$output_tmp"
    ;;
  raw)
    if [[ "$input_type" == "raw" ]]; then
      # Raw inputs may be sparse. Preserve their holes by copying the original
      # image sparsely, then patch only the modified ESP into the copy.
      cp --sparse=always --reflink=auto -- "$input" "$output_tmp"
      dd if="$efi_image" of="$output_tmp" bs="$UEFISIGN_STREAM_BS" \
        oflag=seek_bytes seek="$efi_offset" conv=notrunc status=none
    else
      # If a future caller asks for raw output from a stream, recreate holes
      # for all-zero blocks instead of fully allocating the output image.
      {
        uefisign_stream_raw_range "$input" "$input_type" 0 "$efi_offset"
        cat -- "$efi_image"
        uefisign_stream_raw_range "$input" "$input_type" "$after_efi"
      } | dd of="$output_tmp" bs="$UEFISIGN_STREAM_BS" conv=sparse status=none
    fi
    ;;
  *)
    rm -f -- "$output_tmp"
    uefisign_die "Unsupported output type: $output_type"
    ;;
  esac

  mv -f -- "$output_tmp" "$output"
}
