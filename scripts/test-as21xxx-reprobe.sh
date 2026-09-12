#!/bin/sh
# Source-side gate for the R4-Pro AS21xxx/MxL boot ordering.
#
# It proves what the checkout says: that 469 and 463 apply, that the board
# config selects both modules, and that the two call sites which execute the
# behavioral gate are still wired. It then materialises the 469 payload as a
# rootfs and hands it to check-as21xxx-rootfs.sh, so the same scenarios that
# judge a shipped image also judge the patch before anything is built.
#
# The behavioral judgement deliberately lives in check-as21xxx-rootfs.sh alone:
# that file is release-gate code, frozen and hashed with the manifest gate, and
# must not depend on a sibling script that the frozen snapshot does not carry.
set -eu

BUILD_DIR=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
PATCH="$BUILD_DIR/patches/bpi-r4-pro/base-files/469-filogic-as21xxx-fw-reprobe.patch"
MODULE_PATCH="$BUILD_DIR/patches/bpi-r4-pro/base-files/463-filogic-package-mxl862xx-module.patch"
BOARD_CONFIG="$BUILD_DIR/config/bpi-r4-pro.config"
ROOTFS_GATE="$BUILD_DIR/scripts/check-as21xxx-rootfs.sh"
FULL_BUILD="$BUILD_DIR/scripts/build-full.sh"
IMAGE_POLICY="$BUILD_DIR/scripts/check-firmware-policy.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

fail() {
	echo "FAIL: $*" >&2
	exit 1
}

TREE="$TMP/tree"
mkdir -p "$TREE"
(cd "$TREE" && git apply "$PATCH") || fail "469 does not apply to an empty base-files payload"
PAYLOAD="$TREE/target/linux/mediatek/filogic/base-files"
[ -f "$PAYLOAD/etc/init.d/bpirouter-as21xxx-fw" ] \
	|| fail "469 did not create the AS21xxx service"
[ -f "$PAYLOAD/etc/uci-defaults/99-bpirouter-as21xxx-fw" ] \
	|| fail "469 did not create the first-boot launcher"

MODULE_TREE="$TMP/module-tree"
mkdir -p "$MODULE_TREE/package/kernel/linux/modules"
# Test the source patch against the pinned pristine OpenWrt baseline rather than
# the working checkout, which prepare.sh has already patched.
git -C "$BUILD_DIR/openwrt" show \
	HEAD:package/kernel/linux/modules/netdevices.mk \
	> "$MODULE_TREE/package/kernel/linux/modules/netdevices.mk" \
	|| fail "cannot read the pristine OpenWrt netdevices.mk"
(cd "$MODULE_TREE" && git apply "$MODULE_PATCH") \
	|| fail "deferred MxL module package patch does not apply"
MODULE_MK="$MODULE_TREE/package/kernel/linux/modules/netdevices.mk"
grep -Fq 'define KernelPackage/dsa-mxl862xx' "$MODULE_MK" \
	|| fail "MxL switch module package is missing"
grep -Fq '$(LINUX_DIR)/drivers/net/dsa/mxl862xx/mxl862xx_dsa.ko' "$MODULE_MK" \
	|| fail "MxL driver module is not packaged"
if sed -n '/define KernelPackage\/dsa-mxl862xx$/,/^endef$/p' "$MODULE_MK" | grep -q 'AUTOLOAD'; then
	fail "MxL switch package must not autoload before PHY preparation"
fi
grep -Fxq 'CONFIG_PACKAGE_kmod-phy-aeonsemi-as21xxx=y' "$BOARD_CONFIG" \
	|| fail "R4-Pro does not select the AS21xxx PHY module"
grep -Fxq 'CONFIG_PACKAGE_kmod-dsa-mxl862xx=y' "$BOARD_CONFIG" \
	|| fail "R4-Pro does not select the deferred MxL switch module"
grep -Fq 'check-as21xxx-rootfs.sh' "$FULL_BUILD" \
	|| fail "ordinary full builds do not execute the assembled-rootfs MxL policy"
grep -Fq 'check-as21xxx-rootfs.sh' "$IMAGE_POLICY" \
	|| fail "firmware manifest policy does not execute the behavioral MxL gate"
[ -x "$ROOTFS_GATE" ] || fail "assembled-rootfs MxL policy is missing or not executable"

# Shape the payload like a rootfs and run the one behavioral gate on it. The
# module files are placeholders: whether the image really carries them is an
# image property, proven by the same gate at the two call sites checked above,
# and their packaging is proven by the 463/config assertions here.
ROOT="$TMP/root"
mkdir -p "$ROOT/etc" "$ROOT/lib/modules/source-payload" "$ROOT/etc/modules.d"
cp -a "$PAYLOAD/etc/init.d" "$PAYLOAD/etc/uci-defaults" "$ROOT/etc/"
for module in as21xxx mxl862xx_dsa tag_mxl862xx tag_mxl862xx_8021q; do
	: > "$ROOT/lib/modules/source-payload/$module.ko"
done
printf 'as21xxx\n' > "$ROOT/etc/modules.d/18-phy-aeonsemi-as21xxx"
"$ROOTFS_GATE" "$ROOT" >/dev/null \
	|| fail "the 469 payload fails the behavioral AS21xxx/MxL rootfs gate"

echo "PASS: AS21xxx is prepared before one non-destructive MxL probe"
