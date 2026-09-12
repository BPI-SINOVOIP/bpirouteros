#!/bin/bash
# Executable v1.5 gate for the immutable offload policy and the bandwidth
# execution-plane package graph. The migration owns exactly two firewall
# options; unrelated firewall state must never be rewritten by this test shim.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
BUILD_DIR=${BPIR_BUILD_DIR:-$(dirname "$SCRIPT_DIR")}
FEEDS_DIR=${BPIR_FEEDS_DIR:-$(dirname "$BUILD_DIR")/bpirouter-feeds}
INIT_SCRIPT="$FEEDS_DIR/net/bpirouter-base/files/etc/uci-defaults/13-bpirouter-offload-disabled"
BASE_MAKEFILE="$FEEDS_DIR/net/bpirouter-base/Makefile"
UI_MAKEFILE="$FEEDS_DIR/net/bpirouter-ui/Makefile"
OPENWRT_DIR=${BPIR_OPENWRT_DIR:-$BUILD_DIR/openwrt}
WED_PATCH="$BUILD_DIR/patches/common/openwrt/001-mt76-disable-wed.patch"
SRCVERSION_PATCH="$BUILD_DIR/patches/common/openwrt/002-kernel-enable-module-srcversion.patch"
PREPARE="$BUILD_DIR/scripts/prepare.sh"
GENERIC_KERNEL_CONFIG="$OPENWRT_DIR/target/linux/generic/config-6.12"

fail() { echo "FAIL: $*" >&2; exit 1; }
[ -x "$INIT_SCRIPT" ] || fail "missing executable offload migration: $INIT_SCRIPT"
[ -f "$WED_PATCH" ] || fail "missing WED package patch: $WED_PATCH"
[ -f "$SRCVERSION_PATCH" ] || fail "missing module srcversion kernel patch: $SRCVERSION_PATCH"

TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
STATE="$TEST_ROOT/state"
STAGED="$TEST_ROOT/staged"
CALLS="$TEST_ROOT/calls"
FAKE_UCI="$TEST_ROOT/uci"

cat >"$FAKE_UCI" <<'SH'
#!/bin/sh
set -eu
: "${FAKE_UCI_STATE:?} ${FAKE_UCI_STAGED:?} ${FAKE_UCI_CALLS:?}"
[ "${1:-}" = -q ] && shift
op=${1:-}; shift || true
printf '%s %s\n' "$op" "$*" >>"$FAKE_UCI_CALLS"
value() {
	key=$1
	if [ -f "$FAKE_UCI_STAGED" ]; then
		staged=$(sed -n "s/^${key}=//p" "$FAKE_UCI_STAGED" | tail -n 1)
		[ -z "$staged" ] || { printf '%s\n' "$staged"; return 0; }
	fi
	result=$(sed -n "s/^${key}=//p" "$FAKE_UCI_STATE" | tail -n 1)
	[ -n "$result" ] || return 1
	[ "$result" != __missing__ ] || return 1
	printf '%s\n' "$result"
}
case "$op" in
	show)
		[ "${FAKE_UCI_FAIL:-}" != show ] || exit 1
		count=$(value defaults_count)
		i=0
		while [ "$i" -lt "$count" ]; do
			printf "firewall.cfg%02d=defaults\n" "$i"
			i=$((i + 1))
		done
		printf "firewall.zone_lan=zone\nfirewall.zone_lan.name='lan'\n"
		;;
	get)
		case "$1" in
			'firewall.@defaults[0].flow_offloading') value software ;;
			'firewall.@defaults[0].flow_offloading_hw') value hardware ;;
			*) exit 1 ;;
		esac
		;;
	set)
		case "$1" in
			'firewall.@defaults[0].flow_offloading=0') key=software ;;
			'firewall.@defaults[0].flow_offloading_hw=0') key=hardware ;;
			*) exit 1 ;;
		esac
		[ "${FAKE_UCI_FAIL:-}" != "set-$key" ] || exit 1
		{ [ ! -f "$FAKE_UCI_STAGED" ] || cat "$FAKE_UCI_STAGED"; printf '%s=0\n' "$key"; } \
			>"$FAKE_UCI_STAGED.new"
		mv "$FAKE_UCI_STAGED.new" "$FAKE_UCI_STAGED"
		;;
	revert)
		rm -f "$FAKE_UCI_STAGED"
		;;
	commit)
		[ "${FAKE_UCI_FAIL:-}" != commit ] || exit 1
		for key in software hardware; do
			new=$(sed -n "s/^${key}=//p" "$FAKE_UCI_STAGED" 2>/dev/null | tail -n 1)
			[ -z "$new" ] || sed -i "s/^${key}=.*/${key}=${new}/" "$FAKE_UCI_STATE"
		done
		rm -f "$FAKE_UCI_STAGED"
		;;
	*) exit 1 ;;
