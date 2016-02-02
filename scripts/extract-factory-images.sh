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
    rm -rf $TMP_WORK_DIR
  fi
  exit $1
}

usage() {
cat <<_EOF
  Usage: $(basename $0) [options]
    OPTIONS:
      -i|--input    : tar archive with factory images as downloaded from Nexus website
      -o|--output   : Path to save contents extracted from images
      -t|--simg2img : simg2img binary path to convert sparse images
_EOF
  abort 1
}

command_exists() {
  type "$1" &> /dev/null ;
}

extract_vendor_partition_size() {
  local VENDOR_IMG_RAW="$1"
  local OUT_FILE="$2/vendor_partition_size"
  local size=""

  size="$(fdisk -l "$VENDOR_IMG_RAW" | egrep 'Disk.*bytes' | cut -d ',' -f2 | cut -d ' ' -f2)"
  if [[ "$size" == "" ]]; then
    echo "[!] Failed to extract vendor partition size from '$VENDOR_IMG_RAW'"
    abort 1
  fi

  # Write to file so that 'generate-vendor.sh' can pick the value
  # for BoardConfigVendor makefile generation 
  echo $size > "$OUT_FILE"
}

# Check that system tools exist
for i in "${sysTools[@]}"
do
  if ! command_exists $i; then
    echo "[-] '$i' command not found"
    abort 1
  fi
done

if [[ "$(uname)" == "Darwin" ]]; then
  echo "[-] Darwin platform is not supported"
  abort 1
fi

INPUT_TAR=""
OUTPUT_DIR=""
SIMG2IMG=""

while [[ $# > 1 ]]
do
  arg="$1"
  case $arg in
    -o|--output)
      OUTPUT_DIR=$(echo "$2" | sed 's:/*$::')
      shift
      ;;
    -i|--input)
      INPUT_TAR=$2
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

if [[ "$INPUT_TAR" == "" || ! -f "$INPUT_TAR" ]]; then
  echo "[-] Input tar archive file not found"
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
  rm -rf "$SYSTEM_DATA_OUT"/*
fi

VENDOR_DATA_OUT="$OUTPUT_DIR/vendor"
if [ -d "$VENDOR_DATA_OUT" ]; then
  rm -rf "$VENDOR_DATA_OUT"/*
fi

tarName="$(basename $INPUT_TAR)"
fileExt="${tarName##*.}"
archName="$(basename $tarName .$fileExt)"
extractDir="$TMP_WORK_DIR/$archName"
mkdir -p $extractDir

echo "[*] Extracting '$tarName'"
if ! tar -xf $INPUT_TAR -C "$extractDir"; then
  echo "[-] Extract failed"
  abort 1
fi

if [[ -f "$extractDir/system.img" && -f "$extractDir/vendor.img" ]]; then
  sysImg="$extractDir/system.img"
  vImg="$extractDir/vendor.img"
else
  updateArch=$(find "$extractDir" -iname "image-*.zip" | head -n 1)
  echo "[*] Unzipping '$(basename $updateArch)'"
  if ! unzip -qq "$updateArch" -d $extractDir/images; then
    echo "[-] unzip failed"
    abort 1
  else
    sysImg="$extractDir/images/system.img"
    vImg="$extractDir/images/vendor.img"
  fi
fi

# Convert from sparse to raw
rawSysImg="$extractDir/images/system.img.raw"
rawVImg="$extractDir/images/vendor.img.raw"

if ! $SIMG2IMG $sysImg $rawSysImg; then
  echo "[-] simg2img failed to convert system.img from sparse"
  abort 1
fi
if ! $SIMG2IMG $vImg $rawVImg; then
  echo "[-] simg2img failed to convert vendor.img from sparse"
  abort 1
fi

# Save raw vendor img partition size
extract_vendor_partition_size $rawVImg $OUTPUT_DIR

sysImgData="$extractDir/factory.system"
mkdir -p "$sysImgData"

mountCmd="mount -t ext4 -o ro,loop $rawSysImg $sysImgData"
umountCmd="umount $sysImgData"

# Mount to loopback
if ! su -c "$mountCmd"; then
  echo "[-] '$mountCmd' failed"
  abort 1
fi

# Copy files - it is very IMPORTANT that softlinks are followed
# and copied.
echo "[*] Copying files from system parition ..."
if ! rsync -aruz "$sysImgData/" "$SYSTEM_DATA_OUT"; then
  echo "[-] system rsync failed"
  abort 1
fi

# Unmount
if ! su -c "$umountCmd"; then
  echo "[-] '$umountCmd' failed"
fi

# Same process for vendor image
vImgData="$extractDir/factory.vendor"
mkdir -p "$vImgData"

mountCmd="mount -t ext4 -o ro,loop $rawVImg $vImgData"
umountCmd="umount $vImgData"

# Mount to loopback
if ! su -c "$mountCmd"; then
  echo "[-] '$mountCmd' failed"
  if [[ "$OS" == "Darwin" ]]; then
    echo "[!] Most probably your MAC doesn't support ext4"
  fi
  abort 1
fi

# Copy files
echo "[*] Copying files from vendor partition ..."
if ! rsync -aruz "$vImgData/" "$VENDOR_DATA_OUT"; then
  echo "[-] system rsync failed"
  abort 1
fi

# Unmount
if ! su -c "$umountCmd"; then
  echo "[-] '$umountCmd' failed"
fi

abort 0
