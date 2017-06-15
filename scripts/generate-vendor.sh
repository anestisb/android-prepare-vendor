#!/usr/bin/env bash
#
# Script to parse list of proprietary blobs from file and generate
# vendor directory structure and makefiles
#

set -e # fail on unhandled error
set -u # fail on undefined variable
#set -x # debug

readonly SCRIPTS_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
readonly REALPATH_SCRIPT="$SCRIPTS_DIR/realpath.sh"
readonly CONSTS_SCRIPT="$SCRIPTS_DIR/constants.sh"
readonly TMP_WORK_DIR=$(mktemp -d /tmp/android_vendor_setup.XXXXXX) || exit 1
declare -a SYS_TOOLS=("cp" "sed" "zipinfo" "jarsigner" "awk" "shasum")

# Standalone symlinks. Need to also take care standalone firmware bin
# symlinks between /data/misc & /system/etc/firmware.
declare -a S_SLINKS_SRC
declare -a S_SLINKS_DST
HAS_STANDALONE_SLINKS=false

# Some shared libraries under are required as dependencies so we need to create
# individual modules for them
declare -a DSO_MODULES
HAS_DSO_MODULES=false

# APK files that need to preserve the original signature
declare -a PSIG_BC_FILES=()

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
      -o|--output     : Path to save vendor blobs & makefiles in AOSP compatible structure
      --blobs-list    : List of proprietary blobs to copy
      --dep-dso-list  : List of shared libraries that need to be included as a separate module
      --flags-list    : List of Makefile flags to be appended at 'BoardConfigVendor.mk'
      --extra-modules : Additional modules to be appended at main vendor 'Android.mk'
      --allow-preopt  : Don't disable LOCAL_DEX_PREOPT for /system
      --force-modules : Text file with AOSP defined modules to force include
    INFO:
      * Output should be moved/synced with AOSP root, unless -o is AOSP root
_EOF
  abort 1
}

command_exists() {
  type "$1" &> /dev/null
}

verify_input() {
  if [[ ! -d "$1/vendor" || ! -d "$1/system" || ! -d "$1/radio" || \
        ! -f "$1/system/build.prop" ]]; then
    echo "[-] Invalid input directory structure"
    usage
  fi
}

get_device_codename() {
  local device=""

  device=$(grep 'ro.product.device=' "$1" | cut -d '=' -f2 | \
           tr '[:upper:]' '[:lower:]' || true)
  if [[ "$device" == "" ]]; then
    echo "[-] Device string not found"
    abort 1
  fi
  echo "$device"
}

get_vendor() {
  local vendor=""

  vendor=$(grep 'ro.product.manufacturer=' "$1" | cut -d '=' -f2 | \
           tr '[:upper:]' '[:lower:]' || true)
  if [[ "$vendor" == "" ]]; then
    echo "[-] Device codename string not found"
    abort 1
  fi
  echo "$vendor"
}

get_radio_ver() {
  local radio_ver=""
  radio_ver=$(grep 'ro.build.expect.baseband' "$1" | cut -d '=' -f2 || true)

  # We allow empty radio version so that we can detect devices with no baseband
  echo "$radio_ver"
}

get_bootloader_ver() {
  local bootloader_ver=""
  bootloader_ver=$(grep 'ro.build.expect.bootloader' "$1" | cut -d '=' -f2 || true)
  if [[ "$bootloader_ver" == "" ]]; then
    echo "[-] Failed to identify bootloader version"
    abort 1
  fi
  echo "$bootloader_ver"
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
  ls -l "$INBASE/$RELTARGET" | sed -e 's/.* -> //'
}

array_contains() {
  local element
  for element in "${@:2}"; do [[ "$element" == "$1" ]] && return 0; done
  return 1
}

copy_radio_files() {
  local INDIR="$1"
  local OUTDIR="$2"

  mkdir -p "$OUTDIR/radio"

  if [[ "$RADIO_VER" != "" ]]; then
    cp -a "$INDIR/radio/radio"* "$OUTDIR/radio/radio.img" || {
      echo "[-] Failed to copy radio image"
      abort 1
    }
  fi

  cp -a "$INDIR/radio/bootloader"* "$OUTDIR/radio/bootloader.img" || {
    echo "[-] Failed to copy bootloader image"
    abort 1
  }

  if [ "$IS_PIXEL" = true ]; then
    for img in "${PIXEL_AB_PARTITIONS[@]}"
    do
      cp "$INDIR/radio/$img.img" "$OUTDIR/radio/"
    done
  fi
}

