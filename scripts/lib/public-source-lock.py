#!/usr/bin/env python3
# Copyright (C) 2026 Ning <mimallaus@gmail.com>
"""Describe revised public inputs without rewriting original firmware provenance."""
import argparse
import copy
import hashlib
import json
from pathlib import Path
import re

ORIGINAL = 'FIRMWARE-INPUTS.lock.json'
PUBLIC = 'RELEASE-INPUTS.lock.json'
GROUPS = ('patches', 'configs')


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def read(path):
    return json.loads(path.read_text())


def validate(tree, lock):
    record = lock['source_delivery']
    if set(record) != {'firmware_input_lock_sha256', 'build_source_revision'}:
        raise ValueError('invalid public source delivery record')
    revision = record['build_source_revision']
    if revision is not None and not re.fullmatch(r'[0-9a-f]{40}', revision):
        raise ValueError('public source revision must be a full commit or null')
    original_path = tree / ORIGINAL
    if digest(original_path) != record['firmware_input_lock_sha256']:
        raise ValueError('original firmware lock hash mismatch')
    original = read(original_path)
    if 'source_delivery' in original:
        raise ValueError('original firmware lock must not be a public source revision')
    comparable = copy.deepcopy(lock)
    del comparable['source_delivery']
    for group in GROUPS:
        before, after = original[group], comparable[group]
        if len(before) != len(after):
            raise ValueError(f'{group} file set differs from the firmware lock')
        for old, new in zip(before, after):
            if not re.fullmatch(r'[0-9a-f]{64}', new['sha256']):
                raise ValueError('invalid public input hash')
            new['sha256'] = old['sha256']
    if comparable != original:
        raise ValueError('public revision changed pinned inputs beyond patch/config hashes')


def generate(tree, firmware_lock, revision):
    original_bytes = firmware_lock.read_bytes()
    lock = json.loads(original_bytes)
    if 'source_delivery' in lock:
        raise ValueError('expected an original firmware lock')
    root = tree.resolve()
    for group in GROUPS:
        for entry in lock[group]:
            path = tree / entry['path']
            if not path.resolve().is_relative_to(root):
                raise ValueError('input path escapes the public tree')
            entry['sha256'] = digest(path)
    lock['source_delivery'] = {
        'firmware_input_lock_sha256': hashlib.sha256(original_bytes).hexdigest(),
        'build_source_revision': revision,
    }
    original_path = tree / ORIGINAL
    if original_path.exists() and original_path.read_bytes() != original_bytes:
        raise ValueError('refusing to replace a different original firmware lock')
    original_path.write_bytes(original_bytes)
    validate(tree, lock)
    (tree / PUBLIC).write_text(json.dumps(lock, indent=2) + '\n')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--tree', required=True, type=Path)
    parser.add_argument('--firmware-lock', type=Path)
    parser.add_argument('--source-revision')
    parser.add_argument('--check', type=Path)
    args = parser.parse_args()
    if args.check:
        validate(args.tree, read(args.check))
    elif args.firmware_lock:
        generate(args.tree, args.firmware_lock, args.source_revision)
    else:
        parser.error('use --check or --firmware-lock')


if __name__ == '__main__':
    main()
