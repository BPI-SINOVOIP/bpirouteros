#!/bin/sh
set -eu

BUILD_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OPENWRT_DIR=${BPIR_OPENWRT_DIR:-${BPIR_WORK_DIR:-$BUILD_DIR/openwrt}}
PACKAGES_DIR=$OPENWRT_DIR/feeds/packages
PATCH=$BUILD_DIR/patches/common/packages/001-mwan3-refresh-connected-after-route-cleanup.patch
SOURCE=net/mwan3/files/usr/sbin/mwan3rtmon
HOTPLUG=net/mwan3/files/etc/hotplug.d/iface/15-mwan3
PREPARE=$BUILD_DIR/scripts/prepare.sh

[ -f "$PATCH" ] || { echo "missing mwan3 route-monitor patch" >&2; exit 1; }
[ -f "$PACKAGES_DIR/$SOURCE" ] || { echo "missing mwan3rtmon source" >&2; exit 1; }
[ -f "$PACKAGES_DIR/$HOTPLUG" ] || { echo "missing mwan3 hotplug source" >&2; exit 1; }

scratch_dir=$(mktemp -d "${TMPDIR:-/tmp}/bpirouter-mwan3-route.XXXXXX")
cleanup() {
	rm -r -- "$scratch_dir"
}
trap cleanup EXIT HUP INT TERM

mkdir -p "$scratch_dir/$(dirname "$SOURCE")"
mkdir -p "$scratch_dir/$(dirname "$HOTPLUG")"
cp "$PACKAGES_DIR/$SOURCE" "$scratch_dir/$SOURCE"
cp "$PACKAGES_DIR/$HOTPLUG" "$scratch_dir/$HOTPLUG"

if git -C "$PACKAGES_DIR" apply --reverse --check "$PATCH" 2>/dev/null; then
	cp "$PACKAGES_DIR/$SOURCE" "$scratch_dir/$SOURCE"
	cp "$PACKAGES_DIR/$HOTPLUG" "$scratch_dir/$HOTPLUG"
elif git -C "$scratch_dir" apply --check "$PATCH" 2>/dev/null; then
	git -C "$scratch_dir" apply "$PATCH"
else
	echo "mwan3 patch neither applies nor matches the prepared feed" >&2
	exit 1
fi

sh -n "$scratch_dir/$SOURCE"
sh -n "$scratch_dir/$HOTPLUG"

# Source only the route handler. The production file's absolute includes and
# main loop are deliberately excluded so this remains a host-side unit test.
sed -e '/^\. \/lib\/functions\.sh$/d' \
	-e '/^\. \/lib\/functions\/network\.sh$/d' \
	-e '/^\. \/lib\/mwan3\/mwan3\.sh$/d' \
	-e '/^main "\$@"$/d' \
	"$scratch_dir/$SOURCE" >"$scratch_dir/handler.sh"

trace=$scratch_dir/trace
route='192.0.2.0/24 dev usb0 proto kernel scope link src 192.0.2.2'

# shellcheck disable=SC1090
. "$scratch_dir/handler.sh"
IP4=ip4_stub
IP6=ip6_stub
IPS=ipset_stub
MWAN3_ROUTE_LINE_EXP=p
NO_IPV6=0

LOG() { :; }
mwan3_get_routes() { :; }
mwan3_update_dev_to_table() { :; }
mwan3_route_line_dev() { eval "$1=1"; }
mwan3_get_mwan3track_status() { eval "$1=active"; }
network_get_device() { eval "$1=usb0"; }
config_foreach() { :; }
mwan3_set_connected_ipv4() { printf '%s\n' connected-rebuild >>"$trace"; }
mwan3_set_connected_ipv6() { printf '%s\n' connected-rebuild >>"$trace"; }
ipset_stub() { :; }
ip4_stub() {
	if [ "$1 $2 $3 $4" = "route list table 1" ]; then
		printf '%s\n' "$route"
	elif [ "$1 $2 $3" = "route del table" ]; then
		printf '%s\n' policy-delete >>"$trace"
	fi
}
ip6_stub() { ip4_stub "$@"; }

