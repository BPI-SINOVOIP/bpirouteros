#!/bin/sh
set -eu
ulimit -c 0

BUILD_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OPENWRT_DIR=${BPIR_OPENWRT_DIR:-$BUILD_DIR/openwrt}
set -- "$OPENWRT_DIR"/build_dir/target-*/netifd-*/interface-ip.c
[ -f "$1" ] || { echo "netifd host-route test requires prepared source" >&2; exit 1; }
source_dir=$(dirname "$1")
scratch_dir=$(mktemp -d "${TMPDIR:-/tmp}/bpirouter-host-route-test.XXXXXXXX")
trap 'rm -r -- "$scratch_dir"' EXIT HUP INT TERM
mkdir "$scratch_dir/source"
for file in interface-ip.c interface-ip.h interface.c proto-shell.c ubus.c; do
	cp "$source_dir/$file" "$scratch_dir/source/"
done
git -C "$scratch_dir" apply --whitespace=nowarn "$BUILD_DIR/patches/common/openwrt/006-netifd-host-route-lifetime.patch"
package_patch=$scratch_dir/package/network/config/netifd/patches/903-bpirouter-host-route-lifetime.patch

# Exercise prepare's real cleanup only in a fresh disposable repository. A
# changed, untracked package patch must not block the next forward application;
# adjacent non-product files and incremental build state must survive.
reprepare=$scratch_dir/reprepare
inner_path=package/network/config/netifd/patches/903-bpirouter-host-route-lifetime.patch
source_helper=$BUILD_DIR/scripts/lib/openwrt-source.sh
git init -q "$reprepare"
git -C "$reprepare" -c user.name=netifd-test -c user.email=netifd-test@example.invalid \
	-c commit.gpgsign=false -c core.hooksPath=/dev/null commit --allow-empty -qm baseline
mkdir -p "$reprepare/package/network/config/netifd/patches" "$reprepare/build_dir"
cp "$package_patch" "$scratch_dir/old-package.patch"
printf '\n# Previous development revision\n' >>"$scratch_dir/old-package.patch"
cp "$scratch_dir/old-package.patch" "$reprepare/$inner_path"
for file in .config build_dir/cache package/network/config/netifd/patches/local.patch; do
	printf 'preserve %s\n' "$file" >"$reprepare/$file"
done
bash -c '. "$1"; bpir_reset_openwrt_source "$2"' _ "$source_helper" "$reprepare"
[ ! -e "$reprepare/$inner_path" ] || {
	echo "prepare cleanup retained the previous netifd host-route patch" >&2; exit 1;
}
for file in .config build_dir/cache package/network/config/netifd/patches/local.patch; do
	[ "$(cat "$reprepare/$file")" = "preserve $file" ] || {
		echo "prepare cleanup changed unrelated fixture state: $file" >&2; exit 1;
	}
done
git -C "$reprepare" apply --whitespace=nowarn "$BUILD_DIR/patches/common/openwrt/006-netifd-host-route-lifetime.patch"
cmp "$package_patch" "$reprepare/$inner_path"

# The former cleanup list must leave the old file and reject reapplication.
sed '\|package/network/config/netifd/patches/903-bpirouter-host-route-lifetime.patch|d' \
	"$source_helper" >"$scratch_dir/old-source-helper.sh"
cp "$scratch_dir/old-package.patch" "$reprepare/$inner_path"
bash -c '. "$1"; bpir_reset_openwrt_source "$2"' _ "$scratch_dir/old-source-helper.sh" "$reprepare"
cmp "$scratch_dir/old-package.patch" "$reprepare/$inner_path"
if git -C "$reprepare" apply --check "$BUILD_DIR/patches/common/openwrt/006-netifd-host-route-lifetime.patch" 2>/dev/null ||
	git -C "$reprepare" apply --reverse --check "$BUILD_DIR/patches/common/openwrt/006-netifd-host-route-lifetime.patch" 2>/dev/null; then
	echo "reprepare negative control accepted the retained old patch" >&2; exit 1
