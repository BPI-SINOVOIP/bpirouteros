#!/bin/bash
# Prove that release provenance is created at build time, not reconstructed by
# the collector from whichever lock happens to be supplied later.
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TMP=$(mktemp -d -t bpir-release-build-XXXXXX)
LOCK_RELEASE_FILE=""
BG_PIDS=""
cleanup() {
    [ -z "$LOCK_RELEASE_FILE" ] || touch "$LOCK_RELEASE_FILE"
    for pid in $BG_PIDS; do kill "$pid" 2>/dev/null || true; done
    rm -rf "$TMP"
}
trap cleanup EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }
ok() { echo "ok: $1"; }
expect_fail() {
    local name="$1"; shift
    if "$@" >"$TMP/negative.log" 2>&1; then
        fail "$name was accepted"
    fi
    ok "$name refused"
}
expect_test_only_refusal() {
    local name="$1"; shift
    if "$@" >"$TMP/test-only.log" 2>&1; then
        fail "$name accepted a test-only lock"
    fi
    grep -Fq 'test-only or legacy input lock cannot authorize a formal release operation' \
        "$TMP/test-only.log" \
        || { cat "$TMP/test-only.log"; fail "$name did not fail at the test-only authority gate"; }
    ok "$name refused test-only authority before release work"
}

ROOT="$TMP/workspace"
BUILD="$ROOT/bpirouter-build"
UI="$ROOT/bpirouter-ui"
FEEDS="$ROOT/bpirouter-feeds"
OPENWRT="$BUILD/openwrt"
mkdir -p "$BUILD/config" "$BUILD/patches/common" "$UI" "$FEEDS" "$OPENWRT"
cp -a "$SCRIPT_DIR/../flashkit" "$BUILD/flashkit"
cp -a "$SCRIPT_DIR" "$BUILD/scripts"
mkdir -p "$UI/docs"
cp -a "$SCRIPT_DIR/../../bpirouter-ui/docs/user" "$UI/docs/user"
# This suite exercises the provenance coordinator with a deliberately tiny
# fake OpenWrt/feed tree. Task-specific QMF/rootfs/cellular gates have their own
# full anti-mutation suites and cannot run against that synthetic package set;
# keep the wiring call sites, but replace only the copied fixture implementations.
for gate in test-mwan3-canonical.sh test-mwan3-route-delete-order.sh \
			test-mwan3-dynamic-child.sh \
			test-sqm-canonical.sh test-sqm-lifecycle-owner.sh test-owned-configs.sh \
			test-offload-disabled.sh \
			test-rootfs-integrity.sh \
			test-kernel-patch-routing.sh \
			test-as21xxx-reprobe.sh \
			test-cellular-netifd-lifecycle.sh \
			test-netifd-dynamic-ip6assign.sh \
			test-netifd-host-route.sh \
			test-netifd-proto-busy.sh \
			test-factory-reset-rootfs.sh check-rootfs-integrity.sh \
			check-factory-reset-rootfs.sh check-acceptance-provenance-rootfs.sh; do
    cat >"$BUILD/scripts/$gate" <<'SH'
#!/bin/sh
exit 0
SH
    chmod +x "$BUILD/scripts/$gate"
done

init_repo() {
    local repo="$1" file="$2" value="$3"
    git -C "$repo" init -q
    git -C "$repo" config user.name provenance-test
    git -C "$repo" config user.email provenance-test@example.invalid
    printf '%s\n' "$value" >"$repo/$file"
    git -C "$repo" add "$file"
    git -C "$repo" commit -qm initial
}

init_repo "$UI" source.txt ui
init_repo "$FEEDS" package.txt feeds
init_repo "$OPENWRT" source.txt openwrt

# A tiny source builder with the same production interface: it must receive the
# exact feed directory selected by feeds.conf and write a self-checking manifest.
mkdir -p "$UI/deploy"
cat >"$UI/deploy/artifact-hash.sh" <<'SH'
#!/bin/bash
set -eo pipefail
mode="$1"; base="$2"
case "$mode" in
    src) (cd "$base" && { printf 'source.txt\0'; sha256sum source.txt; }) ;;
    art) (cd "$base" && find . -type f ! -name .manifest -print0 | sort -z | xargs -0 -r sha256sum) ;;
    *) exit 2 ;;
esac | sha256sum | cut -d' ' -f1
SH
cat >"$UI/deploy/build.sh" <<'SH'
#!/bin/bash
set -eo pipefail
[ "$1" = --feed-files ] && [ -n "$2" ] || exit 2
feed="$2"; project="$(cd "$(dirname "$0")/.." && pwd)"
printf 'observed-ui-build-time=%s\n' "${BPIROUTER_BUILD_TIME:-unset}"
rm -rf "$feed"; mkdir -p "$feed/www"
printf 'apid-from-current-build\n' >"$feed/bpirouter-apid"
printf 'generator\n' >"$feed/bpirouter-gen-cert"
printf 'version\n' >"$feed/version"
printf '<html>current</html>\n' >"$feed/www/index.html"
apid_sha=$(sha256sum "$feed/bpirouter-apid" | cut -d' ' -f1)
apid_size=$(wc -c <"$feed/bpirouter-apid" | tr -d ' ')
index_sha=$(sha256sum "$feed/www/index.html" | cut -d' ' -f1)
index_size=$(wc -c <"$feed/www/index.html" | tr -d ' ')
printf 'BPIR-PAYLOAD|1\nT|/www/bpirouter\nT|/usr/share/bpirouter\nF|755|%s|%s|/usr/bin/bpirouter-apid\nF|644|%s|%s|/www/bpirouter/index.html\n' \
    "$apid_size" "$apid_sha" "$index_size" "$index_sha" | LC_ALL=C sort >"$feed/.payload-inventory"
inventory=$(sha256sum "$feed/.payload-inventory" | cut -d' ' -f1)
src=$("$project/deploy/artifact-hash.sh" src "$project")
art=$("$project/deploy/artifact-hash.sh" art "$feed")
printf 'src %s\nart %s\ninventory %s\n' "$src" "$art" "$inventory" >"$feed/.manifest"
SH
chmod +x "$UI/deploy/artifact-hash.sh" "$UI/deploy/build.sh"
# Formal acceptance tools are identified through the real UI helper; only the
# five tool files are fixtures.
mkdir -p "$UI/scripts/lib"
cp "$SCRIPT_DIR/../../bpirouter-ui/scripts/acceptance-bundle.sh" "$UI/scripts/acceptance-bundle.sh"
for runner in cell qos seg tel; do
    printf '#!/bin/sh\n# %s acceptance fixture\n' "$runner" >"$UI/scripts/$runner-acceptance.sh"
done
printf '#!/bin/sh\n# common acceptance fixture\n' >"$UI/scripts/lib/acceptance-common.sh"
chmod +x "$UI/scripts/"*.sh "$UI/scripts/lib/acceptance-common.sh"
git -C "$UI" add deploy docs scripts
git -C "$UI" commit --amend -qm initial

mkdir -p "$FEEDS/net/bpirouter-ui"
printf 'include package.mk\n' >"$FEEDS/net/bpirouter-ui/Makefile"
printf 'net/bpirouter-ui/files/\n' >"$FEEDS/.gitignore"
git -C "$FEEDS" add .gitignore net/bpirouter-ui/Makefile
git -C "$FEEDS" commit --amend -qm initial

mkdir -p "$OPENWRT/scripts" "$OPENWRT/include" "$OPENWRT/target/linux"
cat >"$OPENWRT/scripts/feeds" <<'SH'
#!/bin/sh
exit 0
SH
chmod +x "$OPENWRT/scripts/feeds"
printf 'openwrt toplevel\n' >"$OPENWRT/include/toplevel.mk"
printf 'openwrt target linux\n' >"$OPENWRT/target/linux/Makefile"
cat >"$OPENWRT/Makefile" <<'MK'
.PHONY: all download defconfig package/bpirouter-ui/clean
all:
	@if [ -n "$${BUILD_LOCK_HELD_FILE:-}" ]; then : >"$${BUILD_LOCK_HELD_FILE}"; while [ ! -e "$${BUILD_LOCK_RELEASE_FILE}" ]; do sleep 0.05; done; fi
	@printf '%s\n' "$${BPIROUTER_UI_PKG_VERSION:-}" >.observed-ui-package-version
	@mkdir -p build_dir/fake/root-mediatek
	@mkdir -p bin/targets/mediatek/filogic
	@if [ "$${SKIP_RAMBL2:-0}" != 1 ]; then stamp=build_dir/target-test/arm-trusted-firmware-mediatek-mt7981-ram-ddr4/source/.pkgdir/trusted-firmware-a-mt7981-ram-ddr4.installed; if [ ! -f "$$stamp" ]; then mkdir -p "$$(dirname "$$stamp")"; printf 'current-ram-bl2\n' >bin/targets/mediatek/filogic/mt7981-ram-ddr4-bl2.bin; touch "$$stamp"; fi; fi
	@printf 'current-r3mini-ram-bl2\n' >bin/targets/mediatek/filogic/mt7986-ram-ddr4-bl2.bin
	@if [ "$${SKIP_PRIMARY_IMAGE:-0}" != 1 ]; then printf 'current-build\n' >bin/targets/mediatek/filogic/openwrt-mediatek-filogic-openwrt_one-squashfs-sysupgrade.itb; fi
	@printf 'current-r3mini-build\n' >bin/targets/mediatek/filogic/openwrt-mediatek-filogic-bananapi_bpi-r3-mini-squashfs-sysupgrade.itb
	@printf 'current-r3mini-fip\n' >bin/targets/mediatek/filogic/openwrt-mediatek-filogic-bananapi_bpi-r3-mini-snand-bl31-uboot.fip
	@printf 'current-r3mini-factory\n' >bin/targets/mediatek/filogic/openwrt-mediatek-filogic-bananapi_bpi-r3-mini-snand-factory.bin
	@for suffix in factory.ubi nor-bl31-uboot.fip nor-factory.bin nor-preloader.bin ram-bl31-uboot.fip snand-bl31-uboot.fip snand-factory.bin snand-preloader.bin; do printf 'current-%s\n' "$$suffix" >"bin/targets/mediatek/filogic/openwrt-mediatek-filogic-openwrt_one-$$suffix"; done
	@printf 'package manifest\n' >bin/targets/mediatek/filogic/openwrt-mediatek-filogic-openwrt_one.manifest
	@if [ "$${SKIP_INITRAMFS:-0}" != 1 ]; then printf 'current-initramfs\n' >bin/targets/mediatek/filogic/openwrt-mediatek-filogic-openwrt_one-initramfs.itb; fi
	@if [ "$${SKIP_APK:-0}" != 1 ]; then pkg=$$(mktemp -d); mkdir -p "$$pkg/usr/bin" "$$pkg/www/bpirouter" bin/packages/aarch64_cortex-a53/bpirouter; printf 'apid-from-package\n' >"$$pkg/usr/bin/bpirouter-apid"; chmod 755 "$$pkg/usr/bin/bpirouter-apid"; printf '<html>package</html>\n' >"$$pkg/www/bpirouter/index.html"; tar -czf bin/packages/aarch64_cortex-a53/bpirouter/bpirouter-ui-1.0.apk -C "$$pkg" .; rm -rf "$$pkg"; fi
	@if [ "$${MUTATE_PREPARED:-0}" = 1 ]; then printf 'build-end-drift\n' >>source.txt; fi
	@if [ "$${MUTATE_BATCH_UI:-0}" = 1 ]; then printf 'batch-input-drift\n' >>../../bpirouter-ui/source.txt; fi
download:
	@true
defconfig:
	@true
package/bpirouter-ui/clean:
	@rm -rf bin/packages/aarch64_cortex-a53/bpirouter
MK
printf 'bin/\nbuild_dir/\nstaging_dir/\n.config\nfeeds.conf\n.observed-ui-package-version\n' >"$OPENWRT/.gitignore"
git -C "$OPENWRT" add .gitignore Makefile include/toplevel.mk scripts/feeds target/linux/Makefile
git -C "$OPENWRT" commit --amend -qm initial

mkdir -p "$OPENWRT/staging_dir/host/bin"
cat >"$OPENWRT/staging_dir/host/bin/apk" <<'SH'
#!/bin/sh
set -eu
[ "$1" = extract ] || exit 2
shift
destination=""
archive=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --allow-untrusted) shift ;;
        --destination) destination="$2"; shift 2 ;;
        *) archive="$1"; shift ;;
    esac
done
[ -n "$destination" ] && [ -f "$archive" ] || exit 2
tar -xzf "$archive" -C "$destination"
SH
chmod +x "$OPENWRT/staging_dir/host/bin/apk"
git -C "$OPENWRT" add -f staging_dir/host/bin/apk
git -C "$OPENWRT" commit --amend -qm initial
git -C "$OPENWRT" tag v25.12.2
git -C "$OPENWRT" commit --allow-empty -qm 'OpenWrt v25.12.5 fixture'
git -C "$OPENWRT" tag v25.12.5
BPIR_OPENWRT_GIT_COMMIT=$(git -C "$OPENWRT" rev-parse 'v25.12.5^{commit}')
sed -i \
    "s/^BPIR_OPENWRT_GIT_COMMIT=.*/BPIR_OPENWRT_GIT_COMMIT=\"$BPIR_OPENWRT_GIT_COMMIT\"/" \
    "$BUILD/scripts/lib/openwrt-source.sh"

cat >"$BUILD/config/common.config" <<'CONFIG'
CONFIG_PACKAGE_kmod-usb-net-cdc-ncm=y
CONFIG_PACKAGE_kmod-usb-net-cdc-ether=y
CONFIG_PACKAGE_kmod-usb-net-rndis=y
# CONFIG_PACKAGE_umbim is not set
# CONFIG_PACKAGE_kmod-usb-net-cdc-mbim is not set
CONFIG
printf 'CONFIG_TARGET_mediatek_filogic_DEVICE_bananapi_bpi-r4=y\n' >"$BUILD/config/bpi-r4.config"
printf 'CONFIG_TARGET_mediatek_filogic_DEVICE_openwrt_one=y\nCONFIG_PACKAGE_bpirouter-ui=y\n' \
    >"$BUILD/config/openwrt-one.config"
printf 'CONFIG_TARGET_mediatek_filogic_DEVICE_bananapi_bpi-r3-mini=y\nCONFIG_PACKAGE_bpirouter-ui=y\n' \
    >"$BUILD/config/bpi-r3-mini.config"
for board in bpi-r4-lite bpi-r4-pro bpi-r3; do
	printf '# synthetic %s config\n' "$board" >"$BUILD/config/$board.config"
done

# The formal board set is VALID_BOARDS, not a list copied into each fixture.
# Copies are how a new SKU gets a lock that still names the previous set: the
# contract check then passes against a stale expectation instead of failing.
PRODUCT_BOARDS_JSON=$( . "$SCRIPT_DIR/boards.sh"; printf '%s\n' $VALID_BOARDS |
    python3 -c 'import json,sys; print(json.dumps([l.strip() for l in sys.stdin if l.strip()]))' )
export PRODUCT_BOARDS_JSON
printf 'patch\n' >"$BUILD/patches/common/test.patch"
FEEDS_COMMIT=$(git -C "$FEEDS" rev-parse HEAD)
printf 'src-git bpirouter https://example.invalid/bpirouter-feeds.git^%s\n' "$FEEDS_COMMIT" >"$BUILD/feeds.conf"
printf 'src-link bpirouter %s\n' "$FEEDS" >>"$BUILD/feeds.conf"
printf 'openwrt/\ndist/\n.bpirouter-build.lock\n' >"$BUILD/.gitignore"
git -C "$BUILD" init -q
git -C "$BUILD" config user.name provenance-test
git -C "$BUILD" config user.email provenance-test@example.invalid
git -C "$BUILD" add .gitignore config patches feeds.conf flashkit scripts
git -C "$BUILD" commit -qm initial
PIPELINE_SCRIPTS="$BUILD/scripts"
MANIFEST_UNDER_TEST="$BUILD/scripts/make-firmware-manifest.sh"

printf 'CONFIG_TARGET_mediatek_filogic_DEVICE_bananapi_bpi-r4=y\nCONFIG_PACKAGE_bpirouter-ui=y\n' >"$OPENWRT/.config"
cp "$BUILD/feeds.conf" "$OPENWRT/feeds.conf"

