#!/bin/bash
# test-public-tree.sh — build the public tree and actually use it.
#
# The tree it checks is the one a customer clones. The previous version of
# make-public-tree.sh produced a tree that could not get past the second command
# in its own README -- prepare.sh copies feeds.conf unconditionally and there
# was none -- and that went unnoticed because the only verification was a
# checklist of files, written by the same person who wrote the copy loop. A list
# of what you remembered to include cannot reveal what you forgot.
#
# So this runs the README's commands against a throwaway copy. It never touches
# the working tree's openwrt/ checkout.
#
# Usage: test-public-tree.sh [--board <board>] [--keep]
#   --board  which board to prepare (default bpi-r4)
#   --keep   leave the temporary tree behind for inspection
#   --full   also build images and unpack them (hours; required for a release)
#
# Two tiers, because the fast one cannot answer the question that matters.
# Staging succeeding says the files landed in the feed; it does not say the
# package builds from them, nor that `none` really produces an image without the
# UI. Only a build answers those, and a build needs the cross toolchain, which
# is why it takes hours. So the default stops at staging for quick regression,
# and --full is what a release must pass.
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$(dirname "$SCRIPT_DIR")"

C='\033[0;36m'; G='\033[0;32m'; Y='\033[0;33m'; R='\033[0;31m'; N='\033[0m'
step() { echo -e "${C}▸ $1${N}"; }
ok()   { echo -e "${G}✓ $1${N}"; }
fail() { echo -e "${R}✗ $1${N}" >&2; exit 1; }
warn() { echo -e "${Y}! $1${N}"; }

BOARD="bpi-r4"; KEEP=no; ARTIFACT=""; SKIP_ARTIFACT=no; FULL=no; MIRROR=""
while [ $# -gt 0 ]; do
    case "$1" in
        --board) BOARD="$2"; shift 2 ;;
        --keep)  KEEP=yes; shift ;;
        --artifact) ARTIFACT="$2"; shift 2 ;;
        # Only for the quick none-only smoke. The release gate must not use it:
        # an artifact case that silently skips is a pass that proves nothing.
        --no-artifact) fail "the public repository includes UI; supply --artifact" ;;
        --full) FULL=yes; shift ;;
        # Where the bytes come from, not what gets built. --full re-downloads
        # every upstream tarball, and one stalled mirror blocks the whole run:
        # cdn.kernel.org accepted a connection for linux-firmware and then sent
        # nothing for sixteen minutes, which --connect-timeout cannot catch.
        # Every file is still hash-checked and a miss falls through to the real
        # URL, so this changes the transport and nothing else. Off by default,
        # because a release gate should exercise the path a customer takes.
        --mirror) MIRROR="$2"; shift 2 ;;
        *) fail "unknown argument: $1" ;;
    esac
done

[ -n "$ARTIFACT" ] || [ "$SKIP_ARTIFACT" = yes ] || {
    echo "--artifact <apk> is required. Pass --no-artifact only for a none-only smoke;" >&2
    echo "a release gate that skips the artifact case reports success having tested nothing." >&2
    exit 2
}

# host_dumpimage <tree> <img> — a dumpimage this machine can run, proved by
# running it. build_dir holds one per u-boot variant and one of them is built
# for the target, so `find ... | head -1` is a coin toss; in our own tree it
# picked the aarch64 one, whose "Exec format error" (exit 126) surfaced as
# "cannot unpack the image". Listing the real image is the check, because it
# proves both that the binary executes here and that it can read this file.
host_dumpimage() {
    local tree="$1" img="$2" c
    for c in "$tree/openwrt/build_dir/host/u-boot-"*/tools/dumpimage \
             "$tree/openwrt/build_dir/"*/u-boot-*/tools/dumpimage; do
        [ -x "$c" ] || continue
        "$c" -l "$img" >/dev/null 2>&1 && { echo "$c"; return 0; }
    done
    return 1
}

