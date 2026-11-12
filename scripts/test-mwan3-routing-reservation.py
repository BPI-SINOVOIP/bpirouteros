#!/usr/bin/env python3
"""Exercise shipped cleanup functions against isolated kernel routing state."""

import fcntl
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import time

BUILD = Path(__file__).resolve().parents[1]
PATCH = BUILD / 'patches/common/packages/004-mwan3-product-routing-reservation.patch'
SOURCE = Path(os.environ.get('BPIR_OPENWRT_DIR', os.environ.get('BPIR_WORK_DIR', BUILD / 'openwrt'))) / 'feeds/packages'
FILES = ['net/mwan3/files/' + name for name in (
    'etc/init.d/mwan3', 'lib/mwan3/common.sh', 'lib/mwan3/mwan3.sh', 'usr/sbin/mwan3rtmon')]


def run(*args, **kwargs):
    return subprocess.check_output(args, text=True, **kwargs).strip()


def ip(*args):
    return run('ip', *args)


def source_text(root):
    return '\n'.join('\n'.join(line for line in (root / name).read_text().splitlines()
                              if not line.startswith('. '))
                     for name in (FILES[1], FILES[2], FILES[0]))


if len(sys.argv) == 3 and sys.argv[1] == '--inside':
    root = Path(sys.argv[2])
    assert os.readlink('/proc/self/ns/net') != os.environ['MWAN_PARENT_NETNS']
    assert [link['ifname'] for link in json.loads(ip('-j', 'link'))] == ['lo']
    ip('link', 'set', 'lo', 'up')
    ip('link', 'add', 'lan0', 'type', 'dummy')
    ip('link', 'set', 'lan0', 'up')
    source = source_text(root)
    stubs = '''
NO_IPV6=0
MWAN3_INTERFACE_MAX=60
MM_BLACKHOLE=61
MM_UNREACHABLE=62
mwan3_init() { :; }
config_foreach() { :; }
mwan3_interface_shutdown() { :; }
empty() { :; }
restore() { cat >/dev/null; }
IPT4=empty; IPT6=empty; IPT4R=restore; IPT6R=restore; IPS=empty
sleep() { :; }
rm() { :; }
'''

    def shell(code, extra=stubs):
        subprocess.run(['bash'], input=source + '\n' + extra + '\n' + code,
                       text=True, check=True)

    def populate():
        for family, destination in [('-4', '192.0.2.0/24'), ('-6', '2001:db8::/64')]:
            for table in (*range(1, 9), 9, 52, 77):
                ip(family, 'route', 'add', 'table', str(table), destination, 'dev', 'lan0')
            for number in (1, 8):
                ip(family, 'rule', 'add', 'pref', str(1000 + number), 'iif', 'lan0', 'lookup', str(number))
                ip(family, 'rule', 'add', 'pref', str(2000 + number), 'fwmark', hex(number << 8) + '/0x3f00', 'lookup', str(number))
                ip(family, 'rule', 'add', 'pref', str(3000 + number), 'fwmark', hex(number << 8) + '/0x3f00', 'unreachable')
            ip(family, 'rule', 'add', 'pref', '2001', 'fwmark', '0x200/0x3f00', 'lookup', '1')
            ip(family, 'rule', 'add', 'pref', '2061', 'fwmark', '0x3d00/0x3f00', 'blackhole')
            ip(family, 'rule', 'add', 'pref', '2062', 'fwmark', '0x3e00/0x3f00', 'unreachable')
            ip(family, 'rule', 'add', 'pref', '1370', 'not', 'fwmark', '0x80000/0xff0000', 'lookup', '52')
            ip(family, 'rule', 'add', 'pref', '1500', 'lookup', '77')

    populate()
    foreign = {(family, table): ip(family, 'route', 'show', 'table', str(table))
               for family in ('-4', '-6') for table in (9, 52, 77)}
    foreign_rules = {family: [r for r in json.loads(ip(family, '-j', 'rule'))
                              if r['priority'] in (1370, 1500)] for family in ('-4', '-6')}
    shell('stop_service\nstop_service')
    for family in ('-4', '-6'):
        for table in range(1, 9):
            assert not ip(family, 'route', 'show', 'table', str(table)), (family, table)
        for table in (9, 52, 77):
            assert ip(family, 'route', 'show', 'table', str(table)) == foreign[family, table]
        rules = json.loads(ip(family, '-j', 'rule'))
        assert [r for r in rules if 1000 < r['priority'] < 4000] == foreign_rules[family], rules
    for family in ('-4', '-6'):
        ip(family, 'rule', 'add', 'pref', '1001', 'iif', 'lan0', 'lookup', '1')
    shell('mwan3_delete_iface_rules test', stubs + '''
config_get() { export "$1=ipv6"; }
mwan3_get_iface_id() { export "$1=1"; }
''')
    assert any(r['priority'] == 1001 for r in json.loads(ip('-4', '-j', 'rule')))
    assert not any(r['priority'] == 1001 for r in json.loads(ip('-6', '-j', 'rule')))
    assert [r for r in json.loads(ip('-6', '-j', 'rule')) if 1000 < r['priority'] < 4000] == foreign_rules['-6']

    # Real init must reject before creating state or modifying anything.
    overlimit = '''
config_load() { :; }
config_foreach() { for n in 1 2 3 4 5 6 7 8 9; do "$1" "wan$n"; done; }
LOG() { :; }
mkdir() { echo unexpected-mutation; exit 99; }
mwan3_init
echo unexpected-success
'''
    result = subprocess.run(['bash'], input=source + '\n' + overlimit, text=True, capture_output=True)
    assert result.returncode == 1 and not result.stdout, result

    # Exercise the shipped rtmon update and route handlers with a stale enabled
    # cache, active tracker and surviving iface chains. Only config/procd inputs
    # are fixtures; flock and policy-table writes use the isolated kernel.
    monitor = '\n'.join(line for line in (root / FILES[3]).read_text().splitlines()
                        if not line.startswith('. ') and line != 'main "$@"')
    lock_path = root / 'procd_mwan3.lock'
    monitor = monitor.replace('/var/lock/procd_mwan3.lock', str(lock_path))
    state_dir = root / 'runtime'
    state_dir.mkdir()
    enabled_path = root / 'enabled'
    ready_path = root / 'ready'
    refreshed = root / 'refreshed'
    monitor_stubs = stubs + f'''
MWAN3_STATUS_DIR="{state_dir}"
cached=1
mwan3_init() {{ cached=$(cat "{enabled_path}"); }}
config_foreach() {{ "$1" wan; "$1" bpir_usb1; }}
config_get_bool() {{
    if [ "$2" = wan ]; then export "$1=0"; else export "$1=$cached"; fi
}}
config_get() {{
    case "$3" in family) export "$1=$FAMILY" ;; *) export "$1=online" ;; esac
}}
network_flush_cache() {{ :; }}
network_get_device() {{
    if [ "$2" = bpir_usb1 ]; then export "$1=lan0"; else export "$1=lo"; fi
}}
mwan3_get_mwan3track_status() {{ export "$1=active"; }}
mwan3_get_routes() {{ printf '%s\\n' "$ROUTE"; }}
mwan3_set_connected_ipv4() {{ echo refresh >>"{refreshed}"; }}
mwan3_set_connected_ipv6() {{ echo refresh >>"{refreshed}"; }}
MWAN3_ROUTE_LINE_EXP=p
LOG() {{ :; }}
'''

    def monitor_script(family, route, initial):
        args = '"$FAMILY"' if initial else '"$FAMILY" "$ROUTE"'
        return (source + '\n' + monitor + '\n' + monitor_stubs +
                f'\nFAMILY={family}\nROUTE="{route}"\n'
                f'echo ready >"{ready_path}"\nmwan3_rtmon_update {args}\n')

    for family, flag, subnet in [('ipv4', '-4', '192.0.2.0/24'), ('ipv6', '-6', '2001:db8::/64')]:
        for initial, route in [(True, 'default dev lan0'),
                               (True, subnet + ' dev lo'),
                               (False, 'default dev lan0'), (False, subnet + ' dev lo')]:
            script = monitor_script(family, route, initial)
            enabled_path.write_text('1\n')
            subprocess.run(['bash'], input=script, text=True, check=True)
            assert ip(flag, 'route', 'show', 'table', '2'), (family, initial, route)
            assert not ip(flag, 'route', 'show', 'table', '1'), 'disabled first member was used'
            ip(flag, 'route', 'flush', 'table', '2')
            ready_path.unlink()
            refreshed.unlink(missing_ok=True)
            # stop owns this same lock while an old event/initial copy queues.
            with lock_path.open('w') as lock:
                fcntl.flock(lock, fcntl.LOCK_EX)
                child = subprocess.Popen(['bash'], stdin=subprocess.PIPE, text=True)
                try:
                    child.stdin.write(script)
                    child.stdin.close()
                    deadline = time.monotonic() + 3
                    while not ready_path.exists() and time.monotonic() < deadline:
                        time.sleep(0.01)
                    assert ready_path.exists(), 'monitor did not enter the fixture'
                    time.sleep(0.15)
                    assert child.poll() is None, 'monitor did not wait for the service lock'
                    assert not ip(flag, 'route', 'show', 'table', '2'), 'write crossed stop lock'
                    assert not refreshed.exists(), 'ipset update crossed stop lock'
                    enabled_path.write_text('0\n')
                    fcntl.flock(lock, fcntl.LOCK_UN)
                    assert child.wait(timeout=3) == 0
                finally:
                    if child.poll() is None:
                        fcntl.flock(lock, fcntl.LOCK_UN)
                        child.wait(timeout=3)
            assert not ip(flag, 'route', 'show', 'table', '2'), 'queued monitor used stale enabled config'
            assert not ip(flag, 'route', 'show', 'table', '1')
    state_dir.rmdir()
    refreshed.unlink(missing_ok=True)
    enabled_path.write_text('1\n')
    for initial in (False, True):
        result = subprocess.run(['bash'], input=monitor_script('ipv4', 'default dev lan0', initial), text=True)
        assert result.returncode != 0 and not state_dir.exists()
        assert not refreshed.exists() and not ip('-4', 'route', 'show', 'table', '2')
    print('PASS: reserved cleanup, foreign preservation, off cleanup, IPv6 scope, over-limit refusal, serialized rtmon refresh')
    raise SystemExit(0)