LOCK="$TMP/RELEASE-INPUTS.lock.json"
CANONICAL_LOCK="$BUILD/dist/RELEASE-INPUTS.v1.4.9-rc999.lock.json"
DOWNLOADS_LOCK="$TMP/DOWNLOADS.lock.json"
cat >"$DOWNLOADS_LOCK" <<JSON
{
  "schema": 1,
  "release": "v1.4.9-rc999",
  "boards": $PRODUCT_BOARDS_JSON,
  "objects": []
}
JSON
mkdir -p "$BUILD/dist"
python3 - "$CANONICAL_LOCK" "$BUILD" "$UI" "$FEEDS" "$OPENWRT" "$DOWNLOADS_LOCK" <<'PY'
import hashlib, json, os, pathlib, subprocess, sys
out, build, ui, feeds, openwrt, downloads = map(pathlib.Path, sys.argv[1:])
def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()
def head(path):
    return subprocess.check_output(["git", "-C", path, "rev-parse", "HEAD"], text=True).strip()
data = {
    "schema": 1,
    "release": "v1.4.9-rc999",
    "test_only": False,
    "downloads_lock_sha256": sha(downloads),
    "boards": json.loads(os.environ["PRODUCT_BOARDS_JSON"]),
    "openwrt": {"commit": head(openwrt)},
    "repos": {
        "bpirouter-build": head(build),
        "bpirouter-ui": head(ui),
        "bpirouter-feeds": head(feeds),
    },
    "feeds": [{
        "name": "bpirouter",
        "url": "https://example.invalid/bpirouter-feeds.git",
        "commit": head(feeds),
    }],
    "patches": [{"path": "patches/common/test.patch", "sha256": sha(build / "patches/common/test.patch")}],
    "configs": [
        {"path": str(path.relative_to(build)), "sha256": sha(path)}
        for path in sorted((build / "config").glob("*.config"))
    ],
    "non_source_inputs": [],
}
out.write_text(json.dumps(data, indent=2) + "\n")
PY
cp "$CANONICAL_LOCK" "$LOCK"

export BPIR_BUILD_DIR="$BUILD"
export BPIR_WORK_DIR="$OPENWRT"
export BPIR_UI_DIR="$UI"
export BPIR_FEEDS_DIR="$FEEDS"
export BPIR_CONFIG_DIR="$BUILD/config"
MARKER="$OPENWRT/.bpirouter-prepared-board"
LOCK_SHA=$(sha256sum "$LOCK" | cut -d' ' -f1)
TREE_SHA=$("$SCRIPT_DIR/release-build-provenance.py" prepared-id --work-dir "$OPENWRT")
PREPARE_INPUT_SHA=$("$SCRIPT_DIR/release-build-provenance.py" prepare-input-id --build-dir "$BUILD" --board bpi-r4)
{
    echo 'board=bpi-r4'
    echo 'ui_mode=source'
    echo "ui_source=$UI"
    echo 'release_bound=1'
    echo "input_lock_path=$LOCK"
    "$SCRIPT_DIR/release-build-provenance.py" lock-metadata --lock "$LOCK" --board bpi-r4 \
        | sed 's/^release=/release_id=/'
    echo "prepared_tree_sha256=$TREE_SHA"
    echo "prepare_inputs_sha256=$PREPARE_INPUT_SHA"
} >"$MARKER"

check_prepared() {
    "$SCRIPT_DIR/check-release-prepared.sh" --board bpi-r4 --lock "$LOCK"
}
check_prepared >/dev/null
ok "matching repositories, lock and prepared tree accepted"

# A copied canonical lock is accepted, but bytes invented elsewhere are not.
# This directly exercises the shared formal consumer gate rather than only the
# generator's output-path check.
HAND_LOCK="$TMP/hand-written-input.lock.json"
python3 - "$LOCK" "$HAND_LOCK" <<'PY'
import json, pathlib, sys
source, target = map(pathlib.Path, sys.argv[1:])
data = json.loads(source.read_text())
data["manual_nonce"] = "not-canonical"
target.write_text(json.dumps(data, indent=2) + "\n")
PY
expect_fail "hand-written noncanonical formal input lock" \
    "$PIPELINE_SCRIPTS/collect-release-artifacts.sh" \
    --release v1.4.9-rc999 --input-lock "$HAND_LOCK" --downloads-lock "$DOWNLOADS_LOCK" \
    --board openwrt-one --output-root "$TMP/hand-written-collection"
grep -Fq 'differs from the canonical release lock' "$TMP/negative.log" \
    || fail "formal consumer did not identify the canonical byte mismatch"
[ ! -e "$TMP/hand-written-collection" ] \
    || fail "noncanonical input lock created a collection directory"

# Real formal entry points must reject a genuine generator-shaped test-only
# lock for its own canonical pathname. Each assertion checks the rejection
# reason so a later unrelated failure cannot hide removal of this gate.
TEST_ONLY_RELEASE=v1.5.1-rc999
TEST_ONLY_DLOCK="$TMP/TEST-ONLY-DOWNLOADS.lock.json"
cat >"$TEST_ONLY_DLOCK" <<JSON
{
  "schema": 1,
  "release": "v1.5.1-rc999",
  "boards": $PRODUCT_BOARDS_JSON,
  "objects": []
}
JSON
TEST_ONLY_CANONICAL="$BUILD/dist/RELEASE-INPUTS.$TEST_ONLY_RELEASE.lock.json"
TEST_ONLY_LOCK="$TMP/TEST-ONLY-RELEASE-INPUTS.lock.json"
python3 - "$LOCK" "$TEST_ONLY_CANONICAL" "$TEST_ONLY_DLOCK" "$TEST_ONLY_RELEASE" <<'PY'
import hashlib, json, pathlib, sys
source, target, downloads = map(pathlib.Path, sys.argv[1:4])
release = sys.argv[4]
data = json.loads(source.read_text())
data["release"] = release
data["test_only"] = True
data["downloads_lock_sha256"] = hashlib.sha256(downloads.read_bytes()).hexdigest()
target.write_text(json.dumps(data, indent=2) + "\n")
PY
cp "$TEST_ONLY_CANONICAL" "$TEST_ONLY_LOCK"

cp "$MARKER" "$TMP/marker-before-test-only"
expect_test_only_refusal "prepare" "$PIPELINE_SCRIPTS/prepare.sh" \
    --board bpi-r4 --ui-source "$UI" --release-lock "$TEST_ONLY_LOCK"
cmp -s "$MARKER" "$TMP/marker-before-test-only" \
    || fail "test-only prepare changed the prepared marker"
expect_test_only_refusal "build" "$PIPELINE_SCRIPTS/build-full.sh" \
    --board bpi-r4 --jobs 1 --release-lock "$TEST_ONLY_LOCK"
[ ! -e "$OPENWRT/.observed-ui-package-version" ] \
    || fail "test-only build reached make"
expect_test_only_refusal "collector" "$PIPELINE_SCRIPTS/collect-release-artifacts.sh" \
    --release "$TEST_ONLY_RELEASE" --input-lock "$TEST_ONLY_LOCK" \
    --downloads-lock "$TEST_ONLY_DLOCK" --board openwrt-one \
    --output-root "$TMP/test-only-collection"
[ ! -e "$TMP/test-only-collection" ] \
    || fail "test-only collector created its output root"

TEST_ONLY_SHA=$(sha256sum "$TEST_ONLY_LOCK" | cut -d' ' -f1)
TEST_ONLY_BOUT="$TMP/test-only-manifest/$TEST_ONLY_RELEASE/${TEST_ONLY_SHA:0:12}"
mkdir -p "$TEST_ONLY_BOUT"
printf '{}\n' >"$TEST_ONLY_BOUT/BUILD-INPUTS.json"
cp "$TEST_ONLY_LOCK" "$TEST_ONLY_BOUT/RELEASE-INPUTS.lock.json"
printf 'reference\n' >"$TMP/test-only-linux-firmware.tar"
expect_test_only_refusal "formal manifest" "$MANIFEST_UNDER_TEST" \
    --release "$TEST_ONLY_RELEASE" --build-output "$TEST_ONLY_BOUT" \
    --input-lock "$TEST_ONLY_LOCK" --downloads-lock "$TEST_ONLY_DLOCK" \
    --linux-firmware "$TMP/test-only-linux-firmware.tar" \
    --output "$TMP/test-only-manifest.json"
[ ! -e "$TMP/test-only-manifest.json" ] \
    || fail "test-only formal manifest published output"
[ ! -e "$(dirname "$TEST_ONLY_BOUT")/.collection.lock" ] \
    || fail "test-only formal manifest created the release collection lock"

printf '{}\n' >"$TMP/test-only-firmware-manifest.json"
# Parsing this placeholder must never precede the release-authority refusal.
printf 'unparsed artifact fixture\n' >"$TMP/test-only-ui.apk"
expect_test_only_refusal "source bundle" "$PIPELINE_SCRIPTS/release-source-bundle.sh" \
    --release "$TEST_ONLY_RELEASE" --input-lock "$TEST_ONLY_LOCK" \
    --downloads-lock "$TEST_ONLY_DLOCK" \
    --firmware-manifest "$TMP/test-only-firmware-manifest.json" \
    --ui-artifact "$TMP/test-only-ui.apk" \
    --output "$TMP/test-only-source-bundle"
[ ! -e "$TMP/test-only-source-bundle" ] \
    || fail "test-only source bundle published output"
ok "all formal consumers share the canonical/test-only authority boundary"

# The classifier is shared by clean, sidecar, collector and policy inference.
# Exercise the real naming shapes, especially OpenWrt One's initramfs.itb.
while IFS=$'\t' read -r base file role; do
    got=$("$SCRIPT_DIR/release-build-provenance.py" classify --base "$base" --file "$file")
    [ "$got" = "$role" ] || fail "$file classified as $got, expected $role"
done <<'EOF'
openwrt-mediatek-filogic-bananapi_bpi-r4	openwrt-mediatek-filogic-bananapi_bpi-r4-initramfs-kernel.bin	initramfs
openwrt-mediatek-filogic-bananapi_bpi-r4-lite	openwrt-mediatek-filogic-bananapi_bpi-r4-lite-sdcard.img.gz	sdcard
openwrt-mediatek-filogic-bananapi_bpi-r4-pro-8x	openwrt-mediatek-filogic-bananapi_bpi-r4-pro-8x-emmc-bl31-uboot.fip	bootloader
openwrt-mediatek-filogic-bananapi_bpi-r3	openwrt-mediatek-filogic-bananapi_bpi-r3-squashfs-sysupgrade.itb	sysupgrade
openwrt-mediatek-filogic-bananapi_bpi-r3-mini	openwrt-mediatek-filogic-bananapi_bpi-r3-mini-snand-factory.bin	factory
openwrt-mediatek-filogic-openwrt_one	openwrt-mediatek-filogic-openwrt_one-initramfs.itb	initramfs
openwrt-mediatek-filogic-openwrt_one	openwrt-mediatek-filogic-openwrt_one-flashkit.tar.gz	flashkit
openwrt-mediatek-filogic-openwrt_one	mt7981-ram-ddr4-bl2.bin	bootloader
EOF
ok "six-board real artifact naming shapes classified"

source "$SCRIPT_DIR/boards.sh"
for contract_board in $VALID_BOARDS; do
    board_init "$contract_board"
    while IFS= read -r contract_file; do
        [ -n "$contract_file" ] || continue
        "$SCRIPT_DIR/release-build-provenance.py" classify \
            --base "$RELEASE_BASE" --file "$contract_file" >/dev/null \
            || fail "$contract_board required artifact is not classified: $contract_file"
    done <<<"$RELEASE_REQUIRED_FILES"
done
ok "every exact six-board release artifact is covered by the shared classifier"

# The formal coordinator holds one descriptor across prepare -> build. Prove a
# child can verify and reuse that inherited descriptor without deadlocking or
# opening a different inode.
INHERITED_LOCK_OK="$TMP/inherited-lock-ok"
(
    export BPIR_LOCK_HELPER="$SCRIPT_DIR/lib/openwrt-build-lock.sh"
    export BPIR_LOCK_WORK_DIR="$OPENWRT"
    export INHERITED_LOCK_OK
    source "$BPIR_LOCK_HELPER"
    bpir_acquire_openwrt_build_lock "$BPIR_LOCK_WORK_DIR"
    bash -c 'source "$BPIR_LOCK_HELPER"; bpir_acquire_openwrt_build_lock "$BPIR_LOCK_WORK_DIR"; : >"$INHERITED_LOCK_OK"'
) &
INHERITED_PID=$!
BG_PIDS="$INHERITED_PID"
for _ in $(seq 1 100); do
    [ -e "$INHERITED_LOCK_OK" ] && break
    kill -0 "$INHERITED_PID" 2>/dev/null || break
    sleep 0.05
done
[ -e "$INHERITED_LOCK_OK" ] || fail "inherited OpenWrt lock descriptor deadlocked or named another inode"
wait "$INHERITED_PID" || fail "inherited OpenWrt lock descriptor test failed"
BG_PIDS=""
ok "coordinator lock descriptor inherited across child process"
expect_fail "release source build without explicit lock" \
    "$PIPELINE_SCRIPTS/build-full.sh" --board bpi-r4 --jobs 1

mutate_repo() {
    local name="$1" repo="$2" file="$3"
    cp "$repo/$file" "$TMP/$name.backup"
    printf 'drift\n' >>"$repo/$file"
    expect_fail "$name drift" check_prepared
    cp "$TMP/$name.backup" "$repo/$file"
    [ -z "$(git -C "$repo" status --porcelain)" ] || fail "$name mutation was not restored"
}
mutate_repo ui "$UI" source.txt
mutate_repo feeds "$FEEDS" package.txt
mutate_repo build "$BUILD" feeds.conf

cp "$OPENWRT/source.txt" "$TMP/openwrt.backup"
printf 'drift\n' >>"$OPENWRT/source.txt"
expect_fail "prepared OpenWrt tree drift" check_prepared
cp "$TMP/openwrt.backup" "$OPENWRT/source.txt"
[ "$("$SCRIPT_DIR/release-build-provenance.py" prepared-id --work-dir "$OPENWRT")" = "$TREE_SHA" ] \
    || fail "OpenWrt mutation was not restored"

cp "$MARKER" "$TMP/marker.backup"
python3 - "$MARKER" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
p.write_text(p.read_text().replace("input_lock_sha256=", "input_lock_sha256=" + "0" * 64 + "#", 1))
PY
expect_fail "marker from another lock" check_prepared
cp "$TMP/marker.backup" "$MARKER"

# Run the real build-full wiring against a tiny fake OpenWrt make. Use another
# checkout of the locked UI commit to prove source mode does not rely on a
# sibling feeds repository: build-full must pass the actual feed_dir explicitly.
ALT_UI="$ROOT/alternate-ui"
git clone -q "$UI" "$ALT_UI"
printf 'CONFIG_TARGET_mediatek_filogic_DEVICE_openwrt_one=y\nCONFIG_PACKAGE_bpirouter-ui=y\n' >"$OPENWRT/.config"
TREE_SHA=$("$SCRIPT_DIR/release-build-provenance.py" prepared-id --work-dir "$OPENWRT")
PREPARE_INPUT_SHA=$("$SCRIPT_DIR/release-build-provenance.py" prepare-input-id --build-dir "$BUILD" --board openwrt-one)
{
    echo 'board=openwrt-one'
    echo 'ui_mode=source'
    echo "ui_source=$ALT_UI"
    echo 'release_bound=1'
    echo "input_lock_path=$LOCK"
    "$SCRIPT_DIR/release-build-provenance.py" lock-metadata --lock "$LOCK" --board openwrt-one \
        | sed 's/^release=/release_id=/'
    echo "prepared_tree_sha256=$TREE_SHA"
    echo "prepare_inputs_sha256=$PREPARE_INPUT_SHA"
} >"$MARKER"

