#!/bin/bash
# Verify 4E boot inputs in scratch, without preparing OpenWrt
# or claiming a compiled FIP / hardware result. Shared templates stay unchanged.
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
BUILD_DIR=$(dirname "$SCRIPT_DIR")
TMP=$(mktemp -d -t bpir-4e-bootchain-XXXXXX)
trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
TREE="$TMP/tree"
mkdir -p "$TREE"

# Only the shared board C file is modified; all other 4E payload files are new.
# Read it from the pinned source archive, not the already patched 8X build tree.
tar -xjf "$BUILD_DIR/openwrt/dl/u-boot-2025.10.tar.bz2" \
    -C "$TREE" --strip-components=1 u-boot-2025.10/board/mediatek/mt7988/mt7988_rfb.c
for name in 305-mt7988-generic-reset-button-ignore-env.patch 310-mt7988-select-rootdisk.patch; do
    git -C "$BUILD_DIR/openwrt" show \
        "HEAD:package/boot/uboot-mediatek/patches/$name" > "$TMP/$name"
    (cd "$TREE" && git apply "$TMP/$name")
done

PATCHES="$BUILD_DIR/patches/bpi-r4-pro-4e"
(cd "$TREE" && git apply "$PATCHES/uboot/450-add-bpi-r4-pro-4e.patch")
for medium in emmc sdmmc snand; do
    cmp "$TREE/defenvs/bananapi_bpi-r4-pro-4e_${medium}_env" \
        "$BUILD_DIR/env-templates/pristine/bananapi_bpi-r4-pro-4e_${medium}_env" \
        || fail "$medium pristine does not match the additive board patch"
done
for patch in "$PATCHES"/uboot/z*.patch; do
    (cd "$TREE" && git apply "$patch")
done

# Regenerate in scratch with the real shared generator. Compare patches AND
# applied environments so an unchanged but stale generated patch cannot pass.
cp -a "$BUILD_DIR/env-templates" "$TMP/env-templates"
mkdir -p "$TMP/patches/bpi-r4-pro-4e/uboot"
bash "$TMP/env-templates/gen-defenv.sh" --board bpi-r4-pro-4e >/dev/null
for medium in emmc sdmmc snand; do
    cmp "$TMP/patches/bpi-r4-pro-4e/uboot/z06-bpirouter-defenv-$medium.patch" \
        "$PATCHES/uboot/z06-bpirouter-defenv-$medium.patch" \
        || fail "$medium environment patch differs from the shared generator"
done

mkdir -p "$TMP/package/package/boot/uboot-mediatek"
git -C "$BUILD_DIR/openwrt" show HEAD:package/boot/uboot-mediatek/Makefile \
    > "$TMP/package/package/boot/uboot-mediatek/Makefile"
(cd "$TMP/package" && git apply "$PATCHES/base-files/450-uboot-mediatek-add-bpi-r4-pro-4e.patch")

