#!/usr/bin/env bash
#
#  Extract system & vendor images from factory archive
#  after reverting from sparse
#

set -e # fail on unhandled error
set -u # fail on undefined variable
#set -x # debug

readonly TMP_WORK_DIR=$(mktemp -d /tmp/android_img_extract.XXXXXX) || exit 1
declare -a sysTools=("tar" "find" "unzip" "mount" "su" "uname" "rsync" "fdisk")

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
      -i|--input    : archive with factory images as downloaded from
                      Google Nexus images website
      -o|--output   : Path to save contents extracted from images
      -t|--simg2img : simg2img binary path to convert sparse images
_EOF
  abort 1
}

command_exists() {
  type "$1" &> /dev/null
}

extract_archive() {
  local IN_ARCHIVE="$1"
  local OUT_DIR="$2"

  echo "[*] Extracting '$IN_ARCHIVE'"

  local F_EXT="${IN_ARCHIVE#*.}"
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

  size="$(LANG=C fdisk -l "$VENDOR_IMG_RAW" | egrep 'Disk.*bytes' | \
          awk -F ', ' '{print $2}' | cut -d ' ' -f1)"
  if [[ "$size" == "" ]]; then
    echo "[!] Failed to extract vendor partition size from '$VENDOR_IMG_RAW'"
    abort 1
  fi

  # Write to file so that 'generate-vendor.sh' can pick the value
  # for BoardConfigVendor makefile generation
  echo "$size" > "$OUT_FILE"
}

mount_loop_and_copy() {
  local IMAGE_FILE="$1"
  local MOUNT_DIR="$2"
  local COPY_DST_DIR="$3"

  # Mount to loopback
  mount -t ext4 -o ro,loop "$IMAGE_FILE" "$MOUNT_DIR" || {
    echo "[-] '$IMAGE_FILE' mount to loopback failed"
    if [[ "$OS" == "Darwin" ]]; then
      echo "[!] Most probably your MAC doesn't support ext4"
    fi
    abort 1
  }

  # Copy files - it is very IMPORTANT that symbolic links are followed and copied
  echo "[*] Copying files from '$(basename $IMAGE_FILE)' image ..."
  rsync -aruz "$MOUNT_DIR/" "$COPY_DST_DIR" || {
    echo "[-] rsync from '$MOUNT_DIR' to '$COPY_DST_DIR' failed"
    abort 1
  }

  # Unmount
  umount "$MOUNT_DIR" || {
    echo "[-] '$MOUNT_DIR' umount failed"
  }
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

if [[ "$(uname)" == "Darwin" ]]; then
  echo "[-] Darwin platform is not supported"
  abort 1
fi

# Check if script run as root
run_as_root

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

# Mount raw system image to loopback and copy files
sysImgData="$extractDir/factory.system"
mkdir -p "$sysImgData"
mount_loop_and_copy "$rawSysImg" "$sysImgData" "$SYSTEM_DATA_OUT"

# Same process for vendor raw image
vImgData="$extractDir/factory.vendor"
mkdir -p "$vImgData"
mount_loop_and_copy "$rawVImg" "$vImgData" "$VENDOR_DATA_OUT"

abort 0
