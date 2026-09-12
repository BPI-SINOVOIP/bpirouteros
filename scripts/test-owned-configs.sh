#!/bin/bash
# Build gate binding the backend's whole-file ownership registry to what the
# image actually ships.
#
# The backend refuses to serve any state it did not write for the configs in
# wholeFileOwnedConfigs. That refusal is only safe if, for EVERY entry:
#
#   1. a boot-time canonicalizer brings the config to product state,
#   2. a strict reader decides "is this ours" (never an upstream fingerprint),
#   3. both are installed into every board's rootfs,
#   4. no LuCI app ships as a second writer over the same file,
#   5. a per-config gate runs during the build.
#
# sqm satisfied none of these for an entire release cycle: every board shipped
# the upstream sqm-scripts example, QoS was down out of the box, and multi-WAN
# went down with it. This gate is what makes that class of omission a build
# failure rather than something found on hardware.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
BUILD_DIR=${BPIR_BUILD_DIR:-$(dirname "$SCRIPT_DIR")}
FEEDS_DIR=${BPIR_FEEDS_DIR:-$(dirname "$BUILD_DIR")/bpirouter-feeds}
UI_DIR=${BPIR_UI_DIR:-$(dirname "$BUILD_DIR")/bpirouter-ui}
REGISTRY="$UI_DIR/backend/internal/handler/owned_configs.go"
BASE_FILES="$FEEDS_DIR/net/bpirouter-base/files"
BASE_MAKEFILE="$FEEDS_DIR/net/bpirouter-base/Makefile"
BOARDS="bpi-r3-mini bpi-r3 bpi-r4-lite bpi-r4-pro bpi-r4 openwrt-one"

fail() { echo "FAIL: $*" >&2; exit 1; }
[ -f "$BASE_MAKEFILE" ] || fail "missing bpirouter-base Makefile: $BASE_MAKEFILE"

# An artifact-mode build has no UI source tree; the registry's own consistency
# was gated when that artifact was produced. Say so out loud rather than
# passing silently -- a skipped gate that reads like a passed one is how the
# sqm omission survived review in the first place.
if [ ! -d "$UI_DIR/backend" ]; then
	echo "SKIP: no UI source tree at $UI_DIR (artifact-mode build); whole-file ownership registry not cross-checked"
	exit 0
fi
[ -f "$REGISTRY" ] || fail "UI source tree is present but the ownership registry is missing: $REGISTRY"

# Read the map keys from the registry rather than hardcoding them here: a new
# entry must pull itself into this gate without anyone remembering to.
configs=$(sed -n '/^var wholeFileOwnedConfigs = map\[string\]string{/,/^}/p' "$REGISTRY" |
	sed -n 's/^[[:space:]]*"\([a-z0-9_]*\)":[[:space:]]*"[A-Za-z0-9_]*",$/\1/p')
[ -n "$configs" ] || fail "could not read any config names from $REGISTRY"

checked=0
for config in $configs; do
	canonicalizer=$(find "$BASE_FILES/etc/uci-defaults" -maxdepth 1 \
		-name "*-bpirouter-$config-canonical" -type f 2>/dev/null | head -1)
	[ -n "$canonicalizer" ] || \
		fail "'$config' is owned whole-file but ships no boot-time canonicalizer"
	[ -x "$canonicalizer" ] || fail "canonicalizer for '$config' is not executable"

	strict_awk="$BASE_FILES/usr/libexec/bpirouter-$config-strict.awk"
	[ -f "$strict_awk" ] || fail "'$config' ships no strict reader: $strict_awk"

	# The decision must be "is this ours". An upstream fingerprint turns one
	# upstream byte change into a first-boot failure on every board.
	if grep -q "^STOCK_SHA256=" "$canonicalizer"; then
		fail "canonicalizer for '$config' pins an upstream fingerprint"
	fi
	grep -Fq "bpirouter-$config-strict.awk" "$canonicalizer" || \
		fail "canonicalizer for '$config' does not consult its strict reader"

	base=$(basename "$canonicalizer")
	grep -Fq "$base \$(1)/etc/uci-defaults/" "$BASE_MAKEFILE" || \
		fail "bpirouter-base does not install $base"
	grep -Fq "bpirouter-$config-strict.awk \$(1)/usr/libexec/" "$BASE_MAKEFILE" || \
		fail "bpirouter-base does not install the strict reader for '$config'"

	gate="$SCRIPT_DIR/test-$config-canonical.sh"
	[ -x "$gate" ] || fail "'$config' has no executable takeover gate: $gate"
	for build in "$BUILD_DIR/scripts/build-full.sh" "$BUILD_DIR/scripts/build-image.sh"; do
		grep -Fq "test-$config-canonical.sh" "$build" || \
			fail "$(basename "$build") does not run the '$config' takeover gate"
	done

	for board in $BOARDS; do
		board_config="$BUILD_DIR/config/$board.config"
		[ -f "$board_config" ] || fail "missing board config: $board.config"
		if grep -Eq "^CONFIG_PACKAGE_luci-app-$config=y\$" "$board_config"; then
			fail "$board.config ships luci-app-$config, a second writer over a product-owned config"
		fi
	done
	checked=$((checked + 1))
done

[ "$checked" -ge 2 ] || fail "ownership registry parsed only $checked entries; expected mwan3 and sqm"
echo "PASS: $checked whole-file owned configs each have a canonicalizer, a strict reader, board installation, an exclusive-ownership board config, and a build gate"
