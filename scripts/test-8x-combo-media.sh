#!/bin/bash
# 8X combo media: verify the boot-time SFP selection inputs in scratch.
# U-Boot: the generated environment patches match the shared generator, the
# selectors compose bootconf for every selector value without writing the
# environment, and all three defconfigs enable preboot. Kernel: the 8X DTS is
# rebuilt from its patches, the base DTB keeps the copper board with only
# additions, and each SFP overlay swaps exactly its combo's nodes.
# Needs a prepared mediatek/filogic kernel tree for dtc, fdtoverlay and the SoC
# dtsi (BPIR_KERNEL_TREE overrides the build_dir default). Not a hardware result.
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
BUILD_DIR=$(dirname "$SCRIPT_DIR")
TMP=$(mktemp -d -t bpir-8x-combo-media-XXXXXX)
trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
PATCHES="$BUILD_DIR/patches/bpi-r4-pro"

# ── U-Boot environment ──
# Regenerate with the real shared generator; a stale checked-in patch fails.
cp -a "$BUILD_DIR/env-templates" "$TMP/env-templates"
for board in bpi-r3 bpi-r3-mini bpi-r4 bpi-r4-lite bpi-r4-pro bpi-r4-pro-4e openwrt-one; do
    mkdir -p "$TMP/patches/$board/uboot"
    bash "$TMP/env-templates/gen-defenv.sh" --board "$board" >/dev/null
    for patch in "$TMP/patches/$board/uboot/"*.patch; do
        cmp "$patch" "$BUILD_DIR/patches/$board/uboot/${patch##*/}" \
            || fail "$board/${patch##*/} differs from the shared generator"
    done
done

ENVTREE="$TMP/env"
mkdir -p "$ENVTREE/defenvs"
for medium in emmc sdmmc snand; do
    cp "$BUILD_DIR/env-templates/pristine/bananapi_bpi-r4-pro-8x_${medium}_env" "$ENVTREE/defenvs/"
    (cd "$ENVTREE" && patch -s -f -p1 < "$PATCHES/uboot/z06-bpirouter-defenv-$medium.patch")
done

# Final defconfigs: the 8X board patch creates them; later patches are applied
# the way OpenWrt does (patch -f -p1, default fuzz), restricted to them.
CFGTREE="$TMP/cfg"
mkdir -p "$CFGTREE"
python3 - "$CFGTREE" "$PATCHES/uboot" <<'PY'
import pathlib, re, subprocess, sys
tree, src = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
def defconfig_sections(text):
    keep = []
    for chunk in re.split(r'(?m)^(?=--- )', text):
        names = '\n'.join(chunk.split('\n', 2)[:2])
        if chunk.startswith('--- ') and re.search(r'configs/mt7988a_bananapi_bpi-r4-pro-8x-\w+_defconfig', names):
            keep.append(re.sub(r'(?m)^diff .*\n', '', chunk))
    return ''.join(keep)
for patch in [src / '450-add-bpi-r4-pro-8x.patch'] + sorted(src.glob('z*.patch')):
    body = defconfig_sections(patch.read_text())
    if body:
        subprocess.run(['patch', '-s', '-f', '-p1', '-d', str(tree)], input=body, text=True, check=True)
PY

