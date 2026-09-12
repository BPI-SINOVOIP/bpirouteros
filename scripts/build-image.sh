#!/bin/bash
# build-image.sh — Quick firmware packaging using ImageBuilder
#
# Usage:
#   ./scripts/build-image.sh [--board <board>]              Quick mode
#   ./scripts/build-image.sh [--board <board>] --release    Release mode
#   --board: bpi-r4 (default), bpi-r4-lite, bpi-r4-pro, bpi-r3, bpi-r3-mini, openwrt-one
#
# Prerequisite: Run build-full.sh at least once (to generate ImageBuilder + .apk repository)
set -eo pipefail

# WSL: drop /mnt/c/* PATH entries. Windows paths contain spaces (e.g.
# "/mnt/c/Program Files/Git/cmd"), and OpenWrt's Makefile passes PATH
# through an unquoted shell expansion to `find`. The space-split fragment
# ("Files/Git/cmd") looks like a relative path, find -execdir refuses to
# run, and `make image` aborts on prepare_rootfs.
if grep -qi microsoft /proc/version 2>/dev/null; then
    PATH=$(echo "$PATH" | tr ':' '\n' | grep -v '^/mnt/[a-zA-Z]/' | paste -sd: -)
    export PATH
fi

OPENWRT_VERSION="25.12.5"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$(dirname "$SCRIPT_DIR")"
WORK_DIR="$BUILD_DIR/openwrt"
UI_DIR="$BUILD_DIR/../bpirouter-ui"
FEEDS_DIR="$BUILD_DIR/../bpirouter-feeds"
IB_DIR="$BUILD_DIR/imagebuilder"

C='\033[0;36m'
G='\033[0;32m'
R='\033[0;31m'
Y='\033[0;33m'
N='\033[0m'
step() { echo -e "${C}▸ $1${N}"; }
ok()   { echo -e "${G}✓ $1${N}"; }
# quick_warn: quick mode injects files via FILES= and skips the bpirouter-ui
# apk, so it omits parts that --release ships — the image must NOT be delivered
# or used for §11 acceptance. Printed at both the start and the end of a quick
# build so it can't scroll past unseen.
quick_warn() {
    echo -e "${R}╔══════════════════════════════════════════════════════════════════╗${N}"
    echo -e "${R}║  QUICK BUILD — DEV / SELF-TEST ONLY · NOT FOR DELIVERY OR §11     ║${N}"
    echo -e "${R}╚══════════════════════════════════════════════════════════════════╝${N}"
    echo -e "${Y}  The FILES= overlay omits files that --release ships via apk:${N}"
    echo -e "${Y}    · bpirouter-bootok          (A/B boot-health bootcount/altcount clear)${N}"
    echo -e "${Y}    · keep.d/bpirouter-ui       (config preserved across sysupgrade)${N}"
    echo -e "${Y}  => A/B OTA / rollback / config-keep are INCOMPLETE in this image.${N}"
    echo -e "${Y}  Deliverable / acceptance images:  $0 --board $BOARD --release${N}"
}

# ── Parse args ──
BOARD="bpi-r4"
MODE="quick"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --board) BOARD="$2"; shift 2 ;;
        --board=*) BOARD="${1#*=}"; shift ;;
        --release) MODE="release"; shift ;;
        *) echo "Unknown argument: $1"; shift ;;
    esac
done

source "$SCRIPT_DIR/boards.sh"
board_init "$BOARD"

# A board whose identity is frozen but whose implementation is not cannot produce
# this output. Refuse by name so the message points at the missing 22-D work
# instead of surfacing later as an absent config or an empty file contract.
[ "$BOARD_IMPLEMENTED" = yes ] || {
    echo -e "${R}✗ board $BOARD has a frozen identity without build admission yet${N}" >&2
    echo -e "${R}  see RELEASE-v1.5-EXECUTION-PLAN 22-D step 6${N}" >&2
    exit 1
}

case " $PLANNED_BOARDS " in
    *" $BOARD "*)
        echo "board $BOARD has a frozen identity; 22-D step 6 uses development build-full, not ImageBuilder" >&2
        exit 1 ;;
esac

# FILES= cannot repair a tree prepared for another board, and release mode must
# bind the ImageBuilder to the exact base-files patch set that build-full used.
# In particular, Task 19's rc.common service fence is a tracked source change,
# not part of either bpirouter apk.
"$SCRIPT_DIR/check-prepared.sh" "$BOARD"

