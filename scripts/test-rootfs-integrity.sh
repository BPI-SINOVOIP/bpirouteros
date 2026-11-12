#!/bin/bash
# Anti-mutation suite for check-rootfs-integrity.sh.
#
# The gate's whole reason to exist is one historical defect: shipped images had
# no `stat`, so the two ownership predicates in the D21 shell fence were
# constant-false and every board refused to start networking at boot once it
# had written a multi-WAN config. A gate that cannot reproduce that verdict is
# decoration, so the central case here restores the exact deleted file from git
# history and requires the gate to reject the rootfs because of it.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
BUILD_DIR=${BPIR_BUILD_DIR:-$(dirname "$SCRIPT_DIR")}
GATE="$SCRIPT_DIR/check-rootfs-integrity.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
[ -x "$GATE" ] || fail "gate is missing or not executable: $GATE"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
ROOT="$WORK/root"
BUNDLE="$WORK/bundle"
GATE_EXTRA=()

# A minimal rootfs shaped like the board's BusyBox command surface. It starts
# without `stat` so each test can prove whether a product script correctly
# forces an explicit provider into the assembled image.
build_rootfs() {
	rm -rf "$ROOT"
	mkdir -p "$ROOT"/{bin,sbin,usr/bin,usr/sbin,etc/config,etc/init.d,etc/rc.d,etc/uci-defaults,etc/modules.d,usr/libexec,lib/bpirouter,lib/modules/6.12-test,usr/share/nftables.d/ruleset-pre}
	: >"$ROOT/etc/config/bpirouter"
	: >"$ROOT/etc/config/tailscale"
	mkdir -p "$ROOT/usr/share/tailscale"
	for notice in LICENSE tailscale.md go.mod go.sum modules.txt; do
		printf 'fixture %s\n' "$notice" >"$ROOT/usr/share/tailscale/$notice"
	done
	: >"$ROOT/usr/share/nftables.d/ruleset-pre/90-bpirouter-s2s.nft"
	printf '#!/bin/sh\nexit 0\n' >"$ROOT/usr/sbin/tailscaled"
	chmod +x "$ROOT/usr/sbin/tailscaled"
	cat >"$ROOT/etc/init.d/tailscale" <<'SH'
#!/bin/sh /etc/rc.common
START=80
start_service() {
	/usr/bin/bpirouter-apid --s2s-service=check || return
	procd_set_param command /usr/bin/bpirouter-apid --s2s-service=run
}
SH
	chmod +x "$ROOT/etc/init.d/tailscale"
	for applet in sh mktemp mkdir chmod rm sync cat ls sed grep printf; do
		: >"$ROOT/bin/$applet"; chmod +x "$ROOT/bin/$applet"
	done
	for applet in find logger flock awk; do
		: >"$ROOT/usr/bin/$applet"; chmod +x "$ROOT/usr/bin/$applet"
	done
	: >"$ROOT/sbin/uci"; chmod +x "$ROOT/sbin/uci"

	write_init() {
		printf '#!/bin/sh /etc/rc.common\nSTART=%s\nstart() { :; }\n' "$2" >"$ROOT/etc/init.d/$1"
		chmod +x "$ROOT/etc/init.d/$1"
	}
	write_init boot 10
	write_init firewall 19
	write_init mwan3 19
	write_init network 20
	write_init bpirouter-api 99
	cat >"$ROOT/etc/init.d/bpirouter-vpn-prepare" <<'SH'
#!/bin/sh /etc/rc.common
START=18
PROG=${BPIR_VPN_PREPARE_PROG:-/usr/bin/bpirouter-apid}
boot() {
	"$PROG" --prepare-vpn-firewall || logger -t bpirouter-vpn-prepare "VPN firewall preparation failed; keeping existing configuration" || true
	return 0
}
start() { return 0; }
stop() { return 0; }
SH
	chmod +x "$ROOT/etc/init.d/bpirouter-vpn-prepare"
	ln -sf ../init.d/bpirouter-vpn-prepare "$ROOT/etc/rc.d/S18bpirouter-vpn-prepare"
	printf '#!/bin/sh\n# prepare-vpn-firewall\nexit 0\n' >"$ROOT/usr/bin/bpirouter-apid"
	chmod +x "$ROOT/usr/bin/bpirouter-apid"
	cat >"$ROOT/etc/init.d/bpirouter-ota-restore" <<'SH'
#!/bin/sh /etc/rc.common
START=10
PROG=${BPIR_OTA_RESTORE_PROG:-/usr/libexec/bpirouter-ota-restore}
boot() {
	"$PROG"
}
start() { return 0; }
stop() { return 0; }
SH
	chmod +x "$ROOT/etc/init.d/bpirouter-ota-restore"
	printf '#!/bin/sh\nexit 0\n' >"$ROOT/usr/libexec/bpirouter-ota-restore"
	chmod +x "$ROOT/usr/libexec/bpirouter-ota-restore"
	cat >"$ROOT/etc/init.d/bpirouter-cfg-recovery" <<'SH'
#!/bin/sh /etc/rc.common
START=11

boot() {
	/usr/bin/bpirouter-apid --recover-config || true
}

start() {
	return 0
}
SH
	chmod +x "$ROOT/etc/init.d/bpirouter-cfg-recovery"
	ln -sf ../init.d/bpirouter-cfg-recovery "$ROOT/etc/rc.d/S11bpirouter-cfg-recovery"
	ln -sf ../init.d/boot "$ROOT/etc/rc.d/S10boot"
	ln -sf ../init.d/bpirouter-ota-restore "$ROOT/etc/rc.d/S10bpirouter-ota-restore"
	ln -sf ../init.d/firewall "$ROOT/etc/rc.d/S19firewall"
	ln -sf ../init.d/mwan3 "$ROOT/etc/rc.d/S19mwan3"
	ln -sf ../init.d/network "$ROOT/etc/rc.d/S20network"
	ln -sf ../init.d/bpirouter-api "$ROOT/etc/rc.d/S99bpirouter-api"

	for canon in 11-bpirouter-mwan3-canonical 12-bpirouter-sqm-canonical; do
		printf '#!/bin/sh\nuci -q export mwan3 >/dev/null\nexit 0\n' >"$ROOT/etc/uci-defaults/$canon"
		chmod +x "$ROOT/etc/uci-defaults/$canon"
	done
	cat >"$ROOT/etc/uci-defaults/13-bpirouter-offload-disabled" <<'SH'
#!/bin/sh
uci -q set firewall.@defaults[0].flow_offloading=0
uci -q set firewall.@defaults[0].flow_offloading_hw=0
exit 0
SH
	chmod +x "$ROOT/etc/uci-defaults/13-bpirouter-offload-disabled"
	printf '%s\n' 'mt7915e wed_enable=0' >"$ROOT/etc/modules.d/mt7915e"
	: >"$ROOT/lib/modules/6.12-test/mt7915e.ko"
	for module in sch_htb sch_ingress cls_matchall act_mirred ifb; do
		: >"$ROOT/lib/modules/6.12-test/$module.ko"
	done
	: >"$ROOT/usr/libexec/bpirouter-mwan3-strict.awk"
	: >"$ROOT/usr/libexec/bpirouter-sqm-strict.awk"
	printf '#!/bin/sh\nexit 0\n' >"$ROOT/etc/rc.common"
	# The acceptance tool bundle lives beside the image, never inside it.
	rm -rf "$BUNDLE"
	mkdir -p "$BUNDLE/lib"
	printf '#!/bin/sh\nexit 0\n' >"$BUNDLE/lib/acceptance-common.sh"
	chmod +x "$BUNDLE/lib/acceptance-common.sh"
	GATE_EXTRA=()
}