TARGET_DIR="$OPENWRT/bin/targets/mediatek/filogic"
BASE=openwrt-mediatek-filogic-openwrt_one
SIDECAR="$TARGET_DIR/.bpirouter-build-openwrt-one.json"
mkdir -p "$TARGET_DIR"
printf 'stale-initramfs\n' >"$TARGET_DIR/$BASE-initramfs.itb"
printf 'stale-bootloader\n' >"$TARGET_DIR/$BASE-emmc-preloader.bin"
printf 'stale-target-ram-bl2\n' >"$TARGET_DIR/mt7981-ram-ddr4-bl2.bin"
OLD_BL2="$OPENWRT/build_dir/target-old/arm-trusted-firmware-mediatek-mt7981-ram-ddr4/old/build/mt7981/release/bl2.bin"
mkdir -p "$(dirname "$OLD_BL2")"
printf 'old-build-dir-ram-bl2\n' >"$OLD_BL2"
expect_fail "formal build with only stale build_dir RAM BL2" env SKIP_RAMBL2=1 \
    "$PIPELINE_SCRIPTS/build-full.sh" --board openwrt-one --jobs 1 --release-lock "$LOCK"
[ ! -e "$TARGET_DIR/mt7981-ram-ddr4-bl2.bin" ] \
    || fail "release clean or make-flashkit reused a stale target RAM BL2"
[ ! -e "$SIDECAR" ] || fail "missing current-build RAM BL2 left a release sidecar"
rm -f "$OLD_BL2"
ok "stale build_dir RAM BL2 was rejected instead of entering provenance"

RAM_STAMP="$OPENWRT/build_dir/target-test/arm-trusted-firmware-mediatek-mt7981-ram-ddr4/source/.pkgdir/trusted-firmware-a-mt7981-ram-ddr4.installed"
OTHER_RAM_STAMP="$OPENWRT/build_dir/target-test/arm-trusted-firmware-mediatek-mt7981-ram-ddr3/source/.pkgdir/trusted-firmware-a-mt7981-ram-ddr3.installed"
mkdir -p "$(dirname "$RAM_STAMP")" "$(dirname "$OTHER_RAM_STAMP")"
touch "$RAM_STAMP" "$OTHER_RAM_STAMP"
for attempt in 1 2; do
    env SKIP_INITRAMFS=1 "$PIPELINE_SCRIPTS/build-full.sh" --board openwrt-one --jobs 1 --release-lock "$LOCK" \
        >"$TMP/repeated-build.log" 2>&1 || { cat "$TMP/repeated-build.log"; fail "RAM BL2 reinstall failed on attempt $attempt"; }
    [ "$(cat "$TARGET_DIR/mt7981-ram-ddr4-bl2.bin")" = current-ram-bl2 ] \
        || fail "repeat build did not reinstall RAM BL2"
    [ -f "$RAM_STAMP" ] || fail "RAM BL2 install did not recreate its stamp"
    [ -f "$OTHER_RAM_STAMP" ] || fail "repeat build invalidated an unrelated DDR variant"
done
ok "consecutive formal builds reinstall RAM BL2 without invalidating other DDR variants"

env SKIP_INITRAMFS=1 "$PIPELINE_SCRIPTS/build-full.sh" --board openwrt-one --jobs 1 --release-lock "$LOCK" \
    >"$TMP/fake-build.log" 2>&1 || { cat "$TMP/fake-build.log"; fail "fake formal build failed"; }
[ "$(cat "$OPENWRT/.observed-ui-package-version")" = 1.4.9_rc999 ] \
    || fail "formal build did not inject the APK-compatible release version into make"

[ ! -e "$TARGET_DIR/$BASE-initramfs.itb" ] || fail "stale OpenWrt One initramfs survived release build start"
[ ! -e "$TARGET_DIR/$BASE-emmc-preloader.bin" ] || fail "stale bootloader survived release build start"
[ -f "$FEEDS/net/bpirouter-ui/files/.manifest" ] || fail "alternate UI checkout did not sync to the actual feed"
"$SCRIPT_DIR/release-build-provenance.py" verify \
    --lock "$LOCK" --release v1.4.9-rc999 --board openwrt-one \
    --profile openwrt_one --target mediatek/filogic --base "$BASE" \
    --source-dir "$TARGET_DIR" --sidecar "$SIDECAR" >/dev/null
EXPECTED_BUNDLE=$("$ALT_UI/scripts/acceptance-bundle.sh" --sha "$ALT_UI/scripts")
[ "$(jq -r '.ui.acceptance_bundle_sha256' "$SIDECAR")" = "$EXPECTED_BUNDLE" ] \
    || fail "source-mode build provenance does not record the acceptance tool bundle identity"
python3 - "$SIDECAR" "$BASE" <<'PY' || fail "stale pre-build artifacts entered the sidecar"
import json, sys
d = json.load(open(sys.argv[1]))
base = sys.argv[2]
files = {item["file"] for item in d["artifacts"]}
expected = {
    "mt7981-ram-ddr4-bl2.bin",
    base + "-factory.ubi",
    base + "-flashkit.tar.gz",
    base + "-nor-bl31-uboot.fip",
    base + "-nor-factory.bin",
    base + "-nor-preloader.bin",
    base + "-ram-bl31-uboot.fip",
    base + "-snand-bl31-uboot.fip",
    base + "-snand-factory.bin",
    base + "-snand-preloader.bin",
    base + "-squashfs-sysupgrade.itb",
    base + ".manifest",
}
assert files == expected, (files - expected, expected - files)
assert base + "-initramfs.itb" not in files
assert base + "-emmc-preloader.bin" not in files
assert d["ui"]["mode"] == "source"
assert d["ui"]["payload_sha256"] and d["ui"]["payload_inventory_sha256"] and d["ui"]["apid_sha256"]
PY
FLASHKIT_LIST="$TMP/openwrt-one-flashkit.list"
tar -tzf "$TARGET_DIR/$BASE-flashkit.tar.gz" >"$FLASHKIT_LIST"
for member in ram-ddr4-bl2.bin snand-uboot.fip snand-factory.bin snand-factory.crc \
              mtk_uartboot mtk_uartboot-v0.1.1-src.tar.gz \
              LICENSE-mtk_uartboot-AGPL-3.0.txt NOTICE-mtk_uartboot.txt \
              RUNBOOK-openwrt-one.md SHA256SUMS; do
    grep -Fxq "flashkit-openwrt-one/$member" "$FLASHKIT_LIST" \
        || fail "formal OpenWrt One flashkit is missing $member"
done
ok "real build wiring excluded stale outputs and bound the actual UI payload"
ok "formal flashkit contains provisioning inputs, tool, source, licence and runbook"

# A coarse bootloader role used to let unrelated eMMC files hide the absence of
# R3 Mini's actual SNAND provisioning FIP. The flashkit itself must fail too,
# rather than warning and allowing build-full to continue.
R3MINI_BASE=openwrt-mediatek-filogic-bananapi_bpi-r3-mini
rm -f "$TARGET_DIR/$R3MINI_BASE-snand-bl31-uboot.fip"
printf 'r3mini-ram-bl2\n' >"$TARGET_DIR/mt7986-ram-ddr4-bl2.bin"
printf 'r3mini-factory\n' >"$TARGET_DIR/$R3MINI_BASE-snand-factory.bin"
expect_fail "R3 Mini flashkit without SNAND FIP" \
    "$SCRIPT_DIR/make-flashkit.sh" --board bpi-r3-mini
rm -f "$TARGET_DIR/mt7986-ram-ddr4-bl2.bin" "$TARGET_DIR/$R3MINI_BASE-snand-factory.bin"
ok "R3 Mini missing provisioning FIP is fatal before release provenance"

# build-full holds the lock while make is paused. A controlled flock wrapper
# emits an event at the exact pre-lock boundary, so this assertion does not
# depend on how quickly prepare reaches that point on a loaded CI worker.
BUILD_HELD="$TMP/build-lock-held"
LOCK_RELEASE_FILE="$TMP/build-lock-release"
PREPARE_ENTERED="$TMP/prepare-entered-mutation-domain"
env BUILD_LOCK_HELD_FILE="$BUILD_HELD" BUILD_LOCK_RELEASE_FILE="$LOCK_RELEASE_FILE" \
    "$PIPELINE_SCRIPTS/build-full.sh" --board openwrt-one --jobs 1 --release-lock "$LOCK" \
    >"$TMP/concurrent-build.log" 2>&1 &
BUILD_PID=$!
BG_PIDS="$BUILD_PID"
for _ in $(seq 1 100); do
    [ -e "$BUILD_HELD" ] && break
    kill -0 "$BUILD_PID" 2>/dev/null || { cat "$TMP/concurrent-build.log"; fail "locking build exited early"; }
    sleep 0.05
done
[ -e "$BUILD_HELD" ] || fail "locking build never reached the controlled make point"

REAL_FLOCK=$(command -v flock)
FLOCK_WRAPPER="$TMP/flock-wrapper"
mkdir -p "$FLOCK_WRAPPER"
cat >"$FLOCK_WRAPPER/flock" <<'SH'
#!/bin/bash
[ -z "${BPIR_TEST_BEFORE_FLOCK:-}" ] || : >"$BPIR_TEST_BEFORE_FLOCK"
exec "$BPIR_TEST_REAL_FLOCK" "$@"
SH
chmod +x "$FLOCK_WRAPPER/flock"

PREPARE_READY="$TMP/prepare-ready-before-flock"
env BPIR_TEST_REAL_FLOCK="$REAL_FLOCK" BPIR_TEST_BEFORE_FLOCK="$PREPARE_READY" \
    BPIR_TEST_AFTER_OPENWRT_LOCK="$PREPARE_ENTERED" PATH="$FLOCK_WRAPPER:$PATH" \
    "$PIPELINE_SCRIPTS/prepare.sh" --board openwrt-one --ui-source "$ALT_UI" --release-lock "$LOCK" \
    >"$TMP/concurrent-prepare.log" 2>&1 &
PREPARE_PID=$!
BG_PIDS="$BUILD_PID $PREPARE_PID"
for _ in $(seq 1 400); do
    [ -e "$PREPARE_READY" ] && break
    kill -0 "$PREPARE_PID" 2>/dev/null || { cat "$TMP/concurrent-prepare.log"; fail "concurrent prepare exited before the pre-lock event"; }
    sleep 0.05
done
[ -e "$PREPARE_READY" ] || fail "prepare never reached the controlled pre-lock event"
kill -0 "$PREPARE_PID" 2>/dev/null || { cat "$TMP/concurrent-prepare.log"; fail "prepare did not block in flock"; }
[ ! -e "$PREPARE_ENTERED" ] || fail "prepare entered the mutation domain while build held the lock"

# Single-point mutation: remove only prepare's lock acquisition. While the real
# prepare is blocked at flock, the mutant must reach the post-lock probe without
# producing the pre-lock wrapper event. This proves the test fails for the exact
# regression it is intended to guard, independent of wall-clock timing.
MUTANT_SCRIPTS="$TMP/mutant-scripts"
cp -a "$SCRIPT_DIR" "$MUTANT_SCRIPTS"
python3 - "$MUTANT_SCRIPTS/prepare.sh" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
text = p.read_text()
line = 'bpir_acquire_openwrt_build_lock "$WORK_DIR" || fail "cannot acquire the OpenWrt build lock"'
assert text.count(line) == 1
p.write_text(text.replace(line, ': # mutation: lock acquisition removed'))
PY
MUTANT_READY="$TMP/mutant-ready-before-flock"
MUTANT_ENTERED="$TMP/mutant-entered-mutation-domain"
env BPIR_RELEASE_LOCK="$LOCK" BPIR_TEST_REAL_FLOCK="$REAL_FLOCK" BPIR_TEST_BEFORE_FLOCK="$MUTANT_READY" \
    BPIR_TEST_AFTER_OPENWRT_LOCK="$MUTANT_ENTERED" PATH="$FLOCK_WRAPPER:$PATH" \
    "$MUTANT_SCRIPTS/prepare.sh" --board openwrt-one --ui-source "$ALT_UI" \
    >"$TMP/mutant-prepare.log" 2>&1 &
MUTANT_PID=$!
BG_PIDS="$BUILD_PID $PREPARE_PID $MUTANT_PID"
for _ in $(seq 1 400); do
    [ -e "$MUTANT_ENTERED" ] && break
    kill -0 "$MUTANT_PID" 2>/dev/null || break
    sleep 0.05
done
[ -e "$MUTANT_ENTERED" ] || { cat "$TMP/mutant-prepare.log"; fail "deleted-lock mutation did not expose the mutation domain"; }
[ ! -e "$MUTANT_READY" ] || fail "deleted-lock mutation unexpectedly called flock"
if wait "$MUTANT_PID"; then
    fail "deleted-lock mutation unexpectedly reported a successful prepare"
else
    MUTANT_RC=$?
fi
[ "$MUTANT_RC" -eq 99 ] || { cat "$TMP/mutant-prepare.log"; fail "deleted-lock mutation exited $MUTANT_RC, expected 99"; }
BG_PIDS="$BUILD_PID $PREPARE_PID"

touch "$LOCK_RELEASE_FILE"
wait "$BUILD_PID" || { cat "$TMP/concurrent-build.log"; fail "locking build failed after release"; }
if wait "$PREPARE_PID"; then
    fail "prepare lock probe unexpectedly reported a successful prepare"
else
    PREPARE_RC=$?
fi
[ "$PREPARE_RC" -eq 99 ] || { cat "$TMP/concurrent-prepare.log"; fail "prepare lock probe exited $PREPARE_RC, expected 99"; }
BG_PIDS=""
LOCK_RELEASE_FILE=""
[ -e "$PREPARE_ENTERED" ] || fail "prepare did not enter after the build released the lock"
python3 - "$SIDECAR" "$BASE-initramfs.itb" <<'PY' || fail "OpenWrt One initramfs is absent from sidecar roles"
import json, sys
items = {item["file"]: item["role"] for item in json.load(open(sys.argv[1]))["artifacts"]}
assert items.get(sys.argv[2]) == "initramfs", items
PY
ok "event-synchronised prepare exclusion and deleted-lock mutation behaved correctly"
ok "OpenWrt One initramfs entered provenance"

printf 'unknown-profile-output\n' >"$TARGET_DIR/$BASE-mystery.bin"
expect_fail "unclassified current-profile output" \
    "$SCRIPT_DIR/release-build-provenance.py" clean --source-dir "$TARGET_DIR" --base "$BASE"
rm -f "$TARGET_DIR/$BASE-mystery.bin"

# A gitignored feed edit must invalidate sidecar creation even when every
# repository commit still matches the lock.
cp "$FEEDS/net/bpirouter-ui/files/bpirouter-apid" "$TMP/apid.backup"
printf 'ignored-payload-drift\n' >>"$FEEDS/net/bpirouter-ui/files/bpirouter-apid"
expect_fail "ignored UI payload drift" \
    "$SCRIPT_DIR/release-build-provenance.py" write \
    --lock "$LOCK" --board openwrt-one --profile openwrt_one \
    --target mediatek/filogic --base "$BASE" --source-dir "$TARGET_DIR" \
    --work-dir "$OPENWRT" \
    --marker "$MARKER" --ui-proof "$TARGET_DIR/.bpirouter-ui-openwrt-one.json" \
    --feed-files "$FEEDS/net/bpirouter-ui/files" --output "$TMP/invalid-sidecar.json"
cp "$TMP/apid.backup" "$FEEDS/net/bpirouter-ui/files/bpirouter-apid"

ARTIFACT_FEED="$TMP/artifact-feed"
mkdir -p "$ARTIFACT_FEED/www"
printf 'artifact-apid\n' >"$ARTIFACT_FEED/bpirouter-apid"
printf '<html>artifact</html>\n' >"$ARTIFACT_FEED/www/index.html"
ARTIFACT_SOURCE_SHA=$(printf 'artifact-source\n' | sha256sum | cut -d' ' -f1)
ARTIFACT_CONTENT_SHA=$(printf 'artifact-content\n' | sha256sum | cut -d' ' -f1)
ARTIFACT_APID_SHA=$(sha256sum "$ARTIFACT_FEED/bpirouter-apid" | cut -d' ' -f1)
ARTIFACT_INDEX_SHA=$(sha256sum "$ARTIFACT_FEED/www/index.html" | cut -d' ' -f1)
printf 'BPIR-PAYLOAD|1\nT|/www/bpirouter\nT|/usr/share/bpirouter\nF|755|%s|%s|/usr/bin/bpirouter-apid\nF|644|%s|%s|/www/bpirouter/index.html\n' \
    "$(wc -c <"$ARTIFACT_FEED/bpirouter-apid" | tr -d ' ')" "$ARTIFACT_APID_SHA" \
    "$(wc -c <"$ARTIFACT_FEED/www/index.html" | tr -d ' ')" "$ARTIFACT_INDEX_SHA" \
    | LC_ALL=C sort >"$ARTIFACT_FEED/.payload-inventory"
