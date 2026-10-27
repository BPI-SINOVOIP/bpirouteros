#!/bin/bash
# Source integration and synthetic rootfs checks: no prepare, firmware build or device writes.
set -euo pipefail
BUILD=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d -t bpir-4e-platform-XXXXXX)
trap 'rm -rf "$TMP"' EXIT
TREE="$TMP/tree"
mkdir -p "$TREE"
git -C "$BUILD/openwrt" archive f0a60eee2fe051741c643ea6118718aae1ef17fb \
    target/linux/mediatek package/boot/uboot-mediatek/Makefile \
    package/boot/uboot-tools/uboot-envtools/files/mediatek_filogic \
    package/kernel/linux/modules/netdevices.mk | tar -x -C "$TREE"
# The common image patch changes the ordinary comb provisioning layout.
(cd "$TREE" && git apply "$BUILD/patches/common/base-files/001-modify-filogic-image-format.patch")
for patch in "$BUILD"/patches/bpi-r4-pro-4e/base-files/*.patch; do
    (cd "$TREE" && git apply "$patch")
done
python3 - "$TREE" "$BUILD" "$TMP" <<'PY'
import importlib.util, pathlib, re, shlex, subprocess, sys
tree, build, tmp = map(pathlib.Path, sys.argv[1:])
base = tree / 'target/linux/mediatek/filogic/base-files'
identity = 'bananapi,bpi-r4-pro-4e'
def shell(source, stubs='', tail=''):
    # Remove router library imports; execute the actual case/functions with
    # inert command boundaries. An absent PATH prevents real device utilities.
    source = re.sub(r'^\s*\. /[^\n]+$', '', source, flags=re.M)
    result = subprocess.run(['/bin/sh', '-ec', stubs + '\n' + source + '\n' + tail],
                            env={'PATH': '/nonexistent'}, text=True, capture_output=True)
    assert result.returncode == 0, result.stderr + result.stdout
    return result.stdout.strip()
board = f'board_name() {{ echo {identity}; }}'
# Exercise prepare's real generic-import block and injector, but only into
# scratch destinations. No prepare entry point, clone or target reset runs.
prepare = (build / 'scripts/prepare.sh').read_text()
injector = 'apply_patches() {' + prepare.split('apply_patches() {', 1)[1].split('\napply_patches "$BUILD_DIR/patches/common/kernel"', 1)[0]
imports = 'if [ "$BOARD" = bpi-r4-pro-4e ]; then' + prepare.split('if [ "$BOARD" = bpi-r4-pro-4e ]; then', 1)[1].split('\nfi', 1)[0] + '\nfi'
dest = tmp / 'generic'
setup = f'BUILD_DIR={shlex.quote(str(build))}; BOARD=bpi-r4-pro-4e; '
setup += f'KERNEL_BACKPORT_DIR={shlex.quote(str(dest / "backport"))}; KERNEL_PENDING_DIR={shlex.quote(str(dest / "pending"))}; '
setup += f'KERNEL_PATCH_DIR={shlex.quote(str(dest / "target"))}; '
setup += 'step() { :; }; ok() { :; }; fail() { echo "$*" >&2; exit 1; }; '
subprocess.run(['bash', '-ec', setup + injector + '\n' + imports], check=True, stdout=subprocess.DEVNULL)
for prefix, layer, count in [('930-', 'backport', 22), ('931-', 'pending', 19)]:
    originals = sorted((build / 'patches/bpi-r4-pro/kernel').glob(prefix + '*.patch'))
    expected = {p.name[7:]: p.read_bytes() for p in originals}
    actual = {p.name: p.read_bytes() for p in (dest / layer).iterdir()}
    assert len(expected) == count and actual == expected
# Every 8X-local fix to the shared MxL driver reaches the 4E unchanged, and
# no other 8X target patch does.
mxl_fixes = {p.name: p.read_bytes() for p in sorted((build / 'patches/bpi-r4-pro/kernel').glob('*.patch'))
             if not p.name.startswith(('930-', '931-')) and '+++ b/drivers/net/dsa/mxl862xx/' in p.read_text()}
assert list(mxl_fixes) == ['987-mxl862xx-retry-initial-phy-id.patch']
assert {p.name: p.read_bytes() for p in (dest / 'target').iterdir()} == mxl_fixes
network = (base / 'etc/board.d/02_network').read_text().split('\nboard_config_update', 1)[0]
assert shell(network, 'ucidef_set_interfaces_lan_wan() { echo "$1|$2"; }',
             f'mediatek_setup_interfaces {identity}') == \
       'lan1 lan3 mxl_lan0 mxl_lan1 mxl_lan2 mxl_lan3 sfp-lan|wan'
compat = (base / 'etc/board.d/05_compat-version').read_text()
assert shell(compat, board + '\nboard_config_update() { :; }; board_config_flush() { :; }; '
             'ucidef_set_compat_version() { echo "$1"; }') == '1.1'
platform = (base / 'lib/upgrade/platform.sh').read_text()
assert shell(platform, board + '\nfit_check_image() { echo "check:$1"; }; '
             'fit_do_upgrade() { echo "upgrade:$1"; }; '
             'CI_METHOD=emmc; emmc_copy_config() { echo copy; }',
             'platform_check_image fixture; platform_do_upgrade fixture; platform_copy_config') == \
       'check:fixture\nupgrade:fixture\ncopy'
envtools = (tree / 'package/boot/uboot-tools/uboot-envtools/files/mediatek_filogic').read_text()
envtools = envtools.replace('[ -e /etc/config/ubootenv ] && exit 0', '').replace('touch /etc/config/ubootenv', '')
stubs = board + '''
config_load() { :; }; config_foreach() { :; }
ubootenv_add_mmc() { echo "mmc:$*"; }
ubootenv_add_ubi_default() { echo ubi; }
'''
assert shell(envtools, stubs + '\nexport_fitblk_bootdev() { CI_METHOD=emmc; EMMC_KERN_DEV=/dev/mmcblk0p6; }') == \
       'mmc:ubootenv mmcblk0 0x0 0x40000 0x40000 1\nmmc:ubootenv mmcblk0 0x40000 0x40000 0x40000 1'
assert shell(envtools, stubs + '\nexport_fitblk_bootdev() { CI_METHOD=ubi; }') == 'ubi'
module = (tree / 'package/kernel/linux/modules/netdevices.mk').read_text().split('define KernelPackage/dsa-mxl862xx\n')[1].split('\nendef')[0]
assert 'AUTOLOAD:=$(call AutoLoad,18,mxl862xx_dsa)' in module
assert 'as21' not in module.lower()
config = (build / 'config/bpi-r4-pro-4e.config').read_text()
assert 'CONFIG_TARGET_mediatek_filogic_DEVICE_bananapi_bpi-r4-pro-4e=y' in config
for package in ['kmod-dsa-mxl862xx', 'mt7988-2p5g-phy-firmware']:
    assert f'CONFIG_PACKAGE_{package}=y' in config
assert not re.search(r'^CONFIG_PACKAGE_.*(?:as21|4bg).*=[ym]$', config, re.M)
assert not (base / 'etc/init.d/bpirouter-as21xxx-fw').exists()
# Shared generic stack and MxL driver fix participate in 4E provenance; 8X-only
# target changes must not change that 4E preparation input identity.
spec = importlib.util.spec_from_file_location('provenance', build / 'scripts/release-build-provenance.py')
p = importlib.util.module_from_spec(spec); spec.loader.exec_module(p)
scratch = tmp / 'inputs'
shared = scratch / 'patches/bpi-r4-pro/kernel'; shared.mkdir(parents=True)
driver = shared / '930-01-driver.patch'; driver.write_text('first\n')
a = p.prepare_input_id(scratch, 'bpi-r4-pro-4e')
driver.write_text('changed\n')
b = p.prepare_input_id(scratch, 'bpi-r4-pro-4e')
assert a != b
(shared / '996-8x-only.patch').write_text('not a 4E input\n')
assert b == p.prepare_input_id(scratch, 'bpi-r4-pro-4e')
fix = shared / '987-mxl862xx-retry-initial-phy-id.patch'; fix.write_text('first\n')
c = p.prepare_input_id(scratch, 'bpi-r4-pro-4e')
fix.write_text('changed\n')
assert len({b, c, p.prepare_input_id(scratch, 'bpi-r4-pro-4e')}) == 3
# Rootfs fixtures are intentionally not image evidence.
root = tmp / 'root'
for path in ['lib/modules/fixture', 'lib/firmware/mediatek/mt7988', 'etc/modules.d', 'etc/init.d']:
    (root / path).mkdir(parents=True)
for name in ['mxl862xx_dsa.ko', 'tag_mxl862xx.ko', 'tag_mxl862xx_8021q.ko']:
    (root / 'lib/modules/fixture' / name).write_bytes(b'fixture')
(root / 'lib/firmware/mediatek/mt7988/i2p5ge-phy-pmb.bin').write_bytes(b'fixture')
autoload = root / 'etc/modules.d/18-dsa-mxl862xx'; autoload.write_text('mxl862xx_dsa\n')
def gate():
    return subprocess.run(['sh', str(build / 'scripts/check-4e-rootfs.sh'), str(root)], capture_output=True).returncode
assert gate() == 0
foreign = root / 'etc/init.d/bpirouter-as21xxx-fw'; foreign.touch()
assert gate() != 0
foreign.unlink(); autoload.write_text('')
assert gate() != 0
autoload.write_text('mxl862xx_dsa\n')
(root / 'lib/firmware/mediatek/mt7988/i2p5ge-phy-pmb.bin').unlink()
assert gate() != 0
print('PASS: 4E platform/envtools/default ports, package policy, rootfs negatives and shared-input provenance')

# Exercise the actual policy extraction branch as an ordinary user. Only FIT
# transport is stubbed; SquashFS creation/extraction and the rootfs gate are real.
# A dev/console inode must not make an otherwise valid 4E payload fail inspection.
import os
assert os.geteuid() != 0, 'run this extraction regression as a non-root user, without fakeroot'
firmware = root / 'lib/firmware/mediatek/mt7988/i2p5ge-phy-pmb.bin'
firmware.write_bytes(b'fixture')
(root / 'dev').mkdir()
squashfs = tmp / 'fixture.squashfs'
mksquashfs = build / 'openwrt/staging_dir/host/bin/mksquashfs4'
policy = (build / 'scripts/check-firmware-policy.sh').read_text()
branch = 'if [ "$BOARD" = bpi-r4-pro-4e ] && [ "$ROLE" = sysupgrade ]; then'
branch += policy.split(branch, 1)[1].split('\nif [ "$NEEDS_FW" = no ]; then', 1)[0]
setup = '''
BOARD=bpi-r4-pro-4e; ROLE=sysupgrade; SCAN=fixture.itb; di=fixture_dump
die() { echo "$*" >&2; exit 1; }
fixture_dump() {
    if [ "$1" = -l ]; then echo ' Image 0 (rootfs-1)';
    else cp "$SQUASHFS" "$6"; fi
}
'''
setup += f'\nSCRIPT_DIR={shlex.quote(str(build / "scripts"))}; SQUASHFS={shlex.quote(str(squashfs))}; '
for index, forbidden in enumerate([None, 'etc/init.d/bpirouter-as21xxx-fw',
                                   'lib/firmware/as21x1x_fw.bin',
                                   'lib/modules/fixture/as21xxx.ko']):
    if forbidden:
        (root / forbidden).write_bytes(b'fixture AS21 payload')
    subprocess.run([str(mksquashfs), str(root), str(squashfs), '-noappend',
                    '-processors', '1', '-no-progress', '-p', 'dev/console c 0600 0 0 5 1'],
                   check=True, stdout=subprocess.DEVNULL)
    dest = tmp / f'policy-{index}'
    dest.mkdir()
    result = subprocess.run(['bash', '-ec', setup + f'TMP={shlex.quote(str(dest))};\n' + branch],
                            text=True, capture_output=True)
    if forbidden:
        assert result.returncode != 0 and '4E carries' in result.stdout + result.stderr, result
        (root / forbidden).unlink()
    else:
        assert result.returncode == 0, result.stdout + result.stderr
    assert not (dest / '4e-root/dev').exists(), 'inspection must not extract device nodes'
print('PASS: non-root policy extraction tolerates dev/console and still rejects AS21 service, firmware and driver payloads')
PY
