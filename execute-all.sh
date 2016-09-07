#!/usr/bin/env bash
#
#  Generate AOSP compatible vendor data for provided device & buildID
#

set -e # fail on unhandled error
set -u # fail on undefined variable
#set -x # debug

readonly SCRIPTS_ROOT="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# Helper script to download Nexus factory images from web
readonly DOWNLOAD_SCRIPT="$SCRIPTS_ROOT/scripts/download-nexus-image.sh"

# Helper script to extract system & vendor images data
readonly EXTRACT_SCRIPT="$SCRIPTS_ROOT/scripts/extract-factory-images.sh"

# Helper script to generate "proprietary-blobs.txt" file
readonly GEN_BLOBS_LIST_SCRIPT="$SCRIPTS_ROOT/scripts/gen-prop-blobs-list.sh"

# Helper script to de-optimize bytecode prebuilts
readonly REPAIR_SCRIPT="$SCRIPTS_ROOT/scripts/system-img-repair.sh"

# Helper script to generate vendor AOSP includes & makefiles
readonly VGEN_SCRIPT="$SCRIPTS_ROOT/scripts/generate-vendor.sh"

# Change this if you don't want to apply used Java version system-wide
readonly LC_J_HOME="/usr/local/java/jdk1.8.0_71/bin/java"

declare -a sysTools=("mkdir" "readlink" "dirname")
declare -a availDevices=("bullhead" "flounder" "angler")

abort() {
  exit "$1"
}

usage() {
cat <<_EOF
  Usage: $(basename "$0") [options]
    OPTIONS:
      -d|--device  : Device codename (angler, bullhead, etc.)
      -a|--alias   : Device alias (e.g. flounder volantis (WiFi) vs volantisg (LTE))
      -b|--buildID : BuildID string (e.g. MMB29P)
      -o|--output  : Path to save generated vendor data
      -i|--img     : [OPTIONAL] Read factory image archive from file instead of downloading
      -k|--keep    : [OPTIONAL] Keep all factory images extracted & repaired data
      -s|--skip    : [OPTIONAL] Skip /system bytecode repairing (for debug purposes)
_EOF
  abort 1
}

command_exists() {
  type "$1" &> /dev/null
}

run_as_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "[-] Script must run as root"
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

# Resolve Java location
readonly JAVALINK=$(which java)
if [[ "$JAVALINK" == "" ]]; then
  echo "[!] Java binary not found in path, using hardcoded path"
  if [ ! -f "$LC_J_HOME" ]; then
    echo "[-] '$LC_J_HOME' not found in system"
    abort 1
  fi

  export JAVA_HOME=$LC_J_HOME
  export PATH
  PATH=$(dirname "$LC_J_HOME"):$PATH
else
  readonly JAVAPATH=$(readlink -f "$JAVALINK")
  readonly JAVADIR=$(dirname "$JAVAPATH")
  export JAVA_HOME="$JAVAPATH"
  export PATH="$JAVADIR":$PATH
fi

# Check if script run as root
run_as_root

DEVICE=""
BUILDID=""
OUTPUT_DIR=""
INPUT_IMG=""
KEEP_DATA=false
HOST_OS=""
DEV_ALIAS=""
API_LEVEL=""
SKIP_SYSDEOPT=false

while [[ $# -gt 0 ]]
do
  arg="$1"
  case $arg in
    -o|--output)
      OUTPUT_DIR=$(echo "$2" | sed 's:/*$::')
      shift
      ;;
    -d|--device)
      DEVICE=$(echo "$2" | tr '[:upper:]' '[:lower:]')
      shift
      ;;
    -a|--alias)
      DEV_ALIAS=$(echo "$2" | tr '[:upper:]' '[:lower:]')
      shift
      ;;
    -b|--buildID)
      BUILDID=$(echo "$2" | tr '[:upper:]' '[:lower:]')
      shift
      ;;
    -i|--imgs)
      INPUT_IMG=$2
      shift
      ;;
    -k|--keep)
      KEEP_DATA=true
      ;;
    -s|--skip)
      SKIP_SYSDEOPT=true
      ;;
    *)
      echo "[-] Invalid argument '$1'"
      usage
      ;;
  esac
  shift
done

if [[ "$DEVICE" == "" ]]; then
  echo "[-] device codename cannot be empty"
  usage
fi
if [[ "$BUILDID" == "" ]]; then
  echo "[-] buildID cannot be empty"
  usage
fi
if [[ "$OUTPUT_DIR" == "" || ! -d "$OUTPUT_DIR" ]]; then
  echo "[-] Output directory not found"
  usage
fi
if [[ "$INPUT_IMG" != "" && ! -f "$INPUT_IMG" ]]; then
  echo "[-] '$INPUT_IMG' file not found"
  abort 1
fi

# Adjust hosts tools based on OS
HOST_OS=$(uname)
if [[ "$HOST_OS" != "Linux" && "$HOST_OS" != "Darwin" ]]; then
  echo "[-] '$HOST_OS' OS is not supported"
  abort 1
fi

# Check if supported device
deviceOK=false
for devNm in "${availDevices[@]}"
do
  if [[ "$devNm" == "$DEVICE" ]]; then
    deviceOK=true
  fi
done
if [ "$deviceOK" = false ]; then
  echo "[-] '$DEVICE' is not supported"
  abort 1
fi

# Prepare output dir structure
OUT_BASE="$OUTPUT_DIR/$DEVICE/$BUILDID"
if [ ! -d "$OUT_BASE" ]; then
  mkdir -p "$OUT_BASE"
