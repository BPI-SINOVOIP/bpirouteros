#!/bin/bash
# Regression test for isolated source-cache collection.  OpenWrt owns its
# default dl/ directory, so the collector must select a per-board directory via
# CONFIG_DOWNLOAD_FOLDER rather than substituting a symlink at dl/.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT

mkdir -p "$TEST_ROOT/build/scripts" "$TEST_ROOT/build/openwrt/dl"
cp "$SCRIPT_DIR/collect-source-cache.sh" "$TEST_ROOT/build/scripts/"
chmod +x "$TEST_ROOT/build/scripts/collect-source-cache.sh"

cat >"$TEST_ROOT/build/scripts/boards.sh" <<'EOF'
VALID_BOARDS=test-board
EOF
cat >"$TEST_ROOT/build/scripts/prepare.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
printf '%s\n' 'CONFIG_LOCALMIRROR=""' > openwrt/.config
EOF
chmod +x "$TEST_ROOT/build/scripts/prepare.sh"
cat >"$TEST_ROOT/build/openwrt/Makefile" <<'EOF'
include .config
DL_DIR := $(subst ",,$(CONFIG_DOWNLOAD_FOLDER))
.PHONY: download
download:
	@mkdir -p "$(DL_DIR)"
	@printf 'fixture source\n' > "$(DL_DIR)/fixture.tar.gz"
	@printf 'download.pl "$(DL_DIR)" "fixture.tar.gz" "skip" "https://example.invalid/fixture"\n'
EOF
printf 'keep\n' >"$TEST_ROOT/build/openwrt/dl/preexisting"

(
    cd "$TEST_ROOT/build"
    ./scripts/collect-source-cache.sh --output dist/cache --boards test-board \
        >"$TEST_ROOT/out" 2>"$TEST_ROOT/err"
)

ABS_CACHE="$TEST_ROOT/build/dist/cache"
[ -d "$TEST_ROOT/build/openwrt/dl" ]
[ ! -L "$TEST_ROOT/build/openwrt/dl" ]
[ -f "$TEST_ROOT/build/openwrt/dl/preexisting" ]
[ -f "$ABS_CACHE/dl-test-board/fixture.tar.gz" ]
[ -s "$ABS_CACHE/manifest/test-board.tsv" ]

# A relative output must have been normalized before recursive make evaluates
# DL_DIR; otherwise it lands below the current package directory instead.
! find "$TEST_ROOT/build/openwrt" -path '*/dist/cache/*' -type f | grep -q .

rm -rf "$TEST_ROOT/build/openwrt/dl"
ln -s "$TEST_ROOT/other-downloads" "$TEST_ROOT/build/openwrt/dl"
if (
    cd "$TEST_ROOT/build"
    ./scripts/collect-source-cache.sh --output dist/rejected --boards test-board
) >"$TEST_ROOT/legacy-symlink.out" 2>"$TEST_ROOT/legacy-symlink.err"; then
    echo "FAIL: collector accepted a legacy openwrt/dl symlink" >&2
    exit 1
fi
grep -Fq 'refusing legacy symlink at openwrt/dl' "$TEST_ROOT/legacy-symlink.err"

echo "PASS: collect-source-cache uses an absolute CONFIG_DOWNLOAD_FOLDER"
