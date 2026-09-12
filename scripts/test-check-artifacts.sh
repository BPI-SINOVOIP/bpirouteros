#!/bin/bash
# Regression test for the release APK freshness gate. In particular, a long
# result set must be fully consumed: `find | head` under pipefail used to exit
# with SIGPIPE (141) before printing the actionable stale-package diagnostic.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT

mkdir -p "$TEST_ROOT/build/scripts" \
    "$TEST_ROOT/build/openwrt/bin/packages/test_arch/bpirouter" \
    "$TEST_ROOT/build/openwrt/feeds" \
    "$TEST_ROOT/ui/backend" "$TEST_ROOT/ui/frontend/src" "$TEST_ROOT/ui/deploy" \
    "$TEST_ROOT/ui/scripts/lib" \
    "$TEST_ROOT/feeds/net/bpirouter-base/files/etc/uci-defaults" \
    "$TEST_ROOT/feeds/net/bpirouter-ui"
cp "$SCRIPT_DIR/check-artifacts.sh" "$TEST_ROOT/build/scripts/check-artifacts.sh"
cat >"$TEST_ROOT/build/scripts/boards.sh" <<'EOF'
pkg_arch() { printf '%s\n' test_arch; }
EOF
chmod +x "$TEST_ROOT/build/scripts/check-artifacts.sh"
ln -s "$TEST_ROOT/feeds" "$TEST_ROOT/build/openwrt/feeds/bpirouter"

APK="$TEST_ROOT/build/openwrt/bin/packages/test_arch/bpirouter/bpirouter-ui-1.apk"
BASE_APK="$TEST_ROOT/build/openwrt/bin/packages/test_arch/bpirouter/bpirouter-base-1.apk"
: >"$APK"
: >"$BASE_APK"
touch -t 202001010000 "$APK"
touch -t 202001010000 "$BASE_APK"
printf '%s\n' 'package source' >"$TEST_ROOT/feeds/net/bpirouter-base/Makefile"
printf '%s\n' 'ui package source' >"$TEST_ROOT/feeds/net/bpirouter-ui/Makefile"
for runner in seg tel cell qos; do
    printf '%s acceptance runner\n' "$runner" >"$TEST_ROOT/ui/scripts/$runner-acceptance.sh"
done
printf '%s\n' 'acceptance common' >"$TEST_ROOT/ui/scripts/lib/acceptance-common.sh"
for i in $(seq 1 58); do
    printf 'source %s\n' "$i" >"$TEST_ROOT/ui/backend/source-$i.go"
done

set +e
BPIR_UI_DIR="$TEST_ROOT/ui" BPIR_FEEDS_DIR="$TEST_ROOT/feeds" \
    "$TEST_ROOT/build/scripts/check-artifacts.sh" \
    >"$TEST_ROOT/stale.out" 2>"$TEST_ROOT/stale.err"
rc=$?
set -e

[ "$rc" -eq 1 ] || {
    echo "FAIL: stale APK should exit 1 with diagnostics, got $rc" >&2
    cat "$TEST_ROOT/stale.err" >&2
    exit 1
}
grep -Fq 'bpirouter-ui source is newer than the packaged .apk' "$TEST_ROOT/stale.err"
grep -Fq '64 file(s) changed since' "$TEST_ROOT/stale.err"
grep -Fq 'Run:' "$TEST_ROOT/stale.err"

touch "$APK" "$BASE_APK"
BPIR_UI_DIR="$TEST_ROOT/ui" BPIR_FEEDS_DIR="$TEST_ROOT/feeds" \
    "$TEST_ROOT/build/scripts/check-artifacts.sh" \
    >"$TEST_ROOT/fresh.out" 2>"$TEST_ROOT/fresh.err"
grep -Fq 'package is newer than every source file' "$TEST_ROOT/fresh.out"

UI_HASH_SCRIPT="$SCRIPT_DIR/../../bpirouter-ui/deploy/artifact-hash.sh"
[ -x "$UI_HASH_SCRIPT" ] || {
    echo "FAIL: cannot locate bpirouter-ui artifact-hash.sh" >&2
    exit 1
}
for acceptance_input in \
    scripts/seg-acceptance.sh \
    scripts/tel-acceptance.sh \
    scripts/cell-acceptance.sh \
    scripts/qos-acceptance.sh \
    scripts/lib/acceptance-common.sh
