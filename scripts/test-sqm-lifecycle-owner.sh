#!/bin/bash
# Execute the patched package scripts, without touching host services or tc.
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
BUILD_DIR=${BPIR_BUILD_DIR:-$(dirname "$SCRIPT_DIR")}
SOURCE=${1:-$BUILD_DIR/openwrt/build_dir/target-aarch64_cortex-a53_musl/sqm-scripts-1.7.2}
PATCH="$BUILD_DIR/patches/common/packages/002-sqm-product-lifecycle-owner.patch"
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
mkdir -p "$TEST_ROOT/feed" "$TEST_ROOT/src/platform/openwrt" "$TEST_ROOT/src/src"
if [ "${1:-}" = --rootfs ]; then
    # Exercise shipped script bodies, not a reconstruction from source.
    cp "$2/etc/init.d/sqm" "$TEST_ROOT/src/platform/openwrt/sqm-init"
    cp "$2/etc/hotplug.d/iface/11-sqm" "$TEST_ROOT/src/platform/openwrt/sqm-hotplug"
    cp "$2/usr/lib/sqm/start-sqm" "$2/usr/lib/sqm/stop-sqm" "$2/usr/lib/sqm/functions.sh" "$TEST_ROOT/src/src/"
    cp "$2/usr/lib/sqm/run.sh" "$TEST_ROOT/src/platform/openwrt/sqm-run.sh"
else
    git -C "$TEST_ROOT/feed" apply --whitespace=nowarn "$PATCH"
    cp "$SOURCE/platform/openwrt/sqm-init" "$SOURCE/platform/openwrt/sqm-hotplug" "$TEST_ROOT/src/platform/openwrt/"
    cp "$SOURCE/src/start-sqm" "$SOURCE/src/stop-sqm" "$SOURCE/src/functions.sh" "$TEST_ROOT/src/src/"
    cp "$SOURCE/src/run-openwrt.sh" "$TEST_ROOT/src/platform/openwrt/sqm-run.sh"
    INNER_PATCH="$TEST_ROOT/feed/net/sqm-scripts/patches/100-bpirouter-lifecycle-owner.patch"
    if patch -s --dry-run --forward -d "$TEST_ROOT/src" -p1 < "$INNER_PATCH" >/dev/null 2>&1; then
        patch -s --forward -d "$TEST_ROOT/src" -p1 < "$INNER_PATCH"
    else
        # A prepared build tree may already contain the same package patch.
        patch -s --dry-run --reverse -d "$TEST_ROOT/src" -p1 < "$INNER_PATCH" >/dev/null
    fi
fi

# Substitute only OS boundaries; the branch/function bodies remain shipped code.
sed -e "s@/usr/bin/bpirouter-apid@$TEST_ROOT/apid@g" \
    -e "s@/lib/functions.sh@$TEST_ROOT/functions@g" \
    -e "s@/usr/lib/sqm/run.sh@trace_sqm@g" \
    -e 's@/etc/init.d/sqm enabled@true@g' \
    "$TEST_ROOT/src/platform/openwrt/sqm-hotplug" > "$TEST_ROOT/hotplug"
sed -e "s@/usr/bin/bpirouter-apid@$TEST_ROOT/apid@g" \
    -e "s@/usr/lib/sqm/run.sh@trace_sqm@g" \
    "$TEST_ROOT/src/platform/openwrt/sqm-init" > "$TEST_ROOT/init"