python3 - "$TREE" "$TMP/package/package/boot/uboot-mediatek/Makefile" <<'PY'
import os, pathlib, re, subprocess, sys
tree = pathlib.Path(sys.argv[1])
packages = pathlib.Path(sys.argv[2]).read_text()
base = 'bananapi_bpi-r4-pro-4e'
for medium, bootdev in [('emmc', 'emmc'), ('sdmmc', 'sdmmc'), ('snand', 'spim-nand-ubi')]:
    name = f'mt7988_{base}-{medium}'
    block = packages.split(f'define U-Boot/{name}\n', 1)[1].split('\nendef', 1)[0]
    assert 'BL2_DDRTYPE:=comb\n' in block
    assert f'DEPENDS:=+trusted-firmware-a-mt7988-{bootdev}-comb\n' in block + '\n'
    assert f'\t{name} \\' in packages
    config = (tree / f'configs/mt7988a_{base}-{medium}_defconfig').read_text()
    for key in ['CONFIG_BOOTDELAY=1', 'CONFIG_AUTOBOOT_STOP_STR=" "',
                'CONFIG_BOOTCOUNT_LIMIT=y', 'CONFIG_BOOTCOUNT_ENV=y',
                'CONFIG_BOOTCOUNT_ALTBOOTCMD=y', 'CONFIG_CMD_I2C=y',
                'CONFIG_DM_PCA953X=y', 'CONFIG_BUTTON_GPIO=y', 'CONFIG_USE_PREBOOT=y']:
        assert key in config, (medium, key)
    for key in ['CONFIG_DEFAULT_DEVICE_TREE', 'CONFIG_ENV_DEFAULT_ENV_TEXT_FILE']:
        value = re.search(r'^' + key + r'="([^"]+)"$', config, re.M)[1]
        path = tree / ('arch/arm/dts/' + value + '.dts' if key.endswith('TREE') else value)
        assert path.is_file(), path
    env = dict(line.split('=', 1) for line in
               (tree / f'defenvs/{base}_{medium}_env').read_text().splitlines())
    assert env['bootconf'] == 'config-mt7988a-bananapi-bpi-r4-pro-4e'
    assert env['bootfile'] == 'openwrt-mediatek-filogic-bananapi_bpi-r4-pro-4e-squashfs-sysupgrade.itb'
    assert env['bootled_pwr'] == 'act' and env['bootled_rec'] == 'err'
    assert not re.search(r'@[A-Z_]+@', str(env))
    assert env['preboot'] == 'run r4pro_4e_select_wan'
    selector = env['r4pro_4e_select_wan']
    assert not re.search(r'\b(saveenv|mmc|ubi|mtd|reset)\b', selector)
    # Execute generated command bodies under a host shell with inert boot/read
    # commands. This checks command flow/arguments, not U-Boot hush or hardware.
    runner = r'''
set -e
setenv() { [ "$#" -eq 2 ] || exit 91; printf -v "$1" '%s' "$2"; }
run() {
    case "$1" in
        r4pro_4e_select_wan) eval "$r4pro_4e_select_wan" ;;
        *_read_production|*_write_production) : ;;
        *) exit 92 ;;
    esac
}
led() { :; }
tftpboot() { :; }
iminfo() { :; }
env() { [ "$1" = exists ] && declare -p "$2" >/dev/null 2>&1; }
bootm() { printf 'BOOTM=%s\n' "$1"; }
eval "$BPIR_TEST_COMMAND"
printf 'SELECTOR=[%s]\n' "$r4pro_4e_wan_media"
'''
    boot_commands = [key for key, value in env.items() if re.search(r'\bbootm\b', value)]
    assert {'boot_production', 'boot_tftp_production'} <= set(boot_commands)
    for raw in [None, '', 'copper', 'sfp', 'invalid', 'SFP']:
        chosen = 'sfp' if raw == 'sfp' else 'copper'
        for key in ['preboot'] + boot_commands:
            # U-Boot hush permits an empty then arm; Bash needs an explicit no-op.
            command = env[key].replace('then else', 'then :; else')
            values = dict(os.environ, **env, PATH='/nonexistent', BPIR_TEST_COMMAND=command)
            values['bootconf'] = 'stale-config#stale-overlay'
            values['r4pro_4e_wan_overlay'] = 'stale-overlay'
            values.pop('r4pro_4e_wan_media', None)
            if raw is not None:
                values['r4pro_4e_wan_media'] = raw
            run_result = subprocess.run(['/bin/bash', '-c', runner], env=values, text=True,
                                        capture_output=True)
            assert run_result.returncode == 0, (medium, key, raw, run_result.stderr)
            result = run_result.stdout
            assert f'SKU=bpi-r4-pro-4e selector=[{raw or ""}] selected={chosen}' in result
            assert ('WARNING:' in result) == (raw not in [None, '', 'copper', 'sfp'])
            assert f'SELECTOR=[{raw or ""}]' in result
            args = [line.removeprefix('BOOTM=') for line in result.splitlines() if line.startswith('BOOTM=')]
            if key == 'preboot':
                assert not args
            else:
                assert len(args) == 1
                configs = [c for c in args[0].split('#')[1:] if c]
                assert configs[0] == 'config-mt7988a-bananapi-bpi-r4-pro-4e'
                assert configs.count('mt7988a-bananapi-bpi-r4-pro-4e-wan-' + chosen) == 1
                assert sum('-wan-' in c for c in configs) == 1
                assert not any('stale' in c for c in configs)
                if key != 'boot_tftp':
                    storage = 'sd' if medium == 'sdmmc' else 'emmc'
                    assert 'mt7988a-bananapi-bpi-r4-pro-4e-' + storage in configs
    if medium == 'emmc':
        assert 'button reset' in env['bootcmd'] and 'golden_restore' in env['bootcmd']
        assert env['active_slot'] == 'a' and env['bootlimit'] == '3'
        assert 'run ab_verify_rollback' in env['altbootcmd']
        assert 'production_b' in env['gr_slots']
    elif medium == 'sdmmc':
        assert 'run ubi_init' in env['bootcmd']
        assert 'run ubi_init_emmc_install' in env['ubi_init']
    else:
        assert 'run emmc_init' in env['bootcmd']
        assert 'run emmc_write_production_b' in env['emmc_init_openwrt']
dts = (tree / 'arch/arm/dts/mt7988a-bananapi-bpi-r4-pro-4e.dtsi').read_text()
assert '"bananapi,bpi-r4-pro-4e"' in dts
assert 'gpios = <&pio 13 GPIO_ACTIVE_LOW>' in dts
assert 'gpios = <&pca9555 14 GPIO_ACTIVE_HIGH>' in dts
assert 'gpios = <&pca9555 15 GPIO_ACTIVE_HIGH>' in dts
code = (tree / 'board/mediatek/mt7988/mt7988_rfb.c').read_text()
assert 'bpirouter,booted-slot' in code and '!strcmp(slot, "b")' in code
for path in tree.rglob('*'):
    if path.is_file():
        content = path.read_text()
        assert not re.search(r'pro-8x|comb-4bg|as21|AS21|wan-phy-reset|lan-phy-reset', content), path
print('PASS: 4E patches apply; three comb packages, pristine/template identity, bootcount, LEDs and recovery wiring agree')
PY

# Shared template hooks must leave all six existing board outputs unchanged.
for board in bpi-r3 bpi-r3-mini bpi-r4 bpi-r4-lite bpi-r4-pro openwrt-one; do
    mkdir -p "$TMP/patches/$board/uboot"
    bash "$TMP/env-templates/gen-defenv.sh" --board "$board" >/dev/null
    for patch in "$TMP/patches/$board/uboot/"*.patch; do
        cmp "$patch" "$BUILD_DIR/patches/$board/uboot/${patch##*/}" \
            || fail "shared template changed $board/${patch##*/}"
    done
done
echo 'PASS: three-media WAN selection command checks and unchanged six-board templates'

# Check that the implemented 4E boot chain enables A/B provisioning.
source "$SCRIPT_DIR/boards.sh"
board_init bpi-r4-pro-4e
[ "$AB_ENABLED" = yes ] || fail "4E A/B execution plane (env seed) is not enabled"
[ "$BOARD_IMPLEMENTED" = yes ] || fail "4E is not declared implemented"
case " $VALID_BOARDS " in
    *" bpi-r4-pro-4e "*) fail "step 2 prematurely joined the release set" ;;
esac
