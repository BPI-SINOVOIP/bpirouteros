#!/usr/bin/env bash
# Verify every supported board publishes the same immutable boot-time slot fact
# from the hook that selects its A/B rootdisk. This is a source/patch contract;
# formal-image and live-DT evidence remain separate six-board release gates.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$SCRIPT_DIR/.." && pwd)

specs=(
  'patches/bpi-r4/uboot/z03-bpirouter-ab-rootdisk.patch|MT7988_BOOT_EMMC|rootdisk-emmc'
  'patches/bpi-r3/uboot/z03-bpirouter-ab-rootdisk.patch|MT7986_BOOT_EMMC|rootdisk-emmc'
  'patches/bpi-r4-lite/uboot/z03-bpirouter-ab-rootdisk.patch|MT7987_BOOT_EMMC|rootdisk-emmc'
  'patches/bpi-r4-pro/uboot/z03-bpirouter-ab-rootdisk.patch|MT7988_BOOT_EMMC|rootdisk-emmc'
  'patches/bpi-r3-mini/uboot/z03-bpirouter-ab-rootdisk.patch|MT7986_BOOT_EMMC|rootdisk-emmc'
  'patches/openwrt-one/uboot/z03-bpirouter-ab-rootdisk.patch|MT7981_BOOT_SPIM_NAND|rootdisk-spim-nand'
)

check_patch() {
  local file=$1
  local boot_case=$2
  local media=$3
  git -C "$ROOT" apply --numstat "$file" >/dev/null || return 1
  python3 - "$file" "$boot_case" "$media" <<'PY'
import pathlib
import re
import sys

path, boot_case, media = sys.argv[1:]
lines = pathlib.Path(path).read_text(encoding="utf-8").splitlines()
# Reconstruct the post-patch C hunk: context and additions are live code;
# deletions and diff metadata are not. This lets the gate check relationships,
# rather than independently finding four strings anywhere in the patch.
code = "\n".join(
    line[1:] for line in lines
    if line and line[0] in " +" and not line.startswith("+++")
)
case_match = re.search(
    rf"case\s+{re.escape(boot_case)}\s*:(?P<body>.*?)\n\s*break\s*;?",
    code,
    re.S,
)
if not case_match:
    raise SystemExit(1)
body = case_match.group("body")
decision = re.search(
    rf'''const\s+char\s+\*booted_slot\s*=\s*"a"\s*;
         .*?if\s*\(slot\s*&&\s*!strcmp\(slot,\s*"b"\)\)\s*\{{
         (?P<b>.*?)\}}\s*else\s*\{{(?P<a>.*?)\}}''',
    body,
    re.S | re.X,
)
if not decision:
    raise SystemExit(1)
b_branch, a_branch = decision.group("b"), decision.group("a")
if not re.search(rf'media\s*=\s*"{re.escape(media)}-b"\s*;', b_branch):
    raise SystemExit(1)
if not re.search(r'booted_slot\s*=\s*"b"\s*;', b_branch):
    raise SystemExit(1)
if not re.search(rf'media\s*=\s*"{re.escape(media)}-a"\s*;', a_branch):
    raise SystemExit(1)
if re.search(r'booted_slot\s*=', a_branch):
    raise SystemExit(1)
publication = re.search(
    r'fdt_setprop_string\s*\(\s*blob\s*,\s*chosen\s*,\s*'
    r'"bpirouter,booted-slot"\s*,\s*booted_slot\s*\)',
    body,
    re.S,
)
if not publication or publication.start() < decision.end():
    raise SystemExit(1)
if code.count('"bpirouter,booted-slot"') != 1:
    raise SystemExit(1)
PY
}

for spec in "${specs[@]}"; do
  IFS='|' read -r relative boot_case media <<<"$spec"
  check_patch "$ROOT/$relative" "$boot_case" "$media" || {
    echo "booted-slot contract failed: $relative" >&2
    exit 1
  }
done

# A single missing publication must make this focused gate fail. This mutation
# catches a future edit that preserves rootdisk selection but silently removes
# the immutable fact consumed by apid.
scratch=$(mktemp -d)
trap 'rm -rf -- "$scratch"' EXIT
mutant=$scratch/z03-mutant.patch
IFS='|' read -r first_patch first_case first_media <<<"${specs[0]}"
cp "$ROOT/$first_patch" "$mutant"
sed -i '/"bpirouter,booted-slot"/d' "$mutant"
if check_patch "$mutant" "$first_case" "$first_media" 2>/dev/null; then
  echo "booted-slot deletion mutation unexpectedly passed" >&2
  exit 1
fi

# Relationship mutations: independent string-presence checks accept both of
# these, but either one makes the published slot disagree with rootdisk.
cp "$ROOT/$first_patch" "$mutant"
sed -i 's/booted_slot = "b";/booted_slot = "a";/' "$mutant"
if check_patch "$mutant" "$first_case" "$first_media" 2>/dev/null; then
  echo "booted-slot constant-value mutation unexpectedly passed" >&2
  exit 1
fi

cp "$ROOT/$first_patch" "$mutant"
sed -i 's/media = "rootdisk-emmc-b";/media = "rootdisk-emmc-a";/' "$mutant"
if check_patch "$mutant" "$first_case" "$first_media" 2>/dev/null; then
  echo "booted-slot/rootdisk relationship mutation unexpectedly passed" >&2
  exit 1
fi

echo "PASS: six-board booted-slot patch contract"