fi
echo "netifd reprepare cleanup and negative control: PASS"

if git -C "$scratch_dir/source" apply --check "$package_patch" 2>/dev/null; then
	patch -s -f -p1 -d "$scratch_dir/source" -i "$package_patch"
else
	git -C "$scratch_dir/source" apply --reverse --check "$package_patch"
fi

# Compile the installed patch's functions, not a duplicate implementation.
extract() {
	awk -v fn="$2" -v type="$3" '
		$0 ~ "^" fn "\\(" { pending=1; declaration="static " type "\n" }
		pending {
			declaration=declaration $0 "\n"
			if (/;$/) { pending=0; next }
			if (/^{$/) { printf "%s", declaration; pending=0; copy=1 }
			next
		}
		copy { print } copy && /^}$/ { exit }
	' "$1"
}
awk '/^enum device_addr_flags \{/ || /^union if_addr \{/ || /^struct device_route \{/ {copy=1}
     copy {print} copy && /^};/ {copy=0}' "$scratch_dir/source/interface-ip.h" >"$scratch_dir/route-types.inc"
awk '/^struct proto_shell_dependency \{/ {copy=1}
     copy {print} copy && /^};/ {exit}' "$scratch_dir/source/proto-shell.c" >"$scratch_dir/dependency-type.inc"
{
	extract "$scratch_dir/source/interface-ip.c" route_cmp int
	extract "$scratch_dir/source/interface-ip.c" clear_if_addr void
	extract "$scratch_dir/source/interface-ip.c" match_if_addr bool
	extract "$scratch_dir/source/interface-ip.c" __find_ip_route_target void
	extract "$scratch_dir/source/interface-ip.c" interface_ip_find_route_target void
	extract "$scratch_dir/source/interface-ip.c" enable_route bool
	extract "$scratch_dir/source/interface-ip.c" __interface_update_route void
	extract "$scratch_dir/source/interface-ip.c" interface_update_proto_route void
	extract "$scratch_dir/source/interface-ip.c" interface_ip_add_target_route 'struct interface *'
	extract "$scratch_dir/source/interface-ip.c" interface_ip_remove_target_route void
	extract "$scratch_dir/source/interface-ip.c" interface_update_host_route void
} >"$scratch_dir/route-functions.inc"
{
	extract "$scratch_dir/source/proto-shell.c" proto_shell_busy bool
	extract "$scratch_dir/source/proto-shell.c" proto_shell_check_dependencies void
	extract "$scratch_dir/source/proto-shell.c" proto_shell_update_host_dep void
	extract "$scratch_dir/source/proto-shell.c" proto_shell_release_host_dep void
	extract "$scratch_dir/source/proto-shell.c" proto_shell_clear_host_dep void
	extract "$scratch_dir/source/proto-shell.c" proto_shell_if_up_cb void
	extract "$scratch_dir/source/proto-shell.c" proto_shell_if_down_cb void
	extract "$scratch_dir/source/proto-shell.c" proto_shell_handler int
} >"$scratch_dir/dependency-functions.inc"
{
	extract "$scratch_dir/source/interface.c" interface_remove_user void
	extract "$scratch_dir/source/interface.c" interface_add_user void
	extract "$scratch_dir/source/interface.c" __interface_set_down void
	extract "$scratch_dir/source/interface.c" interface_set_down void
} >"$scratch_dir/interface-functions.inc"
extract "$scratch_dir/source/proto-shell.c" proto_shell_task_finish void >"$scratch_dir/task-finish.inc"
host=$OPENWRT_DIR/staging_dir/host
compile() {
	"${HOSTCC:-cc}" -std=gnu11 -Wall -Wextra -Werror -Wno-unused-parameter -Wno-unused-function \
		-I"$scratch_dir" -I"$host/include" "$BUILD_DIR/scripts/tests/netifd-host-route.c" \
		"$host/lib/libubox.a" -o "$scratch_dir/check"
}
compile
"$scratch_dir/check"
for file in route-functions dependency-functions interface-functions; do
	cp "$scratch_dir/$file.inc" "$scratch_dir/$file.fixed"
