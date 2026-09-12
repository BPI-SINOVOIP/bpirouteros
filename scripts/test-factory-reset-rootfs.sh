#!/bin/bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
BUILD_DIR=${BPIR_BUILD_DIR:-$(dirname "$SCRIPT_DIR")}
FEEDS_DIR=${BPIR_FEEDS_DIR:-$(dirname "$BUILD_DIR")/bpirouter-feeds}
SOURCE="$FEEDS_DIR/net/bpirouter-base/files"
PATCH="$BUILD_DIR/patches/common/base-files/z13-bpirouter-factory-reset-button.patch"
TMP=$(mktemp -d -t bpir-fr1-rootfs-XXXXXX)
trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: FR-1 source/rootfs: $*" >&2; exit 1; }
must_refuse() {
	if "$@" >"$TMP/refused.log" 2>&1; then
		fail "mutation was accepted: $*"
	fi
}

[ -f "$SOURCE/usr/libexec/bpirouter-factory-reset-button" ] || fail "missing feed reset helper"
sh -n "$SOURCE/usr/libexec/bpirouter-factory-reset-button" || fail "reset helper shell syntax"
[ -f "$PATCH" ] || fail "missing base-files reset button patch"
grep -Fq '/usr/libexec/bpirouter-factory-reset-button' "$PATCH" || fail "button patch omits shared helper"
grep -Fq 'files/usr/libexec/bpirouter-factory-reset-button' "$FEEDS_DIR/net/bpirouter-base/Makefile" ||
	fail "package recipe omits reset button helper"
if grep -Fq 'files/etc/rc.button/reset' "$FEEDS_DIR/net/bpirouter-base/Makefile"; then
	fail "bpirouter-base must not collide with base-files ownership of rc.button/reset"
fi

PATCH_TREE="$TMP/patch-tree"
mkdir -p "$PATCH_TREE/package/base-files/files/etc/rc.button"
cp "$BUILD_DIR/openwrt/package/base-files/files/etc/rc.button/reset" \
	"$PATCH_TREE/package/base-files/files/etc/rc.button/reset"
git -C "$PATCH_TREE" init -q
git -C "$PATCH_TREE" add package/base-files/files/etc/rc.button/reset
git -C "$PATCH_TREE" -c user.name=fr1-test -c user.email=fr1@example.invalid commit -qm baseline
if git -C "$PATCH_TREE" apply --check "$PATCH" 2>/dev/null; then
	git -C "$PATCH_TREE" apply "$PATCH"
elif ! git -C "$PATCH_TREE" apply --reverse --check "$PATCH" 2>/dev/null; then
	fail "base-files button patch is neither applicable nor already applied"
fi
PATCHED_BUTTON="$PATCH_TREE/package/base-files/files/etc/rc.button/reset"
sh -n "$PATCHED_BUTTON" || fail "patched reset button shell syntax"

make_root() {
	local root=$1
	mkdir -p "$root/etc/rc.button" "$root/usr/libexec" "$root/usr/bin"
	cp "$PATCHED_BUTTON" "$root/etc/rc.button/reset"
	cp "$SOURCE/usr/libexec/bpirouter-factory-reset-button" "$root/usr/libexec/bpirouter-factory-reset-button"
	printf '#!/bin/sh\n# physical factory reset accepted; supervised reboot handoff pending\nexit 0\n' >"$root/usr/bin/bpirouter-apid"
	chmod 755 "$root/etc/rc.button/reset" "$root/usr/libexec/bpirouter-factory-reset-button" "$root/usr/bin/bpirouter-apid"
}

ROOT="$TMP/root"
make_root "$ROOT"
"$SCRIPT_DIR/check-factory-reset-rootfs.sh" "$ROOT" >/dev/null

rm "$ROOT/etc/rc.button/reset"
must_refuse "$SCRIPT_DIR/check-factory-reset-rootfs.sh" "$ROOT"
make_root "$ROOT"
sed -i 's|/usr/libexec/bpirouter-factory-reset-button|factoryreset -y|' "$ROOT/etc/rc.button/reset"
must_refuse "$SCRIPT_DIR/check-factory-reset-rootfs.sh" "$ROOT"
make_root "$ROOT"
sed -i 's/"$SEEN" -ge 5/"$SEEN" -ge 1/' "$ROOT/etc/rc.button/reset"
must_refuse "$SCRIPT_DIR/check-factory-reset-rootfs.sh" "$ROOT"
make_root "$ROOT"
sed -i 's/"$SEEN" -ge 5/"$SEEN" -eq 5/' "$ROOT/etc/rc.button/reset"
must_refuse "$SCRIPT_DIR/check-factory-reset-rootfs.sh" "$ROOT"
make_root "$ROOT"
sed -i 's/ -a -n "$OVERLAY"//' "$ROOT/etc/rc.button/reset"
must_refuse "$SCRIPT_DIR/check-factory-reset-rootfs.sh" "$ROOT"
make_root "$ROOT"
sed -i '0,/reboot/s//\/usr\/libexec\/bpirouter-factory-reset-button/' "$ROOT/etc/rc.button/reset"
must_refuse "$SCRIPT_DIR/check-factory-reset-rootfs.sh" "$ROOT"
make_root "$ROOT"
sed -i '/readlink/d' "$ROOT/usr/libexec/bpirouter-factory-reset-button"
must_refuse "$SCRIPT_DIR/check-factory-reset-rootfs.sh" "$ROOT"
make_root "$ROOT"
sed -i 's/kill -USR1/kill -TERM/' "$ROOT/usr/libexec/bpirouter-factory-reset-button"
must_refuse "$SCRIPT_DIR/check-factory-reset-rootfs.sh" "$ROOT"
make_root "$ROOT"
sed -i '/physical factory reset accepted/d' "$ROOT/usr/bin/bpirouter-apid"
must_refuse "$SCRIPT_DIR/check-factory-reset-rootfs.sh" "$ROOT"

for gate in "$BUILD_DIR/scripts/build-image.sh" "$BUILD_DIR/scripts/build-full.sh"; do
	grep -Fq 'test-factory-reset-rootfs.sh' "$gate" || fail "$(basename "$gate") omits FR-1 source gate"
	grep -Fq 'check-factory-reset-rootfs.sh' "$gate" || fail "$(basename "$gate") omits FR-1 assembled-root gate"
done

echo "PASS: FR-1 physical reset payload and assembled-root anti-mutations"
