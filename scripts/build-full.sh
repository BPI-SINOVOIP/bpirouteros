#!/bin/bash
# Copyright (C) 2026 Ning <mimallaus@gmail.com>
# build-full.sh — Full firmware build for BpiRouter
# Usage: ./scripts/build-full.sh [--board <board>] [--jobs <n>]
#   --board: bpi-r4 (default), bpi-r4-lite, bpi-r4-pro, bpi-r3, bpi-r3-mini, openwrt-one
# Use when: kernel/U-Boot/feeds have changes
# Time: 1-2 hours for first build, 10-30 minutes for incremental builds
set -eo pipefail

# WSL: drop /mnt/c/* PATH entries — Windows paths with spaces break
# OpenWrt's Makefile shell tokenization and trip GNU find -execdir's
# relative-path safety check.
if grep -qi microsoft /proc/version 2>/dev/null; then
    PATH=$(echo "$PATH" | tr ':' '\n' | grep -v '^/mnt/[a-zA-Z]/' | paste -sd: -)
    export PATH
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$(dirname "$SCRIPT_DIR")"
[ -n "${BPIR_BUILD_DIR:-}" ] && BUILD_DIR="$BPIR_BUILD_DIR"
WORK_DIR="${BPIR_WORK_DIR:-$BUILD_DIR/openwrt}"
C='\033[0;36m'
R='\033[0;31m'
G='\033[0;32m'
N='\033[0m'
step() { echo -e "${C}▸ $1${N}"; }
ok()   { echo -e "${G}✓ $1${N}"; }

# ── Parse args ──
BOARD="bpi-r4"
JOBS="$(nproc)"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --board) BOARD="$2"; shift 2 ;;
        --board=*) BOARD="${1#*=}"; shift ;;
        --jobs) JOBS="$2"; shift 2 ;;
        --jobs=*) JOBS="${1#*=}"; shift ;;
        --release-lock|--release-lock=*) echo "Pass --release-lock to prepare.sh" >&2; exit 2 ;;
        --release) shift ;;  # accepted for compatibility
        [0-9]*) JOBS="$1"; shift ;;   # backward compat: positional jobs count
        *) echo "Unknown argument: $1" >&2; exit 2 ;;
    esac
done

MARKER="$WORK_DIR/.bpirouter-prepared-board"
[ -f "$MARKER" ] || {
    echo -e "${R}✗ OpenWrt tree has no prepare marker; run prepare.sh first${N}" >&2
    exit 1
}
UI_MODE=$(sed -n 's/^ui_mode=//p' "$MARKER" | head -1)
PREPARED_LOCK=$(sed -n 's/^input_lock_path=//p' "$MARKER" | head -1)
RELEASE_BOUND=$(sed -n 's/^release_bound=//p' "$MARKER" | head -1)
DEVELOPMENT_BOUND=$(sed -n 's/^development_bound=//p' "$MARKER" | head -1)
[ -n "$DEVELOPMENT_BOUND" ] || DEVELOPMENT_BOUND=0
case "$DEVELOPMENT_BOUND" in
    0|1) ;;
    *) echo -e "${R}✗ prepared marker has invalid development_bound=$DEVELOPMENT_BOUND${N}" >&2; exit 1 ;;
esac
[ "$RELEASE_BOUND$DEVELOPMENT_BOUND" != 11 ] || {
    echo -e "${R}✗ prepared marker cannot be both release-bound and development-bound${N}" >&2
    exit 1
}
PUBLIC_RELEASE=""
if [ "$RELEASE_BOUND" != 0 ] || [ "$DEVELOPMENT_BOUND" != 0 ]; then
    echo "Re-run prepare.sh in this source tree" >&2
    exit 1
elif [ "$UI_MODE" = artifact ] || { [ "$UI_MODE" = none ] && [ -n "$PREPARED_LOCK" ]; }; then
    # The public board set follows the prepared lock even without the UI.
    # Artifact mode also retains the package version. Neither mode acquires
    # publisher provenance from this tree-scope check.
    PUBLIC_LOCK=$("$SCRIPT_DIR/lib/release-lock-contract.py" find-input --build-dir "$BUILD_DIR" \
        --explicit "${PREPARED_LOCK:-${BPIR_RELEASE_LOCK:-}}") || exit 1
    "$SCRIPT_DIR/check-release-lock.sh" --scope tree "$PUBLIC_LOCK"
    PUBLIC_RELEASE=$("$SCRIPT_DIR/lib/release-lock-contract.py" release-id --input-lock "$PUBLIC_LOCK") || exit 1
    if [ "$UI_MODE" = artifact ]; then
        BPIROUTER_UI_PKG_VERSION=$("$SCRIPT_DIR/lib/release-lock-contract.py" release-version \
            --release "$PUBLIC_RELEASE" --format package)
        export BPIROUTER_UI_PKG_VERSION
    else
        unset BPIROUTER_UI_PKG_VERSION
    fi
