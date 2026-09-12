#!/bin/bash
# check-artifacts.sh — refuse to assemble a release image around stale
# bpirouter-ui or bpirouter-base packages.
#
# Usage: check-artifacts.sh <arch>        e.g. aarch64_cortex-a53
#
# Only build-image.sh --release needs this. The other two paths are coupled to
# the source by construction and must NOT call it:
#   build-full.sh        runs bpirouter-ui/deploy/build.sh, then `make`.
#   build-image.sh quick compiles to /tmp and injects it with FILES=.
# Release mode is the exception: it resolves bpirouter-ui from the .apk
# repository that a PREVIOUS build-full.sh produced. It compiles the Go binary
# and the frontend on the way past and then never uses them, so the operator
# watches a build scroll by and reasonably concludes the image contains it.
# What actually ships is whatever vintage each .apk happens to be.  The base
# package owns early rootfs contracts such as QMF-15/QMF-16, so it has the same gate.
#
# Same contract as check-prepared.sh: report and stop, never repair. Rebuilding
# the artifacts here would not help anyway -- only build-full.sh regenerates the
# .apk that release mode packs, which is what the error says to run.
set -eo pipefail

# Takes no arch argument any more. It used to be handed the board's CPU
# subtype, which is not the package architecture: filogic builds a53 packages
# for every board in the subtarget, so the a73 boards' lookup could never match
# and this gate would have blocked their release builds outright.
source "$(cd "$(dirname "$0")" && pwd)/boards.sh"
ARCH=$(pkg_arch)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$(dirname "$SCRIPT_DIR")"
WORK_DIR="$BUILD_DIR/openwrt"
UI_DIR="${BPIR_UI_DIR:-$(dirname "$BUILD_DIR")/bpirouter-ui}"

R='\033[0;31m'; G='\033[0;32m'; N='\033[0m'
die() { echo -e "${R}✗ artifacts: $1${N}" >&2; [ -n "$2" ] && echo -e "  $2" >&2; exit 1; }

# Freshness must be checked against the feed OpenWrt actually consumed.  A
# release coordinator may run these scripts from a clean checkout while its
# openwrt/ path points at a shared work tree.  In that layout the sibling
# bpirouter-feeds checkout and openwrt/feeds/bpirouter can have identical git
# content but different checkout mtimes.  Comparing the sibling made an unused
# clone look newer than a correctly built package and blocked the release.
#
# The installed feed symlink is the build system's authority after prepare; it
# also handles published-tree layouts without guessing where the feed lives.
INSTALLED_FEED="$WORK_DIR/feeds/bpirouter"
FEED_ROOT=$(readlink -f "$INSTALLED_FEED" 2>/dev/null || true)
[ -n "$FEED_ROOT" ] && [ -d "$FEED_ROOT" ] || die \
    "cannot resolve the bpirouter feed installed at $INSTALLED_FEED" \
    "Run prepare.sh before checking package freshness."

APK=$(ls -t "$WORK_DIR/bin/packages/$ARCH/bpirouter/bpirouter-ui-"*.apk 2>/dev/null | head -1 || true)
[ -n "$APK" ] || die "no bpirouter-ui package for $ARCH" \
    "Run: $SCRIPT_DIR/build-full.sh --board <board>"

[ -d "$UI_DIR" ] || die "cannot reach the source tree at $UI_DIR" \
    "The gate compares the package against the source it should contain.
  Set BPIR_UI_DIR if bpirouter-ui is not a sibling of $(basename "$BUILD_DIR")."

BASE_APK=$(ls -t "$WORK_DIR/bin/packages/$ARCH/bpirouter/bpirouter-base-"*.apk 2>/dev/null | head -1 || true)
[ -n "$BASE_APK" ] || die "no bpirouter-base package for $ARCH" \
    "Run: $SCRIPT_DIR/build-full.sh --board <board>"
BASE_SRC="$FEED_ROOT/net/bpirouter-base"
[ -d "$BASE_SRC" ] || die "cannot reach bpirouter-base source at $BASE_SRC" \
    "The installed bpirouter feed has no bpirouter-base package source."

