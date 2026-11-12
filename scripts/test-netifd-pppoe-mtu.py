#!/usr/bin/env python3
# Copyright (C) 2026 Ning <mimallaus@gmail.com>
"""Execute netifd's parent configuration function against real host libubox."""
import argparse
import os
from pathlib import Path
import re
import resource
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--prepared', action='store_true')
args = parser.parse_args()
resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
build = Path(__file__).resolve().parents[1]
openwrt = Path(os.environ.get('BPIR_OPENWRT_DIR', build / 'openwrt'))
sources = list(openwrt.glob('build_dir/target-*/netifd-*/interface.c'))
assert len(sources) == 1, 'Expected one prepared netifd source tree'
host = openwrt / 'staging_dir/host'
outer = build / 'patches/common/openwrt/007-netifd-pppoe-parent-mtu.patch'
with tempfile.TemporaryDirectory(prefix='bpir-pppoe-mtu-') as tmp:
    root = Path(tmp)
    subprocess.run(['git', 'apply', '--whitespace=nowarn', str(outer)], cwd=root, check=True)
    patch = root / 'package/network/config/netifd/patches/904-bpirouter-pppoe-parent-mtu.patch'
    source = root / 'interface.c'
    source.write_bytes(sources[0].read_bytes())

    def apply(*options, check=True):
        return subprocess.run(['patch', '-s', '-f', '-p1', *options, '-i', str(patch)],
                              cwd=root, capture_output=True, check=check)

    installed = apply('-R', '--dry-run', check=False).returncode == 0
    if args.prepared:
        assert installed, 'Prepared netifd is missing the PPPoE MTU fix'
    if installed:
        apply('-R')
    original = source.read_text()

    def execute(text, success):
        match = re.search(r'static void\ninterface_set_device_config\(.*?\n}\n', text, re.S)
        assert match, 'Missing production function'
        (root / 'function.inc').write_text(match[0])
        subprocess.run([os.environ.get('HOSTCC', 'cc'), '-std=gnu11', '-Wall', '-Wextra', '-Werror',
                        '-I'+str(root), '-I'+str(host/'include'),
                        str(build/'scripts/tests/netifd-pppoe-mtu.c'), str(host/'lib/libubox.a'),
                        '-o', str(root/'check')], check=True)
        result = subprocess.run([str(root/'check')], capture_output=True, text=True)
        assert (result.returncode == 0) == success, result.stdout + result.stderr
        if success:
            print(result.stdout.strip())

    execute(original, False)
    apply()
    fixed = source.read_text()
    execute(fixed, True)
    execute(fixed.replace('!strcmp(iface->proto_handler->name, "pppoe")', '1'), False)
    execute(fixed.replace('if (strcmp(blobmsg_name(cur), "mtu"))',
                         'if (strcmp(blobmsg_name(cur), "mtu") && strcmp(blobmsg_name(cur), "macaddr"))'), False)
    print('PASS: original defect and two overbroad changes rejected')
