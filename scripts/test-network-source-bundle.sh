#!/bin/bash
# Exercise the real exporter with isolated Git inputs and a valid fixture APK.
# This tests archive contents and commands, not firmware compilation.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$(dirname "$SCRIPT_DIR")"
APK="${APK_TOOL:-$BUILD_DIR/openwrt/staging_dir/host/bin/apk}"
ZSTD="${ZSTD_TOOL:-$BUILD_DIR/openwrt/staging_dir/host/bin/zstd}"
[ -x "$APK" ] && [ -x "$ZSTD" ] || {
    echo "Set APK_TOOL and ZSTD_TOOL to existing OpenWrt host tools" >&2
    exit 1
}
TEST_ROOT=$(mktemp -d -t bpir-network-bundle-XXXXXX)
trap 'rm -rf "$TEST_ROOT"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

for repo in bpirouter-build bpirouter-feeds; do
    mkdir "$TEST_ROOT/$repo"
    case "$repo" in
        bpirouter-build) paths=(.gitignore LICENSE LICENSING.md patches config env-templates scripts flashkit feeds.conf) ;;
        bpirouter-feeds) paths=(.gitignore LICENSE LICENSING.md net) ;;
    esac
    git -C "$BUILD_DIR/../$repo" archive HEAD "${paths[@]}" | tar -xf - -C "$TEST_ROOT/$repo"
done
# Test the current script even before it has been committed in the real repo.
cp "$SCRIPT_DIR/release-source-bundle.sh" "$TEST_ROOT/bpirouter-build/scripts/"
cp "$SCRIPT_DIR/lib/public-export-policy.py" "$TEST_ROOT/bpirouter-build/scripts/lib/"
cp "$SCRIPT_DIR/make-public-tree.sh" "$TEST_ROOT/bpirouter-build/scripts/"
cp "$SCRIPT_DIR/make-flashkit.sh" "$TEST_ROOT/bpirouter-build/scripts/"
cp "$SCRIPT_DIR/test-flashkit-metadata.py" "$TEST_ROOT/bpirouter-build/scripts/"
# Older locks ship only the runbook inside each flashkit, not sibling guides.
for legacy in RUNBOOK-r3mini.md RUNBOOK-openwrt-one.md; do
    printf 'Legacy internal installation record\n' > "$TEST_ROOT/bpirouter-build/flashkit/$legacy"
done
mkdir -p "$TEST_ROOT/bpirouter-build/docs"
cp "$BUILD_DIR/docs/README-PUBLIC.md" "$TEST_ROOT/bpirouter-build/docs/"
cp "$BUILD_DIR/LICENSING.md" "$TEST_ROOT/bpirouter-build/"
cp "$BUILD_DIR/../bpirouter-feeds/LICENSING.md" "$TEST_ROOT/bpirouter-feeds/"
mkdir "$TEST_ROOT/bpirouter-ui"
mkdir -p "$TEST_ROOT/bpirouter-ui/docs/user"
for document in FEATURES.md FEATURES.zh-CN.md INSTALLATION.md INSTALLATION.zh-CN.md; do
    cp "$BUILD_DIR/../bpirouter-ui/docs/user/$document" "$TEST_ROOT/bpirouter-ui/docs/user/"
done
printf 'Internal records must not be exported\n' > "$TEST_ROOT/bpirouter-ui/docs/internal.md"
cp "$BUILD_DIR/../bpirouter-ui/LICENSE" "$TEST_ROOT/bpirouter-ui/"
printf 'Private source must not be exported\n' > "$TEST_ROOT/bpirouter-ui/private.go"

# Freeze a pre-fix lock, then introduce all five corrected files in METADATA_REV.
SD_FIX="$TEST_ROOT/sd-fix"
mkdir "$SD_FIX"
cp "$TEST_ROOT/bpirouter-build/scripts/build-full.sh" "$SD_FIX/"
cp "$TEST_ROOT/bpirouter-build/scripts/make-flashkit.sh" "$SD_FIX/"
mv "$TEST_ROOT/bpirouter-build/scripts/lib/refresh-sd-image-metadata.py" "$SD_FIX/"
mv "$TEST_ROOT/bpirouter-build/scripts/test-sd-image-metadata.py" "$SD_FIX/"
mv "$TEST_ROOT/bpirouter-build/scripts/test-flashkit-metadata.py" "$SD_FIX/"
sed '/# OpenWrt emitted metadata before the factory environment was written\./d; /python3 .*refresh-sd-image-metadata\.py/d' \
    "$SD_FIX/build-full.sh" > "$TEST_ROOT/bpirouter-build/scripts/build-full.sh"
