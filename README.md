## Introduction

For latest Android Nexus devices (N5x, N6p, N9, etc.), Google is no longer
providing vendor binary archives to be included into AOSP build tree.
Officially it is claimed that all vendor proprietary blobs have been moved to
`/vendor` partition, which allegedly doesn't need build from users.
Unfortunately, that is not the case since quite a few vendor executables, DSOs
and APKs/JARs required to have a fully functional set of images, are present
under `/system` although missing from AOSP public tree. Additionally, if
`vendor.img` is not generated when `system.img` is getting built, a few bits
are broken that also require manual fixing (`/system/vendor` symlink, bytecode
product packages, etc.).

Everyone's hope is that Google **will revise** this policy for Nexus devices.
However until then, missing blobs need to be manually extracted from factory
images, processed and included into AOSP tree. This processing is evolving
into a total nightmare considering that all recent factory images have their
bytecode (APKs, JARs) pre-optimized to reduce boot time. As such these missing
pre-builts need to be de-optimized prior to be included since they might break
otherwise (incompatibilities with original boot classes `boot.oat`).

Scripts & tools included in this repo aim to automate the extraction,
processing and generation of vendor specific data using factory images as
input. Data from vendor partition are mirrored to blob includes, so that
`vendor.img` can be generated from AOSP builds while specially handling the
vendor APKs with presigned certificates. If you have modified the build
process (such as CyanogenMod) you might need to apply additional changes in
device configurations.

The main concept of this toolset is to apply all required changes in vendor
makefiles leaving the `$(BUILD_TREE)/build` makefiles untouched. Hacks in AOSP
build tree (such as those applied by CyanogenMod) are painful to maintain and
very fragile.

Repo data are LICENSE free, use them as you want at your own risk. Feedback &
patches are more than welcome though.


## Required steps summary

The process to extract and import vendor proprietary blobs requires to:

1. Obtain device matching factory images archive from Google developer website (`scripts/download-nexus-image.sh`)
2. Extract images from archives, convert from sparse to raw, mount to loopback & extract data (`scripts/extract-factory-images.sh`)
  * Extra care is taken to maintain symlinks since they are important to generate rules for prebuilt packages' JNI libs not embedded into APKs
  * All vendor partition data are mirror in order to generate a production identical `vendor.img`
3. De-optimize bytecode (APKs/JARs) from factory system image (`scripts/system-img-repair.sh`)
4. Generate vendor proprietary includes & makefiles compatible with AOSP build tree (`scripts/generate-vendor.sh`)
  * Extra care in Makefile rules to not break compatibility between old & new build system (ninja)

`execute-all.sh` runs all previous steps with required order. As an
alternative to download images, script can also read factory images from
filesystem location using the `-i|--imgs-tar` flag. `-k|--keep` flag can be
used if you want to keep extracted intermediate files for further
investigation. Scripts must run as root in order to maintain correct file
permissions for generated proprietary blobs.

All scripts except `scripts/extract-factory-images.sh` can be executed from
both MAC & *unix systems. In case `execute-all.sh` is used, *unix host system
is the only option. If you have ext4 support in your MAC you can edit the
mount loopback commands.

Individual scripts include usage info with additional flags that be used for
targeted actions and bugs investigation.


## Supported devices

* bullhead - Nexus 5x
* flounder - Nexus 9 WiFi (volantis)
* flounder - Nexus 9 LTE (volantisg)
* angler - Nexus 6p

## Android N Supported devices

* flounder - Nexus 9 WiFi (volantis)

Remaining devices are in the TODO list

## Contributing

If you want to contribute to `system-proprietary-blobs.txt` files, please test
against the target device before pull request.

## Warnings

* No binary vendor data against supported devices will be maintained in this
repo. Scripts provide all necessary automation to generate them yourself.
* No promises on how `system-proprietary-blobs.txt` lists will be maintained.
Feel free to contribute if you detect that something is broken/missing or not
required.
* Host tool binaries are provided for convenience, although with no promises
that will be updated. Prefer to adjust your env. with upstream versions and
keep them updated (specially the SmalliEx).
* It's your responsibility to flash matching baseband & bootloader images
* If you experience `already defined` type of errors when AOSP makefiles are
included, you have other vendor makefiles that define the same packages (e.g.
hammerhead vs bullhead from LGE). This issue is because the source of
conflicted vendor makefiles didn't bother to wrap them with
`ifeq ($TARGET_DEVICE),<device_model>)`. Wrap conflicting makefiles with
device matching clauses to resolve the issue.
* Some might find a performance overkill to copy across & de-optimize the
entire partition, while only a small subset of them is required. This will not
change since same toolset is used to extract data for other purposes too. Feel
free to edit them locally at your forks if you want to speed-up the process.
* Java 8 is required for the bytecode de-optimization tool to work


