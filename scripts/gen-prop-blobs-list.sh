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
      -i|--input    : Root path of /vendor partition
      -s|--sys-list : File list with proprietary blobs in /system partition
      -o|--output   : Path to save generated "proprietary-blobs.txt" file
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
}

# Check that system tools exist
for i in "${sysTools[@]}"
do
  if ! command_exists "$i"; then
    echo "[-] '$i' command not found"
    abort 1
  fi
done

INPUT_DIR=""
IN_SYS_FILE=""
OUTPUT_DIR=""

while [[ $# -gt 1 ]]
do
  arg="$1"
  case $arg in
    -o|--output)
      # shellcheck disable=SC2001
      OUTPUT_DIR=$(echo "$2" | sed 's:/*$::')
      shift
      ;;
    -i|--input)
      # shellcheck disable=SC2001
      INPUT_DIR=$(echo "$2" | sed 's:/*$::')
      shift
      ;;
    -s|--sys-list)
      IN_SYS_FILE=$2
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

# Verify input directory structure
verify_input "$INPUT_DIR"

readonly OUT_BLOBS_FILE_TMP="$OUTPUT_DIR/_proprietary-blobs.txt"
readonly OUT_BLOBS_FILE="$OUTPUT_DIR/proprietary-blobs.txt"

# First add system-proprietary-blobs to
cat "$IN_SYS_FILE" > "$OUT_BLOBS_FILE_TMP"

# Then add all regular files from /vendor partition
find "$INPUT_DIR" -type f | sed "s#^$INPUT_DIR/##" | while read -r FILE
do
  # Skip "build.prop" since it will be re-generated at build time
  if [[ "$FILE" == "build.prop" ]]; then
    continue
  fi
  echo "vendor/$FILE" >> "$OUT_BLOBS_FILE_TMP"
done

# Sort & delete tmp
sort "$OUT_BLOBS_FILE_TMP" > "$OUT_BLOBS_FILE"
rm -f "$OUT_BLOBS_FILE_TMP"

abort 0
