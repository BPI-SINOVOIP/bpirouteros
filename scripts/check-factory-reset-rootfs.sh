#!/bin/bash
# Post-build FR-1 physical-entrypoint payload gate.
set -euo pipefail

ROOT=${1:-}
fail() { echo "FAIL: FR-1 rootfs: $*" >&2; exit 1; }
[ -n "$ROOT" ] && [ -d "$ROOT" ] || fail "target rootfs is required"

check_button_behavior() {
	local source=$1 tmp harness fakebin events console real_grep
	tmp=$(mktemp -d -t bpir-fr1-button-XXXXXX)
	trap 'rm -rf "$tmp"' RETURN
	harness="$tmp/reset"
	fakebin="$tmp/bin"
	events="$tmp/events"
	console="$tmp/console"
	real_grep=$(command -v grep)
	mkdir -p "$fakebin"
	# Execute the installed control flow, replacing only absolute platform
	# dependencies with observable functions.  Thresholds and branch order are
	# deliberately left untouched.
	sed \
		-e 's|^\. /lib/functions\.sh$|:|' \
		-e 's|/usr/libexec/bpirouter-factory-reset-button|fr_helper|' \
		-e "s|/dev/console|$console|g" \
		"$source" >"$harness"
	cat >"$fakebin/grep" <<EOF
#!/bin/sh
case "\$*" in
*'/proc/mounts'*)
	[ "\${FR_HAVE_OVERLAY:-0}" = 1 ] && printf '/dev/test /overlay f2fs rw 0 0\\n'
	;;
*) exec "$real_grep" "\$@" ;;
esac
EOF
	chmod 755 "$fakebin/grep"

	run_case() {
		local action=$1 seen=$2 overlay=$3 helper_rc=$4 expected_rc=$5 expected=$6 got rc
		: >"$events"
		set +e
		PATH="$fakebin:$PATH" FR_HAVE_OVERLAY="$overlay" FR_HELPER_RC="$helper_rc" \
			ACTION="$action" SEEN="$seen" FR_EVENTS="$events" \
			sh -c '
				sync() { printf "SYNC\\n" >>"$FR_EVENTS"; }
				reboot() { printf "REBOOT\\n" >>"$FR_EVENTS"; }
				fr_helper() { printf "HELPER\\n" >>"$FR_EVENTS"; return "$FR_HELPER_RC"; }
				. "$1"
			' sh "$harness" >/dev/null 2>&1
		rc=$?
		set -e
		got=$(cat "$events")
		[ "$rc" -eq "$expected_rc" ] || fail "button case $action/$seen/$overlay exited $rc, want $expected_rc"
		[ "$got" = "$expected" ] || fail "button case $action/$seen/$overlay events '$got', want '$expected'"
	}

	run_case pressed 0 0 0 0 ""
	run_case pressed 0 1 0 5 ""
	run_case released 0 1 0 0 $'SYNC\nREBOOT'
	run_case released 1 1 0 0 ""
	run_case released 4 1 0 0 ""
	run_case released 5 1 0 0 "HELPER"
	run_case released 5 1 1 0 "HELPER"
	run_case released 6 1 0 0 "HELPER"
	run_case released 6 1 1 0 "HELPER"
	run_case released 30 1 0 0 "HELPER"
	run_case released 5 0 0 0 ""
	rm -rf "$tmp"
	trap - RETURN
}

button="$ROOT/etc/rc.button/reset"
helper="$ROOT/usr/libexec/bpirouter-factory-reset-button"
apid="$ROOT/usr/bin/bpirouter-apid"
for file in "$button" "$helper" "$apid"; do
	[ -f "$file" ] || fail "missing /${file#"$ROOT"/}"
	[ -x "$file" ] || fail "/${file#"$ROOT"/} is not executable"
done

grep -Fq '/usr/libexec/bpirouter-factory-reset-button' "$button" ||
	fail "long press does not delegate to the shared apid path"
grep -Fq 'kill -USR1 "$pid"' "$helper" || fail "button helper does not request SIGUSR1"
grep -Fq 'pidof bpirouter-apid' "$helper" || fail "button helper does not require the apid identity"
grep -Fq 'readlink "/proc/$pid/exe"' "$helper" || fail "button helper does not read the live executable identity"
grep -Fq '[ "$exe" = /usr/bin/bpirouter-apid ]' "$helper" ||
	fail "button helper does not bind /proc identity to the installed apid"

if grep -Eq '(^|[[:space:]])(factoryreset|firstboot)([[:space:]]|$)' "$button" "$helper"; then
	fail "physical entrypoint contains an independent destructive fallback"
fi
grep -Fq 'reboot' "$button" || fail "short press no longer provides reboot-only behavior"
grep -aFq 'physical factory reset accepted; supervised reboot handoff pending' "$apid" ||
	fail "installed apid does not contain the shared physical reset handler"
check_button_behavior "$button"

echo "PASS: FR-1 rootfs reset-button timing delegates only long press to the shared apid transaction"
