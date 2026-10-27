#!/bin/bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
TMP=$(mktemp -d -t bpir-acceptance-rootfs-XXXXXX)
trap 'rm -rf "$TMP"' EXIT
ROOT=$TMP/root
FEED=$TMP/feed
mkdir -p "$ROOT/etc" "$ROOT/usr/bin" "$ROOT/www/bpirouter/assets" \
    "$ROOT/usr/share/bpirouter/gcom" \
    "$ROOT/usr/libexec" "$ROOT/etc/init.d" "$ROOT/etc/uci-defaults" "$FEED"

fail() { echo "FAIL: $*" >&2; exit 1; }
expect_fail() {
    local name=$1
    shift
    if "$@" >"$TMP/negative.log" 2>&1; then fail "$name was accepted"; fi
    echo "ok: $name refused"
}

src=$(printf source | sha256sum | awk '{print $1}')
art=$(printf artifact | sha256sum | awk '{print $1}')
printf 'apid bytes\n' >"$FEED/bpirouter-apid"
cp "$FEED/bpirouter-apid" "$ROOT/usr/bin/bpirouter-apid"
chmod 755 "$ROOT/usr/bin/bpirouter-apid"
apid=$(sha256sum "$FEED/bpirouter-apid" | awk '{print $1}')
cat >"$ROOT/etc/bpirouter-version" <<EOF
BPIROUTER_SRC_REV=test
BPIROUTER_SRC_HASH=$src
BPIROUTER_BUILT=2026-08-16T00:00:00Z
EOF
printf '<html>formal UI</html>\n' >"$ROOT/www/bpirouter/index.html"
printf 'formal chunk\n' >"$ROOT/www/bpirouter/assets/app.js"
printf 'gcom script\n' >"$ROOT/usr/share/bpirouter/gcom/connect.gcom"
printf 'OTA restore helper\n' >"$ROOT/usr/libexec/bpirouter-ota-restore"
printf 'OTA restore init\n' >"$ROOT/etc/init.d/bpirouter-ota-restore"
printf 'product setup defaults\n' >"$ROOT/etc/uci-defaults/99-bpirouter-setup"
chmod 755 "$ROOT/usr/libexec/bpirouter-ota-restore" \
    "$ROOT/etc/init.d/bpirouter-ota-restore" "$ROOT/etc/uci-defaults/"*
file_row() {
    local kind=$1 mode=$2 path=$3 file=$ROOT$3
    printf '%s|%s|%s|%s|%s\n' "$kind" "$mode" "$(wc -c <"$file" | tr -d ' ')" \
        "$(sha256sum "$file" | awk '{print $1}')" "$path"
}
{
    printf '%s\n' 'BPIR-PAYLOAD|1' 'T|/www/bpirouter' 'T|/usr/share/bpirouter'
    file_row F 755 /usr/bin/bpirouter-apid
    file_row F 755 /usr/libexec/bpirouter-ota-restore
    file_row F 755 /etc/init.d/bpirouter-ota-restore
    file_row F 644 /etc/bpirouter-version
    file_row F 644 /www/bpirouter/index.html
    file_row F 644 /www/bpirouter/assets/app.js
    file_row F 644 /usr/share/bpirouter/gcom/connect.gcom
    file_row B 755 /etc/uci-defaults/99-bpirouter-setup
} | LC_ALL=C sort >"$FEED/.payload-inventory"
cp "$FEED/.payload-inventory" "$ROOT/etc/bpirouter-product-payload.manifest"
inventory=$(sha256sum "$FEED/.payload-inventory" | awk '{print $1}')
printf 'src %s\nart %s\ninventory %s\n' "$src" "$art" "$inventory" >"$FEED/.manifest"
cp "$FEED/.manifest" "$ROOT/etc/bpirouter-ui-build.manifest"
cat >"$TMP/proof.json" <<EOF
{"source_sha256":"$src","manifest_artifact_sha256":"$art","payload_inventory_sha256":"$inventory","apid_sha256":"$apid"}
EOF

"$SCRIPT_DIR/check-acceptance-provenance-rootfs.sh" "$ROOT" --ui-proof "$TMP/proof.json" >/dev/null
"$SCRIPT_DIR/check-acceptance-provenance-rootfs.sh" "$ROOT" --feed-files "$FEED" >/dev/null
echo "ok: matching rootfs accepted through proof and feed boundaries"

