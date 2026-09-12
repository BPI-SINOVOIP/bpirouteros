#!/bin/bash
# Copyright (C) 2026 Ning <mimallaus@gmail.com>
# prepare.sh — Prepare OpenWrt build environment
# Usage: ./scripts/prepare.sh [--board <board>]
#        [--development | --release-lock <file>]
#   --board: bpi-r4 (default), bpi-r4-lite, bpi-r4-pro, bpi-r3, bpi-r3-mini, openwrt-one
set -eo pipefail

# WSL: drop /mnt/c/* PATH entries — Windows paths with spaces break
# OpenWrt's Makefile shell tokenization and trip GNU find -execdir's
# relative-path safety check. See build-image.sh for the full story.
if grep -qi microsoft /proc/version 2>/dev/null; then
    PATH=$(echo "$PATH" | tr ':' '\n' | grep -v '^/mnt/[a-zA-Z]/' | paste -sd: -)
    export PATH
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$(dirname "$SCRIPT_DIR")"
[ -n "${BPIR_BUILD_DIR:-}" ] && BUILD_DIR="$BPIR_BUILD_DIR"
WORK_DIR="${BPIR_WORK_DIR:-$BUILD_DIR/openwrt}"
source "$SCRIPT_DIR/lib/openwrt-source.sh"
source "$SCRIPT_DIR/lib/kernel-patch-routing.sh"

C='\033[0;36m'
G='\033[0;32m'
Y='\033[0;33m'
R='\033[0;31m'
N='\033[0m'
step() { echo -e "${C}▸ $1${N}"; }
ok()   { echo -e "${G}✓ $1${N}"; }
warn() { echo -e "${Y}! $1${N}"; }
fail() { echo -e "${R}✗ $1${N}"; exit 1; }

source "$SCRIPT_DIR/lib/release-gate.sh"

# ── Parse args ──
#
# The UI mode is decided HERE, not at build time. It changes the derived
# .config -- every board config selects CONFIG_PACKAGE_bpirouter-ui, so a build
# that merely skips the UI step still tries to package it and either fails on a
# missing files/ or, worse, packages whatever a previous build left behind.
# Deciding it at prepare puts it where the tree records it.
#
# Exactly one mode, never inferred. Probing for ../bpirouter-ui would mean a
# machine that happens to have a directory of that name silently builds a
# different image from one that does not.
BOARD="bpi-r4"
UI_MODE=""; UI_SOURCE=""; UI_ARTIFACT=""
RELEASE_LOCK_ARG=""
DEVELOPMENT=0
set_mode() {
    [ -z "$UI_MODE" ] || fail "UI mode already set to '$UI_MODE'; --ui-source, --ui-artifact and --without-proprietary-ui are mutually exclusive"
    UI_MODE="$1"
}
while [[ $# -gt 0 ]]; do
    case "$1" in
        --board) BOARD="$2"; shift 2 ;;
        --board=*) BOARD="${1#*=}"; shift ;;
        --ui-source)   set_mode source;   UI_SOURCE="$2"; shift 2 ;;
        --ui-artifact) set_mode artifact; UI_ARTIFACT="$2"; shift 2 ;;
        --without-proprietary-ui) set_mode none; shift ;;
        --development)
            [ "$DEVELOPMENT" = 0 ] || fail "--development was specified more than once"
            DEVELOPMENT=1
            shift
            ;;
        --release-lock) RELEASE_LOCK_ARG="$2"; shift 2 ;;
        *) fail "Unknown argument: $1" ;;
    esac
done
[ -n "$UI_MODE" ] || fail "no UI mode given. Pass exactly one of:
    --ui-source <dir>              build the UI from its source tree (needs a licence to it)
    --ui-artifact <apk>            stage a released UI package
    --without-proprietary-ui       build an image WITHOUT the BpiRouter UI and API
  This is required rather than defaulted: an image silently missing its
  management interface looks fine until it is flashed."
[ "$DEVELOPMENT" = 0 ] || [ -z "$RELEASE_LOCK_ARG" ] \
    || fail "--development and --release-lock are mutually exclusive"