# The production script is not executed with nounset and intentionally calls
# handle_route without an interface when the route already maps to a table.
expected='policy-delete
connected-rebuild'
for family in ipv4 ipv6; do
	: >"$trace"
	set +u
	mwan3_rtmon_route_handle "Deleted $route" "$family"
	set -u

	actual=$(cat "$trace")
	[ "$actual" = "$expected" ] || {
		echo "mwan3 $family delete order is unsafe:" >&2
		printf '%s\n' "$actual" >&2
		exit 1
	}
done

# A physical netdev removal can publish only a local-table delete, which the
# route monitor intentionally filters. Exercise the existing ifdown lifecycle
# and prove that it rebuilds both connected sets only after the interface's
# policy table has been flushed.
hotplug_trace=$scratch_dir/hotplug-trace
hotplug_harness=$scratch_dir/hotplug-harness.sh
{
	cat <<'EOF'
ACTION=ifdown
INTERFACE=cellular
FIRSTCONNECT=0
MWAN3_SHUTDOWN=0
MWAN3_STARTUP=test
IPT4=ipt4_stub
procd_lock() { :; }
mwan3_init() { :; }
mwan3_service_running() { return 0; }
ipt4_stub() { return 0; }
config_get_bool() { eval "$1=1"; }
config_get() { eval "$1=online"; }
LOG() { :; }
mwan3_set_iface_hotplug_state() { :; }
mwan3_delete_iface_ipset_entries() { :; }
mwan3_delete_iface_rules() { :; }
mwan3_delete_iface_route() { printf '%s\n' policy-route-delete >>"$hotplug_trace"; }
mwan3_delete_iface_iptables() { :; }
procd_running() { return 1; }
procd_send_signal() { :; }
mwan3_set_policies_iptables() { printf '%s\n' policy-update >>"$hotplug_trace"; }
mwan3_set_connected_ipv4() { printf '%s\n' connected-v4 >>"$hotplug_trace"; }
mwan3_set_connected_ipv6() { printf '%s\n' connected-v6 >>"$hotplug_trace"; }
mwan3_flush_conntrack() { :; }
EOF
	sed -e '/^\. \/lib\/functions\.sh$/d' \
		-e '/^\. \/lib\/functions\/network\.sh$/d' \
		-e '/^\. \/lib\/mwan3\/mwan3\.sh$/d' \
		-e '/^\. \/lib\/functions\/procd\.sh$/d' \
		-e 's#^/etc/init.d/mwan3 running#\tmwan3_service_running#' \
		"$scratch_dir/$HOTPLUG"
} >"$hotplug_harness"

: >"$hotplug_trace"
hotplug_trace=$hotplug_trace sh "$hotplug_harness"
expected_hotplug='policy-route-delete
policy-update
connected-v4
connected-v6'
actual_hotplug=$(cat "$hotplug_trace")
[ "$actual_hotplug" = "$expected_hotplug" ] || {
	echo "mwan3 ifdown connected-set refresh order is unsafe:" >&2
	printf '%s\n' "$actual_hotplug" >&2
	exit 1
}

update_line=$(grep -nF './scripts/feeds update -a' "$PREPARE" | cut -d: -f1)
patch_line=$(grep -nF 'apply_patches "$BUILD_DIR/patches/common/packages" packages' "$PREPARE" | cut -d: -f1)
install_line=$(grep -nF './scripts/feeds install -a' "$PREPARE" | cut -d: -f1)
[ "$update_line" -lt "$patch_line" ] && [ "$patch_line" -lt "$install_line" ] || {
	echo "packages-feed patch is not applied between feed update and install" >&2
	exit 1
}

for build in "$BUILD_DIR/scripts/build-full.sh" "$BUILD_DIR/scripts/build-image.sh"; do
	grep -Fq '"$SCRIPT_DIR/test-mwan3-route-delete-order.sh"' "$build" || {
		echo "$(basename "$build") omits the mwan3 route-delete gate" >&2
		exit 1
	}
done

echo "mwan3 route-delete ordering gate: PASS"