ARTIFACT_INVENTORY_SHA=$(sha256sum "$ARTIFACT_FEED/.payload-inventory" | cut -d' ' -f1)
printf 'src %s\nart %s\ninventory %s\n' "$ARTIFACT_SOURCE_SHA" "$ARTIFACT_CONTENT_SHA" \
    "$ARTIFACT_INVENTORY_SHA" >"$ARTIFACT_FEED/.manifest"
ARTIFACT_PAYLOAD_SHA=$("$SCRIPT_DIR/release-build-provenance.py" payload-id --feed-files "$ARTIFACT_FEED")
ARTIFACT_SHA=$(printf 'locked-artifact\n' | sha256sum | cut -d' ' -f1)
"$SCRIPT_DIR/release-build-provenance.py" ui-proof \
    --mode artifact --feed-files "$ARTIFACT_FEED" --artifact-sha256 "$ARTIFACT_SHA" \
    --expected-payload-sha256 "$ARTIFACT_PAYLOAD_SHA" --expected-apid-sha256 "$ARTIFACT_APID_SHA" \
    --output "$TMP/artifact-ui-proof.json"
python3 - "$TMP/artifact-ui-proof.json" "$ARTIFACT_SOURCE_SHA" "$ARTIFACT_CONTENT_SHA" "$ARTIFACT_INVENTORY_SHA" <<'PY' \
    || fail "artifact UI proof omitted runtime-verifiable manifest identities"
import json, sys
proof = json.load(open(sys.argv[1]))
assert proof["source_sha256"] == sys.argv[2]
assert proof["manifest_artifact_sha256"] == sys.argv[3]
assert proof["payload_inventory_sha256"] == sys.argv[4]
PY
cp "$ARTIFACT_FEED/.manifest" "$TMP/artifact-manifest.backup"
sed -i 's/^art .*/art ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff/' \
    "$ARTIFACT_FEED/.manifest"
expect_fail "artifact UI manifest edited after staging" \
    "$SCRIPT_DIR/release-build-provenance.py" ui-proof \
    --mode artifact --feed-files "$ARTIFACT_FEED" --artifact-sha256 "$ARTIFACT_SHA" \
    --expected-payload-sha256 "$ARTIFACT_PAYLOAD_SHA" --expected-apid-sha256 "$ARTIFACT_APID_SHA" \
    --output "$TMP/invalid-artifact-manifest-proof.json"
cp "$TMP/artifact-manifest.backup" "$ARTIFACT_FEED/.manifest"
printf 'post-stage-drift\n' >>"$ARTIFACT_FEED/www/index.html"
expect_fail "artifact UI payload edited after staging" \
    "$SCRIPT_DIR/release-build-provenance.py" ui-proof \
    --mode artifact --feed-files "$ARTIFACT_FEED" --artifact-sha256 "$ARTIFACT_SHA" \
    --expected-payload-sha256 "$ARTIFACT_PAYLOAD_SHA" --expected-apid-sha256 "$ARTIFACT_APID_SHA" \
    --output "$TMP/invalid-artifact-ui-proof.json"

REPLACED_DOWNLOADS_LOCK="$TMP/DOWNLOADS.replaced.lock.json"
python3 - "$DOWNLOADS_LOCK" "$REPLACED_DOWNLOADS_LOCK" <<'PY'
import json, sys
source, target = sys.argv[1:]
data = json.load(open(source))
data["objects"] = [{"path": "source-cache/replacement", "sha256": "0" * 64, "size": 0}]
json.dump(data, open(target, "w"), indent=2)
PY
expect_fail "collector same-release replacement downloads lock" \
    "$PIPELINE_SCRIPTS/collect-release-artifacts.sh" \
    --release v1.4.9-rc999 --input-lock "$LOCK" --downloads-lock "$REPLACED_DOWNLOADS_LOCK" \
    --board openwrt-one --output-root "$TMP/replaced-downloads"
WRONG_RELEASE_DOWNLOADS_LOCK="$TMP/DOWNLOADS.wrong-release.lock.json"
python3 - "$DOWNLOADS_LOCK" "$WRONG_RELEASE_DOWNLOADS_LOCK" <<'PY'
import json, sys
source, target = sys.argv[1:]
data = json.load(open(source))
data["release"] = "v1.5.1-rc999"
json.dump(data, open(target, "w"), indent=2)
PY
expect_fail "collector wrong-release downloads lock" \
    "$PIPELINE_SCRIPTS/collect-release-artifacts.sh" \
    --release v1.4.9-rc999 --input-lock "$LOCK" --downloads-lock "$WRONG_RELEASE_DOWNLOADS_LOCK" \
    --board openwrt-one --output-root "$TMP/wrong-release-downloads"

CONFLICTING_BATCH_ROOT="$TMP/conflicting-batch"
mkdir -p "$CONFLICTING_BATCH_ROOT/v1.4.9-rc999/ffffffffffff"
expect_fail "collector second input-lock batch for one release" \
    "$PIPELINE_SCRIPTS/collect-release-artifacts.sh" \
    --release v1.4.9-rc999 --input-lock "$LOCK" --downloads-lock "$DOWNLOADS_LOCK" \
    --board openwrt-one --output-root "$CONFLICTING_BATCH_ROOT"
[ ! -d "$CONFLICTING_BATCH_ROOT/v1.4.9-rc999/${LOCK_SHA:0:12}" ] \
    || fail "collector published a second batch for one release ID"

"$PIPELINE_SCRIPTS/collect-release-artifacts.sh" \
    --release v1.4.9-rc999 --input-lock "$LOCK" --downloads-lock "$DOWNLOADS_LOCK" \
    --board openwrt-one --output-root "$TMP/collected" >/dev/null
COLLECTED_EARLY=$(find "$TMP/collected/v1.4.9-rc999" -mindepth 1 -maxdepth 1 -type d | head -1)
[ -n "$COLLECTED_EARLY" ] && cmp -s "$LOCK" "$COLLECTED_EARLY/RELEASE-INPUTS.lock.json" \
    || fail "collector did not publish the exact input lock beside BUILD-INPUTS"
cp "$COLLECTED_EARLY/RELEASE-INPUTS.lock.json" "$TMP/collected-lock.backup"
printf '{"schema":1,"release":"wrong"}\n' >"$COLLECTED_EARLY/RELEASE-INPUTS.lock.json"
expect_fail "collector batch with replaced frozen input lock" \
    "$PIPELINE_SCRIPTS/collect-release-artifacts.sh" \
    --release v1.4.9-rc999 --input-lock "$LOCK" --downloads-lock "$DOWNLOADS_LOCK" \
    --board openwrt-one --output-root "$TMP/collected"
cp "$TMP/collected-lock.backup" "$COLLECTED_EARLY/RELEASE-INPUTS.lock.json"
chmod 666 "$COLLECTED_EARLY/RELEASE-INPUTS.lock.json"
expect_fail "collector batch with writable frozen input lock" \
    "$PIPELINE_SCRIPTS/collect-release-artifacts.sh" \
    --release v1.4.9-rc999 --input-lock "$LOCK" --downloads-lock "$DOWNLOADS_LOCK" \
    --board openwrt-one --output-root "$TMP/collected"
chmod 644 "$COLLECTED_EARLY/RELEASE-INPUTS.lock.json"
ok "collector accepted the matching build-time sidecar"

UNRELATED_UI="$TMP/unrelated-ui.apk"
printf 'not-the-built-ui\n' >"$UNRELATED_UI"
expect_fail "collector UI label unrelated to the sidecar" \
    "$PIPELINE_SCRIPTS/collect-release-artifacts.sh" \
    --release v1.4.9-rc999 --input-lock "$LOCK" --downloads-lock "$DOWNLOADS_LOCK" \
    --board openwrt-one --ui-artifact "$UNRELATED_UI" --output-root "$TMP/unrelated-ui-collection"

# Replace cp with a controlled wrapper that corrupts only the destination after
# copying. Pre-copy verification passes; the post-copy sidecar check must fail.
REAL_CP=$(command -v cp)
mkdir -p "$TMP/cp-wrapper"
cat >"$TMP/cp-wrapper/cp" <<'SH'
#!/bin/bash
"$REAL_CP" "$@"
destination="${!#}"
case "$destination" in *squashfs-sysupgrade.itb) printf 'copy-race\n' >>"$destination" ;; esac
SH
chmod +x "$TMP/cp-wrapper/cp"
expect_fail "verify/copy replacement" env REAL_CP="$REAL_CP" PATH="$TMP/cp-wrapper:$PATH" \
    "$PIPELINE_SCRIPTS/collect-release-artifacts.sh" \
    --release v1.4.9-rc999 --input-lock "$LOCK" --downloads-lock "$DOWNLOADS_LOCK" \
    --board openwrt-one --output-root "$TMP/copy-race-collection"

cp "$TARGET_DIR/$BASE-squashfs-sysupgrade.itb" "$TMP/artifact.backup"
printf 'stale-or-replaced\n' >>"$TARGET_DIR/$BASE-squashfs-sysupgrade.itb"
expect_fail "artifact changed after build" \
    "$SCRIPT_DIR/release-build-provenance.py" verify \
    --lock "$LOCK" --release v1.4.9-rc999 --board openwrt-one \
    --profile openwrt_one --target mediatek/filogic --base "$BASE" \
    --source-dir "$TARGET_DIR" --sidecar "$SIDECAR"
expect_fail "collector rejected artifact changed after build" \
    "$PIPELINE_SCRIPTS/collect-release-artifacts.sh" \
    --release v1.4.9-rc999 --input-lock "$LOCK" --downloads-lock "$DOWNLOADS_LOCK" \
    --board openwrt-one --output-root "$TMP/stale-collection"
cp "$TMP/artifact.backup" "$TARGET_DIR/$BASE-squashfs-sysupgrade.itb"

OTHER_LOCK="$TMP/OTHER-INPUTS.lock.json"
python3 - "$LOCK" "$OTHER_LOCK" <<'PY'
import json, pathlib, sys
source, target = map(pathlib.Path, sys.argv[1:])
data = json.loads(source.read_text())
data["release"] = "v1.5.1-rc999"
target.write_text(json.dumps(data, indent=2) + "\n")
PY
expect_fail "sidecar collected with another lock" \
    "$SCRIPT_DIR/release-build-provenance.py" verify \
    --lock "$OTHER_LOCK" --release v1.5.1-rc999 --board openwrt-one \
    --profile openwrt_one --target mediatek/filogic --base "$BASE" \
    --source-dir "$TARGET_DIR" --sidecar "$SIDECAR"
expect_fail "collector rejected another lock" \
    "$PIPELINE_SCRIPTS/collect-release-artifacts.sh" \
    --release v1.5.1-rc999 --input-lock "$OTHER_LOCK" --downloads-lock "$DOWNLOADS_LOCK" \
    --board openwrt-one --output-root "$TMP/other-collection"

# Formal manifest creation must reject the one-board collection because the
# lock names all six product boards. It must fail before touching firmware data.
COLLECTED=$(find "$TMP/collected/v1.4.9-rc999" -mindepth 1 -maxdepth 1 -type d | head -1)
printf 'not-a-tar\n' >"$TMP/linux-firmware.tar"

manifest_partial_must_fail() {
    local name="$1" output="$2"
    expect_fail "$name" "$MANIFEST_UNDER_TEST" \
        --release v1.4.9-rc999 --build-output "$output" --input-lock "$LOCK" \
        --downloads-lock "$DOWNLOADS_LOCK" --linux-firmware "$TMP/linux-firmware.tar" \
        --allow-partial-development --output "$TMP/mutated-manifest.json"
}

MANIFEST_CONFLICT_DIR="$(dirname "$COLLECTED")/eeeeeeeeeeee"
mkdir -p "$MANIFEST_CONFLICT_DIR"
manifest_partial_must_fail "manifest second input-lock batch for one release" "$COLLECTED"
grep -Fq 'contains another input-lock batch' "$TMP/negative.log" \
    || fail "manifest did not reject a sibling input-lock batch"
rmdir "$MANIFEST_CONFLICT_DIR"

LOCK_DRIFT_OUTPUT="$TMP/frozen-lock-drift-output"
cp -a "$COLLECTED" "$LOCK_DRIFT_OUTPUT"
printf '{"schema":1,"release":"wrong"}\n' >"$LOCK_DRIFT_OUTPUT/RELEASE-INPUTS.lock.json"
manifest_partial_must_fail "manifest replaced frozen input lock" "$LOCK_DRIFT_OUTPUT"
grep -Fq 'frozen input lock differs' "$TMP/negative.log" \
    || fail "manifest frozen-lock mutation did not fail at the lock binding"

ROLE_RELABEL_OUTPUT="$TMP/role-relabel-output"
cp -a "$COLLECTED" "$ROLE_RELABEL_OUTPUT"
python3 - "$ROLE_RELABEL_OUTPUT/BUILD-INPUTS.json" <<'PY'
import json, pathlib, sys
p = pathlib.Path(sys.argv[1]); data = json.loads(p.read_text())
data["boards"]["openwrt-one"]["artifacts"][0]["role"] = "metadata"
p.write_text(json.dumps(data, indent=2) + "\n")
PY
manifest_partial_must_fail "manifest outer role relabel" "$ROLE_RELABEL_OUTPUT"
grep -Eq 'do not exactly match|classifier requires' "$TMP/negative.log" \
    || fail "manifest role relabel did not fail at sidecar/classifier binding"

ROLE_SWAP_OUTPUT="$TMP/role-swap-output"
cp -a "$COLLECTED" "$ROLE_SWAP_OUTPUT"
python3 - "$ROLE_SWAP_OUTPUT/BUILD-INPUTS.json" <<'PY'
import json, pathlib, sys
p = pathlib.Path(sys.argv[1]); data = json.loads(p.read_text())
items = data["boards"]["openwrt-one"]["artifacts"]
left, right = next((a, b) for a in items for b in items if a["role"] != b["role"])
left["role"], right["role"] = right["role"], left["role"]
p.write_text(json.dumps(data, indent=2) + "\n")
PY
manifest_partial_must_fail "manifest outer role swap" "$ROLE_SWAP_OUTPUT"

CLASSIFIER_RELABEL_OUTPUT="$TMP/classifier-relabel-output"
cp -a "$COLLECTED" "$CLASSIFIER_RELABEL_OUTPUT"
python3 - "$CLASSIFIER_RELABEL_OUTPUT/BUILD-INPUTS.json" <<'PY'
import json, pathlib, sys
p = pathlib.Path(sys.argv[1]); data = json.loads(p.read_text())
info = data["boards"]["openwrt-one"]
outer = next(item for item in info["artifacts"] if item["file"].endswith("-nor-factory.bin"))
inner = next(item for item in info["build_provenance"]["artifacts"] if item["file"] == outer["file"])
outer["role"] = inner["role"] = "bootloader"
p.write_text(json.dumps(data, indent=2) + "\n")
PY
manifest_partial_must_fail "manifest outer and sidecar role relabel" "$CLASSIFIER_RELABEL_OUTPUT"
grep -q 'classifier requires' "$TMP/negative.log" \
    || fail "manifest did not independently classify a consistently relabelled role"

FACTORY_AS_BOOT_OUTPUT="$TMP/factory-as-boot-output"
cp -a "$COLLECTED" "$FACTORY_AS_BOOT_OUTPUT"
python3 - "$FACTORY_AS_BOOT_OUTPUT" <<'PY'
import json, pathlib, sys
root = pathlib.Path(sys.argv[1]); p = root / "BUILD-INPUTS.json"
data = json.loads(p.read_text()); info = data["boards"]["openwrt-one"]
kept = []
for item in info["artifacts"]:
    if item["role"] == "bootloader":
        (root / item["path"]).unlink()
    else:
        kept.append(item)
