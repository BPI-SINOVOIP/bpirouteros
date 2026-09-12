#!/bin/sh
# Check one assembled R4-Pro 8X rootfs and execute the boot service it actually
# carries against deterministic hardware fixtures.
#
# This is the whole gate: structure and behaviour, in one file with no external
# script dependency. It runs from build-full.sh against the assembled rootfs and
# from check-firmware-policy.sh against a rootfs unpacked out of a published
# image -- the latter from a frozen, read-only release-gate snapshot, which is
# why it must not reach for a sibling script. Source greps alone cannot prove
# that an optional 10G-PHY failure still preserves the four base MxL ports.
set -eu

ROOT=${1:-}
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

fail() {
	echo "FAIL: $*" >&2
	exit 1
}

[ -n "$ROOT" ] || fail "usage: check-as21xxx-rootfs.sh <assembled-rootfs>"
[ -d "$ROOT" ] || fail "assembled rootfs does not exist: $ROOT"

SCRIPT="$ROOT/etc/init.d/bpirouter-as21xxx-fw"
UCI_DEFAULT="$ROOT/etc/uci-defaults/99-bpirouter-as21xxx-fw"
[ -f "$SCRIPT" ] || fail "assembled rootfs has no /etc/init.d/bpirouter-as21xxx-fw.
  The firmware would be present and the PHY would never be bound to it."
[ -f "$UCI_DEFAULT" ] || fail "assembled rootfs has no AS21xxx first-boot launcher.
  The service would neither run on first deployment nor enable future boot recovery."
# Parsed, not merely present. A shipped image once carried this script with its
# closing brace missing -- a hand-edited patch hunk header was one line short, so
# git apply dropped the last line. `sh -n` on the source file passed, the patch
# applied cleanly, and the board booted with the PHY unbound and "syntax error:
# unexpected end of file" in the log. What matters is the file that shipped, so
# that is what gets parsed, and below, sourced and executed.
sh -n "$SCRIPT" || fail "assembled AS21xxx service does not parse"
sh -n "$UCI_DEFAULT" || fail "assembled AS21xxx first-boot launcher does not parse"
grep -Fxq '/etc/init.d/bpirouter-as21xxx-fw boot' "$UCI_DEFAULT" \
	|| fail "first deployment does not invoke the boot-only preparation action"
if grep -Fxq '/etc/init.d/bpirouter-as21xxx-fw start' "$UCI_DEFAULT"; then
	fail "first deployment incorrectly invokes diagnostic-only start"
fi
grep -Fq '/sbin/modprobe "$MXL_MODULE"' "$SCRIPT" \
	|| fail "boot preparation does not load the deferred MxL module"
if grep -Eq 'MXL_DRIVER/(un)?bind|mxl862xx.*/unbind' "$SCRIPT"; then
	fail "boot preparation still contains destructive MxL bind control writes"
fi

# The target busybox has no FEATURE_FLOAT_SLEEP, so a fractional interval makes
# every wait a no-op that still looks like polling. The build host's GNU sleep
# accepts floats and cannot reproduce it, so assert the value instead.
grep -qE '^WAIT_INTERVAL=[0-9]+$' "$SCRIPT" \
	|| fail "boot preparation uses a non-integer sleep interval; busybox sleep would reject it"

for module in as21xxx.ko mxl862xx_dsa.ko tag_mxl862xx.ko tag_mxl862xx_8021q.ko; do
	find "$ROOT/lib/modules" -type f -name "$module" -print -quit 2>/dev/null | grep -q . \
		|| fail "assembled rootfs is missing $module"
done
if find "$ROOT/etc/modules.d" -type f -print0 2>/dev/null \
	| xargs -0 -r grep -l -E '(^|[[:space:]])mxl862xx_dsa($|[[:space:]])' \
	| grep -q .; then
	fail "assembled rootfs autoloads mxl862xx_dsa before PHY preparation"
fi

fixture() {
	root=$1
	mkdir -p "$root/sys/bus/mdio_bus/devices/mdio-bus:1c" \
		"$root/sys/bus/mdio_bus/devices/mdio-bus:18" \
		"$root/sys/bus/mdio_bus/devices/mdio-bus:10" \
		"$root/sys/class/net" "$root/drivers" "$root/proc/device-tree" "$root/lib/firmware"
	printf '%s\0' 'Banana Pi BPI-R4 Pro 8X' > "$root/proc/device-tree/model"
	: > "$root/lib/firmware/as21x1x_fw.bin"
	: > "$root/sys/bus/mdio_bus/drivers_probe"
}

