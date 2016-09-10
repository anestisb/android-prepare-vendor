## Introduction

For latest Android Nexus devices (N5x, N6p, N9 LTE/WiFi), Google is no longer
providing vendor binary archives to be included into AOSP build tree.
Officially it is claimed that all vendor proprietary blobs have been moved to
`/vendor` partition, which allegedly doesn't need build from users.
Unfortunately, that is not the case since quite a few vendor executables, DSOs
and APKs/JARs required in order to have a fully functional set of images, are present
under `/system`, although missing from AOSP public tree. Additionally, if
`vendor.img` is not generated when `system.img` is getting built, a few bits
are broken that also require manual fixing (`/system/vendor` symbolic link, bytecode
product packages, vendor shared libs dependencies, etc.).

Everyone's hope is that Google **will revise** this policy for Nexus devices.
However until then, missing blobs need to be manually extracted from factory
images, processed and included into AOSP tree. This processing steps are evolving
into a total nightmare considering that all recent factory images have their
bytecode (APKs, JARs) pre-optimized to reduce boot time and their original
classes.dex stripped to reduce disk size. As such, these missing pre-built components
need to be repaired/de-optimized prior to be included since AOSP build is not
capable to import pre-optimized modules as part of the makefile tree.

Scripts & tools included in this repository aim to automate the extraction,
processing and generation of vendor specific data using factory images as
input. Data from vendor partition are mirrored to blob includes via a compatible
makefile structure, so that `vendor.img` can be generated from AOSP builds while
specially annotating the vendor APKs to maintain pre-signed certificates and not
pre-optimize. If you have modified the build process (such as CyanogenMod) you
might need to apply additional changes in device configurations / makefiles.

The main concept of this tool-set is to apply all required changes in vendor
makefiles leaving the AOSP tree & build chain untouched. Hacks in AOSP tree
(such as those applied by CyanogenMod) are painful to maintain and very fragile.

Repository data are LICENSE free, use them as you want at your own risk. Feedback &
patches are more than welcome though.


## Required steps summary

The process to extract and import vendor proprietary blobs requires to:

1. Obtain device matching factory images archive from Google developer website
(`scripts/download-nexus-image.sh`)
2. Extract images from archives, convert from sparse to raw, mount to with fuse-ext2 &
extract data (`scripts/extract-factory-images.sh`)
  * Extra care is taken to maintain symbolic links since they are important to
generate rules for prebuilt packages' JNI libs not embedded into APKs
  * All vendor partition data are mirror in order to generate a production identical `vendor.img`
3. Repair bytecode (APKs/JARs) from factory system image (`scripts/system-img-repair.sh`)
  * Use oatdump ART host tool to extract DEX from OAT ELF .rodata section & dexRepair