! grep -q 'refresh-sd-image-metadata.py' "$TEST_ROOT/bpirouter-build/scripts/build-full.sh" || fail "pre-fix build fixture"
sed '/^# OpenWrt wrote its checksums before this final recovery archive existed\./,/^PY$/d' \
    "$SD_FIX/make-flashkit.sh" > "$TEST_ROOT/bpirouter-build/scripts/make-flashkit.sh"

for repo in bpirouter-build bpirouter-feeds bpirouter-ui; do
    git -C "$TEST_ROOT/$repo" init -q
    git -C "$TEST_ROOT/$repo" add .
    git -C "$TEST_ROOT/$repo" -c user.name=Fixture -c user.email=fixture@example.invalid \
        commit -qm 'Source bundle fixture'
done

OW="$TEST_ROOT/bpirouter-build/openwrt"
mkdir "$OW"
printf 'all:\n\t@echo source fixture\n' > "$OW/Makefile"
cp "$BUILD_DIR/openwrt/COPYING" "$OW/"
git -C "$OW" init -q
git -C "$OW" add Makefile COPYING
git -C "$OW" -c user.name=Fixture -c user.email=fixture@example.invalid \
    commit -qm 'Upstream identity fixture'
git -C "$OW" tag v25.12.5
git -C "$OW" remote add origin https://example.invalid/openwrt.git
printf 'CONFIG_TARGET_ARCH_PACKAGES="aarch64_cortex-a53"\n' > "$OW/.config"
mkdir -p "$OW/staging_dir/host/bin"
ln -s "$APK" "$OW/staging_dir/host/bin/apk"
ln -s "$ZSTD" "$OW/staging_dir/host/bin/zstd"

RELEASE=v1.5.0-rc999
source "$SCRIPT_DIR/boards.sh"
bpir_select_release_boards "$RELEASE"
python3 - "$TEST_ROOT/DOWNLOADS.lock.json" "$RELEASE" $VALID_BOARDS <<'PY'
import json, sys
with open(sys.argv[1], 'w') as stream:
    json.dump({'schema': 1, 'release': sys.argv[2], 'boards': sys.argv[3:], 'objects': []}, stream)
PY
printf '{}\n' > "$TEST_ROOT/firmware-manifest.json"
mkdir -p "$TEST_ROOT/payload/usr/bin"
printf 'Fixture payload, not a runnable API\n' > "$TEST_ROOT/payload/usr/bin/bpirouter-apid"
UIAPK="$TEST_ROOT/bpirouter-ui-1.5.0_rc999-r1.apk"
"$APK" mkpkg --info name:bpirouter-ui --info version:1.5.0_rc999-r1 \
    --info arch:aarch64_cortex-a53 --files "$TEST_ROOT/payload" --output "$UIAPK"

LOCK="$TEST_ROOT/bpirouter-build/dist/RELEASE-INPUTS.$RELEASE.lock.json"
bash "$TEST_ROOT/bpirouter-build/scripts/make-release-lock.sh" \
    --release "$RELEASE" --downloads-lock "$TEST_ROOT/DOWNLOADS.lock.json" \
    --ui-artifact "$UIAPK" --output "$LOCK" > "$TEST_ROOT/lock.log" 2>&1 \
    || { cat "$TEST_ROOT/lock.log"; fail "fixture lock"; }
bundle_args=(--release "$RELEASE" --input-lock "$LOCK"
             --downloads-lock "$TEST_ROOT/DOWNLOADS.lock.json"
             --firmware-manifest "$TEST_ROOT/firmware-manifest.json" --ui-artifact "$UIAPK")
# No upstream feeds or download cache exist: neither is an export prerequisite.
bash "$TEST_ROOT/bpirouter-build/scripts/release-source-bundle.sh" \
    "${bundle_args[@]}" --output "$TEST_ROOT/output" > "$TEST_ROOT/bundle.log" 2>&1 \
    || { cat "$TEST_ROOT/bundle.log"; fail "network bundle export"; }
mkdir "$TEST_ROOT/unpacked"
gzip -dc "$TEST_ROOT/output/bpirouter-release-$RELEASE.tgz" \
    | tar -xf - -C "$TEST_ROOT/unpacked"
