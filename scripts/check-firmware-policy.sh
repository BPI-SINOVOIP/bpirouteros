#!/bin/bash
# check-firmware-policy.sh — refuse an image that ships firmware the wrong way.
#
# Usage: check-firmware-policy.sh --board <board> --image <sysupgrade.itb>
#                                 --linux-firmware <linux-firmware-*.tar.*>
#                                 [--downloads-lock <DOWNLOADS.lock.json>]
#
# AEONSEMI's licence for the AS21xxx PHY firmware grants redistribution and
# excludes distribution "as part of the Linux kernel or in any other form which
# would require these files themselves to be covered by the terms of the GNU
# General Public License". CONFIG_EXTRA_FIRMWARE links the blob into vmlinux,
# which is that excluded form, so the firmware travels as an ordinary root
# filesystem file instead.
#
# That arrangement is one config line away from being undone. The PHY and MxL
# switch are therefore rootfs modules: the boot service makes a bounded PHY
# preparation attempt and then performs one switch probe. Optional external-PHY
# failure may degrade a 10G path but cannot suppress the independent four-port
# baseline. A hardware test done once will not preserve these properties. This
# will.
#
# The kernel is checked by searching for the firmware's bytes rather than for a
# config symbol: a symbol says what was asked for, the bytes say what shipped.
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$(dirname "$SCRIPT_DIR")"
[ -n "${BPIR_BUILD_DIR:-}" ] && BUILD_DIR="$BPIR_BUILD_DIR"

C='\033[0;36m'; G='\033[0;32m'; Y='\033[0;33m'; R='\033[0;31m'; N='\033[0m'
step() { echo -e "${C}▸ $1${N}"; }
ok()   { echo -e "${G}✓ $1${N}"; }
die()  { echo -e "${R}✗ $1${N}" >&2; exit 1; }

BOARD=""; IMAGE=""; LFW=""; DLOCK=""; REF=""; ROLE=""; PAIRED=""
while [ $# -gt 0 ]; do
    case "$1" in
        --board)              BOARD="$2"; shift 2 ;;
        --image)              IMAGE="$2"; shift 2 ;;
        --linux-firmware)     LFW="$2"; shift 2 ;;
        --reference-firmware) REF="$2"; shift 2 ;;
        --downloads-lock)     DLOCK="$2"; shift 2 ;;
        --role)               ROLE="$2"; shift 2 ;;
        --paired-sysupgrade)  PAIRED="$2"; shift 2 ;;
        *) die "unknown argument: $1" ;;
    esac
done
[ -n "$BOARD" ] && [ -n "$IMAGE" ] && { [ -n "$LFW" ] || [ -n "$REF" ]; } || die \
"usage: check-firmware-policy.sh --board <board> --image <sysupgrade.itb>
                                --linux-firmware <linux-firmware-*.tar.*>
                                [--downloads-lock <DOWNLOADS.lock.json>]
   or: ... --reference-firmware <already-extracted as21x1x_fw.bin>

--reference-firmware exists for batch use. Pulling one file out of a 600 MB xz
archive takes seconds, and doing it once per image made a six-board release
check time out; the caller extracts once and passes the result."
[ -f "$IMAGE" ] || die "no such image: $IMAGE"
[ -z "$LFW" ] || [ -f "$LFW" ] || die "no such linux-firmware archive: $LFW"
[ -z "$REF" ] || [ -f "$REF" ] || die "no such reference firmware: $REF"

source "$SCRIPT_DIR/boards.sh"
board_init "$BOARD"
BASE="openwrt-mediatek-filogic-$PROFILE"

FW=as21x1x_fw.bin

# The board is passed in, never inferred from the file name. Inferring it meant
# renaming an image turned the last two checks off silently, and those are
# exactly the checks a rename would need to skip.
# Every board is listed explicitly. board_init already rejects an unknown board,
# so the old `*) NEEDS_FW=no` could only ever catch a board that IS registered in
# boards.sh but was forgotten here -- and it answered "no firmware needed" for it,
# which is indistinguishable from a correct verdict and silently skips the whole
# firmware policy. Adding the seventh SKU is exactly that situation, so the
# default now fails instead of guessing.
case "$BOARD" in
    bpi-r4-pro)    NEEDS_FW=yes ;;   # AS21010P 10G PHYs need as21x1x_fw.bin
    bpi-r4-pro-4e) NEEDS_FW=no  ;;   # 4E carries no AS21010P (22-D, schematic sheet 21)
    bpi-r4|bpi-r4-lite|bpi-r3|bpi-r3-mini|openwrt-one) NEEDS_FW=no ;;
    *) die "no firmware policy registered for board: $BOARD" ;;
esac

TMP=$(mktemp -d -t bpir-fwpol-XXXXXX)
trap 'rm -rf "$TMP"' EXIT

