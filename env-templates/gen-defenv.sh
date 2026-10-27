#!/bin/bash
# Copyright (C) 2026 Ning <mimallaus@gmail.com>
# gen-defenv.sh — generate u-boot defenv replacement patches from board-agnostic
# templates (media/*.env.in) + per-board params (boards/<board>.params).
#
# Source of truth = the templates. Output = patches/<board>/uboot/
# z06-bpirouter-defenv-<medium>.patch, each replacing the OpenWrt-pristine defenv
# (added by uboot-mediatek's 450-add-bpi-r4.patch, vendored in pristine/) with the
# A/B-enabled env. Build flow is UNCHANGED: prepare.sh copies these committed
# patches and OpenWrt applies them after 450 (numeric patches sort before z*).
#
# Workflow: edit a template -> run this -> commit the regenerated z06 patches.
#
# Usage:
#   ./gen-defenv.sh --board bpi-r4            # (re)write committed defenv patches
#   ./gen-defenv.sh --board bpi-r4 --verify   # render only; assert no stray placeholder
set -eo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$(dirname "$SCRIPT_DIR")"

BOARD=bpi-r4; VERIFY=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --board) BOARD="$2"; shift 2 ;;
        --board=*) BOARD="${1#*=}"; shift ;;
        --verify) VERIFY=1; shift ;;
        *) echo "unknown arg: $1"; exit 1 ;;
    esac
done

PARAMS="$SCRIPT_DIR/boards/$BOARD.params"
[ -f "$PARAMS" ] || { echo "no params file: $PARAMS"; exit 1; }
# shellcheck disable=SC1090
source "$PARAMS"
# Per-SoC constants (LOADADDR/BOOTARGS_BASE/NAND geom) live in soc/<SOC_ENV>.params,
# sourced after the board file sets SOC_ENV.
[ -n "$SOC_ENV" ] && { SOCP="$SCRIPT_DIR/soc/$SOC_ENV.params"
    [ -f "$SOCP" ] || { echo "no soc params: $SOCP"; exit 1; }
    source "$SOCP"; }
OUT="$BUILD_DIR/patches/$BOARD/uboot"

# PROV_DONE: provisioning success/fail tail appended after the write chain.
# Default = the original "light pwr+rec on success" tail (keeps non-LED
# boards byte-identical). r4-pro overrides it to turn LEDs off on success
# and show err on failure.
[ -n "${PROV_DONE+x}" ] || PROV_DONE=' && led $bootled_pwr on && led $bootled_rec on'
[ -n "${GR_EN8811H+x}" ] || GR_EN8811H=true
[ -n "${EMMC_WRITE_EN8811H_FW+x}" ] || EMMC_WRITE_EN8811H_FW=true
# Optional board-owned boot preparation. Empty defaults keep
# every existing board's rendered environment byte-identical.
BOOTM_PREPARE=${BOOTM_PREPARE:-}
EXTRA_ENV=${EXTRA_ENV:-}

# esc <val> -> escape sed-replacement specials (\\ & and the | delimiter). Values may
# contain `&&` (mtd write) and `$loadaddr` (kept literal); only \\ & | are special.
esc() { printf '%s' "$1" | sed -e 's/[\\&|]/\\&/g'; }

# render_base <medium> -> stdout with placeholders substituted, preserving each
# template's existing final-newline convention.
render_base() {
    sed -e "s|@DTBBASE@|$(esc "$DTBBASE")|g" \
        -e "s|@IMGPREFIX@|$(esc "$IMGPREFIX")|g" \
        -e "s|@BOOTLED_PWR@|$(esc "$BOOTLED_PWR")|g" \
        -e "s|@BOOTLED_REC@|$(esc "$BOOTLED_REC")|g" \
        -e "s|@BOOTCONF_EXTRA@|$(esc "$BOOTCONF_EXTRA")|g" \
        -e "s|@LOADADDR@|$(esc "$LOADADDR")|g" \
        -e "s|@BOOTARGS_BASE@|$(esc "$BOOTARGS_BASE")|g" \
        -e "s|@UBOOTENV_VOL@|$(esc "$UBOOTENV_VOL")|g" \
        -e "s|@OVERLAY_SIZE@|$(esc "$OVERLAY_SIZE")|g" \
        -e "s|@SNAND_WRITE_BL2@|$(esc "$SNAND_WRITE_BL2")|g" \
        -e "s|@LED_WRITING@|$(esc "$LED_WRITING")|g" \
        -e "s|@PROV_DONE@|$(esc "$PROV_DONE")|g" \
		-e "s|@GR_EN8811H@|$(esc "$GR_EN8811H")|g" \
		-e "s|@EMMC_WRITE_EN8811H_FW@|$(esc "$EMMC_WRITE_EN8811H_FW")|g" \
        -e "s|@LED_FAULT@|$(esc "$LED_FAULT")|g" \
        -e "s|@RESET_FACTORY_SNAND@|$(esc "$RESET_FACTORY_SNAND")|g" \
        -e "s|@BOOTM_PREPARE@|$(esc "$BOOTM_PREPARE")|g" \
        "$SCRIPT_DIR/media/$1.env.in"
}

render() {
    if [ -z "$EXTRA_ENV" ]; then
        render_base "$1"
    else
        # Templates differ in their final newline; append exactly one separator.
        local base
        base=$(render_base "$1")
        printf '%s\n%s' "$base" "$EXTRA_ENV"
    fi
}

for m in $MEDIA; do
    # DEFENV_SEP: board/medium separator in the defenv filename. Defaults to '_'
    # (bananapi_bpi-r4_emmc_env); openwrt-one's defenv is openwrt-one-spi-nand_env
    # (hyphen), so its params set DEFENV_SEP='-'. Backward-compatible: unset => '_'.
    name="${DEFENV_BASE}${DEFENV_SEP:-_}${m}_env"
    gen="$(mktemp)"
    render "$m" > "$gen"
    if grep -qE '@[A-Z_]+@' "$gen"; then
        echo "FAIL [$m]: unsubstituted placeholder(s): $(grep -oE '@[A-Z_]+@' "$gen" | sort -u | tr '\n' ' ')"; rm -f "$gen"; exit 1
    fi
    if [ "$VERIFY" = 1 ]; then
        echo "rendered $name: $(wc -l < "$gen") lines (+ no trailing newline)"
    else
        patch="$OUT/z06-bpirouter-defenv-$m.patch"
        { echo "--- a/defenvs/$name"
          echo "+++ b/defenvs/$name"
          diff -u "$SCRIPT_DIR/pristine/$name" "$gen" | tail -n +3 || true
        } > "$patch"
        echo "wrote $patch"
    fi
    rm -f "$gen"
done