# QMF-15 is a source/payload contract, not a runtime best-effort migration.
# Fail before assembling either quick or release images if a canonicalizer, a
# strict reader, or the six-board package selection has drifted.
BPIR_FEEDS_DIR="$FEEDS_DIR" \
BPIR_MWAN3_STOCK="$WORK_DIR/feeds/packages/net/mwan3/files/etc/config/mwan3" \
    "$SCRIPT_DIR/test-mwan3-canonical.sh"
"$SCRIPT_DIR/test-mwan3-route-delete-order.sh"
BPIR_FEEDS_DIR="$FEEDS_DIR" "$SCRIPT_DIR/test-sqm-canonical.sh"
BPIR_FEEDS_DIR="$FEEDS_DIR" "$SCRIPT_DIR/test-offload-disabled.sh"
BPIR_FEEDS_DIR="$FEEDS_DIR" BPIR_UI_DIR="$UI_DIR" "$SCRIPT_DIR/test-owned-configs.sh"
"$SCRIPT_DIR/test-cellular-package-scope.sh"
"$SCRIPT_DIR/test-cellular-netifd-lifecycle.sh"
"$SCRIPT_DIR/test-netifd-dynamic-ip6assign.sh"
"$SCRIPT_DIR/test-netifd-proto-busy.sh"
BPIR_FEEDS_DIR="$FEEDS_DIR" "$SCRIPT_DIR/test-factory-reset-rootfs.sh"
BPIR_FEEDS_DIR="$FEEDS_DIR" "$SCRIPT_DIR/test-rootfs-integrity.sh"

echo -e "${Y}Board: $BOARD ($PROFILE) | Mode: $MODE${N}"
echo ""

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 0. Find or extract ImageBuilder
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
if [ ! -d "$IB_DIR/staging_dir" ]; then
    step "Setting up ImageBuilder..."
    # `|| true` keeps a no-match `ls` (or empty `grep`) from killing the script
    # via pipefail before we get a chance to fall back to the official download.
    IB_TAR=$(ls "$WORK_DIR/bin/targets/${TARGET}/"*imagebuilder*.tar.* 2>/dev/null | head -1 || true)
    if [ -z "$IB_TAR" ]; then
        if [ "$MODE" = "release" ]; then
            echo -e "${R}Release mode requires local ImageBuilder from build-full.sh.${N}"
            echo -e "${R}Official ImageBuilder cannot verify locally-signed .apk packages.${N}"
            echo "  Run: ./scripts/build-full.sh --board $BOARD"
            exit 1
        fi
        step "No local ImageBuilder found. Downloading official..."
        IB_URL="https://downloads.openwrt.org/releases/${OPENWRT_VERSION}/targets/${TARGET}/"
        IB_FILE=$(curl -sL "$IB_URL" | grep -o 'openwrt-imagebuilder[^"]*\.tar\.[xz|zst]*' | head -1 || true)
        if [ -z "$IB_FILE" ]; then
            echo -e "${R}Cannot find ImageBuilder. Run build-full.sh --board $BOARD first.${N}"
            exit 1
        fi
        wget -P /tmp "$IB_URL/$IB_FILE"
        IB_TAR="/tmp/$IB_FILE"
    fi
    mkdir -p "$IB_DIR"
    tar xf "$IB_TAR" --strip-components=1 -C "$IB_DIR"
    ok "ImageBuilder ready"
fi

# ── Sync build keys ──
if [ -d "$WORK_DIR/keys" ]; then
    step "Syncing build keys for apk signature verification..."
    mkdir -p "$IB_DIR/keys"
    cp -f "$WORK_DIR/keys/"* "$IB_DIR/keys/" 2>/dev/null
    ok "Build keys synced: $(ls $IB_DIR/keys/ | wc -l) key files"
fi

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 1. Build BpiRouter application layer
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Quick mode only. Release mode resolves bpirouter-ui from the .apk repository
# a previous build-full.sh produced, so anything compiled here would be built
# and then thrown away -- while the scrolling build log tells the operator the
# image contains it. check-artifacts.sh below guards what release mode really
# ships; this block guards what quick mode really ships.
if [ "$MODE" != "release" ]; then
    step "Building Go API (arm64)..."
    cd "$UI_DIR/backend"
    [ ! -f go.sum ] && go mod tidy
    CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build \
        -ldflags="-s -w" -o /tmp/bpirouter-apid ./cmd/apid/
    ok "Go binary"

    step "Building Vue frontend..."
    cd "$UI_DIR/frontend"
    [ -d node_modules ] || npm ci --silent
    npx vite build --outDir /tmp/bpirouter-www/
    ok "Frontend"
