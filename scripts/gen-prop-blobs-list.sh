#!/usr/bin/env bash
#
# Iterate vendor partition and extract the list of files to be copied from vendor blobs generator
# script. The script combines vendor partition files and items included in the selected
# configuration, into a unified file so that following scripts can pick-up the complete list.
#

set -e # fail on unhandled error
set -u # fail on undefined variable
#set -x # debug

readonly SCRIPTS_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
readonly CONSTS_SCRIPT="$SCRIPTS_DIR/constants.sh"
readonly COMMON_SCRIPT="$SCRIPTS_DIR/common.sh"
declare -a SYS_TOOLS=("find" "sed" "sort" "jq")

abort() {
  exit "$1"
}

usage() {
cat <<_EOF
  Usage: $(basename "$0") [options]
    OPTIONS:
      -i|--input  : Root path of /vendor partition
      -o|--output : Path to save generated "proprietary-blobs.txt" file
      --conf-file : Device configuration file
      --conf-type : 'naked' or 'full' configuration profile
      --api       : API level
_EOF
  abort 1
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
. "$CONSTS_SCRIPT"
. "$COMMON_SCRIPT"

# Check that system tools exist
for i in "${SYS_TOOLS[@]}"
do
  if ! command_exists "$i"; then
    echo "[-] '$i' command not found"
    abort 1
  fi
done

INPUT_DIR=""
OUTPUT_DIR=""
CONFIG_FILE=""
CONFIG_TYPE="naked"
API_LEVEL=""

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
    --conf-file)
      CONFIG_FILE="$2"
      shift
      ;;
    --conf-type)
      CONFIG_TYPE="$2"
      shift
      ;;
    --api)
      API_LEVEL="$2"
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
check_file "$CONFIG_FILE" "Device Config File"

# Check if valid config type & API level
isValidConfigType "$CONFIG_TYPE"
isValidApiLevel "$API_LEVEL"

# Verify input directory structure
verify_input "$INPUT_DIR"

readonly OUT_BLOBS_FILE_TMP="$OUTPUT_DIR/_proprietary-blobs.txt"
readonly OUT_BLOBS_FILE="$OUTPUT_DIR/proprietary-blobs.txt"

# Clean copy from previous runs
> "$OUT_BLOBS_FILE"
> "$OUT_BLOBS_FILE_TMP"

# First add all regular files or symbolic links from /vendor partition
find "$INPUT_DIR" -not -type d | sed "s#^$INPUT_DIR/##" | while read -r FILE
do
  # Skip VENDOR_SKIP_FILES since it will be re-generated at build time
  if array_contains "$FILE" "${VENDOR_SKIP_FILES[@]}"; then
    continue
  fi

  # Additional skips only for naked configs
  if [[ "$CONFIG_TYPE" == "naked" ]]; then
    if array_contains "$FILE" "${VENDOR_SKIP_FILES_NAKED[@]}"; then
      continue
    fi
  fi

  echo "vendor/$FILE" >> "$OUT_BLOBS_FILE_TMP"
done

{
  # Then append system-proprietary-blobs
  jqIncRawArray "$API_LEVEL" "$CONFIG_TYPE" "system-other" "$CONFIG_FILE" | grep -Ev '(^#|^$)' || true

  # Then append dep-dso-proprietary-blobs
  jqIncRawArray "$API_LEVEL" "$CONFIG_TYPE" "dep-dso" "$CONFIG_FILE" | grep -Ev '(^#|^$)' || true

  # Then append bytecode-proprietary
  jqIncRawArray "$API_LEVEL" "$CONFIG_TYPE" "system-bytecode" "$CONFIG_FILE" | grep -Ev '(^#|^$)' || true
} >> "$OUT_BLOBS_FILE_TMP"

# Sort merged file with all lists
sort -u "$OUT_BLOBS_FILE_TMP" > "$OUT_BLOBS_FILE"

# Clean-up
rm -f "$OUT_BLOBS_FILE_TMP"

abort 0
