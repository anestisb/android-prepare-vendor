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

check_dir() {
  local dirPath="$1"
  local dirDesc="$2"

  if [[ "$dirPath" == "" || ! -d "$dirPath" ]]; then
    echo "[-] $dirDesc directory not found"
    usage
  fi
}

check_file() {
  local filePath="$1"
  local fileDesc="$2"

  if [[ "$filePath" == "" || ! -f "$filePath" ]]; then
    echo "[-] $fileDesc file not found"
    usage
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

# Input args check
check_dir "$INPUT_DIR" "Input"
check_dir "$OUTPUT_DIR" "Output"

# Mandatory configuration files
check_file "$IN_SYS_FILE" "system-proprietary-blobs"
check_file "$IN_BYTECODE_FILE" "bytecode-proprietary-blobs"
check_file "$IN_DEP_DSO_FILE" "dep-dso-proprietary-blobs"

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

{
  # Then append system-proprietary-blobs
  grep -Ev '(^#|^$)' "$IN_SYS_FILE" || true

  # Then append dep-dso-proprietary-blobs
  grep -Ev '(^#|^$)' "$IN_DEP_DSO_FILE" || true

  # Then append bytecode-proprietary
  grep -Ev '(^#|^$)' "$IN_BYTECODE_FILE" || true
} >> "$OUT_BLOBS_FILE_TMP"

# Sort merged file with all lists
sort -u "$OUT_BLOBS_FILE_TMP" > "$OUT_BLOBS_FILE"

# Clean-up
rm -f "$OUT_BLOBS_FILE_TMP"

abort 0