done

# Reintroduce the actual former teardown callback: a disconnected interface
# keeps its dependency and endpoint route. The same executable test must fail.
cp "$scratch_dir/task-finish.inc" "$scratch_dir/task-finish.fixed"
sed '/if (!state->proto.iface->autostart)/,+1d' "$scratch_dir/task-finish.fixed" >"$scratch_dir/task-finish.inc"
compile
if "$scratch_dir/check" >"$scratch_dir/negative.log" 2>&1; then
	echo "host-route regression test accepted former teardown" >&2
	exit 1
fi
cp "$scratch_dir/task-finish.fixed" "$scratch_dir/task-finish.inc"
# Removing the shared-owner check must also fail, rather than accepting a
# repair that drops another tunnel's endpoint route.
sed '/list_for_each_entry(user, &iface->users, list)/,/^\t}/d' "$scratch_dir/dependency-functions.inc" \
	| sed '/struct interface_user \*user;/d; /struct proto_shell_dependency \*other;/d' >"$scratch_dir/no-sharing.inc"
cp "$scratch_dir/no-sharing.inc" "$scratch_dir/dependency-functions.inc"
compile
if "$scratch_dir/check" >"$scratch_dir/no-sharing.log" 2>&1; then
	echo "host-route regression test accepted deletion of shared route" >&2
	exit 1
fi
cp "$scratch_dir/dependency-functions.fixed" "$scratch_dir/dependency-functions.inc"

# Each fix must have an executable counterexample; all mutations are confined
# to generated scratch includes, never the repository or prepared source.
sed '/route->failed = !!system_add_route(iface->l3_dev.dev, route);/d' \
	"$scratch_dir/route-functions.fixed" >"$scratch_dir/route-functions.inc"
compile
if "$scratch_dir/check" >"$scratch_dir/no-restore.log" 2>&1; then
	echo "host-route regression test accepted deletion of a configured route" >&2
	exit 1
fi
sed 's/ || r_next->mask == (v6 ? 128 : 32)//' \
	"$scratch_dir/route-functions.fixed" >"$scratch_dir/route-functions.inc"
compile
if "$scratch_dir/check" >"$scratch_dir/clone-static.log" 2>&1; then
	echo "host-route regression test accepted cloning a configured host route" >&2
	exit 1
fi
cp "$scratch_dir/route-functions.fixed" "$scratch_dir/route-functions.inc"

sed '/if (iface->state == IFS_DOWN)/,+1d' \
	"$scratch_dir/interface-functions.fixed" >"$scratch_dir/interface-functions.inc"
compile
if "$scratch_dir/check" >"$scratch_dir/no-down-stop.log" 2>&1; then
	echo "host-route regression test accepted dependencies after stopping a DOWN interface" >&2
	exit 1
fi
cp "$scratch_dir/interface-functions.fixed" "$scratch_dir/interface-functions.inc"

sed '/if (cmd == PROTO_CMD_TEARDOWN && !proto_shell_busy(proto)/,/^\t}/d' \
	"$scratch_dir/dependency-functions.fixed" >"$scratch_dir/dependency-functions.inc"
compile
if "$scratch_dir/check" >"$scratch_dir/redundant-teardown.log" 2>&1; then
	echo "host-route regression test accepted another script for an idle stopped protocol" >&2
	exit 1
fi
cp "$scratch_dir/dependency-functions.fixed" "$scratch_dir/dependency-functions.inc"
compile
"$scratch_dir/check"
echo "netifd endpoint ownership: six negative controls PASS"