do
    hash_before=$("$UI_HASH_SCRIPT" src "$TEST_ROOT/ui")
    printf 'source-hash mutation for %s\n' "$acceptance_input" >>"$TEST_ROOT/ui/$acceptance_input"
    hash_after=$("$UI_HASH_SCRIPT" src "$TEST_ROOT/ui")
    [ "$hash_before" != "$hash_after" ] || {
        echo "FAIL: $acceptance_input did not change the UI source hash" >&2
        exit 1
    }
done
mv "$TEST_ROOT/ui/scripts/seg-acceptance.sh" "$TEST_ROOT/seg-acceptance.saved"
if "$UI_HASH_SCRIPT" src "$TEST_ROOT/ui" >"$TEST_ROOT/missing-tool-hash.out" 2>&1; then
    echo "FAIL: source hash accepted a missing required acceptance runner" >&2
    exit 1
fi
mv "$TEST_ROOT/seg-acceptance.saved" "$TEST_ROOT/ui/scripts/seg-acceptance.sh"
set +e
BPIR_UI_DIR="$TEST_ROOT/ui" BPIR_FEEDS_DIR="$TEST_ROOT/feeds" \
    "$TEST_ROOT/build/scripts/check-artifacts.sh" \
    >"$TEST_ROOT/ui-runner-stale.out" 2>"$TEST_ROOT/ui-runner-stale.err"
rc=$?
set -e
[ "$rc" -eq 1 ] || {
    echo "FAIL: stale APK after an acceptance runner change should exit 1, got $rc" >&2
    exit 1
}
grep -Fq 'bpirouter-ui source is newer than the packaged .apk' "$TEST_ROOT/ui-runner-stale.err"

touch "$APK"
common_hash_before=$("$UI_HASH_SCRIPT" src "$TEST_ROOT/ui")
printf '%s\n' 'reviewed common-library change' >>"$TEST_ROOT/ui/scripts/lib/acceptance-common.sh"
common_hash_after=$("$UI_HASH_SCRIPT" src "$TEST_ROOT/ui")
[ "$common_hash_before" != "$common_hash_after" ] || {
    echo "FAIL: acceptance common library did not change the UI source hash" >&2
    exit 1
}
set +e
BPIR_UI_DIR="$TEST_ROOT/ui" BPIR_FEEDS_DIR="$TEST_ROOT/feeds" \
    "$TEST_ROOT/build/scripts/check-artifacts.sh" \
    >"$TEST_ROOT/ui-common-stale.out" 2>"$TEST_ROOT/ui-common-stale.err"
rc=$?
set -e
[ "$rc" -eq 1 ] || {
    echo "FAIL: stale APK after acceptance-common change should exit 1, got $rc" >&2
    exit 1
}
grep -Fq 'bpirouter-ui source is newer than the packaged .apk' "$TEST_ROOT/ui-common-stale.err"

touch -t 202001010000 "$APK"

printf '%s\n' 'PKG_VERSION:=$(BPIROUTER_UI_PKG_VERSION)' \
    >>"$TEST_ROOT/feeds/net/bpirouter-ui/Makefile"
set +e
BPIR_UI_DIR="$TEST_ROOT/ui" BPIR_FEEDS_DIR="$TEST_ROOT/feeds" \
    "$TEST_ROOT/build/scripts/check-artifacts.sh" \
    >"$TEST_ROOT/ui-package-version-stale.out" 2>"$TEST_ROOT/ui-package-version-stale.err"
rc=$?
set -e
[ "$rc" -eq 1 ] || {
    echo "FAIL: stale APK after package-version recipe change should exit 1, got $rc" >&2
    exit 1
}
grep -Fq 'bpirouter-ui source is newer than the packaged .apk' \
    "$TEST_ROOT/ui-package-version-stale.err"
touch "$APK"

printf '%s\n' 'new canonicalizer source' \
    >"$TEST_ROOT/feeds/net/bpirouter-base/files/etc/uci-defaults/11-bpirouter-mwan3-canonical"