else
    # Never let an inherited formal package version make an unbound build look
    # like a product release. The feed then uses its explicit 0.0.0_pre default.
    unset BPIROUTER_UI_PKG_VERSION
fi

# Select the boards admitted by the prepared lock.
source "$SCRIPT_DIR/boards.sh"
bpir_select_release_boards "$PUBLIC_RELEASE"
board_init "$BOARD"

# A board whose identity is frozen but whose implementation is not cannot produce
# this output. Refuse by name so the message points at the missing build prerequisites
# instead of surfacing later as an absent config or an empty file contract.
[ "$BOARD_IMPLEMENTED" = yes ] || {
    echo -e "${R}✗ board $BOARD has a frozen identity without build admission yet${N}" >&2
    echo -e "${R}  board configuration and provisioning support must be complete before building${N}" >&2
    exit 1
}
case " $PLANNED_BOARDS " in
    *" $BOARD "*)
        echo "board $BOARD is not admitted by the selected release" >&2
        exit 1 ;;
esac
step "Board: $BOARD ($PROFILE, $ARCH)"
if [ "$BOARD" = openwrt-one ]; then
    command -v "${BUSYBOX:-busybox}" >/dev/null || { echo "OpenWrt One checks require host busybox (or BUSYBOX)." >&2; exit 1; }
    command -v cc >/dev/null || { echo "OpenWrt One checks require a host C compiler (cc)." >&2; exit 1; }
fi

# Lock before validating the marker. A build that checked first and then waited
# could consume a tree another prepare changed while it was queued.
source "$SCRIPT_DIR/lib/openwrt-build-lock.sh"
bpir_acquire_openwrt_build_lock "$WORK_DIR" || {
    echo -e "${R}✗ cannot acquire the OpenWrt build lock${N}" >&2
    exit 1
}

# ── 0. Refuse to build unless the tree is prepared for THIS board ──
# Deliberately fail-fast and never auto-prepare: this used to test only for the
# directory's existence, which let `--board X` rebuild the previously prepared
# board Y and still exit 0. Auto-preparing here would hide the same mistake
# behind a long rebuild instead of surfacing it.
"$SCRIPT_DIR/check-prepared.sh" "$BOARD"
LOCKED_UI_MODE=$(sed -n 's/^ui_mode=//p' "$MARKER" | head -1)
LOCKED_RELEASE_BOUND=$(sed -n 's/^release_bound=//p' "$MARKER" | head -1)
LOCKED_DEVELOPMENT_BOUND=$(sed -n 's/^development_bound=//p' "$MARKER" | head -1)
[ -n "$LOCKED_DEVELOPMENT_BOUND" ] || LOCKED_DEVELOPMENT_BOUND=0
[ "$LOCKED_UI_MODE" = "$UI_MODE" ] \
    && [ "$LOCKED_RELEASE_BOUND" = "$RELEASE_BOUND" ] \
    && [ "$LOCKED_DEVELOPMENT_BOUND" = "$DEVELOPMENT_BOUND" ] || {
    echo -e "${R}✗ prepare marker changed while build waited for the OpenWrt lock${N}" >&2
    exit 1
}
TARGET_DIR="$WORK_DIR/bin/targets/$TARGET"
BUILD_PROVENANCE="$TARGET_DIR/.bpirouter-build-$BOARD.json"
UI_PROOF="$TARGET_DIR/.bpirouter-ui-$BOARD.json"
BASE="openwrt-mediatek-filogic-$PROFILE"
# Any build attempt invalidates a previous sidecar before it can mutate output.
# A failed or development build must never leave an older release assertion
# beside newer files.
mkdir -p "$TARGET_DIR"
rm -f "$BUILD_PROVENANCE" "$UI_PROOF"
FEEDS_DIR=$(feed_dir)
FEED_FILES="$FEEDS_DIR/net/bpirouter-ui/files"
case "$UI_MODE" in
    artifact)
        # Already staged by prepare.sh, which verified it against the lock. The
        # feed's files/ must still be there: an empty one would make the package
        # build fail on a missing INSTALL_BIN, which reads as a packaging bug
        # rather than a staging one.
        [ -f "$(feed_dir)/net/bpirouter-ui/files/bpirouter-apid" ] || \
            { echo -e "${R}✗ ui_mode=artifact but nothing is staged; re-run prepare.sh --ui-artifact${N}"; exit 1; }
        ok "Using staged UI artifact"
        ;;
    none)
        # Nothing to build, and nothing to check: .config does not select the
        # package, which check-prepared.sh has already confirmed.
        step "UI mode 'none' — building without the BpiRouter UI and API"
        ;;
    *)
        echo -e "${R}✗ no usable ui_mode in the prepare marker (got '${UI_MODE:-empty}')${N}"
        echo "  Re-run prepare.sh with one of --ui-artifact / --without-proprietary-ui" >&2
        exit 1
        ;;