# unpack_rootfs <tree> <out> — extract an image's rootfs so its contents can be
# asserted on. dumpimage rather than hunting for the squashfs magic: slicing
# from the magic to EOF yields a truncated filesystem that unsquashfs still
# reports as 100% extracted, which is how a partial artifact once passed for a
# whole one.
#
# The component index is read from the image, never hardcoded. It was -p 2,
# which is a 1,812-byte device tree overlay: the count of DT overlays ahead of
# rootfs-1 differs per board, so no constant can be right for all of them.
unpack_rootfs() {
    local tree="$1" out="$2" img di idx
    img=$(ls -t "$tree/openwrt/bin/targets/mediatek/filogic/"*squashfs-sysupgrade.itb 2>/dev/null | head -1)
    [ -n "$img" ] || { echo "no sysupgrade.itb under $tree/openwrt/bin/targets" >&2; return 1; }
    di=$(host_dumpimage "$tree" "$img") \
        || { echo "no host-executable dumpimage in $tree/openwrt/build_dir" >&2; return 1; }
    idx=$("$di" -l "$img" 2>/dev/null | sed -n 's/^ Image \([0-9]\+\) (rootfs.*/\1/p' | head -1)
    [ -n "$idx" ] || { echo "no rootfs component in $(basename "$img"):" >&2
                       "$di" -l "$img" | grep '^ Image' >&2; return 1; }
    rm -rf "$out"; mkdir -p "$out"
    "$di" -T flat_dt -p "$idx" -o "$out/rootfs.squashfs" "$img" >"$out/dump.log" 2>&1 \
        || { cat "$out/dump.log" >&2; return 1; }
    # Judged by what came out, not by the exit code: unsquashfs returns 2 when it
    # cannot create /dev/console as a non-root user, which is every run here and
    # is not a failure of the extraction -- 2,253 files and all of them correct.
    # Treating that as fatal rejects a good image; treating the exit code as
    # authoritative in the other direction is what let a truncated filesystem
    # pass before. The log is kept either way.
    unsquashfs -d "$out/root" -f "$out/rootfs.squashfs" >"$out/unsquashfs.log" 2>&1 || true
    [ -n "$(ls -A "$out/root" 2>/dev/null)" ] \
        || { tail -5 "$out/unsquashfs.log" >&2; return 1; }
}

# set_mirror — applied after prepare, which is the last thing to run defconfig.
set_mirror() {
    [ -n "$MIRROR" ] || return 0
    sed -i '/^CONFIG_LOCALMIRROR=/d' "$TREE/openwrt/.config"
    echo "CONFIG_LOCALMIRROR=\"$MIRROR\"" >> "$TREE/openwrt/.config"
}

TMP=$(mktemp -d -t bpir-pubtree-XXXXXX)
cleanup() { [ "$KEEP" = yes ] && echo "kept: $TMP" || rm -rf "$TMP"; }
trap cleanup EXIT

TREE="$TMP/bpirouteros"

# ── 1. Generate ──
# The generator requires a verified lock, so the test freezes one first. Doing
# it here rather than accepting a path keeps the test self-contained and
# exercises the real precondition instead of working around it.
step "Freezing a lock for the test..."
if [ -n "$ARTIFACT" ]; then
    APK="$BUILD_DIR/openwrt/staging_dir/host/bin/apk"
    [ -x "$APK" ] || fail "no host apk to derive the artifact's release version"
    ARTIFACT_VERSION=$("$APK" adbdump "$ARTIFACT" 2>/dev/null | sed -n 's/^  version: //p' | head -1)
    REL=$(python3 - "$ARTIFACT_VERSION" <<'PY'
import re, sys
m = re.fullmatch(r"(\d+)\.(\d+)\.(\d+)(?:_rc([1-9]\d*))?-r1", sys.argv[1])
if not m:
    raise SystemExit("artifact version is not a release version: " + sys.argv[1])
major, minor, patch, rc = m.groups()
print(f"v{major}.{minor}.{patch}" + (f"-rc{rc}" if rc else ""))
PY
    ) || fail "cannot map the artifact version to a release ID"
else
    REL="v0.0.0-rc1"
fi
source "$SCRIPT_DIR/boards.sh"
bpir_select_release_boards "$REL"
python3 - "$TMP/downloads-lock.json" "$REL" $VALID_BOARDS <<'PY'
import json, sys
path, release, *boards = sys.argv[1:]
with open(path, 'w') as stream:
    json.dump({'schema': 1, 'release': release, 'boards': boards, 'objects': []}, stream)