# mtime rather than content hashing on purpose: the question here is ordering
# ("was the package built after this change?"), which a hash cannot answer --
# two different hashes say nothing about which came first. Content hashing stays
# in artifact-hash.sh, where it answers a different question.
#
# `find -newer` rather than comparing stat output: stat -c %Y truncates to whole
# seconds, so a source file edited in the same second as the package compared
# equal and passed. -newer uses the full timestamp the filesystem stores.
SRC_DIRS=("$UI_DIR/backend" "$UI_DIR/frontend/src" "$UI_DIR/deploy")
UI_ACCEPTANCE_FILES=(
    "$UI_DIR/scripts/seg-acceptance.sh"
    "$UI_DIR/scripts/tel-acceptance.sh"
    "$UI_DIR/scripts/cell-acceptance.sh"
    "$UI_DIR/scripts/qos-acceptance.sh"
    "$UI_DIR/scripts/lib/acceptance-common.sh"
)
UI_PACKAGE_MAKEFILE="$FEED_ROOT/net/bpirouter-ui/Makefile"
for d in "${SRC_DIRS[@]}"; do
    [ -d "$d" ] || die "missing source directory: $d" \
        "Expected backend/, frontend/src/ and deploy/ under $UI_DIR."
done
for file in "${UI_ACCEPTANCE_FILES[@]}"; do
    [ -f "$file" ] && [ ! -L "$file" ] || die "missing or symlinked acceptance source: $file" \
        "The exact four runners and shared library are production package inputs."
done
[ -f "$UI_PACKAGE_MAKEFILE" ] || die "missing bpirouter-ui package Makefile: $UI_PACKAGE_MAKEFILE" \
    "The release package layout cannot be proven without its feed recipe."

NEWER_LIST=$(mktemp)
NEWER_ERR=$(mktemp)
trap 'rm -f "$NEWER_LIST" "$NEWER_ERR"' EXIT
if ! find "${SRC_DIRS[@]}" "${UI_ACCEPTANCE_FILES[@]}" "$UI_PACKAGE_MAKEFILE" -type f -newer "$APK" \
    -not -path '*/node_modules/*' -not -name '*_test.go' \
    >"$NEWER_LIST" 2>"$NEWER_ERR"; then
    detail=$(sed -n '1,5p' "$NEWER_ERR")
    die "could not scan bpirouter-ui source freshness" \
        "${detail:-find returned an error without diagnostics}"
fi

if [ -s "$NEWER_LIST" ]; then
    NEWER=$(sed -n '1,5p' "$NEWER_LIST")
    n=$(wc -l <"$NEWER_LIST" | tr -d '[:space:]')
    die "bpirouter-ui source is newer than the packaged .apk" \
        "package  $(date -d @"$(stat -c %Y "$APK")" '+%Y-%m-%d %H:%M')  $(basename "$APK")
  $n file(s) changed since, e.g.:
$(echo "$NEWER" | sed "s#$UI_DIR/#    #")
  Release mode packs the .apk, not the binaries it just compiled, so this image
  would ship the older backend, frontend and/or acceptance bundle.
  Run: $SCRIPT_DIR/build-full.sh --board <board>"
fi

echo -e "${G}✓ bpirouter-ui package is newer than every source file${N}"

: >"$NEWER_LIST"
: >"$NEWER_ERR"
if ! find "$BASE_SRC" -type f -newer "$BASE_APK" \
    -not -path '*/.git/*' -not -name '.*' -not -name '*.swp' \
    -not -name '*~' -not -name '*.tmp' -not -name '#*#' \
    >"$NEWER_LIST" 2>"$NEWER_ERR"; then
    detail=$(sed -n '1,5p' "$NEWER_ERR")
    die "could not scan bpirouter-base source freshness" \
        "${detail:-find returned an error without diagnostics}"
fi
if [ -s "$NEWER_LIST" ]; then
    NEWER=$(sed -n '1,5p' "$NEWER_LIST")
    n=$(wc -l <"$NEWER_LIST" | tr -d '[:space:]')
    die "bpirouter-base source is newer than the packaged .apk" \
        "package  $(date -d @"$(stat -c %Y "$BASE_APK")" '+%Y-%m-%d %H:%M')  $(basename "$BASE_APK")
  $n file(s) changed since, e.g.:
$(echo "$NEWER" | sed "s#$FEED_ROOT/#    #")
  Release mode would omit the reviewed QMF-15/QMF-16 payload vintage.
  Run: $SCRIPT_DIR/build-full.sh --board <board>"
fi

echo -e "${G}✓ bpirouter-base package is newer than every source file${N}"
