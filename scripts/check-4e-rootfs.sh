#!/bin/sh
# Inspect assembled 4E contents, not the current checkout's config requests.
set -eu
ROOT=${1:?usage: check-4e-rootfs.sh <assembled-rootfs>}
fail() { echo "FAIL: $*" >&2; exit 1; }
[ -d "$ROOT" ] || fail "rootfs missing: $ROOT"
for path in etc/init.d/bpirouter-as21xxx-fw etc/uci-defaults/99-bpirouter-as21xxx-fw lib/firmware/as21x1x_fw.bin; do
    [ ! -e "$ROOT/$path" ] || fail "4E carries 8X-only $path"
done
if find "$ROOT/lib/modules" -name as21xxx.ko | grep -q .; then
    fail "4E carries the AS21 PHY module"
fi
for module in mxl862xx_dsa.ko tag_mxl862xx.ko tag_mxl862xx_8021q.ko; do
    find "$ROOT/lib/modules" -type f -name "$module" | grep -q . \
        || fail "4E lacks $module"
done
[ -s "$ROOT/lib/firmware/mediatek/mt7988/i2p5ge-phy-pmb.bin" ] \
    || fail "4E lacks internal 2.5G PHY firmware"
# Standard kmodloader performs the one boot-time load, without any AS21 gate.
loads=$(find "$ROOT/etc/modules.d" -type f -exec grep -hEx 'mxl862xx_dsa' {} + | wc -l)
[ "$loads" -eq 1 ] || fail "4E needs exactly one MxL autoload entry, found $loads"
echo 'PASS: 4E rootfs has MxL autoload and internal PHY firmware, without AS21 payload'
