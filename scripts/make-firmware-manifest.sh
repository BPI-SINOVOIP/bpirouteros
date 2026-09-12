#!/bin/bash
# make-firmware-manifest.sh — describe a release's artifacts, and only those.
#
# Usage: make-firmware-manifest.sh --release vX.Y.Z --build-output <dir>
#                                  --input-lock <f> --downloads-lock <f>
#                                  --linux-firmware <linux-firmware-*.tar.*>
#                                  --output <f> [--ui-artifact <apk>]
#                                  [--allow-partial-development]
#
# Build-output evidence, generated after the images exist. It is deliberately
# separate from DOWNLOADS.lock.json: one says what we consumed, the other what
# we produced, and a single file that did both would let each vouch for the
# other.
#
# ── The contract this enforces ──
#
#  1. BUILD-INPUTS.json holds full SHA-256s. The twelve characters in the
#     directory name locate the directory; they are never evidence.
#  2. Every artifact is declared with board, relative path, role, SHA-256 and
#     size, and the manifest is built from that list -- never by globbing the
#     directory again. Globbing is how the described set drifted away from the
#     checked set before, and an unchecked initramfs went into a manifest.
#  3. Every hash is recomputed here. Undeclared files, declared files that are
#     absent, duplicate paths and hash mismatches are refusals.
#  4. The full input-lock, downloads-lock and UI artifact hashes must equal the
#     ones written when the directory was created.
#  5. A formal manifest contains exactly the board set frozen by the input
#     lock. Partial output is accepted only behind an explicit development
#     flag, and is permanently marked as not release-eligible.
#  6. Formal gate code is loaded only from the clean bpirouter-build checkout
#     named by the input lock; an environment path cannot authenticate another
#     checkout on its behalf.
#
# It reads a per-release output directory rather than a shared output/ folder,
# because a shared folder cannot say which release its contents belong to. That
# was not theoretical: an initramfs four days old, built before a licence fix,
# sat beside current images and would have been published as part of the release
# that fixed it. An mtime comparison was tried and is not provenance -- it stops
# files older than the lock and says nothing about the ones that pass.
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
C='\033[0;36m'; G='\033[0;32m'; Y='\033[0;33m'; R='\033[0;31m'; N='\033[0m'
step() { echo -e "${C}▸ $1${N}"; }
ok()   { echo -e "${G}✓ $1${N}"; }
warn() { echo -e "${Y}! $1${N}"; }
die()  { echo -e "${R}✗ $1${N}" >&2; exit 1; }

RELEASE=""; BOUT=""; ILOCK=""; DLOCK=""; LFW=""; OUT=""; UIAPK=""; PARTIAL=0
while [ $# -gt 0 ]; do
    case "$1" in
        --release)        RELEASE="$2"; shift 2 ;;
        --build-output)   BOUT="$2"; shift 2 ;;
        --input-lock)     ILOCK="$2"; shift 2 ;;
        --downloads-lock) DLOCK="$2"; shift 2 ;;
        --linux-firmware) LFW="$2"; shift 2 ;;
        --output)         OUT="$2"; shift 2 ;;
        --ui-artifact)    UIAPK="$2"; shift 2 ;;
        --allow-partial-development) PARTIAL=1; shift ;;
        *) die "unknown argument: $1" ;;
    esac
done
[ -n "$RELEASE" ] && [ -n "$BOUT" ] && [ -n "$ILOCK" ] && [ -n "$DLOCK" ] \
    && [ -n "$LFW" ] && [ -n "$OUT" ] || die \
"usage: make-firmware-manifest.sh --release vX.Y.Z --build-output <dir>
                                 --input-lock <f> --downloads-lock <f>
                                 --linux-firmware <linux-firmware-*.tar.*>
                                 --output <f> [--ui-artifact <apk>]
                                 [--allow-partial-development]

--downloads-lock is required: without it any archive with a plausible name can
serve as the firmware reference, and the check then proves an image matches
something rather than matching this release's input."
for f in "$ILOCK" "$DLOCK" "$LFW"; do [ -f "$f" ] || die "no such file: $f"; done
[ -d "$BOUT" ] || die "no build-output directory: $BOUT"
[ -z "$UIAPK" ] || [ -f "$UIAPK" ] || die "no such UI artifact: $UIAPK"

