## Introduction
For the latest Android devices (Nexus and Pixel), Google is no longer providing
vendor binary archives to be included into AOSP build tree. Officially it is
claimed that all vendor proprietary blobs have been moved to `/vendor`
partition, which allegedly doesn't need building from users. Unfortunately, that
is not the case since quite a few proprietary executables, DSOs and APKs/JARs
located under `/system` are required in order to have a fully functional set of
images, although are missing from AOSP public tree. Additionally, if
`vendor.img` is not generated when `system.img` is prepared for build, a few
bits are broken that also require manual fixing (various symbolic links between
two partitions, bytecode product packages, vendor shared library dependencies,
etc.).

Everyone's hope is that Google **will revise** this policy for its devices.
However until then, missing blobs need to be manually extracted from factory
images, processed and included into AOSP tree. These processing steps are
evolving into a total nightmare considering that all recent factory images have
their bytecode (APKs, JARs) pre-optimized to reduce boot time and their original
`classes.dex` stripped to reduce disk size. As such, these missing prebuilt
components need to be repaired/de-optimized prior to be included, since AOSP
build is not capable to import pre-optimized bytecode modules as part of the
makefile tree.

Scripts & tools included in this repository aim to automate the extraction,
processing and generation of vendor specific data using factory images as
input. Data from vendor partition is mirrored to blob includes via a compatible
makefile structure, so that `vendor.img` can be generated from AOSP builds while
specially annotating the vendor APKs to maintain pre-signed certificates and not
pre-optimize. If you have modified the build process (such as CyanogenMod) you
might need to apply additional changes in device configurations / makefiles.

The main concept of this tool-set is to apply all required changes in vendor
makefiles leaving the AOSP source code tree & build chain untouched. Hacks in
AOSP tree, such as those applied by CyanogenMod, are painful to maintain and
very fragile.

Repository data is LICENSE free, use it as you want at your own risk. Feedback
& patches are more than welcome though.


### Status update (12 Feb 2017)
As of 7.1 release Google has started publishing again a set of vendor blobs for
supported Nexus & Pixel devices. Unfortunately the distributed blobs still miss
some functionality when compiled under AOSP:

* Vendor partition is distributed in a form that does not allow to enable
verified boot (dm-verity) against it
* Distributed blobs do not include APK bytecode vendor packages, only some jar
files. It is still unclear to what extent device functionalities are broken.
* Due to missing proprietary modules, required modules present in AOSP are not
included as active dependencies resulting into skipped functionality (e.g. IMS,
RCS).

### Status update (15 Sep 2017)
As of Oreo release (8.0) Google has improved the state of the proprietary vendor
blobs for Pixel devices. State of supported Nexus devices has not changed much.
For Pixel devices most vendor specific resources have been moved to vendor
partition and thus simplify & reduce the amount of work that needs to be done
to include /system dependencies. Furthermore, the original bytecode is no longer
stripped from the factory APKs, enabling an easier inclusion of these resources
to the generated vendor makefiles.


## Required steps summary
The process to extract and import vendor proprietary blobs requires to:

1. Obtain device matching factory images archive from Google developer website
(`scripts/download-nexus-image.sh`)
   * Users need to accept Google ToS for Nexus factory images
2. Extract images from archive, convert from sparse to raw, mount with ext4fuse
& extract data (`scripts/extract-factory-images.sh`)
   * All vendor partition data are mirrored in order to generate a production
   identical `vendor.img`
3. Repair bytecode (APKs/JARs) from factory system image (
`scripts/system-img-repair.sh`) using one of supported bytecode de-optimization
methods (see next paragraph for details)
4. Generate vendor proprietary includes & makefiles compatible with AOSP build
tree (`scripts/generate-vendor.sh`)
   * Extra care in Makefile rules to not break compatibility among supported
   AOSP branches

`execute-all.sh` runs all previous steps with required order. As an alternative
to download images from Google's website, script can also read factory images
from file-system location using the `-i|--img` flag.

`-k|--keep` flag can be used if you want to keep extracted intermediate files
for further investigation. Keep in mind that if used the mount-points from
ext4fuse are not unmounted. So be sure that you manually remove them (or run
the script again without the flag) when done.

All scripts can be executed from macOS, Linux & other Unix-based systems as long
as bash 4.x and other utilized command line tools are installed. Scripts will
abort if any of the required tools is missing from the host.

Scripts include individual usage info and additional flags that be used for
targeted advanced actions, bugs investigation & development of new features.

