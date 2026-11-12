#!/usr/bin/env python3
"""Test the package's routing patch in an isolated copy and network namespace."""

import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

BUILD = Path(__file__).resolve().parents[1]
if len(sys.argv) != 2:
    raise SystemExit('usage: test-tailscale-product-routing.py <unpacked-tailscale-source>')
source = Path(sys.argv[1]).resolve()
patch = BUILD / 'patches/common/packages/005-tailscale-product-routing.patch'
with tempfile.TemporaryDirectory(prefix='bpir-tailscale-routing-') as directory:
    temp = Path(directory)
    feed = temp / 'feed'
    feed.mkdir()
    subprocess.run(['git', '-C', str(feed), 'apply', '--whitespace=nowarn', str(patch)], check=True)
    target = temp / 'source'
    target.mkdir()
    for entry in source.iterdir():
        if entry.name == 'wgengine':
            shutil.copytree(entry, target / entry.name)
        elif entry.is_file() and not entry.name.startswith('.'):
            shutil.copy2(entry, target / entry.name)
        elif not entry.name.startswith('.'):
            (target / entry.name).symlink_to(entry, target_is_directory=entry.is_dir())
    inner = feed / 'net/tailscale/patches/100-bpirouter-mwan-routing.patch'
    reverse = subprocess.run(['git', '-C', str(target), 'apply', '--reverse', '--check', str(inner)], capture_output=True)
    if reverse.returncode:
        subprocess.run(['git', '-C', str(target), 'apply', str(inner)], check=True)
    shutil.copy2(BUILD / 'scripts/lib/tailscale-product-routing_test.go',
                 target / 'wgengine/router/osrouter/bpirouter_product_test.go')
    binary = temp / 'router.test'
    subprocess.run([os.environ.get('GO', 'go'), 'test', '-c', '-o', str(binary),
                    './wgengine/router/osrouter'], cwd=target, check=True)
    # Run upstream unprivileged regressions separately from the real-kernel test.
    subprocess.run([str(binary), '-test.run', '^Test(RouterStates|IPRulesForUBNT)$'], check=True)
    subprocess.run(['unshare', '-Urn', str(binary), '-test.run', '^TestBpiRouterProductRules$', '-test.v'],
                   check=True, env={**os.environ, 'BPIR_PARENT_NETNS': os.readlink('/proc/self/ns/net')})