# Refuse noncanonical/test-only authority before snapshots, collection-lock
# files or any prospective output are created. The full gate is repeated below
# around the immutable policy-code snapshot to detect later drift.
source "$SCRIPT_DIR/lib/release-gate.sh"
if [ "$PARTIAL" = 0 ]; then
    bpir_require_release_workspace "$SCRIPT_DIR" "${BPIR_BUILD_DIR:-$SCRIPT_DIR/..}" "$ILOCK" \
        || die "formal manifest input lock is not the canonical release authority"
fi

LIVE_BOUT=$(cd "$BOUT" && pwd -P)
LIVE_INPUTS="$LIVE_BOUT/BUILD-INPUTS.json"
[ -f "$LIVE_INPUTS" ] || die "no BUILD-INPUTS.json in $LIVE_BOUT
  That directory was not produced by collect-release-artifacts.sh, so nothing
  ties its contents to a release."
LIVE_ILOCK=$(cd "$(dirname "$ILOCK")" && pwd -P)/$(basename "$ILOCK")
LIVE_DLOCK=$(cd "$(dirname "$DLOCK")" && pwd -P)/$(basename "$DLOCK")
LIVE_LFW=$(cd "$(dirname "$LFW")" && pwd -P)/$(basename "$LFW")
LIVE_FROZEN_INPUT_LOCK="$LIVE_BOUT/RELEASE-INPUTS.lock.json"
[ -f "$LIVE_FROZEN_INPUT_LOCK" ] && [ ! -L "$LIVE_FROZEN_INPUT_LOCK" ] \
    || die "release collection has no regular frozen RELEASE-INPUTS.lock.json"
python3 - "$LIVE_FROZEN_INPUT_LOCK" <<'PYMODE' || die "release collection frozen input lock has unsafe owner/mode"
import os, stat, sys
st = os.lstat(sys.argv[1])
if not stat.S_ISREG(st.st_mode) or st.st_uid != os.getuid() or st.st_mode & 0o022:
    raise SystemExit(1)
PYMODE
cmp -s "$LIVE_ILOCK" "$LIVE_FROZEN_INPUT_LOCK" \
    || die "release collection frozen input lock differs from --input-lock"
LIVE_UIAPK=""
[ -z "$UIAPK" ] || LIVE_UIAPK=$(cd "$(dirname "$UIAPK")" && pwd -P)/$(basename "$UIAPK")
BUILD_OUTPUT_NAME=$(basename "$LIVE_BOUT")
LFW_NAME=$(basename "$LIVE_LFW")

GATE_TMP=""
GATE_SCRIPT_DIR="$SCRIPT_DIR"
GATE_DIGEST_START=""
EVIDENCE_TMP=""
FWTMP=""
MANIFEST_TMP=""
cleanup_manifest() {
    [ -z "$GATE_TMP" ] || { chmod -R u+w "$GATE_TMP" 2>/dev/null || true; rm -rf "$GATE_TMP"; }
    [ -z "$EVIDENCE_TMP" ] || { chmod -R u+w "$EVIDENCE_TMP" 2>/dev/null || true; rm -rf "$EVIDENCE_TMP"; }
    [ -z "$FWTMP" ] || { chmod -R u+w "$FWTMP" 2>/dev/null || true; rm -rf "$FWTMP"; }
    [ -z "$MANIFEST_TMP" ] || rm -f "$MANIFEST_TMP"
}

trap cleanup_manifest EXIT

# Freeze every byte that will be classified, hashed, inspected by firmware
# policy or copied into the final manifest. The collector lock prevents a
# cooperating collection process from changing BUILD-INPUTS/artifacts while
# the snapshot is made; final live comparisons also catch non-cooperating
# writers before publication.
EVIDENCE_TMP=$(mktemp -d -t bpir-manifest-evidence-XXXXXX)
cp --reflink=auto -p -- "$LIVE_ILOCK" "$EVIDENCE_TMP/input-lock.json"
cp --reflink=auto -p -- "$LIVE_DLOCK" "$EVIDENCE_TMP/downloads-lock.json"
cp --reflink=auto -p -- "$LIVE_LFW" "$EVIDENCE_TMP/linux-firmware.input"
cmp -s "$LIVE_ILOCK" "$EVIDENCE_TMP/input-lock.json" \
    || die "input lock changed while it was being snapshotted"