factory = next(item for item in kept if item["file"].endswith("-nor-factory.bin"))
factory["role"] = "bootloader"
info["artifacts"] = kept
p.write_text(json.dumps(data, indent=2) + "\n")
PY
manifest_partial_must_fail "manifest factory relabel after deleting bootloaders" "$FACTORY_AS_BOOT_OUTPUT"
ok "manifest reclassified outer roles and rebound them to the embedded sidecar"

# Formal mode authenticates the checkout containing the gate before boards.sh
# or the classifier is loaded. Exercise both ways that contract code can drift:
# an uncommitted edit in the locked checkout and a clean checkout at another
# commit. The partial-development path remains intentionally non-release.
cp "$BUILD/scripts/boards.sh" "$TMP/gate-boards.backup"
printf '\n# dirty release-gate mutation\n' >>"$BUILD/scripts/boards.sh"
expect_fail "formal manifest with dirty release-gate checkout" \
    "$MANIFEST_UNDER_TEST" \
    --release v1.4.9-rc999 --build-output "$COLLECTED" --input-lock "$LOCK" \
    --downloads-lock "$DOWNLOADS_LOCK" --linux-firmware "$TMP/linux-firmware.tar" \
    --output "$TMP/dirty-gate-manifest.json"
grep -q 'bpirouter-build has uncommitted changes' "$TMP/negative.log" \
    || fail "dirty gate did not fail at the pre-contract workspace binding"
cp "$TMP/gate-boards.backup" "$BUILD/scripts/boards.sh"
[ -z "$(git -C "$BUILD" status --porcelain)" ] || fail "dirty gate mutation was not restored"

OTHER_BUILD="$TMP/other-build-checkout"
git clone -q "$BUILD" "$OTHER_BUILD"
git -C "$OTHER_BUILD" config user.name provenance-test
git -C "$OTHER_BUILD" config user.email provenance-test@example.invalid
printf 'different gate commit\n' >"$OTHER_BUILD/gate-version.txt"
git -C "$OTHER_BUILD" add gate-version.txt
git -C "$OTHER_BUILD" commit -qm 'different gate commit'

# prepare, build and collection must authenticate their own script checkout,
# not the different checkout named by BPIR_BUILD_DIR. All three refusals occur
# before a marker, sidecar or collection directory can be produced.
CROSS_OPENWRT="$TMP/cross-checkout-openwrt"
expect_fail "formal prepare executed from another checkout" env \
    BPIR_BUILD_DIR="$BUILD" BPIR_WORK_DIR="$CROSS_OPENWRT" \
    "$OTHER_BUILD/scripts/prepare.sh" --board openwrt-one --ui-source "$UI" --release-lock "$LOCK"
grep -q 'BPIR_BUILD_DIR must name the checkout containing the executing scripts' "$TMP/negative.log" \
    || fail "cross-checkout prepare did not fail at script identity binding"
[ ! -e "$CROSS_OPENWRT/.bpirouter-prepared-board" ] \
    || fail "cross-checkout prepare produced a marker"

SIDECAR_BEFORE=$(sha256sum "$SIDECAR" | cut -d' ' -f1)
expect_fail "formal build executed from another checkout" env \
    BPIR_BUILD_DIR="$BUILD" "$OTHER_BUILD/scripts/build-full.sh" \
    --board openwrt-one --jobs 1 --release-lock "$LOCK"
grep -q 'BPIR_BUILD_DIR must name the checkout containing the executing scripts' "$TMP/negative.log" \
    || fail "cross-checkout build did not fail at script identity binding"
[ "$(sha256sum "$SIDECAR" | cut -d' ' -f1)" = "$SIDECAR_BEFORE" ] \
    || fail "cross-checkout build replaced the locked sidecar"

CROSS_COLLECTION="$TMP/cross-checkout-collection"
expect_fail "formal collector executed from another checkout" env \
    BPIR_BUILD_DIR="$BUILD" "$OTHER_BUILD/scripts/collect-release-artifacts.sh" \
    --release v1.4.9-rc999 --input-lock "$LOCK" --downloads-lock "$DOWNLOADS_LOCK" \
    --board openwrt-one --output-root "$CROSS_COLLECTION"
grep -q 'BPIR_BUILD_DIR must name the checkout containing the executing scripts' "$TMP/negative.log" \
    || fail "cross-checkout collector did not fail at script identity binding"
[ ! -e "$CROSS_COLLECTION" ] || fail "cross-checkout collector created release output"
ok "prepare, build and collector bound their actual script checkout to the input lock"

expect_fail "formal manifest with BPIR_BUILD_DIR redirected to another checkout" env \
    BPIR_BUILD_DIR="$OTHER_BUILD" "$MANIFEST_UNDER_TEST" \
    --release v1.4.9-rc999 --build-output "$COLLECTED" --input-lock "$LOCK" \
    --downloads-lock "$DOWNLOADS_LOCK" --linux-firmware "$TMP/linux-firmware.tar" \
    --output "$TMP/redirected-gate-manifest.json"
grep -q 'BPIR_BUILD_DIR must name the checkout containing the executing scripts' "$TMP/negative.log" \
    || fail "BPIR_BUILD_DIR redirected the formal gate authentication"

expect_fail "formal manifest from another build commit" \
    env BPIR_BUILD_DIR="$OTHER_BUILD" "$OTHER_BUILD/scripts/make-firmware-manifest.sh" \
    --release v1.4.9-rc999 --build-output "$COLLECTED" --input-lock "$LOCK" \
    --downloads-lock "$DOWNLOADS_LOCK" --linux-firmware "$TMP/linux-firmware.tar" \
    --output "$TMP/other-gate-manifest.json"
grep -q 'bpirouter-build is at .* lock says' "$TMP/negative.log" \
    || fail "other gate commit did not fail at the pre-contract workspace binding"
ok "formal manifest bound its actual clean gate checkout to the input lock"

# The checkout can drift after the first workspace check. Pause at the exact
# post-snapshot event, mutate each long-lived contract consumer in turn, and
# require a gate-specific failure with no manifest publication.
manifest_gate_drift() {
    local label="$1" rel="$2"
    local ready="$TMP/${label}-gate-ready" release_file="$TMP/${label}-gate-release"
    local output="$TMP/${label}-gate-manifest.json" log="$TMP/${label}-gate.log"
    local backup="$TMP/${label}-gate.backup" pid rc
    cp "$BUILD/scripts/$rel" "$backup"
    rm -f "$ready" "$release_file" "$output"
    env BPIR_TEST_MANIFEST_GATE_READY="$ready" \
        BPIR_TEST_MANIFEST_GATE_RELEASE="$release_file" \
        "$MANIFEST_UNDER_TEST" \
        --release v1.4.9-rc999 --build-output "$COLLECTED" --input-lock "$LOCK" \
        --downloads-lock "$DOWNLOADS_LOCK" --linux-firmware "$TMP/linux-firmware.tar" \
        --output "$output" >"$log" 2>&1 &
    pid=$!
    BG_PIDS="$pid"
    for _ in $(seq 1 200); do
        [ -e "$ready" ] && break
        kill -0 "$pid" 2>/dev/null || { cat "$log"; fail "$label manifest exited before the gate event"; }
        sleep 0.05
    done
    [ -e "$ready" ] || { cat "$log"; fail "$label manifest never reached the gate event"; }
    printf '\n# post-entry %s mutation\n' "$label" >>"$BUILD/scripts/$rel"
    touch "$release_file"
    if wait "$pid"; then
        cp "$backup" "$BUILD/scripts/$rel"
        fail "$label post-entry mutation was accepted"
    else
        rc=$?
    fi
    BG_PIDS=""
    [ "$rc" -ne 0 ] || fail "$label post-entry mutation returned success"
    grep -q 'release-gate files changed after the initial workspace check' "$log" \
        || { cat "$log"; cp "$backup" "$BUILD/scripts/$rel"; fail "$label drift did not fail at the post-entry gate"; }
    [ ! -e "$output" ] || { cp "$backup" "$BUILD/scripts/$rel"; fail "$label drift left a formal manifest"; }
    cp "$backup" "$BUILD/scripts/$rel"
    [ -z "$(git -C "$BUILD" status --porcelain)" ] \
        || fail "$label gate mutation was not exactly restored"
    ok "$label post-entry mutation refused before manifest publication"
}
manifest_gate_drift classifier release-build-provenance.py
manifest_gate_drift policy check-firmware-policy.sh
# The policy script's R4-Pro judgement lives in the rootfs gate, not in itself.
# It is gate code for the same reason and must fail the same way.
manifest_gate_drift rootfs-policy check-as21xxx-rootfs.sh
manifest_gate_drift 4e-rootfs-policy check-4e-rootfs.sh

# Build a tiny, valid partial-development collection whose sole artifact is
# metadata. It exercises the complete snapshot -> policy -> temporary manifest
# -> live revalidation -> atomic publication path without pretending that the
# synthetic bytes satisfy the six-board formal artifact contract.
FAKE_DUMPIMAGE="$OPENWRT/build_dir/host/u-boot-test/tools/dumpimage"
mkdir -p "$(dirname "$FAKE_DUMPIMAGE")"
cat >"$FAKE_DUMPIMAGE" <<'SH'
#!/bin/sh
exit 1
SH
chmod +x "$FAKE_DUMPIMAGE"

EVIDENCE_FW_ROOT="$TMP/evidence-fw-root/linux-firmware-test/aeonsemi"
mkdir -p "$EVIDENCE_FW_ROOT"
printf 'synthetic-reference-firmware\n' >"$EVIDENCE_FW_ROOT/as21x1x_fw.bin"
EVIDENCE_LFW="$TMP/linux-firmware-evidence.tar"
tar -cf "$EVIDENCE_LFW" -C "$TMP/evidence-fw-root" linux-firmware-test
EVIDENCE_DLOCK="$TMP/EVIDENCE-DOWNLOADS.lock.json"
python3 - "$EVIDENCE_DLOCK" "$EVIDENCE_LFW" <<'PY'
import hashlib, json, os, pathlib, sys
out, archive = map(pathlib.Path, sys.argv[1:])
json.dump({"schema": 1, "release": "v1.4.9-rc999",
           "boards": json.loads(os.environ["PRODUCT_BOARDS_JSON"]),
           "objects": [{"path": archive.name,
                          "sha256": hashlib.sha256(archive.read_bytes()).hexdigest()}]},
          open(out, "w"), indent=2)
PY
EVIDENCE_ILOCK="$TMP/EVIDENCE-RELEASE-INPUTS.lock.json"
python3 - "$LOCK" "$EVIDENCE_ILOCK" "$EVIDENCE_DLOCK" <<'PY'
import hashlib, json, pathlib, sys
source, target, downloads = map(pathlib.Path, sys.argv[1:])
data = json.loads(source.read_text())
data["downloads_lock_sha256"] = hashlib.sha256(downloads.read_bytes()).hexdigest()
data["test_only"] = True
target.write_text(json.dumps(data, indent=2) + "\n")
PY

EVIDENCE_BOUT="$TMP/evidence-build-output"
EVIDENCE_ARTIFACT="$EVIDENCE_BOUT/openwrt-one/$BASE.manifest"
mkdir -p "$(dirname "$EVIDENCE_ARTIFACT")"
cp "$EVIDENCE_ILOCK" "$EVIDENCE_BOUT/RELEASE-INPUTS.lock.json"
printf 'synthetic package manifest\n' >"$EVIDENCE_ARTIFACT"
python3 - "$EVIDENCE_BOUT/BUILD-INPUTS.json" "$EVIDENCE_ILOCK" "$EVIDENCE_DLOCK" \
    "$EVIDENCE_ARTIFACT" "$BASE" <<'PY'
import hashlib, json, pathlib, sys
out, lock, downloads, artifact, base = sys.argv[1:]
lock, downloads, artifact = map(pathlib.Path, (lock, downloads, artifact))
sha = lambda path: hashlib.sha256(path.read_bytes()).hexdigest()
item = {"file": artifact.name, "role": "metadata",
        "sha256": sha(artifact), "size": artifact.stat().st_size}
provenance = {
    "schema": 2, "release": "v1.4.9-rc999", "board": "openwrt-one",
    "profile": "openwrt_one", "target": "mediatek/filogic", "base": base,
    "input_lock_sha256": sha(lock), "ui_mode": "none", "ui": {"mode": "none"},
    "artifacts": [item],
}
outer = dict(item)
outer["path"] = "openwrt-one/" + artifact.name
json.dump({
    "schema": 1, "release": "v1.4.9-rc999",
    "input_lock_sha256": sha(lock), "downloads_lock_sha256": sha(downloads),
    "ui_identity": {"mode": "none"}, "ui_artifact_sha256": None,
    "boards": {"openwrt-one": {"profile": "openwrt_one",
                                  "build_provenance": provenance,
                                  "artifacts": [outer]}},
}, open(out, "w"), indent=2)
PY

# The package policy must reject the actual collected manifest even when its
# hashes and embedded provenance are internally consistent. This synthetic
# case makes that refusal executable without claiming a formal image exists.
EVIDENCE_MBIM_BOUT="$TMP/mbim-evidence-build-output"
cp -a "$EVIDENCE_BOUT" "$EVIDENCE_MBIM_BOUT"
python3 - "$EVIDENCE_MBIM_BOUT/BUILD-INPUTS.json" \
    "$EVIDENCE_MBIM_BOUT/openwrt-one/$BASE.manifest" <<'PY'
import hashlib, json, pathlib, sys
inputs, artifact = map(pathlib.Path, sys.argv[1:])
with artifact.open("a") as f:
    f.write("umbim - 2025.05.11-r1\n")
data = json.loads(inputs.read_text())
content = artifact.read_bytes()
sha, size = hashlib.sha256(content).hexdigest(), len(content)
board = data["boards"]["openwrt-one"]
for item in board["artifacts"]:
    if item["file"] == artifact.name:
        item["sha256"], item["size"] = sha, size
for item in board["build_provenance"]["artifacts"]:
    if item["file"] == artifact.name:
        item["sha256"], item["size"] = sha, size
inputs.write_text(json.dumps(data, indent=2) + "\n")
PY
expect_fail "formal manifest with unsupported MBIM package" \
    "$MANIFEST_UNDER_TEST" \
    --release v1.4.9-rc999 --build-output "$EVIDENCE_MBIM_BOUT" --input-lock "$EVIDENCE_ILOCK" \
    --downloads-lock "$EVIDENCE_DLOCK" --linux-firmware "$EVIDENCE_LFW" \
    --allow-partial-development --output "$TMP/mbim-evidence-manifest.json"
grep -q 'package manifest contains unsupported umbim' "$TMP/negative.log" \
    || fail "unsupported MBIM package did not reach the formal package policy gate"

manifest_evidence_drift() {
    local label="$1" target="$2" expected="$3"
    local ready="$TMP/${label}-policy-ready" release_file="$TMP/${label}-policy-release"
    local output="$TMP/${label}-evidence-manifest.json" log="$TMP/${label}-evidence.log"
    local backup="$TMP/${label}-evidence.backup" pid rc
    cp "$target" "$backup"
    rm -f "$ready" "$release_file" "$output"
    env BPIR_TEST_MANIFEST_POLICY_READY="$ready" \
        BPIR_TEST_MANIFEST_POLICY_RELEASE="$release_file" \
        "$MANIFEST_UNDER_TEST" \
        --release v1.4.9-rc999 --build-output "$EVIDENCE_BOUT" --input-lock "$EVIDENCE_ILOCK" \
        --downloads-lock "$EVIDENCE_DLOCK" --linux-firmware "$EVIDENCE_LFW" \
        --allow-partial-development --output "$output" >"$log" 2>&1 &
    pid=$!
    BG_PIDS="$pid"
    for _ in $(seq 1 200); do
        [ -e "$ready" ] && break
        kill -0 "$pid" 2>/dev/null || { cat "$log"; fail "$label manifest exited before policy completed"; }
        sleep 0.05
    done
    [ -e "$ready" ] || { cat "$log"; fail "$label manifest never reached the post-policy event"; }
    printf 'post-policy-%s-drift\n' "$label" >>"$target"
    touch "$release_file"
    if wait "$pid"; then
        cp "$backup" "$target"
        fail "$label post-policy mutation was accepted"
    else
        rc=$?
    fi
    BG_PIDS=""
    [ "$rc" -ne 0 ] || fail "$label post-policy mutation returned success"
    grep -q "$expected" "$log" \
        || { cat "$log"; cp "$backup" "$target"; fail "$label mutation did not fail at live evidence revalidation"; }
    [ ! -e "$output" ] || { cp "$backup" "$target"; fail "$label mutation published a manifest"; }
    cp "$backup" "$target"
    ok "$label post-policy mutation refused before manifest publication"
}
manifest_evidence_drift metadata "$EVIDENCE_BOUT/BUILD-INPUTS.json" 'BUILD-INPUTS.json changed'
manifest_evidence_drift frozen-lock "$EVIDENCE_BOUT/RELEASE-INPUTS.lock.json" 'frozen input lock changed'
manifest_evidence_drift artifact "$EVIDENCE_ARTIFACT" 'collected artifact set changed'
manifest_evidence_drift reference "$EVIDENCE_LFW" 'linux-firmware reference changed'