## Example

```
root@aosp_b_server:prepare_vendor_blobs# ./execute-all.sh -d bullhead -b MTC20F -o $(pwd) -k
[*] Setting output base to '/aosp_b_prod/prepare_vendor_blobs/bullhead/mtc20f'
[*] Downloading image from 'https://dl.google.com/dl/android/aosp/bullhead-mtc20f-factory-fa466167.zip'
--2016-09-01 22:32:58--  https://dl.google.com/dl/android/aosp/bullhead-mtc20f-factory-fa466167.zip
Resolving dl.google.com (dl.google.com)... 62.75.10.35, 62.75.10.34, 62.75.10.45, ...
Connecting to dl.google.com (dl.google.com)|62.75.10.35|:443... connected.
HTTP request sent, awaiting response... 200 OK
Length: 964936069 (920M) [application/zip]
Saving to: ‘/aosp_b_prod/prepare_vendor_blobs/bullhead/mtc20f/bullhead-mtc20f-factory-fa466167.zip’

/aosp_b_prod/prepare_vendor_blobs/bullhead/mtc20f/ 100%[=================================================================================================================>] 920.23M  1.20MB/s   in 12m 46ss

2016-09-01 22:45:45 (1.20 MB/s) - ‘/aosp_b_prod/prepare_vendor_blobs/bullhead/mtc20f/bullhead-mtc20f-factory-fa466167.zip’ saved [964936069/964936069]

[*] Unzipping 'image-bullhead-mtc20f.zip'
[*] Copying files from system partition ...
[*] Copying files from vendor partition ...
[*] Preparing environment for 'arm' ABI
[*] Preparing environment for 'arm64' ABI
[*] Start extracting system partition & de-optimize pre-compiled bytecode ...
[*] Skipping framework-res since it doesn't pair with bytecode
[*] '/framework/framework.jar' is multi-dex - adjusting recursive archive adds
[*] '/framework/rcsimssettings.jar' not pre-optimized with sanity checks passed - copying without changes
[*] '/framework/rcsservice.jar' not pre-optimized with sanity checks passed - copying without changes
[*] '/framework/cneapiclient.jar' not pre-optimized with sanity checks passed - copying without changes
[*] '/priv-app/GoogleServicesFramework/GoogleServicesFramework.apk' not pre-optimized with sanity checks passed - copying without changes
[*] '/priv-app/PrebuiltGmsCore/PrebuiltGmsCore.apk' is multi-dex - adjusting recursive archive adds
[*] '/app/Music2/Music2.apk' is multi-dex - adjusting recursive archive adds
[-] '/app/PlayGames/PlayGames.apk' de-optimization failed consider manual inspection - skipping archive
[-] '/app/PrebuiltExchange3Google/PrebuiltExchange3Google.apk' de-optimization failed consider manual inspection - skipping archive
[*] '/app/Photos/Photos.apk' is multi-dex - adjusting recursive archive adds
[*] System partition successfully extracted & de-optimized at '/aosp_b_prod/prepare_vendor_blobs/bullhead/mtc20f/factory_imgs_repaired_data'
[!] Target device expects to have following img versions when using output system img
 [*] Booatloder:BHZ10r
 [*] Baseband:M8994F-2.6.32.1.13
[*] Generating blobs for vendor/lge/bullhead
[*] Copying files to '/aosp_b_prod/prepare_vendor_blobs/bullhead/mtc20f/vendor/lge/bullhead' ...
[*] Generating 'bullhead-vendor-blobs.mk' makefile
[*] Generating 'device-vendor.mk'
[*] Generating 'BoardConfigVendor.mk'
[*] Generating 'Android.mk' ...
[*] Gathering data from '/aosp_b_prod/prepare_vendor_blobs/bullhead/mtc20f/vendor/lge/bullhead/vendor/app' APK/JAR pre-builts
[*] Gathering data from '/aosp_b_prod/prepare_vendor_blobs/bullhead/mtc20f/vendor/lge/bullhead/proprietary/app' APK/JAR pre-builts
[*] Gathering data from '/aosp_b_prod/prepare_vendor_blobs/bullhead/mtc20f/vendor/lge/bullhead/proprietary/framework' APK/JAR pre-builts
[*] Gathering data from '/aosp_b_prod/prepare_vendor_blobs/bullhead/mtc20f/vendor/lge/bullhead/proprietary/priv-app' APK/JAR pre-builts
[*] All actions completed successfully
[*] Import '/aosp_b_prod/prepare_vendor_blobs/bullhead/mtc20f/vendor' to AOSP root
```