python3 - "$ENVTREE/defenvs" "$CFGTREE/configs" <<'PY'
import os, pathlib, re, subprocess, sys
envdir, cfgdir = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
base = 'mt7988a-bananapi-bpi-r4-pro-8x'
for medium in ['emmc', 'sdmmc', 'snand']:
    config = (cfgdir / f'mt7988a_bananapi_bpi-r4-pro-8x-{medium}_defconfig').read_text()
    assert 'CONFIG_USE_PREBOOT=y\n' in config, medium
    env = dict(line.split('=', 1) for line in
               (envdir / f'bananapi_bpi-r4-pro-8x_{medium}_env').read_text().splitlines())
    assert env['bootconf'] == f'config-{base}'
    assert env['preboot'] == 'run r4pro_8x_select_media'
    for name in ['r4pro_8x_select_media', 'r4pro_8x_select_wan', 'r4pro_8x_select_lan']:
        assert not re.search(r'\b(saveenv|env save|mmc|ubi|mtd|reset)\b', env[name]), name
        # Stay within the selector length already proven on the 4E.
        assert len(env[name]) <= 575, (name, len(env[name]))
    boot_commands = [key for key, value in env.items() if re.search(r'\bbootm\b', value)]
    assert {'boot_production', 'boot_tftp_production'} <= set(boot_commands)
    for key in boot_commands:
        assert 'run r4pro_8x_select_media && bootm' in env[key], (medium, key)
    # Execute the generated bodies in a host shell with inert boot/read
    # commands. This checks command flow and arguments, not U-Boot hush.
    runner = r'''
set -e
setenv() { [ "$#" -le 2 ] || exit 91; printf -v "$1" '%s' "${2-}"; }
run() {
    case "$1" in
        r4pro_8x_select_media|r4pro_8x_select_wan|r4pro_8x_select_lan) eval "${!1}" ;;
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
printf 'SELECTORS=[%s][%s]\n' "${r4pro_8x_wan_media-}" "${r4pro_8x_lan_media-}"
'''
    raws = [None, '', 'copper', 'sfp', 'invalid', 'SFP']
    for wan in raws:
        for lan in raws:
            chosen = {'wan': 'sfp' if wan == 'sfp' else 'copper',
                      'lan': 'sfp' if lan == 'sfp' else 'copper'}
            for key in ['preboot'] + boot_commands:
                command = env[key].replace('then else', 'then :; else')
                values = dict(os.environ, **env, PATH='/nonexistent', BPIR_TEST_COMMAND=command)
                values['bootconf'] = 'stale-config#stale-overlay'
                for name, raw in [('wan', wan), ('lan', lan)]:
                    values.pop(f'r4pro_8x_{name}_media', None)
                    if raw is not None:
                        values[f'r4pro_8x_{name}_media'] = raw
                r = subprocess.run(['/bin/bash', '-c', runner], env=values, text=True, capture_output=True)
                assert r.returncode == 0, (medium, key, wan, lan, r.stderr)
                out = r.stdout
                assert (f'SKU=bpi-r4-pro-8x wan=[{wan or ""}] selected={chosen["wan"]} '
                        f'lan=[{lan or ""}] selected={chosen["lan"]} ') in out, out
                for name, raw in [('wan', wan), ('lan', lan)]:
                    warned = f'WARNING: invalid r4pro_8x_{name}_media' in out
                    assert warned == (raw not in [None, '', 'copper', 'sfp']), (name, raw, out)
                assert f'SELECTORS=[{wan or ""}][{lan or ""}]' in out
                args = [l.removeprefix('BOOTM=') for l in out.splitlines() if l.startswith('BOOTM=')]
                if key == 'preboot':
                    assert not args
                    continue
                assert len(args) == 1
                parts = args[0].split('#')[1:]
                configs = [c for c in parts if c]
                assert configs[0] == f'config-{base}'
                assert not any('stale' in c for c in configs)
                media = [c for c in configs if c.endswith('-sfp')]
                expect = [f'{base}-{n}-sfp' for n in ['wan', 'lan'] if chosen[n] == 'sfp']
                assert media == expect, (media, expect)
                # Only a trailing empty extra slot may be empty; never "##".
                assert '' not in parts[:-1], args[0]
                if key != 'boot_tftp':
                    storage = 'sd' if medium == 'sdmmc' else 'emmc'
                    assert f'{base}-{storage}' in configs, (medium, key, configs)
print('PASS: generated environments, preboot defconfigs and 36 selector pairs on three media')
PY

# ── Kernel DTS ──
KTREE=${BPIR_KERNEL_TREE:-$(ls -d "$BUILD_DIR"/openwrt/build_dir/target-aarch64_cortex-a53_musl/linux-mediatek_filogic/linux-6.* 2>/dev/null | head -1)}
[ -n "$KTREE" ] && [ -x "$KTREE/scripts/dtc/dtc" ] && [ -x "$KTREE/scripts/dtc/fdtoverlay" ] \
    && [ -f "$KTREE/arch/arm64/boot/dts/mediatek/mt7988a.dtsi" ] \
    || fail "no prepared mediatek/filogic kernel tree with dtc and fdtoverlay (set BPIR_KERNEL_TREE)"

python3 - "$KTREE" "$PATCHES/kernel" "$TMP/dts" <<'PY'
import pathlib, re, shutil, subprocess, sys
ktree, src, work = map(pathlib.Path, sys.argv[1:4])
rel = 'arch/arm64/boot/dts/mediatek'
base = 'mt7988a-bananapi-bpi-r4-pro-8x'
dtc, fdtoverlay = ktree / 'scripts/dtc/dtc', ktree / 'scripts/dtc/fdtoverlay'

