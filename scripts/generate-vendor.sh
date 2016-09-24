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

readonly TMP_WORK_DIR=$(mktemp -d /tmp/android_vendor_setup.XXXXXX) || exit 1
declare -a sysTools=("cp" "sed" "zipinfo" "jarsigner" "awk")
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

# Some shared libraries under are required as dependencies so we need to create
# individual modules for them
declare -a DSO_MODULES
hasDsoModules=false

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
      --blobs-list    : Text file with list of proprietary blobs to copy
      --dep-dso-list  : Text file with list of shared libraries that required to be
                        included as a separate module
      --flags-list    : Text file with list of Makefile flags to be appended at
                        'BoardConfigVendor.mk'
      --extra-modules : Text file additional modules to be appended at master vendor
                        'Android.mk'
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
  local device

  device=$(grep 'ro.product.device=' "$1" | cut -d '=' -f2 | \
           tr '[:upper:]' '[:lower:]')
  if [[ "$device" == "" ]]; then
    echo "[-] Device string not found"
    abort 1
  fi
  echo "$device"
}

get_vendor() {
  local vendor

  vendor=$(grep 'ro.product.manufacturer=' "$1" | cut -d '=' -f2 | \
           tr '[:upper:]' '[:lower:]')
  if [[ "$vendor" == "" ]]; then
    echo "[-] Device codename string not found"
    abort 1
  fi
  echo "$vendor"
}

get_radio_ver() {
  local radio_ver
  radio_ver=$(grep 'ro.build.expect.baseband' "$1" | cut -d '=' -f2)
  if [[ "$radio_ver" == "" ]]; then
    echo "[-] Failed to identify radio version"
    abort 1
  fi
  echo "$radio_ver"
}

get_bootloader_ver() {
  local bootloader_ver
  bootloader_ver=$(grep 'ro.build.expect.bootloader' "$1" | cut -d '=' -f2)
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
  _resolve_symlinks "$INBASE/$RELTARGET"
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
  cp -a "$INDIR/radio/radio"* "$OUTDIR/radio/radio-$DEVICE-$RADIO_VER.img" || {
    echo "[-] Failed to copy radio image"
    abort 1
  }

  cp -a "$INDIR/radio/bootloader"* "$OUTDIR/radio/bootloader-$DEVICE-$BOOTLOADER_VER.img" || {
    echo "[-] Failed to copy bootloader image"
    abort 1
  }
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
  local openTag=""

  while read -r file
  do
    # Input format follows AOSP compatibility allowing optional save at relative path
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
      openTag=$(grep '^<?xml version' "$outBase/$dst")
      grep -v '^<?xml version' "$outBase/$dst" > "$TMP_WORK_DIR/xml_fixup.tmp"
      echo "$openTag" > "$outBase/$dst"
      cat "$TMP_WORK_DIR/xml_fixup.tmp" >> "$outBase/$dst"
      rm "$TMP_WORK_DIR/xml_fixup.tmp"
    fi
  done < <(grep -Ev '(^#|^$)' "$BLOBS_LIST")
}

gen_vendor_blobs_mk() {
  local BLOBS_LIST="$1"
  local OUTDIR="$2"

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
    # Skip files that have dedicated target module (APKs, JARs & selected shared libraries)
    fileExt="${file##*.}"
    if [[ "$fileExt" == "apk" || "$fileExt" == "jar" ]]; then
      continue
    fi
    if [[ $hasDsoModules = true && "$fileExt" == "so" ]]; then
      if array_contains "$file" "${DSO_MODULES[@]}"; then
        continue
      fi
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
  done < <(grep -Ev '(^#|^$)' "$BLOBS_LIST")

  # Trim last backslash
  sed '$s/ \\//' "$OUTMK" > "$OUTMK.tmp"
  mv "$OUTMK.tmp" "$OUTMK"
}

gen_dev_vendor_mk() {
  local OUTDIR="$1"
  local OUTMK="$OUTDIR/device-vendor.mk"

  {
    echo "# Auto-generated file, do not edit"
    echo ""
    echo "\$(call inherit-product, vendor/$VENDOR/$DEVICE/$DEVICE-vendor-blobs.mk)"
  } > "$OUTMK"
}

gen_board_vendor_mk() {
  local OUTDIR="$1"
  local OUTMK="$OUTDIR/AndroidBoardVendor.mk"

  {
    echo "# Auto-generated file, do not edit"
    echo ""
    echo 'LOCAL_PATH := $(call my-dir)'
    echo ""
    echo "\$(call add-radio-file,radio/bootloader-$DEVICE-$BOOTLOADER_VER.img,version-bootloader)"
    echo "\$(call add-radio-file,radio/radio-$DEVICE-$RADIO_VER.img,version-baseband)"
  } > "$OUTMK"
}