set_driver() {
	root=$1
	phy=$2
	driver=$3
	mkdir -p "$root/drivers/$driver"
	rm -f "$root/sys/bus/mdio_bus/devices/$phy/driver"
	ln -s "$root/drivers/$driver" "$root/sys/bus/mdio_bus/devices/$phy/driver"
}

set_mxl_bound() {
	root=$1
	mkdir -p "$root/drivers/mxl862xx"
	rm -f "$root/sys/bus/mdio_bus/devices/mdio-bus:10/driver"
	ln -s "$root/drivers/mxl862xx" "$root/sys/bus/mdio_bus/devices/mdio-bus:10/driver"
}

set_ports() {
	root=$1
	count=$2
	rm -rf "$root/sys/class/net/mxl_lan0" "$root/sys/class/net/mxl_lan1" \
		"$root/sys/class/net/mxl_lan2" "$root/sys/class/net/mxl_lan3" \
		"$root/sys/class/net/mxl_lan4"
	i=0
	while [ "$i" -lt "$count" ]; do
		mkdir -p "$root/sys/class/net/mxl_lan$i"
		i=$((i + 1))
	done
}

load_service() {
	root=$1
	export BPIR_AS21XXX_SYSFS_ROOT="$root/sys"
	export BPIR_AS21XXX_MODEL_FILE="$root/proc/device-tree/model"
	export BPIR_AS21XXX_FW="$root/lib/firmware/as21x1x_fw.bin"
	# shellcheck disable=SC1090
	. "$SCRIPT"
	[ "${WAIT_STEPS:-}" = 10 ] || fail "AS21xxx wait-step budget is not the 10-cycle bound"
	[ "${WAIT_INTERVAL:-}" = 1 ] || fail "AS21xxx wait interval is not the 1s integer bound"
	ACTION_LOG="$root/actions"
	: > "$ACTION_LOG"
	load_count=0
	MXL_LOAD_MODE=${MXL_LOAD_MODE:-full}
	PROBE_FAIL_PHY=${PROBE_FAIL_PHY:-}
	PROBE_DELAY_PHY=${PROBE_DELAY_PHY:-}
	MXL_LOAD_DELAY=${MXL_LOAD_DELAY:-0}
	probe_wait_ticks=0
	mxl_wait_ticks=0
	say() { :; }
	wait_tick() {
		if [ "$MXL_LOAD_DELAY" -eq 1 ]; then
			mxl_wait_ticks=$((mxl_wait_ticks + 1))
			if [ "$mxl_wait_ticks" -eq 2 ]; then
				set_mxl_bound "$root"
				set_ports "$root" 5
				MXL_LOAD_DELAY=0
			fi
			return
		fi
		probe_wait_ticks=$((probe_wait_ticks + 1))
		if [ -n "$PROBE_DELAY_PHY" ] && [ "$probe_wait_ticks" -eq 2 ]; then
			set_driver "$root" "$PROBE_DELAY_PHY" 'Aeonsemi AS21010PB1'
			PROBE_DELAY_PHY=
		fi
	}
	control_write() {
		value=$1
		path=$2
		printf '%s|%s\n' "$value" "$path" >> "$ACTION_LOG"
		case "$path" in
		"$MDIO_BUS/drivers_probe")
			if [ "$value" != "$PROBE_FAIL_PHY" ] && [ "$value" != "$PROBE_DELAY_PHY" ]; then
				set_driver "$root" "$value" 'Aeonsemi AS21010PB1'
			fi
			;;
		*/driver/unbind)
			rm -f "$MDIO_BUS/devices/$value/driver"
			;;
		esac
		return 0
	}
	load_mxl_driver() {
		load_count=$((load_count + 1))
		printf '%s\n' "load:$MXL_MODULE" >> "$ACTION_LOG"
		case "$MXL_LOAD_MODE" in
			fail) return 1 ;;
			delayed) MXL_LOAD_DELAY=1; return 0 ;;
			partial) count=4 ;;
			full) count=5 ;;
			*) fail "unknown MXL_LOAD_MODE $MXL_LOAD_MODE" ;;
		esac
		set_mxl_bound "$root"
		set_ports "$root" "$count"
	}
}

# Manual service actions must remain diagnostic-only even when the topology is
# incomplete. They must never infer a safe mutation window from netifd state.
(
	root="$TMP/runtime"
	fixture "$root"
	set_driver "$root" mdio-bus:1c 'Generic Clause 45 PHY'
	set_driver "$root" mdio-bus:18 'Generic Clause 45 PHY'
	set_mxl_bound "$root"
	set_ports "$root" 4
	load_service "$root"
	start && fail "diagnostic start accepted an incomplete runtime"
	[ ! -s "$ACTION_LOG" ] || fail "diagnostic start performed a control write"
)

