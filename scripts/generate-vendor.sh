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
readonly COMMON_SCRIPT="$SCRIPTS_DIR/common.sh"
readonly TMP_WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}"/android_vendor_setup.XXXXXX) || exit 1
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

# APK files that need to maintain the original signature
declare -a PSIG_BC_FILES=()

# All bytecode packages included from system partition
declare -a ALL_BC_PKGS=()

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
      -i|--input     : Root path of extracted /system & /vendor partitions
      -o|--output    : Path to save vendor blobs & makefiles in AOSP compatible structure
      --aosp-root    : [OPTIONAL] AOSP ROOT SRC directoy to directly rsync output
      --conf-file    : Device configuration file
      --conf-type    : 'naked' or 'full' configuration profile
      --api          : API level in order to pick appropriate config file
      --allow-preopt : [OPTIONAL] Don't disable LOCAL_DEX_PREOPT for /system
      --force-vimg   : [OPTIONAL] Always override AOSP definitions with included vendor blobs
    INFO:
      * If '--aosp-root' is used intermediate output is set to tmp and rsynced when success
_EOF
  abort 1
}

verify_input() {
  if [[ ! -d "$1/vendor" || ! -d "$1/system" || ! -d "$1/radio" || \
        ! -f "$1/system/build.prop" ]]; then
    echo "[-] Invalid input directory structure"
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

get_build_id() {
  local build_id=""
  build_id=$(grep 'ro.build.id' "$1" | cut -d '=' -f2 || true)
  if [[ "$build_id" == "" ]]; then
    echo "[-] Failed to identify BUILD_ID"
    abort 1
  fi
  echo "$build_id"
}

has_vendor_size() {
  local search_file="$1/vendor_partition_size"
  if [ -f "$search_file" ]; then
    cat "$search_file"
  else
    echo ""
  fi
}

read_invalid_symlink() {
  local inBase="$1"
  local relTarget="$2"
  ls -l "$inBase/$relTarget" | sed -e 's/.* -> //'
}

copy_radio_files() {
  local inDir="$1"
  local outDir="$2"

  mkdir -p "$outDir/radio"

  if [[ "$RADIO_VER" != "" ]]; then
    cp -a "$inDir/radio/radio"* "$outDir/radio/radio.img" || {
      echo "[-] Failed to copy radio image"
      abort 1
    }
  fi

  cp -a "$inDir/radio/bootloader"* "$outDir/radio/bootloader.img" || {
    echo "[-] Failed to copy bootloader image"
    abort 1
  }

  if [[ "$VENDOR" == "google" && "$EXTRA_IMGS_LIST" != "" ]]; then
    for img in "${EXTRA_IMGS[@]}"
    do
      cp "$inDir/radio/$img.img" "$outDir/radio/"
    done
  fi
}

extract_blobs() {
  local blobsList="$1"
  local inDir="$2"
  local outDir_prop="$3/proprietary"
  local outDir_vendor="$3/vendor"

  local src="" dst="" dstDir="" outBase="" outPath="" openTag=""

  while read -r file
  do
    # Input format allows optional store under a different directory/name
    src=$(echo "$file" | cut -d ":" -f1)
    dst=$(echo "$file" | cut -d ":" -f2)
    if [[ "$dst" == "" ]]; then
      dst=$src
    fi

    # Special handling if source file is a symbolic link. Additional rules
    # will be handled later when unified Android.mk is created
    if [[ -L "$inDir/$src" ]]; then
      if [[ "$dst" != "$src" ]]; then
        echo "[-] Symbolic links cannot have their destination path altered"
        abort 1
      fi
      symLinkSrc="$(read_invalid_symlink "$inDir" "$src")"
      if [[ "$symLinkSrc" != /* ]]; then
        symLinkSrc="/$(dirname "$src")/$symLinkSrc"
      fi
      S_SLINKS_SRC+=("$symLinkSrc")
      S_SLINKS_DST+=("$src")
      HAS_STANDALONE_SLINKS=true
      continue
    fi

    # Files under /system go to $outDir_prop, while files from /vendor
    # to $outDir_vendor
    if [[ $src == system/* ]]; then
      outBase=$outDir_prop
      dst=$(echo "$dst" | sed 's#^system/##')
    elif [[ $src == vendor/* ]]; then
      outBase=$outDir_vendor
      dst=$(echo "$dst" | sed 's#^vendor/##')
    else
      echo "[-] Invalid path detected at '$blobsList' ($src)"
      abort 1
    fi

    # Always maintain relative directory structure
    dstDir=$(dirname "$dst")
    if [ ! -d "$outBase/$dstDir" ]; then
      mkdir -p "$outBase/$dstDir"
    fi

    # Keep the same file name when including the resource (will be renamed at build time when
    # writing to destination)
    outPath="$outBase/$dstDir/$(basename "$src")"

    cp -a "$inDir/$src" "$outPath" || {
      echo "[-] Failed to copy '$src'"
      abort 1
    }

    # Some vendor xml files don't satisfy xmllint so fix here
    if [[ "${file##*.}" == "xml" ]]; then
      openTag=$(grep '^<?xml version' "$outPath" || true )
      if [[ "$openTag" != "" ]]; then
        grep -v '^<?xml version' "$outPath" > "$TMP_WORK_DIR/xml_fixup.tmp" || true
        rm -f "$outPath"
        echo "$openTag" > "$outPath"
        cat "$TMP_WORK_DIR/xml_fixup.tmp" >> "$outPath"
        rm "$TMP_WORK_DIR/xml_fixup.tmp"
      fi
    fi
  done < <(grep -Ev '(^#|^$)' "$blobsList")
}

update_vendor_blobs_mk() {
  local blobsList="$1"

  local relDir_prop="vendor/$VENDOR_DIR/$DEVICE/proprietary"
  local relDir_vendor="vendor/$VENDOR_DIR/$DEVICE/vendor"

  local src="" srcRelDir="" dst="" dstRelDir="" fileExt="" dstMk=""

  echo 'PRODUCT_COPY_FILES += \' >> "$DEVICE_VENDOR_BLOBS_MK"
  if [ $FORCE_VIMG = true ]; then
    echo 'PRODUCT_COPY_FILES := \' >> "$BOARD_CONFIG_VENDOR_MK"
  fi

  while read -r file
  do
    # Split the file from the destination (format is "file[:destination]")
    src=$(echo "$file" | cut -d ":" -f1)
    dst=$(echo "$file" | cut -d ":" -f2)
    if [[ "$dst" == "" ]]; then
      dst=$src
    fi

    # Skip files that have dedicated target module (APKs, JARs & selected shared libraries)
    fileExt="${src##*.}"
    if [[ "$fileExt" == "apk" || "$fileExt" == "jar" ]]; then
      continue
    fi
    if [[ "$HAS_DSO_MODULES" = true && "$fileExt" == "so" ]]; then
      if array_contains "$src" "${DSO_MODULES[@]}"; then
        continue
      fi
    fi

    # Skip standalone symbolic links if available
    if [ "$HAS_STANDALONE_SLINKS" = true ]; then
      if array_contains "$src" "${S_SLINKS_DST[@]}"; then
        continue
      fi
    fi

    # Adjust prefixes for relative dirs of src & dst files
    if [[ $src == system/* ]]; then
      srcRelDir=$relDir_prop
      src=$(echo "$src" | sed 's#^system/##')
    elif [[ $src == vendor/* ]]; then
      srcRelDir=$relDir_vendor
      src=$(echo "$src" | sed 's#^vendor/##')
    else
      echo "[-] Invalid src path detected at '$blobsList'"
      abort 1
    fi
    if [[ $dst == system/* ]]; then
      dstRelDir='$(TARGET_COPY_OUT_SYSTEM)'
      dst=$(echo "$dst" | sed 's#^system/##')
      dstMk="$DEVICE_VENDOR_BLOBS_MK"
    elif [[ $dst == vendor/* ]]; then
      dstRelDir='$(TARGET_COPY_OUT_VENDOR)'
      dst=$(echo "$dst" | sed 's#^vendor/##')
      dstMk="$BOARD_CONFIG_VENDOR_MK"
    else
      echo "[-] Invalid dst path detected at '$blobsList'"
      abort 1
    fi

    if [ $FORCE_VIMG = true ]; then
      echo "    $srcRelDir/$src:$dstRelDir/$dst:$VENDOR \\" >> "$dstMk"
    else
      echo "    $srcRelDir/$src:$dstRelDir/$dst:$VENDOR \\" >> "$DEVICE_VENDOR_BLOBS_MK"
    fi
  done < <(grep -Ev '(^#|^$)' "$blobsList")

  strip_trail_slash_from_file "$DEVICE_VENDOR_BLOBS_MK"

  if [ $FORCE_VIMG = true ]; then
    echo '    $(PRODUCT_COPY_FILES)' >> "$BOARD_CONFIG_VENDOR_MK"
    echo "" >> "$BOARD_CONFIG_VENDOR_MK"
  fi
}

process_extra_modules() {
  local module

  if [[ "$EXTRA_MODULES" == "" ]]; then
    return
  fi

  {
    echo "# Extra modules from user configuration"
    echo 'PRODUCT_PACKAGES += \'
    echo "$EXTRA_MODULES" | grep 'LOCAL_MODULE :=' | cut -d "=" -f2- | \
      awk '{$1=$1;print}' | while read -r module
    do
      echo "    $module \\"
    done
  } >> "$DEVICE_VENDOR_MK"
  strip_trail_slash_from_file "$DEVICE_VENDOR_MK"
}

process_enforced_modules() {
  local module

  if [[ "$FORCE_MODULES" == "" ]]; then
    return
  fi

  {
    echo "# Enforced modules from user configuration"
    echo 'PRODUCT_PACKAGES += \'
    echo "$FORCE_MODULES" | grep -Ev '(^#|^$)' | while read -r module
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

    if [[ "$VENDOR" == "google" && "$EXTRA_IMGS_LIST" != "" ]]; then
      for img in "${EXTRA_IMGS[@]}"
      do
        echo "\$(call add-radio-file,radio/$img.img)"
      done
    fi
  } >> "$ANDROID_BOARD_VENDOR_MK"
}

gen_board_cfg_mk() {
  local inDir="$1"
  local v_img_sz

  # First lets check if vendor partition size has been extracted from
  # previous data extraction script
  v_img_sz="$(has_vendor_size "$inDir")"
  if [[ "$v_img_sz" == "" ]]; then
    echo "[-] Unknown vendor image size for '$DEVICE' device"
    abort 1
  fi

  {
    echo "TARGET_BOARD_INFO_FILE := vendor/$VENDOR_DIR/$DEVICE/vendor-board-info.txt"
    echo 'BOARD_VENDORIMAGE_FILE_SYSTEM_TYPE := ext4'
    echo "BOARD_VENDORIMAGE_PARTITION_SIZE := $v_img_sz"

    # Update with user selected extra flags
    echo "$MK_FLAGS_LIST"
  } >> "$BOARD_CONFIG_VENDOR_MK"
}

gen_board_family_cfg_mk() {
  # So far required only for Pixel 1st generation
  if [[ "$DEVICE_FAMILY" == "marlin" ]]; then
    local familyBoardCfgVendorMk="$OUTPUT_DIR/vendor/$VENDOR_DIR/$DEVICE_FAMILY/BoardConfigVendor.mk"
    {
      echo "# [$EXEC_DATE] Auto-generated file, do not edit"
      echo ""
      echo 'ifneq ($(filter sailfish,$(TARGET_DEVICE)),)'
      echo '  LOCAL_STEM := sailfish/BoardConfigVendorPartial.mk'
      echo 'else'
      echo '  LOCAL_STEM := marlin/BoardConfigVendorPartial.mk'
      echo 'endif'
      echo "-include vendor/$VENDOR_DIR/\$(LOCAL_STEM)"
    } > "$familyBoardCfgVendorMk"
  fi
}

gen_board_info_txt() {
  local outDir="$1"
  local outTxt="$outDir/vendor-board-info.txt"

  {
    echo "require board=$DEVICE"
    echo "require version-bootloader=$BOOTLOADER_VER"
    if [[ "$RADIO_VER" != "" ]]; then
      echo "require version-baseband=$RADIO_VER"
    fi
  } > "$outTxt"
}

zip_needs_resign() {
  local inFile="$1"
  local output

  output=$(jarsigner -verify "$inFile" 2>&1 || abort 1)
  if [[ "$output" =~ .*"contains unsigned entries".* ]]; then
    return 0
  else
    return 1
  fi
}

gen_apk_dso_symlink() {
  local dso_name=$1
  local dso_mName=$2
  local dso_root=$3
  local apk_dir=$4
  local dso_abi=$5

  echo ""
  echo "include \$(CLEAR_VARS)"
  echo "LOCAL_MODULE := $dso_mName"
  echo "LOCAL_MODULE_CLASS := FAKE"
  echo "LOCAL_MODULE_TAGS := optional"
  echo "LOCAL_MODULE_OWNER := $VENDOR"
  echo 'include $(BUILD_SYSTEM)/base_rules.mk'
  echo "\$(LOCAL_BUILT_MODULE): TARGET := $dso_root/$dso_name"
  echo "\$(LOCAL_BUILT_MODULE): SYMLINK := $apk_dir/lib/$dso_abi/$dso_name"
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
  local inDir="$1"

  local -a pkgs_SSLinks
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

    local dst="${S_SLINKS_DST[$cnt]}"
    local src="${S_SLINKS_SRC[$cnt]}"
    local linknm=""

    # Skip symbolic links the destination of which is under bytecode directories
    if [[ "$dst" == *app/* ]]; then
      continue
    fi

    linknm="$(basename "$link")"

    # Skip toybox, toolbox & grep links since already built from AOSP
    #  - external/toybox/Android.mk#419
    #  - system/core/toolbox/Android.bp#79
    #  - system/core/toolbox/Android.bp
    if [[ "$linknm" == "toybox_vendor" || "$linknm" == "toolbox" || "$linknm" == "grep" ]]; then
      continue
    fi

    if [[ "$link" == *lib64/*.so ]]; then
      pkgName="$(basename "$link" .so)_64.so__$(basename "$dst")"
    elif [[ "$link" == *lib/*.so ]]; then
      pkgName="$(basename "$link" .so)_32.so__$(basename "$dst")"
    else
      pkgName="$(basename "$link")__$(basename "$dst")__$cnt"
    fi
    pkgs_SSLinks+=("$pkgName")

    {
      echo -e "\ninclude \$(CLEAR_VARS)"
      echo -e "LOCAL_MODULE := $pkgName"
      echo -e "LOCAL_MODULE_CLASS := FAKE"
      echo -e "LOCAL_MODULE_TAGS := optional"
      echo -e "LOCAL_MODULE_OWNER := $VENDOR"
      echo -e 'include $(BUILD_SYSTEM)/base_rules.mk'
      echo -e "\$(LOCAL_BUILT_MODULE): TARGET := $src"
      echo -e "\$(LOCAL_BUILT_MODULE): SYMLINK := \$(PRODUCT_OUT)/$dst"
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

  if [ ! -z "${pkgs_SSLinks-}" ]; then
    {
      echo "# Standalone symbolic links"
      echo 'PRODUCT_PACKAGES += \'
      for module in "${pkgs_SSLinks[@]}"
      do
        echo "    $module \\"
      done
    } >> "$DEVICE_VENDOR_MK"
  fi
  strip_trail_slash_from_file "$DEVICE_VENDOR_MK"
}

gen_mk_for_bytecode() {
  local inDir="$1"
  local relRoot="$2"
  local relSubRoot="$3"
  local outBase="$4"
  local -a pkgs
  local -a pkgs_SLinks

  local origin="" zipName="" fileExt="" pkgName="" src="" class="" suffix=""
  local priv="" cert="" stem="" lcMPath="" appDir="" dsoRootBase="" dsoRoot=""
  local dsoName="" dsoMName="" arch="" apk_lib_slinks=""
  local has_bc_file

  # Set module path (output)
  if [[ "$relRoot" == "vendor" ]]; then
    origin="$inDir/vendor/$relSubRoot"
    lcMPath="\$(PRODUCT_OUT)/\$(TARGET_COPY_OUT_VENDOR)/$relSubRoot"
    dsoRootBase="/vendor"
  elif [[ "$relRoot" == "proprietary" ]]; then
    origin="$inDir/system/$relSubRoot"
    lcMPath="\$(PRODUCT_OUT)/\$(TARGET_COPY_OUT_SYSTEM)/$relSubRoot"
    dsoRootBase="/system"
  else
    echo "[-] Invalid '$relRoot' relative directory"
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
      src="$relRoot/$relSubRoot/$zipName"
      class='JAVA_LIBRARIES'
      suffix='$(COMMON_JAVA_PACKAGE_SUFFIX)'
    elif [[ "$fileExt" == "apk" ]]; then
      if [ -d "$outBase/$relRoot/$relSubRoot/$pkgName" ]; then
        src="$relRoot/$relSubRoot/$pkgName/$zipName"
      else
        src="$relRoot/$relSubRoot/$zipName"
      fi
      class='APPS'
      suffix='$(COMMON_ANDROID_PACKAGE_SUFFIX)'
      stem="package.apk"
    fi

    # Annotate extra privileges when required
    if [[ "$relSubRoot" == "priv-app" ]]; then
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
    if [[ "$relSubRoot" == "priv-app" && "$relRoot" == "vendor" ]]; then
      echo "[-] Privileged modules under /vendor/priv-app are not supported"
      abort 1
    fi

    # Pre-optimized APKs have their native libraries resources stripped from archive
    if [ -d "$appDir/lib" ]; then
      # Self-contained native libraries are copied across utilizing PRODUCT_COPY_FILES
      while read -r lib
      do
        echo "$lib" | sed "s#$inDir/##" >> "$RUNTIME_EXTRA_BLOBS_LIST"
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
        pkgs_SLinks+=("$dsoMName")
        apk_lib_slinks+="$(gen_apk_dso_symlink "$dsoName" "$dsoMName" "$dsoRoot" \
                           "$lcMPath/$pkgName" "$arch")"
        echo "${dsoRoot:1}/$dsoName" >> "$APK_SYSTEM_LIB_BLOBS_LIST"
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
        echo "LOCAL_REQUIRED_MODULES := ${pkgs_SLinks[@]}"
      fi
      echo "LOCAL_CERTIFICATE := $cert"
      echo "LOCAL_MODULE_CLASS := $class"
      if [[ "$priv" != "" ]]; then
        echo "$priv"
      fi
      echo "LOCAL_MODULE_SUFFIX := $suffix"

      # Deal with multi-lib
      if [[ ( -d "$appDir/oat/arm" && -d "$appDir/oat/arm64" ) ||
            ( -d "$appDir/oat/x86" && -d "$appDir/oat/x86_64" ) ]]; then
        echo "LOCAL_MULTILIB := both"
      elif [[ -d "$appDir/oat/arm" || -d "$appDir/oat/x86" ]]; then
        echo "LOCAL_MULTILIB := 32"
      fi

      # If the archive is resources only (no bytecode), don't optimize
      if zipinfo "$file" classes.dex &>/dev/null; then
        has_bc_file=true
      else
        has_bc_file=false
      fi

      if [[ "$ALLOW_PREOPT" = false || "$has_bc_file" = false || "$relSubRoot" =~ ^overlay/.* ]]; then
        echo "LOCAL_DEX_PREOPT := false"
      fi

      # Annotate overlay APKs
      if [[ "$relSubRoot" =~ ^overlay/.* ]]; then
        echo "LOCAL_IS_RUNTIME_RESOURCE_OVERLAY := true"
      fi

      echo 'include $(BUILD_PREBUILT)'

      # Append rules for APK lib symlinks if present
      if [[ "$apk_lib_slinks" != "" ]]; then
        echo -e "$apk_lib_slinks"
      fi
    } >> "$ANDROID_MK"

    # Also add pkgName to local runtime array to append later the vendor mk
    pkgs+=("$pkgName")

    # Add to global array
    ALL_BC_PKGS+=("$pkgName")
  done < <(find "$outBase/$relRoot/$relSubRoot" -type f -iname '*.apk' -o -iname '*.jar' | sort)

  # Update vendor mk
  {
    echo "# Prebuilt APKs/JARs from '$relRoot/$relSubRoot'"
    echo 'PRODUCT_PACKAGES += \'
    for pkg in "${pkgs[@]}"
    do
      echo "    $pkg \\"
    done
  }  >> "$DEVICE_VENDOR_MK"
  strip_trail_slash_from_file "$DEVICE_VENDOR_MK"

  # Update vendor mk again with symlink modules if present
  if [ ! -z "${pkgs_SLinks-}" ]; then
    {
      echo "# Prebuilt APKs libs symlinks from '$relRoot/$relSubRoot'"
      echo 'PRODUCT_PACKAGES += \'
      for module in "${pkgs_SLinks[@]}"
      do
        echo "    $module \\"
      done
    } >> "$DEVICE_VENDOR_MK"
    strip_trail_slash_from_file "$DEVICE_VENDOR_MK"
  fi
}

check_orphan_bytecode() {
  # Directly set to output directory so we can clean the orphans
  local parseDir="$1"
  local zipName="" fileExt="" pkgName=""

  while read -r file
  do
    zipName=$(basename "$file")
    fileExt="${zipName##*.}"
    pkgName=$(basename "$file" ".$fileExt")

    if array_contains "$pkgName" "${ALL_BC_PKGS[@]}"; then
      continue
    else
      echo "[!] Orphan bytecode file detected '$zipName' & removed"
      rm "$file"
    fi

  done < <(find "$parseDir" -type f -iname '*.apk' -o -iname '*.jar' | sort)
}

gen_mk_for_shared_libs() {
  local inDir="$1"
  local outBase="$2"

  local -a pkgs
  local -a multiDSO
  local dsoModule curFile

  # First iterate the 64bit libs to detect possible dual target modules
  for dsoModule in "${DSO_MODULES[@]}"
  do
    # Array is mixed so skip non-64bit libs
    if echo "$dsoModule" | grep -q "/lib/"; then
      continue
    fi

    curFile="$outBase/$(echo "$dsoModule" | sed "s#system/#proprietary/#")"

    # Check that configuration requested file exists
    if [ ! -f "$curFile" ]; then
      echo "[-] Failed to locate '$curFile' file"
      abort 1
    fi

    local dsoRelRoot="" dso32RelRoot="" dsoFile="" dsoName="" dsoSrc="" dso32Src=""

    dsoRelRoot=$(dirname "$curFile" | sed "s#$outBase/##")
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
      if [ -f "$outBase/$dso32Src" ]; then
        echo "LOCAL_MULTILIB := both"
        echo "LOCAL_SRC_FILES_32 := $dso32Src"

        # Cache dual-targets so that we don't include again when searching for
        # 32bit only libs under a 64bit system
        multiDSO+=("$dso32Src")
      else
        echo "LOCAL_MULTILIB := first"
      fi

      echo 'include $(BUILD_PREBUILT)'
    } >> "$ANDROID_MK"

    # Also add pkgName to runtime array to append later the vendor mk
    pkgs+=("$dsoName")
  done

  # Then iterate the 32bit libs excluding the ones already included as dual targets
  for dsoModule in "${DSO_MODULES[@]}"
  do
    # Array is mixed so skip non-64bit libs
    if echo "$dsoModule" | grep -q "/lib64/"; then
      continue
    fi

    curFile="$outBase/$(echo "$dsoModule" | sed "s#system/#proprietary/#")"

    # Check that configuration requested file exists
    if [ ! -f "$curFile" ]; then
      echo "[-] Failed to locate '$curFile' file"
      abort 1
    fi

    local dsoRelRoot="" dsoFile="" dsoName="" dsoSrc=""

    dsoRelRoot=$(dirname "$curFile" | sed "s#$outBase/##")
    dsoFile=$(basename "$curFile")
    dsoName=$(basename "$curFile" ".so")
    dsoSrc="$dsoRelRoot/$dsoFile"

    if [ ! -z "${multiDSO-}" ]; then
      if array_contains "$dsoSrc" "${multiDSO[@]}"; then
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
    pkgs+=("$dsoName")
  done

  # Update vendor mk
  if [ ! -z "${pkgs-}" ]; then
    {
      echo "# Prebuilt shared libraries"
      echo 'PRODUCT_PACKAGES += \'
      for pkg in "${pkgs[@]}"
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
    echo 'AB_OTA_PARTITIONS += vendor \'
    for partition in "${EXTRA_IMGS[@]}"
    do
      echo "    $partition \\"
    done
  }  >> "$outMk"
  strip_trail_slash_from_file "$outMk"
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
    echo "expected_build_id := \$(shell cat vendor/$VENDOR_DIR/$DEVICE/build_id.txt)"
    echo 'ifneq ($(BUILD_ID),$(expected_build_id))'
    echo '    $(error "Expected BUILD_ID is $(expected_build_id) and currently building with $(BUILD_ID)")'
    echo 'endif'
    echo ""
    echo "include vendor/$VENDOR_DIR/$DEVICE/AndroidBoardVendor.mk"
  } >> "$ANDROID_MK"

  for root in "vendor" "proprietary"
  do
    for path in "${SUBDIRS_WITH_BC[@]}"
    do
      if [ -d "$OUTPUT_VENDOR/$root/$path" ]; then
        echo "[*] Gathering data from '$root/$path' APK/JAR pre-builts"
        gen_mk_for_bytecode "$INPUT_DIR" "$root" "$path" "$OUTPUT_VENDOR"
      fi
    done
  done

  # Ensure that no bytecode files are included without generating a matching module
  check_orphan_bytecode "$OUTPUT_VENDOR"

  if [ "$HAS_STANDALONE_SLINKS" = true ]; then
    echo "[*] Processing standalone symlinks"
    gen_standalone_symlinks "$INPUT_DIR"
  fi

  # Iterate over directories with shared libraries and update the unified Android.mk file
  if [ "$HAS_DSO_MODULES" = true ]; then
    echo "[*] Generating shared library individual pre-built modules"
    gen_mk_for_shared_libs "$INPUT_DIR" "$OUTPUT_VENDOR"
  fi

  # Append extra modules if present
  if [[ "$EXTRA_MODULES" != "" ]]; then
    {
      echo ""
      echo "$EXTRA_MODULES"
    } >> "$ANDROID_MK"
  fi

  # Finally close master Android.mk
  {
    echo ""
    echo "endif"
  } >> "$ANDROID_MK"
}

strip_trail_slash_from_file() {
  local inFile="$1"

  sed '$s# \\#\'$'\n#' "$inFile" > "$inFile.tmp"
  mv "$inFile.tmp" "$inFile"
}

gen_sigs_file() {
  local inDir="$1"
  local sigsFile="$2"
  > "$sigsFile"

  find "$inDir"/vendor* -type f ! -name "file_signatures.txt" | sort | while read -r file
  do
    shasum -a1 "$file" | sed "s#$inDir/##" >> "$sigsFile"
  done
}

setOverlaysDir() {
  local relDir
  relDir="$(jqRawStr "$API_LEVEL" "$CONFIG_TYPE" "overlays-dir" "$CONFIG_FILE")"
  if [[ "$relDir" == "" ]]; then
    echo ""
  else
    echo "$DEVICE_CONFIG_DIR/$relDir"
  fi
}

initConfig() {
  local mkFile="$1"
  mkdir -p "$(dirname "$mkFile")"
  > "$mkFile"
}

trap "abort 1" SIGINT SIGTERM
. "$REALPATH_SCRIPT"
. "$CONSTS_SCRIPT"
. "$COMMON_SCRIPT"

INPUT_DIR=""
AOSP_ROOT=""
OUTPUT_DIR=""
CONFIG_FILE=""
CONFIG_TYPE="naked"
API_LEVEL=""
ALLOW_PREOPT=false
FORCE_VIMG=false

DEVICE_CONFIG_DIR=""
DEVICE=""
DEVICE_FAMILY=""
VENDOR=""
APK_SYSTEM_LIB_BLOBS_LIST="$TMP_WORK_DIR/apk_system_lib_blobs.txt"
RUNTIME_EXTRA_BLOBS_LIST="$TMP_WORK_DIR/runtime_extra_blobs.txt"
EXEC_DATE="$(date +%Y-%m-%d)"

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
    --aosp-root)
      AOSP_ROOT=$(echo "$2" | sed 's:/*$::')
      shift
      ;;
    --conf-file)
      CONFIG_FILE="$2"
      shift
      ;;
    --conf-type)
      CONFIG_TYPE="$2"
      shift
      ;;
    --api)
      API_LEVEL="$2"
      shift
      ;;
    --allow-preopt)
      ALLOW_PREOPT=true
      ;;
    --force-vimg)
      FORCE_VIMG=true
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
check_file "$CONFIG_FILE" "Device Config File"

# Check if valid config type & API level
isValidConfigType "$CONFIG_TYPE"
isValidApiLevel "$API_LEVEL"

# Populate config files from base conf dir
readonly DEVICE_CONFIG_DIR="$(dirname "$CONFIG_FILE")"
readonly BLOBS_LIST="$DEVICE_CONFIG_DIR/proprietary-blobs.txt"
readonly OVERLAYS_DIR="$(setOverlaysDir)"
readonly DEP_DSO_BLOBS_LIST="$(jqIncRawArray "$API_LEVEL" "$CONFIG_TYPE" "dep-dso" "$CONFIG_FILE" | grep -Ev '(^#|^$)')"
readonly MK_FLAGS_LIST="$(jqIncRawArray "$API_LEVEL" "$CONFIG_TYPE" "BoardConfigVendor" "$CONFIG_FILE")"
readonly DEVICE_VENDOR_CONFIG="$(jqIncRawArray "$API_LEVEL" "$CONFIG_TYPE" "device-vendor" "$CONFIG_FILE")"
readonly EXTRA_MODULES="$(jqIncRawArray "$API_LEVEL" "$CONFIG_TYPE" "new-modules" "$CONFIG_FILE")"
readonly FORCE_MODULES="$(jqIncRawArray "$API_LEVEL" "$CONFIG_TYPE" "forced-modules" "$CONFIG_FILE")"
readonly EXTRA_IMGS_LIST="$(jqIncRawArrayTop "extra-partitions" "$CONFIG_FILE")"

# Populate the array with the APK that need to maintain their signature
readarray -t PSIG_BC_FILES < <(
 grep -E ':PRESIGNED$' "$BLOBS_LIST" | cut -d ":" -f1 | while read -r apk; do
  basename "$apk"; done
)

# Verify input directory structure
verify_input "$INPUT_DIR"

# Get device details
DEVICE=$(get_device_codename "$INPUT_DIR/system/build.prop")
DEVICE_FAMILY="$(jqRawStrTop "device-family" "$CONFIG_FILE")"
VENDOR=$(get_vendor "$INPUT_DIR/system/build.prop")
VENDOR_DIR="$(jqRawStrTop "aosp-vendor-dir" "$CONFIG_FILE")"
RADIO_VER=$(get_radio_ver "$INPUT_DIR/system/build.prop")
BOOTLOADER_VER=$(get_bootloader_ver "$INPUT_DIR/system/build.prop")
BUILD_ID=$(get_build_id "$INPUT_DIR/system/build.prop")
if [[ "$EXTRA_IMGS_LIST" != "" ]]; then
  readarray -t EXTRA_IMGS < <(echo "$EXTRA_IMGS_LIST")
fi


echo "[*] Generating '$DEVICE' vendor blobs"

# Prepare vendor output directory structure
OUTPUT_VENDOR="$OUTPUT_DIR/vendor/$VENDOR_DIR/$DEVICE"
if [ -d "$OUTPUT_VENDOR" ]; then
  rm -rf "${OUTPUT_VENDOR:?}"/*
fi
PROP_EXTRACT_BASE="$OUTPUT_VENDOR/proprietary"
mkdir -p "$PROP_EXTRACT_BASE"

if [[ "$DEVICE" != "$DEVICE_FAMILY" ]]; then
  # We don't clean here since we might corrupt other device configurations
  # if output is directly set to AOSP root
  mkdir -p "$OUTPUT_DIR/vendor/$VENDOR_DIR/$DEVICE_FAMILY"
fi

# Prepare vendor overlays output directory structure
readonly REL_VENDOR_OVERLAY="vendor_overlay/$VENDOR_DIR/$DEVICE/overlay"
OUTPUT_VENDOR_OVERLAY="$OUTPUT_DIR/$REL_VENDOR_OVERLAY"
if [ -d "$OUTPUT_VENDOR_OVERLAY" ]; then
  rm -rf "${OUTPUT_VENDOR_OVERLAY:?}"/*
fi

# Don't generate folder if no overlays configured
if [[ "$OVERLAYS_DIR" != "" ]]; then
  mkdir -p "$OUTPUT_VENDOR_OVERLAY"
fi

# Prepare generated makefiles
# Master ones included from AOSP device profiles
ANDROID_MK="$OUTPUT_DIR/vendor/$VENDOR_DIR/$(jqRawStrTop "AndroidMk" "$CONFIG_FILE")"
DEVICE_VENDOR_MK="$OUTPUT_DIR/vendor/$VENDOR_DIR/$(jqRawStrTop "DeviceVendorMk" "$CONFIG_FILE")"
BOARD_CONFIG_VENDOR_MK="$OUTPUT_DIR/vendor/$VENDOR_DIR/$(jqRawStrTop "BoardConfigVendorMk" "$CONFIG_FILE")"

# Helper ones to be included from the ones we generate
DEVICE_VENDOR_BLOBS_MK="$OUTPUT_VENDOR/$DEVICE-vendor-blobs.mk";
ANDROID_BOARD_VENDOR_MK="$OUTPUT_VENDOR/AndroidBoardVendor.mk";

initConfig "$DEVICE_VENDOR_MK"
initConfig "$DEVICE_VENDOR_BLOBS_MK"
initConfig "$BOARD_CONFIG_VENDOR_MK"
initConfig "$ANDROID_BOARD_VENDOR_MK"
initConfig "$ANDROID_MK"

# And prefix them
find "$OUTPUT_DIR/vendor/$VENDOR_DIR" -type f -name '*.mk' | while read -r file
do
  echo -e "# [$EXEC_DATE] Auto-generated file, do not edit\n" > "$file"
done

# Update from DSO_MODULES array from DEP_DSO_BLOBS_LIST
if [[ "$DEP_DSO_BLOBS_LIST" != "" ]]; then
  readarray -t DSO_MODULES < <(echo "$DEP_DSO_BLOBS_LIST")
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

# Append items listed in device vendor configuration file
{
  if [[ "$DEVICE_VENDOR_CONFIG" != "" ]]; then
    echo "$DEVICE_VENDOR_CONFIG"
    echo ""
  fi
} >> "$DEVICE_VENDOR_MK"

# Activate & populate overlay directory if overlays defined in device config
if [[ "$OVERLAYS_DIR" != "" ]]; then
  cp -a "$OVERLAYS_DIR"/* "$OUTPUT_VENDOR_OVERLAY"
  echo -e "PRODUCT_PACKAGE_OVERLAYS += $REL_VENDOR_OVERLAY\n" >> "$DEVICE_VENDOR_MK"
fi

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
fi
if [ -f "$APK_SYSTEM_LIB_BLOBS_LIST" ]; then
  echo "[*] Processing additional runtime generated product files from APK symlinks"
  extract_blobs "$APK_SYSTEM_LIB_BLOBS_LIST" "$INPUT_DIR" "$OUTPUT_VENDOR"
  update_vendor_blobs_mk "$APK_SYSTEM_LIB_BLOBS_LIST"

  cat "$APK_SYSTEM_LIB_BLOBS_LIST" >> "$BLOBS_LIST"
fi
sort "$BLOBS_LIST" > "$BLOBS_LIST.tmp"
mv "$BLOBS_LIST.tmp" "$BLOBS_LIST"

if [[ "$VENDOR" == "google" ]]; then
  update_ab_ota_partitions "$DEVICE_VENDOR_MK"
fi

# Generate file signatures list
echo "[*] Generating signatures file"
gen_sigs_file "$OUTPUT_DIR" "$OUTPUT_VENDOR/file_signatures.txt"

# Can be used from AOSP build infrastructure to verify that build is performed
# against a matching factory images vendor blobs extract
echo "[*] Generating build_id file"
echo "$BUILD_ID" > "$OUTPUT_VENDOR/build_id.txt"

if [[ "$AOSP_ROOT" != "" ]]; then
  mkdir -p "$AOSP_ROOT/vendor/$VENDOR_DIR/$DEVICE"

  # Device name does not match device family (e.g. sailfish)
  if [[ "$DEVICE" != "$DEVICE_FAMILY" ]]; then
    mkdir -p "$AOSP_ROOT/vendor/$VENDOR_DIR/$DEVICE_FAMILY"

    # Soft update for device family dir so that co-existing configs are not affected
    rsync -arz "$OUTPUT_DIR/vendor/$VENDOR_DIR/$DEVICE_FAMILY/" "$AOSP_ROOT/vendor/$VENDOR_DIR/$DEVICE_FAMILY" || {
      echo "[-] rsync failed"
      abort 1
    }

    # Force update for device (--delete old copies no longer present)
    rsync -arz --delete "$OUTPUT_DIR/vendor/$VENDOR_DIR/$DEVICE/" "$AOSP_ROOT/vendor/$VENDOR_DIR/$DEVICE" || {
      echo "[-] rsync failed"
      abort 1
    }
  else
    rsync -arz --delete "$OUTPUT_DIR/vendor/$VENDOR_DIR/$DEVICE/" "$AOSP_ROOT/vendor/$VENDOR_DIR/$DEVICE" || {
      echo "[-] rsync failed"
      abort 1
    }
  fi
  echo "[*] Vendor blobs copied to '$AOSP_ROOT/vendor/$VENDOR_DIR'"

  # Vendor overlays are always under separate directories so it's safe to force update
  if [[ "$OVERLAYS_DIR" != "" ]]; then
    mkdir -p "$AOSP_ROOT/vendor_overlay/$VENDOR_DIR"
    rsync -arz --delete "$OUTPUT_DIR/vendor_overlay/$VENDOR_DIR/" "$AOSP_ROOT/vendor_overlay/$VENDOR_DIR/" || {
      echo "[-] rsync failed"
      abort 1
    }
    echo "[*] Vendor overlays copied to '$AOSP_ROOT/vendor_overlay/$VENDOR_DIR'"
  fi
fi

abort 0
