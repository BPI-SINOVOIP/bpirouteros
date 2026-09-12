#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/kernel-patch-routing.sh"

REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
R4_PRO_KERNEL_DIR="$REPO_ROOT/patches/bpi-r4-pro/kernel"

require_indexed=false
case "${1:-}" in
    "") ;;
    --require-indexed) require_indexed=true ;;
    *)
        echo "usage: $0 [--require-indexed]" >&2
        exit 2
        ;;
esac

# Keep the vendored migration complete in the filesystem used by a build. The
# optional --require-indexed pre-commit mode additionally proves that the same
# migration plus combo-LAN runtime files are in Git's index instead of merely
# surviving as local untracked files.
# The two series counts are part of the pinned OpenWrt 25.12.5 / 93cf01b0 import
# documented by MXL862XX-UPSTREAM.md.
shopt -s nullglob
backport_patches=("$R4_PRO_KERNEL_DIR"/930-*.patch)
pending_patches=("$R4_PRO_KERNEL_DIR"/931-*.patch)
[ "${#backport_patches[@]}" -eq 22 ] || {
    echo "FAIL: R4-Pro MxL backport inventory has ${#backport_patches[@]} patches, expected 22" >&2
    exit 1
}
[ "${#pending_patches[@]}" -eq 19 ] || {
    echo "FAIL: R4-Pro MxL pending inventory has ${#pending_patches[@]} patches, expected 19" >&2
    exit 1
}
[ -f "$REPO_ROOT/patches/bpi-r4-pro/MXL862XX-UPSTREAM.md" ] || {
    echo "FAIL: R4-Pro MxL source/provenance document is missing" >&2
    exit 1
}
[ ! -e "$R4_PRO_KERNEL_DIR/994-mxl862xx-dsa-driver.patch" ] || {
    echo "FAIL: retired vendor MxL driver patch 994 is still present" >&2
    exit 1
}
[ ! -e "$R4_PRO_KERNEL_DIR/995-net-dsa-mxl862xx-core.patch" ] || {
    echo "FAIL: retired vendor MxL core patch 995 is still present" >&2
    exit 1
}

if $require_indexed; then
    required_files=(
        config/bpi-r4-pro.config
        patches/bpi-r4-pro/MXL862XX-UPSTREAM.md
        patches/bpi-r4-pro/base-files/463-filogic-package-mxl862xx-module.patch
        patches/bpi-r4-pro/base-files/467-filogic-network-r4-pro-8x.patch
        patches/bpi-r4-pro/base-files/469-filogic-as21xxx-fw-reprobe.patch
        patches/bpi-r4-pro/kernel/996-bpi-r4-pro-8x-mxl862xx-switch.patch
        patches/bpi-r4-pro/kernel/997a-bpi-r4-pro-8x-10g-lan.patch
        patches/bpi-r4-pro/kernel/999-bpi-r4-pro-8x-disable-unrouted-ports.patch
        patches/bpi-r4-pro/uboot/z13-bpirouter-wan-phy-reset.patch
        scripts/boards.sh
        scripts/build-full.sh
        scripts/check-as21xxx-rootfs.sh
        scripts/lib/kernel-patch-routing.sh
        scripts/test-as21xxx-reprobe.sh
        scripts/test-kernel-patch-routing.sh
        scripts/test-release-build-provenance.sh
    )
    for patch in "${backport_patches[@]}" "${pending_patches[@]}"; do
        required_files+=("${patch#"$REPO_ROOT"/}")
    done

    for path in "${required_files[@]}"; do
        git -C "$REPO_ROOT" ls-files --error-unmatch -- "$path" >/dev/null 2>&1 || {
            echo "FAIL: required R4-Pro MxL migration file is not in the Git index: $path" >&2
            exit 1
        }
    done
    for retired in \
        patches/bpi-r4-pro/base-files/463-filogic-config-enable-mxl862xx.patch \
        patches/bpi-r4-pro/base-files/464-filogic-config-as21xxx-builtin.patch \
        patches/bpi-r4-pro/kernel/994-mxl862xx-dsa-driver.patch \
        patches/bpi-r4-pro/kernel/995-net-dsa-mxl862xx-core.patch
    do
        if git -C "$REPO_ROOT" ls-files --error-unmatch -- "$retired" >/dev/null 2>&1; then
            echo "FAIL: retired vendor MxL patch remains in the Git index: $retired" >&2
            exit 1
        fi
    done
    git -C "$REPO_ROOT" diff --quiet -- \
        "${required_files[@]}" \
        patches/bpi-r4-pro/kernel/994-mxl862xx-dsa-driver.patch \
        patches/bpi-r4-pro/kernel/995-net-dsa-mxl862xx-core.patch || {
        echo "FAIL: staged R4-Pro MxL migration differs from the working tree" >&2
        exit 1
    }
fi

board_kernel_dir="/fixture/patches/bpi-r4-pro/kernel"
common_kernel_dir="/fixture/patches/common/kernel"

assert_route() {
    local expected="$1"
    local source_dir="$2"
    local basename="$3"
    local got

    got="$(bpir_kernel_patch_route "$source_dir" "$board_kernel_dir" "$basename")"
    [ "$got" = "$expected" ] || {
        echo "FAIL: $basename routed to '$got', expected '$expected'" >&2
        exit 1
    }
}

assert_route backport "$board_kernel_dir" 930-upstream.patch
assert_route pending "$board_kernel_dir" 931-upstream.patch
assert_route target "$board_kernel_dir" 996-board-dts.patch
assert_route target "$common_kernel_dir" 010-common-fix.patch

if bpir_kernel_patch_route "$common_kernel_dir" "$board_kernel_dir" 930-misplaced.patch >/dev/null; then
    echo "FAIL: a generic 930 patch outside the board stack was accepted" >&2
    exit 1
fi
if bpir_kernel_patch_route "$common_kernel_dir" "$board_kernel_dir" 931-misplaced.patch >/dev/null; then
    echo "FAIL: a generic 931 patch outside the board stack was accepted" >&2
    exit 1
fi

if $require_indexed; then
    echo "PASS: kernel patch routing is layer-aware, complete, indexed and fail-closed"
else
    echo "PASS: kernel patch routing is layer-aware, complete and fail-closed"
fi