to fix signatures (API >= 24 - **EXPERIMENTAL** more info [here](https://github.com/anestisb/android-prepare-vendor/issues/22))
  * Use SmaliEx to de-odex bytecode (API == 23)
4. Generate vendor proprietary includes & makefiles compatible with AOSP build tree
(`scripts/generate-vendor.sh`)
  * Extra care in Makefile rules to not break compatibility between old & new build
  system (ninja)

`execute-all.sh` runs all previous steps with required order. As an
alternative to download images method, script can also read factory images from
file-system location using the `-i|--img` flag.

`-k|--keep` flag can be used if you want to keep extracted intermediate files for further
investigation.

All scripts can be executed from OS X, Linux & other Unix-based systems as long
as `fuse-ext2` and other utilized command line tools are installed. Scripts will
abort if any of the required tools is missing from the host.

Scripts include individual usage info and additional flags that be used for
targeted advanced actions, bugs investigation & development of new features.


## Configuration files explained
### **system-proprietary-blobs-apiXX.txt**
List of files to be appended at the `PRODUCT_COPY_FILES` list. These files are
effectively copied across as is from source vendor directory to configured AOSP
build output directory.

### **bytecode-proprietary-apiXX.txt**
List of bytecode archive files to extract from factory images, repair and generate
individual target modules to be included in vendor makefile structure.

### **dep-dso-proprietary-blobs-apiXX.txt**
Pre-built shared libraries (*.so) extracted from factory images that are included
as a separate local module. Multi-lib support & paths are automatically generated
based on the evidence collected while crawling factory images extracted partitions.
Files enlisted here will excluded from `PRODUCT_COPY_FILES` and instead added to
the `PRODUCT_PACKAGES` list.

### **vendor-config-apiXX.txt**
Additional makefile flags to be appended at the dynamically generated `BoardConfigVendor.mk`
These flags are useful in case we want to override some default values set at
original `BoardConfig.mk` without editing the source file.

### **extra-modules-apiXX.txt**
Additional target modules (with compatible structure based on rule build type) to
be appended at master vendor `Android.mk`.


## Android M (API-23) supported devices

* angler - Nexus 6p
* bullhead - Nexus 5x
* flounder - Nexus 9 WiFi (volantis)
* flounder - Nexus 9 LTE (volantisg)

## Android N (API-24) supported devices

* angler - Nexus 6p (`TESTING`)
* bullhead - Nexus 5x
* flounder - Nexus 9 WiFi (volantis)

`Nexus 9 LTE will be supported as soon as Google releases Nougat factory images`


## Contributing

If you want to contribute to `system-proprietary-blobs-apiXX.txt` or `shared-proprietary-blobs-apiXX.txt`
files, please test against the target device before pull request.

## Warnings

* No binary vendor data against supported devices will be maintained in this
repository. Scripts provide all necessary automation to generate them yourself.
* No promises on how `system-proprietary-blobs-apiXX.txt` and
`shared-proprietary-blobs-apiXX.txt` lists will be maintained. Feel free to
contribute if you detect that something is broken/missing or not required.
* Host tool binaries are provided for convenience, although with no promises
that will be kept up-to-date. Prefer to adjust your env. with upstream versions and
keep them updated.
* It's your responsibility to flash matching baseband & bootloader images.
* If you experience `already defined` type of errors when AOSP makefiles are
included, you have other vendor makefiles that define the same packages (e.g.
hammerhead vs bullhead from LGE). This issue is due to the developers of
conflicted vendor makefiles didn't bother to wrap them with
`ifeq ($TARGET_DEVICE),<device_model>)`. Wrap conflicting makefiles with
device matching clauses to resolve the issue.
* If deprecated SmaliEx method for API-23 is chosen, Java 8 is required for
the bytecode de-optimization process to work.


## Examples

```
root@aosp-build:prepare_vendor_blobs# ./execute-all.sh -d bullhead -b NRD90S -o $(pwd)
[*] Setting output base to '/aosp_b_prod/prepare_vendor_blobs/bullhead/nrd90s'
[*] Downloading image from 'https://dl.google.com/dl/android/aosp/bullhead-nrd90s-factory-d6bf1f56.zip'
--2016-09-07 10:02:31--  https://dl.google.com/dl/android/aosp/bullhead-nrd90s-factory-d6bf1f56.zip
Resolving dl.google.com (dl.google.com)... 62.75.10.30, 62.75.10.24, 62.75.10.55, ...
Connecting to dl.google.com (dl.google.com)|62.75.10.30|:443... connected.
HTTP request sent, awaiting response... 200 OK
Length: 1243254222 (1.2G) [application/zip]
Saving to: ‘/aosp_b_prod/prepare_vendor_blobs/bullhead/nrd90s/bullhead-nrd90s-factory-d6bf1f56.zip’

/aosp_b_prod/prepare_vendor_blobs/bullhead/nrd90s/ 100%[==================================================================================================================>]   1.16G  1.21MB/s   in 16m 28ss

2016-09-07 10:19:00 (1.20 MB/s) - ‘/aosp_b_prod/prepare_vendor_blobs/bullhead/nrd90s/bullhead-nrd90s-factory-d6bf1f56.zip’ saved [1243254222/1243254222]

[*] Processing with 'API-24' configuration
[*] Extracting '/aosp_b_prod/prepare_vendor_blobs/bullhead/nrd90s/bullhead-nrd90s-factory-d6bf1f56.zip'
[*] Unzipping 'image-bullhead-nrd90s.zip'
[*] Copying files from 'system.img.raw' image
[*] Copying files from 'vendor.img.raw' image
[*] '15' APKs will be repaired along with framework jars
[*] Repairing bytecode under /system partition using oatdump method
[-] '/framework/framework-res.apk' not pre-optimized & without 'classes.dex' - skipping
[-] '/framework/core-oj.jar' not pre-optimized & without 'classes.dex' - skipping
[*] '/framework/rcsimssettings.jar' not pre-optimized with sanity checks passed - copying without changes
[*] '/framework/rcsservice.jar' not pre-optimized with sanity checks passed - copying without changes
[*] '/framework/cneapiclient.jar' not pre-optimized with sanity checks passed - copying without changes
[*] System partition successfully extracted & repaired at '/aosp_b_prod/prepare_vendor_blobs/bullhead/nrd90s/factory_imgs_repaired_data'
[!] Target device expects to have following img versions when using output system img
 [*] Booatloder:BHZ11e
 [*] Baseband:M8994F-2.6.33.2.14
[*] Generating blobs for vendor/lge/bullhead
[*] Copying files to '/aosp_b_prod/prepare_vendor_blobs/bullhead/nrd90s/vendor/lge/bullhead'
[*] Generating 'bullhead-vendor-blobs.mk' makefile
[*] Generating 'device-vendor.mk'
[*] Generating 'BoardConfigVendor.mk'
[*] Generating 'Android.mk'
[*] Gathering data from '/aosp_b_prod/prepare_vendor_blobs/bullhead/nrd90s/vendor/lge/bullhead/vendor/app' APK/JAR pre-builts
[*] Gathering data from '/aosp_b_prod/prepare_vendor_blobs/bullhead/nrd90s/vendor/lge/bullhead/proprietary/app' APK/JAR pre-builts
[*] Gathering data from '/aosp_b_prod/prepare_vendor_blobs/bullhead/nrd90s/vendor/lge/bullhead/proprietary/framework' APK/JAR pre-builts
[*] Gathering data from '/aosp_b_prod/prepare_vendor_blobs/bullhead/nrd90s/vendor/lge/bullhead/proprietary/priv-app' APK/JAR pre-builts
[*] Gathering data for shared library (.so) pre-built modules
[*] All actions completed successfully
[*] Import '/aosp_b_prod/prepare_vendor_blobs/bullhead/nrd90s/vendor' to AOSP root
```

```
root@aosp-build:prepare_vendor_blobs# ./execute-all.sh -d bullhead -b nrd90m -o $(pwd) -i bullhead/nrd90m/bullhead-nrd90m-factory-61495c8b.zip
[*] Setting output base to '/aosp_b_prod/prepare_vendor_blobs/bullhead/nrd90m'
[*] Processing with 'API-24' configuration
[*] Extracting 'bullhead/nrd90m/bullhead-nrd90m-factory-61495c8b.zip'
[*] Unzipping 'image-bullhead-nrd90m.zip'
[*] Copying files from 'system.img.raw' image
[*] Copying files from 'vendor.img.raw' image
[*] '15' APKs will be repaired along with framework jars
[*] Repairing bytecode under /system partition using oatdump method
[-] '/framework/framework-res.apk' not pre-optimized & without 'classes.dex' - skipping
[-] '/framework/core-oj.jar' not pre-optimized & without 'classes.dex' - skipping
[*] '/framework/rcsimssettings.jar' not pre-optimized with sanity checks passed - copying without changes
[*] '/framework/rcsservice.jar' not pre-optimized with sanity checks passed - copying without changes
[*] '/framework/cneapiclient.jar' not pre-optimized with sanity checks passed - copying without changes
[*] System partition successfully extracted & repaired at '/aosp_b_prod/prepare_vendor_blobs/bullhead/nrd90m/factory_imgs_repaired_data'
[!] Target device expects to have following img versions when using output system img
 [*] Booatloder:BHZ11e
 [*] Baseband:M8994F-2.6.33.2.14
[*] Generating blobs for vendor/lge/bullhead
[*] Copying files to '/aosp_b_prod/prepare_vendor_blobs/bullhead/nrd90m/vendor/lge/bullhead'
[*] Generating 'bullhead-vendor-blobs.mk' makefile
[*] Generating 'device-vendor.mk'
[*] Generating 'BoardConfigVendor.mk'
[*] Generating 'Android.mk'
[*] Gathering data from '/aosp_b_prod/prepare_vendor_blobs/bullhead/nrd90m/vendor/lge/bullhead/vendor/app' APK/JAR pre-builts
[*] Gathering data from '/aosp_b_prod/prepare_vendor_blobs/bullhead/nrd90m/vendor/lge/bullhead/proprietary/app' APK/JAR pre-builts
[*] Gathering data from '/aosp_b_prod/prepare_vendor_blobs/bullhead/nrd90m/vendor/lge/bullhead/proprietary/framework' APK/JAR pre-builts
[*] Gathering data from '/aosp_b_prod/prepare_vendor_blobs/bullhead/nrd90m/vendor/lge/bullhead/proprietary/priv-app' APK/JAR pre-builts
[*] Gathering data for shared library (.so) pre-built modules
[*] All actions completed successfully
[*] Import '/aosp_b_prod/prepare_vendor_blobs/bullhead/nrd90m/vendor' to AOSP root
```

```
root@aosp-build:prepare_vendor_blobs# ./execute-all.sh -d angler -b MTC20L -o $(pwd)
[*] Setting output base to '/aosp_b_prod/prepare_vendor_blobs/angler/mtc20l'
[*] Downloading image from 'https://dl.google.com/dl/android/aosp/angler-mtc20l-factory-a74ad54f.zip'
--2016-09-07 10:36:10--  https://dl.google.com/dl/android/aosp/angler-mtc20l-factory-a74ad54f.zip
Resolving dl.google.com (dl.google.com)... 216.58.214.46, 2a00:1450:4001:814::200e
Connecting to dl.google.com (dl.google.com)|216.58.214.46|:443... connected.
HTTP request sent, awaiting response... 200 OK
Length: 935435661 (892M) [application/zip]
Saving to: ‘/aosp_b_prod/prepare_vendor_blobs/angler/mtc20l/angler-mtc20l-factory-a74ad54f.zip’

/aosp_b_prod/prepare_vendor_blobs/angler/mtc20l/an 100%[==================================================================================================================>] 892.10M  1.19MB/s   in 12m 26ss

2016-09-07 10:48:37 (1.20 MB/s) - ‘/aosp_b_prod/prepare_vendor_blobs/angler/mtc20l/angler-mtc20l-factory-a74ad54f.zip’ saved [935435661/935435661]

[*] Processing with 'API-23' configuration
[*] Extracting '/aosp_b_prod/prepare_vendor_blobs/angler/mtc20l/angler-mtc20l-factory-a74ad54f.zip'
[*] Unzipping 'image-angler-mtc20l.zip'
[*] Copying files from 'system.img.raw' image
[*] Copying files from 'vendor.img.raw' image
[*] '16' APKs will be decompiled along with framework jars
[*] Repairing bytecode under /system partition using oat2dex method
[*] Preparing environment for 'arm' ABI
[*] Preparing environment for 'arm64' ABI
[*] Start processing system partition & de-optimize pre-compiled bytecode
[-] '/framework/framework-res.apk' not pre-optimized & without 'classes.dex' - skipping
[*] '/framework/framework.jar' is multi-dex - adjusting recursive archive adds
[*] System partition successfully extracted & repaired at '/aosp_b_prod/prepare_vendor_blobs/angler/mtc20l/factory_imgs_repaired_data'
[!] Target device expects to have following img versions when using output system img
 [*] Booatloder:angler-03.54
 [*] Baseband:angler-03.61
[*] Generating blobs for vendor/huawei/angler
[*] Copying files to '/aosp_b_prod/prepare_vendor_blobs/angler/mtc20l/vendor/huawei/angler'
[*] Generating 'angler-vendor-blobs.mk' makefile
[*] Generating 'device-vendor.mk'
[*] Generating 'BoardConfigVendor.mk'
[*] Generating 'Android.mk'
[*] Gathering data from '/aosp_b_prod/prepare_vendor_blobs/angler/mtc20l/vendor/huawei/angler/vendor/app' APK/JAR pre-builts
[*] Gathering data from '/aosp_b_prod/prepare_vendor_blobs/angler/mtc20l/vendor/huawei/angler/proprietary/app' APK/JAR pre-builts
[*] Gathering data from '/aosp_b_prod/prepare_vendor_blobs/angler/mtc20l/vendor/huawei/angler/proprietary/framework' APK/JAR pre-builts
[*] Gathering data from '/aosp_b_prod/prepare_vendor_blobs/angler/mtc20l/vendor/huawei/angler/proprietary/priv-app' APK/JAR pre-builts
[*] Processing standalone symlinks
[*] All actions completed successfully
[*] Import '/aosp_b_prod/prepare_vendor_blobs/angler/mtc20l/vendor' to AOSP root
```

```
root@aosp-build:prepare_vendor_blobs# ./execute-all.sh -d flounder -a volantis -b NRD90R -o $(pwd)
[*] Setting output base to '/aosp_b_prod/prepare_vendor_blobs/flounder/nrd90r'
[*] Downloading image from 'https://dl.google.com/dl/android/aosp/volantis-nrd90r-factory-84de678f.zip'
--2016-09-07 12:08:24--  https://dl.google.com/dl/android/aosp/volantis-nrd90r-factory-84de678f.zip
Resolving dl.google.com (dl.google.com)... 172.217.16.174, 2a00:1450:4001:816::200e
Connecting to dl.google.com (dl.google.com)|172.217.16.174|:443... connected.
HTTP request sent, awaiting response... 200 OK
Length: 793127173 (756M) [application/zip]
Saving to: ‘/aosp_b_prod/prepare_vendor_blobs/flounder/nrd90r/volantis-nrd90r-factory-84de678f.zip’

/aosp_b_prod/prepare_vendor_blobs/flounder/nrd90r/ 100%[==================================================================================================================>] 756.38M  1.19MB/s   in 10m 33ss

2016-09-07 12:18:58 (1.19 MB/s) - ‘/aosp_b_prod/prepare_vendor_blobs/flounder/nrd90r/volantis-nrd90r-factory-84de678f.zip’ saved [793127173/793127173]

[*] Processing with 'API-24' configuration
[*] Extracting '/aosp_b_prod/prepare_vendor_blobs/flounder/nrd90r/volantis-nrd90r-factory-84de678f.zip'
[*] Unzipping 'image-volantis-nrd90r.zip'
[*] Copying files from 'system.img.raw' image
[*] Copying files from 'vendor.img.raw' image
[!] System partition doesn't contain any pre-optimized files - moving as is
[*] Generating blobs for vendor/htc/flounder
[*] Copying files to '/aosp_b_prod/prepare_vendor_blobs/flounder/nrd90r/vendor/htc/flounder'
[*] Generating 'flounder-vendor-blobs.mk' makefile
[*] Generating 'device-vendor.mk'
[*] Generating 'BoardConfigVendor.mk'
[*] Generating 'Android.mk'
[*] Gathering data from '/aosp_b_prod/prepare_vendor_blobs/flounder/nrd90r/vendor/htc/flounder/vendor/app' APK/JAR pre-builts
[*] All actions completed successfully
[*] Import '/aosp_b_prod/prepare_vendor_blobs/flounder/nrd90r/vendor' to AOSP root
```
