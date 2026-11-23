#!/bin/bash
# Single source of truth for bootstrapping the OpenWrt source checkout.

BPIR_OPENWRT_GIT_REF="v25.12.6"
BPIR_OPENWRT_GIT_COMMIT="64900e756efa667774214f9c6b17c113222e01f7"
BPIR_OPENWRT_DEFAULT_CLONE_URL="https://github.com/openwrt/openwrt.git"

# Git searches parent directories for .git. `--is-inside-work-tree` alone would
# therefore accept an ordinary build/openwrt directory as the surrounding
# bpirouter-build checkout. A top-level check alone would still accept a symlink
# or BPIR_WORK_DIR that points directly at another project repository. Require a
# real checkout root whose HEAD carries OpenWrt's invariant source skeleton;
# normal clones and `git worktree add` checkouts both satisfy this contract.
bpir_is_exact_openwrt_worktree() {
    local work_dir="$1"
    local expected top required
    [ -d "$work_dir" ] && [ ! -L "$work_dir" ] || return 1
    expected=$(readlink -f -- "$work_dir") || return 1
    top=$(git -C "$work_dir" rev-parse --show-toplevel 2>/dev/null) || return 1
    top=$(readlink -f -- "$top") || return 1
    [ "$top" = "$expected" ] \
        && [ "$(git -C "$work_dir" rev-parse --is-inside-work-tree 2>/dev/null)" = true ] \
        || return 1
    for required in include/toplevel.mk scripts/feeds target/linux/Makefile; do
        git -C "$work_dir" cat-file -e "HEAD:$required" 2>/dev/null || return 1
    done
}

bpir_clone_openwrt() {
    local destination="$1"
    local clone_url="${BPIR_OPENWRT_CLONE_URL:-$BPIR_OPENWRT_DEFAULT_CLONE_URL}"
    git clone --branch "$BPIR_OPENWRT_GIT_REF" --depth 1 \
        "$clone_url" "$destination" || return 1
    [ "$(git -C "$destination" rev-parse --verify 'HEAD^{commit}' 2>/dev/null)" = \
        "$BPIR_OPENWRT_GIT_COMMIT" ] || {
        echo "OpenWrt $BPIR_OPENWRT_GIT_REF did not resolve to pinned commit $BPIR_OPENWRT_GIT_COMMIT" >&2
        return 1
    }
}

# Reset only the source paths populated by BpiRouter prepare. Build products,
# downloads, staging_dir and .config remain available for incremental builds.
bpir_reset_openwrt_source() {
    local work_dir="$1"
    git -C "$work_dir" reset --hard HEAD >/dev/null || return 1
    git -C "$work_dir" clean -fd -- \
        target/linux/generic/backport-6.12 \
        target/linux/generic/pending-6.12 \
        target/linux/mediatek/patches-6.12 \
        target/linux/mediatek/filogic/base-files/etc/init.d/bpirouter-as21xxx-fw \
        target/linux/mediatek/filogic/base-files/etc/uci-defaults/99-bpirouter-as21xxx-fw \
        target/linux/mediatek/filogic/base-files/etc/uci-defaults/99-bpirouter-combo-led-activity \
        target/linux/mediatek/filogic/base-files/lib/functions/bpirouter-combo-leds.sh \
        package/boot/uboot-mediatek/patches \
        package/boot/arm-trusted-firmware-mediatek/patches \
        package/network/config/netifd/patches/900-bpirouter-refresh-dynamic-ip6assign.patch \
        package/network/config/netifd/patches/901-bpirouter-proto-busy.patch \
        package/network/config/netifd/patches/902-bpirouter-protocol-script-lifetime.patch \
        package/network/config/netifd/patches/903-bpirouter-host-route-lifetime.patch \
        package/network/config/netifd/patches/904-bpirouter-pppoe-parent-mtu.patch \
        package/network/config/firewall4/patches/910-bpirouter-s2s-lock-boundary.patch \
        package/network/utils/uqmi/patches/100-fix-ctl-data-format-request.patch \
        >/dev/null 2>&1 || return 1
}