[ "$DEVELOPMENT" = 0 ] || [ "$UI_MODE" = source ] \
    || fail "--development requires --ui-source"

case "$UI_MODE" in
    source)
        [ -d "$UI_SOURCE" ] || fail "--ui-source: no such directory: $UI_SOURCE"
        [ -x "$UI_SOURCE/deploy/build.sh" ] || fail "--ui-source: $UI_SOURCE has no deploy/build.sh"
        UI_SOURCE="$(cd "$UI_SOURCE" && pwd)"
        ;;
    artifact)
        [ -f "$UI_ARTIFACT" ] || fail "--ui-artifact: no such file: $UI_ARTIFACT"
        UI_ARTIFACT="$(cd "$(dirname "$UI_ARTIFACT")" && pwd)/$(basename "$UI_ARTIFACT")"
        ;;
esac

# ── Which release lock describes this tree ──
# A published tree carries it at the root; the internal workspace writes it under
# dist/, one file per release.
#
# This used to end with a fixed dist/RELEASE-INPUTS.lock.json, which is not the
# name make-release-lock.sh writes -- it writes dist/RELEASE-INPUTS.<release>.lock.json.
# So a stale unversioned file from an earlier run shadowed every lock made since,
# and the tree was checked against a revision from days before. It failed closed
# that time. The dangerous direction is the same mistake passing.
#
# Resolve through the shared helper and check its status before using the path.
LOCKF=""
if [ "$DEVELOPMENT" = 1 ]; then
    # An explicit development prepare must not be influenced by canonical locks
    # left under dist/ or by a caller's BPIR_RELEASE_LOCK environment. It is
    # intentionally unbound and cannot authorize release collection.
    LOCKF=""
else
    LOCKF=$("$SCRIPT_DIR/lib/release-lock-contract.py" find-input --build-dir "$BUILD_DIR" \
        --explicit "${RELEASE_LOCK_ARG:-${BPIR_RELEASE_LOCK:-}}") || fail "cannot select release lock"
fi
find_lock() { echo "$LOCKF"; }

# A source build without an explicit lock is a development build. It may still
# be useful locally, but build-full deliberately emits no release provenance and
# collect-release-artifacts refuses it. Formal source mode has to name the lock
# on the command line; auto-discovering one would let a stale file silently turn
# an ordinary build into a claimed release build.
RELEASE_BOUND=0
BOUND_LOCK=""
UI_ARTIFACT_SHA=""
UI_PAYLOAD_SHA=""
UI_APID_SHA=""
if [ -n "$RELEASE_LOCK_ARG" ]; then
    EXPLICIT_SCOPE=tree
    git -C "$BUILD_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
        && git -C "$(dirname "$BUILD_DIR")/bpirouter-ui" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
        && git -C "$(dirname "$BUILD_DIR")/bpirouter-feeds" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
        && EXPLICIT_SCOPE=workspace
    [ "$UI_MODE" != source ] || [ "$EXPLICIT_SCOPE" = workspace ] \
        || fail "release source mode requires the complete three-repository workspace"
    if [ "$EXPLICIT_SCOPE" = workspace ]; then
        bpir_require_release_workspace "$SCRIPT_DIR" "$BUILD_DIR" "$LOCKF" \
            || fail "the executing prepare checkout does not match the explicit release lock"
        RELEASE_BOUND=1
        BOUND_LOCK="$LOCKF"
    else
        "$SCRIPT_DIR/check-release-lock.sh" --scope tree "$LOCKF" \
            || fail "the explicit release lock does not describe the published build tree"
        warn "published-tree prepare is reproducible but not release-collectable; formal provenance requires the locked three-repository workspace"
    fi
    if [ "$UI_MODE" = source ]; then
        EXPECTED_UI=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["repos"]["bpirouter-ui"])' "$LOCKF")
        ACTUAL_UI=$(git -C "$UI_SOURCE" rev-parse HEAD 2>/dev/null || true)
        [ "$ACTUAL_UI" = "$EXPECTED_UI" ] \
            || fail "--ui-source is at ${ACTUAL_UI:-no git commit}; release lock requires ${EXPECTED_UI:0:12}"
        [ -z "$(git -C "$UI_SOURCE" status --porcelain 2>/dev/null)" ] \
            || fail "--ui-source has uncommitted changes; release source must exactly match the lock"
    fi