# Acceptance tools are delivered beside the image. An image that still carries
# them is refused even when every hash binding its inventory to the build agrees.
TOOLS_ROOT=$TMP/tools-root
TOOLS_FEED=$TMP/tools-feed
rm -rf "$TOOLS_ROOT" "$TOOLS_FEED"
cp -a "$ROOT" "$TOOLS_ROOT"
cp -a "$FEED" "$TOOLS_FEED"
mkdir -p "$TOOLS_ROOT/usr/share/bpirouter/acceptance"
printf 'acceptance runner\n' >"$TOOLS_ROOT/usr/share/bpirouter/acceptance/cell-acceptance.sh"
chmod 755 "$TOOLS_ROOT/usr/share/bpirouter/acceptance/cell-acceptance.sh"
{
    cat "$ROOT/etc/bpirouter-product-payload.manifest"
    printf 'F|755|%s|%s|%s\n' \
        "$(wc -c <"$TOOLS_ROOT/usr/share/bpirouter/acceptance/cell-acceptance.sh" | tr -d ' ')" \
        "$(sha256sum "$TOOLS_ROOT/usr/share/bpirouter/acceptance/cell-acceptance.sh" | awk '{print $1}')" \
        /usr/share/bpirouter/acceptance/cell-acceptance.sh
} | LC_ALL=C sort >"$TOOLS_FEED/.payload-inventory"
cp "$TOOLS_FEED/.payload-inventory" "$TOOLS_ROOT/etc/bpirouter-product-payload.manifest"
tools_inventory=$(sha256sum "$TOOLS_FEED/.payload-inventory" | awk '{print $1}')
printf 'src %s\nart %s\ninventory %s\n' "$src" "$art" "$tools_inventory" >"$TOOLS_FEED/.manifest"
cp "$TOOLS_FEED/.manifest" "$TOOLS_ROOT/etc/bpirouter-ui-build.manifest"
expect_fail "release image carrying acceptance tools" \
    "$SCRIPT_DIR/check-acceptance-provenance-rootfs.sh" "$TOOLS_ROOT" --feed-files "$TOOLS_FEED"
grep -Fq "payload inventory carries formal acceptance tools" "$TMP/negative.log" \
    || { cat "$TMP/negative.log" >&2; fail "acceptance tools in the image were refused for the wrong reason"; }


mv "$FEED/.manifest" "$TMP/feed-manifest.real"
ln -s "$TMP/feed-manifest.real" "$FEED/.manifest"
expect_fail "symlinked feed manifest" "$SCRIPT_DIR/check-acceptance-provenance-rootfs.sh" \
    "$ROOT" --feed-files "$FEED"
rm "$FEED/.manifest"
mv "$TMP/feed-manifest.real" "$FEED/.manifest"

mv "$FEED/bpirouter-apid" "$TMP/feed-apid.real"
ln -s "$TMP/feed-apid.real" "$FEED/bpirouter-apid"
expect_fail "symlinked feed apid" "$SCRIPT_DIR/check-acceptance-provenance-rootfs.sh" \
    "$ROOT" --feed-files "$FEED"
rm "$FEED/bpirouter-apid"
mv "$TMP/feed-apid.real" "$FEED/bpirouter-apid"

mv "$FEED/.payload-inventory" "$TMP/feed-inventory.real"
ln -s "$TMP/feed-inventory.real" "$FEED/.payload-inventory"
expect_fail "symlinked feed payload inventory" "$SCRIPT_DIR/check-acceptance-provenance-rootfs.sh" \
    "$ROOT" --feed-files "$FEED"
rm "$FEED/.payload-inventory"
mv "$TMP/feed-inventory.real" "$FEED/.payload-inventory"

mutate() {
    local name=$1 path=$2 replacement=$3
    cp "$path" "$TMP/original"
    printf '%s\n' "$replacement" >"$path"
    expect_fail "$name" "$SCRIPT_DIR/check-acceptance-provenance-rootfs.sh" "$ROOT" --ui-proof "$TMP/proof.json"
    cp "$TMP/original" "$path"
}
mutate wrong-ui-source "$ROOT/etc/bpirouter-ui-build.manifest" \
    "src ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff
