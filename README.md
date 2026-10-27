# BpiRouterOS

This repository provides the project sources, board configurations, patches and
package recipes needed to build BpiRouter firmware, together with the matching
precompiled UI/APID package. Private source repository access is not required.

For product support, contact [Banana Pi](https://www.banana-pi.org/contact-us/)
or use the [official forum](https://forum.banana-pi.org/).

## User guides

| Guide | English | Chinese |
|---|---|---|
| Features and use | [Features](FEATURES.md) | [Features (Chinese)](FEATURES.zh-CN.md) |
| Installation | [Installation](INSTALLATION.md) | [Installation (Chinese)](INSTALLATION.zh-CN.md) |

The feature guide identifies the product release it describes. Use the matching
guide and installation files for your hardware. The sections below describe
building the software, not operating or installing the router.

## 1. Prepare the build host

Use x86_64 Debian/Ubuntu Linux and build as an ordinary user, not root or sudo.
At least 16 GB RAM and 100 GB free disk space are recommended. Reduce parallelism
if memory is limited. Use a local Linux filesystem path without spaces.
Network access to GitHub and upstream download sites is required. The first build
downloads sources and builds the toolchain; duration depends on the host and network.

Install dependencies (sudo is used only to install host packages):

```bash
sudo apt update
sudo apt install build-essential clang flex bison g++ gawk gcc-multilib \
  g++-multilib gettext git libncurses-dev libssl-dev python3 python3-setuptools \
  rsync swig unzip zlib1g-dev file wget curl ca-certificates jq \
  tar gzip bzip2 xz-utils zstd patch perl util-linux squashfs-tools
```

The delivery archive uses gzip. Upstream dependencies may use other compression
formats, so their extraction tools are still required.

## 2. Obtain the repository

Copy the URL from **Code → HTTPS** on this GitHub repository's page and replace
the placeholder below:

```bash
git clone <repository-https-url> bpirouteros
cd bpirouteros
```

Alternatively, use the supplied archive:

```bash
sha256sum -c bpirouteros.tgz.sha256
tar -xzf bpirouteros.tgz
cd bpirouteros
```

Do not extract over an existing directory containing local changes. The public
repository is updated for subsequent releases. To use historical inputs, check
out the maintainer's corresponding commit or tag. Save local changes before updating.

## 3. Inspect the version and select a board

This README is not tied to a specific release. The version, upstream commits,
board set and UI hashes are recorded in `RELEASE-INPUTS.lock.json` for this
checkout. Do not mix locks, patches or UI APKs from different revisions.

When `source_delivery` is present in that lock, it describes revised public
sources, not the exact inputs originally used to produce the downloadable
firmware. `FIRMWARE-INPUTS.lock.json` preserves the original firmware lock,
bound by its SHA-256. The public lock records current patch/config hashes;
the upstream revisions, board set and UI package remain pinned. Its `repos`
field retains the original firmware repository revisions. The delivery's
`build_source_revision` identifies the revised build-source commit when known;
null means that no committed source revision is claimed. Public Git history
identifies the checkout you are building. The build still verifies input hashes.

If present, `SOURCE-DELIVERY.json` records reviewed SD and flashkit post-build
metadata corrections to the supplied scripts. They fix final checksum/size
records without changing the locked firmware configuration or UI package.
This is a source-delivery revision, not evidence that the original published
images used those scripts.

```bash
jq -r '.release, .openwrt.tag' RELEASE-INPUTS.lock.json
jq -r '.boards[]' RELEASE-INPUTS.lock.json
jq -r '.boards_unbuildable_publicly[]?' RELEASE-INPUTS.lock.json
```

Boards listed by the third command lack publicly distributable inputs and cannot
be built using these instructions. Build availability does not establish hardware
acceptance; consult the release notes for per-SKU limitations.

| Hardware | BOARD |
|---|---|
| BPI-R4 | `bpi-r4` |
| BPI-R3 | `bpi-r3` |
| BPI-R4-Lite | `bpi-r4-lite` |
| BPI-R3-Mini | `bpi-r3-mini` |
| OpenWrt One | `openwrt-one` |
| BPI-R4-Pro 8X | `bpi-r4-pro` |
| BPI-R4-Pro 4E | `bpi-r4-pro-4e` |

The current lock's board list is authoritative. Do not interchange 8X and 4E.

## 4. Build firmware with the Web interface and API

Run these commands from the repository root. R4 is the example; change BOARD
for another supported model.

```bash
BOARD=bpi-r4
export OPENWRT_VERBOSE=s
./scripts/prepare.sh --board "$BOARD" \
  --ui-artifact ./proprietary-artifacts/bpirouter-ui.apk
./scripts/build-full.sh --board "$BOARD" --jobs 4
```

`prepare.sh` downloads the pinned OpenWrt and feeds, applies patches, selects
the configuration, and verifies and stages the UI APK. On a fresh tree it also
builds the required host tools. Do not separately update feeds, run menuconfig
or copy private UI files. `build-full.sh` downloads and verifies dependencies,
then compiles the images. Both commands must exit successfully.
Adjust `--jobs` to suit the host without changing sources or configuration.

On failure, keep the error output and do not treat leftover images as successful
builds. To capture a diagnostic build log:

```bash
set -o pipefail
./scripts/build-full.sh --board "$BOARD" --jobs 1 2>&1 | tee build.log
```

When changing boards in the same directory, rerun both commands. Do not build
multiple boards concurrently in one tree. After updating the repository, run
prepare again before building. Use a new clone in a separate directory when
you need to exclude the effects of old build caches.

## 5. Locate the artifacts

```bash
ls -lh openwrt/bin/targets/mediatek/filogic/
```

Select files by the chosen hardware name, not another board's images in the
shared output directory.

- `*squashfs-sysupgrade.itb`: upgrade image; applicability depends on the installation/upgrade instructions.
- `*sdcard.img.gz`: SD installation media for applicable boards, used to provision onboard storage.
- `*factory.ubi` / `*snand-factory.bin`: NAND installation artifacts for applicable boards.
- `*initramfs*`, `*preloader.bin`, `*bl31-uboot.fip`: boot/recovery files; do not interchange or flash arbitrarily.
- `*flashkit.tar.gz`: recovery kit for applicable boards; follow its matching runbook.
- `*.manifest`: package version list.

Not every board produces every file type above. These are build instructions,
not flashing instructions. Before flashing, verify the hardware, storage medium
and corresponding installation/recovery procedure. A successful build does not
establish successful flashing or hardware acceptance.

## Inputs, UI and licensing

Project code, configurations and patches are included. Upstream OpenWrt, feeds
and download caches are not included; the build retrieves them over the network.
`proprietary-artifacts/bpirouter-ui.apk` contains the matching UI static assets
and APID binary, not their private source. Its separate licence is in
`proprietary-artifacts/LICENSE`. It is not part of the GPL corresponding source;
its proprietary terms do not restrict the GPL-covered parts of this repository.
See `LICENSE`, `LICENSING.md` and the notices in `feeds/bpirouter/` for other
licences and third-party attribution.

To build without the proprietary package, use the following commands instead
of section 4. The resulting image has no BpiRouter Web interface or APID and
does not provide the same functionality as the published product image.
R4 is the example; replace BOARD with the appropriate value from the table above.

```bash
BOARD=bpi-r4
./scripts/prepare.sh --board "$BOARD" --without-proprietary-ui
./scripts/build-full.sh --board "$BOARD" --jobs 4
```

The build uses matching software versions, configurations and UI payloads;
byte-identical output compared with published images is not required.
Internal Git history, internal design/acceptance documents and build caches
are not included.
