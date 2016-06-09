#!/usr/bin/env bash
#
# For latest Android Nexus devices (N5x, N6p, N9, etc.), Google is no longer
# providing vendor tar archives to be included into AOSP build trees.
# Officially it is claimed that all vendor proprietary blobs have been moved
# to /vendor partition. Unfortunately that is not true since a few vendor
# executables, DSOs and APKs/JARs are present under /system although missing
# from AOSP public tree.
#
# As such custom AOSP builds require to first extract such blobs from /system
# of factory images and manually include them in vendor directory of AOSP tree.
# This process is going anal++ due to the fact that APKs/JARs under /system are
# pre-optimized, requiring to reverse the process (de-optimize them) before
# being capable to copy and include them in AOSP build trees.
#
# This script aims to automate the de-optimization process by creating a copy
# of the input system partition while repairing all optimized bytecode
# packages. Before using this script you'll be required to perform the
# following steps:
#  a) Download matching factory image from Google developers website
#  b) Extract downloaded archives & use simg2img tool to convert the system.
#     img sparse image to raw Linux image
#  c) Mount system raw image to loopback interface and extract all directories
#     while maintaining directory structure
#  d) Execute this script against the root of extracted system directory
#

set -e # fail on unhandled error
set -u # fail on undefined variable
#set -x # debug

readonly TMP_WORK_DIR=$(mktemp -d /tmp/android_img_repair.XXXXXX) || exit 1
declare -a sysTools=("cp" "sed" "java" "zipinfo" "jar" "zip" "wc" "cut")

abort() {
  # If debug keep work dir for bugs investigation
  if [[ "$-" == *x* ]]; then
    echo "[*] Workspace available at '$TMP_WORK_DIR' - delete manually \
          when done"
  else
    rm -rf $TMP_WORK_DIR
  fi
  exit $1
}

usage() {
cat <<_EOF
  Usage: $(basename $0) [options]
    OPTIONS:
      -i|--input   : Root path of extracted factory image system partition
      -o|--output  : Path to save input partition with de-optimized odex files
      -t|--oat2dex : Path to SmaliEx oat2dex.jar
    INFO:
      * Input path expected to be system root as extracted from factory system
        image
      * Download oat2dex.jar from 'https://github.com/testwhat/SmaliEx'
      * When creating vendor makefiles, extra care is needed for APKs signature type
_EOF
  abort 1
}

command_exists() {
  type "$1" &> /dev/null
}

print_expected_imgs_ver() {
  bootloader=$(cat $1 | grep 'ro.build.expect.bootloader' | cut -d '=' -f2)
  baseband=$(cat $1 | grep 'ro.build.expect.baseband' | cut -d '=' -f2)
  echo "[!] Target device expects to have following img versions when using output system img"
  echo " [*] Booatloder:$bootloader"
  echo " [*] Baseband:$baseband"
}

get_build_id() {
  local build_id=$(cat $1 | grep 'ro.build.id=' | cut -d "=" -f2)
  echo $build_id
}

check_java_version() {
  local JAVA_VER=$(java -version 2>&1 | \
                   grep -E "java version|openjdk version" | \
                   awk '{ print $3 }' | tr -d '"' | \
                   awk '{ split($0, data, ".") } END{ print data[2] }')
  if [[ $JAVA_VER -lt 8 ]]; then
    echo "[-] Java version ('$JAVA_VER') is detected, while minimum required version is 8"
    echo "[!] Consider exporting PATH like the following if a system-wide set is not desired"
    echo ' # PATH=/usr/local/java/jdk1.8.0_71/bin:$PATH; ./execute-all.sh <..args..>'
    abort 1
  fi
}

# Check that system tools exist
for i in "${sysTools[@]}"
do
  if ! command_exists $i; then
    echo "[-] '$i' command not found"
    abort 1
  fi
done

# Verify Java version >= 8
check_java_version

INPUT_DIR=""
OUTPUT_DIR=""
OAT2DEX_JAR=""
declare -a ABIS

