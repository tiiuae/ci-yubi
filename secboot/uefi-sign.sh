 #!/usr/bin/env bash
 set -euo pipefail

 log() { echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*"; }

 if [[ $# -ne 4 ]]; then
   log "[!] Usage: $0 <CERT> <PKEY> <IMAGE> <OUTDIR>"
   exit 1
 fi

 CERT="$1"
 PKEY="$2"
 IMAGE="$3"
 OUTDIR="$4"

 if [[ ! -f "$IMAGE" ]]; then
   log "[!] Input file not found: $IMAGE"
   exit 1
 fi

 case "${UEFISIGN_MODE:-}" in
   iso)
     log "[*] UEFISIGN_MODE=iso → forcing ISO signer"
     exec uefisigniso "$CERT" "$PKEY" "$IMAGE" "$OUTDIR"
     ;;
   raw)
     log "[*] UEFISIGN_MODE=raw → forcing RAW signer"
     exec uefisignraw "$CERT" "$PKEY" "$IMAGE" "$OUTDIR"
     ;;
 esac

 MIME="$(file -b --mime-type "$IMAGE" || true)"
 DESC="$(file -b "$IMAGE" || true)"

 log "[DEBUG] file mime='$MIME', desc='$DESC'"

 if [[ "$MIME" == "application/x-iso9660-image" ]] \
    || [[ "$DESC" == *"ISO 9660 CD-ROM filesystem data"* ]]; then
   log "[*] Detected ISO image → using uefisigniso"
   exec uefisigniso "$CERT" "$PKEY" "$IMAGE" "$OUTDIR"
 elif [[ "$MIME" == "application/zstd" ]] \
    || [[ "$DESC" == *"Zstandard compressed data"* ]] \
    || [[ "$IMAGE" == *.zst ]]; then
   log "[*] Detected Zstandard-compressed RAW image → using uefisignraw"
   exec uefisignraw "$CERT" "$PKEY" "$IMAGE" "$OUTDIR"
 else
   log "[!] Could not identify image type."
   log "    mime='$MIME'"
   log "    desc='$DESC'"
   log "    If this is an ISO, make sure it's a proper ISO 9660 image."
   log "    If this is a RAW runtime image, it should be .raw.zst."
   exit 1
 fi
