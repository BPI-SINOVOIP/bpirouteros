#!/usr/bin/env python3
# Copyright (C) 2026 Ning <mimallaus@gmail.com>
"""Public source revisions retain firmware provenance and pinned dependencies."""
import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('public_lock', Path(__file__).parent / 'lib/public-source-lock.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class PublicSourceLockTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.tree = self.root / 'public'
        self.tree.mkdir()
        self.original = self.root / 'firmware.json'
        self.data = {'schema': 1, 'release': 'v1.5.0', 'boards': ['bpi-r4'],
                     'repos': {'bpirouter-build': 'a' * 40},
                     'openwrt': {'commit': 'b' * 40}, 'feeds': [{'commit': 'c' * 40}],
                     'downloads_lock_sha256': 'd' * 64,
                     'ui_artifacts': [{'sha256': 'e' * 64}],
                     'non_source_inputs': [{'sha256': 'f' * 64}],
                     'unknown_future_field': {'must': 'remain identical'}}
        for group in module.GROUPS:
            name = group + '/input'
            path = self.tree / name
            path.parent.mkdir()
            path.write_text('original code\n# revised comment\n')
            self.data[group] = [{'path': name, 'sha256': '0' * 64}]
        self.original.write_text(json.dumps(self.data, indent=4) + '\n')

    def generate(self):
        module.generate(self.tree, self.original, '1' * 40)
        return module.read(self.tree / module.PUBLIC)

    def test_original_preserved_and_inputs_rehashed(self):
        before = self.original.read_bytes()
        lock = self.generate()
        self.assertEqual(self.original.read_bytes(), before)
        self.assertEqual((self.tree / module.ORIGINAL).read_bytes(), before)
        for group in module.GROUPS:
            self.assertEqual(lock[group][0]['sha256'], module.digest(self.tree / lock[group][0]['path']))
        self.assertEqual(lock['source_delivery']['firmware_input_lock_sha256'], hashlib.sha256(before).hexdigest())
        module.validate(self.tree, lock)

    def test_pinned_and_unknown_fields_cannot_change(self):
        lock = self.generate()
        for key in ('release', 'boards', 'repos', 'openwrt', 'feeds',
                    'downloads_lock_sha256', 'ui_artifacts', 'non_source_inputs', 'unknown_future_field'):
            with self.subTest(key=key):
                changed = copy.deepcopy(lock)
                changed[key] = 'changed'
                with self.assertRaises(ValueError):
                    module.validate(self.tree, changed)

    def test_changed_file_set_rejected(self):
        lock = self.generate()
        lock['patches'][0]['path'] = 'another.patch'
        with self.assertRaises(ValueError):
            module.validate(self.tree, lock)

    def test_modified_firmware_reference_rejected(self):
        lock = self.generate()
        with (self.tree / module.ORIGINAL).open('a') as stream:
            stream.write(' ')
        with self.assertRaises(ValueError):
            module.validate(self.tree, lock)

    def test_cannot_replace_firmware_reference(self):
        self.generate()
        changed = copy.deepcopy(self.data)
        changed['release'] = 'v1.5.1'
        self.original.write_text(json.dumps(changed))
        with self.assertRaises(ValueError):
            module.generate(self.tree, self.original, None)

    def test_missing_input_does_not_publish_lock(self):
        (self.tree / 'configs/input').unlink()
        with self.assertRaises(FileNotFoundError):
            module.generate(self.tree, self.original, None)
        self.assertFalse((self.tree / module.PUBLIC).exists())


if __name__ == '__main__':
    unittest.main()
