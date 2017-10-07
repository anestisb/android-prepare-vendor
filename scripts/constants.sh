#!/usr/bin/env bash

# Ensure script is sourced
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && exit 1

# List of supported devices
declare -ra SUPPORTED_DEVICES=("bullhead" "flounder" "angler" "sailfish" "marlin")

# URLs to download factory images from
readonly NID_URL="https://google.com"
readonly GURL="https://developers.google.com/android/nexus/images"
readonly TOSURL="https://developers.google.com/profile/acknowledgeNotification"

# oatdump dependencies URLs as compiled from AOSP matching API levels
readonly L_OATDUMP_URL_API23='https://onedrive.live.com/download?cid=D1FAC8CC6BE2C2B0&resid=D1FAC8CC6BE2C2B0%21490&authkey=ACA4f4Zvs3Tb_SY'
readonly D_OATDUMP_URL_API23='https://onedrive.live.com/download?cid=D1FAC8CC6BE2C2B0&resid=D1FAC8CC6BE2C2B0%21493&authkey=AJ0rWu5Ci8tQNLY'
readonly L_OATDUMP_URL_API24='https://onedrive.live.com/download?cid=D1FAC8CC6BE2C2B0&resid=D1FAC8CC6BE2C2B0%21492&authkey=AE4uqwH-THvvkSQ'
readonly D_OATDUMP_URL_API24='https://onedrive.live.com/download?cid=D1FAC8CC6BE2C2B0&resid=D1FAC8CC6BE2C2B0%21491&authkey=AHvCaYwFBPYD4Fs'
readonly L_OATDUMP_URL_API25='https://onedrive.live.com/download?cid=D1FAC8CC6BE2C2B0&resid=D1FAC8CC6BE2C2B0%21503&authkey=AKDpBAzhzum6d7w'
readonly D_OATDUMP_URL_API25='https://onedrive.live.com/download?cid=D1FAC8CC6BE2C2B0&resid=D1FAC8CC6BE2C2B0%21504&authkey=AC5YFNSAZ31-W3o'
readonly L_OATDUMP_URL_API26='https://onedrive.live.com/download?cid=D1FAC8CC6BE2C2B0&resid=D1FAC8CC6BE2C2B0%21557&authkey=AG47qhXu164sYwc'
readonly D_OATDUMP_URL_API26='https://onedrive.live.com/download?cid=D1FAC8CC6BE2C2B0&resid=D1FAC8CC6BE2C2B0%21561&authkey=ABu-oqJbQDwQ-ZQ'

readonly L_OATDUMP_API23_SIG='688f1c1f97e3b9eb32702c60ca05abbf313bc98a25334aa3ed4a108095162244'
readonly D_OATDUMP_API23_SIG='688f1c1f97e3b9eb32702c60ca05abbf313bc98a25334aa3ed4a108095162244'
readonly L_OATDUMP_API24_SIG='1f99e7d0f2894cfe52fb7f2a24d5076f217977cbb1a46fafdf5ea38b0a11adce'
readonly D_OATDUMP_API24_SIG='4a7f5614eb04d9bea85bfa05853523843f9cc80a64eab4c98efed2f70ed3d90e'
readonly L_OATDUMP_API25_SIG='8b8cd18f08afd00fc6bf33d5b7f5be4faab9f39849b258bade5d15c3e5f33ce8'
readonly D_OATDUMP_API25_SIG='97f26b40cdc1fb2b5e5babe7ff8c63b70e7d3a3ab8dee19b035bbb0fdfa5477e'
readonly L_OATDUMP_API26_SIG='b0fba0d6ceae8e921c11ce5b7325da6ca885628243bf19b5679530d7196f18bf'
readonly D_OATDUMP_API26_SIG='7b3543b862e0a3298ce50e8f5c4b7c4b56950170f0248b25ee13bc757004ea8d'

# sub-directories that contain bytecode archives
declare -ra SUBDIRS_WITH_BC=("app" "framework" "priv-app" "overlay/Pixel")

# Files to skip from vendor partition when parsing factory images (for all configs)
declare -ra VENDOR_SKIP_FILES=(
  "build.prop"
  "compatibility_matrix.xml"
  "default.prop"
  "etc/NOTICE.xml.gz"
  "etc/wifi/wpa_supplicant.conf"
  "manifest.xml"
)

# Files to skip from vendor partition when parsing factory images (for naked config only)
declare -ra VENDOR_SKIP_FILES_NAKED=(
  "etc/selinux/nonplat_file_contexts"
  "etc/selinux/nonplat_hwservice_contexts"
  "etc/selinux/nonplat_mac_permissions.xml"
  "etc/selinux/nonplat_property_contexts"
  "etc/selinux/nonplat_seapp_contexts"
  "etc/selinux/nonplat_sepolicy.cil"
  "etc/selinux/nonplat_service_contexts"
  "etc/selinux/plat_sepolicy_vers.txt"
  "etc/selinux/precompiled_sepolicy"
  "etc/selinux/precompiled_sepolicy.plat_and_mapping.sha256"
  "etc/selinux/vndservice_contexts"
)

declare -ra PIXEL_AB_PARTITIONS=(
  "aboot"
  "apdp"
  "bootlocker"
  "cmnlib32"
  "cmnlib64"
  "devcfg"
  "hosd"
  "hyp"
  "keymaster"
  "modem"
  "pmic"
  "rpm"
  "tz"
  "xbl"
)