# The same host-executable dumpimage problem as elsewhere: build_dir holds one
# per u-boot variant and one of them is built for the target.
# Probed against the tool, not against this image: a non-FIT deliverable makes
# every candidate "fail", and the loop then reports no dumpimage at all instead
# of reporting what the file is. Exit 126 is the kernel refusing to execute a
# binary built for the target.
di=""
for c in "$BUILD_DIR/openwrt/build_dir/host/u-boot-"*/tools/dumpimage \
         "$BUILD_DIR/openwrt/build_dir/"*/u-boot-*/tools/dumpimage; do
    [ -x "$c" ] || continue
    # `|| rc=$?` keeps set -e out of it: listing /dev/null is meant to fail, and
    # the only failure that disqualifies the binary is 126, cannot-execute.
    rc=0; "$c" -l /dev/null >/dev/null 2>&1 || rc=$?
    [ "$rc" -eq 126 ] || { di="$c"; break; }
done
[ -n "$di" ] || die "no host-executable dumpimage under $BUILD_DIR/openwrt/build_dir"

# Not every deliverable is a FIT. Bootloader pieces and partition tables cannot
# carry a kernel, but they are published, so they are searched raw rather than
# waved through -- and anything not recognised is refused. A new artifact type
# appearing in a release must stop the release, not pass by default.
# The shared classifier remains authoritative even when manifest assembly
# supplies a role. This prevents a mutable metadata label from selecting a
# weaker policy branch.
CLASSIFIED_ROLE=$("$SCRIPT_DIR/release-build-provenance.py" classify --base "$BASE" --file "$IMAGE") \
    || die "$(basename "$IMAGE") has no release artifact role"
[ -z "$ROLE" ] || [ "$ROLE" = "$CLASSIFIED_ROLE" ] \
    || die "declared role '$ROLE' does not match classifier role '$CLASSIFIED_ROLE'"
ROLE="$CLASSIFIED_ROLE"
case "$ROLE" in
    sysupgrade)              KERNEL_CARRIER=yes ;;
    initramfs)               KERNEL_CARRIER=yes ;;
    sdcard)                  KERNEL_CARRIER=gz ;;
    # A factory image is a raw flash image with the FIT written into it, the
    # same shape as an sdcard image without the gzip wrapper.
    factory)                 KERNEL_CARRIER=raw ;;
    bootloader|flashkit|metadata) KERNEL_CARRIER=no ;;
    *) die "unknown role '$ROLE'" ;;
esac
# Only a full sysupgrade image carries a root filesystem; the others have no
# rootfs to check for the firmware, modules or preparation service.
[ "$ROLE" = sysupgrade ] || NEEDS_FW=no

if [ "$KERNEL_CARRIER" = no ]; then
    if [ -n "$REF" ]; then RAWREF="$REF"; else
        tar -xf "$LFW" -C "$TMP" --wildcards "*/aeonsemi/$FW" 2>/dev/null || true
        RAWREF=$(find "$TMP" -name "$FW" | head -1)
    fi
    [ -n "$RAWREF" ] || die "no reference firmware to search for"
    python3 - "$IMAGE" "$RAWREF" <<'PYRAW' || exit 1
import sys
img = open(sys.argv[1], "rb").read()
if open(sys.argv[2], "rb").read() in img:
    sys.exit("FATAL: the firmware appears verbatim in %s" % sys.argv[1])
PYRAW
    ok "$(basename "$IMAGE"): not a kernel carrier, and does not contain the firmware"
    exit 0
fi

# ── The reference bytes, from one exact archive ──
# It used to take a directory and pick with `ls | head -1`. The shared download
# directory holds four linux-firmware releases and that picks the oldest --
# 20230804, which predates this firmware entirely. A check that quietly reads
# the wrong reference is worse than no check.
if [ -n "$REF" ]; then
    SRC="$REF"
    EXPECT=$(sha256sum "$SRC" | cut -d' ' -f1)
    ok "reference firmware ${EXPECT:0:16}... (extracted by the caller)"
else
step "Reading the expected firmware from $(basename "$LFW")..."
if [ -n "$DLOCK" ]; then
    # And it has to be the archive this release locked, not merely one with a
    # plausible name.
    LFWSHA=$(sha256sum "$LFW" | cut -d' ' -f1)
    python3 - "$DLOCK" "$(basename "$LFW")" "$LFWSHA" <<'PYLOCK' || exit 1
import json, sys
lock, name, got = sys.argv[1:4]
for o in json.load(open(lock)).get("objects", []):
    if o["path"].split("/")[-1] == name:
        if o["sha256"] != got:
            sys.exit("%s does not match the downloads lock\n  lock  %s\n  file  %s"
                     % (name, o["sha256"], got))
        sys.exit(0)
