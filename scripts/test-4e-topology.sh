#!/bin/bash
# Task 22-D steps 3/4: compile actual DTS, apply storage/WAN overlays and
# inspect a fixture FIT container (not a bootable kernel or firmware image).
# Requires a host dtc (DTC may name an existing OpenWrt host executable), cc,
# Python 3 and the downloaded pinned kernel archive. No OpenWrt tree mutation.
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
BUILD_DIR=$(dirname "$SCRIPT_DIR")
DTC=${DTC:-dtc}
command -v "$DTC" >/dev/null || { echo 'FAIL: set DTC to a host dtc executable' >&2; exit 1; }
TMP=$(mktemp -d -t bpir-4e-topology-test-XXXXXX)
trap 'rm -rf "$TMP"' EXIT
TREE="$TMP/kernel"
mkdir -p "$TREE"
OPENWRT_REV=f0a60eee2fe051741c643ea6118718aae1ef17fb
tar -xJf "$BUILD_DIR/openwrt/dl/linux-6.12.94.tar.xz" -C "$TREE" --strip-components=1 \
    linux-6.12.94/arch/arm64/boot/dts/mediatek linux-6.12.94/include/dt-bindings \
    linux-6.12.94/include/uapi/linux/input-event-codes.h linux-6.12.94/scripts/dtc/libfdt
git -C "$BUILD_DIR/openwrt" archive "$OPENWRT_REV" target/linux/mediatek/files-6.12/arch \
    | tar -x -C "$TREE" --strip-components=4
while IFS= read -r p; do
    git -C "$BUILD_DIR/openwrt" show "$OPENWRT_REV:$p" \
        | (cd "$TREE" && git apply --whitespace=nowarn --include='arch/arm64/boot/dts/mediatek/*' -)
done < <(git -C "$BUILD_DIR/openwrt" ls-tree -r --name-only "$OPENWRT_REV" \
    target/linux/mediatek/patches-6.12 | LC_ALL=C sort)

PATCHES="$BUILD_DIR/patches/bpi-r4-pro-4e"
for patch in 990-add-bpi-r4-pro-4e.patch 991-bpi-r4-pro-4e-wan-overlays.patch; do
    (cd "$TREE" && git apply "$PATCHES/kernel/$patch")
done
BASE=mt7988a-bananapi-bpi-r4-pro-4e
for name in "$BASE.dts" "$BASE-emmc.dtso" "$BASE-sd.dtso" "$BASE-wan-copper.dtso" "$BASE-wan-sfp.dtso"; do
    cpp -nostdinc -undef -D__DTS__ -x assembler-with-cpp \
        -I "$TREE/include" -I "$TREE/arch/arm64/boot/dts/mediatek" \
        "$TREE/arch/arm64/boot/dts/mediatek/$name" \
        | "$DTC" -@ -I dts -O dtb -o "$TMP/$name.dtb"
done
mkdir -p "$TMP/openwrt"
git -C "$BUILD_DIR/openwrt" archive "$OPENWRT_REV" \
    target/linux/mediatek/image/filogic.mk scripts/mkits.sh | tar -x -C "$TMP/openwrt"
(cd "$TMP/openwrt" && git apply "$PATCHES/base-files/451-filogic-add-bpi-r4-pro-4e.patch")
# Exercise the real OpenWrt FIT generator with non-executable fixture bytes.
cp "$TREE/include/dt-bindings/gpio/gpio.h" "$TMP/kernel-fixture"
bash "$TMP/openwrt/scripts/mkits.sh" -A arm64 -C none -a 0x46000000 -e 0x46000000 \
    -v fixture -k "$TMP/kernel-fixture" -D '4E fixture' -c "config-$BASE" \
    -d "$TMP/$BASE.dts.dtb" -o "$TMP/fixture.its" \
    -O "$BASE-emmc:$TMP/$BASE-emmc.dtso.dtb" -O "$BASE-sd:$TMP/$BASE-sd.dtso.dtb" \
    -O "$BASE-wan-copper:$TMP/$BASE-wan-copper.dtso.dtb" \
    -O "$BASE-wan-sfp:$TMP/$BASE-wan-sfp.dtso.dtb"
PATH="$(dirname "$(command -v "$DTC")"):$PATH" \
    "${MKIMAGE:-$BUILD_DIR/openwrt/staging_dir/host/bin/mkimage}" -f "$TMP/fixture.its" "$TMP/fixture.itb" >/dev/null
# Use upstream libfdt for reads and real overlay application; do not implement
# a second DTS/FDT parser in the test or merely grep the source for labels.
cc -shared -fPIC -I "$TREE/scripts/dtc/libfdt" \
    "$TREE"/scripts/dtc/libfdt/fdt*.c -o "$TMP/libfdt.so"
python3 - "$TMP" "$PATCHES/physical-ports.tsv" <<'PY'
import csv
import ctypes as C
import pathlib
import struct
import sys

