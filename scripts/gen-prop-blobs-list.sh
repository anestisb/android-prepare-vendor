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

readonly SCRIPTS_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
readonly CONSTS_SCRIPT="$SCRIPTS_DIR/constants.sh"
declare -a SYS_TOOLS=("find" "sed" "sort")

abort() {
  exit "$1"
}

usage() {
cat <<_EOF
  Usage: $(basename "$0") [options]
    OPTIONS:
      -i|--input  : Root path of /vendor partition
      -o|--output : Path to save generated "proprietary-blobs.txt" file
      --conf-dir  : Directory containing device configuration files
      --api       : API level in order to pick appropriate config file
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

array_contains() {
  local element
  for element in "${@:2}"; do [[ "$element" == "$1" ]] && return 0; done
  return 1
}

is_naked_config() {
  local inConfDir="$1"
  if [[ "$(basename "$inConfDir")" == "config-naked" ]]; then
    return 0
  else
    return 1
  fi
}

trap "abort 1" SIGINT SIGTERM
. "$CONSTS_SCRIPT"

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
CONFIGS_DIR=""
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
    --conf-dir)
      CONFIGS_DIR=$(echo "$2" | sed 's:/*$::')
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
check_dir "$CONFIGS_DIR" "Base Config Dir"

# Check if API level is a number
if [[ ! "$API_LEVEL" = *[[:digit:]]* ]]; then
  echo "[-] Invalid API level (not a number)"
  abort 1
fi

readonly IN_SYS_FILE="$CONFIGS_DIR/system-proprietary-blobs-api$API_LEVEL.txt"
readonly IN_BYTECODE_FILE="$CONFIGS_DIR/bytecode-proprietary-api$API_LEVEL.txt"
readonly IN_DEP_DSO_FILE="$CONFIGS_DIR/dep-dso-proprietary-blobs-api$API_LEVEL.txt"

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

# First add all regular files or symbolic links from /vendor partition
find "$INPUT_DIR" -not -type d | sed "s#^$INPUT_DIR/##" | while read -r FILE
do
  # Skip VENDOR_SKIP_FILES since it will be re-generated at build time
  if array_contains "$FILE" "${VENDOR_SKIP_FILES[@]}"; then
    continue
  fi

  # Additional skips only for naked configs
  if is_naked_config "$CONFIGS_DIR"; then
    if array_contains "$FILE" "${VENDOR_SKIP_FILES_NAKED[@]}"; then
      continue
    fi
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