sys.exit("%s is not in the downloads lock; it is not an input of this release" % name)
PYLOCK
    ok "$(basename "$LFW") matches the downloads lock"
fi

tar -xf "$LFW" -C "$TMP" --wildcards "*/aeonsemi/$FW" 2>/dev/null || true
SRC=$(find "$TMP" -name "$FW" | head -1)
[ -n "$SRC" ] || die "$(basename "$LFW") has no aeonsemi/$FW"
EXPECT=$(sha256sum "$SRC" | cut -d' ' -f1)
ok "expected sha256 ${EXPECT:0:16}..."
fi

# ── 1. No published artifact may carry it in a kernel ──
# Every kernel component of every FIT in the artifact, not just the first. The
# sysupgrade image has one; initramfs-kernel.bin is also a FIT and was being
# collected into the release manifest without ever being checked, which is the
# same blob in the same excluded form under a different file name.
# An sdcard image is a gzipped disk image with the sysupgrade FIT written into a
# partition. Two things that do not work, both tried:
#
#   - cutting the FIT out using the totalsize in its header. OpenWrt builds it
#     with external data, so totalsize covers only the structure -- tens of
#     kilobytes -- and "largest d00dfeed" lands on a device tree instead.
#   - requiring the disk to contain the sysupgrade image verbatim. The disk ends
#     610 bytes before the FIT does, because the image is cut to a block
#     boundary, so a correct pair fails the test.
#
# What does work is slicing from the FIT magic to the end of the disk and letting
# dumpimage read it. The kernel sits near the front, so a short tail costs
# nothing, and this checks the sdcard's own kernel rather than inferring it from
# another artifact.
if [ "$KERNEL_CARRIER" = gz ] || [ "$KERNEL_CARRIER" = raw ]; then
    if [ "$KERNEL_CARRIER" = gz ]; then
        step "Unpacking $(basename "$IMAGE")..."
        gzip -dc "$IMAGE" > "$TMP/disk.img" 2>/dev/null || die "could not decompress $(basename "$IMAGE")"
    else
        step "Scanning $(basename "$IMAGE")..."
        cp "$IMAGE" "$TMP/disk.img"
    fi
    python3 - "$TMP/disk.img" "$TMP" <<'PYFIT' || exit 1
import sys, os
disk, tmp = sys.argv[1:3]
d = open(disk, "rb").read()
i, n = 0, 0
while True:
    i = d.find(b"\xd0\x0d\xfe\xed", i)
    if i < 0:
        break
    open(os.path.join(tmp, "cand-%d.itb" % n), "wb").write(d[i:])
    n += 1
    i += 4
if n == 0:
    sys.exit("no FIT (d00dfeed) found in the disk image")
print("  %d candidate FIT offset(s)" % n)
PYFIT
    SCAN=""
    for cand in "$TMP"/cand-*.itb; do
        # Counted, not grep -q: an early exit SIGPIPEs dumpimage and pipefail
        # then reports a candidate with a kernel as having none.
        kc=$("$di" -l "$cand" 2>/dev/null | grep -c '(kernel' || true)
        [ "${kc:-0}" -gt 0 ] && { SCAN="$cand"; break; }
    done
    [ -n "$SCAN" ] || die "no FIT with a kernel component inside $(basename "$IMAGE")"
    ok "found the kernel-carrying FIT inside the disk image"
else
    SCAN="$IMAGE"
fi

step "Checking $(basename "$IMAGE") for kernels..."
KCOUNT=0
for KIDX in $("$di" -l "$SCAN" 2>/dev/null | sed -n 's/^ Image \([0-9]\+\) (kernel.*/\1/p'); do
    "$di" -T flat_dt -p "$KIDX" -o "$TMP/kernel-$KIDX.bin" "$SCAN" >/dev/null 2>&1 \
        || die "could not extract kernel component $KIDX"
    KCOUNT=$((KCOUNT+1))
done
[ "$KCOUNT" -gt 0 ] || die "no kernel component in $(basename "$IMAGE") (role $ROLE)"

python3 - "$SRC" "$TMP"/kernel-*.bin <<'PYKERNEL' || exit 1
import gzip, lzma, sys
src, kfs = sys.argv[1], sys.argv[2:]
blob = open(src, "rb").read()
for kf in kfs:
    raw = open(kf, "rb").read()
    img = None
    for fn in (gzip.decompress, lzma.decompress,
               lambda b: lzma.decompress(b, format=lzma.FORMAT_XZ)):
        try:
            img = fn(raw); break
        except Exception:
            pass
    if img is None:
        # An uncompressed kernel is still searchable; searching the raw
        # component is the safe fallback, never skipping the check.
        img = raw
        sys.stderr.write("  note: %s is not gzip/xz; searching it raw\n" % kf)
    if blob in img:
        sys.exit("FATAL: the firmware is linked into a kernel image.\n"
                 "  AEONSEMI's licence excludes distribution as part of the Linux kernel.\n"
                 "  Something re-enabled CONFIG_EXTRA_FIRMWARE -- see LICENSING.md section 3.")
    print("  %d bytes decompressed, no firmware" % len(img))
