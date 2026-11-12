#!/usr/bin/env python3
"""Verify fw4 patch reapplication using prepare's real source cleanup."""
from pathlib import Path
import subprocess
import sys
import tempfile

build = Path(__file__).resolve().parents[1]
openwrt = Path(sys.argv[1])
makefile = 'package/network/config/firewall4/Makefile'
inner = 'package/network/config/firewall4/patches/910-bpirouter-s2s-lock-boundary.patch'
patch = build / 'patches/common/base-files/008-firewall4-product-lock.patch'
helper = build / 'scripts/lib/openwrt-source.sh'
baseline = subprocess.check_output(['git', '-C', str(openwrt), 'show', 'HEAD:' + makefile])

with tempfile.TemporaryDirectory(prefix='bpir-s2s-reprepare-') as directory:
    root = Path(directory)
    target = root / makefile
    target.parent.mkdir(parents=True)
    target.write_bytes(baseline)
    subprocess.run(['git', 'init', '-q', str(root)], check=True)
    git = ['git', '-C', str(root)]
    subprocess.run(git + ['add', makefile], check=True)
    subprocess.run(git + ['-c', 'user.name=fixture', '-c', 'user.email=fixture@example.invalid',
        '-c', 'commit.gpgsign=false', '-c', 'core.hooksPath=/dev/null',
        'commit', '-qm', 'baseline'], check=True)
    subprocess.run(git + ['apply', '--whitespace=nowarn', str(patch)], check=True)
    expected = (root / inner).read_bytes()
    preserved = ('.config', 'build_dir/cache', 'package/network/config/firewall4/patches/local.patch')
    for name in preserved:
        path = root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text('preserve ' + name + '\n')
    for prior in (expected, expected + b'\n# Previous development revision\n'):
        (root / inner).write_bytes(prior)
        subprocess.run(['bash', '-c', '. "$1"; bpir_reset_openwrt_source "$2"',
            '_', str(helper), str(root)], check=True)
        assert not (root / inner).exists(), 'prepare retained the fw4 package patch'
        assert target.read_bytes() == baseline
        for name in preserved:
            assert (root / name).read_text() == 'preserve ' + name + '\n', name
        subprocess.run(git + ['apply', '--whitespace=nowarn', '--check', str(patch)], check=True)
        subprocess.run(git + ['apply', '--whitespace=nowarn', str(patch)], check=True)
        assert (root / inner).read_bytes() == expected
        subprocess.run(git + ['apply', '--reverse', '--check', str(patch)], check=True)

print('PASS: fw4 reprepare removes current/older product patches, preserves local files/cache and reapplies cleanly')