with tempfile.TemporaryDirectory(prefix='bpir-mwan-reservation-') as temp:
    root = Path(temp)
    for name in FILES:
        dest = root / name
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(SOURCE / name, dest)
    reverse = subprocess.run(['git', '-C', str(root), 'apply', '--reverse', '--check', str(PATCH)], capture_output=True)
    if reverse.returncode:
        if sys.argv[1:] == ['--prepared']:
            raise SystemExit('prepared mwan3 tree is missing the product routing patch')
        subprocess.run(['git', '-C', str(root), 'apply', str(PATCH)], check=True)
    common = (root / FILES[1]).read_text()
    limit = int(re.search(r'^MWAN3_PRODUCT_MAX=(\d+)$', common, re.M)[1])
    ui = Path(os.environ.get('BPIR_UI_DIR', BUILD.parent / 'bpirouter-ui'))
    if (ui / 'backend').is_dir():
        backend = (ui / 'backend/internal/handler/mwan3.go').read_text()
        assert limit == int(re.search(r'\bmwanMaxMembers\s*=\s*(\d+)', backend)[1])
    else:
        print('SKIP: backend source unavailable; artifact build cannot cross-check the member limit')
    if sys.argv[1:] in (['--source-check'], ['--prepared']):
        scope = 'prepared tree' if sys.argv[1:] == ['--prepared'] else 'patch fixture'
        print(f'PASS: {scope} and product member-limit contract')
        raise SystemExit(0)
    if sys.argv[1:]:
        raise SystemExit('usage: test-mwan3-routing-reservation.py [--source-check|--prepared]')
    subprocess.run(['unshare', '-Urn', sys.executable, __file__, '--inside', str(root)], check=True,
                   env={**os.environ, 'MWAN_PARENT_NETNS': os.readlink('/proc/self/ns/net')})
