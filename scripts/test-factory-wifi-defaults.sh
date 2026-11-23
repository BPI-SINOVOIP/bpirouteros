#!/bin/bash
# SYS-45: factory defaults leave every radio off and write no shared key, so
# nothing transmits until the setup wizard sets the owner's password. Runs a
# path-rewritten copy of 99-bpirouter-defaults against a recording fake uci.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
BUILD_DIR=${BPIR_BUILD_DIR:-$(dirname "$SCRIPT_DIR")}
FEEDS_DIR=${BPIR_FEEDS_DIR:-$BUILD_DIR/feeds/bpirouter}
DEFAULTS="$FEEDS_DIR/net/bpirouter-base/files/etc/uci-defaults/99-bpirouter-defaults"

fail() { echo "FAIL: $*" >&2; exit 1; }
[ -f "$DEFAULTS" ] || fail "missing $DEFAULTS"

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/etc" "$T/sys/eth0"
printf '02:00:00:12:32:c6\n' >"$T/sys/eth0/address"
export CALLS="$T/calls"

cat >"$T/bin/uci" <<'SH'
#!/bin/sh
[ "$1" = -q ] && shift
printf '%s\n' "$*" >>"$CALLS"
case "$1 $2" in
'show wireless')
	printf "wireless.radio0=wifi-device\nwireless.radio1=wifi-device\nwireless.radio2=wifi-device\n" ;;
'get wireless.radio0.band') echo 2g ;;
'get wireless.radio1.band') echo 5g ;;
'get wireless.radio2.band') echo 6g ;;
esac
exit 0
SH
chmod +x "$T/bin/uci"

sed -e "s#/etc/bpirouter#$T/etc/bpirouter#g" -e "s#/etc/banner#$T/etc/banner#g" \
	-e "s#/sys/class/net#$T/sys#g" "$DEFAULTS" >"$T/defaults"
PATH="$T/bin:$PATH" sh "$T/defaults" || fail "defaults script failed"

for radio in radio0 radio1 radio2; do
	grep -qx "set wireless.$radio.disabled=1" "$CALLS" || fail "$radio is not disabled"
	grep -qx "set wireless.default_$radio.disabled=1" "$CALLS" || fail "default_$radio is not disabled"
	grep -qx "delete wireless.default_$radio.key" "$CALLS" || fail "default_$radio keeps a key"
	grep -q "^set wireless\.$radio\.disabled=0$\|^set wireless\.default_$radio\.disabled=0$" "$CALLS" &&
		fail "$radio is enabled at some point"
done
grep -q '^set wireless\.[^ ]*\.key=' "$CALLS" && fail "a Wi-Fi key is written by the factory defaults"
grep -qx 'set wireless.default_radio2.encryption=sae' "$CALLS" || fail "6 GHz is not WPA3-only"
grep -qx 'set wireless.default_radio0.ssid=BpiRouter_2.4G_32C6' "$CALLS" || fail "2.4 GHz SSID changed"
grep -qx 'commit wireless' "$CALLS" || fail "wireless defaults were not committed"
[ -f "$T/etc/bpirouter/.provisioned" ] || fail "provisioned marker missing"

echo "PASS: factory defaults keep all radios off and write no shared Wi-Fi key"
