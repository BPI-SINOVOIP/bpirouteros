#!/usr/bin/env python3
"""Exercise the shipped fw4 adaptation with native ucode, Go and nft.

Requires Linux user/network namespaces, nft, BusyBox ash, native ucode+fs,
the prepared firewall4 source and an internal/s2s test binary (go test -c).
UCI rendering and procd are fixture inputs; this is not a device test.
"""
import argparse
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile

BUILD = Path(__file__).resolve().parents[1]
PATCH = BUILD / "patches/common/base-files/008-firewall4-product-lock.patch"


def run(*args, **kwargs):
    return subprocess.run([str(a) for a in args], text=True, capture_output=True,
                          timeout=40, **kwargs)


def checked(*args, **kwargs):
    p = run(*args, **kwargs)
    assert p.returncode == 0, (args, p.returncode, p.stdout, p.stderr)
    return p.stdout


def nft(text):
    checked("nft", "-f", "-", input=text)


def read_table(name):
    p = run("nft", "-j", "list", "table", "inet", name)
    return json.loads(p.stdout) if p.returncode == 0 else None


def ordinary():
    return "destroy table inet fw4\ntable inet fw4 {\n" + "".join(
        f"chain {hook} {{ type filter hook {hook} priority 0; policy drop; counter drop; }}\n"
        for hook in ("input", "output", "forward")) + "}\n"


def guard_closed():
    doc = read_table("bpirouter_s2s")
    rules = [v["rule"] for v in doc["nftables"] if "rule" in v] if doc else []
    assert len(rules) == 4, doc
    assert all(any("drop" in e for e in r["expr"]) for r in rules), doc


def prepare(args, root):
    tree = root / "openwrt"
    makefile = tree / "package/network/config/firewall4/Makefile"
    makefile.parent.mkdir(parents=True)
    shutil.copyfile(BUILD / "openwrt/package/network/config/firewall4/Makefile", makefile)
    checked("patch", "-p1", "--batch", "-i", PATCH, cwd=tree)
    src = root / "firewall4"
    shutil.copytree(args.fw4, src)
    checked("patch", "-p1", "--batch", "-i",
            tree / "package/network/config/firewall4/patches/910-bpirouter-s2s-lock-boundary.patch",
            cwd=src)
    checked("patch", "-R", "-p1", "--dry-run", "--batch", "-i",
            tree / "package/network/config/firewall4/patches/910-bpirouter-s2s-lock-boundary.patch",
            cwd=src)
    return src


