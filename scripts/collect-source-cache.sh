#!/bin/bash
# collect-source-cache.sh — the exact set of upstream sources each board downloads.
#
# Usage: collect-source-cache.sh --output <dir> [--release <version>]
#                               [--boards "a b"] [--mirror <url>] [--resume]
#
# For each board this prepares the tree, points openwrt/dl at an EMPTY
# per-board directory and runs `make download`. What lands there is what that
# board's build actually asked for.
#
# It is deliberately not derived. The alternative -- parsing PKG_SOURCE and
# PKG_HASH out of every Makefile -- produces a list that looks the same and is
# not the same thing: it re-implements OpenWrt's download resolution, and drifts
# from it silently whenever upstream changes how a package is fetched. A
# release's source cache has to be what the release consumed, so it is collected
# by consuming it.
#
# The developer's own dl/ cannot stand in for this. It is shared across builds
# and holds several versions of the same package -- here 502 files, 3.8 GB, with
# three vintages of wireless-regdb -- so publishing it would ship objects this
# release never touched.
#
# --mirror only changes where the bytes come from. Every file is still checked
# against the hash OpenWrt expects, and a mirror miss falls through to the real
# URL, so the collected set does not depend on the mirror being complete.
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$(dirname "$SCRIPT_DIR")"
WORK_DIR="$BUILD_DIR/openwrt"

C='\033[0;36m'; G='\033[0;32m'; Y='\033[0;33m'; R='\033[0;31m'; N='\033[0m'
step() { echo -e "${C}▸ $1${N}"; }
ok()   { echo -e "${G}✓ $1${N}"; }
warn() { echo -e "${Y}! $1${N}"; }
die()  { echo -e "${R}✗ $1${N}" >&2; exit 1; }

OUT=""; MIRROR=""; RESUME=no; BOARDS=""; RELEASE=""
while [ $# -gt 0 ]; do
    case "$1" in
        --output)  OUT="$2"; shift 2 ;;
        --boards)  BOARDS="$2"; shift 2 ;;
        --release) RELEASE="$2"; shift 2 ;;
        --mirror)  MIRROR="$2"; shift 2 ;;
        --resume)  RESUME=yes; shift ;;
        *) die "unknown argument: $1" ;;
    esac
done
[ -n "$OUT" ] || die "usage: collect-source-cache.sh --output <dir> [--boards ...] [--mirror <url>]"

# Older collectors replaced this directory with a relative symlink.  It makes
# ordinary OpenWrt builds fail at their first `mkdir -p $(DL_DIR)`, and guessing
# whether a symlink is user-owned would be unsafe.  A fresh collector never
# creates one, so require the normal directory shape up front.
[ ! -L "$WORK_DIR/dl" ] || die "refusing legacy symlink at openwrt/dl; replace it with a normal shared download directory before collecting"
[ -d "$WORK_DIR/dl" ] || die "openwrt/dl must be a normal directory"

# OpenWrt recursively invokes make from package directories. A relative
# CONFIG_DOWNLOAD_FOLDER would therefore resolve differently for every
# sub-make, splintering one board's source set across the tree. Resolve it once
# before it is written into .config so DL_DIR is stable at every make depth.
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd -P)"

source "$SCRIPT_DIR/boards.sh"
if [ -n "$RELEASE" ]; then
    "$SCRIPT_DIR/lib/release-lock-contract.py" release-version --release "$RELEASE" --format apk >/dev/null
    bpir_select_release_boards "$RELEASE"
fi
[ -n "$BOARDS" ] || BOARDS="$VALID_BOARDS"

mkdir -p "$OUT/logs" "$OUT/manifest"
FAILED=""