EVIDENCE_MANIFEST="$TMP/evidence-positive-manifest.json"
EVIDENCE_LOCK_READY="$TMP/evidence-collection-lock-ready"
EVIDENCE_LOCK_RELEASE="$TMP/evidence-collection-lock-release"
EVIDENCE_POSITIVE_LOG="$TMP/evidence-positive.log"
env BPIR_TEST_MANIFEST_COLLECTION_LOCK_READY="$EVIDENCE_LOCK_READY" \
    BPIR_TEST_MANIFEST_COLLECTION_LOCK_RELEASE="$EVIDENCE_LOCK_RELEASE" \
    "$MANIFEST_UNDER_TEST" \
    --release v1.4.9-rc999 --build-output "$EVIDENCE_BOUT" --input-lock "$EVIDENCE_ILOCK" \
    --downloads-lock "$EVIDENCE_DLOCK" --linux-firmware "$EVIDENCE_LFW" \
    --allow-partial-development --output "$EVIDENCE_MANIFEST" \
    >"$EVIDENCE_POSITIVE_LOG" 2>&1 &
EVIDENCE_PID=$!
BG_PIDS="$EVIDENCE_PID"
for _ in $(seq 1 200); do
    [ -e "$EVIDENCE_LOCK_READY" ] && break
    kill -0 "$EVIDENCE_PID" 2>/dev/null \
        || { cat "$EVIDENCE_POSITIVE_LOG"; fail "positive manifest exited before acquiring the collection lock"; }
    sleep 0.05
done
[ -e "$EVIDENCE_LOCK_READY" ] \
    || { cat "$EVIDENCE_POSITIVE_LOG"; fail "positive manifest never acquired the collection lock"; }
EVIDENCE_COLLECTION_LOCK="$TMP/.collection.lock"
if flock -n "$EVIDENCE_COLLECTION_LOCK" -c true; then
    fail "manifest did not hold the collector's collection lock"
fi
touch "$EVIDENCE_LOCK_RELEASE"
wait "$EVIDENCE_PID" \
    || { cat "$EVIDENCE_POSITIVE_LOG"; fail "positive frozen-evidence manifest failed"; }
BG_PIDS=""
[ "$(stat -c '%a' "$EVIDENCE_MANIFEST")" = 644 ] \
    || fail "atomically published manifest is not mode 0644"
python3 - "$EVIDENCE_MANIFEST" <<'PY' || fail "positive evidence manifest has the wrong release boundary"
import json, sys
d = json.load(open(sys.argv[1]))
assert d["release_eligible"] is False and d["development_partial"] is True
assert len(d["images"]) == 1 and d["images"][0]["role"] == "metadata"
PY
ok "manifest held the collector lock and published a mode-0644 frozen-evidence manifest"

expect_fail "formal manifest with five missing boards" \
    "$MANIFEST_UNDER_TEST" \
    --release v1.4.9-rc999 --build-output "$COLLECTED" --input-lock "$LOCK" \
    --downloads-lock "$DOWNLOADS_LOCK" --linux-firmware "$TMP/linux-firmware.tar" \
    --output "$TMP/formal-manifest.json"
grep -q 'formal release is missing locked boards' "$TMP/negative.log" \
    || fail "manifest failed before the exact board-set gate"

# A caller must not make the same partial directory look formal by trimming the
# lock itself to one board. Release locks generated by this product name all six
# supported boards; a smaller lock is development-only even when internally
# self-consistent.
SINGLE_LOCK="$TMP/SINGLE-BOARD.lock.json"
SINGLE_STAGE="$TMP/single-board-stage"
cp -a "$COLLECTED" "$SINGLE_STAGE"
python3 - "$LOCK" "$SINGLE_LOCK" "$SINGLE_STAGE/BUILD-INPUTS.json" <<'PY'
import hashlib, json, pathlib, sys
source, target, inputs_path = map(pathlib.Path, sys.argv[1:])
lock = json.loads(source.read_text())
lock["boards"] = ["openwrt-one"]
target.write_text(json.dumps(lock, indent=2) + "\n")
inputs = json.loads(inputs_path.read_text())
inputs["input_lock_sha256"] = hashlib.sha256(target.read_bytes()).hexdigest()
inputs_path.write_text(json.dumps(inputs, indent=2) + "\n")
PY
SINGLE_OUTPUT="$TMP/single-board-output/v1.4.9-rc999/$(sha256sum "$SINGLE_LOCK" | cut -c1-12)"
mkdir -p "$(dirname "$SINGLE_OUTPUT")"
mv "$SINGLE_STAGE" "$SINGLE_OUTPUT"
cp "$SINGLE_LOCK" "$SINGLE_OUTPUT/RELEASE-INPUTS.lock.json"
expect_fail "formal manifest with a trimmed one-board lock" \
    "$MANIFEST_UNDER_TEST" \
    --release v1.4.9-rc999 --build-output "$SINGLE_OUTPUT" --input-lock "$SINGLE_LOCK" \
    --downloads-lock "$DOWNLOADS_LOCK" --linux-firmware "$TMP/linux-firmware.tar" \
    --output "$TMP/single-board-manifest.json"
grep -Eq 'formal release lock must name exactly the six supported boards|input lock must name exactly' "$TMP/negative.log" \
    || fail "manifest did not reject the trimmed formal lock at the six-board gate"

