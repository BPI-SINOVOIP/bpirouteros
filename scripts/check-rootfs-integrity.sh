#!/bin/bash
# Post-build gate on the two things that decide whether a flashed board comes
# up with networking at all.
#
# 1. BOOT ORDER AND PAYLOAD -- the product's canonicalizers and services are
#    present, executable, and sequenced so config is canonical before the
#    services that consume it start.
#
# 2. RUNTIME COMMAND DEPENDENCIES -- every external command the product's own
#    on-device shell invokes is actually provided by this rootfs.
#
# Check runtime commands against the target rootfs, not the build host.
# Host-installed utilities must not hide missing target dependencies.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
ROOT=${1:-}
fail() { echo "FAIL: rootfs integrity: $*" >&2; exit 1; }
# Optional: the formal acceptance tool bundle that will run on this rootfs.
ACCEPTANCE_TOOLS=
if [ $# -gt 1 ]; then
	[ $# -eq 3 ] && [ "$2" = --acceptance-tools ] \
		|| fail "usage: $(basename "$0") <assembled-rootfs> [--acceptance-tools <bundle-dir>]"
	ACCEPTANCE_TOOLS=$3
fi

# The rootfs must be supplied. This gate runs after ASSEMBLY, and the rc.d
# links it checks are created by each package's postinst during assembly -- the
# staging tree this used to fall back to has an empty /etc/rc.d, so the search
# could only ever produce a red that means nothing. build-full.sh and
# build-image.sh both pass the assembled root they just produced.
[ -n "$ROOT" ] || fail "usage: $(basename "$0") <assembled-rootfs>  (e.g. the ImageBuilder root, as build-image.sh passes it)"
[ -d "$ROOT" ] || fail "target rootfs $ROOT is not a directory"

# ── 1. Boot order and payload ────────────────────────────────────────────────

for file in \
	etc/init.d/boot etc/init.d/firewall etc/init.d/mwan3 etc/init.d/network \
	etc/init.d/bpirouter-api etc/init.d/bpirouter-cfg-recovery \
	etc/init.d/bpirouter-ota-restore usr/libexec/bpirouter-ota-restore \
	etc/uci-defaults/11-bpirouter-mwan3-canonical \
	etc/uci-defaults/12-bpirouter-sqm-canonical \
	etc/uci-defaults/13-bpirouter-offload-disabled \
	usr/libexec/bpirouter-mwan3-strict.awk \
	usr/libexec/bpirouter-sqm-strict.awk; do
	[ -f "$ROOT/$file" ] || fail "missing /$file"
done
for file in etc/init.d/bpirouter-ota-restore usr/libexec/bpirouter-ota-restore; do
	[ -x "$ROOT/$file" ] || fail "/$file is not executable"
done

[ ! -e "$ROOT/etc/uci-defaults/10-bpirouter-ota-restore" ] &&
	[ ! -L "$ROOT/etc/uci-defaults/10-bpirouter-ota-restore" ] ||
	fail "OTA restore is still packaged as a one-shot uci-defaults script"
for file in etc/uci-defaults/11-bpirouter-mwan3-canonical \
	etc/uci-defaults/12-bpirouter-sqm-canonical \
	etc/uci-defaults/13-bpirouter-offload-disabled; do
	[ -x "$ROOT/$file" ] || fail "/$file is not executable"
done

offload_script=$ROOT/etc/uci-defaults/13-bpirouter-offload-disabled
for assignment in \
	'firewall.@defaults[0].flow_offloading=0' \
	'firewall.@defaults[0].flow_offloading_hw=0'; do
	grep -Fq "$assignment" "$offload_script" ||
		fail "offload migration does not pin $assignment"
done

wifi_drivers=0
for driver in mt7915e mt7996e; do
	if find "$ROOT/lib/modules" -type f -name "$driver.ko*" -print -quit 2>/dev/null | grep -q .; then
		wifi_drivers=$((wifi_drivers + 1))
		modules_file=$ROOT/etc/modules.d/$driver
		[ -f "$modules_file" ] || fail "$driver is present but its autoload policy is absent"
		[ "$(grep -Fxc "$driver wed_enable=0" "$modules_file")" -eq 1 ] ||
			fail "$driver WED is not disabled in its original autoload entry"
		if grep -Ev "^$driver wed_enable=0$" "$modules_file" | grep -q .; then
			fail "$driver autoload policy contains an unknown or non-disabled entry"
		fi
	fi
done
[ "$wifi_drivers" -eq 1 ] || fail "rootfs must contain exactly one supported Wi-Fi driver, found $wifi_drivers"

for module in sch_htb sch_ingress cls_matchall act_mirred ifb; do
	if ! find "$ROOT/lib/modules" -type f -name "$module.ko*" -print -quit 2>/dev/null | grep -q .; then
		fail "bandwidth execution dependency $module.ko is absent"
	fi
done

start_of() { sed -n 's/^START=//p' "$ROOT/etc/init.d/$1" | head -1; }
[ "$(start_of boot)" = 10 ] || fail "boot is not START=10"
[ "$(start_of bpirouter-ota-restore)" = 10 ] || fail "OTA restore is not START=10"
[ "$(start_of bpirouter-cfg-recovery)" = 11 ] || fail "config generation recovery is not START=11"
[ "$(start_of firewall)" = 19 ] || fail "firewall is not START=19"
[ "$(start_of mwan3)" = 19 ] || fail "mwan3 is not START=19"
[ "$(start_of network)" = 20 ] || fail "network is not START=20"
[ "$(start_of bpirouter-api)" = 99 ] || fail "apid is not START=99"

check_link() {
	local link=$1 service=$2 path="$ROOT/etc/rc.d/$1"
	[ -L "$path" ] || fail "missing rc.d/$link"
	[ "$(readlink "$path")" = "../init.d/$service" ] ||
		fail "rc.d/$link does not point exactly to ../init.d/$service"
	[ -f "$ROOT/etc/init.d/$service" ] && [ -x "$ROOT/etc/init.d/$service" ] ||
		fail "rc.d/$link target /etc/init.d/$service is not an executable regular file"
}
check_link S10boot boot
check_link S10bpirouter-ota-restore bpirouter-ota-restore
check_link S11bpirouter-cfg-recovery bpirouter-cfg-recovery
check_link S19firewall firewall
check_link S19mwan3 mwan3
check_link S20network network
check_link S99bpirouter-api bpirouter-api

ota_restore_init=$ROOT/etc/init.d/bpirouter-ota-restore
grep -Fq 'PROG=${BPIR_OTA_RESTORE_PROG:-/usr/libexec/bpirouter-ota-restore}' "$ota_restore_init" ||
	fail "OTA restore init does not select the immutable every-boot helper"
grep -Eq '^[[:space:]]*"\$PROG"[[:space:]]*$' "$ota_restore_init" ||
	fail "OTA restore init does not execute the immutable helper on boot"

# Nothing the product ships may gate a service start. rc.common runs for every
# init script including network at boot, so a non-zero exit from anything
# spliced in here is indistinguishable from "this board has no network", with
# no way in except serial or a factory reset. Whatever the next reason to add
# an admission check is, this is not the place: it can only ever subtract
# availability, and it defends against nobody -- root is the only account on
# the device, and root can bypass any check it can also delete.
if [ -f "$ROOT/etc/rc.common" ] && grep -Eq 'bpir|bpirouter' "$ROOT/etc/rc.common"; then
	fail "etc/rc.common carries a product hook; service start must never be gated"
fi

# Generation recovery runs on the boot path, so it must be incapable of
# failing one. It restores files and nothing more: it never decides whether a
# service may start, and every command it runs is swallowed. Every config file
# on disk is complete whatever it does, so a board that skips recovery still
# comes up -- on the generation it booted with.
#
# This is the property the withdrawn fence did not have, and it is the reason
# that fence turned one missing `stat` into boards that would not start their
# network. Anything added to this script must keep it.
recovery=$ROOT/etc/init.d/bpirouter-cfg-recovery
grep -Eq '^[[:space:]]*/usr/bin/bpirouter-apid --recover-config \|\| true[[:space:]]*$' "$recovery" ||
	fail "bpirouter-cfg-recovery does not run the recovery so that it cannot fail the boot"
if grep -Eq '^[[:space:]]*(exit[[:space:]]+[1-9]|return[[:space:]]+[1-9])' "$recovery"; then
	fail "bpirouter-cfg-recovery can exit non-zero; a boot-path script must never fail a service start"
fi

# ── 2. Runtime command dependencies ──────────────────────────────────────────

# The vocabulary is the point. A general shell parser would have to understand
# here-documents, embedded awk programs and functions sourced from
# /lib/functions/*.sh, and it would misfire on all three -- and a gate that
# cries wolf is a gate someone turns off. So this checks the failure that
# actually happens instead: an author reaches for a command that exists on
# every development machine and on no shipped image.
#
# These are exactly such commands. Of this list our own images provide fewer
# than half; none is a BusyBox default we can rely on. A hit must therefore be
# backed by a real file in this rootfs. `stat` is now selected explicitly for
# formal acceptance; the others remain available only when an equally explicit
# package selection or dependency provides them.
#
# This does not prove a script's dependencies are complete. It makes the
# recurring way they are incomplete a build failure.
ASSUMED_COMMANDS='stat timeout realpath readlink base64 seq column getopt
envsubst xxd od python python3 perl bc install truncate shuf tac nl comm join
paste split csplit fold fmt pr numfmt stdbuf pgrep pkill killall xargs curl
jq openssl rsync bzip2 xz zstd unzip nohup setsid flock logger'

# Whether the ROOTFS provides the command -- never the build host. A test that
# follows a symlink out of the tree answers the host's question, which is the
# exact confusion this gate exists to catch: the assembled image already
# contains absolute links (usr/sbin/ipset-translate -> /usr/sbin/ipset), and
# `[ -e ]` resolves those against the machine running the build.
resolves() {
	local word=$1 dir path target hops
	for dir in bin usr/bin sbin usr/sbin; do
		path="$ROOT/$dir/$word"
		# Walk the links ourselves, rewriting each target inside the root. An
		# absolute target is the device's own /, not the host's; letting the
		# shell follow it would resolve /usr/bin/stat to the host's coreutils.
		# The hop limit also breaks the loop an absolute self-link makes once
		# it is rewritten (/usr/bin/stat -> $ROOT/usr/bin/stat -> ...).
		hops=0
		while [ -L "$path" ] && [ "$hops" -lt 8 ]; do
			target=$(readlink "$path")
			case $target in
				/*) path="$ROOT$target" ;;
				*) path="${path%/*}/$target" ;;
			esac
			hops=$((hops + 1))
		done
		if [ ! -L "$path" ] && [ -e "$path" ]; then
			return 0
		fi
	done
	return 1
}

shell_files=
for shell_dir in \
	"$ROOT/etc/uci-defaults" "$ROOT/etc/init.d" "$ROOT/usr/libexec" \
	"$ROOT/usr/bin" "$ROOT/usr/sbin" "$ROOT/lib/bpirouter"; do
	[ -e "$shell_dir" ] || continue
	[ -d "$shell_dir" ] && [ ! -L "$shell_dir" ] || fail "product shell path is not a real directory: $shell_dir"
	found=$(find "$shell_dir" -maxdepth 1 -type f -name '*bpirouter*') \
		|| fail "cannot scan product shell directory: $shell_dir"
	[ -z "$found" ] || shell_files="${shell_files}${shell_files:+$'\n'}$found"
done

# Formal acceptance tools are delivered beside the image (bpirouter-ui
# scripts/acceptance-bundle.sh) and must never be packaged into it. They still
# run on this rootfs, so a supplied bundle is scanned against its command
# surface like the product's own shell; their names carry no bpirouter prefix
# and the shared library sits one level deeper.
acceptance_dir=$ROOT/usr/share/bpirouter/acceptance
[ ! -e "$acceptance_dir" ] && [ ! -L "$acceptance_dir" ] \
	|| fail "rootfs carries formal acceptance tools at /usr/share/bpirouter/acceptance"
if [ -n "$ACCEPTANCE_TOOLS" ]; then
	[ -d "$ACCEPTANCE_TOOLS" ] && [ ! -L "$ACCEPTANCE_TOOLS" ] \
		|| fail "acceptance tool bundle is redirected or not a directory: $ACCEPTANCE_TOOLS"
	[ -d "$ACCEPTANCE_TOOLS/lib" ] && [ ! -L "$ACCEPTANCE_TOOLS/lib" ] \
		|| fail "acceptance tool library directory is absent or redirected"
	acceptance_files=$(find "$ACCEPTANCE_TOOLS" -maxdepth 2 -type f -name '*.sh') \
		|| fail "cannot scan the acceptance tool bundle"
	[ -n "$acceptance_files" ] || fail "acceptance tool bundle contains no shell tools"
	shell_files="${shell_files}${shell_files:+$'\n'}$acceptance_files"
fi
shell_files=$(printf '%s\n' "$shell_files" | sort -u) \
	|| fail "cannot sort the product shell inventory"

scanned=0
missing=""
# read, not word-splitting: an unquoted expansion in a `for` list is also
# subject to pathname expansion, so a single glob character in a path would
# silently change which files get scanned.
while IFS= read -r script; do
	[ -n "$script" ] || continue
	head -1 "$script" | grep -Eq '^#!.*/(sh|ash|bash)' || continue
	scanned=$((scanned + 1))
	# Drop whole-line comments so a mention in prose is not a dependency.
	body=$(grep -v '^[[:space:]]*#' "$script" || true)
	for word in $ASSUMED_COMMANDS; do
		# Command position: start of line, or right after a separator that
		# opens one. Deliberately not a parser -- just enough to tell an
		# invocation from "$STAT_TOOL" or a word inside a string.
		printf '%s\n' "$body" |
			grep -Eq "(^|[;|&\`]|\\\$\()[[:space:]]*(if[[:space:]]+|then[[:space:]]+|else[[:space:]]+|do[[:space:]]+|!"'[[:space:]]+)*'"$word"'([[:space:]]|$)' ||
			continue
		resolves "$word" ||
			missing="$missing$(basename "$script") invokes '$word', which this rootfs does not provide"$'\n'
	done
done <<EOF
$shell_files
EOF

[ "$scanned" -gt 0 ] || fail "found no product shell scripts in the rootfs to scan"
if [ -n "$missing" ]; then
	printf '%s' "$missing" >&2
	fail "product shell depends on commands the image does not ship (see above)"
fi

echo "PASS: boot order boot:10 -> OTA-restore:10 -> cfg-recovery:11 -> firewall/mwan3:19 -> network:20 -> apid:99, an every-boot OTA restore, an unfailable generation recovery, ungated rc.common, and $scanned product shell scripts that invoke no command this rootfs lacks"
