#!/usr/bin/env python3
"""Check the ddns-scripts patches: HTTPS update URLs for the product's providers, a single
No-IP request with the real address, the Cloudflare zone lookup for plain record names and one
success line per update. The patched Cloudflare script runs against a stub cURL that answers like
the Cloudflare v4 API, the No-IP script against a stub transfer; nothing leaves the host.

usage: test-ddns-scripts-patches.py PACKAGES_FEED [--prepared]
Without --prepared the patches are applied to a copy of the supplied feed, and the
unpatched scripts are first shown to have the defects (Cloudflare subdomain, No-IP dummy
localhost update, both success lines logged).
"""

from pathlib import Path
import argparse
import json
import os
import re
import shutil
import subprocess
import tempfile

BUILD = Path(__file__).resolve().parents[1]
PATCHES = [BUILD / 'patches/common/packages' / name for name in (
    '012-ddns-scripts-https-providers.patch', '013-ddns-scripts-cloudflare-zone-lookup.patch',
    '014-ddns-scripts-success-log.patch')]
FILES = ['Makefile', 'files/usr/lib/ddns/update_cloudflare_com_v4.sh', 'files/usr/lib/ddns/update_no-ip_com.sh',
         'files/usr/lib/ddns/dynamic_dns_updater.sh',
         'files/usr/share/ddns/default/duckdns.org.json', 'files/usr/share/ddns/default/dynu.com.json',
         'files/usr/share/ddns/default/no-ip.com.json', 'files/usr/share/ddns/default/cloudflare.com-v4.json',
         'files/usr/share/ddns/default/afraid.org-v2-token.json']

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('packages_feed', type=Path)
parser.add_argument('--prepared', action='store_true', help='require the patches in the supplied source')
args = parser.parse_args()
source = args.packages_feed.resolve()

STUB_CURL = r'''#!/usr/bin/env python3
import json, os, sys, urllib.parse
a = sys.argv[1:]; out = method = None; url = ''
i = 0
while i < len(a):
    if a[i] == '-o': out = a[i + 1]; i += 2; continue
    if a[i] in ('--stderr', '--header', '--data', '--interface'): i += 2; continue
    if a[i] == '--request': method = a[i + 1]; i += 2; continue
    if a[i].startswith('https://'): url = a[i]
    i += 1
base = 'https://api.cloudflare.com/client/v4'
assert url.startswith(base), url
path = url[len(base):]
with open(os.environ['CALLS'], 'a') as f:
    f.write(f'{method} {path}\n')
zones = [z for z in os.environ['ZONES'].split(',') if z]
u = urllib.parse.urlsplit(path); q = dict(urllib.parse.parse_qsl(u.query))
if u.path == '/zones':
    res = [{'id': 'zid-' + q['name'], 'name': q['name']}] if q.get('name') in zones else []
elif u.path.endswith('/dns_records') and method == 'GET':
    res = [{'id': 'rid', 'name': q['name'], 'content': '192.0.2.1'}] if q.get('name') == os.environ['RECORD'] else []
else:
    res = {'id': 'rid', 'content': '203.0.113.5'}
open(out, 'w').write(json.dumps({'result': res, 'success': True}))
'''

STUB_JSONFILTER = r'''#!/usr/bin/env python3
import json, re, sys
a = sys.argv[1:]
data = json.load(open(a[a.index('-i') + 1])); expr = a[a.index('-e') + 1]
result = data.get('result')
items = result if isinstance(result, list) else []
if expr == '@.result.*.id':
    print('\n'.join(x['id'] for x in items))
elif (m := re.fullmatch(r"@\.result\[@\.id='([^']*)'\]\.id", expr)):
    print('\n'.join(x['id'] for x in items if x['id'] == m.group(1)))
else:
    sys.exit('unsupported jsonfilter expression: ' + expr)
'''

HARNESS = r'''
write_log() { lvl=$1; shift; echo "LOG$lvl $*" >> "$LOGF"; [ "$lvl" -ge 13 ] && exit 1; return 0; }
expand_ipv6() { :; }
IPV4_REGEX="[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}"
CURL=$STUBDIR/curl; CURL_SSL=1; CURL_PROXY=1
use_https=1; use_ipv6=0; force_ipversion=0; cacert=""; proxy=""; bind_network=""
VERBOSE_MODE=0; retry_max_count=0; RETRY_SECONDS=0; GET_REGISTERED_IP=""
username=Bearer; password=test-token-not-secret; __IP=203.0.113.5
send_update() { . "$SCRIPT"; }
send_update
echo "rc=$?"
'''

