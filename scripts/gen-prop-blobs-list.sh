#!/usr/bin/env bash
#
#  Walk vendor partition and extract file list
#  to be copied from vendor blobs generator script.
#  Script combines system-proprietary-blobs.txt into
#  a unified file so that following scripts can pick-up
#  the complete list.
#

set -e # fail on unhandled error
set -u # fail on undefined variable
#set -x # debug

declare -a sysTools=("find" "sed" "sort")

abort() {
  exit "$1"
}

usage() {
cat <<_EOF
  Usage: $(basename "$0") [options]
    OPTIONS:
      -i|--input      : Root path of /vendor partition
      -o|--output     : Path to save generated "proprietary-blobs.txt" file
      --sys-list      : File list with proprietary blobs in /system partition
      --bytecode-list : File list with proprietary bytecode archive files
      --dep-dso-list  : File list with DSO files with individual targets
_EOF
  abort 1
}

command_exists() {
  type "$1" &> /dev/null
}

verify_input() {
  if [[ ! -f "$1/build.prop" ]]; then
    echo "[-] Invalid input directory structure"
    usage
  fi

  # Also check that we don't have any pre-optimized apps in vendor image
  if [[ "$(find "$1" -name "*.odex" | wc -l | tr -d " ")" -ne 0 ]]; then
    echo "[!] Vendor partition contains pre-optimized bytecode - not supported yet"
    abort 1
  fi
}

trap "abort 1" SIGINT SIGTERM

# Check that system tools exist
for i in "${sysTools[@]}"
do
  if ! command_exists "$i"; then
    echo "[-] '$i' command not found"
    abort 1
  fi
done

INPUT_DIR=""
OUTPUT_DIR=""
IN_SYS_FILE=""
IN_BYTECODE_FILE=""
IN_DEP_DSO_FILE=""

while [[ $# -gt 1 ]]
do
  arg="$1"
  case $arg in
    -o|--output)
      OUTPUT_DIR="$(echo "$2" | sed 's:/*$::')"
      shift
      ;;
    -i|--input)
      INPUT_DIR="$(echo "$2" | sed 's:/*$::')"
      shift
      ;;
    --sys-list)
      IN_SYS_FILE="$2"
      shift
      ;;
    --bytecode-list)
      IN_BYTECODE_FILE="$2"
      shift
      ;;
    --dep-dso-list)
      IN_DEP_DSO_FILE="$2"
      shift
      ;;
    *)
      echo "[-] Invalid argument '$1'"
      usage
      ;;
  esac
  shift
done

if [[ "$INPUT_DIR" == "" || ! -d "$INPUT_DIR" ]]; then
  echo "[-] Input directory not found"
  usage
fi
if [[ "$OUTPUT_DIR" == "" || ! -d "$OUTPUT_DIR" ]]; then
  echo "[-] Output directory not found"
  usage
fi
if [[ "$IN_SYS_FILE" == "" || ! -f "$IN_SYS_FILE" ]]; then
  echo "[-] system-proprietary-blobs file not found"
  usage
fi
if [[ "$IN_BYTECODE_FILE" == "" || ! -f "$IN_BYTECODE_FILE" ]]; then
  echo "[-] bytecode-proprietary-blobs file not found"
  usage
fi
if [[ "$IN_DEP_DSO_FILE" == "" || ! -f "$IN_DEP_DSO_FILE" ]]; then
  echo "[-] dep-dso-proprietary-blobs file not found"
  usage
fi

# Verify input directory structure
verify_input "$INPUT_DIR"

readonly OUT_BLOBS_FILE_TMP="$OUTPUT_DIR/_proprietary-blobs.txt"
readonly OUT_BLOBS_FILE="$OUTPUT_DIR/proprietary-blobs.txt"

# Clean copy from previous runs
> "$OUT_BLOBS_FILE"
> "$OUT_BLOBS_FILE_TMP"

# First add all regular files from /vendor partition
find "$INPUT_DIR" -type f | sed "s#^$INPUT_DIR/##" | while read -r FILE
do
  # Skip "build.prop" since it will be re-generated at build time
  if [[ "$FILE" == "build.prop" ]]; then
    continue
  fi
  echo "vendor/$FILE" >> "$OUT_BLOBS_FILE_TMP"
done

# Then append system-proprietary-blobs
cat "$IN_SYS_FILE" >> "$OUT_BLOBS_FILE_TMP"

# Then append dep-dso-proprietary-blobs
cat "$IN_DEP_DSO_FILE" >> "$OUT_BLOBS_FILE_TMP"

# Then append bytecode-proprietary
cat "$IN_BYTECODE_FILE" >> "$OUT_BLOBS_FILE_TMP"

# Sort merged file with all lists
sort -u "$OUT_BLOBS_FILE_TMP" > "$OUT_BLOBS_FILE_TMP"

# Clean-up
rm -f "$OUT_BLOBS_FILE_TMP"

abort 0
