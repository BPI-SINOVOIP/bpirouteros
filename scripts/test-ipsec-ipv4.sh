#!/bin/bash
# KI-10: the boot helper restricts OpenWrt's stock IPsec forward rules to IPv4
# once per firewall configuration, leaves any changed rule alone, records the
# migration in the firewall config only when every step succeeded, and never
# commits someone else's pending firewall change. The fake uci keeps committed state as
# `uci -X show` lines and staged changes in a second file; like real uci it
# shows anonymous sections by position (@rule[N]) unless -X is given.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
BUILD_DIR=${BPIR_BUILD_DIR:-$(dirname "$SCRIPT_DIR")}
FEEDS_DIR=${BPIR_FEEDS_DIR:-$BUILD_DIR/feeds/bpirouter}
HELPER="$FEEDS_DIR/net/bpirouter-base/files/usr/libexec/bpirouter-ipsec-ipv4"
INIT="$FEEDS_DIR/net/bpirouter-base/files/etc/init.d/bpirouter-ipsec-ipv4"

fail() { echo "FAIL: $*" >&2; exit 1; }
[ -x "$HELPER" ] || fail "missing executable helper: $HELPER"
[ -x "$INIT" ] || fail "missing executable init script: $INIT"

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
export FAKE_STATE="$T/state" FAKE_STAGED="$T/staged" FAKE_CALLS="$T/calls" \
	FAKE_COMMIT_FAILS="$T/commit-fails" FAKE_SHOW_FAILS="$T/show-fails" \
	FAKE_SET_FAILS="$T/set-fails" FAKE_CHANGES_FAILS="$T/changes-fails"

cat >"$T/uci" <<'SH'
#!/bin/sh
# Like real uci: options first; without -X anonymous sections are shown by
# position (firewall.@rule[N]), with -X by internal name (firewall.cfgXXXX).
X=0
while :; do
	case "$1" in
	-q) shift ;;
	-X) X=1; shift ;;
	*) break ;;
	esac
done
op=$1; shift
printf '%s %s X=%s\n' "$op" "$*" "$X" >>"$FAKE_CALLS"
positional() {
	# Map firewall.cfgXXXX to firewall.@<type>[index] in declaration order.
	awk -F'[.=]' '
		NF >= 3 && $0 ~ /^firewall\.[^.=]+=/ { type = substr($0, index($0, "=") + 1); n[type]++; idx[$2] = "@" type "[" n[type] - 1 "]" }
		{ lines[NR] = $0; sec[NR] = $2 }
		END { for (i = 1; i <= NR; i++) { l = lines[i]; s = sec[i]; if (s in idx) sub("^firewall\\." s, "firewall." idx[s], l); print l } }
	' "$FAKE_STATE"
}
quote() { printf '%s' "$1" | sed 's/\./\\./g'; }
case "$op" in
get)
	sed -n "s/^$(quote "$1")='\(.*\)'\$/\1/p" "$FAKE_STATE" | grep . ;;
show)
	[ -f "$FAKE_SHOW_FAILS" ] && exit 1
	key=$1
	if [ "$key" = firewall ]; then
		if [ "$X" = 1 ]; then cat "$FAKE_STATE"; else positional; fi
	else
		grep -E "^$(quote "$key")(=|\.)" "$FAKE_STATE" || true
	fi ;;
changes)
	[ -f "$FAKE_CHANGES_FAILS" ] && exit 1
	[ -f "$FAKE_STAGED" ] && cat "$FAKE_STAGED"; true ;;
set)
	[ -f "$FAKE_SET_FAILS" ] && grep -qF "$1" "$FAKE_SET_FAILS" && exit 1
	k=${1%%=*}; v=${1#*=}
	case $k in
	*.*.*) printf "%s='%s'\n" "$k" "$v" >>"$FAKE_STAGED" ;;
	*) printf '%s=%s\n' "$k" "$v" >>"$FAKE_STAGED" ;;
	esac ;;
commit)
	[ -f "$FAKE_COMMIT_FAILS" ] && exit 1
	if [ -f "$FAKE_STAGED" ]; then
		while IFS= read -r line; do
			k=${line%%=*}
			grep -v "^$(quote "$k")=" "$FAKE_STATE" >"$FAKE_STATE.new" || true
			printf '%s\n' "$line" >>"$FAKE_STATE.new"
			mv "$FAKE_STATE.new" "$FAKE_STATE"
		done <"$FAKE_STAGED"
		rm -f "$FAKE_STAGED"
	fi ;;
