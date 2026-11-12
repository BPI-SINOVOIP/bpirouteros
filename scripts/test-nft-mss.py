#!/usr/bin/env python3
# Copyright (C) 2026 Ning <mimallaus@gmail.com>
"""Execute the kernel's MSS calculator with controlled link and route MTUs."""
import argparse
import os
from pathlib import Path
import re
import shlex
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--prepared', action='store_true', help='require the fix in the built kernel source')
parser.add_argument('--kernel-tree', type=Path)
args = parser.parse_args()
build = Path(__file__).resolve().parents[1]
openwrt = Path(os.environ.get('BPIR_OPENWRT_DIR', build / 'openwrt'))
trees = [args.kernel_tree] if args.kernel_tree else list(openwrt.glob(
    'build_dir/target-*/linux-mediatek_filogic/linux-*/net/netfilter/nft_rt.c'))
if not args.kernel_tree:
    trees = [p.parents[2] for p in trees]
assert len(trees) == 1, 'Expected one prepared kernel; supply --kernel-tree'
source = trees[0] / 'net/netfilter/nft_rt.c'
patch = build / 'patches/common/kernel/991-netfilter-nft-rt-clamp-to-ingress-mtu.patch'

# Only the kernel environment is substituted. The calculator below comes from
# nft_rt.c; expectations are packet-path requirements, not source-text matches.
prefix = r'''
#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <linux/ip.h>
#include <linux/ipv6.h>
#include <linux/tcp.h>
#include <linux/netfilter.h>
typedef uint16_t u16;
typedef uint32_t u32;
#define min(a, b) ((a) < (b) ? (a) : (b))
#define min_t(t, a, b) min((t)(a), (t)(b))
#define READ_ONCE(x) (x)
struct net_device { int mtu; };
struct dst_entry { u32 mtu; };
struct sk_buff { struct iphdr ip; struct ipv6hdr ip6; u32 mark; };
struct nft_pktinfo { struct sk_buff *skb; struct net_device *in; int pf; };
struct flowi { union {
    struct { u32 daddr, flowi4_mark; } ip4;
    struct { struct in6_addr daddr; u32 flowi6_mark; } ip6;
} u; };
#define nft_pf(p) ((p)->pf)
#define nft_in(p) ((p)->in)
#define nft_net(p) (0)
#define ip_hdr(s) (&(s)->ip)
#define ipv6_hdr(s) (&(s)->ip6)
#define dst_mtu(d) ((d)->mtu)
static struct dst_entry reverse_route;
static int releases;
static void dst_release(struct dst_entry *d) { assert(d == &reverse_route); releases++; }
static void nf_route(int net, struct dst_entry **dst, struct flowi *fl, bool strict, int pf)
{
    (void)net; (void)strict;
    /* Reply marks need not select the ingress WAN (mwan3's connected LAN rule). */
    if (pf == NFPROTO_IPV4) assert(fl->u.ip4.daddr == 123);
    else assert(fl->u.ip6.daddr.s6_addr[15] == 123);
    *dst = reverse_route.mtu ? &reverse_route : NULL;
}
'''
suffix = r'''
int main(void)
{
    static const struct { const char *name; u32 in, out, reverse, v4, v6; } cases[] = {
        { "USB reply with main-table lookup", 1400, 1500, 1500, 1360, 1340 },
        { "outbound low-MTU WAN", 1500, 1400, 1500, 1360, 1340 },
        { "ordinary WAN", 1500, 1500, 1500, 1460, 1440 },
        { "PPPoE reply", 1492, 1500, 1500, 1452, 1432 },
        { "S2S ingress", 1280, 1500, 1500, 1240, 1220 },
        { "S2S egress", 1500, 1280, 1500, 1240, 1220 },
        { "smaller forward PMTU", 1400, 1300, 1500, 1260, 1240 },
        { "smaller reverse PMTU", 1400, 1500, 1300, 1260, 1240 },
        { "reverse lookup unavailable", 1400, 1500, 0, 1360, 1340 },
        { "no ingress device", 0, 1500, 1500, 1460, 1440 },
        { "local output reverse PMTU", 0, 1500, 1280, 1240, 1220 },
        { "invalid route MTU retains fallback", 0, 20, 1500, TCP_MSS_DEFAULT, TCP_MSS_DEFAULT },
    };
    for (unsigned i = 0; i < sizeof(cases) / sizeof(*cases); i++) {
        for (int family = 0; family < 2; family++) {
            struct sk_buff skb = { .ip.saddr = 123, .mark = 0x3f00 };
            skb.ip6.saddr.s6_addr[15] = 123;
            struct net_device in = { .mtu = cases[i].in };
            struct dst_entry forward = { .mtu = cases[i].out };
            struct nft_pktinfo pkt = { .skb = &skb, .in = cases[i].in ? &in : NULL,
                                      .pf = family ? NFPROTO_IPV6 : NFPROTO_IPV4 };
            reverse_route.mtu = cases[i].reverse;
            releases = 0;
            u16 result = get_tcpmss(&pkt, &forward);
            u16 expected = family ? cases[i].v6 : cases[i].v4;
            if (result != expected) {
                fprintf(stderr, "%s IPv%d: got %u, expected %u\n",
                        cases[i].name, family ? 6 : 4, result, expected);
                return 1;
            }
            assert(releases == !!cases[i].reverse);
        }
    }
    puts("PASS: 24 ingress, egress, path-MTU and local-output cases");
}
'''

with tempfile.TemporaryDirectory(prefix='bpir-nft-mss-') as tmp:
    root = Path(tmp)
    target = root / 'net/netfilter/nft_rt.c'
    target.parent.mkdir(parents=True)
    target.write_bytes(source.read_bytes())

    def apply(*options, check=True):
        return subprocess.run(['patch', '--force', '--silent', '-p1', *options, '-i', str(patch)],
                              cwd=root, capture_output=True, check=check)

    installed = apply('--reverse', '--dry-run', check=False).returncode == 0
    if args.prepared:
        assert installed, 'Prepared kernel is missing the ingress MSS fix'
    elif not installed:
        apply('--forward')
    fixed = target.read_text()

    def exercise(text):
        match = re.search(r'^static u16 get_tcpmss\([^\n]+\)\n\{.*?^\}', text, re.M | re.S)
        assert match, 'Kernel MSS function not found'
        unit = root / 'mss.c'
        unit.write_text(prefix + match[0] + suffix)
        binary = root / 'mss'
        subprocess.run(shlex.split(os.environ.get('CC', 'cc')) + [
            '-std=gnu11', '-Wall', '-Wextra', '-Werror', str(unit), '-o', str(binary)], check=True)
        return subprocess.run([str(binary)], capture_output=True, text=True)

    result = exercise(fixed)
    assert result.returncode == 0, result.stderr
    print(result.stdout.strip())
    apply('--reverse')
    baseline = exercise(target.read_text())
    assert baseline.returncode != 0 and 'USB reply with main-table lookup' in baseline.stderr
    print('PASS: unpatched kernel fails the policy-routed USB reply case')
