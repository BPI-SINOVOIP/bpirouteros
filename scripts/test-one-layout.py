#!/usr/bin/env python3
# Copyright (C) 2026 Ning <mimallaus@gmail.com>
"""Check One's layout patches and execute the old/new upgrade checks on the host."""
import argparse
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--prepared', action='store_true', help='test the supplied prepared OpenWrt source')
args = parser.parse_args()
build = Path(__file__).resolve().parents[1]
openwrt = Path(os.environ.get("OPENWRT_DIR", build / "openwrt"))
revision = "f0a60eee2fe051741c643ea6118718aae1ef17fb"
host = openwrt / "staging_dir/host"
jshn = host / "share/libubox/jshn.sh"
assert jshn.is_file(), "Build the OpenWrt host tools before running this check"
busybox = os.environ.get("BUSYBOX") or shutil.which("busybox")
assert busybox, "Install host busybox or set BUSYBOX to run the upgrade check with ash"

with tempfile.TemporaryDirectory(prefix="one-layout-") as tmp:
    root = Path(tmp)
    source = subprocess.check_output([
        "git", "-C", str(openwrt), "archive", revision,
        "include/image-commands.mk", "target/linux/mediatek",
        "package/base-files/files/lib/upgrade/fwtool.sh",
        "package/boot/uboot-mediatek/Makefile",
    ])
    subprocess.run(["tar", "-x", "-C", str(root)], input=source, check=True)
    fwtool = root / "package/base-files/files/lib/upgrade/fwtool.sh"
    old_check = fwtool.read_text()
    if args.prepared:
        for name in ("target/linux/mediatek/image/filogic.mk",
                     "target/linux/mediatek/filogic/base-files/etc/board.d/05_compat-version",
                     "package/base-files/files/lib/upgrade/fwtool.sh"):
            shutil.copy2(openwrt / name, root / name)
    else:
        patches = [build / "patches/common/base-files/001-modify-filogic-image-format.patch"]
        patches += sorted((build / "patches/openwrt-one/base-files").glob("*.patch"))
        for patch in patches:
            subprocess.run(["git", "apply", str(patch)], cwd=root, check=True)

    recipe = (root / "target/linux/mediatek/image/filogic.mk").read_text()
    one = recipe.split("define Device/openwrt_one\n", 1)[1].split("\nendef", 1)[0]
    assert one.count("ubinize-image fit-a squashfs-sysupgrade.itb 64") == 2
    assert "openwrt_one-squashfs-sysupgrade.itb=64" in one
    assert "DEVICE_COMPAT_VERSION := 2.0" in one
    message = re.search(r"DEVICE_COMPAT_MESSAGE := (.+)", one).group(1)
    assert "new flashkit UART installer" in message
    assert "reset-button USB restore is not supported" in message
    params = (build / "env-templates/boards/openwrt-one.params").read_text()
    assert re.search(r"^OVERLAY_SIZE=0x3000000\s", params, re.M)
    env_patch = (build / "patches/openwrt-one/uboot/z06-bpirouter-defenv-spi-nand.patch").read_text()
    prepare = next(line for line in env_patch.splitlines() if line.startswith("+ubi_prepare_rootfs="))
    assert "ubi create rootfs_data 0x3000000 dynamic" in prepare
    assert "ubi create rootfs_data_alt 0x3000000 dynamic" in prepare
    assert "ubi create cfgstage 0x800000 dynamic" in prepare
    # Factory images contain both FIT payloads plus UBI and bootloader data.
    # Check the runtime and RAM installers, not only the capacity declarations.
    ram_patch = (build / "patches/openwrt-one/uboot/z07-bpirouter-provision-uboot.patch").read_text()
    for installer in [env_patch, ram_patch]:
        readback = next(line for line in installer.splitlines() if line.startswith("+verify_nand="))
        assert "mtd read spi-nand0 0x54000000" in readback
        assert "cmp.b $loadaddr 0x54000000 $imgsz" in readback
    leb = 126976
    assert sum((m * 1024**2 + leb - 1) // leb for m in [64, 64, 48, 48, 8]) == 1919

    compat = (root / "target/linux/mediatek/filogic/base-files/etc/board.d/05_compat-version").read_text()
    compat = re.sub(r"^\s*\. /[^\n]+$", "", compat, flags=re.M)
    harness = '''
board_name() { echo openwrt,one; }
board_config_update() { :; }
board_config_flush() { :; }
ucidef_set_compat_version() { echo "$1"; }
'''
    assert subprocess.check_output(["sh", "-c", harness + compat], text=True).strip() == "2.0"

    # Use the real jshn parser and upgrade function. Only metadata extraction,
    # UCI and filesystem locations are substituted; no device commands run.
    harness = '''
v() { printf '%s\n' "$*"; }
uci() { printf '%s\n' "$DEVICE_COMPAT"; }
fwtool() { cp "$FIXTURE_META" "$3"; }
. "$FIXTURE_SCRIPT"
fwtool_check_image fixture.itb
'''
    cases = 0
    for installed, script in [("1.0", old_check), ("2.0", fwtool.read_text())]:
        for before, after in {
            "/usr/share/libubox/jshn.sh": str(jshn),
            "/tmp/sysupgrade.meta": str(root / "extracted.json"),
            "/tmp/sysinfo/board_name": str(root / "board_name"),
            "/tmp/sysinfo/oem_name": str(root / "oem_name"),
        }.items():
            script = script.replace(before, after)
        (root / "check.sh").write_text(script)
        # Old settings must not allow downgrading a new-layout device.
        for configured in (["1.0"] if installed == "1.0" else ["2.0", "1.0", ""]):
            for image in ["1.0", "2.0"]:
                for keep in ["0", "1"]:
                    (root / "board_name").write_text("openwrt,one\n")
                    key = "supported_devices" if image == "1.0" else "new_supported_devices"
                    (root / "meta.json").write_text(json.dumps({"compat_version": image, key: ["openwrt,one"],
                                                              "compat_message": message if image == "2.0" else ""}))
                    env = dict(os.environ, PATH=f"{host}/bin:/usr/bin:/bin",
                               DEVICE_COMPAT=configured, SAVE_CONFIG=keep,
                               FIXTURE_META=str(root / "meta.json"), FIXTURE_SCRIPT=str(root / "check.sh"))
                    result = subprocess.run([busybox, "ash", "-c", harness], env=env, text=True, capture_output=True)
                    assert result.returncode == (0 if image == installed else 1), (installed, configured, image, keep, result)
                    assert not result.stderr, result.stderr
                    if installed == "1.0" and image == "2.0":
                        assert message in result.stdout, result.stdout
                    cases += 1
        if installed == "2.0":
            (root / "board_name").write_text("bananapi,bpi-r4\n")
            (root / "meta.json").write_text(json.dumps({"compat_version": "1.1", "new_supported_devices": ["bananapi,bpi-r4"]}))
            env.update(DEVICE_COMPAT="1.1", SAVE_CONFIG="1")
            subprocess.run([busybox, "ash", "-c", harness], env=env, check=True)
    print(f"PASS: One patch application, 64/48 MiB layout, {cases} compatibility cases and other-board control")