else
    # The .apk is the only thing release mode installs bpirouter-ui from, so its
    # vintage IS the image's. Refuse rather than assemble a plausible-looking
    # image around a package that predates the source.
    "$SCRIPT_DIR/check-artifacts.sh"
fi

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 2. Choose packaging method based on mode
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

BASE_PACKAGES="nginx-ssl openssl-util wireguard-tools openvpn-openssl mwan3 sqm flock \
    $WIFI_PKGS \
    luci luci-ssl"

cd "$IB_DIR"

if [ "$MODE" = "release" ]; then
    # ── Release mode: Register local apk repository ──
    step "[release] Registering local package repository..."

    LOCAL_APK_DIR="$WORK_DIR/bin/packages/$(pkg_arch)/bpirouter"
    if [ ! -d "$LOCAL_APK_DIR" ]; then
        LOCAL_APK_DIR="$WORK_DIR/bin/targets/${TARGET}/packages"
    fi

    if [ ! -d "$LOCAL_APK_DIR" ] || [ -z "$(ls $LOCAL_APK_DIR/*.apk 2>/dev/null)" ]; then
        echo -e "${R}No .apk files found. Run build-full.sh --board $BOARD first.${N}"
        exit 1
    fi

    REPO_CONF="$IB_DIR/repositories.conf"
    [ ! -f "$REPO_CONF.orig" ] && cp "$REPO_CONF" "$REPO_CONF.orig"
    cp "$REPO_CONF.orig" "$REPO_CONF"
    sed -i "1i src bpirouter file://$LOCAL_APK_DIR" "$REPO_CONF"
    ok "Local repo registered: $LOCAL_APK_DIR"

    # Derive the package set from the SAME per-board config that build-full's
    # `make` consumes (config/<board>.config + common.config), so the release
    # ImageBuilder image matches the verified full build instead of a hand-written
    # BASE_PACKAGES list that silently drifts (mwan3 / sqm / QMI / 10G PHY firmware
    # / kmod-leds-gpio were all missing from it). Mapping:
    #   CONFIG_PACKAGE_x=y            -> x      (add)
    #   # CONFIG_PACKAGE_x is not set -> -x     (remove, e.g. the unused wpad variant)
    # All these packages were built into the local apk repo by build-full, so
    # ImageBuilder can resolve them; bpirouter-ui's DEPENDS pull nginx/wireguard/etc.
    CONFIG_FILE="$BUILD_DIR/config/$BOARD.config"
    COMMON_CONFIG="$BUILD_DIR/config/common.config"
    if [ ! -f "$CONFIG_FILE" ]; then
        echo -e "${R}No build config for '$BOARD': $CONFIG_FILE${N}"; exit 1
    fi
    RELEASE_PACKAGES=$( { [ -f "$COMMON_CONFIG" ] && cat "$COMMON_CONFIG"; cat "$CONFIG_FILE"; } | \
        sed -nE 's/^CONFIG_PACKAGE_(.*)=y$/\1/p; s/^# CONFIG_PACKAGE_(.*) is not set$/-\1/p' | sort -u | tr '\n' ' ')
    ok "Release packages from $BOARD.config: $(echo "$RELEASE_PACKAGES" | wc -w) entries"

    step "[release] Building firmware with apk packages (from $BOARD.config)..."
    make image \
        PROFILE="$PROFILE" \
        PACKAGES="$RELEASE_PACKAGES"