fi
FACTORY_IMGS_DATA="$OUT_BASE/factory_imgs_data"
FACTORY_IMGS_R_DATA="$OUT_BASE/factory_imgs_repaired_data"
echo "[*] Setting output base to '$OUT_BASE'"

# Download images if not provided
factoryImgArchive=""
if [[ "$INPUT_IMG" == "" ]]; then

  # Factory image alias for devices with naming incompatibilities with AOSP
  if [[ "$DEVICE" == "flounder" && "$DEV_ALIAS" == "" ]]; then
    echo "[-] Building for flounder requires setting the device alias option - 'volantis' or 'volantisg'"
    abort 1
  fi
  if [[ "$DEV_ALIAS" == "" ]]; then
    DEV_ALIAS="$DEVICE"
  fi

 $DOWNLOAD_SCRIPT --device "$DEVICE" --alias "$DEV_ALIAS" \
       --buildID "$BUILDID" --output "$OUT_BASE" || {
    echo "[-] Images download failed"
    abort 1
  }
  factoryImgArchive="$(find "$OUT_BASE" -iname "*$DEV_ALIAS*$BUILDID*.tgz" -or \
                       -iname "*$DEV_ALIAS*$BUILDID*.zip" | head -1)"
else
  factoryImgArchive="$INPUT_IMG"
fi

if [[ "$factoryImgArchive" == "" ]]; then
  echo "[-] Failed to locate factory image archive"
  abort 1
fi

# Define API level from first char of build tag
magicChar=$(echo "${BUILDID:0:1}" | tr '[:upper:]' '[:lower:]')
case "$magicChar" in
  "m")
    API_LEVEL=23
    ;;
  "n")
    API_LEVEL=24
    ;;
  *)
    echo "[-] Unsupported API level for magic '$magicChar'"
    abort 1
    ;;
esac
echo "[*] Processing with 'API-$API_LEVEL' configuration"

# Clear old data if present & extract data from factory images
if [ -d "$FACTORY_IMGS_DATA" ]; then
  rm -rf "${FACTORY_IMGS_DATA:?}"/*
else
  mkdir -p "$FACTORY_IMGS_DATA"
fi
$EXTRACT_SCRIPT --input "$factoryImgArchive" --output "$FACTORY_IMGS_DATA" \
     --simg2img "$SCRIPTS_ROOT/hostTools/$HOST_OS/bin/simg2img" || {
  echo "[-] Factory images data extract failed"
  abort 1
}

# Generate unified readonly "proprietary-blobs.txt"
$GEN_BLOBS_LIST_SCRIPT --input "$FACTORY_IMGS_DATA/vendor" \
     --output "$SCRIPTS_ROOT/$DEVICE" \
     --sys-list "$SCRIPTS_ROOT/$DEVICE/system-proprietary-blobs-api""$API_LEVEL"".txt" || {
  echo "[-] 'proprietary-blobs.txt' generation failed"
  abort 1
}

# De-optimize bytecode from system partition
if [ -d "$FACTORY_IMGS_R_DATA" ]; then
  rm -rf "${FACTORY_IMGS_R_DATA:?}"/*
else
  mkdir -p "$FACTORY_IMGS_R_DATA"
fi

# Adjust repair method based on API level or skip flag
if [ $SKIP_SYSDEOPT = true ]; then
  REPAIR_SCRIPT_ARG="--method NONE"
elif [ $API_LEVEL -le 23 ]; then
  REPAIR_SCRIPT_ARG="--method OAT2DEX \
                     --oat2dex $SCRIPTS_ROOT/hostTools/Java/oat2dex.jar"
elif [ $API_LEVEL -ge 24 ]; then
  REPAIR_SCRIPT_ARG="--method OATDUMP \
                     --oatdump $SCRIPTS_ROOT/hostTools/$HOST_OS/bin/oatdump \
                     --dexrepair $SCRIPTS_ROOT/hostTools/$HOST_OS/bin/dexrepair"
else
  echo "[-] Non expected /system repair method"
  abort 1
fi

$REPAIR_SCRIPT --input "$FACTORY_IMGS_DATA/system" \
     --output "$FACTORY_IMGS_R_DATA" \
     --blobs-list "$SCRIPTS_ROOT/$DEVICE/proprietary-blobs.txt" \
     $REPAIR_SCRIPT_ARG || {
  echo "[-] System partition de-optimization failed"
  abort 1
}

# Bytecode under vendor partition doesn't require de-opt for (up to now)
# However, move it to repaired data directory to have a single source for
# next script
mv "$FACTORY_IMGS_DATA/vendor" "$FACTORY_IMGS_R_DATA"

# Copy vendor partition image size as saved from $EXTRACT_SCRIPT script
# $VGEN_SCRIPT will fail over to last known working default if image size
# file not found when parsing data
cp "$FACTORY_IMGS_DATA/vendor_partition_size" "$FACTORY_IMGS_R_DATA"

$VGEN_SCRIPT --input "$FACTORY_IMGS_R_DATA" --output "$OUT_BASE" \
  --blobs-list "$SCRIPTS_ROOT/$DEVICE/proprietary-blobs.txt" \
  --so-list "$SCRIPTS_ROOT/$DEVICE/shared-proprietary-blobs-api$API_LEVEL.txt" || {
  echo "[-] Vendor generation failed"
  abort 1
}

if [ "$KEEP_DATA" = false ]; then
  rm -rf "$FACTORY_IMGS_DATA"
  rm -rf "$FACTORY_IMGS_R_DATA"
fi

echo "[*] All actions completed successfully"
echo "[*] Import '$OUT_BASE/vendor' to AOSP root"

abort 0