revert)
	rm -f "$FAKE_STAGED" ;;
*) exit 1 ;;
esac
SH
chmod +x "$T/uci"
# The helper runs before logd; its messages go to the kernel log.
export BPIR_UCI_BIN="$T/uci" BPIR_KMSG="$T/log"

stock() {
	cat >"$FAKE_STATE" <<'EOF'
firewall.cfg01=defaults
firewall.cfg01.input='REJECT'
firewall.cfg0a92bd=rule
firewall.cfg0a92bd.name='Allow-DHCP-Renew'
firewall.cfg0a92bd.src='wan'
firewall.cfg0a92bd.proto='udp'
firewall.cfg0a92bd.dest_port='68'
firewall.cfg0a92bd.target='ACCEPT'
firewall.cfg0c92bd=rule
firewall.cfg0c92bd.name='Allow-IPSec-ESP'
firewall.cfg0c92bd.src='wan'
firewall.cfg0c92bd.dest='lan'
firewall.cfg0c92bd.proto='esp'
firewall.cfg0c92bd.target='ACCEPT'
firewall.cfg0d92bd=rule
firewall.cfg0d92bd.name='Allow-ISAKMP'
firewall.cfg0d92bd.src='wan'
firewall.cfg0d92bd.dest='lan'
firewall.cfg0d92bd.dest_port='500'
firewall.cfg0d92bd.proto='udp'
firewall.cfg0d92bd.target='ACCEPT'
EOF
	rm -f "$FAKE_STAGED" "$FAKE_CALLS" "$FAKE_COMMIT_FAILS" "$FAKE_SHOW_FAILS" \
		"$FAKE_SET_FAILS" "$FAKE_CHANGES_FAILS" "$T/log"
}
recorded() { grep -qx "firewall.bpirouter_migration.ipsec_ipv4='1'" "$FAKE_STATE"; }
family() { grep -c "^firewall\.$1\.family='ipv4'$" "$FAKE_STATE" || true; }
commits() { grep -c '^commit ' "$FAKE_CALLS" || true; }
run() { "$HELPER" || fail "helper exited non-zero"; }

# 1. Stock rules are restricted to IPv4 and the migration recorded, in one commit;
#    nothing else changes.
stock
cp "$FAKE_STATE" "$T/before"
run
[ "$(family cfg0c92bd)" = 1 ] && [ "$(family cfg0d92bd)" = 1 ] || fail "stock rules were not restricted to IPv4"
[ "$(commits)" = 1 ] || fail "expected exactly one commit"
recorded || fail "a completed migration was not recorded"
diff <(sort "$T/before") <(grep -v -e "\.family='ipv4'$" -e '^firewall\.bpirouter_migration[.=]' "$FAKE_STATE" | sort) >/dev/null ||
	fail "the helper changed something besides the two family options and its record"
grep -Fq 'restricted the stock IPsec forward rules to IPv4' "$T/log" || fail "no log entry for the change"
cp "$FAKE_STATE" "$T/migrated"

# 2. Later boots leave the rules alone, including after the user removes the
#    family again (LuCI's "IPv4 and IPv6" deletes the option).
: >"$FAKE_CALLS"
run
[ "$(commits)" = 0 ] || fail "a repeated boot committed again"
grep -q '^set ' "$FAKE_CALLS" && fail "a repeated boot staged a change"
grep -v "\.family='ipv4'$" "$FAKE_STATE" >"$T/s" && mv "$T/s" "$FAKE_STATE"
run
[ "$(family cfg0c92bd)" = 0 ] && [ "$(family cfg0d92bd)" = 0 ] ||
	fail "the user's IPv4-and-IPv6 choice was overwritten on a later boot"

# 3. Restoring an older firewall config (a v1.6.0 backup: stock rules, no record)
#    over a migrated one brings the migration back.
cp "$T/migrated" "$FAKE_STATE"
stock
run
[ "$(family cfg0c92bd)" = 1 ] && [ "$(family cfg0d92bd)" = 1 ] || fail "a restored older config was not migrated"
recorded || fail "the migration of a restored config was not recorded"

# 4. A changed rule is the user's: ESP with an extra option stays, ISAKMP is restricted.
stock
printf "firewall.cfg0c92bd.enabled='0'\n" >>"$FAKE_STATE"
run
[ "$(family cfg0c92bd)" = 0 ] || fail "a changed ESP rule was modified"
[ "$(family cfg0d92bd)" = 1 ] || fail "the stock ISAKMP rule was not restricted"