## Supported bytecode de-optimization methods
### oatdump (Default for API >= 24 or `--oatdump` flag)
Use oatdump host tool (`platform/art` project from AOSP) to extract DEX
bytecode from OAT's ELF `.rodata` section. Extracted DEX is not identical to
original since DEX-to-DEX compiler transformations have already been applied
when code was pre-optimized (more info
[here](https://github.com/anestisb/oatdump_plus#dex-to-dex-optimisations)).
[dexrepair](https://github.com/anestisb/dexRepair) is also used to repair the
extracted DEX file CRC checksum prior to appending bytecode back to matching
APK package from which it has been originally stripped. More info about this
method [here](https://github.com/anestisb/android-prepare-vendor/issues/22).

### baksmali / smali (`--smali` flag)
Use baksmali disassembler against target OAT file to generate a smali syntaxed
output. Disassembling process relies on boot framework files (which are
automatically include) to resolve class dependencies. Baksmali output is then
forwarded to smali assembler to generate a functionally equivalent DEX bytecode
file.

### SmaliEx *[DEPRECATED]* (Default for API-23 or `--smaliex` flag)
SmaliEx is an automation tool that is using baksmali/smali at the background and
is smoothly handling all the required disassembler/assembler iterations and
error handling. Unfortunately due to not quickly catching-up with upstream smali
& dexlib it has been deprecated for now.

## Configuration files explained
### Naked vs Full
Naked configuration group (enabled by default when using the master script)
includes data & module targets required to have a functional device from AOSP
without installing non-essential OEM packages. With this setup using Google Play
Services / Google Apps will probably not work.

On the other hand the full configuration group (enabled with `-f|--full` flag
from master script) has additional blobs & module targets which are normally
marked as non-essential, although might be required for some carriers or in case
of GApps being installed (either manually post-boot or included as additional
vendor blobs).


## Supported devices
| Device                          | API 23                      | API 24           | API 25           | API 26  | API 27  | API 28  |
| ------------------------------- | --------------------------- | -----------------| -----------------| --------| --------| --------|
| N5x bullhead                    | smaliex<br>smali<br>oatdump | oatdump<br>smali | oatdump<br>smali | oatdump | oatdump | N/A     |
| N6p angler                      | smaliex<br>smali<br>oatdump | oatdump<br>smali | oatdump<br>smali | oatdump | oatdump | N/A     |
| N9 flounder<br> WiFi (volantis) | smaliex<br>smali<br>oatdump | oatdump<br>smali | oatdump<br>smali | N/A     | N/A     | N/A     |
| N9 flounder<br> LTE (volantisg) | smaliex<br>smali<br>oatdump | oatdump<br>smali | oatdump<br>smali | N/A     | N/A     | N/A     |
| Pixel sailfish                  | N/A                         | N/A              | oatdump<br>smali | oatdump | oatdump | oatdump |
| Pixel XL marlin                 | N/A                         | N/A              | oatdump<br>smali | oatdump | oatdump | oatdump |
| Pixel 2 walleye                 | N/A                         | N/A              | N/A              | oatdump | oatdump | oatdump |
| Pixel 2 XL taimen               | N/A                         | N/A              | N/A              | oatdump | oatdump | oatdump |
| Pixel 3 blueline                | N/A                         | N/A              | N/A              | N/A     | N/A     | oatdump |
| Pixel 3 XL crosshatch           | N/A                         | N/A              | N/A              | N/A     | N/A     | oatdump |
| Pixel 3a sargo                  | N/A                         | N/A              | N/A              | N/A     | N/A     | oatdump |
| Pixel 3a XL bonito              | N/A                         | N/A              | N/A              | N/A     | N/A     | oatdump |


Please check existing
[issues](https://github.com/anestisb/android-prepare-vendor/issues) before
reporting new ones

## Contributing
If you want to contribute to device configuration files, please test against the
target device before any pull request.

## Change Log
* 0.6.0 - TBC
  * Android 9 (API-28) support for Pixel 3a (sargo) & Pixel 3a XL (bonito)
  * Android 9 (API-28) support for Pixel 3 (blueline) & Pixel 3 XL (crosshatch)
  * Improve support for deterministic builds (`--timestamp` option)
  * Compatibility fixes in image downloader logic
  * Create output directory if does not exist
  * Remove prebuilts that are available in AOSP
* 0.5.0 - 4 September 2018
  * Android 9 (API-28) support for Pixel (sailfish), Pixel XL (marlin), Pixel 2 (walleye) & Pixel 2
    XL (taimen)
  * Developed an oatdump patch (see
    [here](https://gist.github.com/anestisb/26ecf8ae13746dc476eddd8d04a5dd23)) to handle CompactDex
    introduced in Android 9
  * Use env's TMPDIR if set instead of defaulting to /tmp
  * Restore option to mount with fuse-ext2 (`--fuse-ext2`)
  * Add option to mount via loopback when running script as root
  * oatdump repair method performance improvements
  * Improve error handling and output formating
* 0.4.1 - 11 August 2018
  * Pixel 2 (walleye) support for API 26 & 27
  * Pixel 2 XL (taimen) support for API 26 & 27 (credits to @deeproot2k)
  * Improve debugfs error checking due to improper symlink parsing from some versions
  * Deprecate fuse-ext2 and replace with ext4fuse
  * Update simg2img binaries for Darwin & Linux
* 0.4.0 - 9 December 2017
  * Refactored configuration files
  * API-27 support: Pixel, Pixel XL, Nexus 6p, Nexus 5x
  * Various code cleanups
* 0.3.0 - 9 October 2017
  * Initial support for Android Oreo (API-26): Pixel, Pixel XL, Nexus 6p, Nexus
  5x
  * Add support for vendor overlays in order to override default AOSP resources
  that are tweaked for specific devices
* 0.2.1 - 1 July 2017
  * Upgrade to smali/baksmali 2.2.1
  * Add support to maintain presigned APKs
  * Add missing AB partitions for Pixel OTA images
  * Fixed Pixel TimeService bug by adding `system/app/TimeService.apk` to
  extract list
* 0.2.0 - 13 May 2017
  * Renamed GPlay configuration to Full configuration
  * Support for Pixel devices
  * Output can be directly set to AOSP SRC ROOT
  * Experimental debugfs support as an alternative to fuse-ext2
  * Bug fixes when processing symbolic links from vendor partition
  * Preserve symbolic links when processing vendor partition
  * Android 7.1 support for Nexus devices (API-25)
  * Follow HTTP redirects when downloading factory images
* 0.1.7 - 8 Oct 2016
  * Nexus 9 LTE (volantisg) support
  * Offer option to de-optimize all packages under /system despite configuration
  settings
  * Deprecate SmaliEx and use baksmali/smali as an alternative method to deodex
  bytecode
  * Improve supported bytecode deodex methods modularity - users can now
  override default methods
  * Global flag to disable /system `LOCAL_DEX_PREOPT` overrides from vendor
  generate script
  * Respect `LOCAL_MULTILIB` `32` or `both` when 32bit bytecode prebuilts
  detected at 64bit devices
* 0.1.6 - 4 Oct 2016
  * Download automation compatibility with refactored Google Nexus images
  website
  * Bug fixes when generating from OS X
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
  * Read directly data from mount points - deprecate local rsync copies for
  speed
  * Add OS X support (requires OSXFuse)
  * Improved device configuration layers / files
  * AOSP compatibility bug fixes & performance optimizations

## Warnings
* No binary vendor data against supported devices will be maintained in this
repository. Scripts provide all necessary automation to generate them yourself.
* No promises on how the device configuration files will be maintained. Feel
free to contribute if you detect that something is broken, missing or not
required.
* Host tool binaries are provided for convenience, although with no promises
that will be kept up-to-date. Prefer to adjust your env. with upstream versions
and keep them updated.
* If you experience `already defined` type of errors when AOSP makefiles are
included, you have other vendor makefiles that define the same packages (e.g.
hammerhead vs bullhead for LGE vendor). This issue is due to other vendor
makefiles not wrapping them with `ifeq ($(TARGET_DEVICE),<device_model>)`.
Wrap conflicting makefiles with device matching clauses to resolve the issue.
* If Smali or SmaliEx de-optimization method is chosen, Java 8 is required for
the bytecode repair process to work.
* Bytecode repaired with oatdump method might not be able to be pre-optimized
when building AOSP. As such generated targets have `LOCAL_DEXPREOPT := false`.
This is because host dex2oat is invoked with more strict flags and results into
aborting when front-end reaches already optimized instructions. You can use
`--force-opt` flag if you have modified the default host dex2oat bytecode
pre-compilation flags.
* If you're planning to deliver OTA updates for Nexus 5x, you need to manually
extract `update-binary` from a factory OTA archive since it's missing from
the AOSP tree due to some proprietary LG code.
* Nexus 9 WiFi (volantis) & Nexus 9 LTE (volantisg) vendor blobs cannot co-exist
under same AOSP root directory. Since AOSP defines a single flounder target for
both boards, lots of definitions will conflict and create problems when building.
As such ensure that only one of them is present when building for desired
target. Generated makefiles include an additional defensive check that will
raise a compiler error when both are detected under same AOSP root.
* If tool output is not set to AOSP root directory, prefer `rsync` instead of
`cp` or `mv` commands to copy the generated directory structure to different
location. Some device configurations (e.g. Pixel/Pixel XL) share some root
directories and might break if `cp` or `mv` are invoked with the wrong base
paths.


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