gen_board_cfg_mk() {
  local INDIR="$1"
  local OUTDIR="$2"
  local OUTMK="$OUTDIR/BoardConfigVendor.mk"

  local v_img_sz

  # First lets check if vendor partition size has been extracted from
  # previous data extraction script
  v_img_sz="$(has_vendor_size "$INDIR")"

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
    echo "TARGET_BOARD_INFO_FILE := vendor/$VENDOR/$DEVICE/vendor-board-info.txt"
    echo 'BOARD_VENDORIMAGE_FILE_SYSTEM_TYPE := ext4'
    echo "BOARD_VENDORIMAGE_PARTITION_SIZE := $v_img_sz"

    # Update with user selected extra flags
    grep -Ev '(^#|^$)' "$MK_FLAGS_LIST" || true
  } > "$OUTMK"
}

gen_board_info_txt() {
  local OUTDIR="$1"
  local OUTTXT="$OUTDIR/vendor-board-info.txt"

  {
    echo "require board=$DEVICE"
    echo "require version-bootloader=$BOOTLOADER_VER"
    echo "require version-baseband=$RADIO_VER"
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

    # Annotate extra privileges when required
    if [[ "$RELSUBROOT" == "priv-app" ]]; then
      priv='LOCAL_PRIVILEGED_MODULE := true'
    fi

    # APKs under /vendor should not be optimized & always use the PRESIGNED cert
    if [[ "$fileExt" == "apk" && "$RELROOT" == "vendor" ]]; then
      cert="PRESIGNED"
    elif [[ "$fileExt" == "apk" ]]; then
      # All other APKs have been repaired & thus need resign
      cert="platform"
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

    # Some prebuilt APKs have also prebuilt JNI libs that are stored under
    # system-wide lib directories, with app directory containing a symlink to.
    # Resolve such cases to adjust includes so that we don't copy across the
    # same file twice.
    if [ -d "$appDir/lib" ]; then
      while read -r lib
      do
        hasApkSymLinks=true

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
        echo "LOCAL_REQUIRED_MODULES := ${PKGS_SLINKS[@]-}"
      fi
      echo "LOCAL_CERTIFICATE := $cert"
      echo "LOCAL_MODULE_CLASS := $class"
      if [[ "$priv" != "" ]]; then
        echo "$priv"
      fi
      echo "LOCAL_MODULE_SUFFIX := $suffix"
      echo "LOCAL_DEX_PREOPT := false"
      echo 'include $(BUILD_PREBUILT)'

      # Append rules for APK lib symlinks if present
      if [[ "$apk_lib_slinks" != "" ]]; then
        echo -e "$apk_lib_slinks"
      fi
    } >> "$OUTMK"

    # Also add pkgName to runtime array to append later the vendor mk
    PKGS=("${PKGS[@]-}" "$pkgName")
  done < <(find "$OUTBASE/$RELROOT/$RELSUBROOT" -maxdepth 2 \
           -type f -iname '*.apk' -o -iname '*.jar' | sort)

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

gen_mk_for_shared_libs() {
  local INDIR="$1"
  local RELROOT="$2"
  local OUTBASE="$3"
  local VENDOR="$4"
  local OUTMK="$5"

  local VENDORMK="$OUTBASE/device-vendor.mk"
  local -a PKGS
  local hasPKGS=false
  local -a MULTIDSO
  local hasMultiDSO=false

  # If target is multi-lib we first iterate the 64bit libs to detect possible
  # dual target modules
  if [ -d "$OUTBASE/$RELROOT/lib64" ]; then
    while read -r file
    do
      local dsoRelRoot=""
      local dso32RelRoot=""
      local dsoFile=""
      local dsoName=""
      local dsoSrc=""
      local dso32Src=""

      dsoRelRoot=$(dirname "$file" | sed "s#$OUTBASE/##")
      dsoFile=$(basename "$file")
      dsoName=$(basename "$file" ".so")
      dsoSrc="$dsoRelRoot/$dsoFile"

      dso32RelRoot=$(echo "$dsoRelRoot" | sed "s#lib64#lib#")
      dso32Src="$dso32RelRoot/$dsoFile"

      # TODO: Instead of iterate all and skip, go with the whitelist array
      # directly. This is a temporarily hack to ensure that approach is working
      # as expected before finalizing
      if [[ "$RELROOT" == "proprietary" ]]; then
        dsoRealRel="$(echo "$dsoSrc" | sed "s#proprietary/#system/#")"
      else
        dsoRealRel="$dsoSrc"
      fi

      if [ $hasDsoModules = true ]; then
        if ! array_contains "$dsoRealRel" "${DSO_MODULES[@]}"; then
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

        if [[ "$RELROOT" == "vendor" ]]; then
          echo "LOCAL_PROPRIETARY_MODULE := true"
        fi

        # In case 32bit version present - upgrade to dual target
        if [ -f "$OUTBASE/$dso32Src" ]; then
          echo "LOCAL_MULTILIB := both"
          echo "LOCAL_SRC_FILES_32 := $dso32Src"

          # Cache dual-targets so that we don't include again when searching for
          # 32bit only libs under a 64bit system
          MULTIDSO=("${MULTIDSO[@]-}" "$dso32Src")
          hasMultiDSO=true
        else
          echo "LOCAL_MULTILIB := first"
        fi

        echo 'include $(BUILD_PREBUILT)'
      } >> "$OUTMK"

      # Also add pkgName to runtime array to append later the vendor mk
      PKGS=("${PKGS[@]-}" "$dsoName")
      hasPKGS=true
    done < <(find "$OUTBASE/$RELROOT/lib64" -maxdepth 1 -type f -iname 'lib*.so' | sort)
  fi

  # Then iterate the 32bit libs excluding the ones already included as dual targets
  while read -r file
  do
    local dsoRelRoot=""
    local dsoFile=""
    local dsoName=""
    local dsoSrc=""

    dsoRelRoot=$(dirname "$file" | sed "s#$OUTBASE/##")
    dsoFile=$(basename "$file")
    dsoName=$(basename "$file" ".so")
    dsoSrc="$dsoRelRoot/$dsoFile"

    # TODO: Instead of iterate all and skip, go with the whitelist array
    # directly. This is a temporarily hack to ensure that approach is working
    # as expected before finalizing
    if [[ "$RELROOT" == "proprietary" ]]; then
      dsoRealRel="$(echo "$dsoSrc" | sed "s#proprietary/#system/#")"
    else
      dsoRealRel="$dsoSrc"
    fi

    if [ $hasDsoModules = true ]; then
      if ! array_contains "$dsoRealRel" "${DSO_MODULES[@]}"; then
        continue
      fi
    fi

    if [ $hasMultiDSO = true ]; then
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

      if [[ "$RELROOT" == "vendor" ]]; then
        echo "LOCAL_PROPRIETARY_MODULE := true"
      fi

      echo "LOCAL_MULTILIB := 32"
      echo 'include $(BUILD_PREBUILT)'
    } >> "$OUTMK"

    # Also add pkgName to runtime array to append later the vendor mk
    PKGS=("${PKGS[@]-}" "$dsoName")
    hasPKGS=true
  done < <(find "$OUTBASE/$RELROOT/lib" -maxdepth 1 -type f -iname 'lib*.so' | sort)

  # Update vendor mk
  if [ $hasPKGS = true ]; then
    {
      echo ""
      echo "# Prebuilt shared libraries from '$RELROOT'"
      echo 'PRODUCT_PACKAGES += \'
      for pkg in ${PKGS[@]}
      do
        echo "    $pkg \\"
      done
    }  >> "$VENDORMK"
    sed '$s/ \\//' "$VENDORMK" > "$VENDORMK.tmp"
    mv "$VENDORMK.tmp" "$VENDORMK"
  fi
}

