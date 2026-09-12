#!/usr/bin/env python3
"""Check pinned remote feeds or local corresponding-source snapshots."""

import json
import os
import pathlib
import subprocess
import sys
import tempfile


def check(lock_path, config_path, scope):
    lock = json.loads(pathlib.Path(lock_path).read_text())
    config = pathlib.Path(config_path)
    expected = {f['name']: (f['url'], f['commit']) for f in lock.get('feeds', [])}
    found = {}
    for line in config.read_text().splitlines():
        fields = line.split()
        if not fields or fields[0].startswith('#'):
            continue
        if len(fields) != 3:
            raise ValueError('invalid feed declaration')
        kind, name, location = fields
        key = (kind, name)
        if key in found:
            raise ValueError(f'duplicate feed {name}')
        found[key] = location
    for name, (url, commit) in expected.items():
        remote = found.pop(('src-git', name), None)
        if remote == f'{url}^{commit}':
            continue
        location = found.pop(('src-link', name), None)
        if remote is not None or scope != 'tree' or location is None:
            raise ValueError(f'feed {name} differs from the lock')
        checkout = (config.parent / 'openwrt/feeds' / location).resolve()

        def git(*args):
            return subprocess.check_output(['git', '-C', str(checkout), *args],
                                           text=True, stderr=subprocess.PIPE).strip()

        if pathlib.Path(git('rev-parse', '--show-toplevel')).resolve() != checkout:
            raise ValueError(f'feed {name} is not a checkout root')
        if git('rev-parse', 'HEAD') != commit:
            raise ValueError(f'feed {name} snapshot differs from the lock')
        if git('status', '--porcelain'):
            # prepare applies the product package patches to the packages feed.
            # Compare against that exact result without modifying the checkout.
            patches = sorted((config.parent / 'patches/common/packages').glob('*.patch')) if name == 'packages' else []
            if not patches:
                raise ValueError(f'feed {name} has unexpected local changes')
            with tempfile.TemporaryDirectory(prefix='bpir-feed-index-') as temporary:
                env = dict(os.environ, GIT_INDEX_FILE=str(pathlib.Path(temporary) / 'index'))

                def indexed(*args):
                    return subprocess.check_output(['git', '-C', str(checkout), *args],
                                                   env=env, stderr=subprocess.PIPE, text=True).strip()

                indexed('read-tree', 'HEAD')
                for patch in patches:
                    indexed('apply', '--cached', str(patch.resolve()))
                indexed('diff', '--quiet')
                if indexed('ls-files', '--others', '--exclude-standard'):
                    raise ValueError(f'feed {name} has unexpected untracked source')
    # The product feed is intentionally local in both layouts.
    found.pop(('src-link', 'bpirouter'), None)
    if found:
        raise ValueError('unexpected feeds')


if __name__ == '__main__':
    try:
        check(*sys.argv[1:])
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        sys.exit(f'feed input check failed: {error}')