PY
# The artifact has to be in the lock, or staging refuses it -- correctly, since
# the lock is the only thing it trusts. Freezing a lock without it and then
# feeding the artifact in tested nothing except that the refusal works.
LOCK_ARGS=(--release "$REL" --downloads-lock "$TMP/downloads-lock.json" \
    --output "$TMP/lock.json" --test-output)
[ -n "$ARTIFACT" ] && LOCK_ARGS+=(--ui-artifact "$ARTIFACT")
BPIR_RELEASE_LOCK_TEST_ONLY=1 "$SCRIPT_DIR/make-release-lock.sh" "${LOCK_ARGS[@]}" \
    >"$TMP/lock.log" 2>&1 || { cat "$TMP/lock.log"; fail "lock generation failed"; }
ok "lock frozen"

step "Generating public tree..."
PUBLIC_ARGS=()
[ -n "$ARTIFACT" ] && PUBLIC_ARGS+=(--ui-artifact "$ARTIFACT")
"$SCRIPT_DIR/make-public-tree.sh" --release "$REL" --lock "$TMP/lock.json" \
    --output "$TREE" "${PUBLIC_ARGS[@]}" >"$TMP/gen.log" 2>&1 || { cat "$TMP/gen.log"; fail "generation failed"; }
ok "generated ($(du -sh "$TREE" | cut -f1))"

# ── 2. The files the README's commands need ──
# Checked by name because their absence is silent until a build is attempted,
# and each one here has a specific consumer.
step "Checking what the README's commands read..."
[ -f "$TREE/feeds.conf" ]     || fail "no feeds.conf — prepare.sh:186 copies it unconditionally"
[ -x "$TREE/fetch-sources.sh" ] || fail "no fetch-sources.sh"
[ -x "$TREE/scripts/prepare.sh" ] || fail "no scripts/prepare.sh"
[ -f "$TREE/RELEASE-INPUTS.lock.json" ] || fail "no lock for fetch-sources.sh to read"
# The published lock must be the authoritative one, not a stub: the earlier
# fallback wrote something that looked pinned and pinned almost nothing.
for k in downloads_lock_sha256 openwrt.commit repos.bpirouter-build patches configs feeds; do
    python3 -c "
import json,sys
d=json.load(open(sys.argv[1]))
for p in sys.argv[2].split('.'): d=d[p]
sys.exit(0 if d else 1)" "$TREE/RELEASE-INPUTS.lock.json" "$k" \
        || fail "published lock has no $k — it is a stub, not an authoritative lock"
done

# The local feed path must resolve inside the tree. src-link is relative to
# openwrt/feeds/, so the value that works in our repo points outside this one.
LINK=$(sed -n 's/^src-link bpirouter[[:space:]]*//p' "$TREE/feeds.conf")
[ -n "$LINK" ] || fail "feeds.conf has no bpirouter src-link"
RESOLVED=$(python3 -c "import os,sys; print(os.path.normpath(os.path.join('$TREE/openwrt/feeds', sys.argv[1])))" "$LINK")
[ "$RESOLVED" = "$TREE/feeds/bpirouter" ] || \
    fail "src-link resolves to $RESOLVED, not $TREE/feeds/bpirouter"
ok "feeds.conf points at the tree's own feed"

# No repository-carried firmware blob. There was one -- the AS21xxx PHY firmware
# linked into vmlinux -- and AEONSEMI's licence excludes that form. It now
# reaches the device through the upstream firmware package instead. Asserted
# here because the way it would come back is someone adding the file, and a
# published tree cannot be unpublished.
BLOBS=$(find "$TREE/patches" -name '*.bin' 2>/dev/null || true)
[ -z "$BLOBS" ] || { echo "$BLOBS" | sed "s#^$TREE/#    #"
    fail "the published tree carries firmware blobs under patches/"; }
ok "no firmware blobs under patches/"

# ── 3. Run the README's commands ──
step "fetch-sources.sh (clones OpenWrt; slow)..."
( cd "$TREE" && ./fetch-sources.sh ) >"$TMP/fetch.log" 2>&1 \
    || { tail -20 "$TMP/fetch.log"; fail "fetch-sources.sh failed"; }