trap "abort 1" SIGINT SIGTERM
. "$REALPATH_SCRIPT"

INPUT_DIR=""
OUTPUT_DIR=""
BLOBS_LIST=""
DEP_DSO_BLOBS_LIST=""
MK_FLAGS_LIST=""
EXTRA_MODULES=""

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
  echo "[-] Vendor proprietary-blobs file not found"
  usage
fi
if [[ "$DEP_DSO_BLOBS_LIST" == "" || ! -f "$DEP_DSO_BLOBS_LIST" ]]; then
  echo "[-] Vendor dep-dso-proprietary file not found"
  usage
fi
if [[ "$MK_FLAGS_LIST" == "" || ! -f "$MK_FLAGS_LIST" ]]; then
  echo "[-] Vendor vendor-config file not found"
  usage
fi
if [[ "$EXTRA_MODULES" == "" || ! -f "$EXTRA_MODULES" ]]; then
  echo "[-] Vendor extra modules file not found"
  usage
fi

# Verify input directory structure
verify_input "$INPUT_DIR"

# Get device details
DEVICE=$(get_device_codename "$INPUT_DIR/system/build.prop")
VENDOR=$(get_vendor "$INPUT_DIR/system/build.prop")
RADIO_VER=$(get_radio_ver "$INPUT_DIR/system/build.prop")
BOOTLOADER_VER=$(get_bootloader_ver "$INPUT_DIR/system/build.prop")

