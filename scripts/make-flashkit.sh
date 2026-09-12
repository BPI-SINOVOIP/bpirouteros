#!/bin/bash
# make-flashkit.sh — collect the bring-up / repair flashing kit for a board into
# the target output dir, after a full build. Gathers the (already-built) UART /
# NAND artifacts from BIN_DIR + the vendored mtk_uartboot + the runbook, and
# writes SHA256SUMS and a release tarball. R3 Mini and OpenWrt One depend on
# this kit for the deepest documented recovery layer, so partial kits fail.
#
# Usage: ./scripts/make-flashkit.sh --board bpi-r3-mini
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$(dirname "$SCRIPT_DIR")"
[ -n "${BPIR_BUILD_DIR:-}" ] && BUILD_DIR="$BPIR_BUILD_DIR"
WORK_DIR="${BPIR_WORK_DIR:-$BUILD_DIR/openwrt}"
KSRC="$BUILD_DIR/flashkit"

C='\033[0;36m'; G='\033[0;32m'; R='\033[0;31m'; N='\033[0m'
step() { echo -e "${C}▸ $1${N}"; }
ok()   { echo -e "${G}✓ $1${N}"; }
fail() { echo -e "${R}✗ $1${N}"; exit 1; }

BOARD="bpi-r3-mini"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --board) BOARD="$2"; shift 2 ;;
        --board=*) BOARD="${1#*=}"; shift ;;
        *) echo "Unknown argument: $1"; shift ;;
    esac
done

source "$SCRIPT_DIR/boards.sh"
board_init "$BOARD"
BIN="$WORK_DIR/bin/targets/$TARGET"
SOC_SHORT="${SOC%[a-z]}"   # mt7986a -> mt7986
OUT="$BIN/flashkit-$BOARD"

[ -d "$BIN" ] || fail "no BIN_DIR ($BIN) — build this board first"

# pick first matching file or empty (never fails the script under set -e)
pick() { { ls $1 2>/dev/null || true; } | head -1; }

# Formal builds clear this exact SoC-wide file before make. Accept only the file
# reinstalled into BIN_DIR by this build; build_dir is an incremental cache and
# cannot prove that a matching BL2 belongs to the current board, lock or run.
RAMBL2="$BIN/${SOC_SHORT}-ram-ddr4-bl2.bin"
[ -f "$RAMBL2" ] || fail "missing current-build ${SOC_SHORT} RAM DDR4 BL2 in BIN_DIR"
# Prefer a dedicated provisioning u-boot fip (ram-bl31-uboot.fip) for the BROM
# payload if the board builds one (openwrt-one: ENV_IS_NOWHERE, auto USB->NAND
# flash); otherwise the snand fip already is the provisioning u-boot (r3-mini).
SNANDFIP=$(pick "$BIN/*${PROFILE}*ram-bl31-uboot.fip")
[ -z "$SNANDFIP" ] && SNANDFIP=$(pick "$BIN/*${PROFILE}*snand-bl31-uboot.fip")
FACTORY=$(pick "$BIN/*${PROFILE}*snand-factory.bin")
[ -n "$SNANDFIP" ] && [ -f "$SNANDFIP" ] || fail "missing provisioning FIP for $BOARD"
[ -n "$FACTORY" ] && [ -f "$FACTORY" ] || fail "missing SNAND factory image for $BOARD"

step "flashkit for $BOARD ($PROFILE, $SOC) -> $OUT"
rm -rf "$OUT"; mkdir -p "$OUT"
copied=0
copy_required() { # src dst
    [ -n "$1" ] && [ -f "$1" ] || fail "missing required flashkit input: $2"
    cp "$1" "$OUT/$2"
    echo "  + $2  ($(basename "$1"))"
    copied=$((copied+1))
}
copy_required "$RAMBL2"   ram-ddr4-bl2.bin
copy_required "$SNANDFIP" snand-uboot.fip
copy_required "$FACTORY"  snand-factory.bin

# CRC32 sidecar (BE 4 bytes) for snand-factory.bin — u-boot's verify_src compares
# this with `crc32`+`cmp.b` BEFORE erasing/writing NAND, so a corrupt image is
# never flashed. Must match the exact kit copy that the operator puts on USB.
# Big-endian: u-boot's `crc32 addr len store` stores via crc32_wd_buf() which does
# htonl() — so the sidecar must be BE or cmp.b sees byte-reversed bytes and fails.
if [ -f "$OUT/snand-factory.bin" ]; then
    crc=$(python3 -c "import zlib,sys,struct;d=open(sys.argv[1],'rb').read();c=zlib.crc32(d)&0xffffffff;open(sys.argv[2],'wb').write(struct.pack('>I',c));print('%08x'%c)" "$OUT/snand-factory.bin" "$OUT/snand-factory.crc")
    echo "  + snand-factory.crc  (crc32=0x$crc, BE)"