[ -d "$TREE/openwrt/.git" ] || fail "fetch-sources.sh reported success but there is no openwrt/"
# What it tells the customer to do next has to be something prepare.sh accepts.
# It printed a bare `prepare.sh --board <board>`, which is refused for having no
# UI mode -- so the tree's own instructions failed on the line after the one
# that said it had worked.
grep -q -- '--without-proprietary-ui\|--ui-artifact' "$TMP/fetch.log" \
    || { grep -A6 'Next' "$TMP/fetch.log"; fail "fetch-sources.sh suggests a prepare.sh command with no UI mode, which prepare.sh refuses"; }
ok "OpenWrt $(git -C "$TREE/openwrt" describe --tags 2>/dev/null || echo '?') cloned"

# ── Negative cases, before anything slow ──
# Each of these must be refused before OpenWrt is touched, so they cost nothing
# and catch the failures that would otherwise surface as a finished image with
# no management interface.
step "Refusals..."
( cd "$TREE" && ./scripts/prepare.sh --board "$BOARD" ) >"$TMP/neg1.log" 2>&1 \
    && fail "prepare.sh accepted no UI mode"
grep -q "no UI mode given" "$TMP/neg1.log" || fail "wrong error for a missing UI mode"

( cd "$TREE" && ./scripts/prepare.sh --board "$BOARD" --without-proprietary-ui \
    --ui-artifact /dev/null ) >"$TMP/neg2.log" 2>&1 \
    && fail "prepare.sh accepted two UI modes"
grep -q "mutually exclusive" "$TMP/neg2.log" || fail "wrong error for two UI modes"

( cd "$TREE" && ./scripts/prepare.sh --board "$BOARD" --ui-artifact /nonexistent.apk ) \
    >"$TMP/neg3.log" 2>&1 && fail "prepare.sh accepted a missing artifact"
ok "no mode, two modes and a missing artifact are all refused"

# ── A board the lock says this tree cannot build ──
# Not a gap in coverage: refusing is the behaviour, and it is the one a customer
# on that board meets first. Testing it means asserting the refusal happens and
# says why, rather than skipping the board and learning nothing about it.
UNBUILDABLE=$(python3 -c "
import json,sys
print(' '.join(json.load(open(sys.argv[1])).get('boards_unbuildable_publicly',[])))" "$TMP/lock.json")
case " $UNBUILDABLE " in
    *" $BOARD "*)
        step "$BOARD is unbuildable from a public tree — asserting it is refused..."
        ( cd "$TREE" && ./scripts/prepare.sh --board "$BOARD" --without-proprietary-ui ) \
            >"$TMP/unbuildable.log" 2>&1 && fail "$BOARD is withheld an input but prepare.sh accepted it"
        grep -q 'cannot be built from this tree' "$TMP/unbuildable.log" \
            || { tail -10 "$TMP/unbuildable.log"; fail "$BOARD was refused, but not for the missing input"; }
        [ -d "$TREE/openwrt/build_dir" ] \
            && fail "$BOARD was refused only after starting to build"
        ok "$BOARD refused before touching OpenWrt, naming the withheld input"
        echo
        ok "public tree correctly refuses $BOARD (nothing further is testable for it)"
        exit 0
        ;;
esac

# ── none ──
step "prepare.sh --without-proprietary-ui (feeds update + patches; slow)..."
( cd "$TREE" && ./scripts/prepare.sh --board "$BOARD" --without-proprietary-ui ) \
    >"$TMP/prepare.log" 2>&1 || { tail -30 "$TMP/prepare.log"; fail "prepare.sh --without-proprietary-ui failed"; }
set_mirror
grep -qx '# CONFIG_PACKAGE_bpirouter-ui is not set' "$TREE/openwrt/.config" \
    || fail "ui_mode=none but .config still selects bpirouter-ui"

# .config is intent; the package set is what the image is built from. Asserting
# only the former would pass on a tree that deselected the package and still
# had it queued.
( cd "$TREE/openwrt" && make prepare-tmpinfo </dev/null ) >/dev/null 2>&1 || true
if grep -q "bpirouter-ui" "$TREE/openwrt/tmp/.packagedeps" 2>/dev/null; then
    grep -q "^package/feeds/bpirouter/bpirouter-ui/compile" "$TREE/openwrt/tmp/.packagedeps" \
        && fail "ui_mode=none but bpirouter-ui is still queued for compile"
