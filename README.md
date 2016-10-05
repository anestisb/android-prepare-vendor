## Introduction

For latest Android Nexus devices (N5x, N6p, N9 LTE/WiFi), Google is no longer
providing vendor binary archives to be included into AOSP build tree.
Officially it is claimed that all vendor proprietary blobs have been moved to
`/vendor` partition, which allegedly doesn't need building from users.
Unfortunately, that is not the case since quite a few vendor executables, DSOs
and APKs/JARs required in order to have a fully functional set of images, are present
under `/system`, although missing from AOSP public tree. Additionally, if
`vendor.img` is not generated when `system.img` is prepared for build, a few bits
are broken that also require manual fixing (various symbolic links between two
partitions, bytecode product packages, vendor shared libs dependencies, etc.).

Everyone's hope is that Google **will revise** this policy for Nexus devices.
However until then, missing blobs need to be manually extracted from factory
images, processed and included into AOSP tree. These processing steps are evolving
into a total nightmare considering that all recent factory images have their
bytecode (APKs, JARs) pre-optimized to reduce boot time and their original
`classes.dex` stripped to reduce disk size. As such, these missing pre-built
components need to be repaired/de-optimized prior to be included, since AOSP build
is not capable to import pre-optimized modules as part of the makefile tree.

Scripts & tools included in this repository aim to automate the extraction,
processing and generation of vendor specific data using factory images as
input. Data from vendor partition are mirrored to blob includes via a compatible
makefile structure, so that `vendor.img` can be generated from AOSP builds while
specially annotating the vendor APKs to maintain pre-signed certificates and not
pre-optimize. If you have modified the build process (such as CyanogenMod) you
might need to apply additional changes in device configurations / makefiles.

The main concept of this tool-set is to apply all required changes in vendor
makefiles leaving the AOSP source code tree & build chain untouched. Hacks in AOSP
tree, such as those applied by CyanogenMod, are painful to maintain and very fragile.

Repository data are LICENSE free, use them as you want at your own risk. Feedback &
patches are more than welcome though.


## Required steps summary

The process to extract and import vendor proprietary blobs requires to:

1. Obtain device matching factory images archive from Google developer website
(`scripts/download-nexus-image.sh`)
2. Extract images from archive, convert from sparse to raw, mount to with fuse-ext2 &
extract data (`scripts/extract-factory-images.sh`)
  * All vendor partition data are mirror in order to generate a production identical `vendor.img`
