#!/usr/bin/env python3
"""W6 positive and negative checks using real APK generation and extraction."""

import copy
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('promotion', HERE / 'check-release-promotion.py')
p = importlib.util.module_from_spec(spec); spec.loader.exec_module(p)
APK = HERE.parent / 'openwrt/staging_dir/host/bin/apk'
UI = HERE.parent.parent / 'bpirouter-ui'
HASH_SCRIPT = (UI / 'deploy/artifact-hash.sh').read_bytes()


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


class PromotionTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='bpir-w6-test-')
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.repo = self.base / 'ui'; (self.repo / 'deploy').mkdir(parents=True)
        (self.repo / 'deploy/artifact-hash.sh').write_bytes(HASH_SCRIPT)
        for args in (('init', '-q'), ('add', '.'),
                     ('-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid',
                      'commit', '-qm', 'Fixture')):
            subprocess.run(['git', '-C', str(self.repo), *args], check=True, capture_output=True)
        self.rev = subprocess.check_output(['git', '-C', str(self.repo), 'rev-parse', 'HEAD'], text=True).strip()
        self.locks = []; self.downloads = []; self.roots = []
        for index, release in enumerate(('v1.5.0-rc9', 'v1.5.0')):
            root = self.base / str(index); root.mkdir(); self.roots.append(root)
            source = 'a' * 64
            self.put(root, p.VERSION, f'BPIROUTER_VERSION={release}\nBPIROUTER_BUILT=2026-10-25T00:00:0{index}Z\n'
                     f'BPIROUTER_SRC_REV={self.rev[:7]}\nBPIROUTER_SRC_HASH={source}\n')
            self.put(root, 'usr/bin/bpirouter-apid', 'fixed executable\n', 0o755)
            self.put(root, 'www/bpirouter/index.html', 'fixed UI\n')
            self.put(root, 'lib/apk/packages/bpirouter-ui.list', '/etc/bpirouter-version\n')
            self.refresh(root, index)
            downloads = self.base / f'downloads-{index}.json'
            downloads.write_text(json.dumps({'schema': 1, 'release': release,
                'boards': p.release_boards(release), 'objects': [{'path': 'source.tar', 'sha256': 'b'*64,
                'urls': ['https://example.invalid/source.tar']}], 'note': 'same'}))
            self.downloads.append(downloads)
            self.locks.append({'schema': 1, 'test_only': False, 'release': release,
                'generated_at': str(index), 'boards': p.release_boards(release),
                'downloads_lock_sha256': sha(downloads), 'openwrt': {'commit': 'c'*40},
                'feeds': [], 'repos': {'bpirouter-ui': self.rev, 'bpirouter-build': 'd'*40,
                'bpirouter-feeds': 'e'*40}, 'patches': [], 'configs': [], 'pkg_arch': 'aarch64_cortex-a53',
                'ui_artifacts': [{'name': 'bpirouter-ui', 'arch': 'aarch64_cortex-a53',
                    'version': p.contract.expected_versions(release)[1], 'file': f'ui-{index}.apk', 'sha256': '0'*64}]})

    def put(self, root, name, text, mode=0o644):
        path = root / name; path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text); path.chmod(mode)

    def refresh(self, root, index):
        # Independent fixture mapping; do not use the comparator's mapper.
        mapping = {p.VERSION: 'version', 'usr/bin/bpirouter-apid': 'bpirouter-apid',
                   'www/bpirouter/index.html': 'www/index.html'}
        rows = ['BPIR-PAYLOAD|1', 'T|/www/bpirouter']
        for name in mapping:
            path = root / name
            rows.append(f'F|{path.stat().st_mode & 0o777:o}|{path.stat().st_size}|{sha(path)}|/{name}')
        self.put(root, p.INVENTORY, '\n'.join(sorted(rows))+'\n')
        with tempfile.TemporaryDirectory() as directory:
            files = Path(directory)
            for name, target in mapping.items():
                dest = files / target; dest.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(root / name, dest)
            shutil.copyfile(root / p.INVENTORY, files / '.payload-inventory')
            art = subprocess.check_output(['bash', str(UI/'deploy/artifact-hash.sh'), 'art', str(files)], text=True).strip()
        self.put(root, p.BUILD, f'# fixture\nsrc {"a"*64}\nrev {self.rev[:7]}\n'
                 f'art {art}\ninventory {sha(root/p.INVENTORY)}\nbuilt 2026-10-25T00:00:0{index}Z\n')

    def compare(self):
        p.check_inputs(*self.locks, *self.downloads)
        p.compare_payloads(*self.roots, *self.locks, HASH_SCRIPT)

    def test_allowed_version_change(self):
        self.compare()

    def test_download_binding_and_all_non_release_fields(self):
        original = self.downloads[1].read_text()
        for key, value in (('objects', []), ('note', 'changed'), ('unknown', True), ('boards', [])):
            with self.subTest(key=key):
                data = json.loads(original); data[key] = value
                self.downloads[1].write_text(json.dumps(data))
                self.locks[1]['downloads_lock_sha256'] = sha(self.downloads[1])
                with self.assertRaises((ValueError, SystemExit)): self.compare()
        self.downloads[1].write_text(original)
        self.locks[1]['downloads_lock_sha256'] = '0'*64
        with self.assertRaisesRegex(ValueError, 'hash mismatch'): self.compare()

    def test_input_and_identity_changes(self):
        original = copy.deepcopy(self.locks[1])
        for field, value in (('repos', dict(original['repos'], **{'bpirouter-build': 'f'*40})),
                             ('patches', [{'path': 'new.patch'}]), ('configs', [{'sha256': 'c'*64}]),
                             ('unknown', 'new'), ('boards', original['boards'][:-1]),
                             ('test_only', True), ('release', 'v1.5.1')):
            with self.subTest(field=field):
                self.locks[1] = copy.deepcopy(original); self.locks[1][field] = value
                with self.assertRaises((ValueError, SystemExit)): self.compare()

    def test_unknown_json_field_types_must_match(self):
        self.locks[0]['future_field'] = 1
        self.locks[1]['future_field'] = True
        with self.assertRaisesRegex(ValueError, 'input locks differ'): self.compare()

    def test_changed_binary_ui_or_mode_even_with_valid_manifests(self):
        for name in ('usr/bin/bpirouter-apid', 'www/bpirouter/index.html'):
            path = self.roots[1] / name; original = path.read_bytes()
            path.write_bytes(original + b'changed')
            self.refresh(self.roots[1], 1)
            with self.assertRaisesRegex(ValueError, 'payload changed'): self.compare()
            path.write_bytes(original)
        (self.roots[1]/'usr/bin/bpirouter-apid').chmod(0o644)
        self.refresh(self.roots[1], 1)
        with self.assertRaisesRegex(ValueError, 'payload changed'): self.compare()

    def test_stale_derived_values_and_unknown_manifest_fields(self):
        path = self.roots[1]/p.BUILD; original = path.read_text()
        for field in ('art', 'inventory', 'src', 'rev', 'built'):
            lines = [field+' incorrect' if line.startswith(field+' ') else line for line in original.splitlines()]
            path.write_text('\n'.join(lines)+'\n')
            with self.subTest(field=field), self.assertRaises(ValueError): self.compare()
        path.write_text(original+'unknown added\n')
        with self.assertRaisesRegex(ValueError, 'unapproved'): self.compare()

    def test_visible_version_and_inventory_entry_are_verified(self):
        root = self.roots[1]; path = root/p.VERSION; original = path.read_text()
        path.write_text(original.replace('BPIROUTER_VERSION=v1.5.0\n', 'BPIROUTER_VERSION=v1.5.1\n'))
        self.refresh(root, 1)
        with self.assertRaisesRegex(ValueError, 'visible version mismatch'): self.compare()
        path.write_text(original); self.refresh(root, 1)
        path.write_text(original+'# unrecorded change\n')
        with self.assertRaisesRegex(ValueError, 'payload content mismatch'): self.compare()

    def test_generated_package_list_is_not_exempt_from_comparison(self):
        (self.roots[1]/'lib/apk/packages/bpirouter-ui.list').write_text('changed\n')
        with self.assertRaisesRegex(ValueError, 'payload changed'): self.compare()

    def test_unlisted_file_and_changed_symlink(self):
        path = self.roots[1]/'etc/extra';path.write_text('extra')
        with self.assertRaisesRegex(ValueError, 'inventory'): self.compare()
        path.unlink();path.symlink_to('/tmp/target')
        with self.assertRaisesRegex(ValueError, 'paths differ'): self.compare()

    def pack(self, index, script=None):
        lock = self.locks[index]; package = self.base/lock['ui_artifacts'][0]['file']
        root = self.roots[index]
        for path in [root, *root.rglob('*')]: os.utime(path, (1700000000, 1700000000))
        args = [str(APK), 'mkpkg', '--files', str(root), '--output', str(package)]
        for key in ('name', 'version', 'arch'):
            args += ['--info', key+':'+lock['ui_artifacts'][0][key]]
        if script:
            args += ['--script', 'post-install:'+str(script)]
        subprocess.run(args, check=True, capture_output=True)
        lock['ui_artifacts'][0]['sha256'] = sha(package)
        return package

    def cli(self):
        args = ['python3', str(HERE/'check-release-promotion.py'), '--ui-repo', str(self.repo), '--apk-tool', str(APK)]
        for index, label in enumerate(('rc', 'stable')):
            lock = self.base/f'lock-{index}.json';lock.write_text(json.dumps(self.locks[index]))
            args += ['--'+label+'-lock', str(lock), '--'+label+'-downloads', str(self.downloads[index]),
                     '--'+label+'-ui', str(self.base/self.locks[index]['ui_artifacts'][0]['file'])]
        return subprocess.run(args, text=True, capture_output=True)

    def test_real_apk_cli_and_script_hash_rejection(self):
        if not APK.is_file(): self.skipTest('host APK tool not built')
        self.pack(0); package = self.pack(1)
        result = self.cli(); self.assertEqual(result.returncode, 0, result.stdout+result.stderr)
        package.write_bytes(package.read_bytes()+b'corruption')
        result = self.cli(); self.assertNotEqual(result.returncode, 0)
        self.assertIn('hash mismatch', result.stderr)
        script = self.base/'postinstall';script.write_text('#!/bin/sh\nexit 1\n')
        self.pack(1, script)
        result = self.cli(); self.assertNotEqual(result.returncode, 0)
        self.assertIn('metadata/scripts changed', result.stderr)


if __name__ == '__main__':
    unittest.main()