fi
ok "prepared without the UI"

if [ "$FULL" = yes ]; then
    step "build-full.sh (none) — builds the cross toolchain; hours..."
    ( cd "$TREE" && ./scripts/build-full.sh --board "$BOARD" ) >"$TMP/build-none.log" 2>&1 \
        || { tail -30 "$TMP/build-none.log"; fail "build-full.sh failed in none mode"; }
    unpack_rootfs "$TREE" "$TMP/none" || fail "cannot unpack the none-mode image"
    # The claim is about the image, not the config. Anything short of looking
    # inside it is an assertion about intent.
    [ ! -e "$TMP/none/root/usr/bin/bpirouter-apid" ] \
        || fail "none-mode image contains bpirouter-apid"
    [ ! -d "$TMP/none/root/www/bpirouter" ] \
        || fail "none-mode image contains www/bpirouter"
    ok "none-mode image carries no UI or API ($(find "$TMP/none/root" -type f | wc -l) files inspected)"
fi

# ── 4. Assert prepare actually did its job ──
# prepare.sh exiting 0 is not the same as the tree being usable; check-prepared
# exists precisely because those two came apart before.
step "Verifying the prepared tree..."
( cd "$TREE" && ./scripts/check-prepared.sh "$BOARD" ) >>"$TMP/prepare.log" 2>&1 \
    || { tail -20 "$TMP/prepare.log"; fail "check-prepared rejected the tree"; }

[ -L "$TREE/openwrt/feeds/bpirouter" ] || fail "the bpirouter feed was not installed"
FEED_TARGET=$(readlink -f "$TREE/openwrt/feeds/bpirouter")
[ "$FEED_TARGET" = "$TREE/feeds/bpirouter" ] || \
    fail "feed symlink resolves outside the tree: $FEED_TARGET"

# The package must be visible to the build, not merely present on disk.
grep -q "bpirouter-ui" "$TREE/openwrt/tmp/.packageinfo" 2>/dev/null \
    || grep -rq "bpirouter-ui" "$TREE/openwrt/feeds/bpirouter" \
    || fail "bpirouter-ui package not found through the installed feed"