for B in $BOARDS; do
    DL="$OUT/dl-$B"
    MF="$OUT/manifest/$B.tsv"
    if [ "$RESUME" = yes ] && [ -s "$MF" ]; then
        ok "$B: already collected ($(wc -l <"$MF") files) — skipping"
        continue
    fi

    step "$B: preparing the tree..."
    # Collection precedes the release lock. Use the existing development path
    # with the complete package selection; this does not build the private UI.
    ( cd "$BUILD_DIR" && ./scripts/prepare.sh --board "$B" --development \
        --ui-source "$BUILD_DIR/../bpirouter-ui" ) \
        >"$OUT/logs/$B-prepare.log" 2>&1 \
        || { tail -25 "$OUT/logs/$B-prepare.log"; warn "$B: prepare failed — skipping"; FAILED="$FAILED $B(prepare)"; continue; }

    # An empty directory per board is the whole point: anything present before
    # the run would be indistinguishable from something this board needed.
    #
    # Do not replace $WORK_DIR/dl with a symlink. OpenWrt's download rules own
    # that directory and run `mkdir -p $(DL_DIR)` before fetching; a symlink at
    # that pathname makes the command fail with EEXIST on current OpenWrt.
    # CONFIG_DOWNLOAD_FOLDER is the supported override and leaves a developer's
    # shared dl/ untouched.
    rm -rf "$DL"; mkdir -p "$DL"

    # Appended after prepare, which is the last thing to run defconfig. Setting
    # it earlier would be normalised away.
    sed -i '/^CONFIG_LOCALMIRROR=/d' "$WORK_DIR/.config"
    sed -i '/^CONFIG_DOWNLOAD_FOLDER=/d' "$WORK_DIR/.config"
    echo "CONFIG_LOCALMIRROR=\"$MIRROR\"" >> "$WORK_DIR/.config"
    echo "CONFIG_DOWNLOAD_FOLDER=\"$DL\"" >> "$WORK_DIR/.config"

    step "$B: make download (tools, toolchain, package, target)..."
    # -k rather than stopping at the first failure: one unreachable upstream
    # should not hide the state of everything after it. The run still fails at
    # the end -- a source cache with a hole in it is not a source cache.
    #
    # V=s keeps the URL each file actually came from in the log, which is what
    # DOWNLOADS.lock.json records. A URL reconstructed from the Makefile is a
    # guess about what happened.
    RC=0
    ( cd "$WORK_DIR" && make download -j"$(nproc)" -k V=s </dev/null ) \
        >"$OUT/logs/$B.log" 2>&1 || RC=$?

    # Kept because `make download` fetches more than the board builds. OpenWrt
    # registers some Download rules unconditionally -- package/kernel/mac80211
    # pulls Broadcom's b43 firmware whether or not any b43 package is selected
    # -- so "in the cache" does not mean "this board needs it". The config is
    # what distinguishes the two, and it is overwritten by the next board.
    mkdir -p "$OUT/config" "$OUT/packageinfo"
    cp "$WORK_DIR/.config" "$OUT/config/$B.config"
    # Package metadata is rewritten by every prepare, so reading it live from
    # the tree races whatever ran last. A downloads lock built against a
    # half-written .packageinfo loses attribution for most of the cache and
    # looks like a hundred new unattributed objects.
    [ -f "$WORK_DIR/tmp/.packageinfo" ] && cp "$WORK_DIR/tmp/.packageinfo" "$OUT/packageinfo/$B.packageinfo"

    COUNT=$(find -L "$DL" -maxdepth 1 -type f ! -name '*.hash' | wc -l)
    [ "$RC" -eq 0 ] || { warn "$B: make download exited $RC (see logs/$B.log)"; FAILED="$FAILED $B(download)"; }
    [ "$COUNT" -gt 0 ] || { warn "$B: nothing was downloaded"; FAILED="$FAILED $B(empty)"; continue; }

    step "$B: hashing $COUNT files..."
    : >"$MF"
    while IFS= read -r f; do
        printf '%s\t%s\t%s\n' "$(sha256sum "$f" | cut -d' ' -f1)" "$(stat -c%s "$f")" "$(basename "$f")" >>"$MF"
    done < <(find -L "$DL" -maxdepth 1 -type f ! -name '*.hash' | LC_ALL=C sort)
    ok "$B: $COUNT files, $(du -sLh "$DL" | cut -f1)"
done

echo
step "Per-board totals"
for B in $BOARDS; do
    MF="$OUT/manifest/$B.tsv"
    [ -s "$MF" ] && printf '  %-14s %4d files\n' "$B" "$(wc -l <"$MF")" || printf '  %-14s %s\n' "$B" "(none)"
done

if [ -n "$FAILED" ]; then
    warn "boards with problems:$FAILED"
    die "collection is incomplete — a source cache missing an input cannot be published"
fi
ok "all boards collected into $OUT"
