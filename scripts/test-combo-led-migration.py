#!/usr/bin/env python3
"""Run the patched LED service after old OTA configuration is restored."""
import copy
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

BUILD = Path(__file__).resolve().parent.parent


class ComboMigrationTest(unittest.TestCase):
    def test_restored_configuration(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            rel = 'package/base-files/files/etc/init.d/led'
            service = root / rel
            service.parent.mkdir(parents=True)
            service.write_bytes(subprocess.check_output(
                ['git', '-C', str(BUILD / 'openwrt'), 'show', 'HEAD:' + rel]))
            subprocess.run(['patch', '-s', '-f', '--fuzz=0', '-p1', '-d', str(root)],
                           input=(BUILD / 'patches/bpi-r4-pro/base-files/472-filogic-r4-pro-8x-led-software-activity.patch').read_bytes(), check=True)
            helper = root / 'target/linux/mediatek/filogic/base-files/lib/functions/bpirouter-combo-leds.sh'
            self.assertTrue(helper.exists())
            self.assertFalse((root / 'target/linux/mediatek/filogic/base-files/etc/uci-defaults/99-bpirouter-combo-led-activity').exists())
            # Persistent UCI state, including missing-section errors. Unlike
            # the former print-only stub, reads observe preceding mutations.
            uci = root / 'uci'
            uci.write_text(f'#!{sys.executable}\n' + '''
import json, os, pathlib, sys
p=pathlib.Path(os.environ['STATE']); state=json.loads(p.read_text())
a=[x for x in sys.argv[1:] if x != '-q']; cmd=a[0]; key=a[1]
if cmd == 'get':
    if key not in state: sys.exit(1)
    print(state[key])
elif cmd == 'show':
    for k,v in state.items():
        if k==key or k.startswith(key+'.'):
            print(k+'='+(v if k.count('.') == 1 else repr(v)))
elif cmd == 'set':
    k,v=key.split('=',1)
    if k.count('.')==2 and k.rsplit('.',1)[0] not in state: sys.exit(1)
    state[k]=v; p.write_text(json.dumps(state))
elif cmd == 'changes':
    print(os.environ.get('PENDING', ''), end='')
elif cmd == 'commit':
    with open(os.environ['COMMITS'],'a') as f: f.write(key+'\\n')
else: sys.exit(2)
''')
            uci.chmod(0o755)
            leds = root / 'leds'
            leds.mkdir()
            text = service.read_text().replace('/lib/functions/bpirouter-combo-leds.sh', str(helper))
            text = text.replace('/sys/class/leds', str(leds)).replace('/var/run/led.state', str(root / 'led.state'))
            script = root / 'service.sh'
            script.write_text('''
extra_command() { :; }
board_name() { printf '%s' "$BOARD"; }
config_load() { cp "$STATE" "$OBSERVED"; }
config_foreach() { :; }
''' + text + '\nboot\n')
            state = root / 'state.json'
            observed = root / 'observed.json'
            commits = root / 'commits'
            env = dict(os.environ, PATH=str(root) + ':' + os.environ['PATH'],
                       STATE=str(state), OBSERVED=str(observed), COMMITS=str(commits),
                       BOARD='bananapi,bpi-r4-pro-8x')
            baseline = {'system.main': 'system', 'system.main.hostname': 'kept-router'}

            def run(values, board='bananapi,bpi-r4-pro-8x', pending=''):
                # This write represents tar restoring the OLD system file
                # after S10boot; S96led must fix it before config_load.
                state.write_text(json.dumps(values))
                subprocess.run(['sh', str(script)], env=dict(env, BOARD=board, PENDING=pending), check=True)
                result = json.loads(state.read_text())
                self.assertEqual(json.loads(observed.read_text()), result)
                return result

            fresh = run(baseline)
            for port, dev, addr in [('eth6', 'mxl_lan4', '18'), ('eth7', 'eth1', '1c')]:
                for kind, mode, interval in [('link', 'link', '50'), ('activity', 'tx rx', '100')]:
                    s = f'system.led_{port}_{kind}'
                    self.assertEqual(fresh[s], 'led')
                    self.assertEqual(fresh[s + '.dev'], dev)
                    self.assertEqual(fresh[s + '.mode'], mode)
                    self.assertEqual(fresh[s + '.interval'], interval)
                    self.assertIn('mdio-bus:' + addr + ':', fresh[s + '.sysfs'])
            self.assertEqual(fresh['system.main.hostname'], 'kept-router')
            count = commits.read_text()
            self.assertEqual(run(fresh), fresh)
            self.assertEqual(commits.read_text(), count, 'idempotent boots must not commit')
            for interval in ('50', None):
                old = copy.deepcopy(fresh)
                for port in ('eth6', 'eth7'):
                    key = f'system.led_{port}_activity.interval'
                    if interval is None:
                        del old[key]
                    else:
                        old[key] = interval
                self.assertEqual(run(old), fresh)
            for field, value in [('interval', '250'), ('mode', 'link'), ('dev', 'custom0'),
                                 ('name', 'Custom'), ('sysfs', 'custom:led'),
                                 ('trigger', 'none'), ('default', '1'), ('custom', 'yes')]:
                custom = copy.deepcopy(fresh)
                custom['system.led_eth6_activity.interval'] = '50'
                custom['system.led_eth6_activity.' + field] = value
                count = commits.read_text()
                self.assertEqual(run(custom), custom, field)
                self.assertEqual(commits.read_text(), count)
            for board in ('bananapi,bpi-r4-pro-4e', 'unknown'):
                self.assertEqual(run(baseline, board), baseline)
            for owner in ('system.custom_led', 'system.@led[0]'):
                for port in ('eth6', 'eth7'):
                    for kind in ('link', 'activity'):
                        section = f'system.led_{port}_{kind}'
                        custom = {owner + k[len(section):] if k == section or k.startswith(section + '.') else k: v
                                  for k, v in fresh.items()}
                        custom[owner + '.interval'] = '250'
                        count = commits.read_text()
                        with self.subTest(owner=owner, port=port, kind=kind):
                            result = run(custom)
                            self.assertEqual(result, custom)
                            self.assertNotIn(section, result)
                            self.assertEqual(commits.read_text(), count)
            count = commits.read_text()
            self.assertEqual(run(baseline, pending='system.main.hostname=draft'), baseline)
            self.assertEqual(commits.read_text(), count)
            # Startup ordering is the integration contract, not a timer.
            import re
            restore = (BUILD.parent / 'bpirouter-ui/deploy/init.d/bpirouter-ota-restore').read_text()
            self.assertLess(int(re.search(r'^START=(\d+)', restore, re.M)[1]),
                            int(re.search(r'^START=(\d+)', text, re.M)[1]))


if __name__ == '__main__':
    unittest.main()
