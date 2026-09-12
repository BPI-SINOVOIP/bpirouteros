#!/bin/bash
# Copyright (C) 2026 Ning <mimallaus@gmail.com>
# make-release-lock.sh — freeze every input a release is built from.
#
# Generated BEFORE any release image is built, and consumed by everything
# downstream: rebuild-all.sh builds against it, make-public-tree.sh publishes
# it, stage-proprietary-ui.sh takes the expected UI artifact hash from it.
#
# The point is that "which inputs produced this release?" is answered by a file
# written in advance, not reconstructed afterwards from whatever the working
# tree happens to look like. Reconstructing after the fact is how a release ends
# up described by inputs it was not built from -- the provenance rows already
# caught one instance of that, where three boards recorded no package hash at
# all because the lookup used the wrong architecture.
#
# Full revisions, not abbreviated ones: a short hash is fine for a human reading
# a log and is not an identifier you can verify against months later.
#
# Usage: make-release-lock.sh --release vX.Y.Z --downloads-lock <file>
#                             --output <file> [--ui-artifact <apk>]...
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$(dirname "$SCRIPT_DIR")"
WORK_DIR="$BUILD_DIR/openwrt"
UI_DIR="$(dirname "$BUILD_DIR")/bpirouter-ui"
FEEDS_DIR="$(dirname "$BUILD_DIR")/bpirouter-feeds"

C='\033[0;36m'; G='\033[0;32m'; Y='\033[0;33m'; R='\033[0;31m'; N='\033[0m'
step() { echo -e "${C}▸ $1${N}"; }
ok()   { echo -e "${G}✓ $1${N}"; }
warn() { echo -e "${Y}! $1${N}"; }
die()  { echo -e "${R}✗ $1${N}" >&2; exit 1; }

RELEASE=""; OUT=""; DLOCK=""; TEST_OUTPUT=0; ARTIFACTS=()
BLOBTMP=""; OUT_TMP=""
cleanup() {
    [ -z "$OUT_TMP" ] || rm -f -- "$OUT_TMP"
    [ -z "$BLOBTMP" ] || rm -rf -- "$BLOBTMP"
}
trap cleanup EXIT
while [ $# -gt 0 ]; do
    case "$1" in
        --release)      RELEASE="$2"; shift 2 ;;
        --downloads-lock) DLOCK="$2"; shift 2 ;;
        --output)       OUT="$2"; shift 2 ;;
        --ui-artifact)  ARTIFACTS+=("$2"); shift 2 ;;
        --test-output)  TEST_OUTPUT=1; shift ;;
        *) die "unknown argument: $1" ;;
    esac
done
[ -n "$RELEASE" ] || die "usage: make-release-lock.sh --release vX.Y.Z --downloads-lock <file> --output <file> [--ui-artifact <apk>]..."
[ -n "$OUT" ]     || die "--output is required"
[ -n "$DLOCK" ]   || die "--downloads-lock is required"
[ -f "$DLOCK" ] && [ ! -L "$DLOCK" ] || die "downloads lock must be a regular, non-symlink file"

source "$SCRIPT_DIR/boards.sh"
bpir_select_release_boards "$RELEASE"
read -r -a RELEASE_BOARDS <<<"$VALID_BOARDS"
"$SCRIPT_DIR/lib/release-lock-contract.py" release-version \
    --release "$RELEASE" --format apk >/dev/null \
    || die "invalid release ID (expected a stable or rcN version)"
if [ "$TEST_OUTPUT" = 1 ]; then
    [ "${BPIR_RELEASE_LOCK_TEST_ONLY:-0}" = 1 ] \
        || die "--test-output is reserved for test harnesses"
else
    CANONICAL_OUT="$BUILD_DIR/dist/RELEASE-INPUTS.$RELEASE.lock.json"
    [ "$(realpath -m -- "$OUT")" = "$(realpath -m -- "$CANONICAL_OUT")" ] \
        || die "formal release lock output must be $CANONICAL_OUT"
