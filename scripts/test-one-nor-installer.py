#!/usr/bin/env python3
# Copyright (C) 2026 Ning <mimallaus@gmail.com>
"""Apply the NOR patch and execute its environment with fake device commands.

Host ash checks the command flow; it does not emulate U-Boot, USB or NAND.
Run a NOR FIP build and board recovery separately before enabling this path.
"""
import argparse
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--prepared', action='store_true', help='require the patch in the supplied source')
args = parser.parse_args()
build = Path(__file__).resolve().parents[1]
openwrt = Path(os.environ.get("OPENWRT_DIR", build / "openwrt"))
uboot = Path(os.environ.get("UBOOT_DIR", openwrt / "build_dir/target-aarch64_cortex-a53_musl/"
                           "u-boot-mt7981_openwrt_one-ram/u-boot-2025.10"))
busybox = os.environ.get("BUSYBOX") or shutil.which("busybox")
assert busybox, "Install host busybox or set BUSYBOX to run the environment with ash"

with tempfile.TemporaryDirectory(prefix="one-nor-") as tmp:
    root = Path(tmp)
    (root / "configs").mkdir()
    name = "configs/mt7981_openwrt-one-nor_defconfig"
    shutil.copy2(uboot / name, root / name)
    env_name = "defenvs/openwrt-one-nor-installer_env"
    if (uboot / env_name).is_file():
        (root / "defenvs").mkdir()
        shutil.copy2(uboot / env_name, root / env_name)
    patch = str(build / "patches/openwrt-one/uboot/z09-nor-usb-installer.patch")
    if not args.prepared:
        check = subprocess.run(["git", "apply", "--check", patch], cwd=root, capture_output=True)
        if check.returncode == 0:
            subprocess.run(["git", "apply", patch], cwd=root, check=True)
    subprocess.run(["git", "apply", "--reverse", "--check", patch], cwd=root, check=True)
    config = (root / name).read_text()
    assert "CONFIG_ENV_IS_NOWHERE=y" in config
    assert "CONFIG_AUTOBOOT_MENU_SHOW=y" not in config
    assert 'CONFIG_ENV_DEFAULT_ENV_TEXT_FILE="defenvs/openwrt-one-nor-installer_env"' in config
    entries = dict(line.split("=", 1) for line in
                   (root / "defenvs/openwrt-one-nor-installer_env").read_text().splitlines() if line)
    commands = {"preboot", "usb_image", "verify_src", "verify_nand", "flash_nand", "install", "bootcmd"}
    script = "\n".join(f"{key}() {{ {value}; }}" if key in commands else f"{key}={shlex.quote(value)}"
                       for key, value in entries.items())
    # Ash does not allow dots in function names; only rename the mocked commands.
    script = script.replace("itest.l ", "itest_l ").replace("cmp.b ", "cmp_b ")
    # Everything that could touch hardware is substituted. Unexpected commands
    # fail the case; the expected MTD sequence is independently asserted below.
    harness = r'''
setenv() { export "$1=$2"; }
run() { for command in "$@"; do "$command" || return $?; done; }
led() { :; }
button() { [ "$1" = front ] && [ "$CASE" != no_button ]; }
usb() { [ "$CASE" != no_usb ]; }
fatsize() {
    case "$3" in
        snand-factory.bin)
            [ "$CASE" != missing_image ] || return 1
            filesize="$IMAGE_SIZE" ;;
        snand-factory.crc)
            [ "$CASE" != missing_crc ] || return 1
            filesize=4
            [ "$CASE" != short_crc ] || filesize=3
            [ "$CASE" != long_crc ] || filesize=5 ;;
        *) exit 90 ;;
    esac
}
fatload() {
    printf '%s\n' "load $*" >> "$TRACE"
    case "$4" in
        snand-factory.bin)
            loads=$((${loads:-0} + 1))
            if [ "$CASE" = media_then_bad_crc ] && [ "$loads" -lt 3 ]; then return 1; fi
            [ "$CASE" != image_load_failed ] || return 1
            filesize="$IMAGE_SIZE"
            [ "$CASE" != image_short_read ] || filesize=100000 ;;
        snand-factory.crc)
            [ "$CASE" != crc_load_failed ] || return 1
            filesize=4
            [ "$CASE" != crc_short_read ] || filesize=3 ;;
        *) exit 91 ;;
    esac
}
itest_l() { [ "$((0x${1#0x}))" "$2" "$((0x${3#0x}))" ]; }
crc32() {
    [ "$*" = "0x46000000 $IMAGE_SIZE 0x4f000004" ] || exit 97
    [ "$CASE" != crc_command_failed ]
}
cmp_b() {
    case "$1" in
        0x4f000000)
            [ "$*" = "0x4f000000 0x4f000004 0x4" ] || exit 98
            [ "$CASE" != bad_crc ] && [ "$CASE" != media_then_bad_crc ] ;;
        0x46000000)
            [ "$*" = "0x46000000 0x54000000 $IMAGE_SIZE" ] || exit 99
            [ "$CASE" != bad_readback ] ;;
        *) exit 92 ;;
    esac
}
mtd() {
    printf '%s\n' "mtd $*" >> "$TRACE"
    [ "$2" = spi-nand0 ] || exit 93
    [ "$CASE" != "${1}_failed" ]
}
reset() { exit 94; }
saveenv() { exit 95; }
bootm() { exit 96; }
'''
    cases = ["no_button", "no_usb", "missing_image", "empty_image", "too_small", "too_large",
             "image_load_failed", "image_short_read", "missing_crc", "short_crc", "long_crc",
             "crc_load_failed", "crc_short_read", "crc_command_failed", "bad_crc",
             "erase_failed", "write_failed", "read_failed", "bad_readback", "success", "max_size"]
    for case in cases:
        size = {"empty_image": "0", "too_small": "100000", "too_large": "9000001",
                "max_size": "9000000"}.get(case, "4ce0000")
        trace = root / "trace"
        trace.write_text("")
        result = subprocess.run([busybox, "ash", "-c", harness + script + "\nrun preboot; run bootcmd"],
                                env=dict(os.environ, CASE=case, IMAGE_SIZE=size, TRACE=str(trace)),
                                text=True, capture_output=True, timeout=3)
        assert result.returncode == 0 and not result.stderr, (case, result)
        operations = trace.read_text().splitlines()
        writes = [line for line in operations if line.startswith("mtd ")]
        full = ["mtd erase spi-nand0", f"mtd write spi-nand0 0x46000000 0x0 {size}",
                f"mtd read spi-nand0 0x54000000 0x0 {size}"]
        length = {"erase_failed": 1, "write_failed": 2, "read_failed": 3,
                  "bad_readback": 3, "success": 3, "max_size": 3}.get(case, 0)
        assert writes == full[:length], (case, writes)
        assert ("INSTALL OK" in result.stdout) == (case in ("success", "max_size")), (case, result.stdout)
        input_failure = case not in ("no_button", "erase_failed", "write_failed", "read_failed",
                                      "bad_readback", "success", "max_size")
        nand_failure = case in ("erase_failed", "write_failed", "read_failed", "bad_readback")
        assert ("check the One flashkit and USB drive" in result.stdout) == input_failure, (case, result.stdout)
        assert ("NAND erase/write/verification failed" in result.stdout) == nand_failure, (case, result.stdout)
        assert ("INSTALL FAILED" in result.stdout) == (input_failure or nand_failure), (case, result.stdout)
        if case == "no_button":
            assert not operations and "hold the front button" in result.stdout
        if case in ("empty_image", "too_small", "too_large"):
            assert not operations, (case, operations)
        if case in ("success", "max_size"):
            assert operations[:2] == [f"load usb 0 0x46000000 snand-factory.bin {size}",
                                      "load usb 0 0x4f000000 snand-factory.crc 4"]
            assert "power off, select NAND boot" in result.stdout

    # Both file-size checks must use the same whole-disk-capable selector.
    # This verifies command arguments, not real USB partition discovery.
    assert re.findall(r"fatsize (\S+) (\S+)", entries["usb_image"]) == [("usb", "0"), ("usb", "0")]
    # The two loaded regions and readback must not overlap at the accepted maximum.
    image_start = int(entries["loadaddr"], 16)
    image_limit = int(re.search(r"itest.l \$imgsz -le (0x[0-9a-f]+)", entries["usb_image"])[1], 16)
    crc_start = int(re.search(r"fatload usb 0 (0x[0-9a-f]+) \$bootfile_factory_crc", entries["usb_image"])[1], 16)
    crc_result = int(re.search(r"crc32 \$loadaddr \$imgsz (0x[0-9a-f]+)", entries["verify_src"])[1], 16)
    readback = int(re.search(r"mtd read spi-nand0 (0x[0-9a-f]+)", entries["verify_nand"])[1], 16)
    assert image_start + image_limit <= crc_start
    assert crc_start + 4 <= crc_result and crc_result + 4 <= readback
    assert readback + image_limit <= 0x40000000 + 1024**3

    # Build gates check the actual prepared recipe, without repairing it first.
    if args.prepared:
        recipe = (openwrt / "target/linux/mediatek/image/filogic.mk").read_text()
    else:
        archive = subprocess.check_output(["git", "-C", str(openwrt), "archive",
                                           "f0a60eee2fe051741c643ea6118718aae1ef17fb",
                                           "include/image-commands.mk",
                                           "target/linux/mediatek", "package/boot/uboot-mediatek/Makefile",
                                           "package/base-files/files/lib/upgrade/fwtool.sh"])
        subprocess.run(["tar", "-x", "-C", str(root)], input=archive, check=True)
        patches = [build / "patches/common/base-files/001-modify-filogic-image-format.patch"]
        patches += sorted((build / "patches/openwrt-one/base-files").glob("*.patch"))
        for patch in patches:
            subprocess.run(["git", "apply", str(patch)], cwd=root, check=True)
        recipe = (root / "target/linux/mediatek/image/filogic.mk").read_text()
    one = recipe.split("define Device/openwrt_one\n", 1)[1].split("\nendef", 1)[0]
    assert "nor-factory.bin" not in one
    assert "nor-ddr4 | check-size 256k" in one
    assert "openwrt_one-nor | check-size 512k" in one
    required = subprocess.check_output(["bash", "-c", 'source "$1"; board_init openwrt-one; '
                                        'printf "%s\\n" "$RELEASE_REQUIRED_FILES"',
                                        "test", str(build / "scripts/boards.sh")], text=True)
    assert "nor-factory.bin" not in required
    assert "nor-bl31-uboot.fip" in required and "nor-preloader.bin" in required
    # RAM provisioning may wait for missing media, but a failed write/readback
    # must return to the prompt instead of repeatedly erasing the whole NAND.
    ram = root / 'ram'
    ram.mkdir()
    ram_patch = build / 'patches/openwrt-one/uboot/z07-bpirouter-provision-uboot.patch'
    if args.prepared:
        for name in ('configs/mt7981_openwrt-one-ram_defconfig', 'defenvs/openwrt-one-ram_env'):
            (ram / name).parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(uboot / name, ram / name)
    else:
        subprocess.run(['git', 'apply', str(ram_patch)], cwd=ram, check=True)
    subprocess.run(['git', 'apply', '--reverse', '--check', str(ram_patch)], cwd=ram, check=True)
    ram_entries = dict(line.split('=', 1) for line in (ram / 'defenvs/openwrt-one-ram_env').read_text().splitlines())
    # The shipped legacy U-Boot hush has no break/continue commands. Host ash
    # supports them, so its successful execution alone cannot guard this defect.
    for key, value in ram_entries.items():
        assert not re.search(r'(?:^|;)\s*(?:break|continue)(?:\s|;|$)', value), (
            key, 'unsupported legacy U-Boot loop command')

    # The production recovery path starts with an already-attached old UBI.
    # A raw full-NAND replacement must not saveenv through that old mapping.
    nand = root / 'nand'
    (nand / 'defenvs').mkdir(parents=True)
    nand_name = 'defenvs/openwrt-one-spi-nand_env'
    source = uboot / nand_name if args.prepared else build / 'env-templates/pristine/openwrt-one-spi-nand_env'
    shutil.copy2(source, nand / nand_name)
    nand_patch = build / 'patches/openwrt-one/uboot/z06-bpirouter-defenv-spi-nand.patch'
    if not args.prepared:
        subprocess.run(['git', 'apply', str(nand_patch)], cwd=nand, check=True)
    subprocess.run(['git', 'apply', '--reverse', '--check', str(nand_patch)], cwd=nand, check=True)
    nand_entries = dict(line.split('=', 1) for line in (nand / nand_name).read_text().splitlines())
    template = dict(line.split('=', 1) for line in (build / 'env-templates/media/spi-nand.env.in').read_text().splitlines())
    for key in ('bootcmd', 'altbootcmd', 'usb_recover', 'nand_write_factory',
                'ab_seed', 'ethaddr_factory'):
        assert nand_entries[key] == template[key], key
    assert nand_entries['active_slot'] == 'a' and nand_entries['altcount'] == '0'

    # U-Boot can already have a temporary random ethaddr before first boot.
    # Only the existing initialization marker protects a saved product MAC.
    seed_keys = {'ab_seed', 'ethaddr_factory', 'ubi_create_env'}
    seed_script = '\n'.join(f'{key}() {{ {value}; }}' for key, value in nand_entries.items()
                            if key in seed_keys)
    seed_script = seed_script.replace('env readmem ', 'readmem ')
    seed_harness = r'''
setenv() { export "$1=$2"; }
run() { for command in "$@"; do "$command" || return $?; done; }
mtd() {
    printf '%s\n' "mtd $*" >> "$TRACE"
    [ "$*" = 'read factory 0x46000000 0x0 0x20000' ] || exit 90
    [ "$CASE" != read_failed ]
}
readmem() {
    printf '%s\n' "readmem $*" >> "$TRACE"
    [ "$*" = '-b ethaddr 0x4600002a 0x6' ] || exit 91
    [ "$CASE" != env_rejected ] || return 1
    setenv ethaddr "$FACTORY_MAC"
}
ubi() {
    printf '%s\n' "ubi $*" >> "$TRACE"
    case "$*" in
        'check ubootenv'|'check ubootenv2') return 1 ;;
        'create ubootenv 0x1f000 dynamic'|'create ubootenv2 0x1f000 dynamic') return 0 ;;
        *) exit 92 ;;
    esac
}
saveenv() { printf '%s\n' "saved $envset $ethaddr" >> "$TRACE"; }
'''
    seed_cases = [('fresh', '', '02:11:22:33:44:55'),
                  ('fresh_other', '', '02:aa:bb:cc:dd:ee'),
                  ('initialized', '1', '02:11:22:33:44:55'),
                  ('read_failed', '', '02:11:22:33:44:55'),
                  ('env_rejected', '', '02:11:22:33:44:55')]
    for case, marker, factory_mac in seed_cases:
        trace.write_text('')
        saved_mac = '02:99:88:77:66:55'
        setup = f'\nenvset={shlex.quote(marker)}; ethaddr={saved_mac}; eth1addr=02:66:55:44:33:22\n'
        result = subprocess.run([busybox, 'ash', '-c', seed_harness + seed_script + setup +
            'run ab_seed; printf "%s|%s|%s\\n" "$envset" "$ethaddr" "$eth1addr"'],
            env=dict(os.environ, CASE=case, FACTORY_MAC=factory_mac, TRACE=str(trace)),
            capture_output=True, text=True, timeout=3)
        assert result.returncode == 0 and not result.stderr, (case, result)
        calls = trace.read_text().splitlines()
        expected_calls = ['mtd read factory 0x46000000 0x0 0x20000',
                          'readmem -b ethaddr 0x4600002a 0x6',
                          'ubi check ubootenv', 'ubi create ubootenv 0x1f000 dynamic',
                          'ubi check ubootenv2', 'ubi create ubootenv2 0x1f000 dynamic',
                          'saved 1 ' + factory_mac]
        if case.startswith('fresh'):
            assert calls == expected_calls, (case, calls)
            assert result.stdout.strip() == f'1|{factory_mac}|02:66:55:44:33:22'
        else:
            count = {'initialized': 0, 'read_failed': 1, 'env_rejected': 2}[case]
            assert calls == expected_calls[:count], (case, calls)
            assert result.stdout.strip() == f'{marker}|{saved_mac}|02:66:55:44:33:22'

    recovery_cases = ['image_load_failed', 'bad_crc', 'crc_command_failed', 'erase_failed',
                      'write_failed', 'read_failed', 'bad_readback', 'success']
    recovery_count = 0
    for mode, env, entry, altcount in (
            ('ram', ram_entries, 'bootcmd', 0),
            ('nand', nand_entries, 'bootcmd', 0),
            ('nand', nand_entries, 'altbootcmd', 0),
            ('nand', nand_entries, 'altbootcmd', 4)):
        callable_keys = commands | {'provision', 'usb_recover', 'usb_read_factory', 'nand_write_factory',
                                    'usb_recover_done', 'altbootcmd', 'ab_seed', 'ab_setpart',
                                    'ab_verify_rollback', 'ethaddr_factory', 'ubi_create_env', 'ubi_prepare_rootfs',
                                    'ab_cfgswap', 'ubi_read_production', 'boot_production', 'boot_ubi'}
        script = '\n'.join(f'{key}() {{ {value}; }}' if key in callable_keys else f'{key}={shlex.quote(value)}'
                           for key, value in env.items())
        script = script.replace('itest.l ', 'itest_l ').replace('cmp.b ', 'cmp_b ')
        # U-Boot hush accepts an empty then arm; host ash requires a no-op.
        script = script.replace('then else', 'then :; else')
        setup = '\nsleep() { [ "$CASE" = media_then_bad_crc ] || exit 88; }\n'
        if mode == 'nand':
            # Run the real outer entries: neither normal boot nor slot fallback
            # may touch the old UBI mapping after a raw recovery attempt fails.
            setup += '''button() { [ "$1" = back ] && [ "$CASE" != no_button ]; }
setexpr() { export "$1=$(($2 + $4))"; }
ubi() { [ "$CASE" = no_button ] || exit 97; }
iminfo() { [ "$CASE" = no_button ] || exit 98; }
envset=1; active_slot=b; last_slot=b; bootcount=4; upgrade_available=1
'''
            setup += f'altcount={altcount}\n'
        for case in recovery_cases + (['no_usb', 'no_button'] if mode == 'nand' else ['media_then_bad_crc']):
            recovery_count += 1
            trace.write_text('')
            result = subprocess.run([busybox, 'ash', '-c', harness + script + setup + 'run ' + entry],
                                    env=dict(os.environ, CASE=case, IMAGE_SIZE='4ce0000', TRACE=str(trace)),
                                    capture_output=True, text=True, timeout=3)
            expected_rc = 94 if case == 'success' else (88 if case == 'image_load_failed' and mode == 'ram' else 0)
            if case == 'no_button':
                # Without a recovery request the ordinary boot/fallback still runs.
                expected_rc = 96 if entry == 'bootcmd' else 95
            assert result.returncode == expected_rc and not result.stderr, (
                mode, entry, altcount, case, result.returncode, result.stdout, result.stderr)
            writes = [line for line in trace.read_text().splitlines() if line.startswith('mtd ')]
            length = {'erase_failed': 1, 'write_failed': 2, 'read_failed': 3,
                      'bad_readback': 3, 'success': 3}.get(case, 0)
            expected = ['mtd erase spi-nand0', 'mtd write spi-nand0 0x46000000 0x0 4ce0000',
                        'mtd read spi-nand0 0x54000000 0x0 4ce0000']
            assert writes == expected[:length], (mode, entry, altcount, case, writes)
            success_text = 'PROVISION OK' if mode == 'ram' else 'USB restore done'
            assert (success_text in result.stdout) == (case == 'success'), (mode, entry, case, result.stdout)
            if mode == 'ram' and case in ('bad_crc', 'media_then_bad_crc'):
                assert result.stdout.count('flash/verify FAILED') == 1, (case, result.stdout)
                loads = [line for line in trace.read_text().splitlines()
                         if line.startswith('load usb 0 0x46000000 ')]
                assert len(loads) == (3 if case == 'media_then_bad_crc' else 1), (case, loads)

    print(f"PASS: {len(cases)} NOR, {recovery_count} RAM/NAND and {len(seed_cases)} factory MAC cases, memory bounds and artifact contract")