def case(args, source, root, name, warm=False, pending=False, action="reload",
         helper_fails=False, main_fails=False, guard_fails=False, stop_fails=False,
         expected_status="blocked"):
    root.mkdir()
    bindir = root / "bin"
    bindir.mkdir()
    (bindir / "sh").symlink_to(args.busybox)
    guard = Path(args.guard)
    (root / "state").touch()
    if pending:
        (root / "pending").touch()
    if stop_fails:
        (root / "stop-failure").touch()
    (root / "ordinary.nft").write_text("invalid nft input\n" if main_fails else ordinary() + guard.read_text())
    nft("flush ruleset\n")
    if warm:
        nft(ordinary())
    nft(guard.read_text())
    nft('insert rule inet bpirouter_s2s forward iifname "tailscale0" accept\n')
    old = read_table("fw4")
    if guard_fails:
        guard = root / "invalid.nft"
        guard.write_text("invalid nft input\n")
    apid = root / "apid"
    apid.write_text("#!/bin/sh\n" + ("exit 127\n" if helper_fails else
                    'export BPIR_FW4_ACTION="${1#--s2s-firewall=}"\nexec ' +
                    shlex.quote(str(args.s2s_binary)) + " -test.run '^TestFirewallExecFixture$'\n"))
    apid.chmod(0o700)
    script = (source / "root/sbin/fw4").read_text()
    for old_path, new_path in (
        ("/var/run/fw4.lock", root / "lock"),
        ("/var/run/fw4.state", root / "state"),
        ("/usr/bin/bpirouter-apid", apid),
        ("/usr/share/nftables.d/ruleset-pre/90-bpirouter-s2s.nft", guard),
        ("/var/run/bpirouter-s2s", root / "runtime"),
    ):
        script = script.replace(old_path, str(new_path))
    (root / "fw4").write_text(script)
    product = root / "include.sh"
    product.write_text((source / "root/usr/libexec/bpirouter-s2s-firewall").read_text()
                       .replace("/usr/bin/bpirouter-apid", str(apid)))
    other = root / "other.sh"
    other.write_text('test ! -e /proc/self/fd/9 && test ! -e /proc/self/fd/1000 && touch "$BPIR_FW4_FIXTURE/other-ok"\n')
    (root / "includes.json").write_text(json.dumps({"includes": [
        {"type": "script", "path": str(product)}, {"type": "script", "path": str(other)}]}))
    uc = (source / "root/usr/share/firewall4/main.uc").read_text()
    start = uc.index("function product_firewall_loaded() {")
    end = uc.index('\n\n\nswitch (getenv("ACTION"))', start)
    functions = uc[start:end].replace("/usr/libexec/bpirouter-s2s-firewall", str(product))
    (root / "main.uc").write_text('let fs = require("fs");\nfunction read_state() { return json(fs.readfile(getenv("BPIR_INCLUDES"))); }\n' +
        functions + '\nif (getenv("ACTION") == "s2s-loaded") exit(product_firewall_loaded() ? 0 : 1);\nrun_includes();\n')
    utpl = bindir / "utpl"
    utpl.write_text('#!/bin/sh\ncase "$ACTION" in\nstart|print) '
                   'touch "$BPIR_FW4_FIXTURE/rendered"; touch "$BPIR_FW4_FIXTURE/state"; '
                   'cat "$BPIR_FW4_FIXTURE/ordinary.nft";;\n'
                   'includes|s2s-loaded) exec ' + shlex.quote(str(args.ucode)) + ' -L ' +
                   shlex.quote(str(args.ucode.parent / "*.so")) + " " +
                   shlex.quote(str(root / "main.uc")) + ";;\nesac\n")
    utpl.chmod(0o700)
    ubus = bindir / "ubus"
    ubus.write_text('#!/bin/sh\ntouch "$BPIR_FW4_FIXTURE/stop-requested"\nexit 1\n')
    ubus.chmod(0o700)
    env = {**os.environ, "PATH": str(bindir) + ":" + os.environ["PATH"],
           "BPIR_FW4_FIXTURE": str(root), "BPIR_INCLUDES": str(root / "includes.json"),
           "BPIR_TEST_GUARD": str(guard)}
    p = run(args.busybox, "sh", root / "fw4", action, env=env)
    preserve = warm and (pending or helper_fails)
    if preserve:
        assert p.returncode != 0, p
        assert read_table("fw4") == old, "warm rules were replaced"
        assert not (root / "rendered").exists(), "rendered unresolved input"
    else:
        assert (root / "rendered").exists(), "cold load was suppressed"
        if not main_fails:
            assert read_table("fw4") is not None, p.stderr
        assert (root / "other-ok").exists(), p.stderr
    if not guard_fails:
        guard_closed()
    else:
        assert expected_status == "isolation_unknown"
    if helper_fails:
        assert (root / "stop-requested").exists()
        status = json.loads((root / "runtime/firewall.json").read_text())["status"]
    else:
        status = (root / "status").read_text()
    assert status == expected_status, (status, expected_status, p.stdout, p.stderr)
    assert (root / "pending").exists() == pending, "preflight altered recovery state"
    print("PASS:", name, flush=True)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--fw4", type=Path, required=True)
    ap.add_argument("--busybox", type=Path, required=True)
    ap.add_argument("--ucode", type=Path, required=True)
    ap.add_argument("--s2s-binary", type=Path, required=True)
    ap.add_argument("--guard", type=Path, default=BUILD.parent / "bpirouter-feeds/net/bpirouter-base/files/usr/share/nftables.d/ruleset-pre/90-bpirouter-s2s.nft")
    ap.add_argument("--inside", action="store_true", help=argparse.SUPPRESS)
    args = ap.parse_args()
    if not args.inside:
        result = checked("unshare", "-Urn", sys.executable, Path(__file__).resolve(), *sys.argv[1:], "--inside",
                         env={**os.environ, "BPIR_PARENT_NETNS": os.readlink("/proc/self/ns/net")})
        print(result, end="")
        print("PASS: 9 patched fw4 execution cases")
        return
    assert os.readlink("/proc/self/ns/net") != os.environ["BPIR_PARENT_NETNS"]
    with tempfile.TemporaryDirectory(prefix="bpir-fw4-test-") as tmp:
        root = Path(tmp)
        src = prepare(args, root)
        for name, options in [
            ("normal-reload", {}),
            ("warm-reload", {"warm": True, "pending": True}),
            ("warm-restart", {"warm": True, "pending": True, "action": "restart"}),
            ("cold-start", {"pending": True, "action": "start"}),
            ("cold-reload", {"pending": True}),
            ("main-load-failure", {"warm": True, "main_fails": True}),
            ("isolation-failure", {"pending": True, "guard_fails": True, "stop_fails": True,
                                   "expected_status": "isolation_unknown"}),
            ("helper-failure-warm", {"warm": True, "helper_fails": True, "expected_status": "isolation_unknown"}),
            ("helper-failure-cold", {"helper_fails": True, "expected_status": "isolation_unknown"}),
        ]:
            case(args, src, root / name, name, **options)


if __name__ == "__main__":
    main()
