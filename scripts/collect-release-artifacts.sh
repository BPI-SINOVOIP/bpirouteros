#!/bin/bash
# collect-release-artifacts.sh — put one board's deliverables where a release
# can prove where they came from.
#
# Usage: collect-release-artifacts.sh --release vX.Y.Z --input-lock <f>
#                                     --downloads-lock <f> --board <board>
#                                     [--ui-artifact <apk>] [--output-root <dir>]
#
# Run after that board's build. Artifacts land in
#
#     <output-root>/<release>/<input-lock-sha256 first 12>/
#
# and the first call writes BUILD-INPUTS.json naming every input the release is
# built from. Later calls must agree with it or they are refused.
#
# Why a directory per lock, rather than one output/ directory reused forever:
# the previous arrangement had no relationship to any release at all. Artifacts
# from different builds sat side by side and the manifest described them all as
# the current release -- an initramfs image four days old, built before a
# licence fix, was described as part of a release that had fixed it.
#
# An mtime comparison was tried first and is not provenance. It stops a file
# older than the lock and proves nothing about the ones that pass: a build from
# a previous lock that finished later goes through, and `touch` defeats it
# entirely. Provenance has to be recorded when the artifact is produced.
#
# Every file is classified here, at collection, because this is where the build
# that produced it is still known. A file that matches nothing is refused: a new
# artifact type appearing in a release is exactly when nobody is looking at it.
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$(dirname "$SCRIPT_DIR")"
[ -n "${BPIR_BUILD_DIR:-}" ] && BUILD_DIR="$BPIR_BUILD_DIR"
WORK_DIR="${BPIR_WORK_DIR:-$BUILD_DIR/openwrt}"

C='\033[0;36m'; G='\033[0;32m'; Y='\033[0;33m'; R='\033[0;31m'; N='\033[0m'
step() { echo -e "${C}▸ $1${N}"; }
ok()   { echo -e "${G}✓ $1${N}"; }
warn() { echo -e "${Y}! $1${N}"; }
die()  { echo -e "${R}✗ $1${N}" >&2; exit 1; }

RELEASE=""; ILOCK=""; DLOCK=""; BOARD=""; UIAPK=""; ROOT="$BUILD_DIR/dist"
while [ $# -gt 0 ]; do
    case "$1" in
        --release)        RELEASE="$2"; shift 2 ;;
        --input-lock)     ILOCK="$2"; shift 2 ;;
        --downloads-lock) DLOCK="$2"; shift 2 ;;
        --board)          BOARD="$2"; shift 2 ;;
        --ui-artifact)    UIAPK="$2"; shift 2 ;;
        --output-root)    ROOT="$2"; shift 2 ;;
        *) die "unknown argument: $1" ;;
    esac
done
[ -n "$RELEASE" ] && [ -n "$ILOCK" ] && [ -n "$DLOCK" ] && [ -n "$BOARD" ] || die \
"usage: collect-release-artifacts.sh --release vX.Y.Z --input-lock <f>
                                    --downloads-lock <f> --board <board>
                                    [--ui-artifact <apk>] [--output-root <dir>]"
[ -f "$ILOCK" ] || die "no such input lock: $ILOCK"
[ -f "$DLOCK" ] || die "no such downloads lock: $DLOCK"

# Collection is a formal release operation. Authenticate the checkout that
# contains this script before it can define board names, classification or
# write a release directory. A redirected BPIR_BUILD_DIR may not authenticate
# a different checkout on this script's behalf.
source "$SCRIPT_DIR/lib/release-gate.sh"
bpir_require_release_workspace "$SCRIPT_DIR" "$BUILD_DIR" "$ILOCK" \
    || die "executing collector checkout does not match the input lock"

