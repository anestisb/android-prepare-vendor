#!/usr/bin/env bash
#
#  Extract system & vendor images from factory archive
#  after converting from sparse to raw
#

set -e # fail on unhandled error
set -u # fail on undefined variable
#set -x # debug

readonly SCRIPTS_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
readonly CONSTS_SCRIPT="$SCRIPTS_DIR/constants.sh"
readonly TMP_WORK_DIR=$(mktemp -d /tmp/android_img_extract.XXXXXX) || exit 1
declare -a SYS_TOOLS=("tar" "find" "unzip" "uname" "du" "stat" "tr" "cut")

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
      -d|--device   : Device codename
      -i|--input    : Archive with factory images as downloaded from
                      Google Nexus images website
      -o|--output   : Path to save contents extracted from images
      -t|--simg2img : Path to simg2img binary for converting sparse images
      --debugfs     : Use debugfs instead of default fuse-ext2

    INFO:
      * fuse-ext2 available at 'https://github.com/alperakcan/fuse-ext2'
      * Caller is responsible to unmount mount points when done
      * debugfs support is experimental
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

mount_darwin() {
  local IMGFILE="$1"
  local MOUNTPOINT="$2"
  local MOUNT_LOG="$TMP_WORK_DIR/mount.log"
  local -a OSXFUSE_VER
  local readonly OS_MAJOR_VER

  OS_MAJOR_VER="$(sw_vers -productVersion | cut -d '.' -f2)"
  if [ "$OS_MAJOR_VER" -ge 12 ]; then
    # If Sierra and above, check that latest supported (3.5.4) osxfuse version is installed
    local readonly OSXFUSE_PLIST="/Library/Filesystems/osxfuse.fs/Contents/version.plist"
    IFS='.' read -r -a OSXFUSE_VER <<< "$(grep '<key>CFBundleVersion</key>' -A1 "$OSXFUSE_PLIST" | \
      grep -o '<string>.*</string>' | cut -d '>' -f2 | cut -d '<' -f1)"

    if [[ ("${OSXFUSE_VER[0]}" -lt 3 ) || \
          ("${OSXFUSE_VER[0]}" -eq 3 && "${OSXFUSE_VER[1]}" -lt 5) || \
          ("${OSXFUSE_VER[0]}" -eq 3 && "${OSXFUSE_VER[1]}" -eq 5 && "${OSXFUSE_VER[2]}" -lt 4) ]]; then
      echo "[!] Detected osxfuse version is '$(echo  ${OSXFUSE_VER[@]} | tr ' ' '.')'"
      echo "[-] Update to latest or disable the check if you know that you're doing"
      abort 1
    fi
  fi

  fuse-ext2 -o uid=$EUID,ro "$IMGFILE" "$MOUNTPOINT" &>"$MOUNT_LOG" || {
    echo "[-] '$IMAGE_FILE' mount failed"
    cat "$MOUNT_LOG"
    abort 1
  }
}

mount_linux() {
  local IMGFILE="$1"
  local MOUNTPOINT="$2"
  local MOUNT_LOG="$TMP_WORK_DIR/mount.log"
  fuse-ext2 -o uid=$EUID,ro "$IMGFILE" "$MOUNTPOINT" &>"$MOUNT_LOG" || {
    echo "[-] '$IMAGE_FILE' mount failed"
    cat "$MOUNT_LOG"
    abort 1
  }
}

extract_img_data() {
  local IMAGE_FILE="$1"
  local OUT_DIR="$2"

  if [ ! -d "$OUT_DIR" ]; then
    mkdir -p "$OUT_DIR"
  fi

  if [[ "$HOST_OS" == "Darwin" ]]; then
    debugfs -R "rdump / \"$OUT_DIR\"" "$IMAGE_FILE" &>/dev/null || {
      echo "[-] Failed to extract data from '$IMAGE_FILE'"
      abort 1
    }
  else
    debugfs -R 'ls -p' "$IMAGE_FILE" 2>/dev/null | cut -d '/' -f6 | while read -r entry
    do
      debugfs -R "rdump \"$entry\" \"$OUT_DIR\"" "$IMAGE_FILE" &>/dev/null || {
        echo "[-] Failed to extract data from '$IMAGE_FILE'"
        abort 1
      }
    done
  fi
}

