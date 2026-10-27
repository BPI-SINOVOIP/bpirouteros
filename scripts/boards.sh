#!/bin/bash
# Copyright (C) 2026 Ning <mimallaus@gmail.com>
# boards.sh — Per-board build definitions. Source this file, then call board_init <board>.
#
# Firmware A/B / recovery params. One shared logic,
# one template; each board only supplies parameters. Fields:
#   SOC            mt7981b|mt7986a|mt7987a|mt7988a
#   PROD_MEDIUM    product run medium: emmc|nand
#   AB_SUBSTRATE   A/B substrate: mmc-part|ubi-vol
#   ENV_LOC        u-boot env location: mmc|ubi
#   PROVISION_SRC  install source: sd|snand-factory|factory.ubi|tftp
#   AB_POLICY      ab | single+recovery
#   NAND_SIZE      raw NAND size (golden/recovery sizing)
#   AB_ENABLED     yes = enable A/B firmware rollback and provisioning.
# env-seed params (consumed by build-full.sh when AB_ENABLED=yes & PROVISION_SRC=sd):
#   ENV_SIZE           CONFIG_ENV_SIZE, mkenvimage -s
#   ENV_SEED_OFFSET_MB offset in sdcard.img to drop the env image (inside the
#                      provisioning install region so it rides SD->NAND->eMMC)
#   ENV_DEFCONFIG_TAG  build_dir path tag locating tools/mkenvimage + the defenv
#   ENV_DEFENV_NAME    defenv filename under defenvs/

# Product families: r4, r4-lite, r4-pro (8X/4E), r3, r3-mini, openwrt-one.
# These span 3 provisioning archetypes — keep ALL of them in mind in any design:
#   (1) SD installer -> eMMC product : r4, r4-pro, r4-lite, r3
#   (2) no-SD, snand-factory -> eMMC : r3-mini
#   (3) NAND-only, A/B in UBI         : openwrt-one
# NOT built: OpenWrt's device id "bananapi_bpi-r4-poe" is not a PoE board and not
# a board at all -- its DEVICE_MODEL is "BPi-R4 2.5GE", its DTS is
# mt7988a-bananapi-bpi-r4-2g5, and it calls Device/bananapi_bpi-r4-common, i.e.
# it is the R4 fitted with a 2.5GbE PHY, differing only by
# mt7988-2p5g-phy-firmware. Only the upstream identifier says "poe". Carrying it
# it as another product would misidentify this hardware variant.
# Re-adding it is cheap if the variant ever arrives: profile bananapi_bpi-r4-poe,
# everything else identical to r4 plus that one firmware package.
# r4-pro had ZERO OpenWrt support in this tree (no DTS/u-boot/recipe); it was
# brought up (BPI-R4 Pro 8X, MT7988A) from mainline (Frank-w) DTS + OpenWrt
# PR #21083 back-ported to kernel 6.12, then wired to archetype-1 A/B ~= r4.
# pkg_arch is the architecture OpenWrt builds PACKAGES for, which is not the
# board's CPU subtype. filogic uses the lowest common denominator across the
# subtarget -- aarch64_cortex-a53 -- so r4/r4-lite/r4-pro (a73 cores) still get
# a53 packages, and bin/packages/aarch64_cortex-a73/ never exists.
#
# ARCH below is the CPU subtype and is informational. Anything that looks up a
# package path must use pkg_arch rather than the CPU subtype.
#
# Read from the prepared tree rather than hardcoded, so it follows a target
# change instead of needing to be remembered.
pkg_arch() {
    local cfg="${BPIR_WORK_DIR:-$(dirname "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)")/openwrt}/.config"
    local a
    a=$(sed -n 's/^CONFIG_TARGET_ARCH_PACKAGES="\(.*\)"$/\1/p' "$cfg" 2>/dev/null | head -1)
    echo "${a:-aarch64_cortex-a53}"
}