def board_sections(text):
    keep = []
    for chunk in re.split(r'(?m)^(?=--- )', text):
        if chunk.startswith('--- ') and re.search(rf'{rel}/{base}[\w-]*\.dtso?\b', chunk.split('\n', 2)[1]):
            keep.append(re.sub(r'(?m)^diff .*\n', '', chunk))
    return ''.join(keep)

def rebuild(dest, upto):
    (dest / rel).mkdir(parents=True)
    for patch in sorted(src.glob('9*.patch')):
        if patch.name.startswith(('930-', '931-')) or patch.name > upto:
            continue
        body = board_sections(patch.read_text())
        if body:
            strict = ['--fuzz=0'] if patch.name.startswith('999d-') else []
            subprocess.run(['patch', '-s', '-f', *strict, '-p1', '-d', str(dest)], input=body, text=True, check=True)
    for dtsi in (ktree / rel).glob('*.dtsi'):
        shutil.copy(dtsi, dest / rel)

def preprocess(tree, name):
    return subprocess.run(['cpp', '-nostdinc', '-I', str(tree / rel), '-I', str(ktree / 'scripts/dtc/include-prefixes'),
                          '-I', str(ktree / 'include'), '-undef', '-D__DTS__', '-x', 'assembler-with-cpp',
                          str(tree / rel / name)], capture_output=True, text=True, check=True).stdout

def compile_dts(tree, name, out):
    r = subprocess.run([str(dtc), '-@', '-q', '-I', 'dts', '-O', 'dtb', '-o', str(out), '-'],
                       input=preprocess(tree, name), text=True, capture_output=True)
    assert r.returncode == 0, r.stderr

def merged_source(tree, name):
    """The whole merged tree as dtc source: references stay &label, numbers stay numbers."""
    return subprocess.run([str(dtc), '-q', '-I', 'dts', '-O', 'dts', '-'], input=preprocess(tree, name),
                          text=True, capture_output=True, check=True).stdout

def decompile(dtb):
    return subprocess.run([str(dtc), '-q', '-I', 'dtb', '-O', 'dts', str(dtb)], capture_output=True, text=True,
                          check=True).stdout

def parse(text):
    """Map node path -> {property: raw value, None for a boolean}."""
    out, stack = {}, []
    for raw in text.splitlines():
        s = raw.strip()
        m = re.match(r'^(?:[\w-]+: )*([\w,@.+-]+|/) \{$', s)
        if m:
            stack.append(m.group(1)); out.setdefault('/'.join(stack[1:]), {}); continue
        if s == '};':
            stack.pop(); continue
        m = re.match(r'^([\w,.+#?-]+)(?: = (.*))?;$', s)
        if m and stack:
            out['/'.join(stack[1:])][m.group(1)] = m.group(2)
    return out

def cells(value):
    if not value or not value.startswith('<'):
        return None
    return [int(x, 0) for group in re.findall(r'<([^>]*)>', value) for x in group.split()]

def phandles(tree):
    return {cells(props['phandle'])[0]: path for path, props in tree.items() if 'phandle' in props}

before, after = work / 'before', work / 'after'
rebuild(before, '999b-zzz'); rebuild(after, '999z-zzz')
compile_dts(after, base + '.dts', work / 'base.dtb')
for v in ['wan', 'lan']:
    r = subprocess.run([str(dtc), '-@', '-q', '-I', 'dts', '-O', 'dtb', '-o', str(work / f'{v}.dtbo'),
                        str(after / rel / f'{base}-{v}-sfp.dtso')], capture_output=True, text=True)
    assert r.returncode == 0, r.stderr
for name, overlays in [('wan', ['wan']), ('lan', ['lan']), ('both', ['wan', 'lan'])]:
    subprocess.run([str(fdtoverlay), '-i', str(work / 'base.dtb'), '-o', str(work / f'{name}.dtb')]
                   + [str(work / f'{v}.dtbo') for v in overlays], check=True)

eth = 'soc/ethernet@15100000'
port = f'{eth}/mdio-bus/switch@16/ports'
pio = 'soc/pinctrl@1001f000'
P = {'gmac1': f'{eth}/mac@1', 'gmac1_sfp': f'{eth}/mac-sfp@1',
     'port13': f'{port}/port@13', 'port13_sfp': f'{port}/port@d',
     'sfp_wan': 'sfp-wan', 'sfp_lan': 'sfp-lan',
     'wan_cu': f'{pio}/wan_combo_copper_hog', 'wan_sfp': f'{pio}/wan_combo_sfp_hog',
     'lan_cu': f'{pio}/lan_combo_copper_hog', 'lan_sfp': f'{pio}/lan_combo_sfp_hog'}