BUNDLE="$TEST_ROOT/unpacked/bpirouter-release-$RELEASE"
for absent in source-cache feeds bpirouter-build/openwrt bpirouter-ui \
              bpirouter-build/docs bpirouter-feeds/net/bpirouter-ui/files; do
    [ ! -e "$BUNDLE/$absent" ] || fail "unexpected export: $absent"
done
[ -z "$(find "$BUNDLE" -name .git -print -quit)" ] || fail "Git history exported"
cmp "$BUNDLE/bpirouter-build/feeds.conf" "$BUILD_DIR/feeds.conf"
cmp "$BUNDLE/proprietary-artifacts/$(basename "$UIAPK")" "$UIAPK"
cmp "$BUNDLE/RELEASE-INPUTS.lock.json" "$LOCK"
cmp "$BUNDLE/LICENSES/GPL-2.0.txt" "$OW/COPYING"
(cd "$BUNDLE" && sha256sum -c --status SHA256SUMS)

# Public repository export includes the locked UI without private history or
# working-tree additions. Its README remains identical across releases.
printf 'uncommitted private note\n' > "$TEST_ROOT/bpirouter-feeds/net/private-note.txt"
PUBLIC="$TEST_ROOT/public/bpirouteros"
bash "$TEST_ROOT/bpirouter-build/scripts/make-public-tree.sh" --release "$RELEASE" \
    --lock "$LOCK" --ui-artifact "$UIAPK" --output "$PUBLIC" > "$TEST_ROOT/public.log" 2>&1 \
    || { cat "$TEST_ROOT/public.log"; fail "public repository export"; }
[ ! -e "$PUBLIC/feeds/bpirouter/net/private-note.txt" ] || fail "working-tree file exported"
[ ! -e "$PUBLIC/feeds/bpirouter/net/bpirouter-ui/files" ] || fail "private generated payload exported"
[ -z "$(find "$PUBLIC" -name .git -print -quit)" ] || fail "public Git history exported"
[ ! -e "$PUBLIC/scripts/lib/public-export-policy.py" ] || fail "internal export policy shipped"
[ ! -e "$PUBLIC/scripts/test-source-export.py" ] || fail "internal export test shipped"
cmp "$PUBLIC/README.md" "$BUILD_DIR/docs/README-PUBLIC.md"
for tree in "$PUBLIC" "$BUNDLE/bpirouter-build"; do
    for legacy in RUNBOOK-r3mini.md RUNBOOK-openwrt-one.md; do
        runbook="$tree/flashkit/$legacy"
        grep -Fq 'NAND OK: remove USB, strap NAND, power-cycle' "$runbook" \
            || fail "legacy runbook lost R3-Mini installation instructions"
        grep -Fq 'PROVISION OK - booting NAND' "$runbook" \
            || fail "legacy runbook lost OpenWrt One installation instructions"
        if grep -Eq '\]\([^)]*\.md([#)]|$)' "$runbook"; then
            fail "legacy runbook links to a document absent from the kit"
        fi
        ! grep -Fq 'Legacy internal installation record' "$runbook" \
            || fail "legacy internal record exported"
    done
done
for document in FEATURES.md FEATURES.zh-CN.md INSTALLATION.md INSTALLATION.zh-CN.md; do
    cmp "$PUBLIC/$document" "$BUILD_DIR/../bpirouter-ui/docs/user/$document"
done
[ ! -e "$PUBLIC/docs" ] || fail "internal UI documentation exported"
[ ! -e "$PUBLIC/private.go" ] || fail "private UI source exported"
! grep -Fq "$RELEASE" "$PUBLIC/README.md" || fail "README hardcodes release"
cmp "$PUBLIC/proprietary-artifacts/bpirouter-ui.apk" "$UIAPK"
(cd "$TEST_ROOT/public" && sha256sum -c bpirouteros.tgz.sha256)
mkdir "$TEST_ROOT/public-unpacked"
tar -xzf "$PUBLIC.tgz" -C "$TEST_ROOT/public-unpacked"
diff -qr "$PUBLIC" "$TEST_ROOT/public-unpacked/bpirouteros"
git -C "$TEST_ROOT/public-unpacked/bpirouteros" init -q
if git -C "$TEST_ROOT/public-unpacked/bpirouteros" check-ignore \
    patches/common/openwrt/004-cellular-netifd-lifecycle-owner.patch; then
    fail "public Git ignore rules hide required OpenWrt patches"