# The 4E must not enter the 8X PHY service at all.
(
	root="$TMP/4e"
	fixture "$root"
	printf '%s\0' 'Banana Pi BPI-R4 Pro 4E' > "$root/proc/device-tree/model"
	load_service "$root"
	boot || fail "4E was not ignored"
	start || fail "4E diagnostics were not ignored"
	[ ! -s "$ACTION_LOG" ] || fail "AS21 service mutated 4E"
)

# A delayed PHY bind and deferred DSA registration are polled by state rather
# than guessed with fixed sleeps.
(
	root="$TMP/delayed"
	fixture "$root"
	set_driver "$root" mdio-bus:1c 'Aeonsemi AS21010PB1'
	set_driver "$root" mdio-bus:18 'Generic Clause 45 PHY'
	PROBE_DELAY_PHY=mdio-bus:18
	MXL_LOAD_MODE=delayed
	load_service "$root"
	boot || fail "bounded state polling rejected delayed PHY/DSA readiness"
	[ "$load_count" -eq 1 ] || fail "delayed readiness loaded MxL more than once"
	mxl_all_ports_ready || fail "delayed readiness did not converge to all ports"
)

# A complete pre-bound topology is a no-op and must never be detached.
(
	root="$TMP/settled"
	fixture "$root"
	set_driver "$root" mdio-bus:1c 'Aeonsemi AS21010PB1'
	set_driver "$root" mdio-bus:18 'Aeonsemi AS21010PB1'
	set_mxl_bound "$root"
	set_ports "$root" 5
	load_service "$root"
	boot || fail "settled boot returned failure"
	[ "$load_count" -eq 0 ] || fail "settled switch was loaded again"
	[ ! -s "$ACTION_LOG" ] || fail "settled boot performed a control write"
)

# Normal boot releases only the two early generic PHY bindings, prepares both
# firmware-backed PHYs, and performs one first MxL probe.
(
	root="$TMP/fresh"
	fixture "$root"
	set_driver "$root" mdio-bus:1c 'Generic Clause 45 PHY'
	set_driver "$root" mdio-bus:18 'Generic Clause 45 PHY'
	MXL_LOAD_MODE=full
	load_service "$root"
	boot || fail "fresh boot did not produce the complete topology"
	[ "$load_count" -eq 1 ] || fail "fresh boot did not load MxL exactly once"
	mxl_all_ports_ready || fail "fresh boot did not create all five MxL ports"
	if grep -q 'mxl862xx.*unbind' "$ACTION_LOG"; then
		fail "fresh boot destructively unbound the MxL switch"
	fi
)

# Failure of the independent WAN PHY is reported after the LAN PHY and switch
# have still been brought to their usable state.
(
	root="$TMP/wan-failure"
	fixture "$root"
	set_driver "$root" mdio-bus:1c 'Generic Clause 45 PHY'
	set_driver "$root" mdio-bus:18 'Generic Clause 45 PHY'
	PROBE_FAIL_PHY=mdio-bus:1c
	MXL_LOAD_MODE=full
	load_service "$root"
	boot && fail "WAN PHY failure was hidden"
	[ "$load_count" -eq 1 ] || fail "WAN failure suppressed the independent MxL load"
	mxl_all_ports_ready || fail "WAN failure suppressed combo-LAN preparation"
)

# Failure of the optional combo-LAN PHY must not suppress the four independent
# internal-PHY switch ports.
(
	root="$TMP/lan-failure"
	fixture "$root"
	set_driver "$root" mdio-bus:1c 'Aeonsemi AS21010PB1'
	set_driver "$root" mdio-bus:18 'Generic Clause 45 PHY'
	PROBE_FAIL_PHY=mdio-bus:18
	MXL_LOAD_MODE=partial
	load_service "$root"
	boot && fail "LAN PHY failure was hidden"
	[ "$load_count" -eq 1 ] || fail "combo PHY failure suppressed or repeated the MxL load"
	mxl_base_ports_ready || fail "combo PHY failure suppressed the base MxL ports"
)

