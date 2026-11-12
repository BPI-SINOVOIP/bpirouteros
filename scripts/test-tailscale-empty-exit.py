#!/usr/bin/env python3
"""Verify the shipped empty-exit patch without modifying the supplied source."""

import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

BUILD = Path(__file__).resolve().parents[1]
if len(sys.argv) not in (2, 3) or (len(sys.argv) == 3 and sys.argv[2] != '--unpatched'):
    raise SystemExit('usage: test-tailscale-empty-exit.py <tailscale-source> [--unpatched]')
source = Path(sys.argv[1]).resolve()
original = hashlib.sha256((source / 'ipn/conf.go').read_bytes()).hexdigest()
with tempfile.TemporaryDirectory(prefix='bpir-tailscale-empty-exit-') as directory:
    temp = Path(directory)
    feed = temp / 'feed'
    feed.mkdir()
    subprocess.run(['git', '-C', str(feed), 'apply', '--whitespace=nowarn',
                    str(BUILD / 'patches/common/packages/006-tailscale-empty-exit-config.patch')], check=True)
    target = temp / 'source'
    target.mkdir()
    for entry in source.iterdir():
        if entry.name == 'ipn':
            shutil.copytree(entry, target / entry.name)
        elif entry.is_file() and not entry.name.startswith('.'):
            shutil.copy2(entry, target / entry.name)
        elif not entry.name.startswith('.'):
            (target / entry.name).symlink_to(entry, target_is_directory=entry.is_dir())
    inner = feed / 'net/tailscale/patches/101-config-clear-empty-exit-node.patch'
    reverse = subprocess.run(['git', '-C', str(target), 'apply', '--reverse', '--check', str(inner)], capture_output=True)
    if sys.argv[-1] == '--unpatched':
        if reverse.returncode == 0:
            subprocess.run(['git', '-C', str(target), 'apply', '--reverse', str(inner)], check=True)
    elif reverse.returncode:
        subprocess.run(['git', '-C', str(target), 'apply', str(inner)], check=True)
    shutil.copy2(BUILD / 'scripts/lib/tailscale-empty-exit_test.go', target / 'ipn/bpir_empty_exit_test.go')
    subprocess.run([os.environ.get('GO', 'go'), 'test', './ipn', '-count=1',
                    '-run', '^Test(BpiRouterEmptyExitConfig|ConfigVAlpha_ToPrefs_AdvertiseRoutes)$'],
                   cwd=target, check=True)
assert original == hashlib.sha256((source / 'ipn/conf.go').read_bytes()).hexdigest()
print('PASS: empty exit selection, omission, idempotence and upstream route validation')
