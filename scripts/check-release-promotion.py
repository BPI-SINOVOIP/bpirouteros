#!/usr/bin/env python3
"""Read-only W6 input and UI-package comparison; not firmware acceptance."""

import argparse
import hashlib
import importlib.util
import json
import pathlib
import re
import shutil
import stat
import subprocess
import tempfile

HERE = pathlib.Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('contract', HERE / 'lib/release-lock-contract.py')
contract = importlib.util.module_from_spec(spec)
spec.loader.exec_module(contract)
VERSION = 'etc/bpirouter-version'
INVENTORY = 'etc/bpirouter-product-payload.manifest'
BUILD = 'etc/bpirouter-ui-build.manifest'
VARIABLE = {VERSION, INVENTORY, BUILD}


def require(ok, message):
    if not ok:
        raise ValueError(message)


def without(data, keys):
    # Preserve JSON scalar types: Python otherwise equates true with 1.
    return json.dumps({k: v for k, v in data.items() if k not in keys},
                      sort_keys=True, allow_nan=False)


def release_boards(release):
    return subprocess.check_output([
        'bash', '-c', 'source "$1"; bpir_select_release_boards "$2"; echo "$VALID_BOARDS"',
        'boards', str(HERE / 'boards.sh'), release], text=True).split()


def check_inputs(rc, stable, rc_downloads, stable_downloads):
    require(re.fullmatch(r'v\d+\.\d+\.\d+-rc[1-9]\d*', rc['release']), 'source must be an RC')
    require(stable['release'] == rc['release'].split('-rc')[0], 'target must be the matching stable release')
    downloads = []
    for data, path in ((rc, rc_downloads), (stable, stable_downloads)):
        require(data.get('test_only') is False, 'formal locks are required')
        expected = release_boards(data['release'])
        contract.validate_input(data, expected)
        actual = contract.validate_downloads(str(path), data['release'], expected)
        require(actual == data['downloads_lock_sha256'], 'downloads lock hash mismatch')
        downloads.append(contract.load(str(path)))
        require(len(data.get('ui_artifacts', [])) == 1, 'exactly one UI package is required')
        for name in ('openwrt', 'feeds', 'repos', 'patches', 'configs', 'pkg_arch'):
            require(name in data, 'missing input field: ' + name)
        require(data['ui_artifacts'][0].get('arch') == data['pkg_arch'], 'UI architecture mismatch')
        for rev in data['repos'].values():
            require(re.fullmatch(r'[0-9a-f]{40}', rev), 'invalid repository revision')
    require(without(downloads[0], {'release'}) == without(downloads[1], {'release'}),
            'downloads differ beyond release')
    ignored = {'release', 'generated_at', 'downloads_lock_sha256', 'ui_artifacts'}
    require(without(rc, ignored) == without(stable, ignored), 'input locks differ beyond allowed fields')
    require(without(rc['ui_artifacts'][0], {'version', 'file', 'sha256'}) ==
            without(stable['ui_artifacts'][0], {'version', 'file', 'sha256'}),
            'UI identity differs beyond allowed fields')


def fields(path, separator, required):
    values = {}
    for line in path.read_text().splitlines():
        if not line or line.startswith('#'):
            continue
        key, sep, value = line.partition(separator)
        require(sep and key not in values and value, 'invalid or duplicate field in ' + str(path))
        values[key] = value
    require(required <= values.keys(), 'missing fields in ' + str(path))
    return values


def normalized_fields(path, separator, allowed):
    return [line.partition(separator)[0] + separator + '<derived>'
            if line.partition(separator)[0] in allowed else line
            for line in path.read_text().splitlines()]


def inventory(root):
    rows = {}; lines = (root / INVENTORY).read_text().splitlines()
    require(lines.count('BPIR-PAYLOAD|1') == 1, 'unsupported payload inventory')
    for line in lines:
        if line == 'BPIR-PAYLOAD|1' or line.startswith('T|'):
            continue
        parts = line.split('|')
        require(len(parts) == 5 and parts[0] in ('F', 'B'), 'invalid payload entry')
        kind, mode, size, digest, absolute = parts
        path = pathlib.PurePosixPath(absolute)
        require(path.is_absolute() and '..' not in path.parts and str(path) == absolute,
                'invalid payload path')
        relative = absolute[1:]
        require(relative not in rows, 'duplicate payload path')
        target = root / relative
        require(target.is_file() and not target.is_symlink(), 'missing regular payload: ' + relative)
        require(str(target.stat().st_size) == size and contract.sha256(target) == digest,
                'payload content mismatch: ' + relative)
        require(format(stat.S_IMODE(target.stat().st_mode), 'o') == mode,
                'payload mode mismatch: ' + relative)
        rows[relative] = parts
    require(VERSION in rows and 'usr/bin/bpirouter-apid' in rows, 'incomplete product inventory')
    return rows