must_pass() {
	"$GATE" "$ROOT" "${GATE_EXTRA[@]}" >/dev/null 2>&1 || fail "$1"
}
must_refuse() {
	local why=$1; shift
	if "$GATE" "$ROOT" "${GATE_EXTRA[@]}" >"$WORK/out" 2>&1; then
		cat "$WORK/out" >&2
		fail "$why"
	fi
}

must_refuse_with_path() {
	local why=$1 path_prefix=$2
	if PATH="$path_prefix:$PATH" "$GATE" "$ROOT" "${GATE_EXTRA[@]}" >"$WORK/out" 2>&1; then
		cat "$WORK/out" >&2
		fail "$why"
	fi
}

# ── Baseline ────────────────────────────────────────────────────────────────
build_rootfs
must_pass "a well-formed rootfs was rejected"

for path in etc/config/tailscale usr/sbin/tailscaled \
	usr/share/nftables.d/ruleset-pre/90-bpirouter-s2s.nft; do
	build_rootfs
	rm "$ROOT/$path"
	must_refuse "missing S2S prerequisite /$path was accepted"
	grep -Fq "missing /$path" "$WORK/out" || fail "wrong rejection for /$path"
done
build_rootfs
printf '#!/bin/sh\nstart_service() { /usr/sbin/tailscaled; }\n' >"$ROOT/etc/init.d/tailscale"
must_refuse "unmanaged tailscale init was accepted"
grep -Fq 'tailscale init does not use the product lifecycle' "$WORK/out" || fail "wrong init rejection"