fi
TEST_ONLY_JSON=false
[ "$TEST_OUTPUT" = 1 ] && TEST_ONLY_JSON=true
[ ! -e "$OUT" ] || die "output already exists; release IDs are immutable, create a new RC"
DOWNLOADS_LOCK_SHA256=$("$SCRIPT_DIR/lib/release-lock-contract.py" validate-downloads \
    --downloads-lock "$DLOCK" --release "$RELEASE" --boards "${RELEASE_BOARDS[@]}") \
    || die "downloads lock does not satisfy the release contract"

# ── Refuse to freeze a state that cannot be returned to ──
# A lock naming a dirty tree describes something no one can check out again.
for r in "$BUILD_DIR" "$UI_DIR" "$FEEDS_DIR"; do
    [ -d "$r/.git" ] || die "$r is not a git repository"
    [ -z "$(git -C "$r" status --porcelain)" ] || \
        die "$(basename "$r") has uncommitted changes — commit before freezing a lock"
done
[ -d "$WORK_DIR/.git" ] || die "no OpenWrt checkout at $WORK_DIR — run prepare.sh first"

step "Freezing inputs for $RELEASE"

sha() { sha256sum "$1" | cut -d' ' -f1; }
jstr() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

# ── Bodies ──
PATCH_JSON=$(cd "$BUILD_DIR" && find patches -name '*.patch' | LC_ALL=C sort | while read -r p; do
    printf '    {"path": "%s", "sha256": "%s"},\n' "$p" "$(sha256sum "$p" | cut -d' ' -f1)"
done | sed '$ s/,$//')

# Non-source inputs are listed separately, not as patches. A firmware blob is
# not a patch and must not be published as though its licence were settled.
#
# The redistribution status comes from config/blob-licences.json, which records
# who granted permission and what the evidence is. It used to be hardcoded to
# "unconfirmed" here while a --allow-unlicensed-blobs flag let a caller override
# it at publish time -- a claim nobody had checked, about something that cannot
# be unpublished. A blob with no entry is unconfirmed; saying nothing is not
# permission.
#
# UNBUILDABLE collects the boards whose blobs are not cleared, so the lock says
# which boards a public tree can actually build instead of leaving a customer to
# discover it partway through.
LICENCES="$BUILD_DIR/config/blob-licences.json"
BLOBTMP=$(mktemp -d)
# Written to files rather than returned through the shell: `read a b` splits on
# whitespace, and JSON is full of it, so a value round-tripping through word
# splitting comes back truncated.
python3 - "$BUILD_DIR" "$LICENCES" "$BLOBTMP" <<'PYEOF'
import json,sys,os,hashlib,glob
base,lic,out = sys.argv[1], sys.argv[2], sys.argv[3]
known = {}
if os.path.exists(lic):
    for b in json.load(open(lic)).get("blobs", []):
        known[b["path"]] = b
def sha(p):
    h=hashlib.sha256()
    with open(p,"rb") as f:
        for c in iter(lambda: f.read(65536), b""): h.update(c)
    return h.hexdigest()
# "confirmed" has to mean something a person can check afterwards. The file's
# own header says the status requires source, granted_by, evidence and date --
# and nothing enforced it, so setting the word alone was enough to publish a
# blob. Demotion rather than a hard error: an incomplete entry is not a broken
# lock, it is an unconfirmed blob, which is exactly what the rest of the
# pipeline already knows how to handle. The reason is reported so the demotion
# is not silent.
REQUIRED = ("source", "granted_by", "evidence", "date")
entries, blocked, demoted = [], set(), []
for p in sorted(glob.glob(os.path.join(base,"patches","*","firmware","*"))):
    rel = os.path.relpath(p, base)
    e = known.get(rel, {})
    digest = sha(p)
    status = e.get("status","unconfirmed")
    if status == "confirmed":
        missing = [k for k in REQUIRED if not e.get(k)]
        if e.get("sha256") != digest:
            # A recorded hash that no longer matches means the file changed
            # after permission was granted; the permission was for the old one.
            status = "unconfirmed"
            demoted.append(f"{rel}: recorded sha256 does not match the file on disk")
        elif missing:
            status = "unconfirmed"
            demoted.append(f"{rel}: marked confirmed without " + ", ".join(missing))
    entries.append({"path": rel, "sha256": digest, "redistribution": status,
                    "granted_by": e.get("granted_by"), "evidence": e.get("evidence")})
    if status != "confirmed":
        blocked.update(e.get("boards") or [rel.split("/")[1]])