def feed_path(path):
    exact = {VERSION: 'version', INVENTORY: '.payload-inventory',
             'etc/nginx/nginx.conf': 'nginx/nginx.conf',
             'lib/upgrade/keep.d/bpirouter-ui': 'keep.d/bpirouter-ui'}
    if path in exact:
        return exact[path]
    for prefix, target in (('usr/bin/', ''), ('usr/libexec/', 'libexec/'),
                           ('www/bpirouter/', 'www/'), ('usr/share/bpirouter/nginx/', 'nginx/'),
                           ('etc/init.d/', 'init.d/'), ('etc/uci-defaults/', 'uci-defaults/')):
        if path.startswith(prefix):
            return target + path[len(prefix):]
    raise ValueError('unmapped artifact path: ' + path)


def tree(root):
    result = {}
    for path in root.rglob('*'):
        relative = path.relative_to(root).as_posix()
        info = path.lstat(); mode = stat.S_IMODE(info.st_mode)
        if path.is_symlink():
            value = ('link', mode, str(path.readlink()))
        elif path.is_dir():
            value = ('directory', mode)
        else:
            require(stat.S_ISREG(info.st_mode), 'unsupported package file type')
            value = ('file', mode, contract.sha256(path))
        result[relative] = value
    return result


def check_payload(root, lock, hash_script):
    version = fields(root / VERSION, '=', {'BPIROUTER_VERSION', 'BPIROUTER_BUILT',
                     'BPIROUTER_SRC_REV', 'BPIROUTER_SRC_HASH'})
    build = fields(root / BUILD, ' ', {'src', 'rev', 'art', 'inventory', 'built'})
    require(version['BPIROUTER_VERSION'] == lock['release'], 'visible version mismatch')
    require(version['BPIROUTER_SRC_REV'] == build['rev'] and
            re.fullmatch(r'[0-9a-f]{7,40}', build['rev']) and
            lock['repos']['bpirouter-ui'].startswith(build['rev']), 'UI source revision mismatch')
    require(version['BPIROUTER_SRC_HASH'] == build['src'] and
            re.fullmatch(r'[0-9a-f]{64}', build['src']), 'UI source hash mismatch')
    require(version['BPIROUTER_BUILT'] == build['built'], 'UI build time mismatch')
    rows = inventory(root)
    require(build['inventory'] == contract.sha256(root / INVENTORY), 'inventory hash mismatch')
    regular = {p for p, value in tree(root).items() if value[0] == 'file'}
    # OpenWrt's package file list is generated outside deploy/build.sh and
    # therefore outside art/inventory. It is still compared byte-for-byte.
    package_list = {'lib/apk/packages/bpirouter-ui.list'}
    require(regular - package_list == set(rows) | {INVENTORY, BUILD},
            'package inventory does not cover all files')
    with tempfile.TemporaryDirectory(prefix='bpir-promotion-art-') as directory:
        dest = pathlib.Path(directory) / 'files'; dest.mkdir()
        used = set()
        for path in set(rows) | {INVENTORY}:
            mapped = feed_path(path)
            require(mapped not in used, 'artifact mapping collision')
            used.add(mapped)
            target = dest / mapped; target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(root / path, target)
        script = pathlib.Path(directory) / 'artifact-hash.sh'; script.write_bytes(hash_script)
        digest = subprocess.check_output(['bash', str(script), 'art', str(dest)], text=True).strip()
        require(digest == build['art'], 'artifact hash mismatch')
    return rows