build_rootfs
GATE_EXTRA=(--acceptance-tools "$BUNDLE")
must_pass "a well-formed rootfs with a well-formed acceptance bundle was rejected"

build_rootfs
mkdir -p "$ROOT/usr/share/bpirouter/acceptance/lib"
printf '#!/bin/sh\nexit 0\n' >"$ROOT/usr/share/bpirouter/acceptance/lib/acceptance-common.sh"
must_refuse "the gate accepted a rootfs that still carries the acceptance tools"
grep -Fq "rootfs carries formal acceptance tools" "$WORK/out" ||
	{ cat "$WORK/out" >&2; fail "the gate rejected packaged acceptance tools for the wrong reason"; }

build_rootfs
GATE_EXTRA=(--acceptance-tool "$BUNDLE")
must_refuse "the gate accepted a malformed acceptance bundle option"
grep -Fq "usage:" "$WORK/out" ||
	{ cat "$WORK/out" >&2; fail "the gate rejected the malformed option for the wrong reason"; }

# ── The historical defect, verbatim ─────────────────────────────────────────
# Restore the deleted fence from git history rather than a hand-written
# imitation: the point is that this exact shipped file is caught.
build_rootfs
DELETED=net/bpirouter-base/files/lib/bpirouter/d21-preflight.sh
FEEDS_DIR=${BPIR_FEEDS_DIR:-$(dirname "$BUILD_DIR")/bpirouter-feeds}
if git -C "$FEEDS_DIR" rev-parse --verify HEAD >/dev/null 2>&1 &&
	git -C "$FEEDS_DIR" show "HEAD:$DELETED" >"$ROOT/lib/bpirouter/bpirouter-d21-preflight.sh" 2>/dev/null &&
	[ -s "$ROOT/lib/bpirouter/bpirouter-d21-preflight.sh" ]; then
	chmod +x "$ROOT/lib/bpirouter/bpirouter-d21-preflight.sh"
	must_refuse "the gate accepted the shipped fence whose 'stat' the rootfs never provided"
	grep -Fq "invokes 'stat'" "$WORK/out" ||
		{ cat "$WORK/out" >&2; fail "the gate rejected the shipped fence but not because of the missing 'stat'"; }
	echo "  historical defect reproduced from git history and caught"
else
	# After the deletion commit lands this file is no longer at HEAD. Keep the
	# assertion alive with the same predicate the original used.
	printf '#!/bin/sh\nowned() { [ "$(stat -c %%u "$1")" = 0 ]; }\nowned /etc\n' \
		>"$ROOT/lib/bpirouter/bpirouter-d21-preflight.sh"
	chmod +x "$ROOT/lib/bpirouter/bpirouter-d21-preflight.sh"
	must_refuse "the gate accepted a product script calling 'stat', which no image provides"
	grep -Fq "invokes 'stat'" "$WORK/out" ||
		{ cat "$WORK/out" >&2; fail "the gate rejected the script but not because of the missing 'stat'"; }
	echo "  historical defect reproduced from its predicate and caught"
fi

# The gate keys on the dependency, not on a file name or a blocklist: the same
# script passes once the rootfs actually provides the command.
build_rootfs
printf '#!/bin/sh\nstat -c %%u /etc\n' >"$ROOT/usr/libexec/bpirouter-needs-stat"
chmod +x "$ROOT/usr/libexec/bpirouter-needs-stat"
must_refuse "the gate accepted a product script calling a command the rootfs lacks"
: >"$ROOT/usr/bin/stat"; chmod +x "$ROOT/usr/bin/stat"
must_pass "the gate still rejected after the rootfs provided 'stat'"