tmp = pathlib.Path(sys.argv[1])
lib = C.CDLL(str(tmp / 'libfdt.so'))
void, integer, charp = C.c_void_p, C.c_int, C.c_char_p
for name, args, result in [
    ('fdt_path_offset', [void, charp], integer),
    ('fdt_getprop', [void, integer, charp, C.POINTER(integer)], void),
    ('fdt_first_subnode', [void, integer], integer),
    ('fdt_next_subnode', [void, integer], integer),
    ('fdt_get_phandle', [void, integer], C.c_uint32),
    ('fdt_open_into', [void, void, integer], integer),
    ('fdt_overlay_apply', [void, void], integer),
]:
    fn = getattr(lib, name)
    fn.argtypes, fn.restype = args, result

def node(tree, path):
    value = lib.fdt_path_offset(tree, path.encode())
    assert value >= 0, ('missing node', path, value)
    return value

def prop(tree, path, key):
    offset = node(tree, path) if isinstance(path, str) else path
    size = integer()
    ptr = lib.fdt_getprop(tree, offset, key.encode(), C.byref(size))
    return C.string_at(ptr, size.value) if ptr else None

def cells(tree, path, key):
    raw = prop(tree, path, key)
    assert raw is not None, (path, key)
    return struct.unpack('>' + 'I' * (len(raw) // 4), raw)

def text(tree, path, key):
    value = prop(tree, path, key)
    return value.rstrip(b'\0').decode() if value is not None else None

def children(tree, path):
    offset = lib.fdt_first_subnode(tree, node(tree, path))
    while offset >= 0:
        yield offset
        offset = lib.fdt_next_subnode(tree, offset)
    assert offset == -1, ('unexpected libfdt traversal error', offset)

def ref(tree, path, key, target):
    phandle = lib.fdt_get_phandle(tree, node(tree, target))
    assert phandle and cells(tree, path, key) == (phandle,), (path, key, target)

base = 'mt7988a-bananapi-bpi-r4-pro-4e'
raw = (tmp / (base + '.dts.dtb')).read_bytes()
tree = C.create_string_buffer(raw)
eth = '/soc/ethernet@15100000'
mdio = eth + '/mdio-bus'
mxl = mdio + '/switch@10'
internal = '/soc/switch@15020000'
assert text(tree, '/', 'compatible') == 'bananapi,bpi-r4-pro-4e\0mediatek,mt7988a'
assert cells(tree, mxl, 'reg') == (16,)
assert cells(tree, mxl, 'dsa,member') == (1, 0)
assert cells(tree, internal, 'dsa,member') == (0, 0)
assert {cells(tree, n, 'reg')[0] for n in children(tree, mdio)} == {15, 16}
assert text(tree, internal + '/ports/port@1', 'status') == 'disabled'
assert text(tree, internal + '/mdio/ethernet-phy@1', 'status') == 'disabled'

rows = list(csv.DictReader(pathlib.Path(sys.argv[2]).open(), delimiter='\t'))
# Freeze connector identities independently of both the DTS and TSV ordering.
assert [(r['panel'], r['label']) for r in rows] == [
    ('ETH1', 'mxl_lan0'), ('ETH2', 'mxl_lan1'), ('ETH3', 'mxl_lan2'),
    ('ETH4', 'mxl_lan3'), ('LAN-SFP+', 'sfp-lan'), ('ETH5', 'lan1'),
    ('ETH6', 'lan3'), ('ETH8', 'lan4'), ('ETH7', 'wan'), ('WAN-SFP+', 'wan')]
actual = set()
for controller, parent in [('internal', internal), ('mxl', mxl)]:
    for n in children(tree, parent + '/ports'):
        if text(tree, n, 'status') == 'disabled' or prop(tree, n, 'ethernet'):
            continue
        actual.add((controller, cells(tree, n, 'reg')[0], text(tree, n, 'label')))
expected = {(r['controller'], int(r['port']), r['label']) for r in rows if r['media'] == 'both'}
assert actual == expected, ('physical port map', actual, expected)
for port in range(1, 5):
    ref(tree, mxl + f'/ports/port@{port}', 'phy-handle', mxl + f'/mdio/ethernet-phy@{port - 1}')
ref(tree, mxl + '/ports/port@9', 'ethernet', eth + '/mac@2')
assert text(tree, mxl + '/ports/port@9', 'dsa-tag-protocol') == 'mxl862xx-8021q'
assert cells(tree, mxl + '/ports/port@9/fixed-link', 'speed') == (10000,)
ref(tree, mxl + '/ports/port@d', 'sfp', '/sfp-lan')
assert text(tree, mxl + '/ports/port@d', 'phy-mode') == '10gbase-r'
assert text(tree, mxl + '/ports/port@d', 'managed') == 'in-band-status'
assert prop(tree, mxl + '/ports/port@d', 'phy-handle') is None
assert text(tree, '/sfp-wan', 'status') == 'disabled'
assert prop(tree, eth + '/mac@1', 'phy-mode') is None
assert prop(tree, eth + '/mac@1', 'phy-handle') is None
assert prop(tree, eth + '/mac@1', 'sfp') is None
assert text(tree, eth + '/mac@1', 'status') == 'disabled'
assert text(tree, mdio + '/ethernet-phy@f', 'status') == 'disabled'
pio = '/soc/pinctrl@1001f000'
assert cells(tree, pio + '/lan-sfp-hog', 'gpios') == (54, 0)
assert prop(tree, pio + '/lan-sfp-hog', 'output-low') == b''
for cage, channel, pins in [('lan', 1, (69, 70, 21)), ('wan', 2, (1, 2, 0))]:
    path = '/sfp-' + cage
    ref(tree, path, 'i2c-bus', f'/soc/i2c@11005000/i2c-mux@70/i2c@{channel}')
    for key, pin, polarity in zip(['mod-def0-gpios', 'los-gpios', 'tx-disable-gpios'], pins, [1, 0, 0]):
        assert cells(tree, path, key)[1:] == (pin, polarity)

for medium in ['emmc', 'sd', 'snand']:
    merged = C.create_string_buffer(len(raw) + 65536)
    assert lib.fdt_open_into(tree, merged, len(merged)) == 0
    # The rescue system uses eMMC for the installation target, as in its env.
    storage = 'emmc' if medium == 'snand' else medium
    overlay = C.create_string_buffer((tmp / f'{base}-{storage}.dtso.dtb').read_bytes())
    assert lib.fdt_overlay_apply(merged, overlay) == 0, medium
    mmc = '/soc/mmc@11230000'
    assert text(merged, mmc, 'status') == 'okay'
    assert cells(merged, mmc, 'bus-width') == ((8,) if storage == 'emmc' else (4,))
    partitions = mmc + '/card@0/partitions'
    ref(merged, '/chosen', 'rootdisk-' + storage, partitions + '/block-partition-production')
    if storage == 'emmc':
        ref(merged, '/chosen', 'rootdisk-emmc-a', partitions + '/block-partition-production')
        ref(merged, '/chosen', 'rootdisk-emmc-b', partitions + '/block-partition-production_b')
        assert text(merged, partitions + '/block-partition-production_b', 'partname') == 'production_b'
    for selected in ['copper', 'sfp']:
        wan = C.create_string_buffer(len(merged))
        assert lib.fdt_open_into(merged, wan, len(wan)) == 0
        overlay = C.create_string_buffer((tmp / f'{base}-wan-{selected}.dtso.dtb').read_bytes())
        assert lib.fdt_overlay_apply(wan, overlay) == 0, (medium, selected)
        assert text(wan, '/chosen', 'bpirouter,wan-media') == selected
        mac = eth + '/mac@1'
        assert text(wan, mac, 'status') == 'okay'
        assert text(wan, mac, 'openwrt,netdev-name') == 'wan'
        assert cells(wan, pio + '/wan-media-hog', 'gpios') == (3, 0)
        if selected == 'copper':
            ref(wan, mac, 'phy-handle', mdio + '/ethernet-phy@f')
            assert prop(wan, mac, 'sfp') is None
            assert text(wan, mac, 'phy-mode') == 'internal'
            assert text(wan, '/sfp-wan', 'status') == 'disabled'
            assert text(wan, mdio + '/ethernet-phy@f', 'status') == 'okay'
            assert prop(wan, pio + '/wan-media-hog', 'output-low') == b''
        else:
            ref(wan, mac, 'sfp', '/sfp-wan')
            assert prop(wan, mac, 'phy-handle') is None
            assert text(wan, mac, 'phy-mode') == '10gbase-r'
            assert text(wan, mac, 'managed') == 'in-band-status'
            assert text(wan, mdio + '/ethernet-phy@f', 'status') == 'disabled'
            assert text(wan, '/sfp-wan', 'status') == 'okay'
            assert prop(wan, pio + '/wan-media-hog', 'output-high') == b''
        # WAN overlays must not change a LAN port or its label/status.
        for parent in [internal, mxl]:
            before = [(cells(merged, n, 'reg'), text(merged, n, 'label'), text(merged, n, 'status'))
                      for n in children(merged, parent + '/ports')]
            after = [(cells(wan, n, 'reg'), text(wan, n, 'label'), text(wan, n, 'status'))
                     for n in children(wan, parent + '/ports')]
            assert before == after

recipe = (tmp / 'openwrt/target/linux/mediatek/image/filogic.mk').read_text()
block = recipe.split('define Device/bananapi_bpi-r4-pro-4e\n', 1)[1].split('\nendef', 1)[0]
names = block.replace('\\\n', ' ').split('DEVICE_DTS_OVERLAY :=', 1)[1].split('\n', 1)[0].split()
assert names == [base + '-' + n for n in ['emmc', 'sd', 'wan-copper', 'wan-sfp']]
fit = C.create_string_buffer((tmp / 'fixture.itb').read_bytes())
assert text(fit, '/configurations', 'default') == 'config-' + base
for name in names:
    image = text(fit, '/configurations/' + name, 'fdt')
    assert prop(fit, '/images/' + image, 'data') == (tmp / (name + '.dtso.dtb')).read_bytes()
print('PASS: compiled 4E topology, six storage/WAN combinations and fixture FIT overlay payloads agree')
PY
