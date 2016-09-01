#!/usr/bin/env bash
#
#  Download Nexus images archive for provided device & build id
#

set -e # fail on unhandled error
set -u # fail on undefined variable
#set -x # debug

readonly GURL="https://developers.google.com/android/nexus/images"
declare -a sysTools=("curl" "wget")

abort() {
  exit "$1"
}

usage() {
cat <<_EOF
  Usage: $(basename "$0") [options]
    OPTIONS:
      -d|--device  : Device AOSP codename (angler, bullhead, etc.)
      -a|--alias   : Device alias at Google Dev website (e.g. volantis vs flounder)
      -b|--buildID : BuildID string (e.g. MMB29P)
      -o|--output  : Path to save images archived
_EOF
  abort 1
}

command_exists() {
  type "$1" &> /dev/null
}

# Check that system tools exist
for i in "${sysTools[@]}"
do
  if ! command_exists "$i"; then
    echo "[-] '$i' command not found"
    abort 1
  fi
done

DEVICE=""
DEV_ALIAS=""
BUILDID=""
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

# If alias not provided assume same as device codename for simplicity.
# If wrong choice, later scripts will fail to find blobs list file.
if [[ "$DEV_ALIAS" == "" ]]; then
  DEV_ALIAS="$DEVICE"
fi

url=$(curl --silent $GURL | grep -i "<a href=.*$DEV_ALIAS-$BUILDID" | \
      cut -d '"' -f2)
if [ "$url" == "" ]; then
  echo "[-] Image URL not found"
  abort 1
fi

echo "[*] Downloading image from '$url'"
outFile=$OUTPUT_DIR/$(basename "$url")
wget -O "$outFile" "$url"

abort 0