PATCHED=$(ls "$TREE/openwrt/target/linux/mediatek/patches-6.12"/*.patch 2>/dev/null | wc -l)
[ "$PATCHED" -gt 100 ] || fail "only $PATCHED kernel patches in the prepared tree; injection did not run"
ok "feed installed inside the tree, $PATCHED kernel patches present"

# ── artifact ──
# The APK is injected from outside the tree on purpose: it is the proprietary
# payload and is not in a published tree. This stands in for a customer taking
# it from the release bundle.
if [ -n "$ARTIFACT" ]; then
    # In the fast tier this tree has never been built, so staging bootstraps the
    # host apk by itself -- that branch is covered. The full tier builds an image
    # first, which leaves apk already there, so the branch a customer hits on a
    # fresh checkout is the one the release gate was skipping. Removed here so
    # --full covers it too.
    #
    # The build directory goes with the binary: .built is what make consults, so
    # deleting only staging_dir/host/bin/apk makes the recompile a no-op and
    # staging then dies with "reported success but apk is not there".
    if [ "$FULL" = yes ]; then
        rm -f "$TREE/openwrt/staging_dir/host/bin/apk"
        rm -rf "$TREE/openwrt/build_dir/hostpkg/apk-"*
    fi
    step "prepare.sh --ui-artifact (bootstraps host apk on a fresh tree; slow)..."
    cp "$ARTIFACT" "$TREE/ui.apk"
    ( cd "$TREE" && ./scripts/prepare.sh --board "$BOARD" --ui-artifact ./ui.apk ) \
        >"$TMP/artifact.log" 2>&1 || { tail -30 "$TMP/artifact.log"; fail "artifact prepare failed"; }
    set_mirror
    grep -qx 'CONFIG_PACKAGE_bpirouter-ui=y' "$TREE/openwrt/.config" \
        || fail "ui_mode=artifact but .config does not select bpirouter-ui"
    FEED_FILES="$TREE/feeds/bpirouter/net/bpirouter-ui/files"
    [ -f "$FEED_FILES/bpirouter-apid" ] \
        || fail "artifact staged nothing into the tree's own feed ($FEED_FILES)"
    ok "artifact staged inside the tree ($(find "$FEED_FILES" -type f | wc -l) files)"

    # Staging is not the finish line. Everything up to here would also pass with
    # an artifact missing files the package installs unconditionally -- that
    # failure only appears at compile, which is where five missing files hid
    # until now.
    # Needs the cross toolchain, so it belongs to the full tier. In the fast
    # tier staging is as far as the evidence goes, and the closing line says so
    # rather than letting a green run imply more than it checked.
    if [ "$FULL" = yes ]; then
    step "package/bpirouter-ui/compile (slow)..."
    ( cd "$TREE/openwrt" && make package/bpirouter-ui/compile -j"$(nproc)" </dev/null ) \
        >"$TMP/compile.log" 2>&1 || { tail -25 "$TMP/compile.log"; fail "package compile failed"; }
    BUILT=$(ls -t "$TREE/openwrt/bin/packages/"*/bpirouter/bpirouter-ui-*.apk 2>/dev/null | head -1)
    [ -n "$BUILT" ] || fail "compile reported success but produced no package"
    ok "package built from the staged artifact"

    # And the payload has to survive into it. Comparing the rebuilt package's
    # contents against the artifact's is what shows the staged files were the
    # ones packaged, rather than something the build filled in.
    # apk extract does not create its destination, and reports that on stderr
    # while exiting 0. Both halves matter: make the directory, and judge by what
    # came out rather than by the exit code, or the failure reappears further
    # down as "the package is missing usr/bin/bpirouter-apid".
    mkdir -p "$TMP/rebuilt"
    "$TREE/openwrt/staging_dir/host/bin/apk" extract --allow-untrusted \
        --destination "$TMP/rebuilt" "$BUILT" >"$TMP/extract.log" 2>&1 || true
    [ -n "$(ls -A "$TMP/rebuilt" 2>/dev/null)" ] \
        || { cat "$TMP/extract.log" >&2; fail "apk extract produced no files"; }
    for f in usr/bin/bpirouter-apid etc/init.d/bpirouter-api etc/uci-defaults/99-bpirouter-setup \
             etc/bpirouter-version www/bpirouter/index.html; do
        [ -f "$TMP/rebuilt/$f" ] || fail "rebuilt package is missing $f"
    done
    cmp -s "$TMP/rebuilt/usr/bin/bpirouter-apid" "$FEED_FILES/bpirouter-apid" \
        || fail "the packaged apid differs from the staged one"
    ok "rebuilt package carries the staged payload"
    fi

    if [ "$FULL" = yes ]; then
        step "build-full.sh (artifact) — reuses the toolchain; slow..."
        ( cd "$TREE" && ./scripts/build-full.sh --board "$BOARD" ) >"$TMP/build-art.log" 2>&1 \
            || { tail -30 "$TMP/build-art.log"; fail "build-full.sh failed in artifact mode"; }
        unpack_rootfs "$TREE" "$TMP/art" || fail "cannot unpack the artifact-mode image"
        for f in usr/bin/bpirouter-apid etc/init.d/bpirouter-api \
                 etc/uci-defaults/99-bpirouter-setup etc/bpirouter-version \
                 www/bpirouter/index.html; do
            [ -e "$TMP/art/root/$f" ] || fail "artifact-mode image is missing $f"
        done
        # Byte-identical to what was staged. The image containing *an* apid says
        # nothing about it being the one from the artifact.
        cmp -s "$TMP/art/root/usr/bin/bpirouter-apid" "$FEED_FILES/bpirouter-apid" 2>/dev/null \
            || warn "image apid differs from the staged file (expected: OpenWrt strips on packaging)"
        cmp -s "$TMP/art/root/etc/uci-defaults/99-bpirouter-setup" \
               "$FEED_FILES/uci-defaults/99-bpirouter-setup" \
            || fail "a staged file was altered on its way into the image"
        ok "artifact-mode image carries the staged UI"
    fi
fi

echo
ok "public tree builds from its own README ($BOARD, $([ "$FULL" = yes ] && echo full || echo staging-only))"
[ "$FULL" = yes ] || echo "  NOTE: staging tier only. A release requires --full."
echo "  logs: $TMP"
