#!/usr/bin/env python3
"""Render real fw4 templates and exercise S2S policy in private namespaces.

Requires Linux user/network namespaces, nft, iproute2, Python, native ucode+fs,
prepared firewall4 sources, and a Go internal/s2s test executable. UCI/ubus
inputs and tailscale0 are fixtures; this does not test Tailscale encryption.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import socket
import errno
import time

BUILD = Path(__file__).resolve().parents[1]


def checked(*args, **kwargs):
    p = subprocess.run([str(x) for x in args], text=True, capture_output=True,
                       timeout=30, **kwargs)
    assert p.returncode == 0, (args, p.stdout, p.stderr)
    return p.stdout


def echo_server(port, family=socket.AF_INET):
    sock = socket.socket(family)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    if family == socket.AF_INET6:
        sock.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
    sock.bind(("::" if family == socket.AF_INET6 else "0.0.0.0", port))
    sock.listen()

    def echo(conn):
        with conn:
            while True:
                try:
                    data = conn.recv(1024)
                    if not data:
                        return
                    conn.sendall(data)
                except OSError:
                    return

    def accept():
        while True:
            try:
                conn, _ = sock.accept()
                threading.Thread(target=echo, args=(conn,), daemon=True).start()
            except OSError:
                return

    threading.Thread(target=accept, daemon=True).start()
    return sock


def worker():
    servers = [echo_server(8765), echo_server(8765, socket.AF_INET6)]
    connections = {}
    print("ready", flush=True)
    for line in sys.stdin:
        request = json.loads(line)
        try:
            if request.get("mtu"):
                with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
                    s.setsockopt(socket.IPPROTO_IP, 10, 2)  # IP_MTU_DISCOVER = IP_PMTUDISC_DO
                    s.setsockopt(socket.IPPROTO_IP, 11, 1)  # IP_RECVERR
                    s.connect((request["host"], 9876))
                    s.send(b"x" * 1400)
                    deadline = time.monotonic() + 1
                    ok = False
                    while time.monotonic() < deadline:
                        try:
                            _, ancillary, _, _ = s.recvmsg(4096, 512, socket.MSG_ERRQUEUE)
                            ok = any(level == socket.IPPROTO_IP and kind == 11 and
                                     int.from_bytes(data[:4], sys.byteorder) == errno.EMSGSIZE
                                     for level, kind, data in ancillary)
                            break
                        except BlockingIOError:
                            time.sleep(0.01)
                    print(json.dumps({"ok": ok}), flush=True)
                    continue
            key = request["key"]
            if request.get("new", True):
                s = socket.socket(socket.AF_INET6 if ":" in request["host"] else socket.AF_INET)
                s.settimeout(0.4)
                s.connect((request["host"], request.get("port", 8765)))
                connections[key] = s
            s = connections[key]
            s.sendall(b"probe")
            ok = s.recv(5) == b"probe"
        except OSError:
            ok = False
        print(json.dumps({"ok": ok}), flush=True)


def render(args, root):
    files = root / "files"
    (files / "uci").mkdir(parents=True, exist_ok=True)
    fw = {"defaults": {"input": "REJECT", "output": "ACCEPT", "forward": "REJECT",
                       "flow_offloading": "0", "flow_offloading_hw": "0", "auto_helper": "0"},
          "zone": [], "forwarding": [{"src": "lan", "dest": "wan"}], "rule": []}
    for name, device in [("lan", "br-lan"), ("bpir_guest", "br-guest"),
                         ("bpir_iot", "br-iot"), ("wan", "eth-wan")]:
        fw["zone"].append({"name": name, "device": [device], "input": "ACCEPT" if name == "lan" else "REJECT",
                           "output": "ACCEPT", "forward": "REJECT"})
    managed = json.loads((root / "managed-firewall.json").read_text())
    fw["zone"].append(managed["zone"])
    fw["rule"] = managed["rule"]
    (files / "uci/firewall.json").write_text(json.dumps(fw))
    (files / "uci/helpers.json").write_text("{}")
    source = '{% include("./root/usr/share/firewall4/main.uc", { getenv: function(k) { return k == "ACTION" ? "print" : null; } }); %}'
    rendered = checked(args.ucode, "-S", "-T,", "-L", str(args.ucode.parent / "*.so"),
                       "-L./tests/lib", "-L./root/usr/share/ucode",
                       "-D", "MOCK_SEARCH_PATH=" + json.dumps([str(files), "./tests/mocks"]),
                       "-l", "mocklib", "-l", "fw4", "-", input=source, cwd=args.fw4)
    (root / "fw4.nft").write_text(rendered)
    checked("nft", "-f", root / "fw4.nft")
    assert "tcp option maxseg size set rt mtu" in rendered, "missing MSS path"


def main(args, root):
    peers = {}
    servers = []
    env = {**os.environ, "BPIR_S2S_ACCESS_FIXTURE": str(root)}

    def policy(mode, succeeds=True):
        p = subprocess.run([args.s2s_binary, "-test.run", "^TestAuthorizationNativeFixture$"],
                           env={**env, "BPIR_S2S_ACCESS_MODE": mode}, text=True,
                           capture_output=True, timeout=20)
        assert (p.returncode == 0) == succeeds, (mode, p.stdout, p.stderr)

    try:
        policy("export")
        checked("ip", "link", "set", "lo", "up")
        checked("sysctl", "-qw", "net.ipv4.ip_forward=1", "net.ipv6.conf.all.forwarding=1")
        for name, device, local, remote, v6 in [
            ("remote", "tailscale0", "100.64.0.1", "100.64.0.2", "fd00:1"),
            ("lan", "br-lan", "192.168.100.1", "192.168.100.2", "fd00:2"),
            ("guest", "br-guest", "192.168.101.1", "192.168.101.2", "fd00:3"),
            ("wan", "eth-wan", "192.168.1.1", "192.168.1.2", "fd00:4"),
        ]:
            p = subprocess.Popen(["unshare", "-n", sys.executable, __file__, "--worker"],
                                 text=True, stdin=subprocess.PIPE, stdout=subprocess.PIPE)
            peers[name] = p
            assert p.stdout.readline().strip() == "ready"
            checked("ip", "link", "add", device, "type", "veth", "peer", "name", "peer")
            checked("ip", "link", "set", "peer", "netns", p.pid)
            checked("ip", "addr", "add", local + "/24", "dev", device)
            checked("ip", "-6", "addr", "add", v6 + "::1/64", "dev", device, "nodad")
            checked("ip", "link", "set", device, "up")
            for command in [
                ["link", "set", "lo", "up"], ["addr", "add", remote + "/24", "dev", "peer"],
                ["-6", "addr", "add", v6 + "::2/64", "dev", "peer", "nodad"],
                ["link", "set", "peer", "up"], ["route", "add", "default", "via", local],
                ["-6", "route", "add", "default", "via", v6 + "::1"],
            ]:
                checked("nsenter", "-t", p.pid, "-n", "ip", *command)
        render(args, root)
        checked("nft", "-f", args.guard)
        for port in [22, 53, 80, 443, 8080, 8081]:
            servers.append(echo_server(port))
        count = 0

        def probe(peer, host, expect, port=8765, key=None, new=True):
            nonlocal count
            count += 1
            p = peers[peer]
            p.stdin.write(json.dumps(dict(host=host, port=port, key=key or str(count), new=new)) + "\n")
            p.stdin.flush()
            got = json.loads(p.stdout.readline())["ok"]
            assert got == expect, (peer, host, port, new, got, expect)

        policy("apply")
        probe("remote", "192.168.100.2", True, key="forward")
        probe("lan", "100.64.0.2", True, key="reverse")
        probe("remote", "100.64.0.1", True, 443, key="management")
        probe("remote", "100.64.0.1", True, 80)
        for port in [22, 53, 8080, 8081]:
            probe("remote", "100.64.0.1", False, port)
        probe("remote", "192.168.101.2", False)
        probe("guest", "100.64.0.2", False)
        probe("remote", "192.168.1.2", False)
        probe("wan", "100.64.0.2", False)
        probe("remote", "fd00:2::2", False)
        probe("lan", "fd00:1::2", False)
        probe("lan", "192.168.1.2", True, key="ordinary")
        # The early guard must enforce scope even if another ordinary rule
        # permits more. Otherwise fw4's rejection would mask a broad grant.
        checked("nft", "insert", "rule", "inet", "fw4", "input", "iifname", "tailscale0", "accept")
        checked("nft", "insert", "rule", "inet", "fw4", "forward", "iifname", "tailscale0", "accept")
        probe("remote", "100.64.0.1", False, 22)
        probe("remote", "192.168.101.2", False)
        probe("remote", "192.168.1.2", False)
        checked("ip", "link", "set", "br-lan", "mtu", "1280")
        peers["remote"].stdin.write(json.dumps({"mtu": True, "host": "192.168.100.2"}) + "\n")
        peers["remote"].stdin.flush()
        assert json.loads(peers["remote"].stdout.readline())["ok"], "router-generated PMTU feedback was lost"
        checked("ip", "link", "set", "br-lan", "mtu", "1500")
        # An actual changed/missing rule must invalidate status readback.
        checked("nft", "insert", "rule", "inet", "bpirouter_s2s", "forward", "accept")
        policy("verify", succeeds=False)
        policy("apply")
        checked("nft", "flush", "chain", "inet", "fw4", "forward_s2s")
        policy("verify", succeeds=False)
        render(args, root)
        policy("closed")
        probe("remote", "192.168.100.2", False, key="forward", new=False)
        probe("lan", "100.64.0.2", False, key="reverse", new=False)
        probe("remote", "100.64.0.1", False, 443, key="management", new=False)
        probe("lan", "192.168.1.2", True, key="ordinary", new=False)
        probe("lan", "192.168.100.1", True, 443)
        policy("apply-guest")
        probe("remote", "192.168.101.2", True)
        probe("guest", "100.64.0.2", True)
        probe("remote", "192.168.100.2", False)
        probe("remote", "100.64.0.1", False, 443)
        probe("remote", "100.64.0.1", False, 80)
        print(f"PASS: actual fw4 + native nft, {count} TCP checks, UDP PMTU feedback and altered-rule rejection")
    finally:
        for p in peers.values():
            p.terminate()
            p.wait(timeout=5)
        for s in servers:
            s.close()


if __name__ == "__main__":
    if "--worker" in sys.argv:
        worker()
        sys.exit()
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fw4", type=Path, required=True)
    parser.add_argument("--ucode", type=Path, required=True)
    parser.add_argument("--s2s-binary", type=Path, required=True)
    parser.add_argument("--guard", type=Path, default=BUILD.parent / "bpirouter-feeds/net/bpirouter-base/files/usr/share/nftables.d/ruleset-pre/90-bpirouter-s2s.nft")
    args = parser.parse_args()
    parent = os.environ.get("BPIR_S2S_PARENT_NS")
    current = os.readlink("/proc/self/ns/net")
    if parent is None:
        os.execvpe("unshare", ["unshare", "-Urn", sys.executable, __file__, *sys.argv[1:]],
                   {**os.environ, "BPIR_S2S_PARENT_NS": current})
    assert parent != current, "refusing firewall changes in caller network namespace"
    with tempfile.TemporaryDirectory(prefix="s2s-access-") as tmp:
        main(args, Path(tmp))
