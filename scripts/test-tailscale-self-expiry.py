#!/usr/bin/env python3
"""Exercise self-key expiry in the pinned backend without changing its source."""

import argparse
import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

BUILD = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('source', type=Path, help='prepared Tailscale source directory')
parser.add_argument('--unpatched', action='store_true', help='remove the fix but retain regression assertions')
args = parser.parse_args()
source = args.source.resolve()
names = ('ipn/ipnlocal/local.go', 'ipn/ipnlocal/state_test.go')
hashes = {name: hashlib.sha256((source / name).read_bytes()).hexdigest() for name in names}

with tempfile.TemporaryDirectory(prefix='bpir-tailscale-expiry-') as directory:
    root = Path(directory)
    feed = root / 'feed'
    feed.mkdir()
    subprocess.run(['git', '-C', str(feed), 'apply', '--whitespace=nowarn',
                    str(BUILD / 'patches/common/packages/009-tailscale-self-key-expiry.patch')], check=True)
    target = root / 'source'
    target.mkdir()
    for entry in source.iterdir():
        if entry.name == 'ipn':
            shutil.copytree(entry, target / entry.name)
        elif entry.is_file() and not entry.name.startswith('.'):
            shutil.copy2(entry, target / entry.name)
        elif not entry.name.startswith('.'):
            (target / entry.name).symlink_to(entry, target_is_directory=entry.is_dir())
    inner = feed / 'net/tailscale/patches/102-self-key-expiry-status.patch'
    reverse = subprocess.run(['git', '-C', str(target), 'apply', '--reverse', '--check', str(inner)], capture_output=True)
    if reverse.returncode:
        subprocess.run(['git', '-C', str(target), 'apply', str(inner)], check=True)
    if args.unpatched:
        subprocess.run(['git', '-C', str(target), 'apply', '--reverse',
                        '--include=ipn/ipnlocal/local.go', str(inner)], check=True)
    binary = root / 'expiry.test'
    subprocess.run([os.environ.get('GO', 'go'), 'test', '-c', '-o', str(binary), './ipn/ipnlocal'],
                   cwd=target, check=True)
    result = subprocess.run(['unshare', '-Urn', str(binary), '-test.run', '^TestStateMachine$',
                             '-test.count=1', '-test.timeout=60s'], cwd=target)
assert hashes == {name: hashlib.sha256((source / name).read_bytes()).hexdigest() for name in names}
result.check_returncode()
print('PASS: initial login, local expiry and renewal JSON; supplied source unchanged')