3. Repair bytecode (APKs/JARs) from factory system image (`scripts/system-img-repair.sh`)
  * **API >= 24**: Use oatdump ART host tool to extract DEX from OAT ELF .rodata section
  & dexRepair to fix signatures (more info [here](https://github.com/anestisb/android-prepare-vendor/issues/22))
  * **API = 23**: Use SmaliEx to de-odex bytecode
4. Generate vendor proprietary includes & makefiles compatible with AOSP build tree
(`scripts/generate-vendor.sh`)
  * Extra care in Makefile rules to not break compatibility among AOSP versions

`execute-all.sh` runs all previous steps with required order. As an alternative to
download images from Google's websize, script can also read factory images from
file-system location using the `-i|--img` flag.

`-k|--keep` flag can be used if you want to keep extracted intermediate files for further
investigation. Keep in mind that if used the mount-points from fuse-ext2 are not unmounted.
So be sure that you manually remove them (or run the script again without the flag) when done.

All scripts can be executed from OS X, Linux & other Unix-based systems as long
as `fuse-ext2` and other utilized command line tools are installed. Scripts will
abort if any of the required tools is missing from the host.

Scripts include individual usage info and additional flags that be used for
targeted advanced actions, bugs investigation & development of new features.


## Configuration files explained
### Naked vs GPlay
Naked configuration group (enabled by default when using the master script)
includes data & module targets required to have a functional device from AOSP
without using Google Play Services / Google Apps. On the other hand GPlay
configuration group (enabled with `-g|--gplay` flag from master script) has additional
blobs & module targets which are required only when GApps are installed (either
manually post-boot or included as additional vendor blobs).

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


## Supported devices
| Device                          | API 23                      | API 24           |
| ------------------------------- | --------------------------- | -----------------|
| N5x bullhead                    | smaliex<br>smali<br>oatdump | smali<br>oatdump |
| N6p angler                      | smaliex<br>smali<br>oatdump | smali<br>oatdump |
| N9 flounder<br> WiFi (volantis) | smaliex<br>smali<br>oatdump | smali<br>oatdump |
| N9 flounder<br> LTE (volantisg) | smaliex<br>smali<br>oatdump | *PENDING*        |

## Contributing

If you want to contribute to device configuration files, please test against the
target device before any pull request.

## Change Log
* 0.1.7 - TBC
 * [EXPERIMENTAL] Deprecate SmaliEx and use Baksmali/Smali to deodex bytecode
 * Improve supported bytecode deodex methods modularity - users can now override default methods
 * Global flag to disable /system `LOCAL_DEX_PREOPT` overrides from vendor generate script
 * Respect LOCAL_MULTILIB when 32bit bytecode prebuilts detected against a 64bit device
* 0.1.6 - 4 Oct 2016
 * Download automation compatibility with refactored Google Nexus images website
 * Bug fixes when generating from MAC
* 0.1.5 - 25 Sep 2016
 * Fixes issue with symlinks resolve when output path with spaces
 * Fixes bug when repairing multi-dex APKs with oatdump method
 * Introduced sorted data processing so that output is diff friendly
 * Include baseband & bootloader firmware at vendor blobs
 * Various performance optimizations
* 0.1.4 - 17 Sep 2016
 * Split configuration into 2 groups: Naked & GPlay
 * Fix extra modules being ignored bug
* 0.1.3 - 14 Sep 2016
 * Fix missing output path normalization which was corrupting symbolic links
* 0.1.2 - 12 Sep 2016
 * Fix JAR META-INF repaired archives deletion bug
 * Improved fuse mount error handling
 * FAQ for common fuse mount issues
 * Extra defensive checks for /vendor/priv-app chosen signing certificate
* 0.1.1 - 12 Sep 2016
 * Unbound variable bug fix when early error abort
* 0.1.0 - 11 Sep 2016
 * Nougat API-24 support
 * Utilize fuse-ext2 to drop required root permissions
 * Implement new bytecode repair method
 * Read directly data from mount points - deprecate local rsync copies for speed
 * Add OS X support (requires OSXFuse)
 * Improved device configuration layers / files
 * AOSP compatibility bug fixes & performance optimizations

## Warnings

* No binary vendor data against supported devices will be maintained in this
repository. Scripts provide all necessary automation to generate them yourself.
* No promises on how the device configuration files will be maintained. Feel free
to contribute if you detect that something is broken/missing or not required.
* Host tool binaries are provided for convenience, although with no promises
that will be kept up-to-date. Prefer to adjust your env. with upstream versions and
keep them updated.
* If you experience `already defined` type of errors when AOSP makefiles are
included, you have other vendor makefiles that define the same packages (e.g.
hammerhead vs bullhead from LGE). This issue is due to the developers of
conflicted vendor makefiles didn't bother to wrap them with
`ifeq ($TARGET_DEVICE),<device_model>)`. Wrap conflicting makefiles with
device matching clauses to resolve the issue.
* If deprecated SmaliEx method for API-23 is chosen, Java 8 is required for
the bytecode de-optimization process to work.
* Bytecode repaired with oatdump method cannot be pre-optimized. As such generated
rules have `LOCAL_DEXPREOPT := false`. This is because host dex2oatd is invoked with
more strict flags and results into aborting when front-end reaches already optimized
instructions.
* If you're planning to deliver OTA updates for Nexus 5x, you need to manually extract
`update-binary` from a factory OTA archive since it's missing from AOSP tree due to some
proprietary LG code.

## Frequently Spotted Issues
### fuse-ext2
* `fusermount: failed to open /etc/fuse.conf: Permission denied`
 * FIX-1: Add low privilege username to fuse group (e.g.: `# usermod -a -G fuse anestisb`)
 * FIX-2: Change file permissions - `# chmod +r /etc/fuse.conf
* `fusermount: option allow_other only allowed if 'user_allow_other' is set in /etc/fuse.conf`
 * Edit `/etc/fuse.conf` and write/uncomment the `user_allow_other` flag

## Examples
### API-24 (Nougat) N9 WiFi (alias volantis) flounder vendor generation after downloading factory image from website
```
$ ./execute-all.sh -d flounder -a volantis -b NRD91D -o /fast-datavault/nexus-vendor-blobs
[*] Setting output base to '/fast-datavault/nexus-vendor-blobs/flounder/nrd91d'

--{ Google Terms and Conditions
Downloading of the system image and use of the device software is subject to the
Google Terms of Service [1]. By continuing, you agree to the Google Terms of
Service [1] and Privacy Policy [2]. Your downloading of the system image and use
of the device software may also be subject to certain third-party terms of
service, which can be found in Settings > About phone > Legal information, or as
otherwise provided.

[1] https://www.google.com/intl/en/policies/terms/
[2] https://www.google.com/intl/en/policies/privacy/

[?] I have read and agree with the above terms and conditions - ACKNOWLEDGE [y|n]: y
[*] Downloading image from 'https://dl.google.com/dl/android/aosp/volantis-nrd91d-factory-a27db9bc.zip'
--2016-10-05 21:53:17--  https://dl.google.com/dl/android/aosp/volantis-nrd91d-factory-a27db9bc.zip
Resolving dl.google.com (dl.google.com)... 173.194.76.93, 173.194.76.190, 173.194.76.136, ...
Connecting to dl.google.com (dl.google.com)|173.194.76.93|:443... connected.
HTTP request sent, awaiting response... 200 OK
Length: 793140236 (756M) [application/zip]
Saving to: ‘/fast-datavault/nexus-vendor-blobs/flounder/nrd91d/volantis-nrd91d-factory-a27db9bc.zip’

s/flounder/nrd91d/volantis-nrd91d-factory-a27db9bc.zip  96%[======================================================================================================================>    ] 733.49M  1.22MB/s    eta 19s    ^/fast-datavault/nexus-vendor-blobs/flounder/nrd91d/vol 100%[==========================================================================================================================>] 756.40M  1.19MB/s    in 10m 21s

2016-10-05 22:03:39 (1.22 MB/s) - ‘/fast-datavault/nexus-vendor-blobs/flounder/nrd91d/volantis-nrd91d-factory-a27db9bc.zip’ saved [793140236/793140236]

[*] Processing with 'API-24 config-naked' configuration
[*] Extracting '/fast-datavault/nexus-vendor-blobs/flounder/nrd91d/volantis-nrd91d-factory-a27db9bc.zip'
[*] Unzipping 'image-volantis-nrd91d.zip'
[!] No baseband firmware present - skipping
[!] System partition doesn't contain any pre-optimized files - link to original partition
[*] Generating blobs for vendor/htc/flounder
[*] Copying radio files '/fast-datavault/nexus-vendor-blobs/flounder/nrd91d/vendor/htc/flounder'
[*] Copying product files & generating 'flounder-vendor-blobs.mk' makefile
[*] Generating 'device-vendor.mk'
[*] Generating 'AndroidBoardVendor.mk'
  [*] Bootloader:3.48.0.0139
[*] Generating 'BoardConfigVendor.mk'
[*] Generating 'vendor-board-info.txt'
[*] Generating 'Android.mk'
[*] Gathering data from 'vendor/app' APK/JAR pre-builts
[*] Generating signatures file
[*] All actions completed successfully
[*] Import '/fast-datavault/nexus-vendor-blobs/flounder/nrd91d/vendor' to AOSP root

```

### API-23 (Marshmallow) N5x vendor generation using factory image from file-system
```
$ ./execute-all.sh -d bullhead -i /fast-datavault/nexus-vendor-blobs/bullhead/mtc20k/bullhead-mtc20k-factory-4a950470.zip -b mtc20k -o /fast-datavault/nexus-vendor-blobs
[*] Setting output base to '/fast-datavault/nexus-vendor-blobs/bullhead/mtc20k'
[*] Processing with 'API-23 config-naked' configuration
[*] Extracting '/fast-datavault/nexus-vendor-blobs/bullhead/mtc20k/bullhead-mtc20k-factory-4a950470.zip'
[*] Unzipping 'image-bullhead-mtc20k.zip'
[*] '20' bytecode archive files will be repaired
[*] Repairing bytecode under /system partition using oat2dex method
[*] Preparing environment for 'arm' ABI
[*] Preparing environment for 'arm64' ABI
[*] Start processing system partition & de-optimize pre-compiled bytecode
[!] '/framework/cneapiclient.jar' not pre-optimized with sanity checks passed - copying without changes
[!] '/framework/framework-res.apk' not pre-optimized & without 'classes.dex' - copying without changes
[*] '/framework/framework.jar' is multi-dex - adjusting recursive archive adds
[!] '/framework/rcsimssettings.jar' not pre-optimized with sanity checks passed - copying without changes
[!] '/framework/rcsservice.jar' not pre-optimized with sanity checks passed - copying without changes
[*] System partition successfully extracted & repaired at '/fast-datavault/nexus-vendor-blobs/bullhead/mtc20k/factory_imgs_repaired_data'
[*] Generating blobs for vendor/lge/bullhead
[*] Copying radio files '/fast-datavault/nexus-vendor-blobs/bullhead/mtc20k/vendor/lge/bullhead'
[*] Copying product files & generating 'bullhead-vendor-blobs.mk' makefile
[*] Generating 'device-vendor.mk'
[*] Generating 'AndroidBoardVendor.mk'
  [*] Bootloader:BHZ10r
  [*] Baseband:M8994F-2.6.32.1.13
[*] Generating 'BoardConfigVendor.mk'
[*] Generating 'vendor-board-info.txt'
[*] Generating 'Android.mk'
[*] Gathering data from 'vendor/app' APK/JAR pre-builts
[*] Gathering data from 'proprietary/app' APK/JAR pre-builts
[*] Gathering data from 'proprietary/framework' APK/JAR pre-builts
[*] Gathering data from 'proprietary/priv-app' APK/JAR pre-builts
[*] Generating signatures file
[*] All actions completed successfully
[*] Import '/fast-datavault/nexus-vendor-blobs/bullhead/mtc20k/vendor' to AOSP root
```