# The base keeps the copper board. Both trees are compared as merged dtc
# source, where a reference is written as &label and every other cell as its
# number, so no phandle numbering is involved: every old node and property must
# survive byte for byte (only the generated phandle values are ignored), and
# additions are limited to the nodes and properties this change introduces.
old_t = parse(merged_source(before, base + '.dts'))
new_t = parse(merged_source(after, base + '.dts'))
mux = next(path for path in new_t if path.endswith('/i2c-mux@70'))
added_nodes = {P['gmac1_sfp'], P['port13_sfp'], P['sfp_wan'], P['sfp_lan'], P['wan_sfp'], P['lan_sfp'],
               f'{mux}/i2c@1', f'{mux}/i2c@2'}
for addr in ['18', '1c']:
    leds = f'{eth}/mdio-bus/ethernet-phy@{addr}/leds'
    added_nodes.update([leds, f'{leds}/led@0', f'{leds}/led@1'])
added_props = {('chosen', 'bpirouter,wan-media'), ('chosen', 'bpirouter,lan-media')}
for path, props in old_t.items():
    assert path in new_t, ('removed node', path)
    for prop, value in props.items():
        if prop == 'phandle':
            continue
        assert prop in new_t[path], ('removed property', path, prop)
        assert value == new_t[path][prop], ('changed property', path, prop, value, new_t[path][prop])
    extra = set(new_t[path]) - set(props) - {'phandle'}
    allowed = {p for n, p in added_props if n == path}
    assert extra <= allowed, ('unexpected property', path, extra - allowed)
for path in new_t:
    if path not in old_t:
        assert path in added_nodes, ('unexpected node', path)

