#!/usr/bin/env python3
# Copyright (C) 2026 Ning <mimallaus@gmail.com>
"""Refresh OpenWrt metadata after seeding an unsigned SD installation image."""

import hashlib
import json
from pathlib import Path
import sys


def refresh(image, profile):
    profiles_path = image.parent / 'profiles.json'
    sums_path = image.parent / 'sha256sums'
    profiles = json.loads(profiles_path.read_text())
    entries = [entry for entry in profiles['profiles'][profile]['images']
               if entry['name'] == image.name]
    if len(entries) != 1:
        raise ValueError('expected one SD image entry in profiles.json')
    digest = hashlib.sha256()
    with image.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(chunk)
    entry = entries[0]
    entry.update(sha256=digest.hexdigest(), size=image.stat().st_size)
    if 'sha256_unsigned' in entry:
        entry['sha256_unsigned'] = digest.hexdigest()
    encoded = json.dumps(profiles, sort_keys=True, separators=(',', ':')).encode()
    hashes = {image.name: digest.hexdigest(),
              profiles_path.name: hashlib.sha256(encoded).hexdigest()}
    lines = sums_path.read_text().splitlines(keepends=True)
    # Do not regenerate unrelated checksums: that could bless a changed artifact.
    for name, sha in hashes.items():
        matches = [index for index, line in enumerate(lines)
                   if line[64:66] in (' *', '  ') and line[66:].rstrip('\n') == name]
        if len(matches) != 1:
            raise ValueError(f'expected one checksum entry for {name}')
        index = matches[0]
        lines[index] = sha + lines[index][64:]
    profiles_path.write_bytes(encoded)
    sums_path.write_text(''.join(lines))


if __name__ == '__main__':
    refresh(Path(sys.argv[1]), sys.argv[2])
