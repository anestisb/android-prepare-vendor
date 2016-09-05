#!/usr/bin/env bash
#
# Script to parse list of proprietary blobs from file and generate
# vendor directory structure and makefiles
#

set -e # fail on unhandled error
set -u # fail on undefined variable
#set -x # debug

readonly TMP_WORK_DIR=$(mktemp -d /tmp/android_vendor_setup.XXXXXX) || exit 1
declare -a sysTools=("cp" "sed" "java" "zipinfo" "jarsigner" "awk")
declare -a dirsWithBC=("app" "framework" "priv-app")

# Last known good defaults in case fdisk automation failed
readonly BULLHEAD_VENDOR_IMG_SZ="260034560"
readonly ANGLER_VENDOR_IMG_SZ="209702912"
readonly FLOUNDER_VENDOR_IMG_SZ="268419072"

# Standalone symlinks. Need to also take care standalone firmware bin
# symlinks between /data/misc & /system/etc/firmware.
declare -a S_SLINKS_SRC
declare -a S_SLINKS_DST
hasStandAloneSymLinks=false

abort() {
  # If debug keep work directory for bugs investigation
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
      -i|--input      : Root path of extracted /system & /vendor partitions
      -o|--output     : Path to save vendor blobs & makefiles in AOSP
                        compatible structure
      -b|--blobs-list : Text file with list of propriatery blobs to copy
    INFO:
      * Output should be moved/synced with AOSP root, unless -o is AOSP root
_EOF
  abort 1
}

command_exists() {
  type "$1" &> /dev/null
}

verify_input() {
  if [[ ! -d "$1/vendor" || ! -d "$1/system" || ! -f "$1/system/build.prop" ]]; then
    echo "[-] Invalid input directory structure"
    usage
  fi
}

get_device_codename() {
  local device=$(grep 'ro.product.device=' "$1" | cut -d '=' -f2 | \
                 tr '[:upper:]' '[:lower:]')
  if [[ "$device" == "" ]]; then
    echo "[-] Device string not found"
    abort 1
  fi
  echo "$device"
}

get_vendor() {
  local vendor=$(grep 'ro.product.manufacturer=' "$1" | \
                 cut -d '=' -f2 | tr '[:upper:]' '[:lower:]')
  if [[ "$vendor" == "" ]]; then
    echo "[-] Device codename string not found"
    abort 1
  fi
  echo "$vendor"
}

has_vendor_size() {
  local SEARCH_FILE="$1/vendor_partition_size"
  if [ -f "$SEARCH_FILE" ]; then
    cat "$SEARCH_FILE"
  else
    echo ""
  fi
}

read_invalid_symlink() {
  local INBASE="$1"
  local RELTARGET="$2"
  # shellcheck disable=SC2012
  ls -l "$INBASE/$RELTARGET" | awk '{ print $11 }'
}

array_contains() {
  local element
  for element in "${@:2}"; do [[ "$element" == "$1" ]] && return 0; done
  return 1
}