PYKERNEL
ok "$KCOUNT kernel component(s) checked, none carries the firmware"

if [ "$BOARD" = bpi-r4-pro-4e ] && [ "$ROLE" = sysupgrade ]; then
    RIDX=$("$di" -l "$SCAN" 2>/dev/null | sed -n 's/^ Image \([0-9]\+\) (rootfs.*/\1/p' | head -1)
    [ -n "$RIDX" ] || die "no 4E rootfs component"
    "$di" -T flat_dt -p "$RIDX" -o "$TMP/4e-rootfs.sqfs" "$SCAN" >/dev/null 2>&1 \
        || die "could not extract the 4E rootfs"
    # The gate reads only etc/lib. Do not create /dev nodes on the build host.
    unsquashfs -q -d "$TMP/4e-root" "$TMP/4e-rootfs.sqfs" etc lib >/dev/null \
        || die "could not unpack the 4E rootfs"
    sh "$SCRIPT_DIR/check-4e-rootfs.sh" "$TMP/4e-root" || die "4E rootfs policy failed"
fi

if [ "$NEEDS_FW" = no ]; then
    echo
    if [ "$ROLE" != sysupgrade ]; then
        ok "firmware policy holds for $BOARD/$ROLE (no root filesystem in this artifact)"
    else
        ok "firmware policy holds for $BOARD (no AS21xxx PHY on this board)"
    fi
    exit 0
fi

# ── 2. The root filesystem must carry it ──
step "Checking the root filesystem..."
RIDX=$("$di" -l "$SCAN" 2>/dev/null | sed -n 's/^ Image \([0-9]\+\) (rootfs.*/\1/p' | head -1)
[ -n "$RIDX" ] || die "no rootfs component in $(basename "$IMAGE")"
"$di" -T flat_dt -p "$RIDX" -o "$TMP/rootfs.sqfs" "$SCAN" >/dev/null 2>&1 \
    || die "could not extract the rootfs"
command -v unsquashfs >/dev/null || die "unsquashfs is needed to check the rootfs"

unsquashfs -q -d "$TMP/root" -f "$TMP/rootfs.sqfs" "lib/firmware/$FW" >/dev/null 2>&1 || true
GOT="$TMP/root/lib/firmware/$FW"
[ -f "$GOT" ] || die "the rootfs has no /lib/firmware/$FW.
  Without it the PHY has no firmware at all: the built-in copy is gone by design
  and nothing else supplies one. Check that CONFIG_PACKAGE_aeonsemi-as21xxx-firmware
  is still selected."

GOTSHA=$(sha256sum "$GOT" | cut -d' ' -f1)
[ "$GOTSHA" = "$EXPECT" ] || die "the rootfs firmware does not match the locked input.
  expected  $EXPECT
  in image  $GOTSHA
  The image was built against a different linux-firmware than the release names."
ok "/lib/firmware/$FW present and matches the locked input"

# ── 3. The ordered module load that makes it usable ──
# Shipping the firmware where the licence allows is only half of it: without the
# preparation service the PHY is left unbound and the port silently does not work.
#
# Every judgement about that service -- present, parses, loads the deferred module,
# never unbinds the switch, modules shipped, no early autoload, and the behavioral
# scenarios -- lives in check-as21xxx-rootfs.sh, which is frozen and hashed with
# this script. A second copy here is what let two anti-unbind regexes drift apart
# once already, so unpack the rootfs and let the one gate decide.
unsquashfs -q -d "$TMP/root2" -f "$TMP/rootfs.sqfs" \
  "etc/init.d/bpirouter-as21xxx-fw" \
  "etc/uci-defaults/99-bpirouter-as21xxx-fw" \
  "etc/modules.d" \
  "lib/modules/*/as21xxx.ko" \
  "lib/modules/*/mxl862xx_dsa.ko" \
  "lib/modules/*/tag_mxl862xx.ko" \
  "lib/modules/*/tag_mxl862xx_8021q.ko" >/dev/null 2>&1 || true
"$SCRIPT_DIR/check-as21xxx-rootfs.sh" "$TMP/root2" >/dev/null \
    || die "the shipped AS21xxx/MxL boot policy gate failed"
ok "the shipped AS21xxx service, launcher and deferred modules pass the boot policy gate"

echo
ok "firmware policy holds for $BOARD"