NOIP_HARNESS = r'''
write_log() { lvl=$1; shift; [ "$lvl" -ge 13 ] && exit 1; return 0; }
do_transfer() { echo "$1" >> "$CALLS"; echo "good 203.0.113.5" > "$DATFILE"; return 0; }
use_https=1; use_ipv6=0; URL_USER=user; URL_PASS=pass; username=user; password=pass
domain=host.example.net; __IP=203.0.113.5; N="
"
send_update() { . "$SCRIPT"; }
send_update
echo "rc=$?"
'''

# The updater's success branch, run on its own. write_log returns 1 for a level-6 message
# because, with the default use_syslog, it is not sent to syslog.
SUCCESS_HARNESS = r'''
write_log() { echo "LOG$1 $2" >> "$LOGF"; [ "$1" -eq 6 ] && return 1; return 0; }
get_uptime() { eval "$1=100"; }
ERR_LAST=0; UPDFILE=$UPDFILE; CURRENT_IP=203.0.113.5
'''


def run_noip(script, work):
    calls, dat = work / 'noip-calls', work / 'noip-dat'
    calls.write_text('')
    env = dict(os.environ, SCRIPT=str(script), CALLS=str(calls), DATFILE=str(dat))
    p = subprocess.run(['sh', '-c', NOIP_HARNESS], env=env, capture_output=True, text=True, timeout=30)
    rc = re.search(r'rc=(\d+)', p.stdout)
    return (int(rc.group(1)) if rc else None), calls.read_text().split('\n')[:-1]


def run_success_branch(updater, work, registered):
    text = updater.read_text()
    start = text.index('\t\tif [ $ERR_LAST -eq 0 ]; then\n')
    end = text.index('\n\t\tfi\n', start) + len('\n\t\tfi\n')
    logf = work / 'success-log'
    logf.write_text('')
    env = dict(os.environ, LOGF=str(logf), UPDFILE=str(work / 'upd'))
    script = SUCCESS_HARNESS + f'REGISTERED_IP={registered}\n' + text[start:end] + ':\n'  # the branch ends in write_log's 1
    subprocess.run(['sh', '-c', script], env=env, check=True, capture_output=True, text=True, timeout=30)
    return logf.read_text().split('\n')[:-1]


def run_cloudflare(script, work, domain, zones, record, param_opt=''):
    stub = work / 'stub'
    stub.mkdir(exist_ok=True)
    for name, body in (('curl', STUB_CURL), ('jsonfilter', STUB_JSONFILTER)):
        (stub / name).write_text(body)
        (stub / name).chmod(0o700)
    calls, logf = work / 'calls', work / 'log'
    for f in (calls, logf):
        f.write_text('')
    env = dict(os.environ, PATH=f'{stub}:{os.environ["PATH"]}', STUBDIR=str(stub), SCRIPT=str(script),
               CALLS=str(calls), LOGF=str(logf), ZONES=','.join(zones), RECORD=record,
               DATFILE=str(work / 'dat'), ERRFILE=str(work / 'err'))
    harness = f'domain="{domain}"; param_opt="{param_opt}"; DATFILE="$DATFILE"; ERRFILE="$ERRFILE"\n' + HARNESS
    p = subprocess.run(['sh', '-c', harness], env=env, capture_output=True, text=True, timeout=30)
    rc = re.search(r'rc=(\d+)', p.stdout)
    return (int(rc.group(1)) if rc else None), calls.read_text().split('\n')[:-1], logf.read_text()