art $art
inventory $inventory"
mutate wrong-version-source "$ROOT/etc/bpirouter-version" \
    "BPIROUTER_SRC_HASH=ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
mutate wrong-apid "$ROOT/usr/bin/bpirouter-apid" "old apid bytes"

cp "$ROOT/www/bpirouter/index.html" "$TMP/index.real"
rm "$ROOT/www/bpirouter/index.html"
expect_fail "missing UI index" "$SCRIPT_DIR/check-acceptance-provenance-rootfs.sh" "$ROOT" --ui-proof "$TMP/proof.json"
cp "$TMP/index.real" "$ROOT/www/bpirouter/index.html"
cp "$ROOT/www/bpirouter/assets/app.js" "$TMP/chunk.real"
printf 'modified chunk\n' >"$ROOT/www/bpirouter/assets/app.js"
expect_fail "modified UI chunk" "$SCRIPT_DIR/check-acceptance-provenance-rootfs.sh" "$ROOT" --ui-proof "$TMP/proof.json"
cp "$TMP/chunk.real" "$ROOT/www/bpirouter/assets/app.js"
printf 'unlisted UI file\n' >"$ROOT/www/bpirouter/foreign.js"
expect_fail "unlisted UI payload" "$SCRIPT_DIR/check-acceptance-provenance-rootfs.sh" "$ROOT" --ui-proof "$TMP/proof.json"
rm "$ROOT/www/bpirouter/foreign.js"
cp "$ROOT/usr/libexec/bpirouter-ota-restore" "$TMP/ota-helper.real"
printf 'mutated OTA restore\n' >"$ROOT/usr/libexec/bpirouter-ota-restore"
expect_fail "modified immutable OTA restore helper" "$SCRIPT_DIR/check-acceptance-provenance-rootfs.sh" \
    "$ROOT" --ui-proof "$TMP/proof.json"
cp "$TMP/ota-helper.real" "$ROOT/usr/libexec/bpirouter-ota-restore"
cp "$ROOT/etc/init.d/bpirouter-ota-restore" "$TMP/ota-init.real"
printf 'mutated OTA init\n' >"$ROOT/etc/init.d/bpirouter-ota-restore"
expect_fail "modified immutable OTA restore init" "$SCRIPT_DIR/check-acceptance-provenance-rootfs.sh" \
    "$ROOT" --ui-proof "$TMP/proof.json"
cp "$TMP/ota-init.real" "$ROOT/etc/init.d/bpirouter-ota-restore"
mv "$ROOT/etc/uci-defaults/99-bpirouter-setup" "$TMP/setup-default.real"
expect_fail "missing immutable product setup default" "$SCRIPT_DIR/check-acceptance-provenance-rootfs.sh" \
    "$ROOT" --ui-proof "$TMP/proof.json"
mv "$TMP/setup-default.real" "$ROOT/etc/uci-defaults/99-bpirouter-setup"
mv "$ROOT/etc/bpirouter-product-payload.manifest" "$TMP/root-inventory.real"
ln -s "$TMP/root-inventory.real" "$ROOT/etc/bpirouter-product-payload.manifest"
expect_fail "symlinked installed payload inventory" "$SCRIPT_DIR/check-acceptance-provenance-rootfs.sh" \
    "$ROOT" --ui-proof "$TMP/proof.json"
rm "$ROOT/etc/bpirouter-product-payload.manifest"
mv "$TMP/root-inventory.real" "$ROOT/etc/bpirouter-product-payload.manifest"
ln -s "$ROOT/etc/bpirouter-ui-build.manifest" "$TMP/symlink-manifest"
mv "$ROOT/etc/bpirouter-ui-build.manifest" "$TMP/manifest.real"
ln -s "$TMP/manifest.real" "$ROOT/etc/bpirouter-ui-build.manifest"
expect_fail "symlinked UI manifest" "$SCRIPT_DIR/check-acceptance-provenance-rootfs.sh" "$ROOT" --ui-proof "$TMP/proof.json"

echo "PASS: acceptance provenance rootfs anti-mutation suite"
