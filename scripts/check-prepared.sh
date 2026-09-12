#!/bin/bash
# check-prepared.sh — Fail fast unless the OpenWrt tree is prepared for the
# board about to be built.
#
# Why this exists. build-full.sh used to treat "the openwrt/ directory exists"
# as "this board is ready", so running it with --board X against a tree last
# prepared for board Y silently rebuilt Y: it printed "Board: X", ran a full
# `make world`, exited 0, and then assembled an X flashkit out of whatever stale
# X artifacts happened to be lying in bin/. A wrong-board firmware that reports
# success is a release-gate defect, so the check is fail-fast and never
# auto-repairs — repairing would hide the same mistake behind a long rebuild.
#
# Two independent conditions, because either alone can pass on a broken tree:
#
#   1. The prepare marker names this board. prepare.sh does more than write a
#      .config: it resets the tracked source and injects BOARD-LEVEL kernel /
#      u-boot / base-files patches. A tree can therefore hold the right .config
#      and the previous board's patches.
#   2. The .config carries this board's device symbol. Catches a tree whose
#      marker is stale relative to a hand-edited or half-written config.
#   3. The board/common patches and configs still match the bytes prepare.sh
#      materialised. Source tests alone otherwise validate newer files while
#      make compiles the older prepared tree.
#
# Usage: check-prepared.sh <board> [--quiet]
# Env:   BPIR_WORK_DIR   override the OpenWrt tree (tests)
#        BPIR_CONFIG_DIR override the board config dir (tests)
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$(dirname "$SCRIPT_DIR")"
[ -n "${BPIR_BUILD_DIR:-}" ] && BUILD_DIR="$BPIR_BUILD_DIR"
WORK_DIR="${BPIR_WORK_DIR:-$BUILD_DIR/openwrt}"
CONFIG_DIR="${BPIR_CONFIG_DIR:-$BUILD_DIR/config}"
MARKER_NAME=".bpirouter-prepared-board"

R='\033[0;31m'
G='\033[0;32m'
N='\033[0m'

BOARD="$1"
QUIET=""
[ "$2" = "--quiet" ] && QUIET=1

[ -n "$BOARD" ] && { [ "${BOARD#-}" = "$BOARD" ]; } || {
    echo -e "${R}✗ usage: check-prepared.sh <board> [--quiet]${N}" >&2
    exit 2
}

die() {
    echo -e "${R}✗ $1${N}" >&2
    echo "" >&2
    echo "  The tree is NOT proven current for '$BOARD'. Building now could" >&2
    echo "  consume another board's state or stale patch/config inputs." >&2
    echo "" >&2
    echo "  Fix:  ./scripts/prepare.sh --board $BOARD" >&2
    exit 1
}

MARKER="$WORK_DIR/$MARKER_NAME"
[ -d "$WORK_DIR" ] || die "OpenWrt tree not found at $WORK_DIR"
[ -f "$MARKER" ] || die "no prepare marker ($MARKER_NAME) — the tree was never prepared, or was prepared by an older script"

# The marker is key=value now. An older single-line marker is rejected rather
# than accepted for its board alone: it carries no UI mode, so a tree stamped by
# the previous script cannot be shown to match what a build is about to do.
mval() { sed -n "s/^$1=//p" "$MARKER" | head -1; }
PREPARED="$(mval board)"
[ -n "$PREPARED" ] || die "marker has no board= line — prepared by an older script; re-run prepare.sh"
[ "$PREPARED" = "$BOARD" ] || die "tree is prepared for '$PREPARED', not '$BOARD'"

PREPARE_INPUT_SHA="$(mval prepare_inputs_sha256)"
[[ "$PREPARE_INPUT_SHA" =~ ^[0-9a-f]{64}$ ]] \
    || die "marker has no valid prepare_inputs_sha256 — re-run prepare.sh"
if ! CURRENT_PREPARE_INPUT_SHA=$("$SCRIPT_DIR/release-build-provenance.py" prepare-input-id \
    --build-dir "$BUILD_DIR" --board "$BOARD"); then
    die "cannot fingerprint the current prepare inputs"
fi
[ "$CURRENT_PREPARE_INPUT_SHA" = "$PREPARE_INPUT_SHA" ] \
    || die "patch/config inputs changed after prepare — re-run prepare.sh"

UI_MODE="$(mval ui_mode)"
case "$UI_MODE" in
    source|artifact|none) ;;
    *) die "marker has no usable ui_mode (got '${UI_MODE:-empty}') — re-run prepare.sh with one of --ui-source / --ui-artifact / --without-proprietary-ui" ;;
esac

# The mode has to agree with what the tree will actually build. Every board
# config selects the UI, so a tree prepared as `none` whose .config still
# selects it would build one anyway -- and the only symptom is an image that
# was supposed to be UI-less and is not.
UI_SELECTED=no
grep -qx 'CONFIG_PACKAGE_bpirouter-ui=y' "$WORK_DIR/.config" 2>/dev/null && UI_SELECTED=yes
if [ "$UI_MODE" = none ] && [ "$UI_SELECTED" = yes ]; then
    die "marker says ui_mode=none but .config still selects bpirouter-ui"
fi
if [ "$UI_MODE" != none ] && [ "$UI_SELECTED" = no ]; then
    die "marker says ui_mode=$UI_MODE but .config does not select bpirouter-ui"
fi

# The expected device symbol comes from the board's own config file, so adding
# a board needs no edit here.
BOARD_CONFIG="$CONFIG_DIR/$BOARD.config"
[ -f "$BOARD_CONFIG" ] || die "no board config at $BOARD_CONFIG"

WANT_SYMBOL="$(grep -oE '^CONFIG_TARGET_[A-Za-z0-9_]+_DEVICE_[A-Za-z0-9_-]+=y' "$BOARD_CONFIG" | head -1 || true)"
[ -n "$WANT_SYMBOL" ] || die "no CONFIG_TARGET_*_DEVICE_*=y line in $BOARD_CONFIG"

[ -f "$WORK_DIR/.config" ] || die "no .config in $WORK_DIR"
if ! grep -qxF "$WANT_SYMBOL" "$WORK_DIR/.config"; then
    ACTUAL="$(grep -oE '^CONFIG_TARGET_[A-Za-z0-9_]+_DEVICE_[A-Za-z0-9_-]+=y' "$WORK_DIR/.config" | head -1 || echo '(none)')"
    die ".config selects $ACTUAL, expected $WANT_SYMBOL"
fi

[ -n "$QUIET" ] || echo -e "${G}✓ tree prepared for $BOARD, ui=$UI_MODE ($WANT_SYMBOL)${N}"
