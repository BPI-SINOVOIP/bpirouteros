#!/bin/bash
# test-build-gate.sh — verifies check-prepared.sh actually blocks a
# wrong-board build.
#
# The gate guards a release-level failure (firmware built for the wrong board
# while every step reports success), so it needs its own proof rather than
# "it looked right when I ran it once".
#
# Runs entirely on fake trees; touches neither openwrt/ nor any real build.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$(dirname "$SCRIPT_DIR")"
GATE="$SCRIPT_DIR/check-prepared.sh"
INPUT_ID="$SCRIPT_DIR/release-build-provenance.py"

G='\033[0;32m'
R='\033[0;31m'
N='\033[0m'

pass=0
fail=0

# run <name> <expected-exit> <board> <marker-contents|--no-marker> <device-symbol|--no-config>
run() {
    local name="$1" want="$2" board="$3" marker="$4" symbol="$5"
    local tree
    tree="$(mktemp -d)"
    trap 'rm -rf "$tree"' RETURN

    if [ "$marker" != "--no-marker" ]; then
        marker="${marker//@PREPARE_INPUT_SHA@/$PREPARE_INPUT_SHA}"
        echo "$marker" > "$tree/.bpirouter-prepared-board"
    fi
    if [ "$symbol" != "--no-config" ]; then
        printf '%s\n' "$symbol" > "$tree/.config"
    fi

    local out rc
    out="$(BPIR_WORK_DIR="$tree" BPIR_CONFIG_DIR="$BUILD_DIR/config" \
        "$GATE" "$board" 2>&1)"
    rc=$?

    if [ "$rc" = "$want" ]; then
        echo -e "${G}PASS${N} $name (exit $rc)"
        pass=$((pass + 1))
    else
        echo -e "${R}FAIL${N} $name — exit $rc, want $want"
        echo "$out" | sed 's/^/      /'
        fail=$((fail + 1))
    fi
}

echo "── check-prepared.sh ──"

PREPARE_INPUT_SHA=$("$INPUT_ID" prepare-input-id --build-dir "$BUILD_DIR" --board openwrt-one)

# 1. Marker names a different board. This is the exact state that produced a
#    silent wrong-board build: the tree was prepared for bpi-r4-lite and the
#    build asked for openwrt-one.
run "wrong board marker is rejected" 1 \
    openwrt-one $'board=bpi-r4-lite\nprepare_inputs_sha256=@PREPARE_INPUT_SHA@\nui_mode=none' "CONFIG_TARGET_mediatek_filogic_DEVICE_openwrt_one=y"

# 2. Marker is right but .config selects another device — a hand-edited or
#    half-written config the marker cannot see.
run "wrong device symbol is rejected" 1 \
    openwrt-one $'board=openwrt-one\nprepare_inputs_sha256=@PREPARE_INPUT_SHA@\nui_mode=none' "CONFIG_TARGET_mediatek_filogic_DEVICE_bananapi_bpi-r4-lite=y"

# 3. Both correct → build may proceed.
run "correct marker and symbol passes" 0 \
    openwrt-one $'board=openwrt-one\nprepare_inputs_sha256=@PREPARE_INPUT_SHA@\nui_mode=none' "CONFIG_TARGET_mediatek_filogic_DEVICE_openwrt_one=y"

run "prepare input drift is rejected" 1 \
    openwrt-one $'board=openwrt-one\nprepare_inputs_sha256=0000000000000000000000000000000000000000000000000000000000000000\nui_mode=none' "CONFIG_TARGET_mediatek_filogic_DEVICE_openwrt_one=y"

# Guards on the guard: an absent marker must not read as "fine". A tree
# prepared by the older script has no marker at all.
run "missing marker is rejected" 1 \
    openwrt-one --no-marker "CONFIG_TARGET_mediatek_filogic_DEVICE_openwrt_one=y"

run "missing .config is rejected" 1 \
    openwrt-one $'board=openwrt-one\nprepare_inputs_sha256=@PREPARE_INPUT_SHA@\nui_mode=none' --no-config

# Exercise content drift, not only a forged marker value. The fake build tree
# contains the same classes of inputs as prepare.sh consumes; editing one patch
# after stamping must make the gate reject the previously valid tree.
mutation_root=$(mktemp -d)
mutation_build="$mutation_root/build"
mutation_tree="$mutation_root/openwrt"
mkdir -p "$mutation_build/config" "$mutation_build/patches/common" "$mutation_tree"
printf '%s\n' 'CONFIG_PACKAGE_base-files=y' >"$mutation_build/config/common.config"
printf '%s\n' 'CONFIG_TARGET_mediatek_filogic_DEVICE_openwrt_one=y' >"$mutation_build/config/openwrt-one.config"
printf '%s\n' 'src-git base https://example.invalid/openwrt.git' >"$mutation_build/feeds.conf"
printf '%s\n' 'original patch bytes' >"$mutation_build/patches/common/test.patch"
printf '%s\n' 'CONFIG_TARGET_mediatek_filogic_DEVICE_openwrt_one=y' >"$mutation_tree/.config"
mutation_sha=$("$INPUT_ID" prepare-input-id --build-dir "$mutation_build" --board openwrt-one)
printf 'board=openwrt-one\nprepare_inputs_sha256=%s\nui_mode=none\n' "$mutation_sha" \
    >"$mutation_tree/.bpirouter-prepared-board"
if BPIR_BUILD_DIR="$mutation_build" BPIR_WORK_DIR="$mutation_tree" \
    "$GATE" openwrt-one --quiet >/dev/null 2>&1; then
    printf '%s\n' 'changed patch bytes' >"$mutation_build/patches/common/test.patch"
    if BPIR_BUILD_DIR="$mutation_build" BPIR_WORK_DIR="$mutation_tree" \
        "$GATE" openwrt-one --quiet >/dev/null 2>&1; then
        echo -e "${R}FAIL${N} changed patch bytes passed the prepared-input gate"
        fail=$((fail + 1))
    else
        echo -e "${G}PASS${N} changed patch bytes invalidate the prepared tree"
        pass=$((pass + 1))
    fi
else
    echo -e "${R}FAIL${N} preparation-input fixture was not initially valid"
    fail=$((fail + 1))
fi
rm -rf "$mutation_root"

echo ""
if [ "$fail" -gt 0 ]; then
    echo -e "${R}$fail failed${N}, $pass passed"
    exit 1
fi
echo -e "${G}all $pass passed${N}"