echo "[*] Generating blobs for vendor/$VENDOR/$DEVICE"

# Clean-up output
OUTPUT_VENDOR="$OUTPUT_DIR/vendor/$VENDOR/$DEVICE"
PROP_EXTRACT_BASE="$OUTPUT_VENDOR/proprietary"
if [ -d "$OUTPUT_VENDOR" ]; then
  rm -rf "${OUTPUT_VENDOR:?}"/*
fi
mkdir -p "$PROP_EXTRACT_BASE"

# Update from DSO_MODULES array from DEP_DSO_BLOBS_LIST file
entries=$(grep -Ev '(^#|^$)' "$DEP_DSO_BLOBS_LIST" | wc -l | tr -d ' ')
if [ $entries -gt 0 ]; then
  readarray -t DSO_MODULES < <(grep -Ev '(^#|^$)' "$DEP_DSO_BLOBS_LIST")
  hasDsoModules=true
fi

# Copy radio images
echo "[*] Copying radio files '$OUTPUT_VENDOR'"
copy_radio_files "$INPUT_DIR" "$OUTPUT_VENDOR"

# Copy device specific files from input
echo "[*] Copying files to '$OUTPUT_VENDOR'"
extract_blobs "$BLOBS_LIST" "$INPUT_DIR" "$OUTPUT_VENDOR"

# Generate $DEVICE-vendor-blobs.mk makefile (plain files that don't require a target module)
echo "[*] Generating '$DEVICE-vendor-blobs.mk' makefile"
gen_vendor_blobs_mk "$BLOBS_LIST" "$OUTPUT_VENDOR"

# Generate device-vendor.mk makefile (will be updated later)
echo "[*] Generating 'device-vendor.mk'"
gen_dev_vendor_mk "$OUTPUT_VENDOR"

# Generate AndroidBoardVendor.mk with radio stuff (baseband & bootloader)
echo "[*] Generating 'AndroidBoardVendor.mk'"
gen_board_vendor_mk $OUTPUT_VENDOR
echo "  [*] Bootloader:$BOOTLOADER_VER"
echo "  [*] Baseband:$RADIO_VER"


# Generate BoardConfigVendor.mk (vendor partition type)
echo "[*] Generating 'BoardConfigVendor.mk'"
gen_board_cfg_mk "$INPUT_DIR" "$OUTPUT_VENDOR"

# Generate vendor-board-info.txt with baseband & bootloader versions
echo "[*] Generating 'vendor-board-info.txt'"
gen_board_info_txt "$OUTPUT_VENDOR"

# Iterate over directories with bytecode and generate a unified Android.mk file
echo "[*] Generating 'Android.mk'"

OUTMK="$OUTPUT_VENDOR/Android.mk"
{
  echo "# Auto-generated file, do not edit"
  echo ""
  echo 'LOCAL_PATH := $(call my-dir)'
  echo "ifeq (\$(TARGET_DEVICE),$DEVICE)"
  echo "include vendor/$VENDOR/$DEVICE/AndroidBoardVendor.mk"
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

# Iterate over directories with shared libraries and update the unified Android.mk file
if [ $hasDsoModules = true ]; then
  echo "[*] Gathering data for shared library (.so) pre-built modules"
  for root in "vendor" "proprietary"
  do
    gen_mk_for_shared_libs "$INPUT_DIR" "$root" "$OUTPUT_VENDOR" "$VENDOR" "$OUTMK"
  done
fi

# Append extra modules & close master Android.mk
{
  echo ""
  cat "$EXTRA_MODULES"
  echo ""
  echo "endif"
} >> "$OUTMK"

# Add extra module targets to PRODUCT_PACKAGES list
VENDORMK="$OUTPUT_VENDOR/device-vendor.mk"
{
  echo ""
  echo "# Extra modules from user configuration"
  echo 'PRODUCT_PACKAGES += \'
  grep 'LOCAL_MODULE :=' "$EXTRA_MODULES" | cut -d "=" -f2- | \
    awk '{$1=$1;print}' | while read -r module
  do
    echo "    $module \\"
  done
} >> "$VENDORMK"
sed '$s/ \\//' "$VENDORMK" > "$VENDORMK.tmp"
mv "$VENDORMK.tmp" "$VENDORMK"

abort 0
