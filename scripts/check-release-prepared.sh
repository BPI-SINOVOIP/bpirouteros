#!/bin/bash
# Verify that a prepared OpenWrt tree still represents one explicit release lock.
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="${BPIR_BUILD_DIR:-$(dirname "$SCRIPT_DIR")}"
WORK_DIR="${BPIR_WORK_DIR:-$BUILD_DIR/openwrt}"
MARKER="$WORK_DIR/.bpirouter-prepared-board"

die() { echo "release-prepared check failed: $1" >&2; exit 1; }
mval() { sed -n "s/^$1=//p" "$MARKER" | head -1; }

BOARD=""; LOCK=""
while [ $# -gt 0 ]; do
    case "$1" in
        --board) BOARD="$2"; shift 2 ;;
        --lock) LOCK="$2"; shift 2 ;;
        *) die "unknown argument: $1" ;;
    esac
done
[ -n "$BOARD" ] && [ -n "$LOCK" ] || die "usage: check-release-prepared.sh --board <board> --lock <file>"
[ -f "$LOCK" ] || die "no such input lock: $LOCK"
[ -f "$MARKER" ] || die "no prepared marker at $MARKER"

[ "$(mval release_bound)" = "1" ] || die "tree was prepared without a release lock"
LOCK_SHA=$(sha256sum "$LOCK" | cut -d' ' -f1)
[ "$(mval input_lock_sha256)" = "$LOCK_SHA" ] || die "prepared marker belongs to another input lock"

# The three workspace repositories must still be exactly at the commits frozen
# before prepare. This check also rejects dirty trees. It intentionally runs at
# both prepare and build boundaries; recording a commit once is not a guard.
LOCK_SCOPE=tree
git -C "$BUILD_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    && git -C "${BPIR_UI_DIR:-$(dirname "$BUILD_DIR")/bpirouter-ui}" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    && git -C "${BPIR_FEEDS_DIR:-$(dirname "$BUILD_DIR")/bpirouter-feeds}" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    && LOCK_SCOPE=workspace
"$SCRIPT_DIR/check-release-lock.sh" --scope "$LOCK_SCOPE" "$LOCK" >/dev/null \
    || die "workspace no longer matches the release lock"

declare -A EXPECTED=()
while IFS='=' read -r key value; do
    EXPECTED["$key"]="$value"
done < <("$SCRIPT_DIR/release-build-provenance.py" lock-metadata --lock "$LOCK" --board "$BOARD")

for key in release input_lock_sha256 openwrt_commit build_commit ui_commit feeds_commit \
           common_config_sha256 board_config_sha256 patch_set_sha256; do
    marker_key="$key"
    [ "$key" = release ] && marker_key=release_id
    [ "$(mval "$marker_key")" = "${EXPECTED[$key]}" ] \
        || die "prepared marker $marker_key does not match the release lock"
done

# Source mode may name an alternate checkout, so checking only the conventional
# sibling bpirouter-ui repository is insufficient. Bind the exact path recorded
# by prepare to the locked commit again immediately before build.
if [ "$(mval ui_mode)" = source ]; then
    UI_SOURCE=$(mval ui_source)
    UI_SOURCE_HEAD=$(git -C "$UI_SOURCE" rev-parse HEAD 2>/dev/null || true)
    [ -n "$UI_SOURCE" ] && [ -n "$UI_SOURCE_HEAD" ] \
        || die "source-mode marker has no git-backed ui_source"
    [ "$UI_SOURCE_HEAD" = "$(mval ui_commit)" ] \
        || die "ui_source no longer matches the release lock"
    [ -z "$(git -C "$UI_SOURCE" status --porcelain 2>/dev/null)" ] \
        || die "ui_source has uncommitted changes"
fi

WANT_TREE=$(mval prepared_tree_sha256)
[ -n "$WANT_TREE" ] || die "prepared marker has no prepared_tree_sha256"
GOT_TREE=$("$SCRIPT_DIR/release-build-provenance.py" prepared-id --work-dir "$WORK_DIR")
[ "$GOT_TREE" = "$WANT_TREE" ] || die "prepared OpenWrt tree changed after prepare"

echo "release-prepared check passed: $BOARD lock ${LOCK_SHA:0:12}"