# The switch creates a netdev for port13 as soon as it attaches ANY phy, so a
# combo PHY still on its generic pre-firmware identity yields five netdevs and
# a dead 10G port. Observed on hardware 2026-09-04. Reporting that as the
# complete topology is how a dead management port gets logged as ready.
(
	root="$TMP/combo-phy-generic"
	fixture "$root"
	set_driver "$root" mdio-bus:1c 'Aeonsemi AS21010PB1'
	set_driver "$root" mdio-bus:18 'Generic Clause 45 PHY'
	PROBE_FAIL_PHY=mdio-bus:18
	MXL_LOAD_MODE=full
	load_service "$root"
	boot && fail "a combo port on the generic pre-firmware PHY was reported as ready"
	[ "$load_count" -eq 1 ] || fail "generic combo PHY suppressed or repeated the MxL load"
	mxl_base_ports_ready || fail "generic combo PHY suppressed the base MxL ports"
	[ -e "$root/sys/class/net/mxl_lan4" ] \
		|| fail "fixture did not reproduce the five-netdev shape under test"
	! mxl_all_ports_ready || fail "netdev presence alone was accepted as a ready combo port"
)

# Missing external-PHY firmware is degraded, not authority to hide the four
# internal-PHY switch ports or detach an early generic PHY binding.
(
	root="$TMP/firmware-missing"
	fixture "$root"
	rm -f "$root/lib/firmware/as21x1x_fw.bin"
	set_driver "$root" mdio-bus:1c 'Generic Clause 45 PHY'
	set_driver "$root" mdio-bus:18 'Generic Clause 45 PHY'
	MXL_LOAD_MODE=partial
	load_service "$root"
	boot && fail "missing firmware was hidden"
	[ "$load_count" -eq 1 ] || fail "missing firmware suppressed or repeated the MxL load"
	mxl_base_ports_ready || fail "missing firmware suppressed the base MxL ports"
	if grep -q '/driver/unbind' "$ACTION_LOG"; then
		fail "missing firmware caused a destructive PHY unbind"
	fi
)

# A physically absent optional combo PHY has the same base-port fallback as a
# present but unready PHY.
(
	root="$TMP/combo-phy-absent"
	fixture "$root"
	set_driver "$root" mdio-bus:1c 'Aeonsemi AS21010PB1'
	mv "$root/sys/bus/mdio_bus/devices/mdio-bus:18" \
		"$root/sys/bus/mdio_bus/devices/mdio-bus:18.absent"
	MXL_LOAD_MODE=partial
	load_service "$root"
	boot && fail "absent combo PHY was hidden"
	[ "$load_count" -eq 1 ] || fail "absent combo PHY suppressed or repeated the MxL load"
	mxl_base_ports_ready || fail "absent combo PHY suppressed the base MxL ports"
)

# If something bound MxL early, an incomplete four-port baseline is preserved.
# The service may repair the PHY binding but never detaches the switch.
(
	root="$TMP/prebound-base"
	fixture "$root"
	set_driver "$root" mdio-bus:1c 'Aeonsemi AS21010PB1'
	set_driver "$root" mdio-bus:18 'Generic Clause 45 PHY'
	set_mxl_bound "$root"
	set_ports "$root" 4
	MXL_LOAD_MODE=fail
	load_service "$root"
	boot && fail "incomplete pre-bound topology was reported as success"
	[ "$load_count" -eq 0 ] || fail "pre-bound switch entered the module load path"
	mxl_base_ports_ready || fail "PHY preparation destroyed the four-port baseline"
)

# A failed first module load is reported without destroying any prior switch
# state; there was no baseline because the switch had not yet probed.
(
	root="$TMP/load-failure"
	fixture "$root"
	set_driver "$root" mdio-bus:1c 'Aeonsemi AS21010PB1'
	set_driver "$root" mdio-bus:18 'Aeonsemi AS21010PB1'
	MXL_LOAD_MODE=fail
	load_service "$root"
	boot && fail "failed MxL module load was reported as success"
	[ "$load_count" -eq 1 ] || fail "failed MxL load was retried"
	! mxl_base_ports_ready || fail "failed load fixture unexpectedly created base ports"
)

# A first probe which supplies only the established base ports is preserved and
# reported as degraded; no retry is allowed to trade four ports for zero.
(
	root="$TMP/partial"
	fixture "$root"
	set_driver "$root" mdio-bus:1c 'Aeonsemi AS21010PB1'
	set_driver "$root" mdio-bus:18 'Aeonsemi AS21210PB1'
	MXL_LOAD_MODE=partial
	load_service "$root"
	is_as21xxx_driver 'Aeonsemi AS21210PB1' || fail "supported AS21xxx family model was rejected"
	is_as21xxx_driver 'Aeonsemi AS21xxx' && fail "generic AS21xxx firmware loader was accepted as ready"
	boot && fail "partial first MxL probe was reported as complete"
	[ "$load_count" -eq 1 ] || fail "partial first probe was retried"
	mxl_base_ports_ready || fail "partial first probe did not preserve base ports"
)


echo "PASS: assembled AS21xxx/MxL boot policy is structurally and behaviorally valid"