open(os.path.join(out,"blobs"),"w").write(",\n".join("    "+json.dumps(e) for e in entries))
open(os.path.join(out,"blocked"),"w").write(",\n".join("    "+json.dumps(b) for b in sorted(blocked)))
open(os.path.join(out,"demoted"),"w").write("\n".join(demoted))
PYEOF
BLOB_JSON=$(cat "$BLOBTMP/blobs")
UNBUILDABLE=$(cat "$BLOBTMP/blocked")
if [ -s "$BLOBTMP/demoted" ]; then
    warn "blobs demoted to unconfirmed:"
    sed 's/^/    /' "$BLOBTMP/demoted"
fi

# Every file in config/, not just *.config. blob-licences.json decides which
# firmware may be published and was the one file in there that no hash covered,
# so it could be edited between freezing a lock and publishing from it without
# the verifier noticing. Globbing the directory rather than an extension also
# means a file added later is covered without anyone remembering to add it.
CONFIG_JSON=$(cd "$BUILD_DIR" && find config -maxdepth 1 -type f | LC_ALL=C sort | while read -r c; do
    printf '    {"path": "%s", "sha256": "%s"},\n' "$c" "$(sha256sum "$c" | cut -d' ' -f1)"
done | sed '$ s/,$//')

FEED_JSON=$(grep '^src-git' "$BUILD_DIR/feeds.conf" | while read -r _ name spec; do
    printf '    {"name": "%s", "url": "%s", "commit": "%s"},\n' \
        "$name" "${spec%%^*}" "${spec##*^}"
done | sed '$ s/,$//')