def check(name):
    t = parse(decompile(work / f'{name}.dtb'))
    ph = phandles(t)
    def ref(path, prop):
        return [ph[c] for c in cells(t[path][prop])]
    def status(key):
        return (t[P[key]].get('status') or '"okay"').strip('"')
    pio_path = t['__symbols__']['pio'].strip('"').lstrip('/')
    assert pio_path == pio
    pio_ph = cells(t[pio]['phandle'])[0]
    sfp = {'wan': name in ('wan', 'both'), 'lan': name in ('lan', 'both')}
    want = {'gmac1': not sfp['wan'], 'gmac1_sfp': sfp['wan'], 'sfp_wan': sfp['wan'],
            'wan_cu': not sfp['wan'], 'wan_sfp': sfp['wan'],
            'port13': not sfp['lan'], 'port13_sfp': sfp['lan'], 'sfp_lan': sfp['lan'],
            'lan_cu': not sfp['lan'], 'lan_sfp': sfp['lan']}
    for key, enabled in want.items():
        assert status(key) == ('okay' if enabled else 'disabled'), (name, key, status(key))
    for combo in ['wan', 'lan']:
        assert t['chosen'][f'bpirouter,{combo}-media'] == ('"sfp"' if sfp[combo] else '"copper"'), (name, combo)
    # Cage wiring from CM17: I2C channel and GPIO number/flags (1 = active low).
    for cage, channel, pins in [('sfp_wan', 2, (1, 2, 0)), ('sfp_lan', 1, (69, 70, 21))]:
        node = t[P[cage]]
        assert node['compatible'] == '"sff,sfp"'
        assert ref(P[cage], 'i2c-bus') == [f'{mux}/i2c@{channel}'], (name, cage)
        assert cells(t[f'{mux}/i2c@{channel}']['reg']) == [channel]
        assert cells(node['mod-def0-gpios']) == [pio_ph, pins[0], 1], (name, cage)
        assert cells(node['los-gpios']) == [pio_ph, pins[1], 0], (name, cage)
        assert cells(node['tx-disable-gpios']) == [pio_ph, pins[2], 0], (name, cage)
        assert cells(node['maximum-power-milliwatt']) == [3000]
    # Attachments: the SFP forms reference their own cage and keep the MAC id,
    # PCS and SerDes PHY, or the port number and label, of the copper form.
    mac, mac_sfp = t[P['gmac1']], t[P['gmac1_sfp']]
    assert ref(P['gmac1'], 'phy-handle') == [f'{eth}/mdio-bus/ethernet-phy@1c']
    assert ref(P['gmac1_sfp'], 'sfp') == [P['sfp_wan']], name
    assert cells(mac_sfp['reg']) == cells(mac['reg']) == [1]
    assert mac_sfp['compatible'] == mac['compatible'] == '"mediatek,eth-mac"'
    for prop in ['pcs-handle', 'phys']:
        assert ref(P['gmac1_sfp'], prop) == ref(P['gmac1'], prop), (name, prop)
    assert mac_sfp['phy-mode'] == '"10gbase-r"' and mac_sfp['managed'] == '"in-band-status"'
    assert 'phy-handle' not in mac_sfp
    assert ref(P['port13'], 'phy-handle') == [f'{eth}/mdio-bus/ethernet-phy@18']
    assert ref(P['port13_sfp'], 'sfp') == [P['sfp_lan']], name
    for key in ['port13', 'port13_sfp']:
        assert cells(t[P[key]]['reg']) == [13] and t[P[key]]['label'] == '"mxl_lan4"', (name, key)
    assert t[P['port13_sfp']]['phy-mode'] == '"10gbase-r"' and 'phy-handle' not in t[P['port13_sfp']]
    # Mux hogs on the SoC controller: GPIO3 high = WAN SFP, GPIO54 low = LAN SFP.
    for key, pin, level in [('wan_cu', 3, 'low'), ('wan_sfp', 3, 'high'), ('lan_cu', 54, 'high'), ('lan_sfp', 54, 'low')]:
        node = t[P[key]]
        assert P[key].rsplit('/', 1)[0] == pio and 'gpio-hog' in node, (name, key)
        assert cells(node['gpios']) == [pin, 0], (name, key, node['gpios'])
        other = 'high' if level == 'low' else 'low'
        assert f'output-{level}' in node and f'output-{other}' not in node, (name, key)
    # The AS21010P nodes stay probed on either medium.
    for phy in ['ethernet-phy@1c', 'ethernet-phy@18']:
        assert t[f'{eth}/mdio-bus/{phy}'].get('status', '"okay"') == '"okay"', (name, phy)
    # CM15/CM16/CM17: LED0 = green, LED1 = yellow, both active-high
    # through NMOS sinks. SFP traffic must not light the copper jack.
    for combo, addr in [('lan', '18'), ('wan', '1c')]:
        leds = f'{eth}/mdio-bus/ethernet-phy@{addr}/leds'
        assert cells(t[leds]['#address-cells']) == [1]
        assert cells(t[leds]['#size-cells']) == [0]
        for index, color in [(0, 2), (1, 6)]:
            node = t[f'{leds}/led@{index}']
            assert cells(node['reg']) == [index]
            assert cells(node['color']) == [color]
            assert node['function'] == f'"{combo}"'
            assert 'active-high' in node and 'active-low' not in node
            assert node['linux,default-trigger'] == '"netdev"'
            assert node.get('status', '"okay"') == ('"disabled"' if sfp[combo] else '"okay"'), (name, combo, index)

for name in ['base', 'wan', 'lan', 'both']:
    check(name)
patch_text = (src / '999c-bpi-r4-pro-8x-combo-sfp.patch').read_text()
for v in ['lan', 'wan']:
    assert f'+dtb-$(CONFIG_ARCH_MEDIATEK) += {base}-{v}-sfp.dtbo' in patch_text, v
print('PASS: 8X base DTB keeps copper with additions only; cage wiring, references and mux hogs resolve in all four media combinations')
print('PASS: combo LED wiring and copper-only availability in all four media combinations')
PY

# Apply and execute the real board LED defaults, checking arguments rather
# than source strings. No board or UCI writes are performed by this fixture.
python3 - "$BUILD_DIR" "$TMP" <<'PY'
import pathlib, subprocess, sys
build, tmp = map(pathlib.Path, sys.argv[1:])
rel = pathlib.Path('target/linux/mediatek/filogic/base-files/etc/board.d/01_leds')
target = tmp / rel
target.parent.mkdir(parents=True, exist_ok=True)
base = subprocess.run(['git', '-C', str(build / 'openwrt'), 'show', f'HEAD:{rel}'],
                      capture_output=True, text=True, check=True).stdout
target.write_text(base)
patch = build / 'patches/bpi-r4-pro/base-files/471-filogic-r4-pro-8x-combo-leds.patch'
subprocess.run(['patch', '-s', '-f', '--fuzz=0', '-p1', '-d', str(tmp)],
               input=patch.read_text(), text=True, check=True)
