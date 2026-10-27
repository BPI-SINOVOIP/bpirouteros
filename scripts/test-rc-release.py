#!/usr/bin/env python3
"""Public rc admission, version mapping and exact SKU-set regression tests."""

import importlib.util
import hashlib
import json
import os
import pathlib
import shutil
import subprocess
import tempfile
import tarfile
import unittest

SCRIPTS = pathlib.Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('contract', SCRIPTS / 'lib/release-lock-contract.py')
contract = importlib.util.module_from_spec(spec)
spec.loader.exec_module(contract)
STABLE = {'bpi-r4', 'bpi-r4-lite', 'bpi-r3', 'bpi-r3-mini', 'openwrt-one', 'bpi-r4-pro'}
RC = STABLE | {'bpi-r4-pro-4e'}


def boards(release):
    return subprocess.check_output(['bash', '-c',
        'source "$1"; bpir_select_release_boards "$2"; printf "%s\\n" "$VALID_BOARDS"',
        'boards', str(SCRIPTS / 'boards.sh'), release], text=True).split()


class RCReleaseTest(unittest.TestCase):
    def test_seven_sku_lock_collection_manifest_and_public_tree(self):
        for release in ('v1.5.0-rc999', 'v1.5.0'):
            with self.subTest(release=release):
                self.check_seven_sku_pipeline(release)

    def check_seven_sku_pipeline(self, release):
        # Entirely synthetic, isolated pipeline: real lock/collector/manifest
        # code, but placeholder firmware and a fixture-only image-policy stub.
        # Passing proves SKU-set plumbing, not firmware or source buildability.
        with tempfile.TemporaryDirectory(prefix='bpir-seven-sku-') as temporary:
            root = pathlib.Path(temporary)
            build, ui, feeds = (root / name for name in
                                ('bpirouter-build', 'bpirouter-ui', 'bpirouter-feeds'))
            for repo in (build, ui, feeds):
                repo.mkdir()
            for name in ('scripts', 'config', 'patches', 'env-templates', 'flashkit'):
                shutil.copytree(SCRIPTS.parent / name, build / name)
            for repo in (build, feeds):
                for name in ('LICENSE', 'LICENSING.md'):
                    shutil.copy2(SCRIPTS.parent.parent / repo.name / name, repo / name)
            (build / 'docs').mkdir()
            shutil.copy2(SCRIPTS.parent / 'docs/README-PUBLIC.md', build / 'docs/README-PUBLIC.md')
            shutil.copytree(SCRIPTS.parent.parent / 'bpirouter-ui/docs/user', ui / 'docs/user')
            shutil.copy2(SCRIPTS.parent.parent / 'bpirouter-ui/LICENSE', ui / 'LICENSE')
            (feeds / 'net').mkdir()
            (feeds / 'net/.keep').touch()
            policy_gate = build / 'scripts/check-firmware-policy.sh'
            policy_gate.write_text('#!/bin/sh\n# Synthetic artifacts only.\nexit 0\n')
            openwrt = build / 'openwrt'
            openwrt.mkdir()
            (build / '.gitignore').write_text('/openwrt/\n/dist/\n')
            (openwrt / '.gitignore').write_text('bin/\n.bpirouter-prepared-board\n')
            (ui / 'source.txt').write_text('private source fixture\n')
            env = {k: v for k, v in os.environ.items()
                   if not k.startswith(('BPIR_', 'BPIROUTER_'))}

            def run(*args, expected=0):
                result = subprocess.run([str(arg) for arg in args], env=env,
                                        text=True, capture_output=True)
                if expected == 0:
                    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                else:
                    self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                return result.stdout + result.stderr

            def init(repo):
                run('git', '-C', repo, 'init', '-q')
                run('git', '-C', repo, 'config', 'user.name', 'Release fixture')
                run('git', '-C', repo, 'config', 'user.email', 'fixture@example.invalid')
                run('git', '-C', repo, 'add', '.')
                run('git', '-C', repo, 'commit', '-qm', 'Synthetic release fixture')

            init(ui)
            init(feeds)
            init(openwrt)
            run('git', '-C', openwrt, 'remote', 'add', 'origin', 'https://example.invalid/openwrt')
            run('git', '-C', openwrt, 'tag', 'v25.12.5')
            feeds_commit = run('git', '-C', feeds, 'rev-parse', 'HEAD').strip()
            (build / 'feeds.conf').write_text(
                f'src-git bpirouter https://example.invalid/feeds^{feeds_commit}\n'
                'src-link bpirouter ../../../bpirouter-feeds\n')
            init(build)
            scripts = build / 'scripts'
            sha = lambda path: hashlib.sha256(path.read_bytes()).hexdigest()
            firmware = root / 'firmware/aeonsemi/as21x1x_fw.bin'
            firmware.parent.mkdir(parents=True)
            firmware.write_bytes(b'synthetic firmware reference')
            archive = root / 'linux-firmware-fixture.tar'
            with tarfile.open(archive, 'w') as tar:
                tar.add(firmware, arcname='linux-firmware-fixture/aeonsemi/as21x1x_fw.bin')
            downloads = root / 'downloads.json'
            data = {'schema': 1, 'release': release, 'boards': sorted(RC),
                    'objects': [{'path': archive.name, 'sha256': sha(archive)}]}
            downloads.write_text(json.dumps(data))
            lock = build / f'dist/RELEASE-INPUTS.{release}.lock.json'
            generator = [scripts / 'make-release-lock.sh', '--release', release,
                         '--downloads-lock', downloads, '--output', lock]
            data['boards'] = sorted(STABLE)
            downloads.write_text(json.dumps(data))
            self.assertIn('exactly', run(*generator, expected=1))
            self.assertFalse(lock.exists())
            data['boards'] = sorted(RC)
            downloads.write_text(json.dumps(data))
            run(*generator)
            run(scripts / 'check-release-lock.sh', '--downloads-lock', downloads, lock)
            self.assertEqual(set(json.loads(lock.read_text())['boards']), RC)
            test_lock = root / 'test-only.lock.json'
            env['BPIR_RELEASE_LOCK_TEST_ONLY'] = '1'
            run(scripts / 'make-release-lock.sh', '--release', release,
                '--downloads-lock', downloads, '--test-output', '--output', test_lock)
            del env['BPIR_RELEASE_LOCK_TEST_ONLY']
            run(scripts / 'check-release-lock.sh', '--downloads-lock', downloads, test_lock)
            self.assertTrue(json.loads(test_lock.read_text())['test_only'])
            refusal = run(scripts / 'collect-release-artifacts.sh', '--release', release,
                          '--input-lock', test_lock, '--downloads-lock', downloads,
                          '--board', 'bpi-r4-pro-4e', '--output-root', root / 'forbidden', expected=1)
            self.assertIn('test-only or legacy input lock cannot authorize', refusal)
            self.assertFalse((root / 'forbidden').exists())

            source = openwrt / 'bin/targets/mediatek/filogic'
            source.mkdir(parents=True)
            proof = root / 'ui-proof.json'
            proof.write_text('{"mode":"none"}')
            provenance = scripts / 'release-build-provenance.py'
            marker = openwrt / '.bpirouter-prepared-board'
            collected = root / 'collected' / release / sha(lock)[:12]
            manifest = root / 'manifest.json'
            manifest_args = [scripts / 'make-firmware-manifest.sh', '--release', release,
                             '--input-lock', lock, '--downloads-lock', downloads,
                             '--build-output', collected, '--linux-firmware', archive,
                             '--output', manifest]
            # Collect the old six first. A complete legacy board set must no
            # longer pass this release's formal manifest gate without 4E.
            for board in sorted(STABLE) + ['bpi-r4-pro-4e']:
                contract_lines = run('bash', '-c',
                    'source "$1"; bpir_select_release_boards "$2"; board_init "$3"; '
                    'printf "%s\\n" "$PROFILE" "$RELEASE_REQUIRED_FILES"',
                    'board', scripts / 'boards.sh', release, board).splitlines()
                profile, *names = contract_lines
                for name in filter(None, names):
                    (source / name).write_text('synthetic artifact\n')
                metadata = run(provenance, 'lock-metadata', '--lock', lock, '--board', board)
                tree_id = run(provenance, 'prepared-id', '--work-dir', openwrt).strip()
                marker.write_text('release_bound=1\nui_mode=none\n' +
                                  metadata.replace('release=', 'release_id=', 1) +
                                  f'prepared_tree_sha256={tree_id}\n')
                base = 'openwrt-mediatek-filogic-' + profile
                run(provenance, 'write', '--lock', lock, '--board', board, '--profile', profile,
                    '--target', 'mediatek/filogic', '--base', base, '--source-dir', source,
                    '--work-dir', openwrt, '--marker', marker, '--ui-proof', proof,
                    '--feed-files', root / 'unused', '--output', source / f'.bpirouter-build-{board}.json')
                run(scripts / 'collect-release-artifacts.sh', '--release', release,
                    '--input-lock', lock, '--downloads-lock', downloads, '--board', board,
                    '--output-root', root / 'collected')
                if board == sorted(STABLE)[-1]:
                    self.assertIn('missing locked boards: bpi-r4-pro-4e', run(*manifest_args, expected=1))
                    self.assertFalse(manifest.exists())
            run(*manifest_args)
            result = json.loads(manifest.read_text())
            self.assertEqual({item['board'] for item in result['images']}, RC)
            self.assertEqual(set(result['required_artifacts']), RC)
            self.assertEqual(len(result['required_artifacts']['bpi-r4-pro-4e']), 9)
            self.assertEqual(result['boards_without_artifacts'], [])
            self.assertEqual(result['input_lock_sha256'], sha(lock))
            refusal = run(scripts / 'make-firmware-manifest.sh', '--release', release,
                          '--input-lock', test_lock, '--downloads-lock', downloads,
                          '--build-output', collected, '--linux-firmware', archive,
                          '--output', root / 'forbidden.json', expected=1)
            self.assertIn('test-only or legacy input lock cannot authorize', refusal)
            self.assertFalse((root / 'forbidden.json').exists())
            public = root / 'public/bpirouteros'
            public_apk = root / 'public-ui.apk'
            public_apk.write_bytes(b'Synthetic export payload, not an installable APK')
            public_lock = root / 'public.lock.json'
            public_data = json.loads(lock.read_text())
            public_data['ui_artifacts'] = [{'name': 'bpirouter-ui', 'version': contract.expected_versions(release)[1],
                                          'arch': 'aarch64_cortex-a53', 'sha256': sha(public_apk)}]
            public_lock.write_text(json.dumps(public_data))
            run(scripts / 'make-public-tree.sh', '--release', release, '--lock', public_lock,
                '--ui-artifact', public_apk, '--output', public)
            self.assertEqual((public / 'RELEASE-INPUTS.lock.json').read_bytes(), public_lock.read_bytes())
            self.assertFalse((public / 'patches/bpi-r4-pro-4e/BUILD-VALIDATION-20260907.md').exists())
            self.assertTrue((public / 'patches/bpi-r4-pro/MXL862XX-UPSTREAM.md').exists())

            # Follow the UI-less public rebuild through the actual lock and
            # prepared-tree gates. Only feed updating and task-specific gates
            # are fixture stubs; stop before download or firmware compilation.
            work = public / 'openwrt'
            shutil.copytree(openwrt, work,
                            ignore=shutil.ignore_patterns('bin', '.bpirouter-prepared-board'))
            env.update(BPIR_BUILD_DIR=str(public), BPIR_WORK_DIR=str(work),
                       BPIROUTER_UI_PKG_VERSION='9.9.9')
            public_scripts = public / 'scripts'
            calls = root / 'feed-gate-calls'
            env.update(BPIR_TEST_GATE_CALLS=str(calls),
                       BPIR_TEST_EXPECTED_FEED=str(public / 'feeds/bpirouter'))
            feed_gates = ('test-mwan3-canonical.sh', 'test-sqm-canonical.sh',
                          'test-offload-disabled.sh', 'test-owned-configs.sh',
                          'test-factory-reset-rootfs.sh', 'test-rootfs-integrity.sh')
            other_gates = ('test-mwan3-route-delete-order.sh', 'test-mwan3-dynamic-child.sh',
                           'test-cellular-package-scope.sh',
                           'test-cellular-netifd-lifecycle.sh', 'test-netifd-dynamic-ip6assign.sh',
                           'test-netifd-proto-busy.sh', 'test-kernel-patch-routing.sh',
                           'test-as21xxx-reprobe.sh')
            for name in other_gates:
                (public_scripts / name).write_text('#!/bin/sh\nexit 0\n')
            for name in feed_gates:
                (public_scripts / name).write_text(
                    '#!/bin/sh\nset -eu\n'
                    '[ "$BPIR_FEEDS_DIR" = "$BPIR_TEST_EXPECTED_FEED" ] || '
                    '{ echo "wrong feed path: $BPIR_FEEDS_DIR" >&2; exit 1; }\n'
                    '[ -f "$BPIR_FEEDS_DIR/LICENSE" ]\n'
                    '[ -z "${BPIROUTER_UI_PKG_VERSION:-}" ]\n'
                    'basename "$0" >>"$BPIR_TEST_GATE_CALLS"\n' +
                    ('exit 99\n' if name == feed_gates[-1] else ''))
            (work / 'scripts').mkdir()
            feed_update = work / 'scripts/feeds'
            feed_update.write_text('#!/bin/sh\nexit 0\n')
            feed_update.chmod(0o755)
            (work / '.config').write_text(
                'CONFIG_TARGET_mediatek_filogic_DEVICE_bananapi_bpi-r4-pro-4e=y\n')
            prepared_sha = run(public_scripts / 'release-build-provenance.py', 'prepare-input-id',
                               '--build-dir', public, '--board', 'bpi-r4-pro-4e').strip()
            public_lock = public / 'RELEASE-INPUTS.lock.json'
            public_marker = work / '.bpirouter-prepared-board'
            marker_text = ('board=bpi-r4-pro-4e\nui_mode=none\nrelease_bound=0\n'
                           f'prepare_inputs_sha256={prepared_sha}\ninput_lock_path={public_lock}\n')
            public_marker.write_text(marker_text)
            command = ['bash', str(public_scripts / 'build-full.sh'), '--board', 'bpi-r4-pro-4e']
            result = subprocess.run(command, env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 99, result.stdout + result.stderr)
            self.assertIn('scope=tree', result.stdout)
            self.assertEqual(calls.read_text().splitlines(), list(feed_gates))
            self.assertFalse(list(work.glob('bin/targets/*/*/.bpirouter-build-*.json')))
            self.assertEqual(public_marker.read_text(), marker_text)

            # A recorded lock still has to describe this tree. Neither dropping
            # the lock nor using an incomplete/older board set may admit 4E.
            original_lock = json.loads(public_lock.read_text())
            for release_id in ('v1.5.0', 'v1.4.9-rc1'):
                public_lock.write_text(json.dumps(dict(original_lock, release=release_id,
                                                        boards=sorted(STABLE), ui_artifacts=[])))
                result = subprocess.run(command, env=env, capture_output=True, text=True)
                self.assertNotEqual(result.returncode, 0)
                if release_id == 'v1.5.0':
                    self.assertIn('input lock must name exactly', result.stdout + result.stderr)
                else:
                    self.assertIn('requires a development-bound prepare', result.stderr)
            public_lock.write_text(json.dumps(original_lock))
            public_marker.write_text(marker_text.replace(f'input_lock_path={public_lock}\n', ''))
            result = subprocess.run(command, env=env, capture_output=True, text=True)
            self.assertIn('requires a development-bound prepare', result.stderr)
            public_marker.write_text(marker_text)
            with (public / 'config/bpi-r4-pro-4e.config').open('a') as stream:
                stream.write('# drift from locked config\n')
            result = subprocess.run(command, env=env, capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('config changed since the lock', result.stderr)
            self.assertEqual(calls.read_text().splitlines(), list(feed_gates))

    def test_v15_selects_exactly_seven_skus_without_changing_older_releases(self):
        self.assertEqual(set(boards('v1.5.0-rc1')), RC)
        self.assertEqual(set(boards('v1.5.0-rc12')), RC)
        self.assertEqual(set(boards('v1.5.0')), RC)
        for release in ('', 'v1.4.9', 'v1.4.9-rc1', 'v1.5.0-rc', 'v1.5.0-rc0'):
            self.assertEqual(set(boards(release)), STABLE)

    def test_rc_does_not_latch_admission(self):
        result = subprocess.check_output(['bash', '-c',
            'source "$1"; bpir_select_release_boards v1.5.0-rc1; '
            'bpir_select_release_boards v1.4.9; echo "$VALID_BOARDS"',
            'boards', str(SCRIPTS / 'boards.sh')], text=True)
        self.assertEqual(set(result.split()), STABLE)

    def test_rc_requires_all_seven_and_matching_ui_version(self):
        expected = boards('v1.5.0-rc1')
        data = {'schema': 1, 'release': 'v1.5.0-rc1', 'boards': expected,
                'downloads_lock_sha256': '0' * 64,
                'ui_artifacts': [{'name': 'bpirouter-ui', 'version': '1.5.0_rc1-r1'}]}
        contract.validate_input(data, expected)
        for subset in (sorted(STABLE), ['bpi-r4-pro'], expected + ['bpi-r4-pro']):
            with self.assertRaises(SystemExit):
                contract.validate_input(dict(data, boards=subset), expected)
        data['ui_artifacts'][0]['version'] = '1.5.0-r1'
        with self.assertRaises(SystemExit):
            contract.validate_input(data, expected)

    def test_4e_keeps_its_own_artifacts_with_ab_execution_enabled(self):
        result = subprocess.check_output(['bash', '-c',
            'source "$1"; bpir_select_release_boards v1.5.0-rc1; '
            'board_init bpi-r4-pro-4e; printf "%s\\n" "$PROFILE" "$AB_ENABLED" '
            '"$BOARD_IMPLEMENTED" "$RELEASE_REQUIRED_FILES"',
            'boards', str(SCRIPTS / 'boards.sh')], text=True).splitlines()
        self.assertEqual(result[:3], ['bananapi_bpi-r4-pro-4e', 'yes', 'yes'])
        artifacts = [line for line in result[3:] if line]
        self.assertEqual(len(artifacts), 9)
        self.assertTrue(all('bpi-r4-pro-4e-' in name or name.endswith('bpi-r4-pro-4e.manifest')
                            for name in artifacts))
        self.assertTrue((SCRIPTS.parent / 'config/bpi-r4-pro-4e.config').is_file())
        self.assertTrue((SCRIPTS.parent / 'patches/bpi-r4-pro-4e').is_dir())

    def test_prepare_dispatch_allows_rc_4e_but_not_older_rc_before_source_mutation(self):
        with tempfile.TemporaryDirectory(prefix='bpir-rc-prepare-') as temporary:
            root = pathlib.Path(temporary)
            lock = root / 'lock.json'
            reached = root / 'reached'
            env = dict(os.environ, BPIR_BUILD_DIR=str(root), BPIR_WORK_DIR=str(root / 'openwrt'),
                       BPIR_RELEASE_LOCK=str(lock), BPIR_TEST_AFTER_OPENWRT_LOCK=str(reached))
            # The existing pre-mutation seam exits 99. This is only a dispatch
            # test, not a validated release lock or a firmware build.
            for release, expected in [('v1.4.9-rc1', 1), ('v1.5.0-rc1', 99)]:
                lock.write_text(json.dumps({'release': release}))
                result = subprocess.run(['bash', str(SCRIPTS / 'prepare.sh'), '--board',
                                         'bpi-r4-pro-4e', '--without-proprietary-ui'],
                                        env=env, text=True, capture_output=True)
                self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
                self.assertEqual(reached.exists(), expected == 99)

    def test_bad_release_id_refuses_before_prepare_or_batch_mutation(self):
        with tempfile.TemporaryDirectory(prefix='bpir-rc-invalid-') as temporary:
            root = pathlib.Path(temporary)
            lock = root / 'lock.json'
            reached = root / 'reached'
            env = dict(os.environ, BPIR_BUILD_DIR=str(root), BPIR_WORK_DIR=str(root / 'openwrt'),
                       BPIR_RELEASE_LOCK=str(lock), BPIR_TEST_AFTER_OPENWRT_LOCK=str(reached))
            for content in ('{', '{}', '{"release":42}', '{"release":""}',
                            '{"release":"v1.5.0-rc1","release":"v1.4.9-rc1"}'):
                lock.write_text(content)
                for command in (
                    ['prepare.sh', '--board', 'bpi-r4', '--without-proprietary-ui'],
                    ['rebuild-all.sh', '--release-lock', str(lock)],
                ):
                    result = subprocess.run(['bash', str(SCRIPTS / command[0]), *command[1:]],
                                            env=env, capture_output=True, text=True)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertNotEqual(result.returncode, 99)
                    self.assertFalse(reached.exists())
                    self.assertFalse((root / 'openwrt').exists())

    def test_lock_discovery_is_shared_and_public_build_uses_prepared_path(self):
        with tempfile.TemporaryDirectory(prefix='bpir-rc-path-') as temporary:
            root = pathlib.Path(temporary)
            (root / 'dist').mkdir()
            self.assertEqual(contract.find_input(str(root), ''), '')
            first = root / 'dist/first.lock.json'
            first.write_text('{"release":"v1.5.0-rc1"}')
            self.assertEqual(contract.find_input(str(root), ''), str(first))
            second = root / 'dist/second.lock.json'
            second.write_bytes(first.read_bytes())
            with self.assertRaises(SystemExit):
                contract.find_input(str(root), '')
            self.assertEqual(contract.find_input(str(root), str(first)), str(first))
            with self.assertRaises(SystemExit):
                contract.find_input(str(root), str(root / 'missing'))
            root_lock = root / 'RELEASE-INPUTS.lock.json'
            root_lock.write_bytes(first.read_bytes())
            self.assertEqual(contract.find_input(str(root), ''), str(root_lock))
            (root / 'scripts/lib').mkdir(parents=True)
            for source in ('build-full.sh', 'lib/release-lock-contract.py'):
                shutil.copy2(SCRIPTS / source, root / 'scripts' / source)
            check = root / 'scripts/check-release-lock.sh'
            check.write_text('#!/bin/sh\nprintf "%s" "$3" >"$BPIR_TEST_SELECTED_LOCK"\nexit 99\n')
            check.chmod(0o755)
            (root / 'openwrt').mkdir()
            marker = root / 'openwrt/.bpirouter-prepared-board'
            selected = root / 'selected'
            env = dict(os.environ, BPIR_BUILD_DIR=str(root), BPIR_WORK_DIR=str(root / 'openwrt'),
                       BPIR_TEST_SELECTED_LOCK=str(selected))
            for mode in ('artifact', 'none'):
                marker.write_text(f'ui_mode={mode}\nrelease_bound=0\ninput_lock_path={first}\n')
                result = subprocess.run(['bash', str(root / 'scripts/build-full.sh')],
                                        env=env, capture_output=True, text=True)
                self.assertEqual(result.returncode, 99, result.stdout + result.stderr)
                self.assertEqual(selected.read_text(), str(first))


if __name__ == '__main__':
    unittest.main()
