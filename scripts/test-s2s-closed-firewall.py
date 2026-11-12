#!/usr/bin/env python3
"""Load the shipped default-deny policy and exercise real TCP in private netns."""

import json
import os
from pathlib import Path
import socket
import subprocess
import sys


def command(*args, **kwargs):
    return subprocess.check_output(args, text=True, **kwargs).strip()


def agent():
    sockets = {}
    print('ready', flush=True)
    for line in sys.stdin:
        q = json.loads(line)
        try:
            op, name = q['op'], q.get('name')
            value = None
            if op == 'quit':
                return
            if op == 'command':
                value = command(*q['args'])
            elif op in ('listen', 'connect'):
                s = socket.socket(socket.AF_INET6 if ':' in q['ip'] else socket.AF_INET)
                s.settimeout(0.5)
                if op == 'listen':
                    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
                    s.bind((q['ip'], 8443))
                    s.listen(16)
                else:
                    s.connect((q['ip'], 8443))
                sockets[name] = s
            elif op == 'accept':
                s, _ = sockets[q['listener']].accept()
                s.settimeout(0.5)
                sockets[name] = s
            elif op == 'send':
                sockets[name].sendall(q['value'].encode())
            elif op == 'receive':
                value = sockets[name].recv(1024).decode()
            else:
                raise ValueError(op)
            print(json.dumps({'ok': True, 'value': value}), flush=True)
        except OSError as error:
            print(json.dumps({'ok': False, 'error': type(error).__name__}), flush=True)


class Node:
    def __init__(self, isolated=True):
        argv = (['unshare', '-n'] if isolated else []) + [sys.executable, __file__, '--agent']
        self.p = subprocess.Popen(argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
        assert self.p.stdout.readline().strip() == 'ready'

    def call(self, op, **args):
        self.p.stdin.write(json.dumps({'op': op, **args}) + '\n')
        self.p.stdin.flush()
        return json.loads(self.p.stdout.readline())

    def do(self, op, **args):
        reply = self.call(op, **args)
        assert reply['ok'], (op, args, reply)
        return reply['value']

    def command(self, *args):
        return self.do('command', args=args)

    def stop(self):
        self.p.stdin.write('{"op":"quit"}\n')
        self.p.stdin.flush()
        self.p.wait(timeout=3)


def probe(rules, output):
    assert os.readlink('/proc/self/ns/net') != os.environ['BPIR_PARENT_NETNS']
    nodes = []
    try:
        command('ip', 'link', 'set', 'lo', 'up')
        command('sysctl', '-qw', 'net.ipv4.ip_forward=1', 'net.ipv6.conf.all.forwarding=1',
                'net.ipv6.conf.default.forwarding=1', 'net.ipv6.conf.default.accept_dad=0')
        for i, iface in enumerate(('tailscale0', 'lan0', 'wan0'), 1):
            n = Node()
            nodes.append(n)
            command('ip', 'link', 'add', iface, 'type', 'veth', 'peer', 'name', 'endpoint')
            command('ip', 'link', 'set', 'endpoint', 'netns', str(n.p.pid))
            command('ip', 'addr', 'add', f'192.0.{i}.1/24', 'dev', iface)
            command('ip', '-6', 'addr', 'add', f'fd00:{i}::1/64', 'dev', iface, 'nodad')
            command('ip', 'link', 'set', iface, 'up')
            n.command('sysctl', '-qw', 'net.ipv6.conf.endpoint.accept_dad=0')
            n.command('ip', 'link', 'set', 'lo', 'up')
            n.command('ip', 'addr', 'add', f'192.0.{i}.2/24', 'dev', 'endpoint')
            n.command('ip', '-6', 'addr', 'add', f'fd00:{i}::2/64', 'dev', 'endpoint', 'nodad')
            n.command('ip', 'link', 'set', 'endpoint', 'up')
            n.command('ip', 'route', 'add', 'default', 'via', f'192.0.{i}.1')
            n.command('ip', '-6', 'route', 'add', 'default', 'via', f'fd00:{i}::1')
        remote, lan, wan = nodes
        router = Node(isolated=False)
        nodes.append(router)
        # Model fw4's early established acceptance; the production guard must
        # override it. This is not a substitute for full fw4 rendering on-board.
        command('nft', '-f', '-', input='''table inet fixture {
chain input { type filter hook input priority 0; policy accept; ct state established,related accept; }
chain output { type filter hook output priority 0; policy accept; ct state established,related accept; }
chain forward { type filter hook forward priority 0; policy accept; ct state established,related accept; }
}''')
        pairs = []
        for family in (4, 6):
            ip = (lambda i, host: f'192.0.{i}.{host}') if family == 4 else (lambda i, host: f'fd00:{i}::{host}')
            listener = f'listener-{family}'
            for node, address in ((lan, ip(2, 2)), (wan, ip(3, 2)), (remote, ip(1, 2)), (router, ip(1, 1))):
                node.do('listen', name=listener, ip=address)
            for label, client, server, address, blocked in (
                ('management', remote, router, ip(1, 1), True),
                ('incoming-lan', remote, lan, ip(2, 2), True),
                ('outgoing-lan', lan, remote, ip(1, 2), True),
                ('incoming-wan', remote, wan, ip(3, 2), True),
                ('local-wan', lan, wan, ip(3, 2), False),
                ('local-management', lan, router, ip(1, 1), False),
            ):
                name = f'{label}-{family}'
                client.do('connect', name=name, ip=address)
                server.do('accept', name=name, listener=listener)
                pairs.append((name, client, server, address, blocked))
        for name, client, server, _, _ in pairs:
            client.do('send', name=name, value='before')
            assert server.do('receive', name=name) == 'before'
            server.do('send', name=name, value='before-return')
            assert client.do('receive', name=name) == 'before-return'
        command('nft', '-f', rules)
        command('nft', '-f', rules)  # Ordinary reload replaces the table atomically.
        Path(output).write_text(command('nft', '-j', 'list', 'table', 'inet', 'bpirouter_s2s') + '\n')
        for name, client, server, address, blocked in pairs:
            for sender, receiver in ((client, server), (server, client)):
                sender.do('send', name=name, value='after')
                result = receiver.call('receive', name=name)
                expected = {'ok': False, 'error': 'TimeoutError'} if blocked else {'ok': True, 'value': 'after'}
                assert result == expected, (name, result, expected)
            if blocked:
                result = client.call('connect', name=name+'-new', ip=address)
                assert not result['ok'], (name, 'new connection allowed')
            print('PASS:', name, 'blocked both ways' if blocked else 'preserved', flush=True)
    finally:
        for node in reversed(nodes):
            node.stop()


if sys.argv[1:] == ['--agent']:
    agent()
elif len(sys.argv) == 4 and sys.argv[1] == '--inside':
    probe(sys.argv[2], sys.argv[3])
elif len(sys.argv) == 3:
    env = dict(os.environ, BPIR_PARENT_NETNS=os.readlink('/proc/self/ns/net'))
    subprocess.run(['unshare', '-Urn', sys.executable, __file__, '--inside',
                    str(Path(sys.argv[1]).resolve()), str(Path(sys.argv[2]).resolve())], env=env, check=True)
else:
    raise SystemExit('usage: test-s2s-closed-firewall.py <shipped-rules.nft> <result.json>')