# Formal acceptance runners run on this rootfs although they are delivered
# beside it and their names do not carry the bpirouter prefix. A supplied
# bundle stays in the scan so the exact missing-stat defect cannot return.
build_rootfs
printf '#!/bin/sh\nstat -Lc %%d:%%i /usr/bin/bpirouter-apid\n' \
	>"$BUNDLE/lib/acceptance-common.sh"
chmod +x "$BUNDLE/lib/acceptance-common.sh"
GATE_EXTRA=(--acceptance-tools "$BUNDLE")
must_refuse "the gate ignored a missing command used by a formal acceptance runner"
grep -Fq "acceptance-common.sh invokes 'stat'" "$WORK/out" ||
	{ cat "$WORK/out" >&2; fail "the gate rejected the acceptance runner for the wrong reason"; }

build_rootfs
mv "$BUNDLE/lib" "$BUNDLE/lib.real"
ln -s lib.real "$BUNDLE/lib"
GATE_EXTRA=(--acceptance-tools "$BUNDLE")
must_refuse "the gate accepted a redirected formal acceptance library directory"
grep -Fq "acceptance tool library directory is absent or redirected" "$WORK/out" ||
	{ cat "$WORK/out" >&2; fail "the gate rejected the redirected acceptance library for the wrong reason"; }

# A failed traversal or inventory sort is a gate failure, not an empty result.
# Wrappers delegate every unrelated call so these cases reach the exact branch
# under test after all earlier rootfs checks have succeeded.
build_rootfs
GATE_EXTRA=(--acceptance-tools "$BUNDLE")
FAIL_FIND_BIN="$WORK/fail-find-bin"
mkdir -p "$FAIL_FIND_BIN"
REAL_FIND=$(command -v find)
cat >"$FAIL_FIND_BIN/find" <<EOF
#!/bin/sh
case "\$1" in
	*/bundle) exit 73 ;;
esac
exec "$REAL_FIND" "\$@"
EOF
chmod +x "$FAIL_FIND_BIN/find"
must_refuse_with_path "the gate swallowed an acceptance find failure" "$FAIL_FIND_BIN"
grep -Fq "cannot scan the acceptance tool bundle" "$WORK/out" ||
	{ cat "$WORK/out" >&2; fail "the gate rejected the failed acceptance traversal for the wrong reason"; }

build_rootfs
FAIL_SORT_BIN="$WORK/fail-sort-bin"
mkdir -p "$FAIL_SORT_BIN"
printf '#!/bin/sh\nexit 73\n' >"$FAIL_SORT_BIN/sort"
chmod +x "$FAIL_SORT_BIN/sort"
must_refuse_with_path "the gate swallowed a product shell inventory sort failure" "$FAIL_SORT_BIN"
grep -Fq "cannot sort the product shell inventory" "$WORK/out" ||
	{ cat "$WORK/out" >&2; fail "the gate rejected the failed inventory sort for the wrong reason"; }

# The same question asked of the ROOTFS, not of the build host. An assembled
# image really does contain absolute links (usr/sbin/ipset-translate ->
# /usr/sbin/ipset); following one lands on the host, where coreutils provides
# every command the device is missing -- which is the precise confusion that
# let the missing 'stat' ship in the first place.
build_rootfs
printf '#!/bin/sh\nstat -c %%u /etc\n' >"$ROOT/usr/libexec/bpirouter-needs-stat"
chmod +x "$ROOT/usr/libexec/bpirouter-needs-stat"
rm -f "$ROOT/usr/bin/stat"
ln -sf /usr/bin/stat "$ROOT/usr/bin/stat"
[ -e /usr/bin/stat ] || fail "this build host has no /usr/bin/stat to mis-resolve against"
must_refuse "the gate resolved an absolute symlink against the build host instead of the rootfs"
grep -Fq "invokes 'stat'" "$WORK/out" ||
	{ cat "$WORK/out" >&2; fail "the gate rejected the rootfs but not for the unresolvable 'stat'"; }