cmp -s "$LIVE_DLOCK" "$EVIDENCE_TMP/downloads-lock.json" \
    || die "downloads lock changed while it was being snapshotted"
cmp -s "$LIVE_LFW" "$EVIDENCE_TMP/linux-firmware.input" \
    || die "linux-firmware reference changed while it was being snapshotted"
if [ -n "$LIVE_UIAPK" ]; then
    cp --reflink=auto -p -- "$LIVE_UIAPK" "$EVIDENCE_TMP/ui-artifact.apk"
    cmp -s "$LIVE_UIAPK" "$EVIDENCE_TMP/ui-artifact.apk" \
        || die "UI artifact changed while it was being snapshotted"
fi

ILOCK="$EVIDENCE_TMP/input-lock.json"
DLOCK="$EVIDENCE_TMP/downloads-lock.json"
LFW="$EVIDENCE_TMP/linux-firmware.input"
[ -z "$LIVE_UIAPK" ] || UIAPK="$EVIDENCE_TMP/ui-artifact.apk"
ILOCK_SHA=$(sha256sum "$ILOCK" | cut -d' ' -f1)
command -v flock >/dev/null 2>&1 || die "flock is required to serialize release manifest generation"
LIVE_RELEASE_DIR=$(dirname "$LIVE_BOUT")
EXPECTED_BATCH_NAME=${ILOCK_SHA:0:12}
CANONICAL_BATCH=0
if [ "$(basename "$LIVE_BOUT")" = "$EXPECTED_BATCH_NAME" ] \
    && [ "$(basename "$LIVE_RELEASE_DIR")" = "$RELEASE" ]; then
    CANONICAL_BATCH=1
fi
if [ "$PARTIAL" = 0 ] && [ "$CANONICAL_BATCH" != 1 ]; then
    die "formal manifest build-output must be <root>/$RELEASE/$EXPECTED_BATCH_NAME"
fi
COLLECTION_LOCK=$(bpir_release_collection_lock_path "$LIVE_RELEASE_DIR" "$ILOCK_SHA") \
    || die "cannot derive the release collection lock path"
exec 8>"$COLLECTION_LOCK"
flock 8
if [ "$CANONICAL_BATCH" = 1 ]; then
    bpir_require_single_release_batch "$LIVE_RELEASE_DIR" "$EXPECTED_BATCH_NAME" \
        || die "release $RELEASE contains another input-lock batch"
fi
if [ -n "${BPIR_TEST_MANIFEST_COLLECTION_LOCK_READY:-}" ]; then
    : >"$BPIR_TEST_MANIFEST_COLLECTION_LOCK_READY"
    [ -n "${BPIR_TEST_MANIFEST_COLLECTION_LOCK_RELEASE:-}" ] \
        || die "manifest collection-lock test hook has no release event"
    while [ ! -e "$BPIR_TEST_MANIFEST_COLLECTION_LOCK_RELEASE" ]; do sleep 0.05; done
fi

BOUT="$EVIDENCE_TMP/build-output"
mkdir -p "$BOUT"
cp -a --reflink=auto "$LIVE_BOUT/." "$BOUT/"
INPUTS="$BOUT/BUILD-INPUTS.json"
[ -f "$INPUTS" ] || die "collection snapshot has no BUILD-INPUTS.json"
FROZEN_INPUT_LOCK="$BOUT/RELEASE-INPUTS.lock.json"
[ -f "$FROZEN_INPUT_LOCK" ] && [ ! -L "$FROZEN_INPUT_LOCK" ] \
    || die "collection snapshot has no regular frozen input lock"
cmp -s "$ILOCK" "$FROZEN_INPUT_LOCK" \
    || die "collection snapshot frozen input lock differs from --input-lock"
cmp -s "$LIVE_INPUTS" "$INPUTS" \
    || die "BUILD-INPUTS.json changed while the collection was being snapshotted"