extract_blobs() {
  local BLOBS_LIST="$1"
  local INDIR="$2"
  local OUTDIR_PROP="$3/proprietary"
  local OUTDIR_VENDOR="$3/vendor"

  local src=""
  local dst=""
  local dstDir=""
  local outBase=""

  while read -r file
  do
    # Input format is following AOSP spec allowing optional save into different path
    src=$(echo "$file" | cut -d ":" -f1)
    dst=$(echo "$file" | cut -d ":" -f2)
    if [[ "$dst" == "" ]]; then
      dst=$src
    fi

    # Special handling if source file is a symbolic link. Additional rules
    # will be handled later when unified Android.mk is created
    if [[ -L "$INDIR/$src" ]]; then
      if [[ "$dst" != "$src" ]]; then
        echo "[-] Symlink paths cannot have their destination altered"
        abort 1
      fi
      symLinkSrc="$(read_invalid_symlink "$INDIR" "$src" | sed 's#^/##')"
      S_SLINKS_SRC=("${S_SLINKS_SRC[@]-}" "$symLinkSrc")
      S_SLINKS_DST=("${S_SLINKS_DST[@]-}" "$src")
      hasStandAloneSymLinks=true
      continue
    fi

    # Files under /system go to $OUTDIR_PROP, while files from /vendor
    # to $OUTDIR_VENDOR
    if [[ $src == system/* ]]; then
      outBase=$OUTDIR_PROP
      dst=$(echo "$dst" | sed 's#^system/##')
    elif [[ $src == vendor/* ]]; then
      outBase=$OUTDIR_VENDOR
      dst=$(echo "$dst" | sed 's#^vendor/##')
    else
      echo "[-] Invalid path detected at '$BLOBS_LIST' ($src)"
      abort 1
    fi

    # Always maintain relative directory structure
    dstDir=$(dirname "$dst")
    if [ ! -d "$outBase/$dstDir" ]; then
      mkdir -p "$outBase/$dstDir"
    fi
    cp "$INDIR/$src" "$outBase/$dst"

    # Some vendor xml's don't satisfy xmllint running from AOSP.
    # Better apply fix-up here
    if [[ "${file##*.}" == "xml" ]]; then
      local openTag=$(grep '^<?xml version' "$outBase/$dst")
      grep -v '^<?xml version' "$outBase/$dst" > "$TMP_WORK_DIR/xml_fixup.tmp"
      echo "$openTag" > "$outBase/$dst"
      cat "$TMP_WORK_DIR/xml_fixup.tmp" >> "$outBase/$dst"
      rm "$TMP_WORK_DIR/xml_fixup.tmp"
    fi
  done <<< "$(grep -Ev '(^#|^$)' "$BLOBS_LIST")"
}

gen_vendor_blobs_mk() {
  local BLOBS_LIST="$1"
  local OUTDIR="$2"
  local VENDOR="$3"

  local OUTMK="$OUTDIR/$DEVICE-vendor-blobs.mk"
  local RELDIR_PROP="vendor/$VENDOR/$DEVICE/proprietary"
  local RELDIR_VENDOR="vendor/$VENDOR/$DEVICE/vendor"

  local src=""
  local srcRelDir=""
  local dst=""
  local dstRelDir=""
  local fileExt=""

  {
    echo "# Auto-generated file, do not edit"
    echo ""
    echo 'PRODUCT_COPY_FILES += \'
  } > "$OUTMK"

  while read -r file
  do
    # Skip APKs & JARs
    fileExt="${file##*.}"
    if [[ "$fileExt" == "apk" || "$fileExt" == "jar" ]]; then
      continue
    fi

    # Skip standalone symbolic links if available
    if [ $hasStandAloneSymLinks = true ]; then
      if array_contains "$file" "${S_SLINKS_DST[@]}"; then
        continue
      fi
    fi

    # Split the file from the destination (format is "file[:destination]")
    src=$(echo "$file" | cut -d ":" -f1)
    dst=$(echo "$file" | cut -d ":" -f2)
    if [[ "$dst" == "" ]]; then
      dst=$src
    fi

    # Adjust prefixes for relative dirs of src & dst files
    if [[ $src == system/* ]]; then
      srcRelDir=$RELDIR_PROP
      src=$(echo "$src" | sed 's#^system/##')
    elif [[ $src == vendor/* ]]; then
      srcRelDir=$RELDIR_VENDOR
      src=$(echo "$src" | sed 's#^vendor/##')
    else
      echo "[-] Invalid src path detected at '$BLOBS_LIST'"
      abort 1
    fi
    if [[ $dst == system/* ]]; then
      dstRelDir='$(TARGET_COPY_OUT_SYSTEM)'
      dst=$(echo "$dst" | sed 's#^system/##')
    elif [[ $dst == vendor/* ]]; then
      dstRelDir='$(TARGET_COPY_OUT_VENDOR)'
      dst=$(echo "$dst" | sed 's#^vendor/##')
    else
      echo "[-] Invalid dst path detected at '$BLOBS_LIST'"
      abort 1
    fi

    echo "    $srcRelDir/$src:$dstRelDir/$dst:$VENDOR \\" >> "$OUTMK"
  done <<< "$(grep -Ev '(^#|^$)' "$BLOBS_LIST")"

  # Trim last backslash
  sed '$s/ \\//' "$OUTMK" > "$OUTMK.tmp"
  mv "$OUTMK.tmp" "$OUTMK"
}

gen_dev_vendor_mk() {
  local OUTDIR="$1"
  local OUTMK="$OUTDIR/device-vendor.mk"

  echo "# Auto-generated file, do not edit" > "$OUTMK"
  echo "" >> "$OUTMK"
  echo "\$(call inherit-product, vendor/$VENDOR/$DEVICE/$DEVICE-vendor-blobs.mk)" >> "$OUTMK"
}

gen_board_cfg_mk() {
  local INDIR="$1"
  local OUTDIR="$2"
  local DEVICE="$3"
  local OUTMK="$OUTDIR/BoardConfigVendor.mk"

  # First lets check if vendor partition size has been extracted from
  # previous data extraction script
  local v_img_sz="$(has_vendor_size "$INDIR")"

  # If not found, fail over to last known value from hardcoded entries
  if [[ "$v_img_sz" == "" ]]; then
    if [[ "$DEVICE" == "bullhead" ]]; then
      v_img_sz=$BULLHEAD_VENDOR_IMG_SZ
    elif [[ "$DEVICE" == "angler" ]]; then
      v_img_sz=$ANGLER_VENDOR_IMG_SZ
    elif [[ "$DEVICE" == "flounder" ]]; then
      v_img_sz=$FLOUNDER_VENDOR_IMG_SZ
    else
      echo "[-] Unknown vendor image size for '$DEVICE' device"
      abort 1
    fi
  fi

  {
    echo "# Auto-generated file, do not edit"
    echo ""
    echo 'BOARD_VENDORIMAGE_FILE_SYSTEM_TYPE := ext4'
    echo "BOARD_VENDORIMAGE_PARTITION_SIZE := $v_img_sz"
  } > "$OUTMK"
}

zip_needs_resign() {
  local INFILE="$1"
  local output=$(jarsigner -verify "$INFILE" 2>&1 || abort 1)
  if [[ "$output" =~ .*"contains unsigned entries".* ]]; then
    return 0
  else
    return 1
  fi
}

gen_apk_dso_symlink() {
  local DSO_NAME=$1
  local DSO_MNAME=$2
  local DSO_ROOT=$3
  local APK_DIR=$4
  local DSO_ABI=$5
  local MANF=$6

  echo "\ninclude \$(CLEAR_VARS)"
  echo "LOCAL_MODULE := $DSO_MNAME"
  echo "LOCAL_MODULE_CLASS := FAKE"
  echo "LOCAL_MODULE_TAGS := optional"
  echo "LOCAL_MODULE_OWNER := $MANF"
  echo 'include $(BUILD_SYSTEM)/base_rules.mk'
  echo "\$(LOCAL_BUILT_MODULE): TARGET := $DSO_ROOT/$DSO_NAME"
  echo "\$(LOCAL_BUILT_MODULE): SYMLINK := $APK_DIR/lib/$DSO_ABI/$DSO_NAME"
  echo "\$(LOCAL_BUILT_MODULE): \$(LOCAL_PATH)/Android.mk"
  echo "\$(LOCAL_BUILT_MODULE):"
  echo "\t\$(hide) mkdir -p \$(dir \$@)"
  echo "\t\$(hide) mkdir -p \$(dir \$(SYMLINK))"
  echo "\t\$(hide) rm -rf \$@"
  echo "\t\$(hide) rm -rf \$(SYMLINK)"
  echo "\t\$(hide) ln -sf \$(TARGET) \$(SYMLINK)"
  echo "\t\$(hide) touch \$@"
}

gen_standalone_symlinks() {
  local INDIR="$1"
  local OUTBASE="$2"
  local VENDOR="$3"
  local OUTMK="$4"
  local VENDORMK="$OUTBASE/device-vendor.mk"

  local -a PKGS_SSLINKS
  local pkgName=""
  local cnt=1

  if [ ${#S_SLINKS_SRC[@]} -ne ${#S_SLINKS_DST[@]} ]; then
    echo "[-] Standalone symlinks arrays corruption - inspect paths manually"
    abort 1
  fi

  for link in ${S_SLINKS_SRC[@]}
  do
    pkgName=$(basename $link)
    PKGS_SSLINKS=("${PKGS_SSLINKS[@]-}" "$pkgName")

    {
      echo -e "\ninclude \$(CLEAR_VARS)"
      echo -e "LOCAL_MODULE := $pkgName"
      echo -e "LOCAL_MODULE_CLASS := FAKE"
      echo -e "LOCAL_MODULE_TAGS := optional"
      echo -e "LOCAL_MODULE_OWNER := $VENDOR"
      echo -e 'include $(BUILD_SYSTEM)/base_rules.mk'
      echo -e "\$(LOCAL_BUILT_MODULE): TARGET := /${S_SLINKS_SRC[$cnt]}"
      echo -e "\$(LOCAL_BUILT_MODULE): SYMLINK := \$(PRODUCT_OUT)/${S_SLINKS_DST[$cnt]}"
      echo -e "\$(LOCAL_BUILT_MODULE): \$(LOCAL_PATH)/Android.mk"
      echo -e "\$(LOCAL_BUILT_MODULE):"
      echo -e "\t\$(hide) mkdir -p \$(dir \$@)"
      echo -e "\t\$(hide) mkdir -p \$(dir \$(SYMLINK))"
      echo -e "\t\$(hide) rm -rf \$@"
      echo -e "\t\$(hide) rm -rf \$(SYMLINK)"
      echo -e "\t\$(hide) ln -sf \$(TARGET) \$(SYMLINK)"
      echo -e "\t\$(hide) touch \$@"
    } >> "$OUTMK"

    let cnt=cnt+1
  done

  {
    echo ""
    echo "# Standalone symbolic links"
    echo 'PRODUCT_PACKAGES += \'
    for module in ${PKGS_SSLINKS[@]}
    do
      echo "    $module \\"
    done
  } >> "$VENDORMK"
  sed '$s/ \\//' "$VENDORMK" > "$VENDORMK.tmp"
  mv "$VENDORMK.tmp" "$VENDORMK"
}

gen_mk_for_bytecode() {
  local INDIR="$1"
  local RELROOT="$2"
  local RELSUBROOT="$3"
  local OUTBASE="$4"
  local VENDOR="$5"
  local OUTMK="$6"
  local VENDORMK="$OUTBASE/device-vendor.mk"
  local -a PKGS
  local -a PKGS_SLINKS

  local origin=""
  local zipName=""
  local fileExt=""
  local pkgName=""
  local src=""
  local class=""
  local suffix=""
  local priv=""
  local cert=""
  local opt=""
  local stem=""
  local lcMPath=""
  local appDir=""
  local dsoRootBase=""
  local dsoRoot=""
  local dsoName=""
  local dsoMName=""
  local arch=""
  local apk_lib_slinks=""
  local hasApkSymLinks=false

  # Set module path (output)
  if [[ "$RELROOT" == "vendor" ]]; then
    origin="$INDIR/vendor/$RELSUBROOT"
    lcMPath="\$(PRODUCT_OUT)/\$(TARGET_COPY_OUT_VENDOR)/$RELSUBROOT"
    dsoRootBase="/vendor"
  elif [[ "$RELROOT" == "proprietary" ]]; then
    origin="$INDIR/system/$RELSUBROOT"
    lcMPath="\$(PRODUCT_OUT)/\$(TARGET_COPY_OUT_SYSTEM)/$RELSUBROOT"
    dsoRootBase="/system"
  else
    echo "[-] Invalid '$RELDIR' relative directory"
    abort 1
  fi

  while read -r file
  do
    zipName=$(basename "$file")
    fileExt="${zipName##*.}"
    pkgName=$(basename "$file" ".$fileExt")
    appDir="$origin/$pkgName"
    apk_lib_slinks=""

    # Adjust APK/JAR specifics
    if [[ "$fileExt" == "jar" ]]; then
      src="$RELROOT/$RELSUBROOT/$zipName"
      class='JAVA_LIBRARIES'
      suffix='$(COMMON_JAVA_PACKAGE_SUFFIX)'
    elif [[ "$fileExt" == "apk" ]]; then
      src="$RELROOT/$RELSUBROOT/$pkgName/$zipName"
      class='APPS'
      suffix='$(COMMON_ANDROID_PACKAGE_SUFFIX)'
      stem="package.apk"
    fi

    # Annotate extra privilleges when required
    if [[ "$RELSUBROOT" == "priv-app" ]]; then
      priv='LOCAL_PRIVILEGED_MODULE := true'
    fi

    # APKs under /vendor should not be optimized and always use the
    # PRESIGNED cert
    if [[ "$fileExt" == "apk" && "$RELROOT" == "vendor" ]]; then
      cert="PRESIGNED"
      opt='LOCAL_DEX_PREOPT := false'
    elif [[ "$fileExt" == "apk" ]]; then
      # All other APKs have been repaired (de-optimized from oat) & thus
      # need resign
      cert="platform"
    else
      # Framework JAR's don't contain signatures, so annotate to skip signing
      cert="PRESIGNED"
    fi

    # Some prebuilt APKs have also prebuilt JNI libs that are stored under
    # system-wide lib directories, with app directory containing a symlink to.
    # Resolve such cases to adjust includes so that we don't copy across the
    # same file twice.
    if [ -d "$appDir/lib" ]; then
      hasApkSymLinks=true
      while read -r lib
      do
        # We don't expect a depth bigger than 1 here
        dsoName=$(basename "$lib")
        arch=$(dirname "$lib" | sed "s#$appDir/lib/##" | cut -d '/' -f1)
        if [[ $arch == *64 ]]; then
          dsoMName="$(basename "$lib" .so)_64.so"
          dsoRoot="$dsoRootBase/lib64"
        else
          dsoMName="$(basename "$lib" .so)_32.so"
          dsoRoot="$dsoRootBase/lib"
        fi

        # Generate symlink fake rule & cache module_names to append later to
        # vendor mk
        PKGS_SLINKS=("${PKGS_SLINKS[@]-}" "$dsoMName")
        apk_lib_slinks="$apk_lib_slinks\n$(gen_apk_dso_symlink "$dsoName" \
                        "$dsoMName" "$dsoRoot" "$lcMPath/$pkgName" "$arch" "$VENDOR")"
      done <<< "$(find -L "$appDir/lib" -type l -iname '*.so')"
    fi

    {
      echo ""
      echo 'include $(CLEAR_VARS)'
      echo "LOCAL_MODULE := $pkgName"
      echo 'LOCAL_MODULE_TAGS := optional'
      if [[ "$stem" != "" ]]; then
        echo "LOCAL_BUILT_MODULE_STEM := $stem"
      fi
      echo "LOCAL_MODULE_OWNER := $VENDOR"
      echo "LOCAL_MODULE_PATH := $lcMPath"
      echo "LOCAL_SRC_FILES := $src"
      if [[ "$apk_lib_slinks" != "" ]]; then
        # Force symlink modules dependencies to avoid omissions from wrong cleans
        # for pre-ninja build envs
        echo "LOCAL_REQUIRED_MODULES := ${PKGS_SLINKS[@]-}"
      fi
      echo "LOCAL_CERTIFICATE := $cert"
      echo "LOCAL_MODULE_CLASS := $class"
      if [[ "$priv" != "" ]]; then
        echo "$priv"
      fi
      echo "LOCAL_MODULE_SUFFIX := $suffix"
      if [[ "$opt" != "" ]]; then
        echo "$opt"
      fi
      echo 'include $(BUILD_PREBUILT)'

      # Append rules for APK lib symlinks if present
      if [[ "$apk_lib_slinks" != "" ]]; then
        echo -e "$apk_lib_slinks"
      fi
    } >> "$OUTMK"

    # Also add pkgName to runtime array to append later the vendor mk
    PKGS=("${PKGS[@]-}" "$pkgName")
  done <<< "$(find "$OUTBASE/$RELROOT/$RELSUBROOT" -maxdepth 2 -type f -iname '*.apk' -o -iname '*.jar')"

  # Update vendor mk
  {
    echo ""
    echo "# Prebuilt APKs/JARs from '$RELROOT/$RELSUBROOT'"
    echo 'PRODUCT_PACKAGES += \'
    for pkg in ${PKGS[@]}
    do
      echo "    $pkg \\"
    done
  }  >> "$VENDORMK"
  sed '$s/ \\//' "$VENDORMK" > "$VENDORMK.tmp"
  mv "$VENDORMK.tmp" "$VENDORMK"

  # Update vendor mk again with symlink modules if present
  if [ $hasApkSymLinks = true ]; then
    {
      echo ""
      echo "# Prebuilt APKs libs symlinks from '$RELROOT/$RELSUBROOT'"
      echo 'PRODUCT_PACKAGES += \'
      for module in ${PKGS_SLINKS[@]}
      do
        echo "    $module \\"
      done
    } >> "$VENDORMK"
    sed '$s/ \\//' "$VENDORMK" > "$VENDORMK.tmp"
    mv "$VENDORMK.tmp" "$VENDORMK"
  fi
}

trap "abort 1" SIGINT SIGTERM

INPUT_DIR=""
OUTPUT_DIR=""
BLOBS_LIST=""

DEVICE=""
VENDOR=""

# Check that system tools exist
for i in "${sysTools[@]}"
do
  if ! command_exists "$i"; then
    echo "[-] '$i' command not found"
    abort 1
  fi
done

while [[ $# -gt 1 ]]
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
    -b|--blobs-list)
      BLOBS_LIST="$2"
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
if [[ "$BLOBS_LIST" == "" || ! -f "$BLOBS_LIST" ]]; then
  echo "[-] Vendor proprietary blobs list file not found"
  usage
fi

# Verify input directory structure
verify_input "$INPUT_DIR"

# Get device details
DEVICE=$(get_device_codename "$INPUT_DIR/system/build.prop")
VENDOR=$(get_vendor "$INPUT_DIR/system/build.prop")

echo "[*] Generating blobs for vendor/$VENDOR/$DEVICE"

# Clean-up output
OUTPUT_VENDOR="$OUTPUT_DIR/vendor/$VENDOR/$DEVICE"
PROP_EXTRACT_BASE="$OUTPUT_VENDOR/proprietary"
if [ -d "$OUTPUT_VENDOR" ]; then
  rm -rf "$OUTPUT_VENDOR"/*
fi
mkdir -p "$PROP_EXTRACT_BASE"

# Copy device specific files from input
echo "[*] Copying files to '$OUTPUT_VENDOR'"
extract_blobs "$BLOBS_LIST" "$INPUT_DIR" "$OUTPUT_VENDOR"

# Generate $DEVICE-vendor-blobs.mk makefile (plain files that don't require a target module)
echo "[*] Generating '$DEVICE-vendor-blobs.mk' makefile"
gen_vendor_blobs_mk "$BLOBS_LIST" "$OUTPUT_VENDOR" "$VENDOR"

# Generate device-vendor.mk makefile (will be updated later)
echo "[*] Generating 'device-vendor.mk'"
gen_dev_vendor_mk "$OUTPUT_VENDOR"

# Generate BoardConfigVendor.mk (vendor partition type)
echo "[*] Generating 'BoardConfigVendor.mk'"
gen_board_cfg_mk "$INPUT_DIR" "$OUTPUT_VENDOR" "$DEVICE"

# Iterate over directories with bytecode and generate a unified Android.mk file
echo "[*] Generating 'Android.mk'"

OUTMK="$OUTPUT_VENDOR/Android.mk"
{
  echo "# Auto-generated file, do not edit"
  echo ""
  echo 'LOCAL_PATH := $(call my-dir)'
  echo "ifeq (\$(TARGET_DEVICE),$DEVICE)"
} > "$OUTMK"

for root in "vendor" "proprietary"
do
  for path in "${dirsWithBC[@]}"
  do
    if [ -d "$OUTPUT_VENDOR/$root/$path" ]; then
      echo "[*] Gathering data from '$OUTPUT_VENDOR/$root/$path' APK/JAR pre-builts"
      gen_mk_for_bytecode "$INPUT_DIR" "$root" "$path" "$OUTPUT_VENDOR" "$VENDOR" "$OUTMK"
    fi
  done
done

if [ $hasStandAloneSymLinks = true ]; then
  echo "[*] Processing standalone symlinks"
  gen_standalone_symlinks "$INPUT_DIR" "$OUTPUT_VENDOR" "$VENDOR" "$OUTMK"
fi

echo "" >> "$OUTMK"
echo "endif" >> "$OUTMK"

abort 0
