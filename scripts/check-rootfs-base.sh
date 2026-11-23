#!/bin/bash
# Post-build gate for the checks that hold for every image, with or without the
# proprietary UI package: the kernel modules users rely on, the apk repository
# list, and the boot-time IPsec IPv4 restriction (KI-10) from bpirouter-base.
#
# check-rootfs-integrity.sh runs this first; build-full.sh runs it on its own
# for an image built without the UI, where the full gate has no payload to check.
set -euo pipefail

ROOT=${1:-}
fail() { echo "FAIL: rootfs base: $*" >&2; exit 1; }
[ $# -eq 1 ] && [ -n "$ROOT" ] || fail "usage: $(basename "$0") <assembled-rootfs>"
[ -d "$ROOT" ] || fail "target rootfs $ROOT is not a directory"

has_module() { find "$ROOT/lib/modules" -type f -name "$1.ko*" -print -quit 2>/dev/null | grep -q .; }

# Kernel modules shipped for user-installed software (v1.6.1). The kernel is
# built here, so users cannot add official kmod packages themselves.
for module in nft_tproxy nft_socket usb-storage uas exfat ntfs3 nf_conntrack_netlink r8152 ax88179_178a ftdi_sio cp210x ch341 pl2303 cdc-acm zram; do
	has_module "$module" || fail "user kernel module $module.ko is absent"
done
# ipheth would let the uplink classifier adopt an iPhone on an unverified path;
# br_netfilter would pass bridged traffic through the IP firewall.
for module in ipheth br_netfilter; do
	! has_module "$module" || fail "forbidden kernel module $module.ko is present"
done

# The local bpirouter feed is never published as a package repository. An image
# whose apk list names it makes every `apk update` report a missing repository.
distfeeds=$ROOT/etc/apk/repositories.d/distfeeds.list
if [ -e "$distfeeds" ]; then
	! grep -Fq '/bpirouter/packages.adb' "$distfeeds" ||
		fail "apk repository list names the unpublished bpirouter feed"
fi

# The IPsec IPv4 restriction runs at boot, before the firewall (19).
ipsec_init=$ROOT/etc/init.d/bpirouter-ipsec-ipv4
for file in etc/init.d/bpirouter-ipsec-ipv4 usr/libexec/bpirouter-ipsec-ipv4; do
	[ -f "$ROOT/$file" ] || fail "missing /$file"
	[ -x "$ROOT/$file" ] || fail "/$file is not executable"
done
[ "$(sed -n 's/^START=//p' "$ipsec_init" | head -1)" = 12 ] || fail "IPsec IPv4 restriction is not START=12"
[ "$(sed -n 's/^START=//p' "$ROOT/etc/init.d/firewall" 2>/dev/null | head -1)" = 19 ] ||
	fail "firewall is not START=19"
link=$ROOT/etc/rc.d/S12bpirouter-ipsec-ipv4
[ -L "$link" ] || fail "missing rc.d/S12bpirouter-ipsec-ipv4"
[ "$(readlink "$link")" = ../init.d/bpirouter-ipsec-ipv4 ] ||
	fail "rc.d/S12bpirouter-ipsec-ipv4 does not point exactly to ../init.d/bpirouter-ipsec-ipv4"
grep -Fq 'PROG=${BPIR_IPSEC_IPV4_PROG:-/usr/libexec/bpirouter-ipsec-ipv4}' "$ipsec_init" ||
	fail "IPsec IPv4 init does not select its helper"
# Run its boot() against a probe helper that fails: the boot must call it and
# survive it. A matching line elsewhere in the script would prove neither.
ipsec_probe=$(mktemp -d) || fail "cannot create the IPsec init probe"
printf '#!/bin/sh\n: >"%s/ran"\nexit 3\n' "$ipsec_probe" >"$ipsec_probe/helper"
chmod +x "$ipsec_probe/helper"
if ! ( BPIR_IPSEC_IPV4_PROG="$ipsec_probe/helper"; . "$ipsec_init"; boot ) >/dev/null 2>&1; then
	rm -rf "$ipsec_probe"
	fail "IPsec IPv4 init does not run its helper without failing the boot"
fi
[ -f "$ipsec_probe/ran" ] || { rm -rf "$ipsec_probe"; fail "IPsec IPv4 init does not run its helper at boot"; }
rm -rf "$ipsec_probe"

echo "PASS: rootfs base: user kernel modules present, ipheth and br_netfilter absent, no unpublished feed, IPsec IPv4 restriction at boot before the firewall"
