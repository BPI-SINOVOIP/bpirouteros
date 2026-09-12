#!/bin/bash
# Keep the formal image package set aligned with the implemented cellular
# protocols. The backend supports QMI and NCM; MBIM must not arrive through a
# future dependency or a per-board override without an implementation change.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
BUILD_DIR=${BPIR_BUILD_DIR:-$(dirname "$SCRIPT_DIR")}
COMMON=$BUILD_DIR/config/common.config
BOARDS="bpi-r3-mini bpi-r3 bpi-r4-lite bpi-r4-pro bpi-r4 openwrt-one"

fail() { echo "FAIL: $*" >&2; exit 1; }
[ -f "$COMMON" ] || fail "missing common config: $COMMON"

for package in umbim kmod-usb-net-cdc-mbim; do
	grep -Fxq "# CONFIG_PACKAGE_$package is not set" "$COMMON" \
		|| fail "common.config does not explicitly remove unsupported $package"
	grep -Fxq "CONFIG_PACKAGE_$package=y" "$COMMON" \
		&& fail "common.config also enables unsupported $package"
done
for package in kmod-usb-net-cdc-ncm kmod-usb-net-cdc-ether kmod-usb-net-rndis; do
	grep -Fxq "CONFIG_PACKAGE_$package=y" "$COMMON" \
		|| fail "common.config does not explicitly retain $package"
done

for board in $BOARDS; do
	config=$BUILD_DIR/config/$board.config
	[ -f "$config" ] || fail "missing board config: $config"
	grep -Eq '^CONFIG_PACKAGE_(umbim|kmod-usb-net-cdc-mbim)=y$' "$config" \
		&& fail "$board re-enables an unsupported MBIM package"
done

# Exercise the same mapping used by build-image.sh. A Kconfig negative must
# become an ImageBuilder removal token, not merely disappear from the list.
packages=$(sed -nE 's/^CONFIG_PACKAGE_(.*)=y$/\1/p; s/^# CONFIG_PACKAGE_(.*) is not set$/-\1/p' "$COMMON" | LC_ALL=C sort -u)
for token in -umbim -kmod-usb-net-cdc-mbim; do
	printf '%s\n' "$packages" | grep -Fxq -- "$token" \
		|| fail "ImageBuilder mapping omitted removal token $token"
done

echo "PASS: six-board package configs retain QMI/NCM support and explicitly remove MBIM"