mount_img() {
  local IMAGE_FILE="$1"
  local MOUNT_DIR="$2"

  if [ ! -d "$MOUNT_DIR" ]; then
    mkdir -p "$MOUNT_DIR"
  fi

  if [[ "$HOST_OS" == "Darwin" ]]; then
    mount_darwin "$IMAGE_FILE" "$MOUNT_DIR"
  else
    mount_linux "$IMAGE_FILE" "$MOUNT_DIR"
  fi

  if ! mount | grep -qs "$MOUNT_DIR"; then
    echo "[-] '$IMAGE_FILE' mount point missing indicates fuse mount error"
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
. "$CONSTS_SCRIPT"

DEVICE=""
INPUT_ARCHIVE=""
OUTPUT_DIR=""
SIMG2IMG=""
USE_DEBUGFS=false

# Compatibility
HOST_OS=$(uname)
if [[ "$HOST_OS" != "Linux" && "$HOST_OS" != "Darwin" ]]; then
  echo "[-] '$HOST_OS' OS is not supported"
  abort 1
fi

while [[ $# -gt 0 ]]
do
  arg="$1"
  case $arg in
    -d|--device)
      DEVICE=$2
      shift
      ;;
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
    --debugfs)
      USE_DEBUGFS=true
      ;;
    *)
      echo "[-] Invalid argument '$1'"
      usage
      ;;
  esac
  shift
done

# Additional tools based on chosen image files data extraction method
if [ "$USE_DEBUGFS" = true ]; then
  SYS_TOOLS+=("debugfs")
else
  SYS_TOOLS+=("fuse-ext2")
  # Platform specific commands
  if [[ "$HOST_OS" == "Darwin" ]]; then
    SYS_TOOLS+=("sw_vers")
  fi
fi

# Check that system tools exist
for i in "${SYS_TOOLS[@]}"
do
  if ! command_exists "$i"; then
    echo "[-] '$i' command not found"
    abort 1
  fi
done

# Input args check
check_dir "$OUTPUT_DIR" "Output"
check_file "$INPUT_ARCHIVE" "Input archive"
check_file "$SIMG2IMG" "simg2img"

# Prepare output folders
SYSTEM_DATA_OUT="$OUTPUT_DIR/system"
if [ -d "$SYSTEM_DATA_OUT" ]; then
  rm -rf "${SYSTEM_DATA_OUT:?}"/*
fi

VENDOR_DATA_OUT="$OUTPUT_DIR/vendor"
if [ -d "$VENDOR_DATA_OUT" ]; then
  rm -rf "${VENDOR_DATA_OUT:?}"/*
fi

RADIO_DATA_OUT="$OUTPUT_DIR/radio"
if [ -d "$RADIO_DATA_OUT" ]; then
  rm -rf "${RADIO_DATA_OUT:?}"/*
fi
mkdir -p "$RADIO_DATA_OUT"

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

# Baseband image
hasRadioImg=true
radioImg=$(find "$extractDir" -iname "radio-*.img" | head -n 1)
if [[ "$radioImg" == "" ]]; then
  echo "[!] No baseband firmware present - skipping"
  hasRadioImg=false
fi

# Bootloader image
bootloaderImg=$(find "$extractDir" -iname "bootloader-*.img" | head -n 1)
if [[ "$bootloaderImg" == "" ]]; then
  echo "[-] Failed to locate bootloader image"
  abort 1
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

if [ "$USE_DEBUGFS" = true ]; then
  # Extract raw system and vendor images. Data will be processed later
  extract_img_data "$rawSysImg" "$SYSTEM_DATA_OUT"
  extract_img_data "$rawVImg" "$VENDOR_DATA_OUT"
else
  # Mount raw system and vendor images. Data will be processed later
  mount_img "$rawSysImg" "$SYSTEM_DATA_OUT"
  mount_img "$rawVImg" "$VENDOR_DATA_OUT"
fi

# Copy bootloader & radio images
if [ $hasRadioImg = true ]; then
  mv "$radioImg" "$RADIO_DATA_OUT/" || {
    echo "[-] Failed to copy radio image"
    abort 1
  }
fi
mv "$bootloaderImg" "$RADIO_DATA_OUT/" || {
  echo "[-] Failed to copy bootloader image"
  abort 1
}

# For devices with AB partitions layout, copy additional images required for OTA
if [[ "$DEVICE" == "sailfish" || "$DEVICE" == "marlin" ]]; then
  for img in "${PIXEL_AB_PARTITIONS[@]}"
  do
    if [ ! -f "$extractDir/images/$img.img" ]; then
      echo "[-] Failed to locate '$img.img' in factory image"
      abort 1
    fi
    mv "$extractDir/images/$img.img" "$RADIO_DATA_OUT/"
  done
fi

abort 0