export TRACE="$TEST_ROOT/trace"
cat > "$TEST_ROOT/functions" <<'EOF'
config_load() { :; }
config_foreach() { :; }
uci() { :; }
trace_sqm() { echo "$*" >> "$TRACE"; }
EOF
touch "$TEST_ROOT/apid"
chmod +x "$TEST_ROOT/apid"
for mode in product stock; do
    [ "$mode" = product ] || chmod -x "$TEST_ROOT/apid"
    for action in ifup ifdown; do
        : > "$TRACE"
        ACTION="$action" DEVICE=br-wan INTERFACE=wan sh "$TEST_ROOT/hotplug"
        if [ "$mode" = product ]; then
            [ ! -s "$TRACE" ] || { echo "FAIL: hotplug bypassed apid"; exit 1; }
        elif [ "$action" = ifup ]; then
            [ "$(cat "$TRACE")" = $'stop br-wan\nstart br-wan' ]
        else
            [ "$(cat "$TRACE")" = 'stop br-wan' ]
        fi
    done
    : > "$TRACE"
    sh -c '. "$1/functions"; . "$1/init"; start() { start_service "$@"; }; procd_add_reload_trigger() { echo trigger >> "$TRACE"; }; boot; service_triggers' sh "$TEST_ROOT"
    if [ "$mode" = product ]; then
        [ ! -s "$TRACE" ] || { echo "FAIL: boot/reload trigger bypassed apid"; exit 1; }
    else
        [ "$(cat "$TRACE")" = $'start\ntrigger' ]
    fi
done
echo 'PASS: product SQM hotplug/boot/config-trigger are passive; stock behavior is preserved'

# Exercise the real run.sh -> stop-sqm -> sqm_stop chain. Only kernel I/O
# and configuration paths are replaced. Failed deletion must keep the state
# file so the next run.sh stop still invokes cleanup.
NATIVE="$TEST_ROOT/native"
mkdir -p "$NATIVE/sysfs/br-wan"
cp "$TEST_ROOT/src/src/functions.sh" "$NATIVE/real-functions.sh"
for spec in 'src/start-sqm:start-sqm' 'src/stop-sqm:stop-sqm' 'platform/openwrt/sqm-run.sh:run.sh'; do
    sed -e "s@/usr/bin/bpirouter-apid@$TEST_ROOT/apid@g" \
        -e "s@/sys/class/net/@$NATIVE/sysfs/@g" \
        -e "s@. /lib/functions.sh@: # no UCI helpers needed for stop@g" \
        -e "s@/etc/sqm/sqm.conf@$NATIVE/sqm.conf@g" \
        "$TEST_ROOT/src/${spec%%:*}" > "$NATIVE/${spec#*:}"
    chmod +x "$NATIVE/${spec#*:}"
done
cat > "$NATIVE/sqm.conf" <<EOF
SQM_LIB_DIR='$NATIVE'
SQM_STATE_DIR='$NATIVE'
SQM_QDISC_STATE_DIR='$NATIVE'
SQM_DEBUG=0
SQM_SYSLOG=0
EOF
cat > "$NATIVE/functions.sh" <<'EOF'
. "$SQM_LIB_DIR/real-functions.sh"
check_state_dir() { :; }
get_ifb_associated_with_if() { echo ifb4br-wan; }
ipt_log_rewind() { :; }
sqm_trace() { :; }
sqm_debug() { :; }
sqm_log() { :; }
sqm_warn() { :; }
sqm_error() { :; }
test_tc() {
    if [ "$1" = -j ]; then
        [ "${FAIL_READ:-0}" = 0 ] || return 1
        if [ "${BAD_JSON:-0}" = 1 ]; then echo broken; return; fi
        if [ -f "$SQM_STATE_DIR/root" ]; then
            echo '[{"kind":"cake","handle":"1:"}]'
        else
            echo '[{"kind":"fq_codel","handle":"0:"}]'
        fi
        return
    fi
    echo "tc $*" >> "$SQM_STATE_DIR/io"
    [ "${FAIL_TC:-0}" = 0 ] || return 1
    rm -f "$SQM_STATE_DIR/root"
}
test_ip() {
    echo "ip $*" >> "$SQM_STATE_DIR/io"
    [ "${FAIL_IFB:-0}" = 0 ] || return 1
    rm -f "$SQM_STATE_DIR/sysfs/ifb4br-wan"
}
# Keep the shipped logging wrappers: unlike the binary, they swallow stdout.
TC=tc_wrapper
TC_BINARY=test_tc
IP=ip_wrapper
IP_BINARY=test_ip
SILENT=0
EOF
printf 'DOWNLINK=30000\nCLEANUP=0\n' > "$NATIVE/defaults.sh"
printf '# piece_of_cake uses the default sqm_stop, loaded unchanged above.\n' > "$NATIVE/piece_of_cake.qos"
chmod +x "$TEST_ROOT/apid"
for failure in FAIL_TC FAIL_IFB FAIL_READ BAD_JSON; do
    printf 'IFACE=br-wan\nSCRIPT=piece_of_cake.qos\n' > "$NATIVE/br-wan.state"
    touch "$NATIVE/root" "$NATIVE/sysfs/ifb4br-wan"
    : > "$NATIVE/io"
    if env "$failure=1" sh "$NATIVE/run.sh" stop > /dev/null 2>&1; then
        echo "FAIL: $failure was reported as successful cleanup" >&2; exit 1
    fi
    [ -f "$NATIVE/br-wan.state" ] || { echo "FAIL: $failure discarded cleanup state"; exit 1; }
    first=$(wc -l < "$NATIVE/io")
    sh "$NATIVE/run.sh" stop
    [ "$(wc -l < "$NATIVE/io")" -gt "$first" ]
    [ ! -e "$NATIVE/root" ] && [ ! -e "$NATIVE/sysfs/ifb4br-wan" ] && [ ! -e "$NATIVE/br-wan.state" ] || {
        echo "FAIL: retry after $failure did not finish cleanup"; exit 1;
    }
