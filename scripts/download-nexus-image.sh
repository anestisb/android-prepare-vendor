#!/usr/bin/env bash
#
# Download factory image for the provided device & build id
#

set -e # fail on unhandled error
set -u # fail on undefined variable
#set -x # debug

readonly SCRIPTS_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
readonly CONSTS_SCRIPT="$SCRIPTS_DIR/constants.sh"
readonly COMMON_SCRIPT="$SCRIPTS_DIR/common.sh"
readonly TMP_WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}"/android_img_download.XXXXXX) || exit 1
declare -a SYS_TOOLS=("curl" "wget")

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
      -y|--yes     : Default accept Google ToS
_EOF
  abort 1
}

accept_tos() {
  local userRes userResFmt

  # Message based on 'October 3, 2016' update
  cat << EOF

--{ Google Terms and Conditions [1]
Downloading of the system image and use of the device software is subject to the
Google Terms of Service [2]. By continuing, you agree to the Google Terms of
Service [2] and Privacy Policy [3]. Your downloading of the system image and use
of the device software may also be subject to certain third-party terms of
service, which can be found in Settings > About phone > Legal information, or as
otherwise provided.

[1] https://developers.google.com/android/images#legal
[2] https://www.google.com/intl/en/policies/terms/
[3] https://www.google.com/intl/en/policies/privacy/

EOF

echo -n "[?] I have read and agree with the above terms and conditions - ACKNOWLEDGE [y|n]: "
if [ "$AUTO_TOS_ACCEPT" = true ]; then
  echo "yes"
  userRes="yes"
else
  read userRes
fi

userResFmt=$(echo "$userRes" | tr '[:upper:]' '[:lower:]')
if [[ "$userResFmt" != "yes" && "$userResFmt" != "y" ]]; then
  echo "[!] Cannot continue downloading without agreeing"
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

DEVICE=""
DEV_ALIAS=""
BUILDID=""
OUTPUT_DIR=""
AUTO_TOS_ACCEPT=false

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
    -y|--yes)
      AUTO_TOS_ACCEPT=true
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

# Since ToS is bind with NID cookie, first get one
COOKIE_FILE="$TMP_WORK_DIR/g_cookies.txt"
curl --silent -c "$COOKIE_FILE" -L "$NID_URL" &>/dev/null

# Change cookie scope back to google.com since we might have
# a location based redirect to different domain (e.g. google.gr)
grep -io "google.[[:alpha:]]\+[[:blank:]]" "$COOKIE_FILE" | \
  sed -e "s/[[:space:]]\+//g" | sort -u | \
  while read -r domain
do
  sed -i.bak "s/$domain/google.com/g" "$COOKIE_FILE"
done

# Accept news ToS page
accept_tos

# Then retrieve the index page
url=$(curl -L -b "$COOKIE_FILE" --silent "$GURL" | \
      grep -i "<a href=.*$DEV_ALIAS-$BUILDID-" | cut -d '"' -f2)
if [ "$url" == "" ]; then
  echo "[-] Image URL not found"
  abort 1
fi

echo "[*] Downloading image from '$url'"
outFile=$OUTPUT_DIR/$(basename "$url")
wget --continue -O "$outFile" "$url"

abort 0