esac

# ── 2. Update feeds ──
step "Updating feeds..."
cd "$WORK_DIR"
./scripts/feeds update bpirouter
./scripts/feeds install -a -f

# Both whole-file-owned configs (mwan3, sqm) must reach the board as product
# state, and every board must carry the bpirouter-base payload that ensures it.
bash "$SCRIPT_DIR/test-release-board-floor.sh"
BPIR_FEEDS_DIR="$FEEDS_DIR" \
BPIR_MWAN3_STOCK="$WORK_DIR/feeds/packages/net/mwan3/files/etc/config/mwan3" \
    "$SCRIPT_DIR/test-mwan3-canonical.sh"
"$SCRIPT_DIR/test-mwan3-route-delete-order.sh"
"$SCRIPT_DIR/test-mwan3-dynamic-child.sh"
# Full kernel behavior runs separately in an isolated user/network namespace.
# Ordinary image builds need no namespace privileges.
BPIR_OPENWRT_DIR="$WORK_DIR" "$SCRIPT_DIR/test-mwan3-routing-reservation.py" --prepared
"$SCRIPT_DIR/test-s2s-reprepare.py" "$WORK_DIR"
"$SCRIPT_DIR/test-tailscale-product-service.py" --prepared "$WORK_DIR/feeds/packages"
"$SCRIPT_DIR/test-ddns-scripts-patches.py" --prepared "$WORK_DIR/feeds/packages"
BPIR_FEEDS_DIR="$FEEDS_DIR" "$SCRIPT_DIR/test-sqm-canonical.sh"
BPIR_FEEDS_DIR="$FEEDS_DIR" "$SCRIPT_DIR/test-offload-disabled.sh"
"$SCRIPT_DIR/test-cellular-package-scope.sh"
"$SCRIPT_DIR/test-cellular-netifd-lifecycle.sh"
"$SCRIPT_DIR/test-netifd-dynamic-ip6assign.sh"
"$SCRIPT_DIR/test-netifd-proto-busy.sh"
"$SCRIPT_DIR/test-kernel-patch-routing.sh"
"$SCRIPT_DIR/test-as21xxx-reprobe.sh"
if [ "$BOARD" = bpi-r4-pro ] || [ "$BOARD" = bpi-r4-pro-4e ]; then
    bash "$SCRIPT_DIR/test-mxl862xx-phy-discovery.sh"
fi
BPIR_FEEDS_DIR="$FEEDS_DIR" "$SCRIPT_DIR/test-factory-reset-rootfs.sh"
BPIR_FEEDS_DIR="$FEEDS_DIR" "$SCRIPT_DIR/test-rootfs-integrity.sh"
BPIR_FEEDS_DIR="$FEEDS_DIR" "$SCRIPT_DIR/test-ipsec-ipv4.sh"
BPIR_FEEDS_DIR="$FEEDS_DIR" "$SCRIPT_DIR/test-factory-wifi-defaults.sh"

# ── 3. Download all source packages ──
step "Downloading source packages..."
make download -j$JOBS

# ── 4. Full compilation ──
step "Building firmware (board=$BOARD, jobs=$JOBS)..."
make -j$JOBS

