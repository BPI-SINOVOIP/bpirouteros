#!/bin/sh
set -eu

# Image checks inspect only shipped bytes, never the current source tree.
if [ "${1:-}" = --rootfs ]; then
	[ "$#" -eq 2 ] || { echo "usage: $0 --rootfs <assembled-rootfs>" >&2; exit 2; }
	binary=$2/sbin/netifd
	if [ ! -f "$binary" ] || [ -L "$binary" ] || [ ! -x "$binary" ] ||
		! LC_ALL=C grep -aFq 'bpir_proto_busy' "$binary" ||
		! LC_ALL=C grep -aFq 'netifd: protocol-script-owner:' "$binary" ||
		! LC_ALL=C grep -aFq 'netifd: modem-slot-lock:' "$binary"; then
		echo "netifd protocol execution evidence: FAIL: assembled /sbin/netifd lacks status or script-lifetime support; rebuild the matching netifd package" >&2
		exit 1
	fi
	echo "netifd protocol execution evidence in assembled binary: PASS"
	exit 0
fi
[ "$#" -eq 0 ] || { echo "usage: $0 [--rootfs <assembled-rootfs>]" >&2; exit 2; }

BUILD_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OPENWRT_DIR=${BPIR_OPENWRT_DIR:-$BUILD_DIR/openwrt}
OUTER=$BUILD_DIR/patches/common/openwrt/004-netifd-proto-busy.patch
INNER=package/network/config/netifd/patches/901-bpirouter-proto-busy.patch
LIFETIME_OUTER=$BUILD_DIR/patches/common/openwrt/005-netifd-protocol-script-lifetime.patch
LIFETIME_INNER=package/network/config/netifd/patches/902-bpirouter-protocol-script-lifetime.patch
scratch_dir=$(mktemp -d "${TMPDIR:-/tmp}/bpirouter-proto-busy.XXXXXX")
trap 'rm -r -- "$scratch_dir"' EXIT HUP INT TERM

# Exercise the package patch which prepare installs, not a copied predicate.
git -C "$scratch_dir" apply --whitespace=nowarn "$OUTER"
git -C "$scratch_dir" apply --whitespace=nowarn "$LIFETIME_OUTER"
patch_file=$scratch_dir/$INNER
lifetime_patch=$scratch_dir/$LIFETIME_INNER
awk '/^\+\+\+ b\/proto-script.h$/ { header=1; next }
     header && /^diff --git/ { exit }
     header && /^\+/ { print substr($0, 2) }' "$lifetime_patch" >"$scratch_dir/proto-script.h"
awk '/^\+\+\+ b\/modem-slot.h$/ { header=1; next }
     header && /^diff --git/ { exit }
     header && /^\+/ { print substr($0, 2) }' "$lifetime_patch" >"$scratch_dir/modem-slot.h"
awk '/^\+netifd_signal_process\(/ { copy=1; print "void" }
     copy { print substr($0, 2) } copy && /^\+}$/ { exit }' \
	"$lifetime_patch" >"$scratch_dir/signal-process.inc"
awk '/^ netifd_kill_process\(/ { copy=1; print "void" }
     copy && !/^-/ { print substr($0, 2) } copy && /^ }$/ { exit }' \
	"$lifetime_patch" >"$scratch_dir/kill-process.inc"
awk '/^\+.*state->script_task.script_group =/ { print substr($0, 2) }' \
	"$lifetime_patch" >"$scratch_dir/script-scope.inc"
awk '/^\+.*if \(\(pid = proc->script_group/ { print substr($0, 2) }' \
	"$lifetime_patch" >"$scratch_dir/fork-script.inc"
[ -s "$scratch_dir/script-scope.inc" ]
[ -s "$scratch_dir/fork-script.inc" ]
awk '/^\+static bool$/ { copy=1 } copy { print substr($0, 2) } copy && /^\+}$/ { exit }' \
	"$patch_file" >"$scratch_dir/proto-busy.inc"
awk '/^\+.*blobmsg_add_u8.*"bpir_proto_busy"/ { copy=1 } copy { print substr($0, 2) } copy && /;$/ { exit }' \
	"$patch_file" >"$scratch_dir/status-busy.inc"
