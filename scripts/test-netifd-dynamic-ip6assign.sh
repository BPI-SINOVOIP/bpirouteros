#!/bin/sh
set -eu

BUILD_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OPENWRT_DIR=${BPIR_OPENWRT_DIR:-$BUILD_DIR/openwrt}
OUTER_PATCH=$BUILD_DIR/patches/common/openwrt/003-netifd-refresh-dynamic-ip6assign.patch
INNER_PATH=package/network/config/netifd/patches/900-bpirouter-refresh-dynamic-ip6assign.patch
PREPARE=$BUILD_DIR/scripts/prepare.sh
OPENWRT_SOURCE_HELPER=$BUILD_DIR/scripts/lib/openwrt-source.sh

fail() {
	echo "netifd dynamic ip6assign gate: FAIL: $*" >&2
	exit 1
}

[ -f "$OUTER_PATCH" ] || fail "missing OpenWrt netifd patch"
[ -d "$OPENWRT_DIR/package/network/config/netifd" ] || fail "missing locked netifd package"
[ -f "$PREPARE" ] || fail "missing prepare.sh"
[ -f "$OPENWRT_SOURCE_HELPER" ] || fail "missing OpenWrt source helper"

numstat=$(git apply --numstat "$OUTER_PATCH")
printf '%s\n' "$numstat" | awk -v path="$INNER_PATH" '
	NF == 3 && $1 == 26 && $2 == 0 && $3 == path { ok=1 }
	END { exit !(NR == 1 && ok) }
' || fail "OpenWrt patch must add only the expected package-level patch"

scratch_dir=$(mktemp -d "${TMPDIR:-/tmp}/bpirouter-netifd-ip6assign.XXXXXX")
cleanup() {
	rm -r -- "$scratch_dir"
}
trap cleanup EXIT HUP INT TERM

# Recover the package-level patch from either a pristine or prepared OpenWrt
# tree. This checks that prepare.sh can install the patch at the package path
# consumed by OpenWrt's normal package patch phase.
mkdir -p "$scratch_dir/package/network/config/netifd"
if git -C "$OPENWRT_DIR" apply --reverse --check "$OUTER_PATCH" 2>/dev/null; then
	cp "$OPENWRT_DIR/$INNER_PATH" "$scratch_dir/netifd.patch"
elif git -C "$OPENWRT_DIR" apply --check "$OUTER_PATCH" 2>/dev/null; then
	git -C "$scratch_dir" apply "$OUTER_PATCH"
	cp "$scratch_dir/$INNER_PATH" "$scratch_dir/netifd.patch"
else
	fail "OpenWrt patch neither applies nor matches the prepared tree"
fi

patch_file=$scratch_dir/netifd.patch
[ -s "$patch_file" ] || fail "package-level netifd patch is empty"

check_contract() {
	file=$1
	[ "$(grep -c '^diff --git a/interface.c b/interface.c$' "$file")" -eq 1 ] || return 1
	[ "$(grep -c '^+.*interface_refresh_assignments(true);$' "$file")" -eq 2 ] || return 1
	grep -Fq '+		if (if_old->assignment_length >= 48 && if_old->assignment_length <= 64)' "$file" || return 1
	grep -Fq '+		if (if_new->assignment_length >= 48 && if_new->assignment_length <= 64)' "$file" || return 1
	! grep -Fq 'interface_refresh_assignments(false)' "$file" || return 1
}

check_contract "$patch_file" || fail "patch does not implement the create/remove deferred-refresh contract"

# Prove the gate catches either half of the regression instead of merely
# recognizing the patch filename.
awk '
	/if_old->assignment_length/ { drop=1 }
	drop && /interface_refresh_assignments\(true\)/ { drop=0; next }
	{ print }
' "$patch_file" >"$scratch_dir/no-remove.patch"
if check_contract "$scratch_dir/no-remove.patch"; then
	fail "anti-mutation failed after removing the delete refresh"
fi

awk '
	/if_new->assignment_length/ { drop=1 }
	drop && /interface_refresh_assignments\(true\)/ { drop=0; next }
	{ print }
' "$patch_file" >"$scratch_dir/no-create.patch"
if check_contract "$scratch_dir/no-create.patch"; then
	fail "anti-mutation failed after removing the create refresh"
fi

# If the source tarball has already been prepared, bind the patch to the exact
# locked netifd revision as well. Fresh build hosts may not have build_dir yet;
# OpenWrt's package prepare phase remains the authoritative application check.
set -- "$OPENWRT_DIR"/build_dir/target-*/netifd-*/interface.c
if [ -f "$1" ]; then
	source_dir=$(dirname "$1")
	if ! git -C "$source_dir" apply --check "$patch_file" 2>/dev/null &&
		! git -C "$source_dir" apply --reverse --check "$patch_file" 2>/dev/null; then
		fail "package patch does not apply to the locked netifd source"
	fi
fi

for gate in "$BUILD_DIR/scripts/build-full.sh" "$BUILD_DIR/scripts/build-image.sh"; do
	grep -Fq '"$SCRIPT_DIR/test-netifd-dynamic-ip6assign.sh"' "$gate" ||
		fail "$(basename "$gate") omits the netifd dynamic ip6assign gate"
done

clean_line=$(grep -nF 'bpir_reset_openwrt_source "$WORK_DIR"' "$PREPARE" | tail -1 | cut -d: -f1)
apply_line=$(grep -nF 'apply_patches "$BUILD_DIR/patches/common/openwrt"    openwrt' "$PREPARE" | cut -d: -f1)
[ -n "$clean_line" ] && [ -n "$apply_line" ] && [ "$clean_line" -lt "$apply_line" ] ||
	fail "prepare.sh does not remove the old injected patch before applying the current one"
awk -v path="$INNER_PATH" '
	/^bpir_reset_openwrt_source\(\)/ { in_reset=1; next }
	in_reset && index($0, path) { found=1 }
	in_reset && /^}/ { exit !found }
	END { if (in_reset) exit !found; exit 1 }
' "$OPENWRT_SOURCE_HELPER" ||
	fail "shared OpenWrt reset does not remove the old injected netifd patch"

echo "netifd dynamic ip6assign gate: PASS"