# This test compiles netifd functions against host libubox. Both are generated
# by the build above; a clean first build has neither at the pre-build gates.
BPIR_OPENWRT_DIR="$WORK_DIR" "$SCRIPT_DIR/test-netifd-host-route.sh"
BPIR_OPENWRT_DIR="$WORK_DIR" "$SCRIPT_DIR/test-netifd-pppoe-mtu.py" --prepared
BPIR_OPENWRT_DIR="$WORK_DIR" "$SCRIPT_DIR/test-nft-mss.py" --prepared
if [ "$BOARD" = openwrt-one ]; then
    # Host libubox and prepared U-Boot sources do not exist before a first build.
    ONE_UBOOT_DIR="$WORK_DIR/build_dir/target-aarch64_cortex-a53_musl/u-boot-mt7981_openwrt_one-nor/u-boot-2025.10"
    OPENWRT_DIR="$WORK_DIR" "$SCRIPT_DIR/test-one-layout.py" --prepared
    OPENWRT_DIR="$WORK_DIR" UBOOT_DIR="$ONE_UBOOT_DIR" "$SCRIPT_DIR/test-one-nor-installer.py" --prepared
    OPENWRT_DIR="$WORK_DIR" UBOOT_DIR="$ONE_UBOOT_DIR" "$SCRIPT_DIR/test-one-mtd-erase.py" --prepared
fi

# Inspect what package installation actually placed in the target rootfs.
# Source-level policy is not evidence that the assembled image kept it.
mapfile -t ASSEMBLED_ROOTS < <(find "$WORK_DIR/build_dir" -maxdepth 2 -type d -name 'root-mediatek' -print 2>/dev/null)
if [ "${#ASSEMBLED_ROOTS[@]}" -ne 1 ]; then
    echo -e "${R}✗ expected exactly one assembled build_dir root-mediatek, found ${#ASSEMBLED_ROOTS[@]}${N}" >&2
    exit 1
fi
ASSEMBLED_ROOT="${ASSEMBLED_ROOTS[0]}"
make package/ucode/host/compile -j"$JOBS"
"$SCRIPT_DIR/test-wifi-segment-isolation.py" "$ASSEMBLED_ROOT/lib/netifd" \
    --ucode "$WORK_DIR/staging_dir/hostpkg/bin/ucode" \
    --module-path "$WORK_DIR/staging_dir/hostpkg/lib/ucode/*.so"
bash "$SCRIPT_DIR/test-fw4-lock-preflight.sh" "$ASSEMBLED_ROOT/sbin/fw4"
"$SCRIPT_DIR/test-netifd-proto-busy.sh" --rootfs "$ASSEMBLED_ROOT"
if [ "$BOARD" = bpi-r4-pro ]; then
	"$SCRIPT_DIR/check-as21xxx-rootfs.sh" "$ASSEMBLED_ROOT"
fi
if [ "$BOARD" = bpi-r4-pro-4e ]; then
    sh "$SCRIPT_DIR/check-4e-rootfs.sh" "$ASSEMBLED_ROOT"
fi
if [ "$UI_MODE" != none ]; then
	bash "$SCRIPT_DIR/test-sqm-lifecycle-owner.sh" --rootfs "$ASSEMBLED_ROOT"
	"$SCRIPT_DIR/check-rootfs-integrity.sh" "$ASSEMBLED_ROOT"
	"$SCRIPT_DIR/check-factory-reset-rootfs.sh" "$ASSEMBLED_ROOT"
else
	# Without the UI package the full gate has no payload to check; what every
	# image needs still applies (the full gate runs this part itself).
	"$SCRIPT_DIR/check-rootfs-base.sh" "$ASSEMBLED_ROOT"
fi