done
echo 'PASS: shipped SQM stop retains failed cleanup state and retries after tc/IFB/read/JSON failures'

# Use the real generic start sequence: ingress preparation fails after egress
# has created a root. The old script never reached write_state_file here.
cat > "$NATIVE/defaults.sh" <<'EOF'
[ -n "$IFACE" ] || IFACE=br-wan
[ -n "$SCRIPT" ] || SCRIPT=piece_of_cake.qos
UPLINK=10000
DOWNLINK=30000
CLEANUP=0
EOF
cat > "$NATIVE/piece_of_cake.qos" <<'EOF'
ipt_log_restart() { :; }
do_modules() { :; }
verify_qdisc() { [ "$1" != ingress ]; }
get_ifb_for_if() { echo ifb4br-wan; }
egress() {
    touch "$SQM_STATE_DIR/root"
    [ -f "$SQM_STATE_DIR/br-wan.state" ] || return 1
}
EOF
IFACE=br-wan SCRIPT=piece_of_cake.qos sh "$NATIVE/start-sqm"
[ -f "$NATIVE/root" ] && [ -f "$NATIVE/br-wan.state" ] || {
    echo 'FAIL: partial start left queues without cleanup state'; exit 1;
}
sh "$NATIVE/run.sh" stop
[ ! -e "$NATIVE/root" ] && [ ! -e "$NATIVE/br-wan.state" ] || {
    echo 'FAIL: partial start could not be cleaned up'; exit 1;
}
echo 'PASS: partial SQM startup retains the existing stop identity and can be cleaned up'
if [ "${1:-}" != --rootfs ]; then
    mkdir -p "$TEST_ROOT/root/etc/init.d" "$TEST_ROOT/root/etc/hotplug.d/iface" "$TEST_ROOT/root/usr/lib/sqm"
    cp "$TEST_ROOT/src/platform/openwrt/sqm-init" "$TEST_ROOT/root/etc/init.d/sqm"
    cp "$TEST_ROOT/src/platform/openwrt/sqm-hotplug" "$TEST_ROOT/root/etc/hotplug.d/iface/11-sqm"
    cp "$TEST_ROOT/src/src/start-sqm" "$TEST_ROOT/src/src/stop-sqm" "$TEST_ROOT/src/src/functions.sh" "$TEST_ROOT/root/usr/lib/sqm/"
    cp "$TEST_ROOT/src/platform/openwrt/sqm-run.sh" "$TEST_ROOT/root/usr/lib/sqm/run.sh"
    bash "$0" --rootfs "$TEST_ROOT/root"
fi