else
    # ── Quick mode: FILES= raw injection ──
    quick_warn
    step "[quick] Preparing files overlay..."
    FILES_DIR="/tmp/bpirouter-ib-files"
    rm -rf "$FILES_DIR"
    mkdir -p "$FILES_DIR/usr/bin"
    mkdir -p "$FILES_DIR/usr/libexec"
    mkdir -p "$FILES_DIR/www/bpirouter"
    mkdir -p "$FILES_DIR/usr/share/bpirouter/nginx"
    mkdir -p "$FILES_DIR/etc/nginx"
    mkdir -p "$FILES_DIR/etc/init.d"
    mkdir -p "$FILES_DIR/etc/rc.d"
    mkdir -p "$FILES_DIR/etc/uci-defaults"
	mkdir -p "$FILES_DIR/etc/modules.d"
    mkdir -p "$FILES_DIR/lib/bpirouter"
    mkdir -p "$FILES_DIR/etc"

    cp /tmp/bpirouter-apid "$FILES_DIR/usr/bin/bpirouter-apid"
    chmod +x "$FILES_DIR/usr/bin/bpirouter-apid"

    # nginx.conf in bpirouter.conf expects `root /www/bpirouter` — drop the
    # Vite bundle there, not /www/ where uhttpd's default landing page lives.
    cp -r /tmp/bpirouter-www/* "$FILES_DIR/www/bpirouter/"

    # Be explicit about each nginx file's target — nginx.conf goes to
    # /etc/nginx/ (top-level), the rest to /usr/share/bpirouter/nginx/
    # which 99-bpirouter-setup symlinks into /etc/nginx/conf.d/.
    cp "$UI_DIR/deploy/nginx/nginx.conf"               "$FILES_DIR/etc/nginx/nginx.conf"
    cp "$UI_DIR/deploy/nginx/bpirouter.conf"           "$FILES_DIR/usr/share/bpirouter/nginx/bpirouter.conf"
    cp "$UI_DIR/deploy/nginx/bpirouter-locations.inc"  "$FILES_DIR/usr/share/bpirouter/nginx/bpirouter-locations.inc"

    cp "$UI_DIR/deploy/init.d/bpirouter-api"          "$FILES_DIR/etc/init.d/"
    cp "$UI_DIR/deploy/init.d/bpirouter-cfg-recovery" "$FILES_DIR/etc/init.d/"
    cp "$UI_DIR/deploy/init.d/bpirouter-ota-restore"  "$FILES_DIR/etc/init.d/"
    chmod +x "$FILES_DIR/etc/init.d/bpirouter-api" \
        "$FILES_DIR/etc/init.d/bpirouter-cfg-recovery" \
        "$FILES_DIR/etc/init.d/bpirouter-ota-restore"
    cp "$UI_DIR/deploy/scripts/bpirouter-ota-restore" "$FILES_DIR/usr/libexec/"
    chmod +x "$FILES_DIR/usr/libexec/bpirouter-ota-restore"
    cp "$UI_DIR/deploy/scripts/gen-cert.sh"        "$FILES_DIR/usr/bin/bpirouter-gen-cert"
    chmod +x "$FILES_DIR/usr/bin/bpirouter-gen-cert"
    cp "$UI_DIR/deploy/uci-defaults/99-bpirouter-setup" "$FILES_DIR/etc/uci-defaults/"
    chmod +x "$FILES_DIR/etc/uci-defaults/99-bpirouter-setup"

    # Quick images remain non-release OTA builds, but they must still be safe
    # to boot. Mirror bpirouter-base's canonical mwan payload; the post-build
    # rootfs gate below proves these raw files survived ImageBuilder assembly.
    # Both canonicalizers and both strict readers. bpirouter-base is not in
    # BASE_PACKAGES, so nothing else puts them in a quick image -- and the gate
    # below has required the sqm pair since whole-file config ownership was
    # gated, which is how quick mode came to fail it.
    BASE_FILES="$FEEDS_DIR/net/bpirouter-base/files"
    cp "$BASE_FILES/etc/uci-defaults/11-bpirouter-mwan3-canonical" "$FILES_DIR/etc/uci-defaults/"
    cp "$BASE_FILES/etc/uci-defaults/12-bpirouter-sqm-canonical" "$FILES_DIR/etc/uci-defaults/"
	cp "$BASE_FILES/etc/uci-defaults/13-bpirouter-offload-disabled" "$FILES_DIR/etc/uci-defaults/"
	case " $WIFI_PKGS " in
		*" kmod-mt7915e "*) printf '%s\n' 'mt7915e wed_enable=0' >"$FILES_DIR/etc/modules.d/mt7915e" ;;
		*" kmod-mt7996e "*) printf '%s\n' 'mt7996e wed_enable=0' >"$FILES_DIR/etc/modules.d/mt7996e" ;;
		*) echo -e "${R}No supported Wi-Fi driver for the WED-disable overlay.${N}"; exit 1 ;;
	esac
    cp "$BASE_FILES/usr/libexec/bpirouter-mwan3-strict.awk" "$FILES_DIR/usr/libexec/"
    cp "$BASE_FILES/usr/libexec/bpirouter-sqm-strict.awk" "$FILES_DIR/usr/libexec/"
    chmod +x "$FILES_DIR/etc/uci-defaults/11-bpirouter-mwan3-canonical" \
             "$FILES_DIR/etc/uci-defaults/12-bpirouter-sqm-canonical" \
		     "$FILES_DIR/etc/uci-defaults/13-bpirouter-offload-disabled"
    ln -s ../init.d/bpirouter-cfg-recovery "$FILES_DIR/etc/rc.d/S11bpirouter-cfg-recovery"
    ln -s ../init.d/bpirouter-ota-restore "$FILES_DIR/etc/rc.d/S10bpirouter-ota-restore"
    ln -s ../init.d/bpirouter-api "$FILES_DIR/etc/rc.d/S99bpirouter-api"

    # Mirror the apk install layout: banner ships as /etc/banner.bpirouter and
    # 99-bpirouter-defaults renames it to /etc/banner on first boot. Quick mode
    # and release mode must drop the file at the same path.
    [ -f "$FEEDS_DIR/net/bpirouter-base/files/etc/banner" ] && \
        cp "$FEEDS_DIR/net/bpirouter-base/files/etc/banner" "$FILES_DIR/etc/banner.bpirouter"

    [ -f "$FEEDS_DIR/net/bpirouter-base/files/etc/uci-defaults/99-bpirouter-defaults" ] && \
        cp "$FEEDS_DIR/net/bpirouter-base/files/etc/uci-defaults/99-bpirouter-defaults" \
           "$FILES_DIR/etc/uci-defaults/" && \
        chmod +x "$FILES_DIR/etc/uci-defaults/99-bpirouter-defaults"

    ok "Files overlay: $(find $FILES_DIR -type f | wc -l) files"

    step "[quick] Building firmware with FILES overlay..."
    make image \
        PROFILE="$PROFILE" \
        PACKAGES="$BASE_PACKAGES" \
        FILES="$FILES_DIR"

    rm -rf "$FILES_DIR"
fi

# Source checks cannot prove which base-files vintage an extracted ImageBuilder
# actually packed. Inspect the concrete assembled rootfs before copying any
# image into output; a stale local/official ImageBuilder without the rc.common
# hook therefore fails closed even when both custom apks are fresh.
mapfile -t IB_ROOTS < <(find "$IB_DIR/build_dir" -maxdepth 2 -type d -name 'root-mediatek' -print 2>/dev/null)
if [ "${#IB_ROOTS[@]}" -ne 1 ]; then
    echo -e "${R}Expected exactly one assembled ImageBuilder rootfs for the D21 release gate; found ${#IB_ROOTS[@]}.${N}"
    exit 1
fi
"$SCRIPT_DIR/test-netifd-proto-busy.sh" --rootfs "${IB_ROOTS[0]}"
"$SCRIPT_DIR/check-rootfs-integrity.sh" "${IB_ROOTS[0]}"
"$SCRIPT_DIR/check-factory-reset-rootfs.sh" "${IB_ROOTS[0]}"
if [ "$MODE" = release ]; then
    "$SCRIPT_DIR/check-acceptance-provenance-rootfs.sh" "${IB_ROOTS[0]}" \
        --feed-files "$FEEDS_DIR/net/bpirouter-ui/files"
fi

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 3. Output results
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
echo ""
ok "Image build complete! (board=$BOARD, mode=$MODE)"
echo ""
echo "  Firmware location:"
ls -lh "$IB_DIR/bin/targets/${TARGET}/"*${PROFILE}*sysupgrade* 2>/dev/null || true
ls -lh "$IB_DIR/bin/targets/${TARGET}/"*${PROFILE}*sdcard* 2>/dev/null || true

mkdir -p "$BUILD_DIR/output"
cp "$IB_DIR/bin/targets/${TARGET}/"*${PROFILE}* "$BUILD_DIR/output/" 2>/dev/null || true
echo ""
echo "  Copied to: $BUILD_DIR/output/"

rm -rf /tmp/bpirouter-apid /tmp/bpirouter-www

[ "$MODE" = "quick" ] && { echo ""; quick_warn; }