# ── 4b. Seed factory u-boot env into the SD install image (A/B, bpi-r4) ──
# Generate a valid env image (mkenvimage) from the *patched* emmc defenv and
# drop it at 25M of the SD image — inside the emmc_install region (19-27M) — so
# it rides SD->NAND->eMMC and emmc_init (z04) writes it to the eMMC ubootenv.
# Keeps env valid+factory from provisioning (no runtime saveenv / bad-CRC
# window) and makes a re-flash always restore factory env.
if [ "$AB_ENABLED" = "yes" ] && [ "$PROVISION_SRC" = "sd" ]; then
    step "Seeding factory u-boot env into sdcard image..."
    MKENV=$(find "$WORK_DIR/build_dir" -type f -path "*${ENV_DEFCONFIG_TAG}*/tools/mkenvimage" 2>/dev/null | head -1)
    DEFENV=$(find "$WORK_DIR/build_dir" -type f -path "*${ENV_DEFCONFIG_TAG}*/defenvs/${ENV_DEFENV_NAME}" 2>/dev/null | head -1)
    # Anchor the profile against the "-sdcard.img.gz" suffix. A bare
    # *${PROFILE}* glob also matches sibling boards whose profile shares this
    # prefix (bananapi_bpi-r4 matches ...-r4-lite-... and ...-r4-pro-8x-...),
    # and `head -1` then takes the alphabetically first — i.e. ANOTHER board's
    # image. The env then lands in the wrong file while this board's installer
    # ships with an all-zero env region, and the build still prints success.
    SDGZ=$(ls "$WORK_DIR/bin/targets/${TARGET}/"*"${PROFILE}-sdcard.img.gz" 2>/dev/null | head -1)
    if [ -n "$MKENV" ] && [ -n "$DEFENV" ] && [ -n "$SDGZ" ]; then
        ENVBIN=$(mktemp)
        trap 'rm -f "$ENVBIN"' EXIT
        "$MKENV" -s "$ENV_SIZE" -r -o "$ENVBIN" "$DEFENV"
        # mkenvimage -s pads to exactly ENV_SIZE; a wrong size means a bad env
        # region (bad CRC at provision) — fail rather than ship it.
        envsz=$(stat -c%s "$ENVBIN" 2>/dev/null || echo 0)
        if [ "$envsz" -ne "$((ENV_SIZE))" ]; then
            echo -e "${R}✗ env image size $envsz != expected $((ENV_SIZE)); aborting.${N}"
            exit 1
        fi
        gunzip -kf "$SDGZ"
        SDIMG="${SDGZ%.gz}"
        dd if="$ENVBIN" of="$SDIMG" bs=1M seek="$ENV_SEED_OFFSET_MB" conv=notrunc status=none
        gzip -f "$SDIMG"
        # OpenWrt emitted metadata before the factory environment was written.
        python3 "$SCRIPT_DIR/lib/refresh-sd-image-metadata.py" "$SDGZ" "$PROFILE"
        # Name the image that was written: the previous message proved nothing
        # about WHICH file got the env, which is how a wrong-file seed stayed
        # invisible.
        ok "Factory env seeded into $(basename "$SDIMG") at ${ENV_SEED_OFFSET_MB}M ($(basename "$DEFENV"), $envsz bytes)"
    else
        # A/B board with no valid env seed => the image can't do A/B boot/rollback.
        # Fail the build instead of silently shipping a broken artifact.
        echo -e "${R}✗ env seed FAILED — mkenvimage=[$MKENV] defenv=[$DEFENV] sdcard=[$SDGZ]${N}"
        echo -e "${R}  A/B env would NOT be valid at provision; aborting build.${N}"
        exit 1
    fi
fi

# ── 4c. Assemble the bring-up / repair flash kit (NAND boards: archetype-2 no-SD,
#       archetype-3 NAND-only) ──
# Collects the UART/NAND artifacts + vendored mtk_uartboot + runbook into
# bin/targets/.../flashkit-<board>/ and a provenance-tracked tarball. These are
# formal recovery deliverables for the NAND provisioning archetypes.
if [ "$PROVISION_SRC" = "snand-factory" ] || [ "$PROVISION_SRC" = "factory.ubi" ]; then
    step "Assembling flash kit..."
    "$SCRIPT_DIR/make-flashkit.sh" --board "$BOARD"
fi

# ── 5. Output results ──
echo ""
ok "Build complete! (board=$BOARD)"
echo ""
echo "  Firmware location:"
ls -lh "$WORK_DIR/bin/targets/${TARGET}/"*${PROFILE}*sysupgrade* 2>/dev/null || true
ls -lh "$WORK_DIR/bin/targets/${TARGET}/"*${PROFILE}*sdcard* 2>/dev/null || true
echo ""
echo "  ImageBuilder (for quick packaging):"
ls -lh "$WORK_DIR/bin/targets/${TARGET}/"*imagebuilder* 2>/dev/null || true
echo ""
echo "  SDK (for building individual packages):"
ls -lh "$WORK_DIR/bin/targets/${TARGET}/"*sdk* 2>/dev/null || true