[ -s "$scratch_dir/proto-busy.inc" ] && [ -s "$scratch_dir/status-busy.inc" ]
grep -Fq '+	state->proto.busy = proto_shell_busy;' "$patch_file"
grep -Fq '+	bool (*busy)(struct interface_proto_state *);' "$patch_file"
"${HOSTCC:-cc}" -std=c99 -Wall -Wextra -Werror -I"$scratch_dir" \
	"$BUILD_DIR/scripts/tests/netifd-proto-busy.c" -o "$scratch_dir/check"
"$scratch_dir/check"

# Execute the shipped lifetime helper with real child processes. The negative
# control uses the former direct-script execution and must leave an orphan.
mkdir -p "$scratch_dir/dev" "$scratch_dir/sys/class/tty/ttyUSB0" \
	"$scratch_dir/sys/class/tty/ttyUSB1" "$scratch_dir/sys/class/usbmisc/cdc-wdm0" \
	"$scratch_dir/sys/devices/2-1.1/2-1.1:1.0" "$scratch_dir/sys/devices/2-1.2/2-1.2:1.0"
touch "$scratch_dir/dev/ttyUSB0" "$scratch_dir/dev/ttyUSB1" "$scratch_dir/dev/cdc-wdm0"
for device in 2-1.1 2-1.2; do
	printf '2c7c\n' >"$scratch_dir/sys/devices/$device/idVendor"
	printf '7\n' >"$scratch_dir/sys/devices/$device/devnum"
done
ln -s "$scratch_dir/sys/devices/2-1.1/2-1.1:1.0" "$scratch_dir/sys/class/tty/ttyUSB0/device"
ln -s "$scratch_dir/sys/devices/2-1.1/2-1.1:1.0" "$scratch_dir/sys/class/usbmisc/cdc-wdm0/device"
ln -s "$scratch_dir/sys/devices/2-1.2/2-1.2:1.0" "$scratch_dir/sys/class/tty/ttyUSB1/device"
set -- "-DMODEM_SYSFS=\"$scratch_dir/sys\"" "-DMODEM_LOCK_ROOT=\"$scratch_dir/locks\"" \
	"-DTEST_DEVICE=\"$scratch_dir/dev/ttyUSB0\"" "-DTEST_OTHER_DEVICE=\"$scratch_dir/dev/ttyUSB1\"" \
	"-DTEST_QMI_DEVICE=\"$scratch_dir/dev/cdc-wdm0\""
"${HOSTCC:-cc}" -std=c99 -Wall -Wextra -Werror -I"$scratch_dir" \
	"$@" "$BUILD_DIR/scripts/tests/netifd-proto-script.c" -o "$scratch_dir/owner-check"
"$scratch_dir/owner-check"
"${HOSTCC:-cc}" -std=c99 -Wall -Wextra -Werror -Wno-unused-function \
	-DBPIR_TEST_UNSUPERVISED -I"$scratch_dir" \
	"$@" "$BUILD_DIR/scripts/tests/netifd-proto-script.c" -o "$scratch_dir/old-check"
if "$scratch_dir/old-check" >"$scratch_dir/old-check.log" 2>&1; then
	echo "protocol script test failed to detect the former orphan lifetime" >&2
	exit 1
fi
grep -Fq 'orphan: owner_reaped=1 command_gone=0' "$scratch_dir/old-check.log"

# Reopen only the pre-handler signal window in the scratch test process.
# The startup assertion must reject it, even though normal teardown works.
"${HOSTCC:-cc}" -std=c99 -Wall -Wextra -Werror -I"$scratch_dir" \
	-DBPIR_TEST_LATE_SIGNAL_BLOCK \
	"$@" "$BUILD_DIR/scripts/tests/netifd-proto-script.c" -o "$scratch_dir/late-block-check"
if "$scratch_dir/late-block-check" >"$scratch_dir/late-block-check.log" 2>&1; then
	echo "protocol script test missed a termination request lost during startup" >&2
	exit 1