with tempfile.TemporaryDirectory(prefix='bpir-ddns-') as directory:
    root = Path(directory)
    feed = root / 'feed'
    for name in FILES:
        target = feed / 'net/ddns-scripts' / name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source / 'net/ddns-scripts' / name, target)
    script = feed / 'net/ddns-scripts/files/usr/lib/ddns/update_cloudflare_com_v4.sh'
    noip_script = feed / 'net/ddns-scripts/files/usr/lib/ddns/update_no-ip_com.sh'
    updater_script = feed / 'net/ddns-scripts/files/usr/lib/ddns/dynamic_dns_updater.sh'
    sent_ok = "LOG6 Update successful - IP '203.0.113.5' send"
    forced_ok = "LOG6 Forced update successful - IP: '203.0.113.5' send"
    subprocess.run(['git', 'init', '-q', str(feed)], check=True)

    if not args.prepared:
        # The defect: a plain subdomain fails because only the full name is tried as a zone.
        rc, calls, log = run_cloudflare(script, root, 'ddns-test.example.com', ['example.com'], 'ddns-test.example.com')
        assert rc == 127 and calls == ['GET /zones?name=ddns-test.example.com'], (rc, calls)
        assert "Could not detect 'zone id'" in log, log
        # No-IP sent a dummy localhost update before the real one.
        rc, calls = run_noip(noip_script, root)
        assert rc == 0 and len(calls) == 2 and 'myip=127.0.0.1' in calls[0], (rc, calls)
        # Both success lines were logged for an update that changed the address.
        assert run_success_branch(updater_script, root, '198.18.0.1') == [sent_ok, forced_ok]
        for patch in PATCHES:
            subprocess.run(['git', '-C', str(feed), 'apply', '--check', str(patch)], check=True)
            subprocess.run(['git', '-C', str(feed), 'apply', str(patch)], check=True)
    for patch in PATCHES:
        subprocess.run(['git', '-C', str(feed), 'apply', '--reverse', '--check', str(patch)], check=True)
    subprocess.run(['sh', '-n', str(script)], check=True)

    # HTTPS: every update URL of the five product providers is https.
    d = feed / 'net/ddns-scripts'
    release = re.search(r'^PKG_RELEASE:=(\d+)$', (d / 'Makefile').read_text(), re.M)
    assert release and int(release.group(1)) >= 9, 'PKG_RELEASE not bumped'
    for name in ('duckdns.org', 'dynu.com', 'afraid.org-v2-token'):
        spec = json.loads((d / f'files/usr/share/ddns/default/{name}.json').read_text())
        urls = [spec[v]['url'] for v in ('ipv4', 'ipv6') if v in spec]
        assert urls and all(u.startswith('https://') for u in urls), (name, urls)
    for name, script_name in (('no-ip.com', 'update_no-ip_com.sh'), ('cloudflare.com-v4', 'update_cloudflare_com_v4.sh')):
        spec = json.loads((d / f'files/usr/share/ddns/default/{name}.json').read_text())
        assert spec['ipv4']['url'] == script_name, (name, spec)
        text = (d / 'files/usr/lib/ddns' / script_name).read_text()
        assert not re.search(r'"http://', text), f'{script_name} still has an http:// URL'
    noip = (d / 'files/usr/lib/ddns/update_no-ip_com.sh').read_text()
    assert noip.count('="https://[USERNAME]:[PASSWORD]@dynupdate') == 2, 'No-IP update URLs are not https'
    subprocess.run(['sh', '-n', str(noip_script)], check=True)
    # No-IP: one request with the real address; a failed second request can no longer leave
    # the host at 127.0.0.1.
    rc, calls = run_noip(noip_script, root)
    assert rc == 0 and calls == ['https://user:pass@dynupdate.noip.com/nic/update?hostname=host.example.net'
                                 '&myip=203.0.113.5'], (rc, calls)
    # One success line per update: the address changed, or a forced update of the same address.
    subprocess.run(['sh', '-n', str(updater_script)], check=True)
    assert run_success_branch(updater_script, root, '198.18.0.1') == [sent_ok]
    assert run_success_branch(updater_script, root, '203.0.113.5') == [forced_ok]
    # "Public address lookup" (ip_source web) defaults to checkip over HTTPS, so an on-path host
    # cannot feed the router a fake address to publish.
    updater = (d / 'files/usr/lib/ddns/dynamic_dns_updater.sh').read_text()
    defaults = re.findall(r'ip_url="([^"]+)"', updater)
    assert defaults == ['https://checkip.dyndns.com', 'https://checkipv6.dyndns.com'], defaults

    # Provider answers: ddns-scripts treats any HTTP 200 as accepted when a service has no
    # answer, so Dynu badauth or a bad FreeDNS token counted as success. Match the way
    # send_update does it (grep -i -E on the reply).
    def accepted(answer, body):
        return subprocess.run(['grep', '-i', '-E', answer], input=body, text=True, capture_output=True).returncode == 0
    for name, ok, bad in (
            ('dynu.com', ['good 203.0.113.5', 'nochg 203.0.113.5'], ['badauth', 'nohost', 'notfqdn', '911', 'abuse']),
            ('afraid.org-v2-token',
             ['Updated bpir-x.mooo.com from 198.18.0.1 to 203.0.113.5 in 0.4 seconds',
              'No IP change detected for bpir-x.mooo.com with IP 203.0.113.5, skipping update',
              'ERROR: Address 203.0.113.5 has not changed.'],
             ['ERROR: Invalid update URL (2)', 'ERROR: Unable to locate this record']),
            # Anchored: an error page that merely contains "ok" (e.g. "token") is not an OK.
            ('duckdns.org', ['OK'], ['KO', '<html><body>Invalid token</body></html>'])):
        spec = json.loads((d / f'files/usr/share/ddns/default/{name}.json').read_text())
        for v in ('ipv4', 'ipv6'):
            answer = spec[v].get('answer')
            assert answer, (name, v, 'no answer check')
            assert all(accepted(answer, b) for b in ok), (name, v, answer, ok)
            assert not any(accepted(answer, b) for b in bad), (name, v, answer, bad)

    # Cloudflare: plain subdomain walks to the zone and updates the full record name.
    rc, calls, log = run_cloudflare(script, root, 'ddns-test.example.com', ['example.com'], 'ddns-test.example.com')
    assert rc == 0, (rc, calls, log)
    assert calls == ['GET /zones?name=ddns-test.example.com', 'GET /zones?name=example.com',
                     'GET /zones/zid-example.com/dns_records?name=ddns-test.example.com&type=A',
                     'PATCH /zones/zid-example.com/dns_records/rid'], calls
    # Nested zones: the most specific zone wins.
    rc, calls, _ = run_cloudflare(script, root, 'a.home.example.co.uk', ['example.co.uk', 'home.example.co.uk'],
                                  'a.home.example.co.uk')
    assert rc == 0 and calls[:2] == ['GET /zones?name=a.home.example.co.uk', 'GET /zones?name=home.example.co.uk'], calls
    assert calls[2].startswith('GET /zones/zid-home.example.co.uk/dns_records?name=a.home.example.co.uk'), calls
    # A zone the token cannot see: stop at two labels, never query the TLD, send nothing.
    rc, calls, log = run_cloudflare(script, root, 'x.other.net', ['example.com'], 'x.other.net')
    assert rc == 127 and calls == ['GET /zones?name=x.other.net', 'GET /zones?name=other.net'], (rc, calls)
    assert "Could not detect 'zone id'" in log and not any(c.startswith('PATCH') for c in calls), log
    # host@zone keeps its exact upstream behaviour: one zone query, no walking.
    rc, calls, _ = run_cloudflare(script, root, 'ddns-test@example.com', ['example.com'], 'ddns-test.example.com')
    assert rc == 0 and calls[0] == 'GET /zones?name=example.com' and calls.count('GET /zones?name=example.com') == 1, calls
    # The apex is its own zone.
    rc, calls, _ = run_cloudflare(script, root, 'example.com', ['example.com'], 'example.com')
    assert rc == 0 and calls[:2] == ['GET /zones?name=example.com',
                                     'GET /zones/zid-example.com/dns_records?name=example.com&type=A'], calls
    # A user-defined zone_id is honoured while walking.
    rc, calls, _ = run_cloudflare(script, root, 'ddns-test.example.com', ['example.com'], 'ddns-test.example.com',
                                  'zone_id=zid-example.com')
    assert rc == 0 and calls[1] == 'GET /zones?name=example.com', calls
    # ... and a more specific zone with another id is skipped, not taken.
    rc, calls, _ = run_cloudflare(script, root, 'ddns-test.sub.example.com', ['sub.example.com', 'example.com'],
                                  'ddns-test.sub.example.com', 'zone_id=zid-example.com')
    assert rc == 0 and calls[:3] == ['GET /zones?name=ddns-test.sub.example.com', 'GET /zones?name=sub.example.com',
                                     'GET /zones?name=example.com'], calls
    assert calls[3].startswith('GET /zones/zid-example.com/dns_records?name=ddns-test.sub.example.com'), calls
    # host@zone never walks, even when the given zone is not visible and a parent is.
    rc, calls, _ = run_cloudflare(script, root, 'ddns-test@sub.example.com', ['example.com'], 'ddns-test.sub.example.com')
    assert rc == 127 and calls == ['GET /zones?name=sub.example.com'], (rc, calls)

print('PASS: ddns-scripts patches: HTTPS update URLs for DuckDNS, Dynu, No-IP (FreeDNS and Cloudflare already HTTPS) and the '
      'public address lookup, a single No-IP request with the real address, one success line per update, '
      'answer checks reject Dynu/FreeDNS/DuckDNS error replies; '
      'Cloudflare finds the zone of a plain record name, keeps host@zone and apex behaviour, honours zone_id, '
      'and sends nothing for a zone it cannot see')
