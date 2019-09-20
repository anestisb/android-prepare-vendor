#!/usr/bin/env bash

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && exit 1

# List of supported devices
declare -ra SUPPORTED_DEVICES=(
  "bullhead"      # Nexus 5x
  "flounder"      # Nexus 9
  "angler"        # Nexus 6p
  "sailfish"      # Pixel
  "marlin"        # Pixel XL
  "walleye"       # Pixel 2
  "taimen"        # Pixel 2 XL
  "blueline"      # Pixel 3
  "crosshatch"    # Pixel 3 XL
  "sargo"	  # Pixel 3a
  "bonito"	  # Pixel 3a XL
)

# URLs to download factory images from
readonly NID_URL="https://google.com"
readonly GURL="https://developers.google.com/android/nexus/images"

# oatdump dependencies URLs as compiled from AOSP matching API levels
readonly L_OATDUMP_URL_API23='https://onedrive.live.com/download?cid=D1FAC8CC6BE2C2B0&resid=D1FAC8CC6BE2C2B0%21490&authkey=ACA4f4Zvs3Tb_SY'
readonly D_OATDUMP_URL_API23='https://onedrive.live.com/download?cid=D1FAC8CC6BE2C2B0&resid=D1FAC8CC6BE2C2B0%21493&authkey=AJ0rWu5Ci8tQNLY'
readonly L_OATDUMP_URL_API24='https://onedrive.live.com/download?cid=D1FAC8CC6BE2C2B0&resid=D1FAC8CC6BE2C2B0%21492&authkey=AE4uqwH-THvvkSQ'
readonly D_OATDUMP_URL_API24='https://onedrive.live.com/download?cid=D1FAC8CC6BE2C2B0&resid=D1FAC8CC6BE2C2B0%21491&authkey=AHvCaYwFBPYD4Fs'
readonly L_OATDUMP_URL_API25='https://onedrive.live.com/download?cid=D1FAC8CC6BE2C2B0&resid=D1FAC8CC6BE2C2B0%21503&authkey=AKDpBAzhzum6d7w'
readonly D_OATDUMP_URL_API25='https://onedrive.live.com/download?cid=D1FAC8CC6BE2C2B0&resid=D1FAC8CC6BE2C2B0%21504&authkey=AC5YFNSAZ31-W3o'
readonly L_OATDUMP_URL_API26='https://onedrive.live.com/download?cid=D1FAC8CC6BE2C2B0&resid=D1FAC8CC6BE2C2B0%21557&authkey=AG47qhXu164sYwc'
readonly D_OATDUMP_URL_API26='https://onedrive.live.com/download?cid=D1FAC8CC6BE2C2B0&resid=D1FAC8CC6BE2C2B0%21561&authkey=ABu-oqJbQDwQ-ZQ'
readonly L_OATDUMP_URL_API26_2='https://onedrive.live.com/download?cid=D1FAC8CC6BE2C2B0&resid=D1FAC8CC6BE2C2B0%21569&authkey=AG5PlexJR0YMLr0'
readonly D_OATDUMP_URL_API26_2='https://onedrive.live.com/download?cid=D1FAC8CC6BE2C2B0&resid=D1FAC8CC6BE2C2B0%21570&authkey=AJrlrh0v2GUvxow'
readonly L_OATDUMP_URL_API27='https://onedrive.live.com/download?cid=D1FAC8CC6BE2C2B0&resid=D1FAC8CC6BE2C2B0%21566&authkey=AKWYYxBfd7NMW_k'
readonly D_OATDUMP_URL_API27='https://onedrive.live.com/download?cid=D1FAC8CC6BE2C2B0&resid=D1FAC8CC6BE2C2B0%21567&authkey=AF-cDubRkZdjRxY'
readonly L_OATDUMP_URL_API28='https://onedrive.live.com/download?cid=D1FAC8CC6BE2C2B0&resid=D1FAC8CC6BE2C2B0%21574&authkey=ADSQA_DtfAmmk2c'
readonly D_OATDUMP_URL_API28='https://onedrive.live.com/download?cid=D1FAC8CC6BE2C2B0&resid=D1FAC8CC6BE2C2B0%21582&authkey=ABMMORAJ-GGjs2k'