script = '\n'.join(line for line in target.read_text().splitlines() if not line.startswith('. /lib/'))
stubs = '''
board_name() { printf '%s' "$TEST_BOARD"; }
board_config_update() { :; }
board_config_flush() { :; }
ucidef_set_led_netdev() { printf '%s|%s|%s|%s|%s\\n' "$1" "$2" "$3" "$4" "$5"; }
'''
expected = [
    'eth6_link|ETH6 Link|mdio-bus:18:green:lan|mxl_lan4|link',
    'eth6_activity|ETH6 Activity|mdio-bus:18:yellow:lan|mxl_lan4|tx rx',
    'eth7_link|ETH7 Link|mdio-bus:1c:green:wan|eth1|link',
    'eth7_activity|ETH7 Activity|mdio-bus:1c:yellow:wan|eth1|tx rx',
]
for board in ['bananapi,bpi-r4-pro-8x', 'bananapi,bpi-r4-pro-4e', 'unknown']:
    result = subprocess.run(['/bin/sh', '-eu', '-c', stubs + script],
                            env={'TEST_BOARD': board}, capture_output=True, text=True, check=True)
    assert result.stdout.splitlines() == (expected if board.endswith('-8x') else []), (board, result.stdout)
print('PASS: applied board LED defaults select the four 8X PHY LEDs and leave other boards alone')

# Apply the software-activity patch to pristine sources, then execute both
# load_led against isolated sysfs files. OTA migration is exercised separately.
rel = pathlib.Path('package/base-files/files/etc/init.d/led')
service = tmp / rel
service.parent.mkdir(parents=True, exist_ok=True)
service.write_text(subprocess.run(
    ['git', '-C', str(build / 'openwrt'), 'show', f'HEAD:{rel}'],
    capture_output=True, text=True, check=True).stdout)
patch = build / 'patches/bpi-r4-pro/base-files/472-filogic-r4-pro-8x-led-software-activity.patch'
subprocess.run(['patch', '-s', '-f', '--fuzz=0', '-p1', '-d', str(tmp)],
               input=patch.read_text(), text=True, check=True)

ledroot = tmp / 'leds'
led = ledroot / 'test'
led.mkdir(parents=True)
script = service.read_text().replace('/sys/class/leds', str(ledroot))
script = script.replace('/var/run/led.state', str(tmp / 'led.state'))
stubs = '''
extra_command() { :; }
config_get() {
    case "$3" in
        sysfs) value=test;; name) value=Test;; trigger) value=netdev;;
        dev) value=eth1;; mode) value="$TEST_MODE";;
        interval) value="$TEST_INTERVAL";; *) value="${4-}";;
    esac
    export "$1=$value"
}
config_get_bool() { config_get "$@"; }
'''
for mode, interval in [('tx rx', '100'), ('link', '50')]:
    rules = ['link', 'link_10', 'link_100', 'link_1000', 'link_2500',
             'link_5000', 'link_10000', 'half_duplex', 'full_duplex', 'tx', 'rx']
    for attr in ['brightness', 'trigger', 'device_name', 'interval'] + rules:
        (led / attr).write_text('1\n')
    result = subprocess.run(['/bin/sh', '-x', '-c', stubs + script + '\nload_led test\n'],
                            env={'TEST_MODE': mode, 'TEST_INTERVAL': interval},
                            capture_output=True, text=True, check=True)
    # Each mode writes 1: the real shell trace must show interval first.
    trace = result.stderr.splitlines()
    assert trace.index('+ echo ' + interval) < trace.index('+ echo 1'), result.stderr
    if interval != '50':
        before_interval = trace[:trace.index('+ echo ' + interval)]
        assert before_interval.count('+ echo 0') == len(rules) + 1, result.stderr
        for attr in set(rules) - set(mode.split()):
            assert (led / attr).read_text().strip() == '0', attr
    assert (led / 'interval').read_text().strip() == interval
    for attr in mode.split():
        assert (led / attr).read_text().strip() == '1'
print('PASS: real LED loader sets interval before modes')
PY

python3 "$SCRIPT_DIR/test-combo-led-migration.py"

grep -q 'DEVICE_DTS_OVERLAY := .*mt7988a-bananapi-bpi-r4-pro-8x-wan-sfp mt7988a-bananapi-bpi-r4-pro-8x-lan-sfp' \
    "$PATCHES/base-files/451-filogic-add-bpi-r4-pro-8x.patch" \
    || fail "the 8X FIT does not carry both media overlays"
echo 'PASS: 8X combo media selection inputs'