fi
grep -Fq 'startup: first_request_reaped_owner=0' "$scratch_dir/late-block-check.log"

# Removing only flock must fail even though process ownership still works.
"${HOSTCC:-cc}" -std=c99 -Wall -Wextra -Werror -Wno-unused-function -I"$scratch_dir" \
	-DBPIR_TEST_NO_SLOT_LOCK "$@" \
	"$BUILD_DIR/scripts/tests/netifd-proto-script.c" -o "$scratch_dir/no-lock-check"
if "$scratch_dir/no-lock-check" >"$scratch_dir/no-lock-check.log" 2>&1; then
	echo "protocol script test missed absent cross-process exclusion" >&2
	exit 1
fi
grep -Fq 'slot lock missing while a protocol command is alive' "$scratch_dir/no-lock-check.log"

# The C fixture contains the actual emitted field. An unrelated executable
# cannot satisfy this requirement, regardless of the current patch contents.
mkdir -p "$scratch_dir/root/sbin"
cp "$scratch_dir/owner-check" "$scratch_dir/root/sbin/netifd"
sh "$0" --rootfs "$scratch_dir/root"
cp "$scratch_dir/check" "$scratch_dir/root/sbin/netifd"
if sh "$0" --rootfs "$scratch_dir/root" >"$scratch_dir/rejected.log" 2>&1; then
	echo "netifd rootfs gate accepted status without protocol script ownership" >&2
	exit 1
fi
cp /bin/true "$scratch_dir/root/sbin/netifd"
if sh "$0" --rootfs "$scratch_dir/root" >"$scratch_dir/rejected.log" 2>&1; then
	echo "netifd rootfs gate accepted a binary without protocol status" >&2
	exit 1
fi
cp "$scratch_dir/owner-check" "$scratch_dir/root/sbin/netifd"
chmod -x "$scratch_dir/root/sbin/netifd"
if sh "$0" --rootfs "$scratch_dir/root" >"$scratch_dir/rejected.log" 2>&1; then
	echo "netifd rootfs gate accepted a non-executable binary" >&2
	exit 1
fi