source "$SCRIPT_DIR/boards.sh"
bpir_select_release_boards "$RELEASE"
board_init "$BOARD"
read -r -a RELEASE_BOARDS <<<"$VALID_BOARDS"
BOUND_DLOCK_SHA=$("$SCRIPT_DIR/lib/release-lock-contract.py" validate-binding \
    --input-lock "$ILOCK" --downloads-lock "$DLOCK" --release "$RELEASE" \
    --boards "${RELEASE_BOARDS[@]}") \
    || die "downloads lock is not the one frozen by the input lock"

ILOCK_SHA=$(sha256sum "$ILOCK" | cut -d' ' -f1)
DLOCK_SHA="$BOUND_DLOCK_SHA"
OUT="$ROOT/$RELEASE/${ILOCK_SHA:0:12}"
INPUTS="$OUT/BUILD-INPUTS.json"
FROZEN_INPUT_LOCK="$OUT/RELEASE-INPUTS.lock.json"

LOCK_RELEASE=$(python3 -c "
import json,sys; print(json.load(open(sys.argv[1])).get('release',''))" "$ILOCK")
[ "$LOCK_RELEASE" = "$RELEASE" ] || die "input lock is for '$LOCK_RELEASE', not '$RELEASE'"

UI_SHA=""
[ -n "$UIAPK" ] && { [ -f "$UIAPK" ] || die "no such UI artifact: $UIAPK"; UI_SHA=$(sha256sum "$UIAPK" | cut -d' ' -f1); }

# Collection consumes a build assertion produced at the successful end of
# build-full.sh; it does not create provenance after the fact. The sidecar binds
# this board, profile, prepared tree, input lock and the exact bytes currently in
# bin/targets. A missing/stale/other-lock sidecar is a hard failure before the
# release directory is touched.
SRC="$WORK_DIR/bin/targets/$TARGET"
[ -d "$SRC" ] || die "no build output at $SRC — build this board first"
BASE="openwrt-mediatek-filogic-$PROFILE"
BUILD_PROVENANCE="$SRC/.bpirouter-build-$BOARD.json"
[ -f "$BUILD_PROVENANCE" ] || die \
    "no release-bound provenance for $BOARD — prepare and build with the same input lock"
"$SCRIPT_DIR/release-build-provenance.py" verify \
    --lock "$ILOCK" \
    --release "$RELEASE" \
    --board "$BOARD" \
    --profile "$PROFILE" \
    --target "$TARGET" \
    --base "$BASE" \
    --source-dir "$SRC" \
    --sidecar "$BUILD_PROVENANCE" >/dev/null \
    || die "build output is not bound to this input lock"
if [ -n "$UI_SHA" ]; then
    python3 - "$BUILD_PROVENANCE" "$UI_SHA" <<'PYUI' || exit 1
import json, sys
ui = json.load(open(sys.argv[1])).get("ui", {})
if ui.get("mode") != "artifact" or ui.get("artifact_sha256") != sys.argv[2]:
    sys.exit("--ui-artifact is not the artifact the sidecar says this image used")
PYUI
fi

command -v flock >/dev/null 2>&1 || die "flock is required to serialize release collection"
mkdir -p "$ROOT/$RELEASE"
COLLECTION_LOCK=$(bpir_release_collection_lock_path "$ROOT/$RELEASE" "$ILOCK_SHA") \
    || die "cannot derive the release collection lock path"
exec 9>"$COLLECTION_LOCK"
flock 9

bpir_require_single_release_batch "$ROOT/$RELEASE" "${ILOCK_SHA:0:12}" \
    || die "release $RELEASE is already bound to another input lock"

mkdir -p "$OUT"
# Publish the exact lock bytes beside BUILD-INPUTS. Task 21's board-side
# preflight must not depend on an operator reconstructing or separately copying
# the lock after collection. The collection flock makes this a single-writer
# namespace; atomic replace + directory fsync closes crash boundaries.
if [ -e "$FROZEN_INPUT_LOCK" ]; then
    [ -f "$FROZEN_INPUT_LOCK" ] && [ ! -L "$FROZEN_INPUT_LOCK" ] \
        || die "frozen input lock is not a regular file"
    cmp -s "$ILOCK" "$FROZEN_INPUT_LOCK" \
        || die "frozen input lock bytes differ from the supplied lock"
else
    [ ! -e "$INPUTS" ] || die "BUILD-INPUTS exists without its frozen input lock"
    python3 - "$ILOCK" "$FROZEN_INPUT_LOCK" <<'PYLOCK' || exit 1
import os, pathlib, sys, tempfile
source, target = map(pathlib.Path, sys.argv[1:])
fd, tmp_name = tempfile.mkstemp(prefix="." + target.name + ".", dir=target.parent)
tmp = pathlib.Path(tmp_name)
try:
    os.fchmod(fd, 0o644)
    with os.fdopen(fd, "wb") as out:
        out.write(source.read_bytes())
        out.flush()
        os.fsync(out.fileno())
    os.replace(tmp, target)
except BaseException:
    try:
        tmp.unlink()
    except FileNotFoundError:
        pass
    raise
dirfd = os.open(target.parent, os.O_RDONLY | os.O_DIRECTORY)
try:
    os.fsync(dirfd)
finally:
    os.close(dirfd)
PYLOCK
    chmod 644 "$FROZEN_INPUT_LOCK"
fi
python3 - "$FROZEN_INPUT_LOCK" <<'PYMODE' || exit 1
import os, stat, sys
st = os.lstat(sys.argv[1])
if not stat.S_ISREG(st.st_mode) or st.st_uid != os.getuid() or st.st_mode & 0o022:
    raise SystemExit("frozen input lock owner/type/mode is unsafe")
PYMODE
[ "$(sha256sum "$FROZEN_INPUT_LOCK" | awk '{print $1}')" = "$ILOCK_SHA" ] \
    || die "frozen input lock hash differs from the batch directory identity"
cmp -s "$ILOCK" "$FROZEN_INPUT_LOCK" \
    || die "input lock changed while its frozen batch copy was being published"
if [ -f "$INPUTS" ]; then
    # Later boards must be building from the same inputs as the first. Without
    # this, a lock edited part-way through a six-board run leaves a directory
    # whose name says one thing and whose contents came from two.
    python3 - "$INPUTS" "$ILOCK_SHA" "$DLOCK_SHA" "$BUILD_PROVENANCE" <<'PYCHK' || exit 1
import json, sys
p, il, dl, provenance_path = sys.argv[1:5]
d = json.load(open(p))
provenance = json.load(open(provenance_path))
ui = provenance["ui"]
identity = {"mode": ui["mode"]}
if ui["mode"] == "source":
    identity.update(source_commit=ui["source_commit"], source_sha256=ui["source_sha256"],
                    manifest_artifact_sha256=ui["manifest_artifact_sha256"],
                    payload_sha256=ui["payload_sha256"],
                    payload_inventory_sha256=ui["payload_inventory_sha256"],
                    apid_sha256=ui["apid_sha256"])
elif ui["mode"] == "artifact":
    identity.update(artifact_sha256=ui["artifact_sha256"],
                    source_sha256=ui["source_sha256"],
                    manifest_artifact_sha256=ui["manifest_artifact_sha256"],
                    payload_sha256=ui["payload_sha256"],
                    payload_inventory_sha256=ui["payload_inventory_sha256"],
                    apid_sha256=ui["apid_sha256"])
for key, got in (("input_lock_sha256", il), ("downloads_lock_sha256", dl)):
    if d.get(key) != got:
        sys.exit("%s changed since this directory was started\n  was %s\n  now %s"
                 % (key, d.get(key), got))
if d.get("ui_identity") != identity:
    sys.exit("UI identity changed since this directory was started")
PYCHK
else
    step "Starting $OUT"
    python3 - "$INPUTS" "$RELEASE" "$ILOCK_SHA" "$DLOCK_SHA" "$BUILD_PROVENANCE" <<'PYNEW'
import json, sys
p, rel, il, dl, provenance_path = sys.argv[1:6]
provenance = json.load(open(provenance_path))
ui = provenance["ui"]
identity = {"mode": ui["mode"]}
if ui["mode"] == "source":
    identity.update(source_commit=ui["source_commit"], source_sha256=ui["source_sha256"],
                    manifest_artifact_sha256=ui["manifest_artifact_sha256"],
                    payload_sha256=ui["payload_sha256"],
                    payload_inventory_sha256=ui["payload_inventory_sha256"],
                    apid_sha256=ui["apid_sha256"])
elif ui["mode"] == "artifact":
    identity.update(artifact_sha256=ui["artifact_sha256"],
                    source_sha256=ui["source_sha256"],
                    manifest_artifact_sha256=ui["manifest_artifact_sha256"],
                    payload_sha256=ui["payload_sha256"],
                    payload_inventory_sha256=ui["payload_inventory_sha256"],
                    apid_sha256=ui["apid_sha256"])
json.dump({
    "schema": 1,
    "note": ("Inputs every artifact in this directory was built from. Written when "
             "the directory is created and never edited: the point is that the "
             "artifacts can be tied to one release, which an output directory "
             "reused across builds cannot do."),
    "release": rel,
    "input_lock_sha256": il,
    "downloads_lock_sha256": dl,
    "ui_identity": identity,
    "ui_artifact_sha256": identity.get("artifact_sha256"),
    "boards": {},
}, open(p, "w"), indent=2)
PYNEW
    ok "BUILD-INPUTS.json written (lock ${ILOCK_SHA:0:12})"
fi

# ── Collect exactly the build-time inventory ──
# release-build-provenance.py is the single classifier used by clean, sidecar,
# collector verification and policy inference. The collector does not glob and
# reclassify a fourth time: it copies the frozen sidecar's exact file/role set.
# Collection is one-shot per release directory. Replacing a populated board in
# place creates a window where BUILD-INPUTS and its directory describe different
# bytes. To recollect, start a new release directory from the same lock.
step "Collecting $BOARD from $SRC"
[ ! -e "$OUT/$BOARD" ] || die "$BOARD is already collected in this release directory"
BOARD_TMP=$(mktemp -d "$OUT/.${BOARD}.collect.XXXXXX")
PROVENANCE_TMP=$(mktemp "$OUT/.${BOARD}.provenance.XXXXXX")
INPUTS_TMP=$(mktemp "$OUT/.BUILD-INPUTS.XXXXXX")
cleanup_collection() {
    [ -n "${BOARD_TMP:-}" ] && rm -rf "$BOARD_TMP"
    rm -f "$PROVENANCE_TMP" "$INPUTS_TMP"
}
trap cleanup_collection EXIT

# Freeze the assertion before copying any artifact. If another build replaces
# the source sidecar afterwards, it cannot change what this collection checks.
cp -f "$BUILD_PROVENANCE" "$PROVENANCE_TMP"
COUNT=0
python3 - "$PROVENANCE_TMP" >"$BOARD_TMP/.roles" <<'PYROLES' || exit 1
import json, os, sys
artifacts = json.load(open(sys.argv[1])).get("artifacts", [])
if not artifacts:
    raise SystemExit("build provenance declares no artifacts")
seen = set()
for item in artifacts:
    name, role = item.get("file"), item.get("role")
    if not isinstance(name, str) or os.path.basename(name) != name or any(c in name for c in "\t\r\n"):
        raise SystemExit("unsafe artifact name in build provenance: %r" % name)
    if name in seen:
        raise SystemExit("duplicate artifact in build provenance: %s" % name)
    if role not in {"sysupgrade", "initramfs", "sdcard", "factory", "bootloader", "flashkit", "metadata"}:
        raise SystemExit("unsupported artifact role in build provenance: %r" % role)
    seen.add(name)
    print("%s\t%s" % (role, name))
PYROLES
while IFS=$'\t' read -r role n; do
    [ -n "$n" ] || continue
    cp -f "$SRC/$n" "$BOARD_TMP/$n"
    COUNT=$((COUNT+1))
done <"$BOARD_TMP/.roles"
[ "$COUNT" -gt 0 ] || die "build provenance contains no artifacts"

# The authoritative check is on the copied bytes against the frozen sidecar,
# not on the source directory before cp. It closes the verify/copy race and also
# rejects a file that changed halfway through copying.
"$SCRIPT_DIR/release-build-provenance.py" verify \
    --lock "$ILOCK" --release "$RELEASE" --board "$BOARD" \
    --profile "$PROFILE" --target "$TARGET" --base "$BASE" \
    --source-dir "$BOARD_TMP" --sidecar "$PROVENANCE_TMP" >/dev/null \
    || die "copied artifacts do not match the frozen build provenance"

python3 - "$INPUTS" "$INPUTS_TMP" "$BOARD" "$PROFILE" "$BOARD_TMP" "$PROVENANCE_TMP" <<'PYADD'
import hashlib, json, os, sys
inputs, output, board, profile, d, provenance_path = sys.argv[1:7]
def sha(p):
    h = hashlib.sha256()
    with open(p, "rb") as f:
        for c in iter(lambda: f.read(65536), b""):
            h.update(c)
    return h.hexdigest()
roles = {}
for line in open(os.path.join(d, ".roles")):
    r, n = line.rstrip("\n").split("\t", 1)
    roles[n] = r
data = json.load(open(inputs))
provenance = json.load(open(provenance_path))
ui = provenance["ui"]
ui_identity = {"mode": ui["mode"]}
if ui["mode"] == "source":
    ui_identity.update(source_commit=ui["source_commit"], source_sha256=ui["source_sha256"],
                       manifest_artifact_sha256=ui["manifest_artifact_sha256"],
                       payload_sha256=ui["payload_sha256"],
                       payload_inventory_sha256=ui["payload_inventory_sha256"],
                       apid_sha256=ui["apid_sha256"])
elif ui["mode"] == "artifact":
    ui_identity.update(artifact_sha256=ui["artifact_sha256"],
                       source_sha256=ui["source_sha256"],
                       manifest_artifact_sha256=ui["manifest_artifact_sha256"],
                       payload_sha256=ui["payload_sha256"],
                       payload_inventory_sha256=ui["payload_inventory_sha256"],
                       apid_sha256=ui["apid_sha256"])
if data.get("ui_identity") != ui_identity:
    raise SystemExit("frozen sidecar UI identity changed during collection")
data["boards"][board] = {
    "profile": profile,
    # Keep the complete sidecar, including its authoritative artifact set. The
    # copied artifact declarations below add release-relative paths and roles;
    # they do not replace build-time provenance.
    "build_provenance": provenance,
    "artifacts": [
        {"file": n,
         # Relative to the release directory, so the manifest can find it
         # without knowing how the board directories are laid out.
         "path": "%s/%s" % (board, n),
         "role": roles[n],
         "sha256": sha(os.path.join(d, n)),
         "size": os.path.getsize(os.path.join(d, n))}
        for n in sorted(roles)
    ],
}
json.dump(data, open(output, "w"), indent=2)
print("%d" % len(roles))
PYADD

# The roles are in BUILD-INPUTS.json now. Leaving this behind would make it an
# undeclared file in a directory whose whole point is that every file is
# declared.
rm -f "$BOARD_TMP/.roles"

# The board directory appears in one rename only after its bytes and manifest
# entry are complete. BUILD-INPUTS is then replaced by rename as well.
bpir_require_release_workspace "$SCRIPT_DIR" "$BUILD_DIR" "$ILOCK" \
    || die "release workspace or executing collector checkout drifted during collection"
mv -T "$BOARD_TMP" "$OUT/$BOARD"
BOARD_TMP=""
mv -T "$INPUTS_TMP" "$INPUTS"
INPUTS_TMP=""
rm -f "$PROVENANCE_TMP"
trap - EXIT

ok "$BOARD: $COUNT artifact(s) collected and recorded"