def compare_payloads(rc_root, stable_root, rc, stable, hash_script):
    rows = [check_payload(root, lock, hash_script) for root, lock in
            ((rc_root, rc), (stable_root, stable))]
    left, right = tree(rc_root), tree(stable_root)
    require(left.keys() == right.keys(), 'package paths differ')
    for path in left:
        if path in VARIABLE:
            require(left[path][:2] == right[path][:2], 'derived file type/mode changed')
        else:
            require(left[path] == right[path], 'package payload changed: ' + path)
    for path, separator, allowed in ((VERSION, '=', {'BPIROUTER_VERSION', 'BPIROUTER_BUILT'}),
                                    (BUILD, ' ', {'inventory', 'art', 'built'})):
        require(normalized_fields(rc_root / path, separator, allowed) ==
                normalized_fields(stable_root / path, separator, allowed),
                'unapproved manifest/version change: ' + path)
    def normalized_inventory(root, entries):
        version_row = entries[VERSION]
        replacement = '|'.join([version_row[0], version_row[1], '<size>', '<sha256>', version_row[4]])
        return sorted(replacement if line == '|'.join(version_row) else line
                      for line in (root / INVENTORY).read_text().splitlines())
    require(normalized_inventory(rc_root, rows[0]) == normalized_inventory(stable_root, rows[1]),
            'inventory differs beyond the version entry')


def package_metadata(tool, package, artifact):
    dump = subprocess.check_output([str(tool), 'adbdump', str(package)], text=True)
    for key in ('name', 'version', 'arch'):
        values = re.findall(r'^  ' + key + r': (.+)$', dump, re.M)
        require(values == [artifact[key]], 'APK metadata mismatch: ' + key)
    # Compare dependencies, scripts and every other non-payload section.
    sections = {}; current = None
    for line in dump.splitlines():
        if line.startswith('#'):
            continue
        if line and not line[0].isspace():
            current = line.split(':', 1)[0]
            require(current not in sections, 'duplicate APK metadata section')
            sections[current] = []
        elif current:
            sections[current].append(line)
    require({'info', 'paths'} <= sections.keys(), 'incomplete APK metadata')
    directory = ''; filename = ''; normalized = []
    for line in sections['paths']:
        if line.startswith('  - name: '):
            directory = line.removeprefix('  - name: ')
        if line.startswith('      - name: '):
            filename = line.removeprefix('      - name: ')
        if directory + '/' + filename in VARIABLE and re.match(r'^        (size|hash): ', line):
            line = line.split(':', 1)[0] + ': <derived>'
        normalized.append(line)
    sections['paths'] = normalized
    sections['info'] = [line for line in sections['info']
                        if not re.match(r'^  (version|hashes|installed-size): ', line)]
    return sections


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('rc-lock', 'stable-lock', 'rc-downloads', 'stable-downloads', 'rc-ui', 'stable-ui', 'ui-repo'):
        parser.add_argument('--' + name, type=pathlib.Path, required=True)
    parser.add_argument('--apk-tool', type=pathlib.Path,
                        default=HERE.parent / 'openwrt/staging_dir/host/bin/apk')
    args = parser.parse_args()
    rc, stable = (contract.load(str(p)) for p in (args.rc_lock, args.stable_lock))
    check_inputs(rc, stable, args.rc_downloads, args.stable_downloads)
    script = subprocess.check_output(['git', '-C', str(args.ui_repo), 'show',
                                     rc['repos']['bpirouter-ui'] + ':deploy/artifact-hash.sh'])
    with tempfile.TemporaryDirectory(prefix='bpir-promotion-') as directory:
        roots = []; metadata = []
        for label, lock, package in (('rc', rc, args.rc_ui), ('stable', stable, args.stable_ui)):
            artifact = lock['ui_artifacts'][0]
            require(package.name == artifact['file'] and contract.sha256(package) == artifact['sha256'],
                    label + ' UI package name/hash mismatch')
            metadata.append(package_metadata(args.apk_tool, package, artifact))
            root = pathlib.Path(directory) / label; root.mkdir()
            subprocess.run([str(args.apk_tool), 'extract', '--allow-untrusted', '--destination',
                            str(root), str(package)], check=True, stdout=subprocess.DEVNULL)
            roots.append(root)
        require(metadata[0] == metadata[1], 'APK metadata/scripts changed')
        compare_payloads(*roots, rc, stable, script)
    print('PASS: W6 input/download locks and UI packages differ only as permitted.')
    for label, path in (('rc_lock', args.rc_lock), ('stable_lock', args.stable_lock),
                        ('rc_ui', args.rc_ui), ('stable_ui', args.stable_ui)):
        print(label + '_sha256=' + contract.sha256(path))
    print('Firmware identity checks and per-SKU startup/version/network smoke remain required.')


if __name__ == '__main__':
    try:
        main()
    except (ValueError, KeyError, OSError, subprocess.CalledProcessError) as exc:
        raise SystemExit('FAIL: ' + str(exc))