fi
if bash "$TEST_ROOT/bpirouter-build/scripts/make-public-tree.sh" --release "$RELEASE" \
    --lock "$LOCK" --ui-artifact "$TEST_ROOT/firmware-manifest.json" \
    --output "$TEST_ROOT/wrong/bpirouteros" > "$TEST_ROOT/wrong.log" 2>&1; then
    fail "unlocked UI accepted"
fi
[ ! -e "$TEST_ROOT/wrong/bpirouteros" ] || fail "wrong UI created output"
for document in bpirouter-build/LICENSING.md bpirouter-build/docs/README-PUBLIC.md bpirouter-feeds/LICENSING.md \
    bpirouter-ui/docs/user/FEATURES.md bpirouter-ui/docs/user/FEATURES.zh-CN.md \
    bpirouter-ui/docs/user/INSTALLATION.md bpirouter-ui/docs/user/INSTALLATION.zh-CN.md; do
    cp "$TEST_ROOT/$document" "$TEST_ROOT/document-backup"
    printf '\nUncommitted delivery text\n' >> "$TEST_ROOT/$document"
    if bash "$TEST_ROOT/bpirouter-build/scripts/make-public-tree.sh" --release "$RELEASE" \
        --lock "$LOCK" --ui-artifact "$UIAPK" --output "$TEST_ROOT/dirty/bpirouteros" \
        > "$TEST_ROOT/dirty.log" 2>&1; then
        fail "uncommitted delivery document accepted: $document"
    fi
    grep -q 'delivery document differs from committed HEAD' "$TEST_ROOT/dirty.log" || fail "wrong document refusal"
    [ ! -e "$TEST_ROOT/dirty/bpirouteros" ] || fail "dirty document created output"
    cp "$TEST_ROOT/document-backup" "$TEST_ROOT/$document"
done
git -C "$TEST_ROOT/bpirouter-build" rm --cached -q docs/README-PUBLIC.md
if bash "$TEST_ROOT/bpirouter-build/scripts/make-public-tree.sh" --release "$RELEASE" \
    --lock "$LOCK" --ui-artifact "$UIAPK" --output "$TEST_ROOT/untracked/bpirouteros" \
    > "$TEST_ROOT/untracked.log" 2>&1; then
    fail "untracked delivery document accepted"
fi
grep -q 'delivery document must be tracked' "$TEST_ROOT/untracked.log" || fail "wrong untracked refusal"
[ ! -e "$TEST_ROOT/untracked/bpirouteros" ] || fail "untracked document created output"
git -C "$TEST_ROOT/bpirouter-build" add docs/README-PUBLIC.md
rm "$TEST_ROOT/bpirouter-feeds/net/private-note.txt"
for script in prepare.sh build-full.sh; do
    [ -x "$BUNDLE/bpirouter-build/scripts/$script" ] || fail "missing command: $script"
    bash -n "$BUNDLE/bpirouter-build/scripts/$script"
done
grep -Fq -- '--ui-artifact "../proprietary-artifacts/' "$BUNDLE/README.md"
grep -Fq 'Internet access is required' "$BUNDLE/README.md"
sed -n '/^    cd bpirouter-build$/,/^$/p' "$BUNDLE/README.md" | bash -n
grep -Fq '    BOARD=bpi-r4' "$BUNDLE/README.md"
! grep -Fq 'ln -s ../../source-cache' "$BUNDLE/README.md" || fail "offline command retained"
while read -r kind name path; do
    [ "$kind" = src-link ] || continue
    [ -d "$(realpath -m "$BUNDLE/bpirouter-build/openwrt/feeds/$path")" ] \
        || fail "unresolved local feed: $name"
done < "$BUNDLE/bpirouter-build/feeds.conf"
for license in bpirouter-build bpirouter-feeds bpirouter-ui; do
    [ -s "$BUNDLE/LICENSES/$license.LICENSE" ] || fail "missing licence: $license"
done
echo "PASS: network bundle includes project sources and UI APK, with no upstream/cache/private source"

