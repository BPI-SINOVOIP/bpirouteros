#!/usr/bin/env python3
"""Exercise the real SD post-processing block without compiling firmware."""

import copy
import gzip
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPTS = Path(__file__).resolve().parent


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


class SDMetadataTest(unittest.TestCase):
    def test_seed_updates_only_final_image_and_profile_checksums(self):
        with tempfile.TemporaryDirectory(prefix='bpir-sd-metadata-') as temporary:
            root = Path(temporary)
            target = root / 'bin/targets/mediatek/filogic'
            target.mkdir(parents=True)
            profile = 'bananapi_bpi-r4'
            name = f'openwrt-mediatek-filogic-{profile}-sdcard.img.gz'
            image = target / name
            image.write_bytes(gzip.compress(b'original SD image' * 8))
            other = target / 'unrelated.bin'
            other.write_bytes(b'keep this artifact')
            other_row = {'name': other.name, 'sha256': digest(other), 'size': other.stat().st_size}
            sibling = target / 'openwrt-mediatek-filogic-bananapi_bpi-r4-lite-sdcard.img.gz'
            sibling.write_bytes(gzip.compress(b'unchanged sibling SD image'))
            sibling_row = {'name': sibling.name, 'sha256': digest(sibling),
                           'sha256_unsigned': digest(sibling), 'size': sibling.stat().st_size,
                           'type': 'sdcard.img.gz'}
            # The target is the second image in the second profile.
            before = {'profiles': {'bananapi_bpi-r4-lite': {'images': [sibling_row]},
                profile: {'images': [other_row,
                {'name': name, 'sha256': digest(image), 'sha256_unsigned': digest(image),
                 'size': image.stat().st_size, 'type': 'sdcard.img.gz'}]}}, 'metadata_version': 1}
            profiles = target / 'profiles.json'
            profiles.write_text(json.dumps(before))
            sums = target / 'sha256sums'
            original_lines = [f'{digest(path)} *{path.name}\n' for path in (image, profiles, other, sibling)]
            sums.write_text(''.join(original_lines))
            tools = root / 'build_dir/fixture-emmc/tools'
            tools.mkdir(parents=True)
            mkenv = tools / 'mkenvimage'
            mkenv.write_text('#!/bin/sh\nprintf ENV! > "$5"\n')
            mkenv.chmod(0o755)
            defenv = tools.parent / 'defenvs/factory-env'
            defenv.parent.mkdir()
            defenv.write_text('fixture\n')
            source = (SCRIPTS / 'build-full.sh').read_text()
            block = source.split('# ── 4b.', 1)[1].split('# ── 4c.', 1)[0]
            block = '# ── 4b.' + block
            env = dict(os.environ, WORK_DIR=str(root), SCRIPT_DIR=str(SCRIPTS),
                       TARGET='mediatek/filogic', PROFILE=profile, AB_ENABLED='yes',
                       PROVISION_SRC='sd', ENV_DEFCONFIG_TAG='fixture-emmc',
                       ENV_DEFENV_NAME='factory-env', ENV_SIZE='4', ENV_SEED_OFFSET_MB='0')
            result = subprocess.run(['bash', '-ec',
                                     'set -o pipefail\nstep() { :; }\nok() { :; }\n' + block],
                                    env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertTrue(gzip.decompress(image.read_bytes()).startswith(b'ENV!'))
            after = json.loads(profiles.read_text())
            expected = copy.deepcopy(before)
            expected['profiles'][profile]['images'][1].update(
                sha256=digest(image), sha256_unsigned=digest(image), size=image.stat().st_size)
            self.assertEqual(after, expected)
            self.assertEqual(sums.read_text().splitlines(keepends=True)[2:], original_lines[2:])
            subprocess.run(['sha256sum', '-c', 'sha256sums'], cwd=target,
                           check=True, capture_output=True)


if __name__ == '__main__':
    unittest.main()