while [[ $# > 1 ]]
do
  arg="$1"
  case $arg in
    -i|--input)
      INPUT_DIR=$(echo "$2" | sed 's:/*$::')
      shift
      ;;
    -o|--output)
      OUTPUT_DIR=$(echo "$2" | sed 's:/*$::')
      shift
      ;;
    -t|--oat2dex)
      OAT2DEX_JAR=$2
      shift
      ;;
    *)
      echo "[-] Invalid argument '$1'"
      usage
      ;;
  esac
  shift
done

if [[ "$INPUT_DIR" == "" || ! -d "$INPUT_DIR" ]]; then
  echo "[-] Input directory not found"
  usage
fi
if [[ "$OUTPUT_DIR" == "" || ! -d "$OUTPUT_DIR" ]]; then
  echo "[-] Output directory not found"
  usage
fi
if [[ "$OAT2DEX_JAR" == "" || ! -f "$OAT2DEX_JAR" ]]; then
  echo "[-] oat2dex.jar not found"
  usage
fi

# Verify input is an Android system partition
if [ ! -f $INPUT_DIR/build.prop ]; then
  echo "[-] '$INPUT_DIR' is not a valid system image partition"
  abort 1
fi

# Output directory should be empty to avoid merge races with old extracts
BUILD_ID=$(get_build_id $INPUT_DIR/build.prop)
OUTPUT_SYS=$OUTPUT_DIR/system
if [[ -d $OUTPUT_SYS && "$(ls -A $OUTPUT_SYS | grep -v '^\.')" ]]; then
  echo "[!] Output directory should be empty to avoid merge problems with old extracts"
  abort 1
else
  mkdir -p $OUTPUT_SYS
fi

# Verify image contains pre-optimized oat files
if [ ! -d $INPUT_DIR/framework/oat ]; then
  echo "[!] System partition doesn't contain any pre-optimized files - nothing to be done"
  abort 0
fi

# Identify supported ABI(s) - extra work for 64bit ABIs
for type in "arm" "arm64" "x86" "x86_64"
do
  if [ -f $INPUT_DIR/framework/$type/boot.art ]; then
    ABIS=("${ABIS[@]-}" "$type")
  fi
done

for abi in ${ABIS[@]}
do
  echo "[*] Preparing environment for '$abi' ABI"
  workDir="$TMP_WORK_DIR/$abi"
  mkdir $workDir
  cp $INPUT_DIR/framework/$abi/boot.oat $workDir
  if ! java -jar $OAT2DEX_JAR boot $workDir/boot.oat &>/dev/null; then
    echo "[!] Boot classes extraction failed"
    abort 1
  fi
done

