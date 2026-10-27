#!/usr/bin/env python3
"""Exercise flashkit checksum registration without compiling firmware."""

import hashlib
import os
from pathlib import Path
import subprocess
import tempfile
import tarfile
import unittest

SCRIPTS = Path(__file__).resolve().parent


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


class FlashkitMetadataTest(unittest.TestCase):
    def check_board(self, board, profile, soc, fip, private=False):
        with tempfile.TemporaryDirectory(prefix='bpir-flashkit-metadata-') as temporary:
            root = Path(temporary)
            build = root / 'bpirouter-build'
            build.mkdir()
            (build / 'flashkit').symlink_to(SCRIPTS.parent / 'flashkit', target_is_directory=True)
            ui = root / 'bpirouter-ui'
            guides = ui / 'docs/user' if private else build
            guides.mkdir(parents=True, exist_ok=True)
            source = SCRIPTS.parent
            if not (source / 'INSTALLATION.md').exists():
                source = source.parent / 'bpirouter-ui/docs/user'
            names = ('FEATURES.md', 'FEATURES.zh-CN.md', 'INSTALLATION.md', 'INSTALLATION.zh-CN.md')
            for guide in names:
                (guides / guide).write_bytes((source / guide).read_bytes())
            if private:
                subprocess.run(['git', 'init', '-q', str(ui)], check=True)
                subprocess.run(['git', '-C', str(ui), 'add', '.'], check=True)
                subprocess.run(['git', '-C', str(ui), '-c', 'user.name=Fixture',
                                '-c', 'user.email=fixture@example.invalid',
                                'commit', '-qm', 'Customer guide fixture'], check=True)
            target = root / 'bin/targets/mediatek/filogic'
            target.mkdir(parents=True)
            base = f'openwrt-mediatek-filogic-{profile}'
            (target / f'{soc}-ram-ddr4-bl2.bin').write_bytes(b'fixture BL2')
            (target / f'{base}-{fip}-bl31-uboot.fip').write_bytes(b'fixture FIP')
            factory = target / f'{base}-snand-factory.bin'
            archive = target / f'{base}-flashkit.tar.gz'
            # A longer filename must not be mistaken for the target archive.
            sibling = target / (archive.name + '.old')
            sibling.write_bytes(b'unchanged sibling')
            profiles = target / 'profiles.json'
            profiles.write_bytes(b'{"profiles":{}}\n')
            unrelated = ''.join(f'{digest(p)} *{p.name}\n' for p in (sibling, profiles))
            sums = target / 'sha256sums'
            env = dict(os.environ, BPIR_WORK_DIR=str(root),
                       BPIR_BUILD_DIR=str(build))
            previous = None
            for stage in ('no-table', 'append', 'replace'):
                with self.subTest(board=board, stage=stage):
                    if stage == 'append':
                        sums.write_text(unrelated)
                    elif stage == 'replace':
                        sums.write_text(unrelated + f'{digest(archive)}  {archive.name}\n')
                    factory.write_bytes(f'factory content for {stage}'.encode())
                    result = subprocess.run(['bash', str(SCRIPTS / 'make-flashkit.sh'),
                                             '--board', board], env=env,
                                            capture_output=True, text=True)
                    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                    with tarfile.open(archive) as kit:
                        for guide in ('FEATURES.md', 'FEATURES.zh-CN.md',
                                      'INSTALLATION.md', 'INSTALLATION.zh-CN.md'):
                            self.assertEqual(kit.extractfile(f'flashkit-{board}/{guide}').read(),
                                             (guides / guide).read_bytes())
                        runbook = 'RUNBOOK-r3mini.md' if board == 'bpi-r3-mini' else 'RUNBOOK-openwrt-one.md'
                        entry = kit.extractfile(f'flashkit-{board}/{runbook}').read().decode()
                        self.assertIn('[Installation](INSTALLATION.md)', entry)
                        self.assertNotIn('Hardware-validated', entry)
                    self.assertTrue(sums.exists(), 'flashkit must create its checksum table')
                    lines = sums.read_text().splitlines(keepends=True)
                    matches = [line for line in lines if line[66:].rstrip('\n') == archive.name]
                    self.assertEqual(len(matches), 1, 'expected exactly one final archive checksum')
                    self.assertEqual(matches[0][:64], digest(archive))
                    if stage != 'no-table':
                        self.assertEqual(''.join(line for line in lines if line not in matches), unrelated)
                    self.assertEqual(profiles.read_bytes(), b'{"profiles":{}}\n')
                    self.assertNotEqual(digest(archive), previous)
                    previous = digest(archive)
                    subprocess.run(['sha256sum', '-c', 'sha256sums'], cwd=target,
                                   check=True, capture_output=True)
            duplicate = sums.read_text() + f'{digest(archive)} *{archive.name}\n'
            sums.write_text(duplicate)
            result = subprocess.run(['bash', str(SCRIPTS / 'make-flashkit.sh'),
                                     '--board', board], env=env,
                                    capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('duplicate checksum entries', result.stderr)
            self.assertEqual(sums.read_text(), duplicate)
            if private:
                (guides / 'FEATURES.md').write_text('Uncommitted customer guidance\n')
                result = subprocess.run(['bash', str(SCRIPTS / 'make-flashkit.sh'),
                                         '--board', board], env=env, capture_output=True, text=True)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('user guide must match committed revision', result.stderr)

    def test_committed_private_guides(self):
        self.check_board('openwrt-one', 'openwrt_one', 'mt7981', 'ram', private=True)

    def test_r3_mini(self):
        self.check_board('bpi-r3-mini', 'bananapi_bpi-r3-mini', 'mt7986', 'snand')

    def test_openwrt_one(self):
        self.check_board('openwrt-one', 'openwrt_one', 'mt7981', 'ram')


if __name__ == '__main__':
    unittest.main()