# 5. A changed value (different port) and an explicit family are left alone; the
#    completed check is still recorded.
stock
sed -i "s/dest_port='500'/dest_port='4500'/" "$FAKE_STATE"
printf "firewall.cfg0c92bd.family='any'\n" >>"$FAKE_STATE"
run
[ "$(family cfg0c92bd)" = 0 ] && [ "$(family cfg0d92bd)" = 0 ] || fail "a changed rule was modified"
grep -q '^set firewall\.cfg' "$FAKE_CALLS" && fail "staged a rule change with nothing to restrict"
recorded || fail "a completed check with nothing to change was not recorded"

# 6. No IPsec rules at all: nothing to restrict, the check is recorded.
stock
grep -v -e cfg0c92bd -e cfg0d92bd "$FAKE_STATE" >"$T/s" && mv "$T/s" "$FAKE_STATE"
run
grep -q '^set firewall\.cfg' "$FAKE_CALLS" && fail "staged a rule change without any IPsec rule"
recorded || fail "a completed check without IPsec rules was not recorded"

# 7. Someone else's pending firewall change, or pending changes that cannot be
#    read: nothing is staged, reverted or committed, and the next boot retries.
for failure in pending unreadable; do
	stock
	case $failure in
	pending) printf "firewall.cfg01.forward='DROP'\n" >"$FAKE_STAGED" ;;
	unreadable) : >"$FAKE_CHANGES_FAILS" ;;
	esac
	run
	grep -q -e '^set ' -e '^revert ' "$FAKE_CALLS" && fail "$failure: touched the staged firewall changes"
	[ "$(commits)" = 0 ] || fail "$failure: committed"
	recorded && fail "$failure: a skipped run was recorded as done"
	[ "$failure" != pending ] || grep -Fq 'uncommitted changes' "$T/log" || fail "no log entry for the skipped run"
	rm -f "$FAKE_STAGED" "$FAKE_CHANGES_FAILS"
	run
	[ "$(family cfg0c92bd)" = 1 ] && recorded || fail "$failure: the next boot did not retry"
done

# 8. A failure to read, stage or commit records nothing, reverts what was
#    staged, exits 0, and the next boot migrates.
for failure in show set-esp set-record commit; do
	stock
	case $failure in
	show) : >"$FAKE_SHOW_FAILS" ;;
	set-esp) printf 'firewall.cfg0c92bd.family=ipv4\n' >"$FAKE_SET_FAILS" ;;
	set-record) printf 'firewall.bpirouter_migration.ipsec_ipv4=1\n' >"$FAKE_SET_FAILS" ;;
	commit) : >"$FAKE_COMMIT_FAILS" ;;
	esac
	run
	[ "$(family cfg0c92bd)" = 0 ] && [ "$(family cfg0d92bd)" = 0 ] || fail "$failure: rules changed despite the failure"
	recorded && fail "$failure: a failed run was recorded as done"
	[ ! -s "$FAKE_STAGED" ] || fail "$failure: staged changes were left behind"
	rm -f "$FAKE_SHOW_FAILS" "$FAKE_SET_FAILS" "$FAKE_COMMIT_FAILS"
	run
	[ "$(family cfg0c92bd)" = 1 ] && [ "$(family cfg0d92bd)" = 1 ] && recorded ||
		fail "$failure: the next boot did not migrate"
done

# 9. The init script runs the helper at boot (START=12) and never fails the boot,
#    even if the helper does; a plain start does not run it.
grep -qx 'START=12' "$INIT" || fail "init is not START=12"
printf '#!/bin/sh\n: >"%s/ran"\nexit 3\n' "$T" >"$T/failing"; chmod +x "$T/failing"
( BPIR_IPSEC_IPV4_PROG="$T/failing"; . "$INIT"; boot ) 2>/dev/null ||
	fail "a failing helper failed the boot"
[ -f "$T/ran" ] || fail "the boot does not run the helper"
rm -f "$T/ran"
( BPIR_IPSEC_IPV4_PROG="$T/failing"; . "$INIT"; start ) 2>/dev/null || fail "a plain start failed"
[ ! -f "$T/ran" ] || fail "a plain start ran the helper"

echo "PASS: stock IPsec forward rules restricted to IPv4 once per firewall config, recorded in it with the change; restored older configs migrate again, the user's later family choice stays, changed or explicit-family rules are left alone, and pending changes or any failed read, stage or commit record nothing and retry; the boot never fails"