esac
SH
chmod +x "$FAKE_UCI"

reset_state() {
	local count=$1 software=$2 hardware=$3
	printf 'defaults_count=%s\nsoftware=%s\nhardware=%s\nunrelated=preserve-me\n' \
		"$count" "$software" "$hardware" >"$STATE"
	rm -f "$STAGED"
	: >"$CALLS"
}

run_migration() {
	FAKE_UCI_STATE="$STATE" FAKE_UCI_STAGED="$STAGED" FAKE_UCI_CALLS="$CALLS" \
		BPIR_UCI_BIN="$FAKE_UCI" BPIR_LOGGER_BIN=true "$INIT_SCRIPT"
}

assert_no_writes() {
	if grep -Eq '^(set|commit|revert) ' "$CALLS"; then
		fail "unexpected UCI write: $(tr '\n' ';' <"$CALLS")"
	fi
}

assert_failed_without_write() {
	local name=$1
	if run_migration >"$TEST_ROOT/out" 2>"$TEST_ROOT/err"; then
		fail "$name was accepted"
	fi
	assert_no_writes
	grep -Fq 'unrelated=preserve-me' "$STATE" || fail "$name changed unrelated state"
}

# Missing values and either form of drift are normalized while preserving all
# unrelated state. A second invocation is a literal zero-write success.
for fixture in '__missing__ __missing__' '1 1' '1 0' '0 1'; do
	read -r software hardware <<<"$fixture"
	reset_state 1 "$software" "$hardware"
	run_migration
	grep -Fxq 'software=0' "$STATE" || fail "software offload was not disabled"
	grep -Fxq 'hardware=0' "$STATE" || fail "hardware offload was not disabled"
	grep -Fxq 'unrelated=preserve-me' "$STATE" || fail "unrelated state changed"
	[ "$(grep -c '^commit firewall$' "$CALLS")" -eq 1 ] || fail "migration did not commit exactly once"
	: >"$CALLS"
	run_migration
	assert_no_writes
done

# A canonical state is idempotent from the first invocation.
reset_state 1 0 0
run_migration
assert_no_writes

# Ambiguous structure and unsupported values fail before any UCI write.
for count in 0 2; do
	reset_state "$count" 0 0
	assert_failed_without_write "$count defaults sections"
done
for key in software hardware; do
	reset_state 1 0 0
	sed -i "s/^${key}=.*/${key}=invalid/" "$STATE"
	assert_failed_without_write "invalid $key value"
done

# A partial stage or failed commit is reverted; the durable state is unchanged.
for failure in set-hardware commit; do
	reset_state 1 1 1
	before=$(sha256sum "$STATE" | awk '{print $1}')
	if FAKE_UCI_FAIL="$failure" run_migration >"$TEST_ROOT/out" 2>"$TEST_ROOT/err"; then
		fail "$failure was accepted"
	fi
	[ "$(sha256sum "$STATE" | awk '{print $1}')" = "$before" ] || fail "$failure changed durable state"
	[ ! -e "$STAGED" ] || fail "$failure left staged UCI state"
	grep -Fq 'revert firewall' "$CALLS" || fail "$failure did not revert its stage"
done

# Bind the policy and execution dependencies into every formal board payload.
grep -Fq '13-bpirouter-offload-disabled $(1)/etc/uci-defaults/' "$BASE_MAKEFILE" || \
	fail "bpirouter-base does not install the offload migration"
for driver in mt7915e mt7996e; do
	grep -Fq "MODPARAMS.$driver:=wed_enable=0" "$WED_PATCH" ||
		fail "$driver WED is not disabled in its own kmod autoload package"
done
grep -Fq 'apply_patches "$BUILD_DIR/patches/common/openwrt"    openwrt' "$PREPARE" ||
	fail "prepare.sh does not apply the WED package patch"
if ! git -C "$OPENWRT_DIR" apply --check "$WED_PATCH" 2>/dev/null &&
	! git -C "$OPENWRT_DIR" apply --reverse --check "$WED_PATCH" 2>/dev/null; then
	fail "WED package patch does not apply to the locked OpenWrt source"