fi

# vendored host tool (AGPL-3.0) — the formal recovery kit includes the exact
# tested host tool plus its corresponding source, licence and notice.
# The binary NEVER ships alone: conveying it obliges us to convey the
# corresponding source with it (AGPL-3.0 section 6), so a kit that has the
# binary but not the source tarball and licence text is a compliance failure,
# not a cosmetic omission. Fail loudly rather than assemble one.
for f in bin/mtk_uartboot-linux-x86_64 src/mtk_uartboot-v0.1.1-src.tar.gz \
         src/LICENSE-mtk_uartboot-AGPL-3.0.txt bin/NOTICE-mtk_uartboot.txt; do
    [ -f "$KSRC/$f" ] || fail "formal flashkit input is missing: flashkit/$f"
done
cp "$KSRC/bin/mtk_uartboot-linux-x86_64" "$OUT/mtk_uartboot"; chmod +x "$OUT/mtk_uartboot"
cp "$KSRC/bin/NOTICE-mtk_uartboot.txt" "$OUT/"
cp "$KSRC/src/mtk_uartboot-v0.1.1-src.tar.gz" "$OUT/"
cp "$KSRC/src/LICENSE-mtk_uartboot-AGPL-3.0.txt" "$OUT/"
echo "  + mtk_uartboot (vendored, linux-x86_64) + source + AGPL-3.0 text"

# Published trees carry the exported guides; private builds use their sole
# maintained source in the UI repository. Never ship internal repair records.
GUIDES="$BUILD_DIR"
if [ ! -f "$GUIDES/INSTALLATION.md" ]; then
    GUIDES="$(dirname "$BUILD_DIR")/bpirouter-ui/docs/user"
fi
for guide in FEATURES.md FEATURES.zh-CN.md INSTALLATION.md INSTALLATION.zh-CN.md; do
    [ -f "$GUIDES/$guide" ] || fail "missing user guide: $GUIDES/$guide"
    cp "$GUIDES/$guide" "$OUT/"
done
case "$BOARD" in
    bpi-r3-mini) RUNBOOK=RUNBOOK-r3mini.md ;;
    openwrt-one) RUNBOOK=RUNBOOK-openwrt-one.md ;;
    *) fail "no formal flashkit contract for $BOARD" ;;
esac
printf '# %s installation\n\nRead [Installation](INSTALLATION.md), section 3, for this board.\n\n[Chinese](INSTALLATION.zh-CN.md)\n' \
    "$BOARD" > "$OUT/$RUNBOOK"
echo "  + user guides and $RUNBOOK"

( cd "$OUT" && sha256sum * > SHA256SUMS )
[ "$copied" -eq 3 ] || fail "flashkit did not contain all three provisioning artifacts"

TARBALL="$BIN/openwrt-mediatek-filogic-$PROFILE-flashkit.tar.gz"
TARBALL_TMP=$(mktemp "$BIN/.flashkit-${BOARD}.XXXXXX.tar.gz")
trap 'rm -f "$TARBALL_TMP"' EXIT
tar --sort=name --mtime='@0' --owner=0 --group=0 --numeric-owner \
    -C "$BIN" -cf - "flashkit-$BOARD" | gzip -n >"$TARBALL_TMP"
mv "$TARBALL_TMP" "$TARBALL"
trap - EXIT
# OpenWrt wrote its checksums before this final recovery archive existed.
python3 - "$TARBALL" <<'PY'
import hashlib
from pathlib import Path
import sys

archive = Path(sys.argv[1])
sums = archive.parent / 'sha256sums'
lines = sums.read_text().splitlines(keepends=True) if sums.exists() else []
matches = [i for i, line in enumerate(lines)
           if line[64:66] in (' *', '  ') and line[66:].rstrip('\n') == archive.name]
if len(matches) > 1:
    raise ValueError(f'duplicate checksum entries for {archive.name}')
digest = hashlib.sha256()
with archive.open('rb') as stream:
    for chunk in iter(lambda: stream.read(1024 * 1024), b''):
        digest.update(chunk)
if matches:
    i = matches[0]
    lines[i] = digest.hexdigest() + lines[i][64:]
else:
    if lines and not lines[-1].endswith('\n'):
        lines[-1] += '\n'
    lines.append(f'{digest.hexdigest()} *{archive.name}\n')
sums.write_text(''.join(lines))
PY
ok "formal flashkit ready ($copied provisioning artifacts): $TARBALL"