# Execute the shipped commands, stopping at external work rather than replacing
# prepare/build or their lock checks. No network or firmware build runs here.
README_SETUP=$(sed -n '/^    cd bpirouter-build$/,/^    BOARD=/p' "$BUNDLE/README.md")
README_PREPARE=$(sed -n '/^    \.\/scripts\/prepare.sh /p' "$BUNDLE/README.md")
README_BUILD=$(sed -n '/^    \.\/scripts\/build-full.sh /p' "$BUNDLE/README.md")
[ -n "$README_PREPARE" ] && [ -n "$README_BUILD" ] || fail "missing README commands"
git() {
    if [ "${1:-}" = clone ]; then
        echo 'FIXTURE: reached OpenWrt clone' >&2
        return 1
    fi
    command git "$@"
}
export -f git
status=0
(cd "$BUNDLE" && bash -ec "$README_SETUP
$README_PREPARE") > "$TEST_ROOT/readme-prepare.log" 2>&1 || status=$?
[ "$status" -eq 1 ] && grep -Fq 'FIXTURE: reached OpenWrt clone' "$TEST_ROOT/readme-prepare.log" \
    || { cat "$TEST_ROOT/readme-prepare.log"; fail "README prepare did not reach fresh checkout initialization"; }
[ ! -e "$BUNDLE/bpirouter-build/openwrt" ] || fail "clone probe created an upstream checkout"
unset -f git

# Model the public artifact marker, using real tree hashes and lock validation.
# Leave the UI unstaged so the real build stops before any compilation.
PUBLIC_BUILD="$BUNDLE/bpirouter-build"
git clone -q --no-hardlinks "$OW" "$PUBLIC_BUILD/openwrt"
cat "$PUBLIC_BUILD/config/common.config" "$PUBLIC_BUILD/config/bpi-r4.config" \
    > "$PUBLIC_BUILD/openwrt/.config"
INPUT_SHA=$("$PUBLIC_BUILD/scripts/release-build-provenance.py" prepare-input-id \
    --build-dir "$PUBLIC_BUILD" --board bpi-r4)
printf '%s\n' 'board=bpi-r4' 'ui_mode=artifact' 'release_bound=0' 'development_bound=0' \
    "input_lock_path=$PUBLIC_BUILD/RELEASE-INPUTS.lock.json" "prepare_inputs_sha256=$INPUT_SHA" \
    > "$PUBLIC_BUILD/openwrt/.bpirouter-prepared-board"
status=0
(cd "$BUNDLE" && bash -ec "$README_SETUP
$README_BUILD") > "$TEST_ROOT/readme-build.log" 2>&1 || status=$?
[ "$status" -eq 1 ] \
    && grep -Fq "lock matches the tree ($RELEASE, scope=tree)" "$TEST_ROOT/readme-build.log" \
    && grep -Fq 'tree prepared for bpi-r4, ui=artifact' "$TEST_ROOT/readme-build.log" \
    && grep -Fq 'ui_mode=artifact but nothing is staged' "$TEST_ROOT/readme-build.log" \
    || { cat "$TEST_ROOT/readme-build.log"; fail "README build did not pass public-tree admission"; }

# Auto-discovery must not mean skipping the lock: altered inputs still fail at
# the lock check, before the deliberately unstaged UI can be considered.
printf '\n# Fixture config drift\n' >> "$PUBLIC_BUILD/config/bpi-r4.config"
if (cd "$BUNDLE" && bash -ec "$README_SETUP
$README_BUILD") > "$TEST_ROOT/readme-drift.log" 2>&1; then
    fail "README build accepted changed locked inputs"
fi
grep -Fq 'config changed since the lock: config/bpi-r4.config' "$TEST_ROOT/readme-drift.log" \
    || { cat "$TEST_ROOT/readme-drift.log"; fail "README build did not enforce the input lock"; }
echo "PASS: README prepare reaches clone; public build checks the lock before UI staging"

# A different but valid APK must still be refused before an archive is written.
printf 'Different fixture payload\n' > "$TEST_ROOT/payload/usr/bin/bpirouter-apid"
"$APK" mkpkg --info name:bpirouter-ui --info version:1.5.0_rc999-r1 \
    --info arch:aarch64_cortex-a53 --files "$TEST_ROOT/payload" --output "$TEST_ROOT/other.apk"
if bash "$TEST_ROOT/bpirouter-build/scripts/release-source-bundle.sh" \
    "${bundle_args[@]}" --ui-artifact "$TEST_ROOT/other.apk" --output "$TEST_ROOT/rejected" \
    > "$TEST_ROOT/rejected.log" 2>&1; then
    fail "unlocked APK accepted"
fi
grep -Fq "the UI artifact's sha256 is not in the input lock" "$TEST_ROOT/rejected.log"
[ ! -e "$TEST_ROOT/rejected" ] || fail "rejected export left an output directory"
echo "PASS: the existing UI artifact identity check remains enforced"

# Exercise the language gate with a committed document, independently of the lock.
printf '\n\344\270\255\346\226\207\n' >> "$TEST_ROOT/bpirouter-build/docs/README-PUBLIC.md"
git -C "$TEST_ROOT/bpirouter-build" add docs/README-PUBLIC.md
git -C "$TEST_ROOT/bpirouter-build" -c user.name=Fixture -c user.email=fixture@example.invalid \
    commit -qm 'Non-English delivery fixture'
if bash "$TEST_ROOT/bpirouter-build/scripts/make-public-tree.sh" --release "$RELEASE" \
    --lock "$LOCK" --ui-artifact "$UIAPK" --output "$TEST_ROOT/nonenglish/bpirouteros" \
    > "$TEST_ROOT/nonenglish.log" 2>&1; then
    fail "Chinese public text accepted"
fi
grep -q 'Chinese text in public export: README.md' "$TEST_ROOT/nonenglish.log" || fail "wrong language refusal"
[ ! -e "$TEST_ROOT/nonenglish/bpirouteros.tgz" ] || fail "non-English archive emitted"
cp "$BUILD_DIR/docs/README-PUBLIC.md" "$TEST_ROOT/bpirouter-build/docs/README-PUBLIC.md"
git -C "$TEST_ROOT/bpirouter-build" add docs/README-PUBLIC.md
git -C "$TEST_ROOT/bpirouter-build" -c user.name=Fixture -c user.email=fixture@example.invalid \
    commit -qm 'Restore English delivery fixture'
bash "$TEST_ROOT/bpirouter-build/scripts/make-public-tree.sh" --release "$RELEASE" \
    --lock "$LOCK" --ui-artifact "$UIAPK" --output "$TEST_ROOT/new-head/bpirouteros" \
    > "$TEST_ROOT/new-head.log" 2>&1 || { cat "$TEST_ROOT/new-head.log"; fail "committed documents with old firmware lock"; }
echo "PASS: committed delivery documents can advance without changing firmware inputs"

# Only the explicitly selected committed correction enters the public tree.
cp "$SD_FIX/build-full.sh" "$SD_FIX/test-sd-image-metadata.py" "$TEST_ROOT/bpirouter-build/scripts/"
cp "$SD_FIX/refresh-sd-image-metadata.py" "$TEST_ROOT/bpirouter-build/scripts/lib/"
printf '\n# Committed SD metadata fixture\n' >> "$TEST_ROOT/bpirouter-build/scripts/lib/refresh-sd-image-metadata.py"
printf 'Unrelated committed revision file\n' > "$TEST_ROOT/bpirouter-build/scripts/revision-note.txt"
git -C "$TEST_ROOT/bpirouter-build" add scripts/build-full.sh scripts/test-sd-image-metadata.py \
    scripts/lib/refresh-sd-image-metadata.py scripts/revision-note.txt
git -C "$TEST_ROOT/bpirouter-build" -c user.name=Fixture -c user.email=fixture@example.invalid \
    commit -qm 'SD metadata revision fixture'
SD_ONLY_REV=$(git -C "$TEST_ROOT/bpirouter-build" rev-parse HEAD)
cp "$SD_FIX/make-flashkit.sh" "$SD_FIX/test-flashkit-metadata.py" "$TEST_ROOT/bpirouter-build/scripts/"
git -C "$TEST_ROOT/bpirouter-build" add scripts/make-flashkit.sh scripts/test-flashkit-metadata.py
git -C "$TEST_ROOT/bpirouter-build" -c user.name=Fixture -c user.email=fixture@example.invalid \
    commit -qm 'Flashkit metadata revision fixture'
METADATA_REV=$(git -C "$TEST_ROOT/bpirouter-build" rev-parse HEAD)
printf '\n# Uncommitted content must not be exported\n' >> "$TEST_ROOT/bpirouter-build/scripts/lib/refresh-sd-image-metadata.py"
REVISED="$TEST_ROOT/revised/bpirouteros"
bash "$TEST_ROOT/bpirouter-build/scripts/make-public-tree.sh" --release "$RELEASE" \
    --lock "$LOCK" --ui-artifact "$UIAPK" --metadata-revision "$METADATA_REV" --output "$REVISED" \
    > "$TEST_ROOT/revised.log" 2>&1 || { cat "$TEST_ROOT/revised.log"; fail "metadata revision export"; }
[ ! -e "$REVISED/scripts/revision-note.txt" ] || fail "unrelated revision file exported"
cmp "$LOCK" "$REVISED/RELEASE-INPUTS.lock.json"
python3 - "$TEST_ROOT/bpirouter-build" "$REVISED" "$METADATA_REV" "$TEST_ROOT/new-head/bpirouteros" <<'PY'
import hashlib, json, pathlib, subprocess, sys
repo, root = map(pathlib.Path, sys.argv[1:3])
record = json.loads((root / 'SOURCE-DELIVERY.json').read_text())
lock = root / 'RELEASE-INPUTS.lock.json'
assert record['input_lock_sha256'] == hashlib.sha256(lock.read_bytes()).hexdigest()
assert record['firmware_build_commit'] == json.loads(lock.read_text())['repos']['bpirouter-build']
assert record['metadata_revision'] == sys.argv[3]
assert set(record['files_sha256']) == {'scripts/build-full.sh',
    'scripts/lib/refresh-sd-image-metadata.py', 'scripts/test-sd-image-metadata.py',
    'scripts/make-flashkit.sh', 'scripts/test-flashkit-metadata.py'}
for name, digest in record['files_sha256'].items():
    content = (root / name).read_bytes()
    assert content == subprocess.check_output(['git', '-C', str(repo), 'show', f'{sys.argv[3]}:{name}'])
    assert hashlib.sha256(content).hexdigest() == digest
baseline = pathlib.Path(sys.argv[4])
assert not (baseline / 'scripts/lib/refresh-sd-image-metadata.py').exists()
assert not (baseline / 'scripts/test-sd-image-metadata.py').exists()
assert not (baseline / 'scripts/test-flashkit-metadata.py').exists()
assert (baseline / 'scripts/make-flashkit.sh').read_bytes() != (root / 'scripts/make-flashkit.sh').read_bytes()
assert 'refresh-sd-image-metadata.py' not in (baseline / 'scripts/build-full.sh').read_text()
allowed = set(record['files_sha256']) | {'SOURCE-DELIVERY.json'}
before = {str(p.relative_to(baseline)): p.read_bytes() for p in baseline.rglob('*') if p.is_file()}
after = {str(p.relative_to(root)): p.read_bytes() for p in root.rglob('*') if p.is_file()}
assert {name for name in before.keys() | after.keys() if before.get(name) != after.get(name)} <= allowed
PY
python3 "$REVISED/scripts/test-sd-image-metadata.py"
python3 "$REVISED/scripts/test-flashkit-metadata.py"
MISSING_SD_REV=$(git -C "$TEST_ROOT/bpirouter-build" rev-parse "$SD_ONLY_REV^")
for revision in HEAD 0000000000000000000000000000000000000000 "$MISSING_SD_REV" "$SD_ONLY_REV"; do
    if bash "$TEST_ROOT/bpirouter-build/scripts/make-public-tree.sh" --release "$RELEASE" \
        --lock "$LOCK" --ui-artifact "$UIAPK" --metadata-revision "$revision" \
        --output "$TEST_ROOT/bad-revision/bpirouteros" > "$TEST_ROOT/bad-revision.log" 2>&1; then
        fail "invalid metadata revision accepted: $revision"
    fi
    if [ "$revision" = "$MISSING_SD_REV" ]; then
        grep -Fq 'metadata revision is missing scripts/lib/refresh-sd-image-metadata.py' \
            "$TEST_ROOT/bad-revision.log" || fail "missing SD file was not rejected before export"
    fi
    if [ "$revision" = "$SD_ONLY_REV" ]; then
        grep -Fq 'metadata revision is missing scripts/test-flashkit-metadata.py' \
            "$TEST_ROOT/bad-revision.log" || fail "missing flashkit file was not rejected before export"
    fi
    [ ! -e "$TEST_ROOT/bad-revision/bpirouteros" ] || fail "invalid revision created output"
done
echo "PASS: explicit metadata revision preserves the image lock and excludes unrelated changes"