# The policy script delegates its R4-Pro behavioral judgement to the rootfs
# gate, which is self-contained for this reason. It runs from the policy's own
# directory, so it must be inside the frozen snapshot below -- otherwise the
# formal path cannot even find it -- and inside the digest, or the semantic
# check could be emptied without changing it.
GATE_FILES=(
    make-firmware-manifest.sh
    boards.sh
    release-build-provenance.py
    check-firmware-policy.sh
    check-as21xxx-rootfs.sh
    check-4e-rootfs.sh
    check-release-lock.sh
    lib/release-lock-contract.py
    lib/check-feed-inputs.py
    lib/release-gate.sh
)
gate_digest() {
    local root="$1" rel
    (
        cd "$root"
        for rel in "${GATE_FILES[@]}"; do
            [ -f "$rel" ] || { echo "missing release-gate file: $rel" >&2; exit 1; }
            sha256sum "$rel"
        done
    ) | sha256sum | cut -d' ' -f1
}

# A formal manifest must not derive its contract from whichever script checkout
# happens to run last. Bind the actual repository containing this script to the
# frozen build commit before sourcing boards.sh, the classifier or policy code.
# BPIR_BUILD_DIR is deliberately unset for this check: a caller may redirect
# build outputs for tests, but cannot redirect which gate implementation is
# being authenticated.
if [ "$PARTIAL" = 0 ]; then
    step "Binding release-gate code to the input lock..."
    if ! bpir_require_release_workspace "$SCRIPT_DIR" "${BPIR_BUILD_DIR:-$SCRIPT_DIR/..}" "$ILOCK"; then
        die "formal manifest gate code or workspace does not match the input lock"
    fi
    GATE_BUILD_DIR="$BPIR_RELEASE_GATE_ROOT"

    # Freeze every repository file that can define the formal contract. The
    # policy script loads boards.sh and the classifier by relative path, so all
    # three must come from the same snapshot. A live checkout edit after the
    # entry check can then neither change the running policy nor be hidden by a
    # lock commit copied into the output.
    GATE_DIGEST_START=$(gate_digest "$SCRIPT_DIR") \
        || die "cannot hash the formal release-gate files"
    bpir_require_release_workspace "$SCRIPT_DIR" "$GATE_BUILD_DIR" "$ILOCK" \
        || die "release-gate checkout changed before it could be frozen"
    GATE_TMP=$(mktemp -d -t bpir-release-gate-XXXXXX)
    GATE_SCRIPT_DIR="$GATE_TMP/scripts"
    mkdir -p "$GATE_SCRIPT_DIR/lib"
    for gate_rel in "${GATE_FILES[@]}"; do
        mkdir -p "$GATE_SCRIPT_DIR/$(dirname "$gate_rel")"
        cp -p -- "$SCRIPT_DIR/$gate_rel" "$GATE_SCRIPT_DIR/$gate_rel"
    done
    [ "$(gate_digest "$GATE_SCRIPT_DIR")" = "$GATE_DIGEST_START" ] \
        || die "release-gate files changed while the read-only snapshot was created"
    chmod -R a-w "$GATE_TMP"

    # Event seam used only to prove the post-entry drift check. It grants no
    # bypass: the process merely waits, then performs the same mandatory check.
    if [ -n "${BPIR_TEST_MANIFEST_GATE_READY:-}" ]; then
        : >"$BPIR_TEST_MANIFEST_GATE_READY"
        [ -n "${BPIR_TEST_MANIFEST_GATE_RELEASE:-}" ] \
            || die "manifest gate test hook has no release event"
        while [ ! -e "$BPIR_TEST_MANIFEST_GATE_RELEASE" ]; do sleep 0.05; done
    fi
    [ "$(gate_digest "$SCRIPT_DIR")" = "$GATE_DIGEST_START" ] \
        || die "release-gate files changed after the initial workspace check"
    bpir_require_release_workspace "$SCRIPT_DIR" "$GATE_BUILD_DIR" "$ILOCK" \
        || die "release-gate workspace changed after the initial check"
    ok "release-gate checkout matches the input lock"
fi