# Source preparation remains authoritative on a clean host. When the locked
# source is already available, also verify the complete C patch applies.
set -- "$OPENWRT_DIR"/build_dir/target-*/netifd-*/proto-shell.c
if [ -f "$1" ]; then
	source_dir=$(dirname "$1")
	# build_dir lives beneath the build Git repository. An apply launched
	# there may silently skip paths outside its repository-relative prefix.
	# Check real source files outside that repository, in application order.
	mkdir -p "$scratch_dir/source"
	for file in proto.h proto-shell.c ubus.c netifd.h main.c interface.c; do
		cp "$source_dir/$file" "$scratch_dir/source/"
	done
	if [ -f "$source_dir/proto-script.h" ]; then
		cp "$source_dir/proto-script.h" "$scratch_dir/source/"
	fi
	if [ -f "$source_dir/modem-slot.h" ]; then
		cp "$source_dir/modem-slot.h" "$scratch_dir/source/"
	fi
	for package_patch in "$patch_file" "$lifetime_patch"; do
		if git -C "$scratch_dir/source" apply --check "$package_patch" 2>/dev/null; then
			# OpenWrt uses patch, which rejects misordered hunks Git accepts.
			patch -f -p1 -d "$scratch_dir/source" -i "$package_patch"
		else
			git -C "$scratch_dir/source" apply --reverse --check "$package_patch"
		fi
	done
	# A rejected owner must not recreate netifd's autonomous retry loop. Use
	# the real patched handler and upstream callbacks, not a copied policy.
	extract_function() {
		awk -v fn="$2" -v type="$3" '
			$0 ~ "^" fn "\\(" { copy=1; print "static " type }
			copy { print } copy && /^}$/ { exit }
		' "$1" >"$4"
		[ -s "$4" ]
	}
	extract_function "$scratch_dir/source/proto-shell.c" proto_shell_handler int "$scratch_dir/restart-handler.inc"
	extract_function "$scratch_dir/source/proto-shell.c" proto_shell_task_finish void "$scratch_dir/restart-task-finish.inc"
	extract_function "$scratch_dir/source/proto-shell.c" proto_shell_script_cb void "$scratch_dir/restart-script-cb.inc"
	extract_function "$scratch_dir/source/proto-shell.c" proto_shell_busy bool "$scratch_dir/restart-busy.inc"
	extract_function "$scratch_dir/source/interface.c" interface_handle_config_change void "$scratch_dir/restart-config-change.inc"
	extract_function "$scratch_dir/source/interface.c" __interface_set_up int "$scratch_dir/restart-ifup.inc"
	extract_function "$scratch_dir/source/interface.c" __interface_set_down void "$scratch_dir/restart-ifdown.inc"
	"${HOSTCC:-cc}" -std=c99 -Wall -Wextra -Werror -Wno-unused-parameter -I"$scratch_dir" \
		"$BUILD_DIR/scripts/tests/netifd-proto-restart.c" -o "$scratch_dir/restart-check"
	"$scratch_dir/restart-check"
	# Revert only the new parent-side policy in scratch. Script-only blocking
	# cannot protect a script which never starts; the callback test must fail.
	mkdir -p "$scratch_dir/restart-old"
	sed '/proto->iface->autostart = false;/s/false/true/' \
		"$scratch_dir/restart-handler.inc" >"$scratch_dir/restart-old/restart-handler.inc"
	"${HOSTCC:-cc}" -std=c99 -Wall -Wextra -Werror -Wno-unused-parameter \
		-I"$scratch_dir/restart-old" -I"$scratch_dir" \
		"$BUILD_DIR/scripts/tests/netifd-proto-restart.c" -o "$scratch_dir/restart-old/check"
	if "$scratch_dir/restart-old/check" >"$scratch_dir/restart-old/rejected.log" 2>&1; then
		echo "netifd callback test missed autonomous retry after script admission failure" >&2
		exit 1
	fi
	grep -Fq 'rejected qmi: launch_error=0 json_error=0 blocked_before_child=0 autonomous_setup=1' \
		"$scratch_dir/restart-old/rejected.log"
	echo "netifd rejected-owner callback and script-only negative control: PASS"
	# Keep restart blocked but restore the no-child busy leak in scratch. A
	# later explicit ifup must fail this test without resetting protocol state.
	mkdir -p "$scratch_dir/restart-stuck"
	sed 's/state->sm = S_IDLE;/state->sm = S_SETUP;/' \
		"$scratch_dir/restart-handler.inc" >"$scratch_dir/restart-stuck/restart-handler.inc"
	"${HOSTCC:-cc}" -std=c99 -Wall -Wextra -Werror -Wno-unused-parameter \
		-I"$scratch_dir/restart-stuck" -I"$scratch_dir" \
		"$BUILD_DIR/scripts/tests/netifd-proto-restart.c" -o "$scratch_dir/restart-stuck/check"
	if "$scratch_dir/restart-stuck/check" >"$scratch_dir/restart-stuck/rejected.log" 2>&1; then
		echo "netifd callback test missed stale busy state after pre-fork failure" >&2
		exit 1
	fi
	grep -Fq 'prefork qmi: json_error=0 idle=0 busy=1 child=0' \
		"$scratch_dir/restart-stuck/rejected.log"
	echo "netifd no-child setup failure, explicit retry and stale-busy negative control: PASS"
else
	echo "netifd restart callback test: SKIP (locked netifd source not prepared)"
fi
for gate in build-full.sh build-image.sh; do
	grep -Fq '"$SCRIPT_DIR/test-netifd-proto-busy.sh"' "$BUILD_DIR/scripts/$gate"
	grep -Fq '"$SCRIPT_DIR/test-netifd-proto-busy.sh" --rootfs' "$BUILD_DIR/scripts/$gate"
done
grep -Fq "$INNER" "$BUILD_DIR/scripts/lib/openwrt-source.sh"
grep -Fq "$LIFETIME_INNER" "$BUILD_DIR/scripts/lib/openwrt-source.sh"
echo "netifd protocol execution evidence: PASS"