echo "[*] Start extracting system partition & de-optimize pre-compiled bytecode ..."
while read -r file
do
  relFile=$(echo $file | sed "s#^$INPUT_DIR##")
  relDir=$(dirname $relFile)
  fileExt="${file##*.}"
  fileName=$(basename $relFile)

  # Skip special files
  if [[ "$fileExt" == "odex" || "$fileExt" == "oat" || "$fileExt" == "art" ]]; then
    continue
  fi

  # Maintain dir structure
  mkdir -p $OUTPUT_SYS/$relDir

  # If not APK/jar file, copy as is
  if [[ "$fileExt" != "apk" && "$fileExt" != "jar" ]]; then
    cp -a $file $OUTPUT_SYS/$relDir/
    continue
  fi

  # For APK/jar files apply de-optimization
  #echo "[*] De-optimizing '$relFile'"
  zipRoot=$(dirname $file)
  pkgName=$(basename $file .$fileExt)
  isMultiDex=false

  # framework resources jar should be the only legitimate jar without matching
  # bytecode
  if [ "$pkgName" == "framework-res" ]; then
    echo "[*] Skipping "$pkgName" since it doesn't pair with bytecode"
    continue
  fi

  # Check if APK/jar bytecode is pre-optimized
  odexFound=0
  if [ -d $zipRoot/oat ]; then
    # Check if optimized code available at app's directory
    odexFound=$(find $zipRoot/oat -type f -iname "$pkgName*.odex" | \
                wc -l | tr -d ' ')
  fi
  if [[ $odexFound -eq 0 && "$relFile" == "/framework/"* ]]; then
    # Boot classes have already been de-optimized. Just check against any ABI
    # to verify that is present (not all jars under framework are part of
    # boot.oat)
    odexFound=$(find "$TMP_WORK_DIR/${ABIS[1]}/dex" -type f \
                -iname "$pkgName*.dex" | wc -l | tr -d ' ')
  fi
  if [ $odexFound -eq 0 ]; then
    if ! zipinfo $file classes.dex &>/dev/null; then
      echo "[-] '$file' not pre-optimized & without 'classes.dex' - skipping"
    else
      echo "[*] '$relFile' not pre-optimized with sanity checks passed - copying without changes"
      cp "$file" $OUTPUT_SYS/$relDir
    fi
  else
    # If pre-compiled, de-optimize to original DEX bytecode
    for abi in ${ABIS[@]}
    do
      curOdex="$zipRoot/oat/$abi/$pkgName.odex"
      if [ -f $curOdex ]; then
        # If odex present de-optimize it
        if ! java -jar $OAT2DEX_JAR -o $TMP_WORK_DIR $curOdex \
             "$TMP_WORK_DIR/$abi/dex" &>/dev/null; then
          echo "[!] '$relFile/oat/$abi/$pkgName.odex' de-optimization failed"
          abort 1
        fi

        # If DEX not created, oat2dex failed to resolve a dependency and skipped file
        if [ ! -f $TMP_WORK_DIR/$pkgName.dex ]; then
          echo "[-] '$relFile' de-optimization failed consider manual inspection - skipping archive"
          continue 2
        fi
      elif [ -f $TMP_WORK_DIR/$abi/dex/$pkgName.dex ]; then
        # boot classes bytecode is available from boot.oat extracts - copy
        # them with wildcard so following multi-dex detection logic can pick
        # them up
        cp $TMP_WORK_DIR/$abi/dex/$pkgName*.dex $TMP_WORK_DIR
      fi
    done

    # If bytecode compiled for more than one ABIs - only the last is kept
    # (shouldn't make any difference)
    if [ ! -f $TMP_WORK_DIR/$pkgName.dex ]; then
      echo "[-] Something is wrong in expected dir structure - inspect manually"
      abort 1
    fi

    # Copy APK/jar to workspace for repair
    cp $file $TMP_WORK_DIR

    # Add dex files back to zip archives (jar or APK) considering possible
    # multi-dex case zipalign is not necessary since AOSP build rules will
    # align them if not already
    if [ -f "$TMP_WORK_DIR/$pkgName-classes2.dex" ]; then
      echo "[*] '$relFile' is multi-dex - adjusting recursive archive adds"
      counter=2
      curMultiDex="$TMP_WORK_DIR/$pkgName-classes$counter.dex"
      while [ -f $curMultiDex ]
      do
        mv $curMultiDex "$TMP_WORK_DIR/classes$counter.dex"
        if ! jar -uf $TMP_WORK_DIR/$fileName -C $TMP_WORK_DIR \
             "classes$counter.dex" &>/dev/null; then
          echo "[-] '$fileName' 'classes$counter.dex' append failed"
          abort 1
        fi
        rm "$TMP_WORK_DIR/classes$counter.dex"

        counter=$(( $counter + 1))
        curMultiDex="$TMP_WORK_DIR/$pkgName-classes$counter.dex"
      done
    fi

    mv $TMP_WORK_DIR/$pkgName.dex $TMP_WORK_DIR/classes.dex
    if ! jar -uf $TMP_WORK_DIR/$fileName -C $TMP_WORK_DIR \
         classes.dex &>/dev/null; then
      echo "[-] '$fileName' classes.dex append failed"
      abort 1
    fi
    rm $TMP_WORK_DIR/classes.dex

    mkdir -p $OUTPUT_SYS/$relDir
    cp $TMP_WORK_DIR/$fileName $OUTPUT_SYS/$relDir
  fi
done <<< "$(find $INPUT_DIR -not -type d)"

echo "[*] System partition successfully extracted & de-optimized at '$OUTPUT_DIR'"
print_expected_imgs_ver $INPUT_DIR/build.prop

abort 0