fi
[ "$(git -C "$OPENWRT_DIR" apply --numstat "$SRCVERSION_PATCH" 2>/dev/null)" = \
	$'1\t1\ttarget/linux/generic/config-6.12' ] ||
	fail "module srcversion patch must change only generic config-6.12 by one line"
git -C "$OPENWRT_DIR" apply --reverse --check "$SRCVERSION_PATCH" 2>/dev/null ||
	fail "module srcversion patch is not applied to the prepared OpenWrt tree"
grep -Eq 'DEPENDS:=.*\+sqm-scripts([[:space:]]|$)' "$UI_MAKEFILE" || \
	fail "bpirouter-ui no longer pulls the SQM execution dependencies"
grep -Eq 'DEPENDS:=.*\+tc([[:space:]]|$)' "$OPENWRT_DIR/feeds/packages/net/sqm-scripts/Makefile" || \
	fail "sqm-scripts no longer selects tc"
grep -Eq 'DEPENDS:=.*\+kmod-ifb([[:space:]]|$)' "$OPENWRT_DIR/feeds/packages/net/sqm-scripts/Makefile" || \
	fail "sqm-scripts no longer selects kmod-ifb"
SCHED_MAKEFILE="$OPENWRT_DIR/package/kernel/linux/modules/netsupport.mk"
IPROUTE_MAKEFILE="$OPENWRT_DIR/package/network/utils/iproute2/Makefile"
for module in sch_htb sch_ingress cls_matchall act_mirred; do
	grep -Eq "^SCHED_MODULES_CORE = .*${module}([[:space:]]|$)" "$SCHED_MAKEFILE" ||
		fail "kmod-sched-core no longer carries $module"
done
grep -Eq '^[[:space:]]*DEPENDS:=\+kmod-sched-core' "$IPROUTE_MAKEFILE" ||
	fail "the selected tc provider no longer pulls kmod-sched-core"
grep -Fxq 'CONFIG_NET_SCH_FQ_CODEL=y' "$GENERIC_KERNEL_CONFIG" || \
	fail "the locked kernel no longer builds the aggregate fq_codel leaf"
grep -Fxq -- '-# CONFIG_MODULE_SRCVERSION_ALL is not set' "$SRCVERSION_PATCH" && \
	grep -Fxq -- '+CONFIG_MODULE_SRCVERSION_ALL=y' "$SRCVERSION_PATCH" || \
	fail "the kernel patch omits module identity metadata required by formal acceptance"
grep -Fxq 'CONFIG_MODULE_SRCVERSION_ALL=y' "$GENERIC_KERNEL_CONFIG" || \
	fail "the prepared kernel config omits module identity metadata required by formal acceptance"
if grep -Fxq '# CONFIG_MODULE_SRCVERSION_ALL is not set' "$GENERIC_KERNEL_CONFIG"; then
	fail "the prepared kernel config still disables module srcversion metadata"
fi
grep -Eq '^CONFIG_PACKAGE_tc=y$' "$BUILD_DIR/config/common.config" || \
	fail "the six-board common config omits tc"
for board in bpi-r3-mini bpi-r3 bpi-r4-lite bpi-r4-pro bpi-r4 openwrt-one; do
	config="$BUILD_DIR/config/$board.config"
	[ -f "$config" ] || fail "missing board config: $board.config"
	grep -Eq '^CONFIG_PACKAGE_bpirouter-base=y$' "$config" || fail "$board omits bpirouter-base"
	grep -Eq '^CONFIG_PACKAGE_bpirouter-ui=y$' "$config" || fail "$board omits bpirouter-ui"
done
for gate in "$BUILD_DIR/scripts/build-full.sh" "$BUILD_DIR/scripts/build-image.sh"; do
	grep -Fq '"$SCRIPT_DIR/test-offload-disabled.sh"' "$gate" || \
		fail "$(basename "$gate") does not run the offload gate"
done
for driver in mt7915e mt7996e; do
	grep -Fq "'$driver wed_enable=0'" "$BUILD_DIR/scripts/build-image.sh" ||
		fail "quick ImageBuilder overlay does not disable WED for $driver"
done

echo "PASS: v1.5 offload migration, WED policy, zero-write idempotence, failure rollback, and six-board bandwidth dependency contract"