# feed_dir resolves the bpirouter feed from feeds.conf, which is the only thing
# OpenWrt actually consults. Deriving it here means the staging path and the
# path the build reads cannot disagree -- they have one source.
#
# Two layouts exist and both are legitimate: internally the feed is a sibling
# repository (../bpirouter-feeds), and in a published tree it lives inside
# (feeds/bpirouter). stage-proprietary-ui.sh had the sibling path hardcoded, so
# in a published tree it unpacked the artifact into a directory outside the tree
# while the build read an empty files/ inside it -- staging reported success and
# the image had no UI.
#
# src-link values are relative to openwrt/feeds/.
feed_dir() {
    local build_dir conf link
    build_dir="${BPIR_BUILD_DIR:-$(dirname "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)")}"
    conf="$build_dir/feeds.conf"
    [ -f "$conf" ] || { echo "feed_dir: no feeds.conf at $conf" >&2; return 1; }
    link=$(sed -n 's/^src-link[[:space:]]\+bpirouter[[:space:]]\+//p' "$conf" | head -1)
    [ -n "$link" ] || { echo "feed_dir: feeds.conf has no bpirouter src-link" >&2; return 1; }
    case "$link" in
        /*) echo "$link" ;;
        *)  python3 -c "import os,sys; print(os.path.normpath(os.path.join(sys.argv[1], sys.argv[2])))" \
                "$build_dir/openwrt/feeds" "$link" ;;
    esac
}

# VALID_BOARDS is the release set, not merely a spelling check: make-release-lock
# writes it into the lock, rebuild-all builds every entry, and collect/manifest/
# release-gate all iterate it. Every member must therefore be buildable today.
VALID_BOARDS="bpi-r4  bpi-r4-lite  bpi-r3  bpi-r3-mini  openwrt-one  bpi-r4-pro"

# Identity frozen ahead of implementation. board_init answers for these boards --
# so provenance, artifact naming and SKU checks are settled before any code
# exists -- but they are not in the release set. Once source-complete, explicit
# development prepare/full builds may exercise step 6 without release admission.
# Graduation is not one edit: the board moves to VALID_BOARDS, sets
# BOARD_IMPLEMENTED=yes, gains a non-empty RELEASE_REQUIRED_FILES and its
# provisioning fields, and needs its config and patches to exist. Half of that
# is what test-sku-identity.sh checks, because a partial graduation is what puts
# an unbuildable or contract-less board into the release set. bpi-r4-pro-4e
# is selected by the release-specific board set below; the lock must match it.
PLANNED_BOARDS="bpi-r4-pro-4e"

# Product v1.5.0 includes seven SKUs in both RC and stable releases. Release
# admission does not claim hardware acceptance or clear known issues.
bpir_select_release_boards() {
    VALID_BOARDS="bpi-r4 bpi-r4-lite bpi-r3 bpi-r3-mini openwrt-one bpi-r4-pro"
    PLANNED_BOARDS="bpi-r4-pro-4e"
    if [[ "$1" =~ ^v1\.5\.0(-rc[1-9][0-9]*)?$ ]]; then
        VALID_BOARDS+=" bpi-r4-pro-4e"
        PLANNED_BOARDS=""
    fi
}

board_init() {
    BOARD="$1"
    # A/B defaults; per-board case overrides. AB_ENABLED=no => env-seed skipped,
    # i.e. identical to pre-param behavior (the case for un-onboarded boards).
    SOC=""; PROD_MEDIUM=""; AB_SUBSTRATE=""; ENV_LOC=""; PROVISION_SRC=""
    AB_POLICY=""; NAND_SIZE=""; AB_ENABLED="no"
    # Identity may be frozen before the boot chain, DTS and config exist. A board
    # that answers board_init but cannot yet produce a tree or an image says so
    # here, so the refusal names the missing work instead of surfacing as a
    # missing config file three scripts later.
    BOARD_IMPLEMENTED="yes"
    ENV_SIZE=""; ENV_SEED_OFFSET_MB=""; ENV_DEFCONFIG_TAG=""; ENV_DEFENV_NAME=""
    case "$BOARD" in
        bpi-r4)
            PROFILE="bananapi_bpi-r4"
            ARCH="aarch64_cortex-a73"
            TARGET="mediatek/filogic"
            # MT7996 tri-band Wi-Fi 7; kmod-mt7996-233-firmware is the 233MHz radio variant
            WIFI_PKGS="kmod-mt7996e kmod-mt7996-firmware kmod-mt7996-233-firmware mt7988-wo-firmware wpad-mbedtls -wpad-basic-mbedtls"
            SOC="mt7988a"; PROD_MEDIUM="emmc"; AB_SUBSTRATE="mmc-part"
            ENV_LOC="mmc"; PROVISION_SRC="sd"; AB_POLICY="ab"; NAND_SIZE="128M"
            AB_ENABLED="yes"
            ENV_SIZE="0x40000"; ENV_SEED_OFFSET_MB="25"
            ENV_DEFCONFIG_TAG="bananapi_bpi-r4-emmc"; ENV_DEFENV_NAME="bananapi_bpi-r4_emmc_env"
            ;;
        bpi-r4-lite)
            # BPi-R4 Lite — MT7987A SoC (not MT7988A), Wi-Fi 7, no Aquantia 10G
            PROFILE="bananapi_bpi-r4-lite"
            ARCH="aarch64_cortex-a73"
            TARGET="mediatek/filogic"
            WIFI_PKGS="kmod-mt7996e kmod-mt7996-firmware kmod-mt7996-233-firmware mt7987-2p5g-phy-firmware wpad-mbedtls -wpad-basic-mbedtls"
            SOC="mt7987a"; PROD_MEDIUM="emmc"; AB_SUBSTRATE="mmc-part"
            ENV_LOC="mmc"; PROVISION_SRC="sd"; AB_POLICY="ab"; NAND_SIZE="128M"
            AB_ENABLED="yes"
            ENV_SIZE="0x40000"; ENV_SEED_OFFSET_MB="25"   # r4-lite eMMC env = R4/R3 layout (0x40000 @ 0x400000/0x440000)
            ENV_DEFCONFIG_TAG="bananapi_bpi-r4-lite-emmc"; ENV_DEFENV_NAME="bananapi_bpi-r4-lite_emmc_env"
            ;;
        bpi-r3)
            PROFILE="bananapi_bpi-r3"
            ARCH="aarch64_cortex-a53"
            TARGET="mediatek/filogic"
            # MT7986A integrated Wi-Fi 6; kmod-mt7986-firmware + WO offload firmware
            WIFI_PKGS="kmod-mt7915e kmod-mt7986-firmware mt7986-wo-firmware wpad-mbedtls -wpad-basic-mbedtls"
            SOC="mt7986a"; PROD_MEDIUM="emmc"; AB_SUBSTRATE="mmc-part"
            ENV_LOC="mmc"; PROVISION_SRC="sd"; AB_POLICY="ab"; NAND_SIZE="128M"
            AB_ENABLED="yes"
            ENV_SIZE="0x40000"; ENV_SEED_OFFSET_MB="25"   # R3 eMMC env = R4 layout (0x40000 @ 0x400000/0x440000)
            ENV_DEFCONFIG_TAG="bananapi_bpi-r3-emmc"; ENV_DEFENV_NAME="bananapi_bpi-r3_emmc_env"
            ;;
        bpi-r3-mini)
            # BPI-R3 Mini (schematic BPI-R3mini-V10) — MT7986A, eMMC + SPI-NAND,
            # NO SD slot; Airoha EN8811H 2.5G PHY. Archetype 2: provisioning via
            # snand-factory (no SD installer hop). Pkgs mirror r3 + en8811 — verify
            # against OpenWrt bananapi_bpi-r3-mini DEVICE_PACKAGES at first build.
            PROFILE="bananapi_bpi-r3-mini"
            ARCH="aarch64_cortex-a53"
            TARGET="mediatek/filogic"
            WIFI_PKGS="kmod-mt7915e kmod-mt7986-firmware mt7986-wo-firmware kmod-phy-airoha-en8811h wpad-mbedtls -wpad-basic-mbedtls"
            SOC="mt7986a"; PROD_MEDIUM="emmc"; AB_SUBSTRATE="mmc-part"
            ENV_LOC="mmc"; PROVISION_SRC="snand-factory"; AB_POLICY="ab"; NAND_SIZE="128M"
            AB_ENABLED="yes"
            ;;
        openwrt-one)
            PROFILE="openwrt_one"
            ARCH="aarch64_cortex-a53"
            TARGET="mediatek/filogic"
            # MT7981B integrated Wi-Fi 6 dual-band + Airoha EN8811H 2.5G WAN PHY
            WIFI_PKGS="kmod-mt7915e kmod-mt7981-firmware mt7981-wo-firmware kmod-phy-airoha-en8811h wpad-mbedtls -wpad-basic-mbedtls"
            SOC="mt7981b"; PROD_MEDIUM="nand"; AB_SUBSTRATE="ubi-vol"
            ENV_LOC="ubi"; PROVISION_SRC="factory.ubi"; AB_POLICY="ab"; NAND_SIZE="256M"  # SPI-NAND holds the whole system incl A/B; two 80M overlays and two FIT volumes
            AB_ENABLED="yes"
            ;;
        bpi-r4-pro)
            # BPI-R4 Pro 8X (schematic BPI-R4Pro-V10) — MT7988A like r4, 8GB DDR4,
            # eMMC + 256M SPI-NAND (W25N02GV) + microSD. Archetype 1 (SD->eMMC); A/B
            # logic reuses r4. Brought up from mainline (Frank-w) DTS + OpenWrt PR
            # #21083 back-ported to kernel 6.12 (this tree had zero r4-pro support).
            # ATF (PLAT=mt7988, DDR4) and ramoops@0x42ff0000 reuse r4 as-is (vendor
            # BSP boot log confirms 8GB DDR4 trains + pstore at 0x42ff0000).
            # MxL862xx and AS21xxx are modules. START=19 makes a bounded PHY
            # preparation attempt, then loads the switch once, without rebinding it.
            # PHY readiness requires the firmware-backed driver, not just a netdev.
            # Integer-second polling supports BusyBox without FEATURE_FLOAT_SLEEP.
            # LAN: lan1, mxl_lan0..4; WAN: eth1; lan4 is the GbE FPC header.
            # Patch 999 disables unrouted internal-switch ports; 999a adds PWM fan
            # control for the two non-inverted headers on channel 0.
            PROFILE="bananapi_bpi-r4-pro-8x"
            ARCH="aarch64_cortex-a73"
            TARGET="mediatek/filogic"
            # WiFi NIC = BE14/MT7996 family (same as r4). The 2.5G/10G PHY support is
            # in-tree via kernel patches, so no extra WIFI_PKGS entries are needed.
            WIFI_PKGS="kmod-mt7996e kmod-mt7996-firmware kmod-mt7996-233-firmware mt7988-wo-firmware wpad-mbedtls -wpad-basic-mbedtls"
            SOC="mt7988a"; PROD_MEDIUM="emmc"; AB_SUBSTRATE="mmc-part"
            ENV_LOC="mmc"; PROVISION_SRC="sd"; AB_POLICY="ab"; NAND_SIZE="256M"
            AB_ENABLED="yes"
            ENV_SIZE="0x40000"; ENV_SEED_OFFSET_MB="25"   # r4-pro eMMC env = R4 layout (0x40000 @ 0x400000/0x440000)
            ENV_DEFCONFIG_TAG="bananapi_bpi-r4-pro-8x-emmc"; ENV_DEFENV_NAME="bananapi_bpi-r4-pro-8x_emmc_env"
            ;;
        bpi-r4-pro-4e)
            # Second SKU of the R4-Pro family, not a runtime variant of the 8X:
            # 4GB DDR4, no AS21010P, and a boot-time static WAN combo. Frozen from
            # CM99.Block Diagram 4E, sheet 21 of BPI-R4Pro-V10-SCH-20250806.pdf
            # bpi-r4-pro keeps meaning the 8X exactly and
            # is not renamed, so every R4-Pro artifact name carries 8x or 4e.
            #
            # Release admission is selected by bpir_select_release_boards.
            PROFILE="bananapi_bpi-r4-pro-4e"
            ARCH="aarch64_cortex-a73"
            TARGET="mediatek/filogic"
            SOC="mt7988a"
            WIFI_PKGS="kmod-mt7996e kmod-mt7996-firmware kmod-mt7996-233-firmware mt7988-wo-firmware wpad-mbedtls -wpad-basic-mbedtls"
            PROD_MEDIUM="emmc"; AB_SUBSTRATE="mmc-part"
            ENV_LOC="mmc"; PROVISION_SRC="sd"; AB_POLICY="ab"; NAND_SIZE="256M"
            ENV_SIZE="0x40000"; ENV_SEED_OFFSET_MB="25"
            ENV_DEFCONFIG_TAG="bananapi_bpi-r4-pro-4e-emmc"; ENV_DEFENV_NAME="bananapi_bpi-r4-pro-4e_emmc_env"
            AB_ENABLED="yes"
            BOARD_IMPLEMENTED="yes"
            ;;
        *)
            echo "Unknown board: $BOARD"
            echo "Valid boards: $VALID_BOARDS"
            echo "Planned (no release admission): $PLANNED_BOARDS"
            exit 1
            ;;
    esac

    # Formal completeness is an exact filename contract: an unrelated eMMC FIP
    # or NOR factory image cannot stand in for the provisioning artifact.
    RELEASE_BASE="openwrt-mediatek-filogic-$PROFILE"
    case "$BOARD" in
        bpi-r4)
            RELEASE_REQUIRED_FILES="
$RELEASE_BASE-emmc-bl31-uboot.fip
$RELEASE_BASE-emmc-gpt.bin
$RELEASE_BASE-emmc-preloader.bin
$RELEASE_BASE-initramfs-kernel.bin
$RELEASE_BASE-sdcard.img.gz
$RELEASE_BASE-snand-bl31-uboot.fip
$RELEASE_BASE-snand-preloader.bin
$RELEASE_BASE-squashfs-sysupgrade.itb
$RELEASE_BASE.manifest"
            ;;
        bpi-r4-lite)
            RELEASE_REQUIRED_FILES="
$RELEASE_BASE-emmc-bl31-uboot.fip
$RELEASE_BASE-emmc-gpt.bin
$RELEASE_BASE-emmc-preloader.bin
$RELEASE_BASE-initramfs-kernel.bin
$RELEASE_BASE-nor-bl31-uboot.fip
$RELEASE_BASE-nor-preloader.bin
$RELEASE_BASE-sdcard.img.gz
$RELEASE_BASE-snand-bl31-uboot.fip
$RELEASE_BASE-snand-preloader.bin
$RELEASE_BASE-squashfs-sysupgrade.itb
$RELEASE_BASE.manifest"
            ;;
        bpi-r4-pro)
            RELEASE_REQUIRED_FILES="
$RELEASE_BASE-emmc-bl31-uboot.fip
$RELEASE_BASE-emmc-gpt.bin
$RELEASE_BASE-emmc-preloader.bin
$RELEASE_BASE-initramfs-kernel.bin
$RELEASE_BASE-sdcard.img.gz
$RELEASE_BASE-snand-bl31-uboot.fip
$RELEASE_BASE-snand-preloader.bin
$RELEASE_BASE-squashfs-sysupgrade.itb
$RELEASE_BASE.manifest"
            ;;
        bpi-r3)
            RELEASE_REQUIRED_FILES="
$RELEASE_BASE-emmc-bl31-uboot.fip
$RELEASE_BASE-emmc-gpt.bin
$RELEASE_BASE-emmc-preloader.bin
$RELEASE_BASE-initramfs-kernel.bin
$RELEASE_BASE-nor-bl31-uboot.fip
$RELEASE_BASE-nor-preloader.bin
$RELEASE_BASE-sdcard.img.gz
$RELEASE_BASE-snand-bl31-uboot.fip
$RELEASE_BASE-snand-preloader.bin
$RELEASE_BASE-squashfs-sysupgrade.itb
$RELEASE_BASE.manifest"
            ;;
        bpi-r3-mini)
            RELEASE_REQUIRED_FILES="
mt7986-ram-ddr4-bl2.bin
$RELEASE_BASE-emmc-bl31-uboot.fip
$RELEASE_BASE-emmc-gpt.bin
$RELEASE_BASE-emmc-preloader.bin
$RELEASE_BASE-flashkit.tar.gz
$RELEASE_BASE-initramfs-kernel.bin
$RELEASE_BASE-snand-bl31-uboot.fip
$RELEASE_BASE-snand-factory.bin
$RELEASE_BASE-snand-preloader.bin
$RELEASE_BASE-squashfs-sysupgrade.itb
$RELEASE_BASE.manifest"
            ;;
        openwrt-one)
            RELEASE_REQUIRED_FILES="
mt7981-ram-ddr4-bl2.bin
$RELEASE_BASE-factory.ubi
$RELEASE_BASE-flashkit.tar.gz
$RELEASE_BASE-initramfs.itb
$RELEASE_BASE-nor-bl31-uboot.fip
$RELEASE_BASE-nor-factory.bin
$RELEASE_BASE-nor-preloader.bin
$RELEASE_BASE-ram-bl31-uboot.fip
$RELEASE_BASE-snand-bl31-uboot.fip
$RELEASE_BASE-snand-factory.bin
$RELEASE_BASE-snand-preloader.bin
$RELEASE_BASE-squashfs-sysupgrade.itb
$RELEASE_BASE.manifest"
            ;;
        bpi-r4-pro-4e)
            # Same media roles, independently SKU-named ordinary comb inputs.
            # PLANNED_BOARDS still refuses release publication during step 6.
            RELEASE_REQUIRED_FILES="
$RELEASE_BASE-emmc-bl31-uboot.fip
$RELEASE_BASE-emmc-gpt.bin
$RELEASE_BASE-emmc-preloader.bin
$RELEASE_BASE-initramfs-kernel.bin
$RELEASE_BASE-sdcard.img.gz
$RELEASE_BASE-snand-bl31-uboot.fip
$RELEASE_BASE-snand-preloader.bin
$RELEASE_BASE-squashfs-sysupgrade.itb
$RELEASE_BASE.manifest"
            ;;
        *)
            # Fail closed. This case had no default arm, so a board registered
            # above but forgotten here got an empty contract -- and an empty
            # required-file set treats any set of outputs, including none, as a
            # complete release.
            echo "No release file contract for board: $BOARD" >&2
            exit 1
            ;;
    esac
}
