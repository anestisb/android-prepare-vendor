#!/usr/bin/env bash
#
#  Extract system & vendor images from factory archive
#  after converting from sparse to raw
#

set -e # fail on unhandled error
set -u # fail on undefined variable
#set -x # debug

readonly TMP_WORK_DIR=$(mktemp -d /tmp/android_img_extract.XXXXXX) || exit 1
declare -a sysTools=("tar" "find" "unzip" "uname" "fuse-ext2" "du" "stat" "tr" "cut")

abort() {
  # If debug keep work dir for bugs investigation
  if [[ "$-" == *x* ]]; then
    echo "[*] Workspace available at '$TMP_WORK_DIR' - delete manually when done"
  else
    rm -rf "$TMP_WORK_DIR"
  fi
  exit "$1"
}

usage() {
cat <<_EOF
  Usage: $(basename "$0") [options]
    OPTIONS:
      -i|--input    : Archive with factory images as downloaded from
                      Google Nexus images website
      -o|--output   : Path to save contents extracted from images
      -t|--simg2img : Path to simg2img binary for converting sparse images

    INFO:
      * fuse-ext2 available at 'https://github.com/alperakcan/fuse-ext2'
_EOF
  abort 1
}

command_exists() {
  type "$1" &> /dev/null
}

extract_archive() {
  local IN_ARCHIVE="$1"
  local OUT_DIR="$2"
  local archiveFile

  echo "[*] Extracting '$IN_ARCHIVE'"

  archiveFile="$(basename "$IN_ARCHIVE")"
  local F_EXT="${archiveFile#*.}"
  if [[ "$F_EXT" == "tar" || "$F_EXT" == "tar.gz" || "$F_EXT" == "tgz" ]]; then
    tar -xf "$IN_ARCHIVE" -C "$OUT_DIR" || { echo "[-] tar extract failed"; abort 1; }
  elif [[ "$F_EXT" == "zip" ]]; then
    unzip -qq "$IN_ARCHIVE" -d "$OUT_DIR" || { echo "[-] zip extract failed"; abort 1; }
  else
    echo "[-] Unknown archive format '$F_EXT'"
    abort 1
  fi
}

extract_vendor_partition_size() {
  local VENDOR_IMG_RAW="$1"
  local OUT_FILE="$2/vendor_partition_size"
  local size=""

  if [[ "$(uname)" == "Darwin" ]]; then
    size="$(stat -f %z "$VENDOR_IMG_RAW")"
  else
    size="$(du -b "$VENDOR_IMG_RAW" | tr '\t' ' ' | cut -d' ' -f1)"
  fi

  if [[ "$size" == "" ]]; then
    echo "[!] Failed to extract vendor partition size from '$VENDOR_IMG_RAW'"
    abort 1
  fi

  # Write to file so that 'generate-vendor.sh' can pick the value
  # for BoardConfigVendor makefile generation
  echo "$size" > "$OUT_FILE"
}

extract_from_img() {
  local IMAGE_FILE="$1"
  local MOUNT_DIR="$2"
  local COPY_DST_DIR="$3"

  # Mount to loopback
  fuse-ext2 -o uid=$EUID "$IMAGE_FILE" "$MOUNT_DIR" &>/dev/null || {
    echo "[-] '$IMAGE_FILE' mount failed"
    abort 1
  }

  # Copy files - it is very IMPORTANT to keep symbolic links untouched
  echo "[*] Copying files from '$(basename "$IMAGE_FILE")' image"
  rsync -aruz "$MOUNT_DIR/" "$COPY_DST_DIR" || {
    echo "[-] rsync from '$MOUNT_DIR' to '$COPY_DST_DIR' failed"
    abort 1
  }

  # Unmount
  umount "$MOUNT_DIR" || {
    echo "[-] '$MOUNT_DIR' unmount failed"
  }
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

INPUT_ARCHIVE=""
OUTPUT_DIR=""
SIMG2IMG=""

while [[ $# -gt 1 ]]
do
  arg="$1"
  case $arg in
    -o|--output)
      OUTPUT_DIR=$(echo "$2" | sed 's:/*$::')
      shift
      ;;
    -i|--input)
      INPUT_ARCHIVE=$2
      shift
      ;;
    -t|--simg2img)
      SIMG2IMG=$2
      shift
      ;;
    *)
      echo "[-] Invalid argument '$1'"
      usage
      ;;
  esac
  shift
done

if [[ "$INPUT_ARCHIVE" == "" || ! -f "$INPUT_ARCHIVE" ]]; then
  echo "[-] Input archive file not found"
  usage
fi
if [[ "$OUTPUT_DIR" == "" || ! -d "$OUTPUT_DIR" ]]; then
  echo "[-] Output directory not found"
  usage
fi
if [[ "$SIMG2IMG" == "" || ! -f "$SIMG2IMG" ]]; then
  echo "[-] simg2img file not found"
  usage
fi

# Prepare output folders
SYSTEM_DATA_OUT="$OUTPUT_DIR/system"
if [ -d "$SYSTEM_DATA_OUT" ]; then
  rm -rf "${SYSTEM_DATA_OUT:?}"/*
fi

VENDOR_DATA_OUT="$OUTPUT_DIR/vendor"
if [ -d "$VENDOR_DATA_OUT" ]; then
  rm -rf "${VENDOR_DATA_OUT:?}"/*
fi

archiveName="$(basename "$INPUT_ARCHIVE")"
fileExt="${archiveName##*.}"
archName="$(basename "$archiveName" ".$fileExt")"
extractDir="$TMP_WORK_DIR/$archName"
mkdir -p "$extractDir"

# Extract archive
extract_archive "$INPUT_ARCHIVE" "$extractDir"

if [[ -f "$extractDir/system.img" && -f "$extractDir/vendor.img" ]]; then
  sysImg="$extractDir/system.img"
  vImg="$extractDir/vendor.img"
else
  updateArch=$(find "$extractDir" -iname "image-*.zip" | head -n 1)
  echo "[*] Unzipping '$(basename "$updateArch")'"
  unzip -qq "$updateArch" -d "$extractDir/images" || {
    echo "[-] unzip failed"
    abort 1
  }
  sysImg="$extractDir/images/system.img"
  vImg="$extractDir/images/vendor.img"
fi

# Convert from sparse to raw
rawSysImg="$extractDir/images/system.img.raw"
rawVImg="$extractDir/images/vendor.img.raw"

$SIMG2IMG "$sysImg" "$rawSysImg" || {
  echo "[-] simg2img failed to convert system.img from sparse"
  abort 1
}
$SIMG2IMG "$vImg" "$rawVImg" || {
  echo "[-] simg2img failed to convert vendor.img from sparse"
  abort 1
}

# Save raw vendor img partition size
extract_vendor_partition_size "$rawVImg" "$OUTPUT_DIR"

# Mount raw system image and copy files
sysImgData="$extractDir/factory.system"
mkdir -p "$sysImgData"
extract_from_img "$rawSysImg" "$sysImgData" "$SYSTEM_DATA_OUT"

# Same process for vendor raw image
vImgData="$extractDir/factory.vendor"
mkdir -p "$vImgData"
extract_from_img "$rawVImg" "$vImgData" "$VENDOR_DATA_OUT"

abort 0