# A symlink that does resolve inside the root is the command being provided --
# that is how every busybox applet appears.
rm -f "$ROOT/usr/bin/stat"
ln -sf ../../bin/busybox "$ROOT/usr/bin/stat"
: >"$ROOT/bin/busybox"; chmod +x "$ROOT/bin/busybox"
must_pass "the gate rejected a command provided by a relative applet symlink"

# A dangling link inside the root provides nothing.
rm -f "$ROOT/usr/bin/stat"
ln -sf ../../bin/absent-applet "$ROOT/usr/bin/stat"
must_refuse "the gate accepted a command whose symlink target is not in the rootfs"

# A command invoked in a position the scan has to recognise. `; do stat ...`
# on one line is the shape a one-line loop takes, and a gate that only looks at
# line starts would wave it through.
build_rootfs
printf '#!/bin/sh\nfor f in /etc/config/*; do stat -c %%u "$f"; done\n' \
	>"$ROOT/usr/libexec/bpirouter-loop-stat"
chmod +x "$ROOT/usr/libexec/bpirouter-loop-stat"
must_refuse "the gate missed a command invoked after 'do' on one line"
grep -Fq "invokes 'stat'" "$WORK/out" ||
	{ cat "$WORK/out" >&2; fail "the gate rejected the loop script for the wrong reason"; }

# ── The gate must not fire on things that are not external commands ─────────
build_rootfs
cat >"$ROOT/usr/libexec/bpirouter-shapes" <<'SH'
#!/bin/sh
helper_fn() { echo "$1"; }
helper_fn one
VAR=value uci -q get network.lan.proto
if [ -n "$VAR" ]; then printf '%s\n' "$VAR"; fi
while read -r line; do :; done </dev/null
out=$(find /etc -maxdepth 1)
[ -z "$out" ] || grep -q x /dev/null || true
exit 0
SH
chmod +x "$ROOT/usr/libexec/bpirouter-shapes"
must_pass "the gate fired on builtins, keywords, assignments or a locally defined function"

# ── The other half: an ungated rc.common ────────────────────────────────────
build_rootfs
printf '#!/bin/sh\nbpir_d21_preflight "$svc" start 1 || exit 1\n' >"$ROOT/etc/rc.common"
must_refuse "the gate accepted an rc.common that can refuse a service start"

# ── Boot order still guarded ────────────────────────────────────────────────
build_rootfs
rm -f "$ROOT/etc/config/bpirouter"
must_refuse "the gate accepted a rootfs whose first firewall reload cannot read product settings"

build_rootfs
rm -f "$ROOT/usr/libexec/bpirouter-ota-restore"
must_refuse "the gate accepted a rootfs without the every-boot OTA restore helper"

build_rootfs
rm -f "$ROOT/etc/rc.d/S10bpirouter-ota-restore"
must_refuse "the gate accepted a rootfs where OTA restore is never run"

build_rootfs
sed -i 's/^START=10/START=12/' "$ROOT/etc/init.d/bpirouter-ota-restore"
must_refuse "the gate accepted OTA restore after config generation recovery"

build_rootfs
sed -i 's/^[[:space:]]*"\$PROG"[[:space:]]*$/\treturn 0/' "$ROOT/etc/init.d/bpirouter-ota-restore"
must_refuse "the gate accepted an OTA init service that never runs its helper"

build_rootfs
printf '#!/bin/sh\nexit 0\n' >"$ROOT/etc/uci-defaults/10-bpirouter-ota-restore"
chmod +x "$ROOT/etc/uci-defaults/10-bpirouter-ota-restore"
must_refuse "the gate accepted OTA restore packaged as a one-shot uci-default"

build_rootfs
ln -s /missing-ota-restore "$ROOT/etc/uci-defaults/10-bpirouter-ota-restore"
must_refuse "the gate accepted a dangling one-shot OTA restore uci-default"

build_rootfs
sed -i 's/^START=20/START=18/' "$ROOT/etc/init.d/network"
must_refuse "the gate accepted network starting before the canonicalized configs"

build_rootfs
rm -f "$ROOT/etc/uci-defaults/12-bpirouter-sqm-canonical"
must_refuse "the gate accepted a rootfs with no sqm canonicalizer"

build_rootfs
rm -f "$ROOT/etc/uci-defaults/13-bpirouter-offload-disabled"
must_refuse "the gate accepted a rootfs with no Flow Offload disable migration"