set +e
BPIR_UI_DIR="$TEST_ROOT/ui" BPIR_FEEDS_DIR="$TEST_ROOT/feeds" \
    "$TEST_ROOT/build/scripts/check-artifacts.sh" \
    >"$TEST_ROOT/base-stale.out" 2>"$TEST_ROOT/base-stale.err"
rc=$?
set -e
[ "$rc" -eq 1 ] || {
    echo "FAIL: stale bpirouter-base APK should exit 1, got $rc" >&2
    exit 1
}
grep -Fq 'bpirouter-base source is newer than the packaged .apk' "$TEST_ROOT/base-stale.err"
grep -Fq 'QMF-15/QMF-16 payload vintage' "$TEST_ROOT/base-stale.err"

touch "$BASE_APK"
BPIR_UI_DIR="$TEST_ROOT/ui" BPIR_FEEDS_DIR="$TEST_ROOT/feeds" \
    "$TEST_ROOT/build/scripts/check-artifacts.sh" \
    >"$TEST_ROOT/base-fresh.out" 2>"$TEST_ROOT/base-fresh.err"
grep -Fq 'bpirouter-base package is newer than every source file' "$TEST_ROOT/base-fresh.out"

mkdir -p "$TEST_ROOT/feeds/net/bpirouter-base/.git" "$TEST_ROOT/feeds/net/bpirouter-base/tmp"
printf 'editor scratch\n' >"$TEST_ROOT/feeds/net/bpirouter-base/.change.swp"
printf 'backup scratch\n' >"$TEST_ROOT/feeds/net/bpirouter-base/Makefile~"
printf 'git metadata\n' >"$TEST_ROOT/feeds/net/bpirouter-base/.git/index"
printf 'temporary scratch\n' >"$TEST_ROOT/feeds/net/bpirouter-base/tmp/notes.tmp"
BPIR_UI_DIR="$TEST_ROOT/ui" BPIR_FEEDS_DIR="$TEST_ROOT/feeds" \
    "$TEST_ROOT/build/scripts/check-artifacts.sh" \
    >"$TEST_ROOT/base-temp.out" 2>"$TEST_ROOT/base-temp.err"
grep -Fq 'bpirouter-base package is newer than every source file' "$TEST_ROOT/base-temp.out"

# A coordinator checkout may sit beside a shared OpenWrt tree.  Its sibling
# feed can have newer checkout mtimes even though OpenWrt consumed the installed
# feed symlink.  That unused checkout must not make a current package look stale.
cp -a "$TEST_ROOT/feeds" "$TEST_ROOT/unused-feeds"
printf '%s\n' 'same release, later checkout time' \
    >>"$TEST_ROOT/unused-feeds/net/bpirouter-base/Makefile"
BPIR_UI_DIR="$TEST_ROOT/ui" BPIR_FEEDS_DIR="$TEST_ROOT/unused-feeds" \
    "$TEST_ROOT/build/scripts/check-artifacts.sh" \
    >"$TEST_ROOT/unused-feed.out" 2>"$TEST_ROOT/unused-feed.err"
grep -Fq 'bpirouter-base package is newer than every source file' "$TEST_ROOT/unused-feed.out"

printf '%s\n' 'install a new runtime sidecar' >>"$TEST_ROOT/feeds/net/bpirouter-ui/Makefile"
set +e
BPIR_UI_DIR="$TEST_ROOT/ui" BPIR_FEEDS_DIR="$TEST_ROOT/feeds" \
    "$TEST_ROOT/build/scripts/check-artifacts.sh" \
    >"$TEST_ROOT/ui-recipe-stale.out" 2>"$TEST_ROOT/ui-recipe-stale.err"
rc=$?
set -e
[ "$rc" -eq 1 ] || {
    echo "FAIL: stale bpirouter-ui package recipe should exit 1, got $rc" >&2
    exit 1
}
grep -Fq 'bpirouter-ui source is newer than the packaged .apk' "$TEST_ROOT/ui-recipe-stale.err"

echo 'PASS: artifact freshness follows the installed feed and binds UI/base payload vintage'
