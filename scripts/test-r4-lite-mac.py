#!/usr/bin/env python3
# Copyright (C) 2026 Ning <mimallaus@gmail.com>
"""Compile the Lite DT and run U-Boot's MAC fixup on old and patched trees.

Requires host cc and prepared Linux/U-Boot sources (including host dtc).
All patch application and native execution take place in a temporary directory.
"""
import argparse
from pathlib import Path
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--openwrt', type=Path, required=True)
parser.add_argument('--kernel', type=Path, required=True)
parser.add_argument('--uboot', type=Path, required=True)
args = parser.parse_args()
build = Path(__file__).resolve().parents[1]
revision = 'f0a60eee2fe051741c643ea6118718aae1ef17fb'
openwrt, kernel, uboot = (p.resolve() for p in (args.openwrt, args.kernel, args.uboot))
dtc = uboot / 'scripts/dtc/dtc'
libfdt = uboot / 'scripts/dtc/libfdt'
source = (uboot / 'boot/fdt_support.c').read_text()
fixup = source.split('void fdt_fixup_ethernet(void *fdt)', 1)[1].split('\nint fdt_record_loadable', 1)[0]
assert 'CONFIG_NET=y' in (uboot / '.config').read_text()
assert 'fdt_fixup_ethernet(blob);' in (uboot / 'boot/image-fdt.c').read_text()
assert 'FDT_SEQ_MACADDR_FROM_ENV' not in (uboot / 'include/configs/mt7987.h').read_text()

# Execute the upstream function unchanged. Substitute only environment access
# and small U-Boot wrappers around libc/libfdt, not the alias traversal.
harness = r'''
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <libfdt.h>
#define ARP_HLEN 6
#define hextoul(s, e) strtoul(s, e, 16)
static char *saved_mac;
static char *env_get(const char *key) {
    return strcmp(key, "ethaddr") == 0 ? saved_mac : NULL;
}
static int trailing_strtol(const char *s) {
    size_t i = strlen(s);
    while (i && s[i-1] >= '0' && s[i-1] <= '9') i--;
    return s[i] ? atoi(s+i) : -1;
}
static void do_fixup_by_path(void *fdt, const char *path, const char *name,
                             const void *data, int len, int create) {
    int node = fdt_path_offset(fdt, path);
    assert(node >= 0);
    if (create || fdt_getprop(fdt, node, name, NULL))
        assert(fdt_setprop(fdt, node, name, data, len) == 0);
}
'''
harness += 'void fdt_fixup_ethernet(void *fdt)' + fixup
harness += r'''
int main(int argc, char **argv) {
    assert(argc == 4);
    char input[262144], blob[524288];
    FILE *file = fopen(argv[1], "rb");
    assert(file);
    size_t size = fread(input, 1, sizeof(input), file);
    assert(size > 0 && size < sizeof(input));
    fclose(file);
    assert(fdt_open_into(input, blob, sizeof(blob)) == 0);
    saved_mac = strcmp(argv[2], "absent") ? argv[2] : NULL;
    fdt_fixup_ethernet(blob);
    /* Resolve by the real GMAC register, independently of the new alias. */
    int lan = fdt_path_offset(blob, "/soc/ethernet@15100000/mac@0");
    int wan = fdt_path_offset(blob, "/soc/ethernet@15100000/mac@1");
    assert(lan >= 0 && wan >= 0);
    int len = 0;
    const unsigned char *mac = fdt_getprop(blob, lan, "local-mac-address", &len);
    if (atoi(argv[3])) {
        unsigned char expected[6];
        char *end = saved_mac;
        for (int i = 0; i < 6; i++) {
            expected[i] = strtoul(end, &end, 16);
            if (*end) end++;
        }
        assert(mac && len == 6 && memcmp(mac, expected, 6) == 0);
    } else assert(!mac);
    assert(!fdt_getprop(blob, wan, "local-mac-address", NULL));
    return 0;
}
'''

with tempfile.TemporaryDirectory(prefix='lite-mac-') as tmp:
    root = Path(tmp)
    archive = subprocess.check_output(['git', '-C', str(openwrt), 'archive', revision,
                                       'target/linux/mediatek/dts'])
    subprocess.run(['tar', '-x', '-C', str(root)], input=archive, check=True)
    native = root / 'fixup.c'
    native.write_text(harness)
    executable = root / 'fixup'
    subprocess.run(['cc', '-O2', '-I', str(libfdt), str(native),
                    *map(str, sorted(libfdt.glob('*.c'))), '-o', str(executable)], check=True)
    dtsdir = root / 'target/linux/mediatek/dts'
    dts = dtsdir / 'mt7987a-bananapi-bpi-r4-lite.dts'
    for patched in (False, True):
        if patched:
            subprocess.run(['git', 'apply', str(build / 'patches/bpi-r4-lite/base-files/z12-bpirouter-ethernet-alias.patch')],
                           cwd=root, check=True)
        preprocessed = subprocess.check_output(['cc', '-E', '-P', '-x', 'assembler-with-cpp',
            '-nostdinc', '-undef', '-D__DTS__', '-I', str(kernel / 'include'),
            '-I', str(dtsdir), str(dts)])
        dtb = root / f'lite-{patched}.dtb'
        subprocess.run([str(dtc), '-q', '-I', 'dts', '-O', 'dtb', '-o', str(dtb)],
                       input=preprocessed, check=True)
        for mac in ('absent', 'e2:0e:ea:96:4c:c8', '02:11:22:33:44:55'):
            subprocess.run([str(executable), str(dtb), mac,
                            str(int(patched and mac != 'absent'))], check=True)
    driver = Path('drivers/net/ethernet/mediatek/mtk_eth_soc.c')
    (root / driver).parent.mkdir(parents=True)
    before = '"generated random MAC address %pM\\n",\n\t\t\teth->netdev[i]);'
    after = before.replace('eth->netdev[i]);', 'eth->netdev[i]->dev_addr);')
    patch = build / 'patches/common/kernel/992-net-ethernet-mtk-fix-random-mac-log.patch'
    (root / driver).write_text((kernel / driver).read_text())
    # Also work after prepare has installed this fix; normalize only the copy.
    if after in (root / driver).read_text():
        subprocess.run(['git', 'apply', '-R', str(patch)], cwd=root, check=True)
    original = (root / driver).read_text()
    assert original.count(before) == 1
    subprocess.run(['git', 'apply', str(patch)], cwd=root, check=True)
    updated = (root / driver).read_text()
    assert updated == original.replace(before, after)
print('PASS: old DT reproduces missing MAC; patched DT transfers two saved MACs only to LAN; absent env stays absent; log-only fix applies')