extract_blobs() {
  local BLOBS_LIST="$1"
  local INDIR="$2"
  local OUTDIR_PROP="$3/proprietary"
  local OUTDIR_VENDOR="$3/vendor"

  local src="" dst="" dstDir="" outBase="" openTag=""

  while read -r file
  do
    # Input format allows optional store under a different directory
    src=$(echo "$file" | cut -d ":" -f1)
    dst=$(echo "$file" | cut -d ":" -f2)
    if [[ "$dst" == "" ]]; then
      dst=$src
    fi

    # Special handling if source file is a symbolic link. Additional rules
    # will be handled later when unified Android.mk is created
    if [[ -L "$INDIR/$src" ]]; then
      if [[ "$dst" != "$src" ]]; then
        echo "[-] Symbolic links cannot have their destination path altered"
        abort 1
      fi
      symLinkSrc="$(read_invalid_symlink "$INDIR" "$src")"
      if [[ "$symLinkSrc" != /* ]]; then
        symLinkSrc="/$(dirname "$src")/$symLinkSrc"
      fi
      S_SLINKS_SRC+=("$symLinkSrc")
      S_SLINKS_DST+=("$src")
      HAS_STANDALONE_SLINKS=true
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
    cp -a "$INDIR/$src" "$outBase/$dst" || {
      echo "[-] Failed to copy '$src'"
      abort 1
    }

    # Some vendor xml files don't satisfy xmllint so fix here
    if [[ "${file##*.}" == "xml" ]]; then
      openTag=$(grep '^<?xml version' "$outBase/$dst" || true )
      if [[ "$openTag" != "" ]]; then
        grep -v '^<?xml version' "$outBase/$dst" > "$TMP_WORK_DIR/xml_fixup.tmp"
        echo "$openTag" > "$outBase/$dst"
        cat "$TMP_WORK_DIR/xml_fixup.tmp" >> "$outBase/$dst"
        rm "$TMP_WORK_DIR/xml_fixup.tmp"
      fi
    fi
  done < <(grep -Ev '(^#|^$)' "$BLOBS_LIST")
}

update_vendor_blobs_mk() {
  local BLOBS_LIST="$1"

  local RELDIR_PROP="vendor/$VENDOR_DIR/$DEVICE/proprietary"
  local RELDIR_VENDOR="vendor/$VENDOR_DIR/$DEVICE/vendor"

  local src="" srcRelDir="" dst="" dstRelDir="" fileExt=""

  echo 'PRODUCT_COPY_FILES += \' >> "$DEVICE_VENDOR_BLOBS_MK"

  while read -r file
  do
    # Skip files that have dedicated target module (APKs, JARs & selected shared libraries)
    fileExt="${file##*.}"
    if [[ "$fileExt" == "apk" || "$fileExt" == "jar" ]]; then
      continue
    fi
    if [[ "$HAS_DSO_MODULES" = true && "$fileExt" == "so" ]]; then
      if array_contains "$file" "${DSO_MODULES[@]}"; then
        continue
      fi
    fi

    # Skip standalone symbolic links if available
    if [ "$HAS_STANDALONE_SLINKS" = true ]; then
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

    echo "    $srcRelDir/$src:$dstRelDir/$dst:$VENDOR \\" >> "$DEVICE_VENDOR_BLOBS_MK"
  done < <(grep -Ev '(^#|^$)' "$BLOBS_LIST")

  strip_trail_slash_from_file "$DEVICE_VENDOR_BLOBS_MK"
}

process_extra_modules() {
  local module

  if [ ! -s "$EXTRA_MODULES" ]; then
    return
  fi

  {
    echo "# Extra modules from user configuration"
    echo 'PRODUCT_PACKAGES += \'
    grep 'LOCAL_MODULE :=' "$EXTRA_MODULES" | cut -d "=" -f2- | \
      awk '{$1=$1;print}' | while read -r module
    do
      echo "    $module \\"
    done
  } >> "$DEVICE_VENDOR_MK"
  strip_trail_slash_from_file "$DEVICE_VENDOR_MK"
}

process_enforced_modules() {
  local module

  if [ ! -s "$FORCE_MODULES" ]; then
    return
  fi

  {
    echo "# Enforced modules from user configuration"
    echo 'PRODUCT_PACKAGES += \'
    grep -Ev '(^#|^$)' "$FORCE_MODULES" | while read -r module
    do
      echo "    $module \\"
    done
  } >> "$DEVICE_VENDOR_MK"
  strip_trail_slash_from_file "$DEVICE_VENDOR_MK"
}

update_dev_vendor_mk() {
  process_extra_modules
  process_enforced_modules
}

gen_board_vendor_mk() {
  {
    echo 'LOCAL_PATH := $(call my-dir)'
    echo ""
    echo "\$(call add-radio-file,radio/bootloader.img,version-bootloader)"
    if [[ "$RADIO_VER" != "" ]]; then
      echo "\$(call add-radio-file,radio/radio.img,version-baseband)"
    fi

    if [ "$IS_PIXEL" = true ]; then
      for img in "${PIXEL_AB_PARTITIONS[@]}"
      do
        echo "\$(call add-radio-file,radio/$img.img)"
      done
    fi
  } >> "$ANDROID_BOARD_VENDOR_MK"
}

gen_board_cfg_mk() {
  local INDIR="$1"
  local v_img_sz

  # First lets check if vendor partition size has been extracted from
  # previous data extraction script
  v_img_sz="$(has_vendor_size "$INDIR")"
  if [[ "$v_img_sz" == "" ]]; then
    echo "[-] Unknown vendor image size for '$DEVICE' device"
    abort 1
  fi

  {
    echo "TARGET_BOARD_INFO_FILE := vendor/$VENDOR_DIR/$DEVICE/vendor-board-info.txt"
    echo 'BOARD_VENDORIMAGE_FILE_SYSTEM_TYPE := ext4'
    echo "BOARD_VENDORIMAGE_PARTITION_SIZE := $v_img_sz"

    # Update with user selected extra flags
    grep -Ev '(^#|^$)' "$MK_FLAGS_LIST" || true
  } >> "$BOARD_CONFIG_VENDOR_MK"
}

gen_board_family_cfg_mk() {
  if [ "$IS_PIXEL" = false ]; then
    return
  fi

  if [[ "$DEVICE_FAMILY" == "marlin" ]]; then
    {
      echo 'AB_OTA_PARTITIONS += vendor'
      echo 'ifneq ($(filter sailfish,$(TARGET_DEVICE)),)'
      echo '  LOCAL_STEM := sailfish/BoardConfigVendorPartial.mk'
      echo 'else'
      echo '  LOCAL_STEM := marlin/BoardConfigVendorPartial.mk'
      echo 'endif'
      echo "-include vendor/$VENDOR_DIR/\$(LOCAL_STEM)"
    } >> "$DEV_FAMILY_BOARD_CONFIG_VENDOR_MK"
  fi
}

gen_board_info_txt() {
  local OUTDIR="$1"
  local OUTTXT="$OUTDIR/vendor-board-info.txt"

  {
    echo "require board=$DEVICE"
    echo "require version-bootloader=$BOOTLOADER_VER"
    if [[ "$RADIO_VER" != "" ]]; then
      echo "require version-baseband=$RADIO_VER"
    fi
  } > "$OUTTXT"
}

zip_needs_resign() {
  local INFILE="$1"
  local output

  output=$(jarsigner -verify "$INFILE" 2>&1 || abort 1)
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

  echo ""
  echo "include \$(CLEAR_VARS)"
  echo "LOCAL_MODULE := $DSO_MNAME"
  echo "LOCAL_MODULE_CLASS := FAKE"
  echo "LOCAL_MODULE_TAGS := optional"
  echo "LOCAL_MODULE_OWNER := $VENDOR"
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

  local -a PKGS_SSLINKS
  local pkgName=""
  local cnt

  if [ ${#S_SLINKS_SRC[@]} -ne ${#S_SLINKS_DST[@]} ]; then
    echo "[-] Standalone symlinks arrays corruption - inspect paths manually"
    abort 1
  fi

  for link in "${S_SLINKS_SRC[@]}"
  do
    if [ -z "${cnt-}" ]; then
      cnt=0
    else
      let cnt=cnt+1
    fi

    # Skip symbolic links the destination of which is under bytecode directories
    if [[ "${S_SLINKS_DST[$cnt]}" == *app/* ]]; then
      continue
    fi

    if [[ "$link" == *lib64/*.so ]]; then
      pkgName="$(basename "$link" .so)_64.so"
    elif [[ "$link" == *lib/*.so ]]; then
      pkgName="$(basename "$link" .so)_32.so"
    else
      pkgName=$(basename "$link")
    fi
    PKGS_SSLINKS+=("$pkgName")

    {
      echo -e "\ninclude \$(CLEAR_VARS)"
      echo -e "LOCAL_MODULE := $pkgName"
      echo -e "LOCAL_MODULE_CLASS := FAKE"
      echo -e "LOCAL_MODULE_TAGS := optional"
      echo -e "LOCAL_MODULE_OWNER := $VENDOR"
      echo -e 'include $(BUILD_SYSTEM)/base_rules.mk'
      echo -e "\$(LOCAL_BUILT_MODULE): TARGET := ${S_SLINKS_SRC[$cnt]}"
      echo -e "\$(LOCAL_BUILT_MODULE): SYMLINK := \$(PRODUCT_OUT)/${S_SLINKS_DST[$cnt]}"
      echo -e "\$(LOCAL_BUILT_MODULE): \$(LOCAL_PATH)/Android.mk"
      echo -e "\$(LOCAL_BUILT_MODULE):"
      echo -e "\t\$(hide) mkdir -p \$(dir \$@)"
      echo -e "\t\$(hide) mkdir -p \$(dir \$(SYMLINK))"
      echo -e "\t\$(hide) rm -rf \$@"
      echo -e "\t\$(hide) rm -rf \$(SYMLINK)"
      echo -e "\t\$(hide) ln -sf \$(TARGET) \$(SYMLINK)"
      echo -e "\t\$(hide) touch \$@"
    } >> "$ANDROID_MK"
  done

  if [ ! -z "${PKGS_SSLINKS-}" ]; then
    {
      echo "# Standalone symbolic links"
      echo 'PRODUCT_PACKAGES += \'
      for module in "${PKGS_SSLINKS[@]}"
      do
        echo "    $module \\"
      done
    } >> "$DEVICE_VENDOR_MK"
  fi
  strip_trail_slash_from_file "$DEVICE_VENDOR_MK"
}

gen_mk_for_bytecode() {
  local INDIR="$1"
  local RELROOT="$2"
  local RELSUBROOT="$3"
  local OUTBASE="$4"
  local -a PKGS
  local -a PKGS_SLINKS

  local origin="" zipName="" fileExt="" pkgName="" src="" class="" suffix=""
  local priv="" cert="" stem="" lcMPath="" appDir="" dsoRootBase="" dsoRoot=""
  local dsoName="" dsoMName="" arch="" apk_lib_slinks=""

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

    # Annotate extra privileges when required
    if [[ "$RELSUBROOT" == "priv-app" ]]; then
      priv='LOCAL_PRIVILEGED_MODULE := true'
    fi

    # Always resign APKs with platform keys
    if [[ "$fileExt" == "apk" ]]; then
      cert="platform"
      if [ ! -z "${PSIG_BC_FILES-}" ]; then
        if array_contains "$zipName" "${PSIG_BC_FILES[@]}"; then
          cert="PRESIGNED"
        fi
      fi
    else
      # Framework JAR's don't contain signatures, so annotate to skip signing
      cert="PRESIGNED"
    fi

    # Some defensive checks in case configuration files are not aligned with the
    # existing assumptions about the signing entities
    if [[ "$RELSUBROOT" == "priv-app" && "$RELROOT" == "vendor" ]]; then
      echo "[-] Privileged modules under /vendor/priv-app are not supported"
      abort 1
    fi

    # Pre-optimized APKs have their native libraries resources stripped from archive
    if [ -d "$appDir/lib" ]; then
      # Self-contained native libraries are copied across utilizing PRODUCT_COPY_FILES
      while read -r lib
      do
        echo "$lib" | sed "s#$INDIR/##" >> "$RUNTIME_EXTRA_BLOBS_LIST"
      done < <(find "$appDir/lib" -type f -iname '*.so')

      # Some prebuilt APKs have also prebuilt JNI libs that are stored under
      # system-wide lib directories, with app directory containing a symlink to.
      # Resolve such cases to adjust includes so that we don't copy across the
      # same file twice.
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

        # Generate symlink fake rule & cache module_names to append later to vendor mk
        PKGS_SLINKS+=("$dsoMName")
        apk_lib_slinks+="$(gen_apk_dso_symlink "$dsoName" "$dsoMName" "$dsoRoot" \
                           "$lcMPath/$pkgName" "$arch")"
      done < <(find -L "$appDir/lib" -type l -iname '*.so')
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
        echo "LOCAL_REQUIRED_MODULES := ${PKGS_SLINKS[@]}"
      fi
      echo "LOCAL_CERTIFICATE := $cert"
      echo "LOCAL_MODULE_CLASS := $class"
      if [[ "$priv" != "" ]]; then
        echo "$priv"
      fi
      echo "LOCAL_MODULE_SUFFIX := $suffix"
      if [[ "$ALLOW_PREOPT" = false || "$RELROOT" == "vendor" ]]; then
        echo "LOCAL_DEX_PREOPT := false"
      fi

      # Deal with multi-lib
      if [[ ( -d "$appDir/oat/arm" && -d "$appDir/oat/arm64" ) ||
            ( -d "$appDir/oat/x86" && -d "$appDir/oat/x86_64" ) ]]; then
        echo "LOCAL_MULTILIB := both"
      elif [[ -d "$appDir/oat/arm" || -d "$appDir/oat/x86" ]]; then
        echo "LOCAL_MULTILIB := 32"
      fi

      echo 'include $(BUILD_PREBUILT)'

      # Append rules for APK lib symlinks if present
      if [[ "$apk_lib_slinks" != "" ]]; then
        echo -e "$apk_lib_slinks"
      fi
    } >> "$ANDROID_MK"

    # Also add pkgName to runtime array to append later the vendor mk
    PKGS+=("$pkgName")
  done < <(find "$OUTBASE/$RELROOT/$RELSUBROOT" -maxdepth 2 \
           -type f -iname '*.apk' -o -iname '*.jar' | sort)

  # Update vendor mk
  {
    echo "# Prebuilt APKs/JARs from '$RELROOT/$RELSUBROOT'"
    echo 'PRODUCT_PACKAGES += \'
    for pkg in "${PKGS[@]}"
    do
      echo "    $pkg \\"
    done
  }  >> "$DEVICE_VENDOR_MK"
  strip_trail_slash_from_file "$DEVICE_VENDOR_MK"

  # Update vendor mk again with symlink modules if present
  if [ ! -z "${PKGS_SLINKS-}" ]; then
    {
      echo "# Prebuilt APKs libs symlinks from '$RELROOT/$RELSUBROOT'"
      echo 'PRODUCT_PACKAGES += \'
      for module in "${PKGS_SLINKS[@]}"
      do
        echo "    $module \\"
      done
    } >> "$DEVICE_VENDOR_MK"
    strip_trail_slash_from_file "$DEVICE_VENDOR_MK"
  fi
}

gen_mk_for_shared_libs() {
  local INDIR="$1"
  local OUTBASE="$2"

  local -a PKGS
  local -a MULTIDSO
  local dsoModule curFile

  # First iterate the 64bit libs to detect possible dual target modules
  for dsoModule in "${DSO_MODULES[@]}"
  do
    # Array is mixed so skip non-64bit libs
    if echo "$dsoModule" | grep -q "/lib/"; then
      continue
    fi

    curFile="$OUTBASE/$(echo "$dsoModule" | sed "s#system/#proprietary/#")"

    # Check that configuration requested file exists
    if [ ! -f "$curFile" ]; then
      echo "[-] Failed to locate '$curFile' file"
      abort 1
    fi

    local dsoRelRoot="" dso32RelRoot="" dsoFile="" dsoName="" dsoSrc="" dso32Src=""

    dsoRelRoot=$(dirname "$curFile" | sed "s#$OUTBASE/##")
    dsoFile=$(basename "$curFile")
    dsoName=$(basename "$curFile" ".so")
    dsoSrc="$dsoRelRoot/$dsoFile"

    dso32RelRoot=$(echo "$dsoRelRoot" | sed "s#lib64#lib#")
    dso32Src="$dso32RelRoot/$dsoFile"

    {
      echo ""
      echo 'include $(CLEAR_VARS)'
      echo "LOCAL_MODULE := $dsoName"
      echo 'LOCAL_MODULE_TAGS := optional'
      echo "LOCAL_MODULE_OWNER := $VENDOR"
      echo "LOCAL_SRC_FILES := $dsoSrc"
      echo "LOCAL_MODULE_CLASS := SHARED_LIBRARIES"
      echo "LOCAL_MODULE_SUFFIX := .so"

      if echo "$dsoModule" | grep -q "^vendor/"; then
        echo "LOCAL_PROPRIETARY_MODULE := true"
      fi

      # In case 32bit version present - upgrade to dual target
      if [ -f "$OUTBASE/$dso32Src" ]; then
        echo "LOCAL_MULTILIB := both"
        echo "LOCAL_SRC_FILES_32 := $dso32Src"

        # Cache dual-targets so that we don't include again when searching for
        # 32bit only libs under a 64bit system
        MULTIDSO+=("$dso32Src")
      else
        echo "LOCAL_MULTILIB := first"
      fi

      echo 'include $(BUILD_PREBUILT)'
    } >> "$ANDROID_MK"

    # Also add pkgName to runtime array to append later the vendor mk
    PKGS+=("$dsoName")
  done

  # Then iterate the 32bit libs excluding the ones already included as dual targets
  for dsoModule in "${DSO_MODULES[@]}"
  do
    # Array is mixed so skip non-64bit libs
    if echo "$dsoModule" | grep -q "/lib64/"; then
      continue
    fi

    curFile="$OUTBASE/$(echo "$dsoModule" | sed "s#system/#proprietary/#")"

    # Check that configuration requested file exists
    if [ ! -f "$curFile" ]; then
      echo "[-] Failed to locate '$curFile' file"
      abort 1
    fi

    local dsoRelRoot="" dsoFile="" dsoName="" dsoSrc=""

    dsoRelRoot=$(dirname "$curFile" | sed "s#$OUTBASE/##")
    dsoFile=$(basename "$curFile")
    dsoName=$(basename "$curFile" ".so")
    dsoSrc="$dsoRelRoot/$dsoFile"

    if [ ! -z "${MULTIDSO-}" ]; then
      if array_contains "$dsoSrc" "${MULTIDSO[@]}"; then
        continue
      fi
    fi

    {
      echo ""
      echo 'include $(CLEAR_VARS)'
      echo "LOCAL_MODULE := $dsoName"
      echo 'LOCAL_MODULE_TAGS := optional'
      echo "LOCAL_MODULE_OWNER := $VENDOR"
      echo "LOCAL_SRC_FILES := $dsoSrc"
      echo "LOCAL_MODULE_CLASS := SHARED_LIBRARIES"
      echo "LOCAL_MODULE_SUFFIX := .so"

      if echo "$dsoModule" | grep -q "^vendor/"; then
        echo "LOCAL_PROPRIETARY_MODULE := true"
      fi

      echo "LOCAL_MULTILIB := 32"
      echo 'include $(BUILD_PREBUILT)'
    } >> "$ANDROID_MK"

    # Also add pkgName to runtime array to append later the vendor mk
    PKGS+=("$dsoName")
  done

  # Update vendor mk
  if [ ! -z "${PKGS-}" ]; then
    {
      echo "# Prebuilt shared libraries"
      echo 'PRODUCT_PACKAGES += \'
      for pkg in "${PKGS[@]}"
      do
        echo "    $pkg \\"
      done
    }  >> "$DEVICE_VENDOR_MK"
    strip_trail_slash_from_file "$DEVICE_VENDOR_MK"
  fi
}

update_ab_ota_partitions() {
  local outMk="$1"

  {
    echo "# Partitions to add in AB OTA images"
    echo 'AB_OTA_PARTITIONS += \'
    for partition in "${PIXEL_AB_PARTITIONS[@]}"
    do
      echo "    $partition \\"
    done
  }  >> "$DEVICE_VENDOR_MK"
  strip_trail_slash_from_file "$DEVICE_VENDOR_MK"
}

gen_android_mk() {
  local root path targetProductDevice
  targetProductDevice="$DEVICE"
  {
    echo 'LOCAL_PATH := $(call my-dir)'

    # Special handling for flounder dual target boards
    if [[ "$DEVICE" == "flounder_lte" ]]; then
      echo 'ifneq ("$(wildcard vendor/htc/flounder/Android.mk)","")'
      echo '  $(error "volantis & volantisg vendor blobs cannot co-exist under AOSP root since definitions conflict")'
      echo 'endif'
      targetProductDevice="flounder"
    fi

    echo "ifeq (\$(TARGET_DEVICE),$targetProductDevice)"
    echo ""
    echo "include vendor/$VENDOR_DIR/$DEVICE/AndroidBoardVendor.mk"
  } >> "$ANDROID_MK"

  for root in "vendor" "proprietary"
  do
    for path in "${SYSTEM_DIRS_WITH_BC[@]}"
    do
      if [ -d "$OUTPUT_VENDOR/$root/$path" ]; then
        echo "[*] Gathering data from '$root/$path' APK/JAR pre-builts"
        gen_mk_for_bytecode "$INPUT_DIR" "$root" "$path" "$OUTPUT_VENDOR"
      fi
    done
  done

  if [ "$HAS_STANDALONE_SLINKS" = true ]; then
    echo "[*] Processing standalone symlinks"
    gen_standalone_symlinks "$INPUT_DIR" "$OUTPUT_VENDOR"
  fi

  # Iterate over directories with shared libraries and update the unified Android.mk file
  if [ "$HAS_DSO_MODULES" = true ]; then
    echo "[*] Generating shared library individual pre-built modules"
    gen_mk_for_shared_libs "$INPUT_DIR" "$OUTPUT_VENDOR"
  fi

  # Append extra modules if present
  if [ -s "$EXTRA_MODULES" ]; then
    {
      echo ""
      cat "$EXTRA_MODULES"
    } >> "$ANDROID_MK"
  fi

  # Finally close master Android.mk
  {
    echo ""
    echo "endif"
  } >> "$ANDROID_MK"
}

strip_trail_slash_from_file() {
  local INFILE="$1"

  sed '$s# \\#\'$'\n#' "$INFILE" > "$INFILE.tmp"
  mv "$INFILE.tmp" "$INFILE"
}

gen_sigs_file() {
  local INDIR="$1"
  local SIGSFILE="$INDIR/file_signatures.txt"
  > "$SIGSFILE"

  find "$INDIR" -type f ! -name "file_signatures.txt" | sort | while read -r file
  do
    shasum -a1 "$file" | sed "s#$INDIR/##" >> "$SIGSFILE"
  done
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
. "$REALPATH_SCRIPT"
. "$CONSTS_SCRIPT"

INPUT_DIR=""
OUTPUT_DIR=""
BLOBS_LIST=""
DEP_DSO_BLOBS_LIST=""
MK_FLAGS_LIST=""
EXTRA_MODULES=""
FORCE_MODULES=""
ALLOW_PREOPT=false

DEVICE=""
DEVICE_FAMILY=""
IS_PIXEL=false
VENDOR=""
DEV_FAMILY_BOARD_CONFIG_VENDOR_MK=""
RUNTIME_EXTRA_BLOBS_LIST="$TMP_WORK_DIR/runtime_extra_blobs.txt"

# Check that system tools exist
for i in "${SYS_TOOLS[@]}"
do
  if ! command_exists "$i"; then
    echo "[-] '$i' command not found"
    abort 1
  fi
done

while [[ $# -gt 0 ]]
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
    --blobs-list)
      BLOBS_LIST="$2"
      shift
      ;;
    --dep-dso-list)
      DEP_DSO_BLOBS_LIST="$2"
      shift
      ;;
    --flags-list)
      MK_FLAGS_LIST="$2"
      shift
      ;;
    --extra-modules)
      EXTRA_MODULES="$2"
      shift
      ;;
    --force-modules)
      FORCE_MODULES="$2"
      shift
      ;;
    --allow-preopt)
      ALLOW_PREOPT=true
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

# Mandatory configuration files
check_file "$BLOBS_LIST" "Vendor proprietary-blobs"
check_file "$DEP_DSO_BLOBS_LIST" "Vendor dep-dso-proprietary"
check_file "$MK_FLAGS_LIST" "Vendor vendor-config"
check_file "$EXTRA_MODULES" "Vendor extra modules"
check_file "$FORCE_MODULES" "Vendor enforce modules"

# Populate the array with the APK that need to maintain their signature
readarray -t PSIG_BC_FILES < <(
 grep -E ':PRESIGNED$' "$BLOBS_LIST" | cut -d ":" -f1 | while read -r apk; do
  basename "$apk"; done
)

# Verify input directory structure
verify_input "$INPUT_DIR"

# Get device details
DEVICE=$(get_device_codename "$INPUT_DIR/system/build.prop")
VENDOR=$(get_vendor "$INPUT_DIR/system/build.prop")
VENDOR_DIR="$VENDOR"
RADIO_VER=$(get_radio_ver "$INPUT_DIR/system/build.prop")
BOOTLOADER_VER=$(get_bootloader_ver "$INPUT_DIR/system/build.prop")

if [[ "$VENDOR" == "google" ]]; then
  VENDOR_DIR="google_devices"
  IS_PIXEL=true
  if [[ "$DEVICE" == "marlin" || "$DEVICE" == "sailfish" ]]; then
    DEVICE_FAMILY="marlin"
  fi
  mkdir -p "$OUTPUT_DIR/vendor/$VENDOR_DIR/$DEVICE_FAMILY"
fi

echo "[*] Generating blobs for vendor/$VENDOR_DIR/$DEVICE"

# Clean-up output
OUTPUT_VENDOR="$OUTPUT_DIR/vendor/$VENDOR_DIR/$DEVICE"
PROP_EXTRACT_BASE="$OUTPUT_VENDOR/proprietary"
if [ -d "$OUTPUT_VENDOR" ]; then
  rm -rf "${OUTPUT_VENDOR:?}"/*
fi
mkdir -p "$PROP_EXTRACT_BASE"

# Prepare generated make files
DEVICE_VENDOR_MK="$OUTPUT_VENDOR/device-vendor.mk";              touch "$DEVICE_VENDOR_MK"
DEVICE_VENDOR_BLOBS_MK="$OUTPUT_VENDOR/$DEVICE-vendor-blobs.mk"; touch "$DEVICE_VENDOR_BLOBS_MK"
BOARD_CONFIG_VENDOR_MK="$OUTPUT_VENDOR/BoardConfigVendor.mk";    touch "$BOARD_CONFIG_VENDOR_MK"
ANDROID_BOARD_VENDOR_MK="$OUTPUT_VENDOR/AndroidBoardVendor.mk";  touch "$ANDROID_BOARD_VENDOR_MK"
ANDROID_MK="$OUTPUT_VENDOR/Android.mk";                          touch "$ANDROID_MK"

if [ "$IS_PIXEL" = true ]; then
  DEV_FAMILY_BOARD_CONFIG_VENDOR_MK="$OUTPUT_DIR/vendor/$VENDOR_DIR/$DEVICE_FAMILY/BoardConfigVendor.mk"
  touch "$DEV_FAMILY_BOARD_CONFIG_VENDOR_MK"

  BOARD_CONFIG_VENDOR_MK="$OUTPUT_VENDOR/BoardConfigVendorPartial.mk"
  touch "$BOARD_CONFIG_VENDOR_MK"

  rm "$DEVICE_VENDOR_MK"
  DEVICE_VENDOR_MK="$OUTPUT_DIR/vendor/$VENDOR_DIR/$DEVICE_FAMILY/device-vendor-$DEVICE.mk"
  touch "$DEVICE_VENDOR_MK"

  # Fingerprint fix
  {
    echo 'PRODUCT_PROPERTY_OVERRIDES += \'
    echo '    ro.hardware.fingerprint=fpc'
  } >> "$DEVICE_VENDOR_MK"
fi

# And prefix them
find "$OUTPUT_DIR/vendor/$VENDOR_DIR" -type f -name '*.mk' | while read -r file
do
  echo -e "# [$(date +%Y-%m-%d)] Auto-generated file, do not edit\n" > "$file"
done

# Update from DSO_MODULES array from DEP_DSO_BLOBS_LIST file
entries=$(grep -Ev '(^#|^$)' "$DEP_DSO_BLOBS_LIST" | wc -l | tr -d ' ')
if [ "$entries" -gt 0 ]; then
  readarray -t DSO_MODULES < <(grep -Ev '(^#|^$)' "$DEP_DSO_BLOBS_LIST")
  HAS_DSO_MODULES=true
fi

# Copy radio images
echo "[*] Copying radio files '$OUTPUT_VENDOR'"
copy_radio_files "$INPUT_DIR" "$OUTPUT_VENDOR"

# Generate $DEVICE-vendor-blobs.mk makefile (plain files that don't require a target module)
# Will be updated later
echo "[*] Copying product files & generating '$DEVICE-vendor-blobs.mk' makefile"
extract_blobs "$BLOBS_LIST" "$INPUT_DIR" "$OUTPUT_VENDOR"
update_vendor_blobs_mk "$BLOBS_LIST"

# Generate device-vendor.mk makefile (will be updated later)
echo "[*] Generating '$(basename "$DEVICE_VENDOR_MK")'"
echo -e "\$(call inherit-product, vendor/$VENDOR_DIR/$DEVICE/$DEVICE-vendor-blobs.mk)\n" >> "$DEVICE_VENDOR_MK"

# Generate AndroidBoardVendor.mk with radio stuff (baseband & bootloader)
echo "[*] Generating 'AndroidBoardVendor.mk'"
gen_board_vendor_mk
echo "  [*] Bootloader:$BOOTLOADER_VER"
if [[ "$RADIO_VER" != "" ]]; then
  echo "  [*] Baseband:$RADIO_VER"
fi

# Generate BoardConfigVendor.mk (vendor partition type)
echo "[*] Generating 'BoardConfigVendor.mk'"
gen_board_cfg_mk "$INPUT_DIR"
gen_board_family_cfg_mk

# Generate vendor-board-info.txt with baseband & bootloader versions
echo "[*] Generating 'vendor-board-info.txt'"
gen_board_info_txt "$OUTPUT_VENDOR"

# Iterate over directories with bytecode and generate a unified Android.mk file
echo "[*] Generating 'Android.mk'"
gen_android_mk "$OUTPUT_VENDOR"

# Add user defined extra and enforced module targets to PRODUCT_PACKAGES list
update_dev_vendor_mk

# Generate $DEVICE-vendor-blobs.mk makefile (plain files that don't require a target module)
if [ -f "$RUNTIME_EXTRA_BLOBS_LIST" ]; then
  echo "[*] Processing additional runtime generated product files"
  extract_blobs "$RUNTIME_EXTRA_BLOBS_LIST" "$INPUT_DIR" "$OUTPUT_VENDOR"
  update_vendor_blobs_mk "$RUNTIME_EXTRA_BLOBS_LIST"

  cat "$RUNTIME_EXTRA_BLOBS_LIST" >> "$BLOBS_LIST"
  sort "$BLOBS_LIST" > "$BLOBS_LIST.tmp"
  mv "$BLOBS_LIST.tmp" "$BLOBS_LIST"
fi

if [ "$IS_PIXEL" = true ]; then
  update_ab_ota_partitions "$DEVICE_VENDOR_MK"
fi

# Generate file signatures list
echo "[*] Generating signatures file"
gen_sigs_file "$OUTPUT_VENDOR"

abort 0