readonly L_OATDUMP_API23_SIG='688f1c1f97e3b9eb32702c60ca05abbf313bc98a25334aa3ed4a108095162244'
readonly D_OATDUMP_API23_SIG='688f1c1f97e3b9eb32702c60ca05abbf313bc98a25334aa3ed4a108095162244'
readonly L_OATDUMP_API24_SIG='1f99e7d0f2894cfe52fb7f2a24d5076f217977cbb1a46fafdf5ea38b0a11adce'
readonly D_OATDUMP_API24_SIG='4a7f5614eb04d9bea85bfa05853523843f9cc80a64eab4c98efed2f70ed3d90e'
readonly L_OATDUMP_API25_SIG='8b8cd18f08afd00fc6bf33d5b7f5be4faab9f39849b258bade5d15c3e5f33ce8'
readonly D_OATDUMP_API25_SIG='97f26b40cdc1fb2b5e5babe7ff8c63b70e7d3a3ab8dee19b035bbb0fdfa5477e'
readonly L_OATDUMP_API26_SIG='d8c08fe0de637412086f8433b41808d7b58e92e7b7341fb9b4da44868d4b311b'
readonly D_OATDUMP_API26_SIG='6fd75110e85f0cc0316c5e7345ea4271d527aae2570552dc3c565177a4d6b743'
readonly L_OATDUMP_API26_2_SIG='22ab2469d32fbb1a4010528695c0c71ed1a3f7f5e956971b7f933e2df9b4f44a'
readonly D_OATDUMP_API26_2_SIG='03b603c09c1dfbdffa0518d39f5d7e5fcf04eac2e8b11bec27f2e4c36b162689'
readonly L_OATDUMP_API27_SIG='e8363ecbd6bc6bd4d3e86e5a59adfa77f62c3f765f4bb8d32706a538831357ac'
readonly D_OATDUMP_API27_SIG='2aaab14d1178845bf9d08b06b7afd3dfd845e882c9bf2c403593940a39ff3449'
readonly L_OATDUMP_API28_SIG='394a47491de4def3b825b22713f5ecfd8f16e00497f35213ffd83c2cc709384e'
readonly D_OATDUMP_API28_SIG='95ce6c296c5115861db3c876eb5bfd11cdc34deebace18462275368492c6ea87'

# sub-directories that contain bytecode archives
declare -ra SUBDIRS_WITH_BC=("app" "framework" "priv-app" "overlay" "product")

# ART runtime files
declare -ra ART_FILE_EXTS=("odex" "oat" "art" "vdex")

# Files to skip from vendor partition when parsing factory images (for all configs)
declare -ra VENDOR_SKIP_FILES=(
  "build.prop"
  "compatibility_matrix.xml"
  "default.prop"
  "etc/NOTICE.xml.gz"
  "etc/wifi/wpa_supplicant.conf"
  "manifest.xml"
  "bin/toybox_vendor"
  "bin/toolbox"
  "bin/grep"
  "overlay/DisplayCutoutEmulationCorner/DisplayCutoutEmulationCornerOverlay.apk"
  "overlay/DisplayCutoutEmulationDouble/DisplayCutoutEmulationDoubleOverlay.apk"
  "overlay/DisplayCutoutEmulationTall/DisplayCutoutEmulationTallOverlay.apk"
  "overlay/DisplayCutoutNoCutout/NoCutoutOverlay.apk"
  "overlay/framework-res__auto_generated_rro.apk"
  "overlay/SysuiDarkTheme/SysuiDarkThemeOverlay.apk"
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
