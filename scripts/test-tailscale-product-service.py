#!/usr/bin/env python3
"""Exercise the patched OpenWrt init entry without starting any real service."""

from pathlib import Path
import argparse
import os
import shutil
import subprocess
import tempfile

BUILD = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('packages_feed', type=Path)
parser.add_argument('--prepared', action='store_true', help='require the patch in the supplied source')
args = parser.parse_args()
source = args.packages_feed.resolve()
patches = [BUILD / 'patches/common/packages' / name for name in (
    '007-tailscale-product-service.patch', '008-tailscale-dependency-record.patch',
    '009-tailscale-self-key-expiry.patch', '010-tailscale-omit-peerapi.patch')]

with tempfile.TemporaryDirectory(prefix='bpir-s2s-service-') as directory:
    root = Path(directory)
    feed = root / 'feed'
    for name in ('Makefile', 'files/tailscale.init', 'files/tailscale.conf'):
        target = feed / 'net/tailscale' / name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source / 'net/tailscale' / name, target)
    expiry_patch = Path('net/tailscale/patches/102-self-key-expiry-status.patch')
    if (source / expiry_patch).exists():
        (feed / expiry_patch).parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source / expiry_patch, feed / expiry_patch)
    for patch in patches:
        if not args.prepared:
            check = subprocess.run(['git', '-C', str(feed), 'apply', '--check', str(patch)],
                                   capture_output=True)
            if check.returncode == 0:
                subprocess.run(['git', '-C', str(feed), 'apply', str(patch)], check=True)
        subprocess.run(['git', '-C', str(feed), 'apply', '--reverse', '--check', str(patch)], check=True)
    # peerapi runs inside tailscaled, outside the S2S nftables guard.
    tags = [line.split(':=', 1)[1].strip().split(',') for line in
            (feed / 'net/tailscale/Makefile').read_text().splitlines() if line.startswith('GO_PKG_TAGS:=')]
    assert len(tags) == 1 and {'ts_omit_peerapiserver', 'ts_omit_wakeonlan',
                               'ts_omit_advertiseexitnode'} <= set(tags[0]), tags
    init = feed / 'net/tailscale/files/tailscale.init'
    subprocess.run(['sh', '-n', str(init)], check=True)

    helper = root / 'apid'
    helper.write_text('''#!/bin/sh
printf '%s\\n' "$*" >> "$CALLS"
echo secret-auth-url
echo secret-auth-url >&2
exit "$CHECK_STATUS"
''')
    helper.chmod(0o700)
    daemon = root / 'tailscaled'
    daemon.write_text('''#!/bin/sh
printf '%s %s\\n' "$TS_NO_LOGS_NO_SUPPORT" "$*" >> "$CLEANUP"
echo secret-auth-url >&2
''')
    daemon.chmod(0o700)
    # Replace executables only; execute the shipped shell control flow unchanged.
    fixture = root / 'init'
    fixture.write_text(init.read_text().replace('/usr/bin/bpirouter-apid', str(helper))
                       .replace('/usr/sbin/tailscaled', str(daemon)))
    harness = root / 'harness'
    harness.write_text('''set -eu
procd_open_instance() { echo open >> "$PARAMS"; }
procd_close_instance() { echo close >> "$PARAMS"; }
procd_set_param() { printf '%s\\n' "$*" >> "$PARAMS"; }
. "$INIT"
if [ "$ACTION" = start ]; then start_service; else service_stopped; fi
''')
    for status in (0, 3, 1, 127):
        calls, params, cleanup = (root / f'{name}-{status}' for name in ('calls', 'params', 'cleanup'))
        env = dict(os.environ, CHECK_STATUS=str(status), CALLS=str(calls), PARAMS=str(params),
                   CLEANUP=str(cleanup), INIT=str(fixture), ACTION='start')
        result = subprocess.run(['sh', str(harness)], env=env, capture_output=True, text=True)
        assert result.returncode == (0 if status in (0, 3) else 1), result
        assert result.stdout == result.stderr == '', result
        assert calls.read_text() == '--s2s-service=check\n'
        if status == 0:
            assert params.read_text().splitlines() == [
                'open', f'command {helper} --s2s-service=run',
                'env TS_NO_LOGS_NO_SUPPORT=true', 'respawn', 'stdout 0', 'stderr 0', 'close',
            ]
        else:
            assert not params.exists(), 'disabled/failed check registered a process'
        assert not cleanup.exists(), 'startup ran daemon cleanup before policy'
        env['ACTION'] = 'stopped'
        result = subprocess.run(['sh', str(harness)], env=env, capture_output=True, text=True)
        assert result.returncode == 0 and result.stdout == result.stderr == '', result
        assert cleanup.read_text() == 'true --cleanup\n'

    # Execute the shipped installation recipe. The fake Go tool supplies
    # build-info records, not an all-platform go.mod dependency inventory.
    package = root / 'package'
    (package / 'licenses').mkdir(parents=True)
    for name in ('LICENSE', 'licenses/tailscale.md', 'go.mod', 'go.sum'):
        (package / name).write_text('upstream ' + name + '\n')
    binary_dir = root / 'bin'
    binary_dir.mkdir()
    (binary_dir / 'tailscaled').write_text('fixture binary\n')
    go = root / 'host/lib/go-test/bin/go'
    go.parent.mkdir(parents=True)
    linked = '\tdep\texample.org/linked\tv1.2.3\th1:fixture\n'
    go.write_text('#!/bin/sh\n[ "$GO_FAIL" != 1 ] || exit 1\n'
                  'printf "%s\\n" "$4: go1.test"\n'
                  'printf \'\\tpath\\ttailscale.com/cmd/tailscaled\\n\'\n'
                  'printf \'\\tdep\\texample.org/linked\\tv1.2.3\\th1:fixture\\n\'\n')
    go.chmod(0o700)
    recipe = (feed / 'net/tailscale/Makefile').read_text().split('define Package/tailscale/install\n', 1)[1].split('\nendef', 1)[0]
    makefile = root / 'install.mk'
    makefile.write_text(f'''INSTALL_DIR=mkdir -p
INSTALL_BIN=install -m0755
INSTALL_DATA=install -m0644
LN=ln -sf
PKG_BUILD_DIR={package}
GO_PKG_BUILD_BIN_DIR={binary_dir}
STAGING_DIR_HOSTPKG={root / 'host'}
GO_HOST_VERSION=test
.PHONY: install
install:
''' + recipe.replace('$(1)', '$(DESTDIR)') + '\n')
    for failed in (False, True):
        destination = root / ('failed' if failed else 'installed')
        result = subprocess.run(['make', '-f', str(makefile), 'install', f'DESTDIR={destination}'],
                                cwd=feed / 'net/tailscale', env=dict(os.environ, GO_FAIL=str(int(failed))),
                                capture_output=True, text=True)
        assert (result.returncode != 0) == failed, result
        record = destination / 'usr/share/tailscale'
        if not failed:
            assert (record / 'modules.txt').read_text() == linked
            for name in ('LICENSE', 'licenses/tailscale.md', 'go.mod', 'go.sum'):
                assert (record / Path(name).name).read_bytes() == (package / name).read_bytes()
        else:
            assert not (record / 'modules.txt').exists(), 'failed build-info read published a record'

print('PASS: init lifecycle, patch application, peerapi omission, dependency records and upstream notice installation')
