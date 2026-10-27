#!/bin/bash
# Prove that a formal rootfs carries the selected application payload consumed
# by the Task 21 on-device acceptance preflight.  This deliberately does not
# claim to identify every base-files byte in the immutable image.
set -euo pipefail

fail() { echo "FAIL: acceptance provenance rootfs: $*" >&2; exit 1; }
usage() {
    echo "usage: $0 <rootfs> (--ui-proof <json> | --feed-files <dir>)" >&2
    exit 2
}

[ $# -ge 3 ] || usage
ROOT=$1
shift
PROOF=
FEED=
case "$1" in
    --ui-proof) PROOF=${2:-}; shift 2 ;;
    --feed-files) FEED=${2:-}; shift 2 ;;
    *) usage ;;
esac
[ $# -eq 0 ] || usage
[ -d "$ROOT" ] || fail "rootfs is absent: $ROOT"

VERSION=$ROOT/etc/bpirouter-version
MANIFEST=$ROOT/etc/bpirouter-ui-build.manifest
APID=$ROOT/usr/bin/bpirouter-apid
INVENTORY=$ROOT/etc/bpirouter-product-payload.manifest
for file in "$VERSION" "$MANIFEST" "$APID" "$INVENTORY"; do
    [ -f "$file" ] && [ ! -L "$file" ] || fail "missing or symlinked ${file#$ROOT}"
done
[ -x "$APID" ] || fail "/usr/bin/bpirouter-apid is not executable"

one_kv() {
    local key=$1 file=$2
    awk -v key="$key" '$1 == key { if (seen++) exit 2; print $2 }
        END { if (seen != 1) exit 1 }' "$file"
}
one_assignment() {
    local key=$1 file=$2
    awk -F= -v key="$key" '$1 == key { if (seen++) exit 2; sub(/^[^=]*=/, ""); print }
        END { if (seen != 1) exit 1 }' "$file"
}
valid_sha() { [[ $1 =~ ^[0-9a-f]{64}$ ]]; }

verify_payload_inventory() {
    python3 - "$ROOT" "$INVENTORY" <<'PY'
import hashlib, os, re, stat, sys

root, inventory = map(os.path.abspath, sys.argv[1:])
root_real = os.path.realpath(root)
trees = {"/www/bpirouter", "/usr/share/bpirouter"}
allowed_exact = {
    "/etc/bpirouter-version", "/etc/nginx/nginx.conf",
    "/lib/upgrade/keep.d/bpirouter-ui",
}
allowed_prefixes = (
    "/usr/bin/bpirouter-", "/usr/libexec/bpirouter-",
    "/www/bpirouter/", "/usr/share/bpirouter/",
    "/etc/init.d/bpirouter-",
)
boot_exact = {
    "/etc/uci-defaults/99-bpirouter-setup",
}
rows, declared_trees, seen = [], set(), set()
header = 0
with open(inventory, "r", encoding="ascii", newline="") as f:
    for raw in f:
        line = raw.rstrip("\n")
        if not line or "\r" in line:
            raise SystemExit("blank/CR payload inventory line")
        fields = line.split("|")
        if fields == ["BPIR-PAYLOAD", "1"]:
            header += 1
            continue
        if len(fields) == 2 and fields[0] == "T":
            if fields[1] not in trees or fields[1] in declared_trees:
                raise SystemExit("invalid/duplicate exact-tree declaration")
            declared_trees.add(fields[1])
            continue
        if len(fields) != 5 or fields[0] not in ("F", "B"):
            raise SystemExit("malformed payload inventory row")
        kind, mode, size, digest, path = fields
        if not re.fullmatch(r"[0-7]{3,4}", mode) or not size.isdigit() or \
           not re.fullmatch(r"[0-9a-f]{64}", digest):
            raise SystemExit("malformed payload metadata")
        if not path.startswith("/") or "|" in path or any(ch.isspace() for ch in path) or \
           any(p in ("", ".", "..") for p in path.split("/")[1:]):
            raise SystemExit("unsafe payload path")
        if kind == "B":
            if path not in boot_exact:
                raise SystemExit("boot-time payload path is outside the frozen boundary")
        elif path not in allowed_exact and not path.startswith(allowed_prefixes):
            raise SystemExit("payload path is outside the selected product boundary")
        # Acceptance tools are delivered beside the image, never inside it.
        if path.startswith("/usr/share/bpirouter/acceptance/"):
            raise SystemExit("payload inventory carries formal acceptance tools")
        if path in seen:
            raise SystemExit("duplicate payload path")
        seen.add(path)
        rows.append((kind, int(mode, 8), int(size), digest, path))
if header != 1 or declared_trees != trees or not rows:
    raise SystemExit("incomplete payload inventory header/tree set")
required_tools = {
    "/etc/init.d/bpirouter-ota-restore",
    "/usr/libexec/bpirouter-ota-restore",
}
if not required_tools.issubset({path for kind, _, _, _, path in rows if kind == "F"}):
    raise SystemExit("OTA restore payload is incomplete")
if {path for kind, _, _, _, path in rows if kind == "B"} != boot_exact:
    raise SystemExit("boot-time payload set is incomplete")

for kind, want_mode, want_size, want_digest, path in rows:
    candidate = os.path.join(root, path.lstrip("/"))
    real = os.path.realpath(candidate)
    if os.path.commonpath((root_real, real)) != root_real:
        raise SystemExit("payload path escapes rootfs")
    st = os.lstat(candidate)
    if not stat.S_ISREG(st.st_mode) or stat.S_ISLNK(st.st_mode):
        raise SystemExit("payload is absent, special, or symlinked")
    if stat.S_IMODE(st.st_mode) != want_mode or st.st_size != want_size:
        raise SystemExit("payload mode/size differs")
    h = hashlib.sha256()
    with open(candidate, "rb") as f:
        for chunk in iter(lambda: f.read(65536), b""):
            h.update(chunk)
    if h.hexdigest() != want_digest:
        raise SystemExit("payload hash differs")

for tree in trees:
    base = os.path.join(root, tree.lstrip("/"))
    if not os.path.isdir(base) or os.path.islink(base):
        raise SystemExit("owned payload tree is absent or symlinked")
    actual = set()
    for directory, dirnames, filenames in os.walk(base, followlinks=False):
        for name in dirnames:
            if os.path.islink(os.path.join(directory, name)):
                raise SystemExit("owned payload tree contains a symlink")
        for name in filenames:
            item = os.path.join(directory, name)
            if not os.path.isfile(item) or os.path.islink(item):
                raise SystemExit("owned payload tree contains a special/symlink file")
            actual.add("/" + os.path.relpath(item, root).replace(os.sep, "/"))
    expected = {path for kind, _, _, _, path in rows if kind == "F" and path.startswith(tree + "/")}
    if actual != expected:
        raise SystemExit("owned payload tree file set differs")
PY
}

root_src=$(one_kv src "$MANIFEST") || fail "UI manifest has no unique src"
root_art=$(one_kv art "$MANIFEST") || fail "UI manifest has no unique art"
root_inventory=$(one_kv inventory "$MANIFEST") || fail "UI manifest has no unique inventory"
version_src=$(one_assignment BPIROUTER_SRC_HASH "$VERSION") || fail "version sidecar has no unique source hash"
root_apid=$(sha256sum "$APID" | awk '{print $1}')
inventory_sha=$(sha256sum "$INVENTORY" | awk '{print $1}')
valid_sha "$root_src" && valid_sha "$root_art" && valid_sha "$root_inventory" && valid_sha "$root_apid" \
    || fail "rootfs sidecar contains a malformed SHA-256"
[ "$version_src" = "$root_src" ] || fail "version and UI manifest source identities differ"
[ "$root_inventory" = "$inventory_sha" ] || fail "UI manifest does not bind the installed payload inventory"

if [ -n "$PROOF" ]; then
    [ -f "$PROOF" ] || fail "UI proof is absent: $PROOF"
    expected_src=$(jq -er '.source_sha256 | select(type == "string")' "$PROOF") \
        || fail "UI proof has no source_sha256"
    expected_art=$(jq -er '.manifest_artifact_sha256 | select(type == "string")' "$PROOF") \
        || fail "UI proof has no manifest_artifact_sha256"
    expected_inventory=$(jq -er '.payload_inventory_sha256 | select(type == "string")' "$PROOF") \
        || fail "UI proof has no payload_inventory_sha256"
    expected_apid=$(jq -er '.apid_sha256 | select(type == "string")' "$PROOF") \
        || fail "UI proof has no apid_sha256"
else
    [ -d "$FEED" ] || fail "UI feed payload is absent: $FEED"
    [ -f "$FEED/.manifest" ] && [ ! -L "$FEED/.manifest" ] && \
        [ -f "$FEED/.payload-inventory" ] && [ ! -L "$FEED/.payload-inventory" ] && \
        [ -f "$FEED/bpirouter-apid" ] && [ ! -L "$FEED/bpirouter-apid" ] \
        || fail "UI feed has no manifest/payload inventory/apid"
    expected_src=$(one_kv src "$FEED/.manifest") || fail "feed manifest has no unique src"
    expected_art=$(one_kv art "$FEED/.manifest") || fail "feed manifest has no unique art"
    expected_inventory=$(one_kv inventory "$FEED/.manifest") || fail "feed manifest has no unique inventory"
    [ "$expected_inventory" = "$(sha256sum "$FEED/.payload-inventory" | awk '{print $1}')" ] \
        || fail "feed manifest does not bind its payload inventory"
    expected_apid=$(sha256sum "$FEED/bpirouter-apid" | awk '{print $1}')
fi
valid_sha "$expected_src" && valid_sha "$expected_art" && valid_sha "$expected_inventory" && valid_sha "$expected_apid" \
    || fail "expected UI proof contains a malformed SHA-256"
[ "$root_src" = "$expected_src" ] || fail "installed UI source identity differs from build proof"
[ "$root_art" = "$expected_art" ] || fail "installed UI artifact identity differs from build proof"
[ "$inventory_sha" = "$expected_inventory" ] || fail "installed product payload inventory differs from build proof"
[ "$root_apid" = "$expected_apid" ] || fail "installed apid bytes differ from build proof"
verify_payload_inventory || fail "installed selected product payload does not match its inventory"

echo "PASS: acceptance provenance rootfs carries the exact selected UI/application payload"