# ── UI artifacts ──
# Recorded per package architecture. stage-proprietary-ui.sh trusts only these
# entries: a hash passed on a command line is no evidence, since whoever
# supplies a substituted artifact supplies the hash with it.
PKGARCH=$(pkg_arch)
UI_JSON=""
if [ ${#ARTIFACTS[@]} -gt 0 ]; then
    # The architecture is read out of the package, not assumed from the tree.
    # It used to be recorded as whatever pkg_arch() said, which describes the
    # checkout rather than the file: an artifact built for another target got
    # filed under the right-looking arch, and from then on its hash matched
    # every time, because the hash was taken from the same wrong file.
    #
    # Name and version are recorded for the same reason -- so the lock says
    # which package this is, rather than only how long it is.
    HOSTAPK="$WORK_DIR/staging_dir/host/bin/apk"
    [ -x "$HOSTAPK" ] || die "no host apk at $HOSTAPK, so --ui-artifact cannot be verified.
  Build it once with: (cd openwrt && make package/system/apk/host/compile)
  Recording an artifact without reading it is what this check exists to stop."
    for a in "${ARTIFACTS[@]}"; do
        [ -f "$a" ] || die "no such UI artifact: $a"
        META=$("$HOSTAPK" adbdump "$a" 2>/dev/null) \
            || die "cannot read $a as an apk v3 package"
        A_NAME=$(printf '%s\n' "$META" | sed -n 's/^  name: //p' | head -1)
        A_VER=$(printf '%s\n' "$META" | sed -n 's/^  version: //p' | head -1)
        A_ARCH=$(printf '%s\n' "$META" | sed -n 's/^  arch: //p' | head -1)
        [ -n "$A_NAME" ] && [ -n "$A_VER" ] && [ -n "$A_ARCH" ] \
            || die "$a declares no name/version/arch — not a package this release can use"
        [ "$A_ARCH" = "$PKGARCH" ] \
            || die "$(basename "$a") is built for $A_ARCH, but this tree packages for $PKGARCH"
        "$SCRIPT_DIR/lib/release-lock-contract.py" validate-apk \
            --release "$RELEASE" --name "$A_NAME" --version "$A_VER" >/dev/null \
            || die "$(basename "$a") package metadata does not match $RELEASE"
        base=$(basename "$a")
        UI_JSON+=$(printf '    {"arch": "%s", "name": "%s", "version": "%s", "file": "%s", "sha256": "%s"},\n' \
            "$(jstr "$A_ARCH")" "$(jstr "$A_NAME")" "$(jstr "$A_VER")" "$base" "$(sha "$a")")
        ok "artifact $base: $A_NAME $A_VER ($A_ARCH)"
    done
    UI_JSON=$(printf '%s' "$UI_JSON" | sed '$ s/,$//')
else
    warn "no --ui-artifact given: artifact mode will be unavailable for this release"
fi

BOARDS_JSON=$(for b in $VALID_BOARDS; do printf '    "%s",\n' "$b"; done | sed '$ s/,$//')

# ── Write, validate, then atomically publish without replacement ──
OUT_DIR=$(dirname -- "$OUT")
OUT_BASE=$(basename -- "$OUT")
mkdir -p "$OUT_DIR"
OUT_TMP=$(mktemp "$OUT_DIR/.$OUT_BASE.tmp.XXXXXX")
chmod 0644 "$OUT_TMP"
cat > "$OUT_TMP" <<EOF
{
  "schema": 1,
  "release": "$(jstr "$RELEASE")",
  "test_only": $TEST_ONLY_JSON,
  "generated_at": "$(date -Iseconds)",
  "downloads_lock_sha256": "$DOWNLOADS_LOCK_SHA256",
  "boards": [
$BOARDS_JSON
  ],
  "openwrt": {
    "url": "$(git -C "$WORK_DIR" config --get remote.origin.url)",
    "tag": "$(git -C "$WORK_DIR" describe --tags 2>/dev/null || echo unknown)",
    "commit": "$(git -C "$WORK_DIR" rev-parse HEAD)"
  },
  "feeds": [
$FEED_JSON
  ],
  "repos": {
    "bpirouter-build": "$(git -C "$BUILD_DIR" rev-parse HEAD)",
    "bpirouter-ui": "$(git -C "$UI_DIR" rev-parse HEAD)",
    "bpirouter-feeds": "$(git -C "$FEEDS_DIR" rev-parse HEAD)"
  },
  "pkg_arch": "$PKGARCH",
  "ui_artifacts": [
$UI_JSON
  ],
  "patches": [
$PATCH_JSON
  ],
  "non_source_inputs": [
$BLOB_JSON
  ],
  "boards_unbuildable_publicly": [
$UNBUILDABLE
  ],
  "configs": [
$CONFIG_JSON
  ]
}
EOF

python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$OUT_TMP" \
    || die "generated lock is not valid JSON"
"$SCRIPT_DIR/lib/release-lock-contract.py" validate-binding \
    --input-lock "$OUT_TMP" --downloads-lock "$DLOCK" --release "$RELEASE" \
    --boards "${RELEASE_BOARDS[@]}" >/dev/null \
    || die "generated input lock violates the release contract"
"$SCRIPT_DIR/lib/release-lock-contract.py" publish \
    --staged "$OUT_TMP" --output "$OUT" >/dev/null \
    || die "release lock publication failed"
OUT_TMP=""

ok "lock written: $OUT"
echo "  release  $RELEASE"
echo "  openwrt  $(git -C "$WORK_DIR" describe --tags 2>/dev/null) @ $(git -C "$WORK_DIR" rev-parse --short HEAD)"
echo "  feeds    $(grep -c '^src-git' "$BUILD_DIR/feeds.conf")"
echo "  patches  $(find "$BUILD_DIR/patches" -name '*.patch' | wc -l)"
echo "  configs  $(find "$BUILD_DIR/config" -maxdepth 1 -type f | wc -l)"
echo "  ui       ${#ARTIFACTS[@]} artifact(s) for $PKGARCH"