build_rootfs
sed -i 's/flow_offloading=0/flow_offloading=1/' "$ROOT/etc/uci-defaults/13-bpirouter-offload-disabled"
must_refuse "the gate accepted a migration that enables software Flow Offload"

build_rootfs
rm -f "$ROOT/etc/modules.d/mt7915e"
must_refuse "the gate accepted a rootfs with no explicit WED module policy"

build_rootfs
sed -i 's/mt7915e wed_enable=0/mt7915e wed_enable=1/' "$ROOT/etc/modules.d/mt7915e"
must_refuse "the gate accepted mt7915e with WED enabled"

build_rootfs
mv "$ROOT/lib/modules/6.12-test/mt7915e.ko" "$ROOT/lib/modules/6.12-test/mt7996e.ko"
mv "$ROOT/etc/modules.d/mt7915e" "$ROOT/etc/modules.d/mt7996e"
sed -i 's/mt7915e/mt7996e/' "$ROOT/etc/modules.d/mt7996e"
must_pass "the gate rejected the correctly disabled mt7996e board variant"

build_rootfs
rm -f "$ROOT/lib/modules/6.12-test/cls_matchall.ko"
must_refuse "the gate accepted a rootfs without the aggregate matchall classifier"

build_rootfs
rm -f "$ROOT/etc/rc.d/S99bpirouter-api"
must_refuse "the gate accepted a rootfs where apid is never started"

# ── Generation recovery must exist and must be unable to fail a boot ────────
build_rootfs
rm -f "$ROOT/etc/init.d/bpirouter-cfg-recovery" "$ROOT/etc/rc.d/S11bpirouter-cfg-recovery"
must_refuse "the gate accepted a rootfs that never recovers its config generation"

build_rootfs
sed -i 's/^START=11/START=21/' "$ROOT/etc/init.d/bpirouter-cfg-recovery"
must_refuse "the gate accepted recovery running after the services that read the config"

# The failure mode the withdrawn fence had: a boot-path script that can exit
# non-zero and take the whole network down with it.
build_rootfs
sed -i 's|--recover-config \|\| true|--recover-config|' "$ROOT/etc/init.d/bpirouter-cfg-recovery"
must_refuse "the gate accepted a boot-path recovery whose failure propagates"

build_rootfs
printf '\texit 1\n' >>"$ROOT/etc/init.d/bpirouter-cfg-recovery"
must_refuse "the gate accepted a boot-path recovery that can exit non-zero"

# The image must retain both dependency evidence and upstream notices.
for fault in missing wrong_order disabled stale_binary; do
	build_rootfs
	case "$fault" in
		missing) rm "$ROOT/etc/init.d/bpirouter-vpn-prepare" ;;
		wrong_order) sed -i 's/START=18/START=21/' "$ROOT/etc/init.d/bpirouter-vpn-prepare" ;;
		disabled) rm "$ROOT/etc/rc.d/S18bpirouter-vpn-prepare" ;;
		stale_binary) printf '#!/bin/sh\nexit 0\n' >"$ROOT/usr/bin/bpirouter-apid" ;;
	esac
	must_refuse "the gate accepted VPN preparation defect: $fault"
done

for notice in LICENSE tailscale.md go.mod go.sum modules.txt; do
	build_rootfs
	rm "$ROOT/usr/share/tailscale/$notice"
	must_refuse "the gate accepted a missing Tailscale notice or dependency record: $notice"
done

# Quick mode must refuse before preparation, downloads or image assembly.
# The official ImageBuilder cannot provide the product's patched Tailscale.
BUILD_IMAGE="$SCRIPT_DIR/build-image.sh"
for board in bpi-r4 openwrt-one; do
	if bash "$BUILD_IMAGE" --board "$board" >"$WORK/quick-refusal" 2>&1; then
		fail "quick ImageBuilder unexpectedly accepted $board"
	fi
	grep -Fq "Quick ImageBuilder builds are unsupported" "$WORK/quick-refusal" ||
		fail "quick mode failed after reaching an unrelated prerequisite"
done

echo "PASS: rootfs integrity gate reproduces the missing-command defect, tolerates shell that is not an external command, and still guards boot order and an ungated rc.common"
