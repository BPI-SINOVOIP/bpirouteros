#!/bin/sh
set -eu

BUILD_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OPENWRT_DIR=${BPIR_OPENWRT_DIR:-${BPIR_WORK_DIR:-$BUILD_DIR/openwrt}}
PACKAGES_DIR=$OPENWRT_DIR/feeds/packages
PATCH=$BUILD_DIR/patches/common/packages/003-mwan3-replay-parent-on-dynamic-child-ifup.patch
HOTPLUG=net/mwan3/files/etc/hotplug.d/iface/15-mwan3

[ -f "$PATCH" ] || { echo "missing mwan3 dynamic-child patch" >&2; exit 1; }
[ -f "$PACKAGES_DIR/$HOTPLUG" ] || { echo "missing mwan3 hotplug source" >&2; exit 1; }

scratch_dir=$(mktemp -d "${TMPDIR:-/tmp}/bpirouter-mwan3-child.XXXXXX")
cleanup() {
	rm -r -- "$scratch_dir"
}
trap cleanup EXIT HUP INT TERM

mkdir -p "$scratch_dir/$(dirname "$HOTPLUG")"
cp "$PACKAGES_DIR/$HOTPLUG" "$scratch_dir/$HOTPLUG"

if git -C "$PACKAGES_DIR" apply --reverse --check "$PATCH" 2>/dev/null; then
	:
elif git -C "$scratch_dir" apply --check "$PATCH" 2>/dev/null; then
	git -C "$scratch_dir" apply "$PATCH"
else
	echo "mwan3 dynamic-child patch neither applies nor matches the prepared feed" >&2
	exit 1
fi

sh -n "$scratch_dir/$HOTPLUG"

# Run the hotplug script up to its lock with the absolute includes removed.
# procd_lock and mwan3_init end the run: reaching either means the event took
# mwan3's normal path. The replay is the only exec in the script; the stub
# records it and stops, as exec would.
trace=$scratch_dir/trace
harness=$scratch_dir/harness.sh
{
	cat <<'EOF'
FIRSTCONNECT=0
MWAN3_SHUTDOWN=0
LOG() { :; }
config_load() { :; }
config_get_bool() {
	if [ "$2.$3" = "$T_PARENT.enabled" ]; then eval "$1=\${T_PARENT_ENABLED}"; else eval "$1=\$4"; fi
}
config_get() {
	case "$2.$3" in
	"$T_PARENT.family") eval "$1=\${T_PARENT_FAMILY}" ;;
	"$INTERFACE.TYPE") eval "$1=\${T_CHILD_TYPE}" ;;
	*) eval "$1=\${4:-}" ;;
	esac
}
replay_stub() { printf 'replay %s %s\n' "$1" "$2" >>"$trace"; exit 0; }
procd_lock() { printf '%s\n' lock >>"$trace"; exit 0; }
mwan3_init() { printf '%s\n' init >>"$trace"; exit 0; }
EOF
	sed -e '/^\. \/lib\/functions\.sh$/d' \
		-e '/^\. \/lib\/functions\/network\.sh$/d' \
		-e '/^\. \/lib\/mwan3\/mwan3\.sh$/d' \
		-e '/^\. \/lib\/functions\/procd\.sh$/d' \
		-e 's#exec /usr/sbin/mwan3 ifup#replay_stub ifup#' \
		"$scratch_dir/$HOTPLUG"
} >"$harness"

grep -q 'replay_stub ifup' "$harness" || {
	echo "mwan3 hotplug no longer replays the parent ifup" >&2
	exit 1
}

# case: action interface startup parent-enabled parent-family child-type expected
check() {
	: >"$trace"
	trace=$trace ACTION=$1 INTERFACE=$2 DEVICE=usb0 MWAN3_STARTUP=$3 \
		T_PARENT=bpir_wwan2 T_PARENT_ENABLED=$4 T_PARENT_FAMILY=$5 T_CHILD_TYPE=$6 \
		sh "$harness" || true
	actual=$(cat "$trace")
	[ "$actual" = "$7" ] || {
		echo "mwan3 hotplug $1 $2 (startup=$3 enabled=$4 family=$5 child=$6):" >&2
		echo "  expected '$7', got '$actual'" >&2
		exit 1
	}
}

check ifup bpir_wwan2_4 hotplug 1 ipv4 '' 'replay ifup bpir_wwan2'
check ifup bpir_wwan2_6 hotplug 1 ipv6 '' 'replay ifup bpir_wwan2'
check ifup bpir_wwan2_4 cmd 1 ipv4 '' 'replay ifup bpir_wwan2'
check ifup bpir_wwan2_4 hotplug 0 ipv4 '' lock
check ifup bpir_wwan2_6 hotplug 1 ipv4 '' lock
check ifup bpir_wwan2_4 hotplug 1 ipv4 interface lock
check ifdown bpir_wwan2_4 hotplug 1 ipv4 '' lock
check connected bpir_wwan2_4 hotplug 1 ipv4 '' lock
check ifup bpir_wwan2 hotplug 1 ipv4 '' lock
check ifup bpir_wwan2_4 init 1 ipv4 '' init

echo "mwan3 dynamic-child replay: PASS"