EXACT_FILE_SPEC=""
for exact_board in $VALID_BOARDS; do
    board_init "$exact_board"
    exact_files=$(printf '%s\n' "$RELEASE_REQUIRED_FILES" | awk '
        NF { printf "%s%s", separator, $0; separator=" " }
        END { print "" }
    ')
    EXACT_FILE_SPEC+="$exact_board=$exact_files"$'\n'
done

make_exact_gate_inputs() {
    local output="$1" mode="$2"
    mkdir -p "$output"
    cp "$LOCK" "$output/RELEASE-INPUTS.lock.json"
    python3 - "$output/BUILD-INPUTS.json" "$LOCK" "$DOWNLOADS_LOCK" "$mode" \
        "$EXACT_FILE_SPEC" <<'PY'
import hashlib, json, pathlib, sys
out, lock_path, downloads_path = map(pathlib.Path, sys.argv[1:4])
mode, spec = sys.argv[4:6]
required = dict(line.split("=", 1) for line in spec.splitlines())
boards = {}
for board, names in required.items():
    files = names.split()
    if mode == "metadata-only":
        files = [name for name in files if name.endswith(".manifest")]
    elif mode == "r3-mini-no-snand-fip" and board == "bpi-r3-mini":
        files = [name for name in files if not name.endswith("-snand-bl31-uboot.fip")]
    elif mode == "openwrt-one-no-factory-ubi" and board == "openwrt-one":
        files = [name for name in files if not name.endswith("-factory.ubi")]
    boards[board] = {
        "profile": "test",
        "artifacts": [
            {"file": name, "path": "%s/%s" % (board, name),
             "role": "metadata", "sha256": "0" * 64, "size": 0}
            for name in sorted(files)
        ],
    }
sha = lambda path: hashlib.sha256(path.read_bytes()).hexdigest()
json.dump({
    "schema": 1, "release": "v1.4.9-rc999",
    "input_lock_sha256": sha(lock_path),
    "downloads_lock_sha256": sha(downloads_path),
    "boards": boards,
}, open(out, "w"), indent=2)
PY
}

MISSING_R3MINI_FIP_OUTPUT="$TMP/missing-r3mini-fip-output/v1.4.9-rc999/${LOCK_SHA:0:12}"
make_exact_gate_inputs "$MISSING_R3MINI_FIP_OUTPUT" r3-mini-no-snand-fip
expect_fail "formal manifest missing R3 Mini SNAND FIP" \
    "$MANIFEST_UNDER_TEST" \
    --release v1.4.9-rc999 --build-output "$MISSING_R3MINI_FIP_OUTPUT" --input-lock "$LOCK" \
    --downloads-lock "$DOWNLOADS_LOCK" --linux-firmware "$TMP/linux-firmware.tar" \
    --output "$TMP/missing-r3mini-fip-manifest.json"
grep -q 'bpi-r3-mini is missing required artifacts: .*snand-bl31-uboot.fip' "$TMP/negative.log" \
    || fail "R3 Mini exact SNAND FIP gate accepted substitute bootloaders"

MISSING_ONE_FACTORY_OUTPUT="$TMP/missing-one-factory-output/v1.4.9-rc999/${LOCK_SHA:0:12}"
make_exact_gate_inputs "$MISSING_ONE_FACTORY_OUTPUT" openwrt-one-no-factory-ubi
expect_fail "formal manifest missing OpenWrt One primary factory.ubi" \
    "$MANIFEST_UNDER_TEST" \
    --release v1.4.9-rc999 --build-output "$MISSING_ONE_FACTORY_OUTPUT" --input-lock "$LOCK" \
    --downloads-lock "$DOWNLOADS_LOCK" --linux-firmware "$TMP/linux-firmware.tar" \
    --output "$TMP/missing-one-factory-manifest.json"
grep -q 'openwrt-one is missing required artifacts: .*factory.ubi' "$TMP/negative.log" \
    || fail "OpenWrt One exact factory.ubi gate accepted NOR/SNAND substitutes"

METADATA_ONLY_OUTPUT="$TMP/metadata-only-output/v1.4.9-rc999/${LOCK_SHA:0:12}"
make_exact_gate_inputs "$METADATA_ONLY_OUTPUT" metadata-only
expect_fail "formal manifest with metadata-only six-board directories" \
    "$MANIFEST_UNDER_TEST" \
    --release v1.4.9-rc999 --build-output "$METADATA_ONLY_OUTPUT" --input-lock "$LOCK" \
    --downloads-lock "$DOWNLOADS_LOCK" --linux-firmware "$TMP/linux-firmware.tar" \
    --output "$TMP/metadata-only-manifest.json"
grep -q 'missing required artifacts' "$TMP/negative.log" \
    || fail "metadata-only set did not reach the per-board exact-artifact gate"

# Pre-candidate integration has an explicit non-release path. Exercise one board
# through the same coordinator: it must keep the batch lock, record full source
# identities and prepared-tree evidence, state its partial scope, ignore leaf
# path overrides, and leave no formal sidecars or inherited release package
# version behind.
DEV_REBUILD_OUT="$TMP/development-rebuild-output"
DEV_IMAGE_NAME="openwrt-mediatek-filogic-openwrt_one-squashfs-sysupgrade.itb"
mkdir -p "$DEV_REBUILD_OUT/openwrt-one"
printf 'stale-previous-build\n' >"$DEV_REBUILD_OUT/openwrt-one/$DEV_IMAGE_NAME"
cp "$MARKER" "$TMP/pre-development-marker"
BPIROUTER_UI_PKG_VERSION=9.9.9 \
    BPIROUTER_BUILD_TIME=1999-01-01T00:00:00Z BPIR_RELEASE_LOCK="$LOCK" \
    BPIR_BUILD_DIR="$TMP/ignored-build" BPIR_WORK_DIR="$TMP/ignored-openwrt" \
    BPIR_UI_DIR="$TMP/ignored-ui" BPIR_FEEDS_DIR="$TMP/ignored-feeds" \
    BPIR_CONFIG_DIR="$TMP/ignored-config" \
    BPIR_REBUILD_OUTPUT="$DEV_REBUILD_OUT" \
    "$PIPELINE_SCRIPTS/rebuild-all.sh" --development openwrt-one \
    >"$TMP/development-rebuild.log" 2>&1 \
    || {
        cat "$TMP/development-rebuild.log"
        find "$DEV_REBUILD_OUT" -type f \( -name '*.prepare.log' -o -name '*.build.log' \) \
            -exec sh -c 'echo "--- $1"; cat "$1"' _ {} \;
        fail "development rebuild failed"
    }
DEV_PROV=$(find "$DEV_REBUILD_OUT" -maxdepth 1 -type f -name 'provenance-*.tsv' -print)
[ -n "$DEV_PROV" ] && [ "$(printf '%s\n' "$DEV_PROV" | wc -l)" = 1 ] \
    || fail "development rebuild did not publish exactly one provenance record"
grep -Fxq '# schema=2' "$DEV_PROV" || fail "development provenance schema is missing"
grep -Fxq '# mode=development' "$DEV_PROV" || fail "development provenance mode is missing"
grep -Fxq '# release_eligible=false' "$DEV_PROV" \
    || fail "development provenance claims release eligibility"
grep -Fxq '# requested_boards=openwrt-one' "$DEV_PROV" \
    || fail "development provenance does not record its requested board"
grep -Fxq '# scope=partial' "$DEV_PROV" \
    || fail "one-board development provenance claims six-board scope"
grep -Fxq '# batch_complete=true' "$DEV_PROV" \
    || fail "completed development provenance is not marked complete"
grep -Fxq '# batch_success=true' "$DEV_PROV" \
    || fail "successful development provenance is not marked successful"
grep -Eq '^# build_id=dev-[0-9a-f]{12}-[0-9a-f]{12}-[0-9a-f]{12}-[0-9a-f]{12}(-dirty)?$' \
    "$DEV_PROV" || fail "development provenance build ID is not commit-derived"
for item in "bpirouter-ui:$UI" "bpirouter-feeds:$FEEDS" \
            "bpirouter-build:$BUILD" "openwrt:$OPENWRT"; do
    label=${item%%:*}
    repo=${item#*:}
    grep -Fxq "# $label.commit=$(git -C "$repo" rev-parse HEAD)" "$DEV_PROV" \
        || fail "development provenance lacks the full $label commit"
    grep -Eq "^# $label.dirty=(true|false)$" "$DEV_PROV" \
        || fail "development provenance lacks the $label dirty state"
    [ "$label" = openwrt ] || grep -Eq "^# $label.fingerprint=[0-9a-f]{64}$" "$DEV_PROV" \
        || fail "development provenance lacks the $label content fingerprint"
done
awk -F '\t' '$1 == "openwrt-one" && $3 == "ok" && $4 ~ /^[0-9a-f]{64}$/ &&
        $5 ~ /^[0-9a-f]{16}$/ && $6 ~ /^[0-9a-f]{16}$/ &&
        $7 ~ /^[0-9a-f]{16}$/ && $8 ~ /^[0-9a-f]{16}$/ && $9 != "-" { found=1 }
    END { exit !found }' "$DEV_PROV" \
    || fail "development provenance lacks a complete successful artifact row"
DEV_IMAGE_REL=$(awk -F '\t' '$1 == "openwrt-one" && $3 == "ok" { print $9 }' "$DEV_PROV")
[ "$DEV_IMAGE_REL" = "openwrt-one/$DEV_IMAGE_NAME" ] \
    || fail "development provenance does not name the canonical board output image"
DEV_IMAGE="$DEV_REBUILD_OUT/$DEV_IMAGE_REL"
[ "$(cat "$DEV_IMAGE")" = current-build ] \
    || fail "development rebuild left a stale board output image"
DEV_IMAGE_SHA=$(sha256sum "$DEV_IMAGE" | cut -d' ' -f1)
DEV_RECORDED_SHA=$(awk -F '\t' '$1 == "openwrt-one" && $3 == "ok" { print $8 }' "$DEV_PROV")
[[ "$DEV_IMAGE_SHA" == "$DEV_RECORDED_SHA"* ]] \
    || fail "published development image does not match its provenance hash"
[ -z "$(find "$DEV_REBUILD_OUT/openwrt-one" -maxdepth 1 -type f -name '.image.*' -print)" ] \
    || fail "development image publication left a temporary file"
[ ! -e "$OPENWRT/bin/targets/mediatek/filogic/.bpirouter-build-openwrt-one.json" ] \
    || fail "development rebuild emitted a formal build sidecar"
[ ! -e "$OPENWRT/bin/targets/mediatek/filogic/.bpirouter-ui-openwrt-one.json" ] \
    || fail "development rebuild emitted a formal UI sidecar"
[ -z "$(cat "$OPENWRT/.observed-ui-package-version")" ] \
    || fail "development rebuild inherited a formal package version"
DEV_BUILD_LOG=$(find "$DEV_REBUILD_OUT" -type f -name 'openwrt-one.build.log' -print)
[ -n "$DEV_BUILD_LOG" ] || fail "development rebuild has no board build log"
DEV_BUILD_TIME=$(sed -n 's/^observed-ui-build-time=//p' "$DEV_BUILD_LOG" | head -1)
[[ "$DEV_BUILD_TIME" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(Z|[+-][0-9]{2}:[0-9]{2})$ ]] \
    || fail "development rebuild did not supply one valid UI build time"
[ "$DEV_BUILD_TIME" != 1999-01-01T00:00:00Z ] \
    || fail "development rebuild inherited a caller-supplied UI build time"

# A one-board fixture proves only that some timestamp was exported. Run two
# successful boards through one coordinator process so moving timestamp
# creation back into the board loop is caught without a real firmware build.
TWO_BOARD_OUT="$TMP/development-two-board-time-output"
DATE_WRAPPER="$TMP/two-board-date-wrapper"
DATE_STATE="$TMP/two-board-date-state"
REAL_DATE=$(command -v date)
mkdir -p "$DATE_WRAPPER"
cat >"$DATE_WRAPPER/date" <<'SH'
#!/bin/bash
set -eo pipefail
if [ "$#" = 1 ] && [ "$1" = -Iseconds ]; then
    count=0
    [ ! -f "$BPIR_TEST_DATE_STATE" ] || read -r count <"$BPIR_TEST_DATE_STATE"
    count=$((count + 1))
    printf '%s\n' "$count" >"$BPIR_TEST_DATE_STATE"
    printf '2026-08-25T00:00:%02dZ\n' "$count"
    exit 0
fi
exec "$BPIR_TEST_REAL_DATE" "$@"
SH
chmod +x "$DATE_WRAPPER/date"
BPIROUTER_BUILD_TIME=1999-01-01T00:00:00Z \
    BPIR_TEST_DATE_STATE="$DATE_STATE" BPIR_TEST_REAL_DATE="$REAL_DATE" \
    PATH="$DATE_WRAPPER:$PATH" \
    BPIR_REBUILD_OUTPUT="$TWO_BOARD_OUT" \
    "$PIPELINE_SCRIPTS/rebuild-all.sh" --development openwrt-one bpi-r3-mini \
    >"$TMP/development-two-board-time.log" 2>&1 \
    || {
        cat "$TMP/development-two-board-time.log"
        find "$TWO_BOARD_OUT" -type f \( -name '*.prepare.log' -o -name '*.build.log' \) \
            -exec sh -c 'echo "--- $1"; cat "$1"' _ {} \;
        fail "two-board timestamp rebuild failed"
    }
TWO_BOARD_PROV=$(find "$TWO_BOARD_OUT" -maxdepth 1 -type f -name 'provenance-*.tsv' -print)
[ -n "$TWO_BOARD_PROV" ] || fail "two-board timestamp rebuild has no provenance"
awk -F '\t' '$1 == "openwrt-one" && $3 == "ok" { one=1 }
               $1 == "bpi-r3-mini" && $3 == "ok" { mini=1 }
               END { exit !(one && mini) }' "$TWO_BOARD_PROV" \
    || fail "two-board timestamp rebuild did not complete both boards"
TWO_BOARD_TIMES="$TMP/development-two-board-times"
for board in openwrt-one bpi-r3-mini; do
    sed -n 's/^observed-ui-build-time=//p' \
        "$TWO_BOARD_OUT"/build-logs-*/"$board.build.log" >>"$TWO_BOARD_TIMES"
done
[ "$(wc -l <"$TWO_BOARD_TIMES" | tr -d ' ')" = 2 ] \
    || fail "two-board timestamp rebuild did not record both build times"
[ "$(LC_ALL=C sort -u "$TWO_BOARD_TIMES" | wc -l | tr -d ' ')" = 1 ] \
    || fail "one coordinator batch supplied different UI build times"
grep -Fxq '2026-08-25T00:00:01Z' "$TWO_BOARD_TIMES" \
    || fail "two-board timestamp rebuild did not retain the one pre-loop time"
ok "one coordinator timestamp is shared by two successful boards"

# A compiler exit status alone is not a successful integration build. Missing
# package evidence or a missing board-primary image must downgrade both the row
# and the batch even when the fake make target itself returned zero.
MISSING_APK_OUT="$TMP/development-missing-apk-output"
[ -f "$OPENWRT/bin/packages/aarch64_cortex-a53/bpirouter/bpirouter-ui-1.0.apk" ] \
    || fail "missing-APK fixture has no valid stale package to preserve"
expect_fail "development rebuild without a UI APK" env SKIP_APK=1 \
    BPIR_REBUILD_OUTPUT="$MISSING_APK_OUT" \
    "$PIPELINE_SCRIPTS/rebuild-all.sh" --development openwrt-one
MISSING_APK_PROV=$(find "$MISSING_APK_OUT" -maxdepth 1 -type f -name 'provenance-*.tsv' -print)
[ -n "$MISSING_APK_PROV" ] || fail "missing-APK batch did not publish diagnostics"
grep -Fxq '# batch_success=false' "$MISSING_APK_PROV" \
    || fail "missing-APK batch claimed success"
awk -F '\t' '$1 == "openwrt-one" && $3 == "fail" && $5 == "-" { found=1 }
    END { exit !found }' "$MISSING_APK_PROV" \
    || fail "missing-APK row was not downgraded"
grep -RFq 'missing or invalid bpirouter-ui APK' "$MISSING_APK_OUT"/build-logs-* \
    || fail "missing-APK failure did not identify the absent evidence"

MISSING_IMAGE_OUT="$TMP/development-missing-image-output"
printf 'valid-but-stale-primary-image\n' \
    >"$OPENWRT/bin/targets/mediatek/filogic/openwrt-mediatek-filogic-openwrt_one-squashfs-sysupgrade.itb"
expect_fail "development rebuild without a primary image" env SKIP_PRIMARY_IMAGE=1 \
    BPIR_REBUILD_OUTPUT="$MISSING_IMAGE_OUT" \
    "$PIPELINE_SCRIPTS/rebuild-all.sh" --development openwrt-one
MISSING_IMAGE_PROV=$(find "$MISSING_IMAGE_OUT" -maxdepth 1 -type f -name 'provenance-*.tsv' -print)
[ -n "$MISSING_IMAGE_PROV" ] || fail "missing-image batch did not publish diagnostics"
grep -Fxq '# batch_success=false' "$MISSING_IMAGE_PROV" \
    || fail "missing-image batch claimed success"
awk -F '\t' '$1 == "openwrt-one" && $3 == "fail" && $8 == "-" && $9 == "-" { found=1 }
    END { exit !found }' "$MISSING_IMAGE_PROV" \
    || fail "missing-image row was not downgraded"
grep -RFq 'missing or invalid primary image' "$MISSING_IMAGE_OUT"/build-logs-* \
    || fail "missing-image failure did not identify the absent evidence"

# Capture dirty contents, not merely HEAD and dirty=true/false. This mutation
# keeps the repository dirty throughout but changes what the batch consumed.
cp "$UI/source.txt" "$TMP/batch-ui-source.backup"
printf 'preexisting-dirty-input\n' >>"$UI/source.txt"
DRIFT_OUT="$TMP/development-input-drift-output"
expect_fail "development batch with source drift" env MUTATE_BATCH_UI=1 \
    BPIR_REBUILD_OUTPUT="$DRIFT_OUT" \
    "$PIPELINE_SCRIPTS/rebuild-all.sh" --development openwrt-one
cp "$TMP/batch-ui-source.backup" "$UI/source.txt"
DRIFT_PROV=$(find "$DRIFT_OUT" -maxdepth 1 -type f -name 'provenance-*.tsv' -print)
[ -n "$DRIFT_PROV" ] || fail "source-drift batch did not publish diagnostics"
grep -Fxq '# batch_success=false' "$DRIFT_PROV" \
    || fail "source-drift batch claimed success"
grep -Fxq '# bpirouter-ui.dirty=true' "$DRIFT_PROV" \
    || fail "source-drift fixture did not begin with an already-dirty repository"
grep -RFq 'bpirouter-ui input drifted after building openwrt-one' "$DRIFT_OUT"/build-logs-* \
    || fail "source-drift failure did not identify the changed repository"
ok "development artifact completeness and repository drift gates"

# The leaf full-build gate must also clear an inherited version when called
# directly against an unbound prepared tree, not only through rebuild-all.
BPIROUTER_UI_PKG_VERSION=9.9.9 \
    "$PIPELINE_SCRIPTS/build-full.sh" --board openwrt-one --jobs 1 \
    >"$TMP/development-build-full.log" 2>&1 \
    || { cat "$TMP/development-build-full.log"; fail "direct development full build failed"; }
[ -z "$(cat "$OPENWRT/.observed-ui-package-version")" ] \
    || fail "unbound full build inherited a formal package version"

cp "$OPENWRT/source.txt" "$TMP/development-source.backup"
expect_fail "development build-end prepared tree drift" env MUTATE_PREPARED=1 \
    "$PIPELINE_SCRIPTS/build-full.sh" --board openwrt-one --jobs 1
grep -Fq 'prepared OpenWrt tree drifted during build' "$TMP/negative.log" \
    || fail "development build did not fail at the prepared-tree boundary"
[ ! -e "$OPENWRT/bin/targets/mediatek/filogic/.bpirouter-build-openwrt-one.json" ] \
    || fail "failed development drift emitted a formal build sidecar"
cp "$TMP/development-source.backup" "$OPENWRT/source.txt"

expect_fail "rebuild-all mixed development/release modes" \
    "$PIPELINE_SCRIPTS/rebuild-all.sh" --development --release-lock "$LOCK" openwrt-one
grep -Fq -- '--development and --release-lock are mutually exclusive' "$TMP/negative.log" \
    || fail "rebuild-all mixed-mode refusal is not explicit"
expect_fail "rebuild-all without an explicit mode" \
    "$PIPELINE_SCRIPTS/rebuild-all.sh" openwrt-one
grep -Fq 'usage: rebuild-all.sh (--development | --release-lock <file>)' "$TMP/negative.log" \
    || fail "rebuild-all missing-mode refusal has the wrong usage"

# A development identity is evidence only if every repository can supply a
# complete commit and an inspectable worktree state. Never silently downgrade a
# missing repository to an "unknown" commit that looks like valid provenance.
mv "$UI/.git" "$TMP/development-ui.git"
expect_fail "development rebuild with an unidentifiable repository" env \
    BPIR_REBUILD_OUTPUT="$TMP/development-missing-git" \
    "$PIPELINE_SCRIPTS/rebuild-all.sh" --development openwrt-one
mv "$TMP/development-ui.git" "$UI/.git"
grep -Fq 'cannot identify bpirouter-ui Git commit' "$TMP/negative.log" \
    || fail "development rebuild did not identify the missing Git evidence"

# Git walks up to a parent repository. An ordinary build/openwrt directory must
# never be accepted as that parent checkout, because prepare's reset --hard
# would then erase tracked changes in bpirouter-build.
PLAIN_ROOT="$TMP/plain-openwrt-workspace"
mkdir -p "$PLAIN_ROOT"
git clone -q "$BUILD" "$PLAIN_ROOT/bpirouter-build"
git clone -q "$UI" "$PLAIN_ROOT/bpirouter-ui"
git clone -q "$FEEDS" "$PLAIN_ROOT/bpirouter-feeds"
mkdir -p "$PLAIN_ROOT/bpirouter-build/openwrt"
printf 'must-survive-invalid-openwrt\n' >>"$PLAIN_ROOT/bpirouter-build/config/common.config"
PLAIN_DIFF_BEFORE=$(git -C "$PLAIN_ROOT/bpirouter-build" diff --binary HEAD -- | sha256sum | cut -d' ' -f1)
expect_fail "coordinator with an ordinary nested OpenWrt directory" env \
    BPIR_REBUILD_OUTPUT="$TMP/plain-openwrt-output" \
    "$PLAIN_ROOT/bpirouter-build/scripts/rebuild-all.sh" --development openwrt-one
grep -Fq 'OpenWrt path exists but is not an exact OpenWrt checkout root' "$TMP/negative.log" \
    || fail "coordinator did not reject the ordinary nested OpenWrt directory at the root gate"
[ "$(git -C "$PLAIN_ROOT/bpirouter-build" diff --binary HEAD -- | sha256sum | cut -d' ' -f1)" = "$PLAIN_DIFF_BEFORE" ] \
    || fail "coordinator changed its parent build checkout while rejecting nested OpenWrt"
expect_fail "direct prepare with an ordinary nested OpenWrt directory" env \
    BPIR_BUILD_DIR="$PLAIN_ROOT/bpirouter-build" \
    BPIR_WORK_DIR="$PLAIN_ROOT/bpirouter-build/openwrt" \
    BPIR_FEEDS_DIR="$PLAIN_ROOT/bpirouter-feeds" \
    "$PLAIN_ROOT/bpirouter-build/scripts/prepare.sh" --development \
    --board openwrt-one --ui-source "$PLAIN_ROOT/bpirouter-ui"
grep -Fq 'OpenWrt path exists but is not an exact OpenWrt checkout root' "$TMP/negative.log" \
    || fail "direct prepare did not reject the ordinary nested OpenWrt directory at the root gate"
[ "$(git -C "$PLAIN_ROOT/bpirouter-build" diff --binary HEAD -- | sha256sum | cut -d' ' -f1)" = "$PLAIN_DIFF_BEFORE" ] \
    || fail "direct prepare reset its parent build checkout"

expect_fail "direct prepare with the build repository as BPIR_WORK_DIR" env \
    BPIR_BUILD_DIR="$PLAIN_ROOT/bpirouter-build" \
    BPIR_WORK_DIR="$PLAIN_ROOT/bpirouter-build" \
    BPIR_FEEDS_DIR="$PLAIN_ROOT/bpirouter-feeds" \
    "$PLAIN_ROOT/bpirouter-build/scripts/prepare.sh" --development \
    --board openwrt-one --ui-source "$PLAIN_ROOT/bpirouter-ui"
grep -Fq 'OpenWrt path exists but is not an exact OpenWrt checkout root' "$TMP/negative.log" \
    || fail "direct prepare accepted bpirouter-build itself as OpenWrt"
[ "$(git -C "$PLAIN_ROOT/bpirouter-build" diff --binary HEAD -- | sha256sum | cut -d' ' -f1)" = "$PLAIN_DIFF_BEFORE" ] \
    || fail "direct prepare reset the explicitly supplied build repository"

SYMLINK_ROOT="$TMP/symlink-openwrt-workspace"
mkdir -p "$SYMLINK_ROOT"
git clone -q "$BUILD" "$SYMLINK_ROOT/bpirouter-build"
git clone -q "$UI" "$SYMLINK_ROOT/bpirouter-ui"
git clone -q "$FEEDS" "$SYMLINK_ROOT/bpirouter-feeds"
ln -s . "$SYMLINK_ROOT/bpirouter-build/openwrt"
printf 'must-survive-symlink-openwrt\n' >>"$SYMLINK_ROOT/bpirouter-build/config/common.config"
SYMLINK_DIFF_BEFORE=$(git -C "$SYMLINK_ROOT/bpirouter-build" diff --binary HEAD -- | sha256sum | cut -d' ' -f1)
expect_fail "coordinator with OpenWrt symlinked to its build repository" env \
    BPIR_REBUILD_OUTPUT="$TMP/symlink-openwrt-output" \
    "$SYMLINK_ROOT/bpirouter-build/scripts/rebuild-all.sh" --development openwrt-one
grep -Fq 'OpenWrt path exists but is not an exact OpenWrt checkout root' "$TMP/negative.log" \
    || fail "coordinator accepted a symlink to bpirouter-build as OpenWrt"
[ "$(git -C "$SYMLINK_ROOT/bpirouter-build" diff --binary HEAD -- | sha256sum | cut -d' ' -f1)" = "$SYMLINK_DIFF_BEFORE" ] \
    || fail "coordinator reset the build repository through its OpenWrt symlink"
ok "invalid OpenWrt paths cannot reach project-repository reset"

# A stale development checkout must move to the configured baseline before its
# identity is recorded. This is the migration path used by a real workspace
# that retains build_dir and staging_dir between OpenWrt maintenance releases.
STALE_ROOT="$TMP/stale-openwrt-workspace"
mkdir -p "$STALE_ROOT"
git clone -q "$BUILD" "$STALE_ROOT/bpirouter-build"
git clone -q "$UI" "$STALE_ROOT/bpirouter-ui"
git clone -q "$FEEDS" "$STALE_ROOT/bpirouter-feeds"
git clone -q "$OPENWRT" "$STALE_ROOT/bpirouter-build/openwrt"
git -C "$STALE_ROOT/bpirouter-build/openwrt" checkout -q --detach v25.12.2
git -C "$STALE_ROOT/bpirouter-build/openwrt" tag -d v25.12.5 >/dev/null
mkdir -p "$STALE_ROOT/bpirouter-build/openwrt/target/linux/mediatek/filogic/base-files/etc/init.d" \
    "$STALE_ROOT/bpirouter-build/openwrt/target/linux/mediatek/filogic/base-files/etc/uci-defaults"
printf 'stale patch digest\n' >"$STALE_ROOT/bpirouter-build/openwrt/.bpirouter_kpatch.md5"
printf 'stale init payload\n' >"$STALE_ROOT/bpirouter-build/openwrt/target/linux/mediatek/filogic/base-files/etc/init.d/bpirouter-as21xxx-fw"
printf 'stale defaults payload\n' >"$STALE_ROOT/bpirouter-build/openwrt/target/linux/mediatek/filogic/base-files/etc/uci-defaults/99-bpirouter-as21xxx-fw"
STALE_OUT="$TMP/stale-openwrt-output"
BPIR_OPENWRT_CLONE_URL="$OPENWRT" BPIR_REBUILD_OUTPUT="$STALE_OUT" \
    "$STALE_ROOT/bpirouter-build/scripts/rebuild-all.sh" --development openwrt-one \
    >"$TMP/stale-openwrt.log" 2>&1 \
    || { cat "$TMP/stale-openwrt.log"; fail "development coordinator did not migrate a stale OpenWrt checkout"; }
[ "$(git -C "$STALE_ROOT/bpirouter-build/openwrt" rev-parse HEAD)" = "$BPIR_OPENWRT_GIT_COMMIT" ] \
    || fail "development coordinator left the stale OpenWrt checkout at its old baseline"
[ "$(git -C "$STALE_ROOT/bpirouter-build/openwrt" rev-parse 'v25.12.5^{commit}')" = "$BPIR_OPENWRT_GIT_COMMIT" ] \
    || fail "development coordinator did not retain the configured OpenWrt release tag"
STALE_PROV=$(find "$STALE_OUT" -maxdepth 1 -type f -name 'provenance-*.tsv' -print)
grep -Fxq "# openwrt.commit=$BPIR_OPENWRT_GIT_COMMIT" "$STALE_PROV" \
    || fail "migrated development provenance recorded the stale OpenWrt commit"
grep -Fxq '# openwrt.dirty=false' "$STALE_PROV" \
    || fail "migrated development provenance was captured before source synchronization"

# The documented compatibility form without an explicit mode is still an
# unbound source-development prepare. It must not retain the old OpenWrt HEAD
# merely because its marker intentionally uses development_bound=0.
LEGACY_ROOT="$TMP/legacy-source-workspace"
mkdir -p "$LEGACY_ROOT"
git clone -q "$BUILD" "$LEGACY_ROOT/bpirouter-build"
git clone -q "$UI" "$LEGACY_ROOT/bpirouter-ui"
git clone -q "$FEEDS" "$LEGACY_ROOT/bpirouter-feeds"
git clone -q "$OPENWRT" "$LEGACY_ROOT/bpirouter-build/openwrt"
git -C "$LEGACY_ROOT/bpirouter-build/openwrt" checkout -q --detach v25.12.2
env -u BPIR_RELEASE_LOCK \
    BPIR_BUILD_DIR="$LEGACY_ROOT/bpirouter-build" \
    BPIR_WORK_DIR="$LEGACY_ROOT/bpirouter-build/openwrt" \
    BPIR_FEEDS_DIR="$LEGACY_ROOT/bpirouter-feeds" \
    "$LEGACY_ROOT/bpirouter-build/scripts/prepare.sh" --board openwrt-one \
    --ui-source "$LEGACY_ROOT/bpirouter-ui" >"$TMP/legacy-source.log" 2>&1 \
    || { cat "$TMP/legacy-source.log"; fail "legacy source prepare did not migrate a stale OpenWrt checkout"; }
[ "$(git -C "$LEGACY_ROOT/bpirouter-build/openwrt" rev-parse HEAD)" = "$BPIR_OPENWRT_GIT_COMMIT" ] \
    || fail "legacy source prepare retained the stale OpenWrt baseline"
grep -Fxq 'development_bound=0' "$LEGACY_ROOT/bpirouter-build/openwrt/.bpirouter-prepared-board" \
    || fail "legacy source prepare changed its documented unbound marker semantics"

# A fresh sibling workspace has no openwrt/ checkout yet. The coordinator must
# bootstrap it under its batch lock before recording the OpenWrt commit instead
# of rejecting the documented first run as unidentifiable.
BOOT_ROOT="$TMP/bootstrap-workspace"
mkdir -p "$BOOT_ROOT"
git clone -q "$BUILD" "$BOOT_ROOT/bpirouter-build"
git clone -q "$UI" "$BOOT_ROOT/bpirouter-ui"
git clone -q "$FEEDS" "$BOOT_ROOT/bpirouter-feeds"
BOOT_OUT="$TMP/bootstrap-output"
BPIR_OPENWRT_CLONE_URL="$OPENWRT" BPIR_REBUILD_OUTPUT="$BOOT_OUT" \
    "$BOOT_ROOT/bpirouter-build/scripts/rebuild-all.sh" --development openwrt-one \
    >"$TMP/bootstrap.log" 2>&1 \
    || { cat "$TMP/bootstrap.log"; fail "fresh development workspace did not bootstrap OpenWrt"; }
[ -d "$BOOT_ROOT/bpirouter-build/openwrt/.git" ] \
    || fail "development coordinator did not create the OpenWrt checkout"
BOOT_PROV=$(find "$BOOT_OUT" -maxdepth 1 -type f -name 'provenance-*.tsv' -print)
[ -n "$BOOT_PROV" ] && [ "$(printf '%s\n' "$BOOT_PROV" | wc -l)" = 1 ] \
    || fail "bootstrapped development build did not publish one provenance record"
grep -Fxq "# openwrt.commit=$(git -C "$OPENWRT" rev-parse v25.12.5^{commit})" "$BOOT_PROV" \
    || fail "bootstrapped development provenance has the wrong OpenWrt commit"
grep -Fxq '# batch_complete=true' "$BOOT_PROV" \
    || fail "bootstrapped development build is not marked complete"

# `git worktree add` creates a valid checkout whose .git is a file. The batch
# bootstrap gate must accept it through Git itself rather than requiring a
# clone-style .git directory.
LINK_ROOT="$TMP/linked-worktree-workspace"
mkdir -p "$LINK_ROOT"
git clone -q "$BUILD" "$LINK_ROOT/bpirouter-build"
git clone -q "$UI" "$LINK_ROOT/bpirouter-ui"
git clone -q "$FEEDS" "$LINK_ROOT/bpirouter-feeds"
git -C "$OPENWRT" worktree add -q --detach "$LINK_ROOT/bpirouter-build/openwrt" HEAD
[ -f "$LINK_ROOT/bpirouter-build/openwrt/.git" ] \
    || fail "linked-worktree fixture does not have a .git file"
LINK_OUT="$TMP/linked-worktree-output"
BPIR_REBUILD_OUTPUT="$LINK_OUT" \
    "$LINK_ROOT/bpirouter-build/scripts/rebuild-all.sh" --development openwrt-one \
    >"$TMP/linked-worktree.log" 2>&1 \
    || { cat "$TMP/linked-worktree.log"; fail "valid linked OpenWrt worktree was refused"; }
LINK_PROV=$(find "$LINK_OUT" -maxdepth 1 -type f -name 'provenance-*.tsv' -print)
[ -n "$LINK_PROV" ] || fail "linked-worktree build did not publish provenance"
grep -Fxq '# batch_success=true' "$LINK_PROV" \
    || fail "linked-worktree development build was not successful"

# The batch lock serializes cooperating scripts, but a plain Git command does
# not honor it. Change HEAD after build-full has verified its per-board prepared
# tree and require the coordinator's boundary check to reject the batch.
HEAD_DRIFT_ROOT="$TMP/openwrt-head-drift-workspace"
mkdir -p "$HEAD_DRIFT_ROOT"
git clone -q "$BUILD" "$HEAD_DRIFT_ROOT/bpirouter-build"
git clone -q "$UI" "$HEAD_DRIFT_ROOT/bpirouter-ui"
git clone -q "$FEEDS" "$HEAD_DRIFT_ROOT/bpirouter-feeds"
git clone -q "$OPENWRT" "$HEAD_DRIFT_ROOT/bpirouter-build/openwrt"
mv "$HEAD_DRIFT_ROOT/bpirouter-build/scripts/build-full.sh" \
    "$HEAD_DRIFT_ROOT/bpirouter-build/scripts/build-full.real.sh"
cat >"$HEAD_DRIFT_ROOT/bpirouter-build/scripts/build-full.sh" <<'SH'
#!/bin/bash
set -eo pipefail
script_dir="$(cd "$(dirname "$0")" && pwd)"
"$script_dir/build-full.real.sh" "$@"
if [ "${MUTATE_OPENWRT_HEAD_AFTER_BUILD:-0}" = 1 ]; then
    git -C "$script_dir/../openwrt" \
        -c user.name=provenance-test \
        -c user.email=provenance-test@example.invalid \
        commit --allow-empty -qm post-build-head-drift
fi
SH
chmod +x "$HEAD_DRIFT_ROOT/bpirouter-build/scripts/build-full.sh"
HEAD_DRIFT_OUT="$TMP/openwrt-head-drift-output"
expect_fail "development batch with post-build OpenWrt HEAD drift" env \
    MUTATE_OPENWRT_HEAD_AFTER_BUILD=1 BPIR_REBUILD_OUTPUT="$HEAD_DRIFT_OUT" \
    "$HEAD_DRIFT_ROOT/bpirouter-build/scripts/rebuild-all.sh" --development openwrt-one
grep -RFq 'OpenWrt HEAD drifted after building openwrt-one' "$HEAD_DRIFT_OUT"/build-logs-* \
    || fail "batch did not identify the OpenWrt HEAD boundary drift"
HEAD_DRIFT_PROV=$(find "$HEAD_DRIFT_OUT" -maxdepth 1 -type f -name 'provenance-*.tsv' -print)
[ -n "$HEAD_DRIFT_PROV" ] || fail "OpenWrt HEAD-drift batch did not publish diagnostics"
grep -Fxq '# batch_success=false' "$HEAD_DRIFT_PROV" \
    || fail "OpenWrt HEAD-drift batch claimed success"
ok "OpenWrt HEAD is immutable across batch boundaries"

# Omitting board arguments means the exact supported six-board set even when
# individual fake boards fail. Use the isolated bootstrapped workspace because
# failed prepares intentionally invalidate its current marker and tree.
SIX_DEV_OUT="$TMP/development-six-board-output"
expect_fail "development six-board fixture batch with unsupported fake configs" env \
    BPIR_REBUILD_OUTPUT="$SIX_DEV_OUT" \
    "$BOOT_ROOT/bpirouter-build/scripts/rebuild-all.sh" --development
SIX_DEV_PROV=$(find "$SIX_DEV_OUT" -maxdepth 1 -type f -name 'provenance-*.tsv' -print)
[ -n "$SIX_DEV_PROV" ] && [ "$(printf '%s\n' "$SIX_DEV_PROV" | wc -l)" = 1 ] \
    || fail "six-board development fixture did not publish one completed record"
grep -Fxq '# requested_boards=bpi-r4,bpi-r4-lite,bpi-r3,bpi-r3-mini,openwrt-one,bpi-r4-pro' \
    "$SIX_DEV_PROV" || fail "six-board development provenance lost the requested set"
grep -Fxq '# scope=six-board' "$SIX_DEV_PROV" \
    || fail "complete supported board selection was not classified as six-board"
grep -Fxq '# batch_complete=true' "$SIX_DEV_PROV" \
    || fail "normally terminated six-board fixture batch is not marked complete"
grep -Fxq '# batch_success=false' "$SIX_DEV_PROV" \
    || fail "failed six-board fixture batch claimed success"
[ "$(awk -F '\t' '$1 !~ /^#/ && $1 != "board" && NF { count++ } END { print count+0 }' \
        "$SIX_DEV_PROV")" = 6 ] \
    || fail "six-board development provenance does not contain six result rows"
cp "$TMP/pre-development-marker" "$MARKER"
ok "development rebuild identity and release isolation"

# rebuild-all may continue after a board failure to preserve diagnostics, but
# the batch result must be non-zero. Unset the fake workspace overrides so the
# deliberately unrelated lock fails before prepare can touch any real tree.
expect_fail "rebuild-all batch with a failed board" env \
    -u BPIR_BUILD_DIR -u BPIR_WORK_DIR -u BPIR_UI_DIR -u BPIR_FEEDS_DIR -u BPIR_CONFIG_DIR \
    BPIR_REBUILD_OUTPUT="$TMP/rebuild-output" \
    "$SCRIPT_DIR/rebuild-all.sh" --release-lock "$LOCK" openwrt-one
grep -q 'release build failed for: openwrt-one' "$TMP/negative.log" \
    || fail "rebuild-all did not report the failed board at batch exit"
FAILED_PROV=$(find "$TMP/rebuild-output" -maxdepth 1 -type f -name 'provenance-*.tsv' -print)
[ -n "$FAILED_PROV" ] && [ "$(printf '%s\n' "$FAILED_PROV" | wc -l)" = 1 ] \
    || fail "failed formal batch did not publish one completed diagnostic record"
grep -Fxq '# release_eligible=false' "$FAILED_PROV" \
    || fail "failed formal batch claimed release eligibility"
grep -Fxq '# requested_boards=openwrt-one' "$FAILED_PROV" \
    || fail "failed formal batch lost its requested-board scope"
grep -Fxq '# scope=partial' "$FAILED_PROV" \
    || fail "failed one-board formal batch claimed six-board scope"
grep -Fxq '# batch_complete=true' "$FAILED_PROV" \
    || fail "normally terminated failed batch is not marked complete"
grep -Fxq '# batch_success=false' "$FAILED_PROV" \
    || fail "failed formal batch claimed success"

# A mutation introduced by make itself after the start check must be caught by
# the full build-end prepared-tree recomputation, and no sidecar may survive.
cp "$OPENWRT/source.txt" "$TMP/build-end-source.backup"
expect_fail "build-end prepared tree drift" env MUTATE_PREPARED=1 \
    "$PIPELINE_SCRIPTS/build-full.sh" --board openwrt-one --jobs 1 --release-lock "$LOCK"
[ ! -e "$SIDECAR" ] || fail "failed build-end drift left a release sidecar"
cp "$TMP/build-end-source.backup" "$OPENWRT/source.txt"

[ "$(sed -n 's/^input_lock_sha256=//p' "$MARKER")" = "$LOCK_SHA" ] \
    || fail "test marker no longer names the original lock"
ok "all release-build provenance mutations were rejected"