elif [ "$UI_MODE" = source ]; then
    warn "source mode has no explicit --release-lock; this is a development-only prepare and cannot be collected as a release"
fi

source "$SCRIPT_DIR/boards.sh"
if [ -n "$LOCKF" ]; then
    LOCK_RELEASE=$("$SCRIPT_DIR/lib/release-lock-contract.py" release-id --input-lock "$LOCKF") \
        || fail "cannot read release ID"
    bpir_select_release_boards "$LOCK_RELEASE"
fi
board_init "$BOARD"

# A board whose identity is frozen but whose implementation is not cannot produce
# this output. Refuse by name so the message points at the missing 22-D work
# instead of surfacing later as an absent config or an empty file contract.
[ "$BOARD_IMPLEMENTED" = yes ] || fail "board $BOARD is a frozen identity without build admission yet (RELEASE-v1.5-EXECUTION-PLAN 22-D step 6); source inputs alone do not satisfy the build gate"
case " $PLANNED_BOARDS " in
    *" $BOARD "*) [ "$DEVELOPMENT" = 1 ] || fail "board $BOARD has a frozen identity; 22-D step 6 permits explicit --development only" ;;
esac

# ── Refuse a board this tree cannot finish ──
# The lock names the boards that need an input we may not redistribute. Until
# now that was written into the published README and nowhere else, so a customer
# on such a board got a normal-looking prepare and a build that died much later
# on a missing firmware file.
#
# The test is whether the input is actually absent, not merely that the board is
# listed: in our own workspace the blob is present and only its redistribution
# is unsettled, and refusing to build here would stop the builds that produce
# the release.
LOCKF_EARLY="$(find_lock)"
if [ -f "$LOCKF_EARLY" ]; then
    MISSING=$(python3 -c "
import json,sys
lock=json.load(open(sys.argv[1])); board=sys.argv[2]
if board in lock.get('boards_unbuildable_publicly',[]):
    for e in lock.get('non_source_inputs',[]):
        if e.get('redistribution')!='confirmed' and e['path'].startswith('patches/%s/'%board):
            print(e['path'])" "$LOCKF_EARLY" "$BOARD" 2>/dev/null || true)
    while IFS= read -r rel; do
        [ -n "$rel" ] || continue
        [ -f "$BUILD_DIR/$rel" ] || fail "board '$BOARD' cannot be built from this tree.
  It needs $rel, which is not here: the release lock records its redistribution
  rights as unconfirmed, so it is withheld from published trees.
  Build another board, or obtain the file from the vendor and place it at that path."
    done <<<"$MISSING"
fi

step "Board: $BOARD ($PROFILE)"

# The marker, patches, .config, build_dir and staging_dir are one shared mutable
# domain. Acquire the same lock used by build-full before the first mutation and
# keep it until the complete marker is on disk. A coordinator can pass an
# inherited descriptor to hold this continuously across prepare -> build.
source "$SCRIPT_DIR/lib/openwrt-build-lock.sh"
bpir_acquire_openwrt_build_lock "$WORK_DIR" || fail "cannot acquire the OpenWrt build lock"
if [ -n "${BPIR_TEST_AFTER_OPENWRT_LOCK:-}" ]; then
    : >"$BPIR_TEST_AFTER_OPENWRT_LOCK"
    # Test probe only: fail closed before touching the marker. It must never
    # turn an accidentally inherited test variable into a successful prepare.
    exit 99
fi

WORK_DIR_EXISTS=0
if [ -e "$WORK_DIR" ] || [ -L "$WORK_DIR" ]; then
    bpir_is_exact_openwrt_worktree "$WORK_DIR" \
        || fail "OpenWrt path exists but is not an exact OpenWrt checkout root: $WORK_DIR"
    WORK_DIR_EXISTS=1
fi

# ── 0. Invalidate the prepare marker BEFORE touching anything ──
# Dropped first, written back only on success (end of this script). An
# interrupted prepare therefore leaves NO marker rather than a marker that
# claims a board whose patches were only half applied — build-full.sh refuses
# to build without one, which is the safe direction.
MARKER="$WORK_DIR/.bpirouter-prepared-board"
rm -f "$MARKER"

# ── 1. Clone OpenWrt Mainline ──
if [ "$WORK_DIR_EXISTS" = 1 ]; then
    bpir_is_exact_openwrt_worktree "$WORK_DIR" \
        || fail "OpenWrt checkout root changed before reset: $WORK_DIR"
    if [ "$UI_MODE" = source ] && [ -z "$RELEASE_LOCK_ARG" ]; then
        step "OpenWrt exists — synchronizing to $BPIR_OPENWRT_GIT_REF before re-patching"
        bpir_sync_openwrt_development_source "$WORK_DIR" \
            || fail "cannot synchronize OpenWrt to $BPIR_OPENWRT_GIT_REF ($BPIR_OPENWRT_GIT_COMMIT)"
    else
        step "OpenWrt exists — resetting tracked source to pristine before re-patching"
        bpir_reset_openwrt_source "$WORK_DIR" \
            || fail "cannot reset OpenWrt source to pristine HEAD"
    fi
    # Re-apply patches idempotently: base-files patches use `git apply`, which is
    # NOT idempotent across runs (an updated patch fails --check against an
    # already-patched tree and gets silently skipped). Revert tracked source to
    # HEAD and drop our previously-injected (untracked) kernel/uboot/package
    # patches so every prepare re-applies the CURRENT patch set from a clean
    # base. build_dir / feeds / .config are untracked and left intact
    # (incremental build preserved).
    ok "Source reset to pristine"
else
    step "Cloning OpenWrt $BPIR_OPENWRT_GIT_REF ..."
    bpir_clone_openwrt "$WORK_DIR"
    bpir_is_exact_openwrt_worktree "$WORK_DIR" \
        || fail "cloned OpenWrt path is not an exact OpenWrt checkout root: $WORK_DIR"
    ok "OpenWrt cloned"
fi

cd "$WORK_DIR"

KERNEL_PATCH_DIR="$WORK_DIR/target/linux/mediatek/patches-6.12"
KERNEL_BACKPORT_DIR="$WORK_DIR/target/linux/generic/backport-6.12"
KERNEL_PENDING_DIR="$WORK_DIR/target/linux/generic/pending-6.12"
UBOOT_PATCH_DIR="$WORK_DIR/package/boot/uboot-mediatek/patches"
ATF_PATCH_DIR="$WORK_DIR/package/boot/arm-trusted-firmware-mediatek/patches"

# ── 2. Apply common patches (all boards) ──
apply_patches() {
    local src_dir="$1"
    local type="$2"   # kernel | kernel-backport | kernel-pending | uboot | atf | openwrt | base-files | packages

    [ -d "$src_dir" ] || return 0
    ls "$src_dir"/*.patch 1>/dev/null 2>&1 || return 0

    case "$type" in
        kernel)
            step "Injecting kernel patches from $src_dir ..."
            mkdir -p "$KERNEL_PATCH_DIR"
            for patch in "$src_dir"/*.patch; do
                basename=$(basename "$patch")
                if ! route="$(bpir_kernel_patch_route "$src_dir" "$BUILD_DIR/patches/$BOARD/kernel" "$basename")"; then
                    fail "generic kernel patch $patch is outside the board stack that routes it into OpenWrt's backport/pending layer"
                fi
                # 930/931 in the board stack are injected below into their
                # original generic layer; applying them as Mediatek target
                # patches would change the upstream order.
                [ "$route" = target ] || continue
                [[ ! "$basename" =~ ^[0-9] ]] && basename="900-bpirouter-${basename}"
                cp "$patch" "$KERNEL_PATCH_DIR/$basename"
                echo "  + $basename"
            done
            ok "Kernel patches injected"
            ;;
        kernel-backport|kernel-pending)
            local prefix destination upstream_name
            if [ "$type" = kernel-backport ]; then
                prefix="930-"
                destination="$KERNEL_BACKPORT_DIR"
            else
                prefix="931-"
                destination="$KERNEL_PENDING_DIR"
            fi
            step "Injecting $type patches from $src_dir ..."
            mkdir -p "$destination"
            for patch in "$src_dir"/${prefix}*.patch; do
                [ -e "$patch" ] || continue
                basename=$(basename "$patch")
                upstream_name="${basename#${prefix}??-}"
                [ "$upstream_name" != "$basename" ] \
                    || fail "invalid $type patch name: $basename"
                cp "$patch" "$destination/$upstream_name"
                echo "  + $upstream_name"
            done
            ok "$type patches injected"
            ;;
        uboot)
            step "Injecting U-Boot patches from $src_dir ..."
            mkdir -p "$UBOOT_PATCH_DIR"
            for patch in "$src_dir"/*.patch; do
                cp "$patch" "$UBOOT_PATCH_DIR/"
                echo "  + $(basename $patch)"
            done
            ok "U-Boot patches injected"
            ;;
        atf)
            step "Injecting ATF patches from $src_dir ..."
            mkdir -p "$ATF_PATCH_DIR"
            for patch in "$src_dir"/*.patch; do
                cp "$patch" "$ATF_PATCH_DIR/"
                echo "  + $(basename $patch)"
            done
            ok "ATF patches injected"
            ;;
        openwrt|base-files)
            step "Applying $type patches from $src_dir ..."
            for patch in "$src_dir"/*.patch; do
                if git apply --check "$patch" 2>/dev/null; then
                    git apply "$patch" && echo "  + $(basename "$patch")"
                elif git apply --reverse --check "$patch" 2>/dev/null; then
                    # reverse applies => already in the (reset) tree; benign, skip
                    echo "  = already applied: $(basename "$patch")"
                else
                    # neither forward nor reverse applies => a real conflict. Do NOT
                    # silently skip: a dropped base-files patch leaves the image
                    # missing board-level network/partition/recipe/DT rules while
                    # the build still reports success. Fail loudly instead.
                    fail "$type patch does NOT apply (conflict): $(basename "$patch") — fix before building"
                fi
            done
            ok "$type patches applied"
            ;;
        packages)
            step "Applying packages-feed patches from $src_dir ..."
            for patch in "$src_dir"/*.patch; do
                if git -C "$WORK_DIR/feeds/packages" apply --check "$patch" 2>/dev/null; then
                    git -C "$WORK_DIR/feeds/packages" apply "$patch" && echo "  + $(basename "$patch")"
                elif git -C "$WORK_DIR/feeds/packages" apply --reverse --check "$patch" 2>/dev/null; then
                    echo "  = already applied: $(basename "$patch")"
                else
                    fail "packages-feed patch does NOT apply (conflict): $(basename "$patch") — fix before building"
                fi
            done
            ok "Packages-feed patches applied"
            ;;
    esac
}

apply_patches "$BUILD_DIR/patches/common/kernel"     kernel
apply_patches "$BUILD_DIR/patches/common/uboot"      uboot
apply_patches "$BUILD_DIR/patches/common/atf"        atf
apply_patches "$BUILD_DIR/patches/common/openwrt"    openwrt
apply_patches "$BUILD_DIR/patches/common/base-files" base-files

# Both R4-Pro SKUs use the same pinned generic MxL driver stack. Import only
# its generic layers, never the 8X target DTS, PHY firmware or reset patches.
if [ "$BOARD" = bpi-r4-pro-4e ]; then
    apply_patches "$BUILD_DIR/patches/bpi-r4-pro/kernel" kernel-backport
    apply_patches "$BUILD_DIR/patches/bpi-r4-pro/kernel" kernel-pending
fi

# ── 3. Apply board-specific patches ──
apply_patches "$BUILD_DIR/patches/$BOARD/kernel"     kernel-backport
apply_patches "$BUILD_DIR/patches/$BOARD/kernel"     kernel-pending
apply_patches "$BUILD_DIR/patches/$BOARD/kernel"     kernel
apply_patches "$BUILD_DIR/patches/$BOARD/uboot"      uboot
apply_patches "$BUILD_DIR/patches/$BOARD/atf"        atf
apply_patches "$BUILD_DIR/patches/$BOARD/base-files" base-files

# No firmware is injected into the kernel image.
#
# There used to be a step here that copied patches/<board>/firmware/* into the
# kernel files overlay so CONFIG_EXTRA_FIRMWARE would link it into vmlinux. It
# existed for one blob on one board -- the AS21xxx PHY firmware on r4-pro -- and
# that blob may not be shipped that way: AEONSEMI grants redistribution "but not
# as part of the Linux kernel".
#
# The firmware now reaches the device as an ordinary rootfs file through the
# aeonsemi-as21xxx-firmware package. The AS21xxx module is loaded from rootfs;
# /etc/init.d/bpirouter-as21xxx-fw replaces any early generic PHY binding and
# only then loads the non-autoloaded MxL module (patches 463/469). Leaving a
# working injection path behind with a comment saying not to use it is weaker
# than not having one: the next person wanting a faster boot would find it and
# use it.
#
# Any previously injected blob is cleared, so a tree prepared before this change
# does not keep one.
rm -rf "$WORK_DIR/target/linux/mediatek/files-6.12/firmware"

# ── 3b. Re-apply changed kernel patches ──
# OpenWrt's incremental `make` will NOT re-apply changed target/linux patches
# once the kernel is unpacked (the .prepared stamp short-circuits re-patching),
# so an edited kernel patch silently builds the OLD source. If our injected
# kernel patches changed since the last prepare, clean target/linux here — the
# next build then re-unpacks + re-applies them. No change => keep the unpacked
# kernel (incremental build preserved). uboot/atf have their own prepare and
# are not covered here.
KHASH_FILE="$WORK_DIR/.bpirouter_kpatch.md5"
KHASH_NEW=$(cat "$KERNEL_BACKPORT_DIR"/*.patch \
    "$KERNEL_PENDING_DIR"/*.patch \
    "$KERNEL_PATCH_DIR"/*.patch \
    "$BUILD_DIR/patches/$BOARD/firmware/"* 2>/dev/null \
    | md5sum | awk '{print $1}' || true)
KHASH_OLD=$(cat "$KHASH_FILE" 2>/dev/null || true)
KDIR=$(ls -d "$WORK_DIR"/build_dir/target-*/linux-mediatek_filogic/linux-6.12.* 2>/dev/null | head -1 || true)
if [ -n "$KDIR" ] && [ "$KHASH_NEW" != "$KHASH_OLD" ]; then
    step "Kernel patches changed since last prepare — cleaning target/linux so they re-apply"
    make target/linux/clean >/dev/null 2>&1 || rm -rf "$KDIR"
    ok "target/linux cleaned (kernel re-unpacks + re-patches on next build)"
fi
echo "$KHASH_NEW" > "$KHASH_FILE"

# ── 4. Setup feeds ──
step "Configuring feeds..."
cp "$BUILD_DIR/feeds.conf" "$WORK_DIR/feeds.conf"
./scripts/feeds update -a
apply_patches "$BUILD_DIR/patches/common/packages" packages
./scripts/feeds install -a
ok "Feeds installed"

# ── 5. Apply .config ──
# common.config (shared across all boards) is merged ahead of the per-board
# seed; duplicate symbols are harmless and resolved by `make defconfig`.
CONFIG_FILE="$BUILD_DIR/config/$BOARD.config"
COMMON_CONFIG="$BUILD_DIR/config/common.config"
step "Applying build config ($CONFIG_FILE)..."
if [ -f "$CONFIG_FILE" ]; then
    cat "$COMMON_CONFIG" "$CONFIG_FILE" > "$WORK_DIR/.config" 2>/dev/null || cp "$CONFIG_FILE" "$WORK_DIR/.config"
    if [ "$UI_MODE" = none ]; then
        # Deselect rather than leave selected and hope the build skips it.
        # `make defconfig` resolves the last assignment, so appending is enough,
        # and the "is not set" form is what a later grep can assert on.
        sed -i '/^CONFIG_PACKAGE_bpirouter-ui=/d' "$WORK_DIR/.config"
        echo "# CONFIG_PACKAGE_bpirouter-ui is not set" >> "$WORK_DIR/.config"
        step "UI mode 'none': bpirouter-ui deselected from .config"
    fi
    make defconfig
    if [ "$UI_MODE" = artifact ]; then
        # AFTER `make defconfig`, not before. OpenWrt regards a .config without
        # CONFIG_HAVE_DOT_CONFIG as unconfigured and answers any make target by
        # launching menuconfig -- an ncurses UI that, with output redirected,
        # looks exactly like a build that never finishes. defconfig is what adds
        # that symbol, so anything invoking make has to come after it.
        # Staged here, not at build time: the package build reads files/, and
        # the tree must be complete when the marker below claims it is.
        LOCKF="$(find_lock)"
        [ -f "$LOCKF" ] || fail "--ui-artifact needs a release lock.
  Expected $LOCKF, or set BPIR_RELEASE_LOCK.
  The expected hash must come from a frozen lock; a hash supplied alongside the
  artifact proves nothing, since whoever replaces one replaces the other."
        # The same verification the publish path runs. A lock that no longer
        # describes this tree supplies hashes for a different release, and
        # accepting it here would give the customer build a weaker standard
        # than the one we hold ourselves to.
        # Scope follows what this checkout can actually show. A published tree
        # has no sibling repositories -- bpirouter-ui is proprietary and is not
        # in it at all -- so demanding the workspace scope there would make
        # artifact builds impossible rather than safe.
        LOCK_SCOPE=tree
        git -C "$BUILD_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
            && git -C "$(dirname "$BUILD_DIR")/bpirouter-ui" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
            && git -C "$(dirname "$BUILD_DIR")/bpirouter-feeds" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
            && LOCK_SCOPE=workspace
        if [ "$LOCK_SCOPE" = workspace ]; then
            bpir_require_release_workspace "$SCRIPT_DIR" "$BUILD_DIR" "$LOCKF" \
                || fail "the executing prepare checkout does not match the artifact release lock"
            RELEASE_BOUND=1
            BOUND_LOCK="$LOCKF"
        else
            "$SCRIPT_DIR/check-release-lock.sh" --scope tree "$LOCKF" \
                || fail "the release lock does not describe this published tree; artifact mode needs a matching lock"
            warn "artifact staged from a published tree; this build is reproducible but cannot produce formal release provenance"
        fi
        # Freeze the exact package bytes consumed by staging. The caller's path
        # may be replaced concurrently; hashing it again later could otherwise
        # bind the marker to different bytes than apk actually extracted.
        UI_ARTIFACT_SNAPSHOT=$(mktemp -t bpir-ui-artifact-XXXXXX.apk)
        trap 'rm -f "$UI_ARTIFACT_SNAPSHOT"' EXIT
        cp -f -- "$UI_ARTIFACT" "$UI_ARTIFACT_SNAPSHOT"
        "$SCRIPT_DIR/stage-proprietary-ui.sh" --artifact "$UI_ARTIFACT_SNAPSHOT" --lock "$LOCKF" \
            || fail "staging the UI artifact failed"
        UI_ARTIFACT_SHA=$(sha256sum "$UI_ARTIFACT_SNAPSHOT" | cut -d' ' -f1)
        rm -f "$UI_ARTIFACT_SNAPSHOT"
        trap - EXIT
        UI_FEED_FILES="$(feed_dir)/net/bpirouter-ui/files"
        UI_PAYLOAD_SHA=$("$SCRIPT_DIR/release-build-provenance.py" payload-id --feed-files "$UI_FEED_FILES")
        UI_APID_SHA=$(sha256sum "$UI_FEED_FILES/bpirouter-apid" | cut -d' ' -f1)
    fi

    ok "Config applied$([ -f "$COMMON_CONFIG" ] && echo " (+ common.config)")"
else
    fail "No config found for board '$BOARD'. Expected: $CONFIG_FILE"
fi

step "Removing dangerous Mediatek fw_setenv default script..."
rm -f "$WORK_DIR/target/linux/mediatek/base-files/etc/uci-defaults/99_fwenv-store-ethaddr.sh"

# ── 6. Stamp the prepare marker ──
# Last step on purpose: it is the assertion "everything above succeeded for
# THIS board", and build-full.sh trusts nothing else.
# board alone is not enough: a tree prepared for `artifact` and then built as
# `none` would reuse a .config that still selects the UI, and the mismatch would
# only show up in the finished image. The artifact hash is included so a tree
# prepared for one release's UI is not silently reused for another's.
TREE_SHA=""
PREPARE_INPUT_SHA=""
LOCK_METADATA=""
if [ "$RELEASE_BOUND" = 1 ]; then
    # Repeat at the END of prepare. A hook or feed operation that dirtied one of
    # the three repositories after the first check must not be blessed by the
    # marker. The prepared-tree digest separately binds the patched OpenWrt tree.
    bpir_require_release_workspace "$SCRIPT_DIR" "$BUILD_DIR" "$BOUND_LOCK" \
        || fail "release workspace or executing prepare checkout drifted while preparing"
    TREE_SHA=$("$SCRIPT_DIR/release-build-provenance.py" prepared-id --work-dir "$WORK_DIR")
    LOCK_METADATA=$("$SCRIPT_DIR/release-build-provenance.py" lock-metadata --lock "$BOUND_LOCK" --board "$BOARD")
elif [ "$DEVELOPMENT" = 1 ]; then
    TREE_SHA=$("$SCRIPT_DIR/release-build-provenance.py" prepared-id --work-dir "$WORK_DIR")
fi
PREPARE_INPUT_SHA=$("$SCRIPT_DIR/release-build-provenance.py" prepare-input-id \
    --build-dir "$BUILD_DIR" --board "$BOARD")

{
    echo "board=$BOARD"
    echo "ui_mode=$UI_MODE"
    [ "$UI_MODE" = artifact ] && echo "ui_artifact_sha256=$UI_ARTIFACT_SHA"
    [ "$UI_MODE" = artifact ] && echo "ui_payload_sha256=$UI_PAYLOAD_SHA"
    [ "$UI_MODE" = artifact ] && echo "ui_apid_sha256=$UI_APID_SHA"
    [ "$UI_MODE" = source ]   && echo "ui_source=$UI_SOURCE"
    echo "release_bound=$RELEASE_BOUND"
    echo "development_bound=$DEVELOPMENT"
    [ -z "$LOCKF" ] || echo "input_lock_path=$LOCKF"
    if [ "$RELEASE_BOUND" = 1 ]; then
        printf '%s\n' "$LOCK_METADATA" | while IFS= read -r line; do
            case "$line" in
                release=*) echo "release_id=${line#release=}" ;;
                *) echo "$line" ;;
            esac
        done
    fi
    [ -z "$TREE_SHA" ] || echo "prepared_tree_sha256=$TREE_SHA"
    echo "prepare_inputs_sha256=$PREPARE_INPUT_SHA"
    true
} > "$MARKER"

echo ""
ok "OpenWrt build environment ready! (board=$BOARD)"
echo "  Next steps:"
echo "    cd $WORK_DIR"
echo "    make menuconfig    # (optional) fine-tune configuration"
echo "    make download -j\$(nproc)"
echo "    make -j\$(nproc)"