# Only after the formal code identity check may the current checkout define
# supported boards, exact required files and filename-to-role classification.
source "$GATE_SCRIPT_DIR/boards.sh"
bpir_select_release_boards "$RELEASE"
read -r -a RELEASE_BOARDS <<<"$VALID_BOARDS"
"$GATE_SCRIPT_DIR/lib/release-lock-contract.py" validate-binding \
    --input-lock "$ILOCK" --downloads-lock "$DLOCK" --release "$RELEASE" \
    --boards "${RELEASE_BOARDS[@]}" >/dev/null \
    || die "downloads lock is not the one frozen by the input lock"
REQUIRED_FILE_SPEC=""
for required_board in $VALID_BOARDS; do
    board_init "$required_board"
    # A board whose identity is frozen ahead of its implementation has no
    # deliverable set yet. Emit no entry for it rather than an empty one: an
    # empty required-file list accepts any output, including none, as complete.
    # Absence is not permission -- the release lock check below refuses a locked
    # board that arrives here without a contract, which is what a formal release
    # naming all of VALID_BOARDS does until the board is implemented.
    [ "$BOARD_IMPLEMENTED" = yes ] || continue
    required_files=$(printf '%s\n' "$RELEASE_REQUIRED_FILES" | awk '
        NF { printf "%s%s", separator, $0; separator=" " }
        END { print "" }
    ')
    # An implemented board with an empty set is worse than a missing one: the
    # formal check below subtracts it from what is present, and an empty set is
    # always satisfied, so a release containing nothing for this board passes.
    [ -n "$required_files" ] \
        || die "board $required_board is in the release set but declares no required artifacts"
    REQUIRED_FILE_SPEC+="$required_board=$required_files"$'\n'
done

# ── 1. The directory's declared inputs are this release's inputs ──
step "Verifying $BOUT against its declared inputs..."
UI_SHA=""
[ -n "$UIAPK" ] && { [ -f "$UIAPK" ] || die "no such UI artifact: $UIAPK"; UI_SHA=$(sha256sum "$UIAPK" | cut -d' ' -f1); }
python3 - "$INPUTS" "$ILOCK" "$RELEASE" "$(sha256sum "$ILOCK" | cut -d' ' -f1)" \
          "$(sha256sum "$DLOCK" | cut -d' ' -f1)" "$UI_SHA" "$PARTIAL" \
          "$VALID_BOARDS" "$REQUIRED_FILE_SPEC" <<'PYINPUTS' || exit 1
import json, sys
p, lock_path, rel, il, dl, ui, partial, product_boards, file_spec = sys.argv[1:10]
d = json.load(open(p))
lock = json.load(open(lock_path))
if d.get("release") != rel:
    sys.exit("BUILD-INPUTS.json is for release %r, not %r" % (d.get("release"), rel))
# Full hashes, not the twelve characters in the directory name: the short form
# locates the directory, it does not authenticate its contents.
for key, got, what in (("input_lock_sha256", il, "input lock"),
                       ("downloads_lock_sha256", dl, "downloads lock")):
    if d.get(key) != got:
        sys.exit("the %s does not match what this directory was built from\n"
                 "  directory  %s\n  supplied   %s" % (what, d.get(key), got))
if ui and d.get("ui_artifact_sha256") != ui:
    sys.exit("the UI artifact does not match what this directory was built from\n"
             "  directory  %s\n  supplied   %s" % (d.get("ui_artifact_sha256"), ui))
locked_board_list = lock.get("boards", [])
expected = set(locked_board_list)
product = set(product_boards.split())
actual = set(d.get("boards", {}))
if partial != "1" and (expected != product or len(locked_board_list) != len(product)):
    sys.exit("formal release lock must name exactly the supported boards\n"
             "  expected %s\n  locked   %s"
             % (", ".join(sorted(product)), ", ".join(sorted(expected))))
extra = sorted(actual - expected)
missing = sorted(expected - actual)
if extra:
    sys.exit("BUILD-INPUTS.json contains boards outside the release lock: %s" % ", ".join(extra))
if missing and partial != "1":
    sys.exit("formal release is missing locked boards: %s\n"
             "  use --allow-partial-development only for explicitly non-release diagnostics"
             % ", ".join(missing))
if partial != "1":
    required = {}
    for line in file_spec.splitlines():
        board, files = line.split("=", 1)
        required[board] = set(files.split())
    for board in sorted(product):
        # A locked board with no required-file contract is unshippable: its
        # deliverable set is not defined yet, so nothing can establish that the
        # release contains it. Say so instead of raising a KeyError.
        if board not in required:
            sys.exit("formal release board %s has no release file contract yet\n"
                     "  its identity is frozen but its implementation is not "
                     "(RELEASE-v1.5-EXECUTION-PLAN 22-D steps 2-5)" % board)
        artifacts = d.get("boards", {}).get(board, {}).get("artifacts", [])
        present_files = {item.get("file") for item in artifacts if isinstance(item, dict)}
        absent_files = sorted(required[board] - present_files)
        if absent_files:
            sys.exit("formal release board %s is missing required artifacts: %s"
                     % (board, ", ".join(absent_files)))
print("  release %s, input lock %s" % (rel, d["input_lock_sha256"][:12]))
PYINPUTS
ok "declared inputs match"
[ "$PARTIAL" = 0 ] || warn "partial development manifest: NOT release-eligible"

# BUILD-INPUTS.json is mutable release metadata, so it cannot assign its own
# roles. Reclassify every filename and require the outer declaration to equal
# the complete build-time sidecar retained by the collector.
"$GATE_SCRIPT_DIR/release-build-provenance.py" verify-collection --inputs "$INPUTS"
ok "artifact roles and embedded build provenance match"

# ── 2. The directory contains exactly what it declares ──
verify_artifact_directory() {
python3 - "$1" "$2" <<'PYSET'
import hashlib, json, os, sys
inputs, root = sys.argv[1:3]
d = json.load(open(inputs))

def sha(p):
    h = hashlib.sha256()
    with open(p, "rb") as f:
        for c in iter(lambda: f.read(65536), b""):
            h.update(c)
    return h.hexdigest()

declared, dupes = {}, []
for board, info in d.get("boards", {}).items():
    for a in info.get("artifacts", []):
        for k in ("file", "path", "role", "sha256", "size"):
            if k not in a:
                sys.exit("%s/%s is missing %r" % (board, a.get("file"), k))
        if a["path"] in declared:
            dupes.append(a["path"])
        declared[a["path"]] = a
if dupes:
    sys.exit("duplicate paths declared: %s" % ", ".join(sorted(set(dupes))))
if not declared:
    sys.exit("BUILD-INPUTS.json declares no artifacts")

present = set()
for dirpath, _, files in os.walk(root):
    for n in files:
        rel = os.path.relpath(os.path.join(dirpath, n), root)
        if rel not in {"BUILD-INPUTS.json", "RELEASE-INPUTS.lock.json"}:
            present.add(rel)

missing = sorted(set(declared) - present)
extra = sorted(present - set(declared))
if missing:
    sys.exit("declared but not present: %s" % ", ".join(missing))
if extra:
    sys.exit("present but not declared: %s\n"
             "  Everything published has to be declared, or it is published unchecked."
             % ", ".join(extra))

# Recomputed, never trusted. A hash written at collection says nothing about the
# file sitting there now.
for rel, a in sorted(declared.items()):
    p = os.path.join(root, rel)
    got = sha(p)
    if got != a["sha256"]:
        sys.exit("%s changed since it was collected\n  declared %s\n  actual   %s"
                 % (rel, a["sha256"], got))
    if os.path.getsize(p) != a["size"]:
        sys.exit("%s: size does not match its declaration" % rel)
print("  %d artifact(s): all declared, all present, all hashes recomputed" % len(declared))
PYSET
}

step "Checking the artifact list against the frozen directory..."
verify_artifact_directory "$INPUTS" "$BOUT" || die "frozen artifact set does not match BUILD-INPUTS.json"
ok "the directory contains exactly what it declares"

# The v1.5 runtime deliberately has no MBIM adapter. Check the actual frozen
# OpenWrt package manifests, not only Kconfig intent: dependencies can override
# a negative selection, and a formal release must catch that before flashing.
python3 - "$INPUTS" "$BOUT" <<'PYPACKAGES' || die "formal image package policy failed"
import json, pathlib, sys
inputs, root = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
data = json.loads(inputs.read_text())
for board, info in data.get("boards", {}).items():
    manifests = [a for a in info.get("artifacts", [])
                 if a.get("role") == "metadata" and str(a.get("file", "")).endswith(".manifest")]
    if len(manifests) != 1:
        raise SystemExit(f"{board} has {len(manifests)} package manifests, want exactly one")
    path = root / manifests[0]["path"]
    for line in path.read_text(errors="strict").splitlines():
        fields = line.split()
        if fields and fields[0] in {"umbim", "kmod-usb-net-cdc-mbim"}:
            raise SystemExit(f"{board} package manifest contains unsupported {fields[0]}")
print("  package manifests explicitly contain no MBIM runtime packages")
PYPACKAGES
ok "formal package manifests match the QMI/NCM runtime scope"

# ── 3. Firmware policy, per artifact, by its declared role ──
# The reference is extracted once: the archive is 600 MB of xz and the file
# wanted is 261 KB, so doing it per artifact timed a six-board check out.
step "Checking firmware policy..."
FWTMP=$(mktemp -d -t bpir-fwref-XXXXXX)
python3 - "$DLOCK" "$LFW_NAME" "$(sha256sum "$LFW" | cut -d' ' -f1)" <<'PYLOCK' || exit 1
import json, sys
lock, name, got = sys.argv[1:4]
for o in json.load(open(lock)).get("objects", []):
    if o["path"].split("/")[-1] == name:
        if o["sha256"] != got:
            sys.exit("%s does not match the downloads lock" % name)
        sys.exit(0)
sys.exit("%s is not in the downloads lock; it is not an input of this release" % name)
PYLOCK
tar -xf "$LFW" -C "$FWTMP" --wildcards "*/aeonsemi/as21x1x_fw.bin" 2>/dev/null || true
REFFW=$(find "$FWTMP" -name as21x1x_fw.bin | head -1)
[ -n "$REFFW" ] || die "$LFW_NAME has no aeonsemi/as21x1x_fw.bin"

CHECKED=0
while IFS=$'\t' read -r board rel role; do
    [ -n "$rel" ] || continue
    BPIR_BUILD_DIR="${GATE_BUILD_DIR:-${BPIR_BUILD_DIR:-$SCRIPT_DIR/..}}" \
        "$GATE_SCRIPT_DIR/check-firmware-policy.sh" --board "$board" --role "$role" \
        --image "$BOUT/$rel" --reference-firmware "$REFFW" \
        >/dev/null 2>"$FWTMP/err" || {
            sed 's/^/    /' "$FWTMP/err" >&2
            die "$rel (role $role) fails the firmware policy; no manifest written"
        }
    CHECKED=$((CHECKED+1))
done < <(python3 -c "
import json,sys
d=json.load(open(sys.argv[1]))
for b,i in sorted(d['boards'].items()):
    for a in i['artifacts']: print('%s\t%s\t%s' % (b, a['path'], a['role']))" "$INPUTS")
ok "$CHECKED artifact(s) pass the firmware policy"

# Event seam for the evidence TOCTOU regression test. It pauses only after all
# frozen artifacts have passed policy and grants no bypass; publication still
# requires the mandatory live-evidence comparison below.
if [ -n "${BPIR_TEST_MANIFEST_POLICY_READY:-}" ]; then
    : >"$BPIR_TEST_MANIFEST_POLICY_READY"
    [ -n "${BPIR_TEST_MANIFEST_POLICY_RELEASE:-}" ] \
        || die "manifest policy test hook has no release event"
    while [ ! -e "$BPIR_TEST_MANIFEST_POLICY_RELEASE" ]; do sleep 0.05; done
fi

# ── 4. Write the manifest from the verified list ──
OUT_DIR=$(dirname "$OUT")
mkdir -p "$OUT_DIR"
MANIFEST_TMP=$(mktemp "$OUT_DIR/.$(basename "$OUT").XXXXXX")
python3 - "$INPUTS" "$BOUT" "$RELEASE" "$ILOCK" "$LFW" "$MANIFEST_TMP" "$PARTIAL" \
          "$REQUIRED_FILE_SPEC" "$BUILD_OUTPUT_NAME" "$LFW_NAME" <<'PYMAN'
import hashlib, json, os, sys
inputs, root, release, ilock, lfw, out, partial, file_spec, build_output, lfw_name = sys.argv[1:11]
def sha(p):
    h = hashlib.sha256()
    with open(p, "rb") as f:
        for c in iter(lambda: f.read(65536), b""):
            h.update(c)
    return h.hexdigest()
d = json.load(open(inputs))
lock = json.load(open(ilock))
required_artifacts = {}
for line in file_spec.splitlines():
    board, files = line.split("=", 1)
    required_artifacts[board] = sorted(files.split())
images = [
    {"board": board, "profile": info["profile"], "file": a["file"], "path": a["path"],
     "role": a["role"], "sha256": a["sha256"], "size": a["size"]}
    for board, info in sorted(d["boards"].items())
    for a in info["artifacts"]
]
json.dump({
    "schema": 2,
    "release": release,
    "build_output": build_output,
    "input_lock_sha256": d["input_lock_sha256"],
    "downloads_lock_sha256": d["downloads_lock_sha256"],
    "ui_artifact_sha256": d.get("ui_artifact_sha256"),
    # The archive every image was checked against, verified against the
    # downloads lock first, so the check can be repeated against the same
    # reference later.
    "firmware_reference": {"file": lfw_name, "sha256": sha(lfw)},
    "openwrt": lock.get("openwrt", {}),
    "repos": lock.get("repos", {}),
    "images": images,
    "release_eligible": partial != "1",
    "development_partial": partial == "1",
    "required_artifacts": required_artifacts,
    "boards_without_artifacts": sorted(set(lock.get("boards", [])) - set(d["boards"])),
}, open(out, "w"), indent=2)
PYMAN
chmod 0644 "$MANIFEST_TMP"
[ "$(stat -c '%a' "$MANIFEST_TMP")" = 644 ] \
    || die "cannot set manifest publication mode to 0644"

# Do not publish bytes under a locked commit label until both the live checkout
# and frozen evidence are rechecked. The output is still a private temporary
# file here; rename is the single publication point.
cmp -s "$LIVE_ILOCK" "$ILOCK" || die "input lock changed while the manifest was running"
cmp -s "$LIVE_DLOCK" "$DLOCK" || die "downloads lock changed while the manifest was running"
cmp -s "$LIVE_LFW" "$LFW" || die "linux-firmware reference changed while the manifest was running"
if [ -n "$LIVE_UIAPK" ]; then
    cmp -s "$LIVE_UIAPK" "$UIAPK" || die "UI artifact changed while the manifest was running"
fi
cmp -s "$LIVE_INPUTS" "$INPUTS" || die "BUILD-INPUTS.json changed while the manifest was running"
cmp -s "$LIVE_FROZEN_INPUT_LOCK" "$FROZEN_INPUT_LOCK" \
    || die "frozen input lock changed while the manifest was running"
cmp -s "$LIVE_ILOCK" "$LIVE_FROZEN_INPUT_LOCK" \
    || die "live frozen input lock no longer matches --input-lock"
verify_artifact_directory "$INPUTS" "$LIVE_BOUT" \
    || die "collected artifact set changed while the manifest was running"
if [ "$PARTIAL" = 0 ]; then
    [ "$(gate_digest "$SCRIPT_DIR")" = "$GATE_DIGEST_START" ] \
        || die "release-gate files changed while the formal manifest was running"
    [ "$(gate_digest "$GATE_SCRIPT_DIR")" = "$GATE_DIGEST_START" ] \
        || die "frozen release-gate bundle changed while the formal manifest was running"
    bpir_require_release_workspace "$SCRIPT_DIR" "$GATE_BUILD_DIR" "$ILOCK" \
        || die "release-gate workspace changed before manifest publication"
fi
mv -f -- "$MANIFEST_TMP" "$OUT"
MANIFEST_TMP=""
[ "$(stat -c '%a' "$OUT")" = 644 ] || die "published manifest mode is not 0644"

NIMG=$(python3 -c "import json,sys;print(len(json.load(open(sys.argv[1]))['images']))" "$OUT")
ok "wrote $OUT — $NIMG artifact(s), every one checked"
